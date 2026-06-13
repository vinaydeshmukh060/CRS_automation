#!/bin/sh
#==============================================================================
# oem_failed_jobs_report.sh
#
# Purpose:
#   On a Data Guard pair (or RAC node), figure out which Oracle instance is
#   actually running on THIS host (by checking PMON against a candidate list
#   and reading oratab for ORACLE_HOME), connect AS SYSDBA (OS auth, no
#   password file), confirm the database is PRIMARY (exit quietly if it is
#   a PHYSICAL STANDBY), locate the PDB hosting the SYSMAN/OEM repository
#   (PDB-aware, auto-detected), then:
#     - query SYSMAN.MGMT$JOB / MGMT$JOB_EXECUTION_HISTORY for custom jobs
#       that FAILED in the last 24 hours
#     - build an HTML report via SQL*Plus SET MARKUP HTML ON
#     - write a custom ORA-20100 entry to the alert log if any failures found
#     - email the HTML report inline AND as an attachment via sendmail
#
# Compatibility:
#   POSIX /bin/sh - works on Oracle Solaris /bin/sh and Linux bash/dash.
#   No GNU-only flags. Raw /usr/sbin/sendmail with manual MIME boundaries.
#
# Usage:
#   ./oem_failed_jobs_report.sh                 -> uses INSTANCE_LIST below
#   ./oem_failed_jobs_report.sh inst1 inst2     -> overrides INSTANCE_LIST
#
# Prerequisites (no DB grants needed - SYS has everything via SYSDBA):
#   - Run as the "oracle" OS user (member of the dba/oinstall OS group) so
#     that "CONNECT / AS SYSDBA" succeeds via OS authentication.
#   - /etc/oratab (Linux) or /var/opt/oracle/oratab (Solaris) must list the
#     instance(s) with a valid ORACLE_HOME.
#   - /usr/sbin/sendmail must be configured and able to relay mail.
#==============================================================================

############################################################
# 1. CONFIGURATION - EDIT FOR YOUR SITE
############################################################

# Candidate instance names that may be running on THIS node (Data Guard
# primary/standby pair, or RAC instances). The script picks whichever one
# has a live PMON process on this host. Override on the command line.
INSTANCE_LIST="inst1 inst2"

if [ $# -ge 1 ]; then
    INSTANCE_LIST="$*"
fi

# Optional: force a specific PDB name that hosts the SYSMAN/OEM repository.
# Leave blank ("") to auto-detect via CDB_USERS. Ignored on non-CDB DBs.
PDB_NAME_OVERRIDE=""

WORKDIR="/u01/app/oracle/admin/scripts/oem_alerts"
TIMESTAMP=`date +%Y%m%d_%H%M%S`
REPORT_FILE="${WORKDIR}/oem_failed_jobs_${TIMESTAMP}.html"
LOG_FILE="${WORKDIR}/oem_failed_jobs_${TIMESTAMP}.log"
TMP_MAIL="${WORKDIR}/oem_mail_${TIMESTAMP}.eml"

MAIL_FROM="oem-monitor@yourcompany.com"
MAIL_TO="dba-team@yourcompany.com"
SENDMAIL_BIN="/usr/sbin/sendmail"

mkdir -p "${WORKDIR}" 2>/dev/null

if [ ! -x "${SENDMAIL_BIN}" ]; then
    echo "`date`: ERROR - ${SENDMAIL_BIN} not found or not executable." >&2
    exit 1
fi

############################################################
# 2. FIND THE RUNNING INSTANCE (PMON) AND LOAD oratab ENV
############################################################

if [ -f /etc/oratab ]; then
    ORATAB=/etc/oratab
elif [ -f /var/opt/oracle/oratab ]; then
    ORATAB=/var/opt/oracle/oratab
else
    echo "`date`: ERROR - oratab not found in /etc or /var/opt/oracle." >> "${LOG_FILE}"
    exit 1
fi

FOUND_SID=""
for CAND_SID in ${INSTANCE_LIST}; do
    if ps -ef | grep -v grep | grep "ora_pmon_${CAND_SID}$" >/dev/null 2>&1; then
        FOUND_SID="${CAND_SID}"
        break
    fi
done

if [ -z "${FOUND_SID}" ]; then
    echo "`date`: INFO - No PMON process found on this node for instances: ${INSTANCE_LIST}. Nothing to do here." >> "${LOG_FILE}"
    exit 0
fi

ORACLE_SID="${FOUND_SID}"

ORACLE_HOME=`awk -F: -v sid="${ORACLE_SID}" '$0 !~ /^#/ && $1==sid {print $2; exit}' "${ORATAB}"`

if [ -z "${ORACLE_HOME}" ]; then
    echo "`date`: ERROR - SID ${ORACLE_SID} not found (or no ORACLE_HOME) in ${ORATAB}." >> "${LOG_FILE}"
    exit 1
fi

PATH=${ORACLE_HOME}/bin:${PATH}
export ORACLE_SID ORACLE_HOME PATH

echo "`date`: INFO - Detected running instance ${ORACLE_SID} (ORACLE_HOME=${ORACLE_HOME})." >> "${LOG_FILE}"

############################################################
# 3. CONNECT AS SYSDBA - CHECK ROLE / CDB / PDB HOSTING SYSMAN
############################################################
#
# If the role is PHYSICAL STANDBY, exit immediately and silently:
# no report, no email, no alert log entry.
#-------------------------------------------------------------

ROLE_OUTPUT=`sqlplus -s /nolog <<EOSQL
WHENEVER OSERROR EXIT FAILURE
CONNECT / AS SYSDBA
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT ON PAGES 0 LINESIZE 500 TRIMSPOOL ON

WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT 'ROLE='||DATABASE_ROLE FROM V\$DATABASE;
SELECT 'CDB='||CDB FROM V\$DATABASE;

WHENEVER SQLERROR CONTINUE
SELECT 'PDB='||NVL(MAX(c.name),'NONE')
FROM   CDB_USERS u, V\$CONTAINERS c
WHERE  u.username = 'SYSMAN'
AND    u.con_id   = c.con_id
AND    c.name    != 'CDB\$ROOT';

EXIT;
EOSQL`

DB_ROLE=`echo "${ROLE_OUTPUT}" | grep '^ROLE=' | sed 's/^ROLE=//' | tr -d '[:space:]'`
CDB_FLAG=`echo "${ROLE_OUTPUT}" | grep '^CDB='  | sed 's/^CDB=//'  | tr -d '[:space:]'`
PDB_DETECTED=`echo "${ROLE_OUTPUT}" | grep '^PDB=' | sed 's/^PDB=//' | tr -d '[:space:]'`

case "${DB_ROLE}" in
    PHYSICALSTANDBY*)
        echo "`date`: INFO - ${ORACLE_SID} is a PHYSICAL STANDBY. No report, email, or alert log entry will be generated. Exiting." >> "${LOG_FILE}"
        exit 0
        ;;
    PRIMARY*)
        ;;
    *)
        echo "`date`: ERROR - Unable to determine database role for ${ORACLE_SID} (got '${DB_ROLE}'). Aborting." >> "${LOG_FILE}"
        exit 1
        ;;
esac

# Resolve which PDB (if any) holds the SYSMAN repository
if [ -n "${PDB_NAME_OVERRIDE}" ]; then
    PDB_NAME="${PDB_NAME_OVERRIDE}"
elif [ "${CDB_FLAG}" = "YES" ] && [ -n "${PDB_DETECTED}" ] && [ "${PDB_DETECTED}" != "NONE" ]; then
    PDB_NAME="${PDB_DETECTED}"
else
    PDB_NAME=""
fi

if [ -n "${PDB_NAME}" ]; then
    CONTAINER_SQL="ALTER SESSION SET CONTAINER = ${PDB_NAME};"
    echo "`date`: INFO - ${ORACLE_SID} is PRIMARY (CDB=${CDB_FLAG}). SYSMAN repository found in PDB '${PDB_NAME}'." >> "${LOG_FILE}"
else
    CONTAINER_SQL=""
    echo "`date`: INFO - ${ORACLE_SID} is PRIMARY (CDB=${CDB_FLAG}). Using current container for SYSMAN repository." >> "${LOG_FILE}"
fi

############################################################
# 4. COUNT FAILED CUSTOM OEM JOBS IN THE LAST 24 HOURS
############################################################
#
# Per the Enterprise Manager Cloud Control Repository Views Reference,
# MGMT$JOB_EXECUTION_HISTORY.STATUS is a VARCHAR2 and 'Failed' is a valid
# value meaning one or more steps of the execution failed, so the
# predicate below (h.status = 'Failed') is correct as written.
#-------------------------------------------------------------

FAILED_COUNT=`sqlplus -s /nolog <<EOSQL | tr -d '[:space:]'
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
CONNECT / AS SYSDBA
${CONTAINER_SQL}
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT ON PAGES 0 LINESIZE 200
SELECT COUNT(*)
FROM   SYSMAN.MGMT\$JOB j,
       SYSMAN.MGMT\$JOB_EXECUTION_HISTORY h
WHERE  j.job_id     = h.job_id
AND    h.status     = 'Failed'
AND    h.start_time >= SYSDATE - 1;
EXIT;
EOSQL`

case "${FAILED_COUNT}" in
    ''|*[!0-9]*)
        echo "`date`: ERROR - Could not retrieve failed job count (got '${FAILED_COUNT}'). Treating as 0." >> "${LOG_FILE}"
        FAILED_COUNT=0
        ;;
    *)
        echo "`date`: INFO - ${FAILED_COUNT} failed custom job execution(s) found in the last 24 hours." >> "${LOG_FILE}"
        ;;
esac

############################################################
# 5. GENERATE THE HTML REPORT (SQL*Plus SET MARKUP HTML ON)
############################################################

sqlplus -s /nolog <<EOSQL >> "${LOG_FILE}" 2>&1
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
CONNECT / AS SYSDBA
${CONTAINER_SQL}

SET ECHO       OFF
SET FEEDBACK   OFF
SET VERIFY     OFF
SET TERMOUT    OFF
SET TRIMSPOOL  ON
SET TRIMOUT    ON
SET WRAP       OFF
SET PAGESIZE   50000
SET LINESIZE   32767
SET LONG       4000
SET LONGCHUNKSIZE 4000

SET MARKUP HTML ON HEAD '<title>OEM Custom Job Failure Report - ${ORACLE_SID} - ${TIMESTAMP}</title><style type="text/css"> body {font-family: Arial, Helvetica, sans-serif; font-size: 13px; color:#333333;} h1 {color:#cc0000; font-size:18px;} table {border-collapse: collapse; width:100%; margin-top:10px;} th {background-color:#cc0000; color:#ffffff; padding:6px 8px; text-align:left; border:1px solid #990000;} td {border:1px solid #cccccc; padding:6px 8px; vertical-align:top;} tr:nth-child(even) td {background-color:#f7f7f7;}</style>' BODY '' TABLE 'border="1" cellpadding="4" cellspacing="0"' ENTMAP ON SPOOL ON

COLUMN job_name   HEADING 'Job Name'
COLUMN job_owner  HEADING 'Owner'
COLUMN status     HEADING 'Status'
COLUMN start_time HEADING 'Start Time'
COLUMN end_time   HEADING 'End Time'
COLUMN error_msg  HEADING 'Error Message'

SPOOL ${REPORT_FILE}

PROMPT <h1>OEM Custom Job Failure Report</h1>
PROMPT <p>Instance: ${ORACLE_SID} &nbsp;|&nbsp; Failed job executions with a start time within the last 24 hours (SYSDATE - 1).</p>

-- NOTE: MGMT$JOB_EXECUTION_HISTORY has no ERROR_MSG column. The failure
-- detail comes from the failed step's OUTPUT in MGMT$JOB_STEP_HISTORY.
-- The scalar subquery below returns the output of the (first) failed
-- step for each execution, truncated to 4000 chars.
SELECT
       j.job_name                                       AS "Job Name",
       j.job_owner                                      AS "Owner",
       h.status                                         AS "Status",
       TO_CHAR(h.start_time, 'YYYY-MM-DD HH24:MI:SS')    AS "Start Time",
       TO_CHAR(h.end_time,   'YYYY-MM-DD HH24:MI:SS')    AS "End Time",
       (SELECT SUBSTR(s.output, 1, 4000)
          FROM SYSMAN.MGMT\$JOB_STEP_HISTORY s
         WHERE s.job_id       = h.job_id
           AND s.execution_id = h.execution_id
           AND s.status       = 'Failed'
           AND ROWNUM = 1)                               AS "Error Message"
FROM   SYSMAN.MGMT\$JOB j,
       SYSMAN.MGMT\$JOB_EXECUTION_HISTORY h
WHERE  j.job_id     = h.job_id
AND    h.status     = 'Failed'
AND    h.start_time >= SYSDATE - 1
ORDER BY h.start_time DESC;

SPOOL OFF
SET MARKUP HTML OFF
EXIT;
EOSQL

if [ ! -s "${REPORT_FILE}" ]; then
    echo "`date`: ERROR - Report file ${REPORT_FILE} was not generated or is empty. Aborting before email." >> "${LOG_FILE}"
    exit 1
fi

############################################################
# 6. WRITE A CUSTOM ORA- MESSAGE TO THE ALERT LOG (IF NEEDED)
############################################################
# Connect AS SYSDBA at the root container - KSDWRT writes to the
# instance-level alert log regardless of container.
#-------------------------------------------------------------

if [ "${FAILED_COUNT}" -gt 0 ]; then
    sqlplus -s /nolog <<EOSQL >> "${LOG_FILE}" 2>&1
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
CONNECT / AS SYSDBA
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT OFF

BEGIN
    SYS.DBMS_SYSTEM.KSDWRT(
        SYS.DBMS_SYSTEM.ALERT_FILE,
        'ORA-20100: OEM_JOB_MONITOR (${ORACLE_SID}) - ${FAILED_COUNT} custom OEM job execution(s) ' ||
        'reported FAILED status within the last 24 hours. ' ||
        'See report ${REPORT_FILE} (run ${TIMESTAMP}) for details.'
    );
END;
/

EXIT;
EOSQL

    if [ $? -eq 0 ]; then
        echo "`date`: INFO - Custom ORA-20100 message written to alert log." >> "${LOG_FILE}"
    else
        echo "`date`: ERROR - Failed to write to alert log via DBMS_SYSTEM.KSDWRT." >> "${LOG_FILE}"
    fi
else
    echo "`date`: INFO - No failed jobs found, alert log entry skipped." >> "${LOG_FILE}"
fi

############################################################
# 7. SEND THE HTML REPORT BY EMAIL (INLINE + ATTACHMENT)
############################################################
# Raw sendmail, hand-built multipart/mixed MIME message:
#   Part 1 - text/html  -> displayed inline in the mail body
#   Part 2 - text/html  -> same file, sent as an attachment
#-------------------------------------------------------------

if [ "${FAILED_COUNT}" -gt 0 ]; then
    SUBJECT="[ALERT] OEM Custom Job Failures Detected (${FAILED_COUNT}) on ${ORACLE_SID} - `date +%Y-%m-%d`"
else
    SUBJECT="[OK] OEM Custom Job Report - No Failures on ${ORACLE_SID} - `date +%Y-%m-%d`"
fi

BOUNDARY="OEM_REPORT_BOUNDARY_${TIMESTAMP}"
ATTACH_NAME="oem_failed_jobs_report_${ORACLE_SID}_${TIMESTAMP}.html"

{
    echo "From: ${MAIL_FROM}"
    echo "To: ${MAIL_TO}"
    echo "Subject: ${SUBJECT}"
    echo "MIME-Version: 1.0"
    echo "Content-Type: multipart/mixed; boundary=\"${BOUNDARY}\""
    echo ""
    echo "This is a MIME-formatted message. If you see this text it means your"
    echo "email client does not support MIME multipart messages."
    echo ""
    echo "--${BOUNDARY}"
    echo "Content-Type: text/html; charset=\"UTF-8\""
    echo "Content-Transfer-Encoding: 8bit"
    echo ""
    cat "${REPORT_FILE}"
    echo ""
    echo "--${BOUNDARY}"
    echo "Content-Type: text/html; name=\"${ATTACH_NAME}\""
    echo "Content-Transfer-Encoding: 8bit"
    echo "Content-Disposition: attachment; filename=\"${ATTACH_NAME}\""
    echo ""
    cat "${REPORT_FILE}"
    echo ""
    echo "--${BOUNDARY}--"
} > "${TMP_MAIL}"

${SENDMAIL_BIN} -t < "${TMP_MAIL}"

if [ $? -eq 0 ]; then
    echo "`date`: INFO - Report emailed to ${MAIL_TO} (subject: ${SUBJECT})." >> "${LOG_FILE}"
else
    echo "`date`: ERROR - sendmail returned a non-zero exit code while sending the report." >> "${LOG_FILE}"
fi

rm -f "${TMP_MAIL}"

exit 0
