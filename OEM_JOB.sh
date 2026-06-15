#!/bin/sh
#==============================================================================
# Script  : oem_failed_jobs_report.sh
# Version : 4.0
#
# Purpose :
#   Detects which Oracle instance is running on this host (PMON + oratab),
#   connects as SYSDBA, checks PRIMARY/STANDBY role, switches to the PDB
#   that contains SYSMAN if this is a CDB, queries OEM job failures in the
#   last 24 hours, generates an HTML report, writes to the alert log, and
#   emails the report.
#
# Key design in v4.0:
#   - ALL SQL runs in ONE sqlplus session per step (no multi-query heredocs
#     with shell-variable SQL injected mid-stream)
#   - PDB detection and container switch use a SQL script written to a temp
#     file so shell quoting can never corrupt the SQL
#   - Role, CDB flag, and PDB name each fetched in dedicated sqlplus calls
#     with output parsed from the LAST non-blank line only
#==============================================================================
# HOW TO USE
#==============================================================================
#
# 1. PREREQUISITES
#    a) Run as oracle OS user (member of dba/oinstall group).
#       "CONNECT / AS SYSDBA" uses OS authentication - no password needed.
#    b) /etc/oratab (Linux) or /var/opt/oracle/oratab (Solaris) must list
#       the instance(s), e.g.:
#         ROEMC02A1:/u01/app/oracle/product/19.29.0/dbhome_1:Y
#    c) /usr/sbin/sendmail must be able to relay mail.
#    d) WORKDIR (below) must be writable by the oracle user.
#
# 2. INSTALLATION
#    a) Copy script to e.g. /u01/app/oracle/admin/scripts/
#    b) chmod 750 oem_failed_jobs_report.sh
#    c) Edit Section 1 (CONFIGURATION) below.
#
# 3. RUNNING MANUALLY
#    # Uses INSTANCE_LIST baked into the script:
#    ./oem_failed_jobs_report.sh
#
#    # Override instance list on the command line:
#    ./oem_failed_jobs_report.sh ROEMC02A1 ROEMC02A2
#
#    Terminal output example:
#      [2026-06-15 09:10:01] INFO  - oratab        : /var/opt/oracle/oratab
#      [2026-06-15 09:10:01] INFO  - Candidates    : ROEMC02A1 ROEMC02A2
#      [2026-06-15 09:10:01] INFO  - PMON match    : ROEMC02A1
#      [2026-06-15 09:10:01] INFO  - ORACLE_HOME   : /u01/app/oracle/product/19.29.0/dbhome_1
#      [2026-06-15 09:10:02] INFO  - DB Role       : PRIMARY
#      [2026-06-15 09:10:02] INFO  - CDB           : YES
#      [2026-06-15 09:10:02] INFO  - PDB (SYSMAN)  : ROEM02
#      [2026-06-15 09:10:04] INFO  - Failed jobs   : 3 in the last 24 hours
#      [2026-06-15 09:10:06] INFO  - Report        : /u01/.../oem_failed_jobs_20260615_091006.html
#      [2026-06-15 09:10:06] INFO  - Alert log     : ORA-20100 written
#      [2026-06-15 09:10:07] INFO  - Email         : Sent to dba-team@yourcompany.com
#      [2026-06-15 09:10:07] INFO  - Log file      : /u01/.../oem_failed_jobs_20260615_091001.log
#      [2026-06-15 09:10:07] INFO  - Done.
#
# 4. CRON (as oracle user - crontab -e)
#    0 7 * * * /u01/app/oracle/admin/scripts/oem_failed_jobs_report.sh ROEMC02A1 ROEMC02A2 >> /u01/app/oracle/admin/scripts/oem_alerts/cron.log 2>&1
#
# 5. EXIT CODES
#    0 = success (or standby/no-PMON - graceful skip)
#    1 = fatal error
#==============================================================================

##############################################################
# 1. CONFIGURATION - EDIT FOR YOUR SITE
##############################################################

INSTANCE_LIST="inst1 inst2"        # overridden by command-line args if given
if [ $# -ge 1 ]; then
    INSTANCE_LIST="$*"
fi

# Set PDB_NAME_OVERRIDE if you want to skip auto-detection
# and always use a specific PDB name.  Leave blank to auto-detect.
PDB_NAME_OVERRIDE=""

WORKDIR="/u01/app/oracle/admin/scripts/oem_alerts"
TIMESTAMP=`date +%Y%m%d_%H%M%S`
REPORT_FILE="${WORKDIR}/oem_failed_jobs_${TIMESTAMP}.html"
LOG_FILE="${WORKDIR}/oem_failed_jobs_${TIMESTAMP}.log"
TMP_MAIL="${WORKDIR}/oem_mail_${TIMESTAMP}.eml"
TMP_SQL="${WORKDIR}/oem_query_${TIMESTAMP}.sql"   # temp SQL file (auto-deleted)

MAIL_FROM="oem-monitor@yourcompany.com"
MAIL_TO="dba-team@yourcompany.com"
SENDMAIL_BIN="/usr/sbin/sendmail"

mkdir -p "${WORKDIR}" 2>/dev/null

##############################################################
# 2. HELPER FUNCTIONS
##############################################################

log() {
    _line="[`date '+%Y-%m-%d %H:%M:%S'`] $1 - $2"
    echo "${_line}"
    echo "${_line}" >> "${LOG_FILE}"
}

# run_sql FILE
#   Runs a pre-written .sql file via sqlplus as SYSDBA.
#   Returns sqlplus exit code.
run_sql() {
    sqlplus -s /nolog @"$1"
    return $?
}

# query_val FILE
#   Runs FILE via sqlplus, returns the last non-blank trimmed output line.
query_val() {
    sqlplus -s /nolog @"$1" 2>/dev/null | \
        grep -v '^[[:space:]]*$' | tail -1 | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

send_mail() {
    _subj="$1"
    _html="$2"
    _bnd="OEM_RPT_${TIMESTAMP}"
    _att="oem_failed_jobs_${ORACLE_SID}_${TIMESTAMP}.html"

    {
        echo "From: ${MAIL_FROM}"
        for _r in ${MAIL_TO}; do echo "To: ${_r}"; done
        echo "Subject: ${_subj}"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=\"${_bnd}\""
        echo "X-Mailer: oem_failed_jobs_report.sh v4.0"
        echo ""
        echo "This is a multi-part message in MIME format."
        echo ""
        echo "--${_bnd}"
        echo "Content-Type: text/html; charset=\"UTF-8\""
        echo "Content-Transfer-Encoding: 8bit"
        echo ""
        cat "${_html}"
        echo ""
        echo "--${_bnd}"
        echo "Content-Type: text/html; name=\"${_att}\""
        echo "Content-Transfer-Encoding: 8bit"
        echo "Content-Disposition: attachment; filename=\"${_att}\""
        echo ""
        cat "${_html}"
        echo ""
        echo "--${_bnd}--"
    } > "${TMP_MAIL}"

    ${SENDMAIL_BIN} -t < "${TMP_MAIL}"
    _rc=$?
    rm -f "${TMP_MAIL}"
    return ${_rc}
}

cleanup() {
    rm -f "${TMP_SQL}"
}
trap cleanup EXIT

##############################################################
# 3. SANITY CHECK
##############################################################

if [ ! -x "${SENDMAIL_BIN}" ]; then
    log "ERROR" "sendmail      : ${SENDMAIL_BIN} not found or not executable"
    exit 1
fi

##############################################################
# 4. FIND RUNNING INSTANCE VIA PMON + ORATAB
##############################################################

if [ -f /etc/oratab ]; then
    ORATAB=/etc/oratab
elif [ -f /var/opt/oracle/oratab ]; then
    ORATAB=/var/opt/oracle/oratab
else
    log "ERROR" "oratab        : not found in /etc or /var/opt/oracle"
    exit 1
fi

log "INFO " "oratab        : ${ORATAB}"
log "INFO " "Candidates    : ${INSTANCE_LIST}"

FOUND_SID=""
for CAND in ${INSTANCE_LIST}; do
    if ps -ef | grep -v grep | grep "ora_pmon_${CAND}$" >/dev/null 2>&1; then
        FOUND_SID="${CAND}"
        break
    fi
done

if [ -z "${FOUND_SID}" ]; then
    log "INFO " "PMON match    : NONE - no candidate instance running on this node"
    log "INFO " "Done."
    exit 0
fi

ORACLE_SID="${FOUND_SID}"
log "INFO " "PMON match    : ${ORACLE_SID}"

ORACLE_HOME=`awk -F: -v s="${ORACLE_SID}" '$0 !~ /^#/ && $1==s {print $2; exit}' "${ORATAB}"`

if [ -z "${ORACLE_HOME}" ]; then
    log "ERROR" "ORACLE_HOME   : ${ORACLE_SID} not found in ${ORATAB}"
    exit 1
fi

PATH="${ORACLE_HOME}/bin:${PATH}"
export ORACLE_SID ORACLE_HOME PATH

log "INFO " "ORACLE_HOME   : ${ORACLE_HOME}"

##############################################################
# 5. GET DB ROLE  (one value, one sqlplus call)
##############################################################

cat > "${TMP_SQL}" << 'SQLEOF'
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
CONNECT / AS SYSDBA
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT ON PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
SELECT DATABASE_ROLE FROM V$DATABASE;
EXIT;
SQLEOF

DB_ROLE=`query_val "${TMP_SQL}"`
log "INFO " "DB Role       : ${DB_ROLE}"

case "${DB_ROLE}" in
    "PHYSICAL STANDBY")
        log "INFO " "Standby       : PHYSICAL STANDBY - exiting, no report or email."
        log "INFO " "Done."
        exit 0
        ;;
    "PRIMARY")
        ;;
    *)
        log "ERROR" "DB Role       : Unexpected value '${DB_ROLE}' - aborting."
        exit 1
        ;;
esac

##############################################################
# 6. GET CDB FLAG  (one value, one sqlplus call)
##############################################################

cat > "${TMP_SQL}" << 'SQLEOF'
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
CONNECT / AS SYSDBA
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT ON PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
SELECT CDB FROM V$DATABASE;
EXIT;
SQLEOF

CDB_FLAG=`query_val "${TMP_SQL}"`
log "INFO " "CDB           : ${CDB_FLAG}"

##############################################################
# 7. GET PDB NAME CONTAINING SYSMAN  (CDB only)
##############################################################

PDB_NAME=""

if [ "${CDB_FLAG}" = "YES" ]; then

    if [ -n "${PDB_NAME_OVERRIDE}" ]; then
        PDB_NAME="${PDB_NAME_OVERRIDE}"
    else
        cat > "${TMP_SQL}" << 'SQLEOF'
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
CONNECT / AS SYSDBA
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT ON PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
SELECT c.name
FROM   v$containers c
WHERE  c.con_id = (
           SELECT con_id
           FROM   cdb_users
           WHERE  username = 'SYSMAN'
             AND  con_id  != 1
             AND  ROWNUM   = 1
       );
EXIT;
SQLEOF
        PDB_NAME=`query_val "${TMP_SQL}"`
    fi

    log "INFO " "PDB (SYSMAN)  : ${PDB_NAME}"
else
    log "INFO " "PDB (SYSMAN)  : non-CDB, using root container"
fi

##############################################################
# 8. COUNT FAILED JOBS
#    Write the full SQL to a temp file so no shell quoting
#    can corrupt it.  ALTER SESSION SET CONTAINER is included
#    only when PDB_NAME is non-empty.
##############################################################

# Build the SQL file
if [ -n "${PDB_NAME}" ]; then
    cat > "${TMP_SQL}" << SQLEOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = ${PDB_NAME};
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT ON PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
SELECT COUNT(*)
FROM   SYSMAN.MGMT\$JOBS j,
       SYSMAN.MGMT\$JOB_EXECUTION_HISTORY h
WHERE  j.job_id     = h.job_id
AND    h.status     = 'Failed'
AND    h.start_time >= SYSDATE - 1;
EXIT;
SQLEOF
else
    cat > "${TMP_SQL}" << SQLEOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
CONNECT / AS SYSDBA
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT ON PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
SELECT COUNT(*)
FROM   SYSMAN.MGMT\$JOBS j,
       SYSMAN.MGMT\$JOB_EXECUTION_HISTORY h
WHERE  j.job_id     = h.job_id
AND    h.status     = 'Failed'
AND    h.start_time >= SYSDATE - 1;
EXIT;
SQLEOF
fi

FAILED_COUNT=`query_val "${TMP_SQL}"`

case "${FAILED_COUNT}" in
    ''|*[!0-9]*)
        log "ERROR" "Failed jobs   : Count query failed (got '${FAILED_COUNT}'). Check ${LOG_FILE}."
        exit 1
        ;;
    *)
        log "INFO " "Failed jobs   : ${FAILED_COUNT} in the last 24 hours"
        ;;
esac

##############################################################
# 9. GENERATE HTML REPORT
#    One sqlplus session: connect, switch container, spool.
##############################################################

CSS='body{font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#333}h1{color:#cc0000;font-size:18px}p.meta{font-size:12px;color:#777;margin-bottom:16px}table{border-collapse:collapse;width:100%;margin-top:10px}th{background:#cc0000;color:#fff;padding:7px 9px;text-align:left;border:1px solid #900}td{border:1px solid #ccc;padding:6px 9px;vertical-align:top}tr:nth-child(even) td{background:#f7f7f7}'

CONTAINER_LABEL="${PDB_NAME:-CDB\$ROOT}"

if [ -n "${PDB_NAME}" ]; then
    cat > "${TMP_SQL}" << SQLEOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = ${PDB_NAME};
SET ECHO OFF FEEDBACK OFF VERIFY OFF TERMOUT OFF TRIMSPOOL ON TRIMOUT ON WRAP OFF
SET PAGESIZE 50000 LINESIZE 32767 LONG 4000 LONGCHUNKSIZE 4000
SET MARKUP HTML ON HEAD '<title>OEM Job Failure Report - ${ORACLE_SID} - ${TIMESTAMP}</title><style type="text/css">${CSS}</style>' BODY '' TABLE 'border="1" cellpadding="4" cellspacing="0"' ENTMAP ON SPOOL ON
SPOOL ${REPORT_FILE}
PROMPT <h1>OEM Custom Job Failure Report</h1>
PROMPT <p class="meta">Instance: <b>${ORACLE_SID}</b> &nbsp;|&nbsp; Container: <b>${PDB_NAME}</b> &nbsp;|&nbsp; Generated: <b>${TIMESTAMP}</b> &nbsp;|&nbsp; Window: last 24 hours</p>
SELECT
    j.job_name                                         AS "Job Name",
    j.job_owner                                        AS "Owner",
    j.job_type                                         AS "Job Type",
    h.status                                           AS "Status",
    TO_CHAR(h.scheduled_time,'YYYY-MM-DD HH24:MI:SS') AS "Scheduled",
    TO_CHAR(h.start_time,    'YYYY-MM-DD HH24:MI:SS') AS "Start (UTC)",
    TO_CHAR(h.end_time,      'YYYY-MM-DD HH24:MI:SS') AS "End (UTC)",
    h.target_name                                      AS "Target",
    (SELECT SUBSTR(s.output,1,4000)
       FROM SYSMAN.MGMT\$JOB_STEP_HISTORY s
      WHERE s.job_id       = h.job_id
        AND s.execution_id = h.execution_id
        AND s.status       = 'Failed'
        AND ROWNUM         = 1)                        AS "Step Error"
FROM   SYSMAN.MGMT\$JOBS j,
       SYSMAN.MGMT\$JOB_EXECUTION_HISTORY h
WHERE  j.job_id     = h.job_id
AND    h.status     = 'Failed'
AND    h.start_time >= SYSDATE - 1
ORDER BY h.start_time DESC;
SPOOL OFF
SET MARKUP HTML OFF
EXIT;
SQLEOF
else
    cat > "${TMP_SQL}" << SQLEOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
CONNECT / AS SYSDBA
SET ECHO OFF FEEDBACK OFF VERIFY OFF TERMOUT OFF TRIMSPOOL ON TRIMOUT ON WRAP OFF
SET PAGESIZE 50000 LINESIZE 32767 LONG 4000 LONGCHUNKSIZE 4000
SET MARKUP HTML ON HEAD '<title>OEM Job Failure Report - ${ORACLE_SID} - ${TIMESTAMP}</title><style type="text/css">${CSS}</style>' BODY '' TABLE 'border="1" cellpadding="4" cellspacing="0"' ENTMAP ON SPOOL ON
SPOOL ${REPORT_FILE}
PROMPT <h1>OEM Custom Job Failure Report</h1>
PROMPT <p class="meta">Instance: <b>${ORACLE_SID}</b> &nbsp;|&nbsp; Container: <b>non-CDB</b> &nbsp;|&nbsp; Generated: <b>${TIMESTAMP}</b> &nbsp;|&nbsp; Window: last 24 hours</p>
SELECT
    j.job_name                                         AS "Job Name",
    j.job_owner                                        AS "Owner",
    j.job_type                                         AS "Job Type",
    h.status                                           AS "Status",
    TO_CHAR(h.scheduled_time,'YYYY-MM-DD HH24:MI:SS') AS "Scheduled",
    TO_CHAR(h.start_time,    'YYYY-MM-DD HH24:MI:SS') AS "Start (UTC)",
    TO_CHAR(h.end_time,      'YYYY-MM-DD HH24:MI:SS') AS "End (UTC)",
    h.target_name                                      AS "Target",
    (SELECT SUBSTR(s.output,1,4000)
       FROM SYSMAN.MGMT\$JOB_STEP_HISTORY s
      WHERE s.job_id       = h.job_id
        AND s.execution_id = h.execution_id
        AND s.status       = 'Failed'
        AND ROWNUM         = 1)                        AS "Step Error"
FROM   SYSMAN.MGMT\$JOBS j,
       SYSMAN.MGMT\$JOB_EXECUTION_HISTORY h
WHERE  j.job_id     = h.job_id
AND    h.status     = 'Failed'
AND    h.start_time >= SYSDATE - 1
ORDER BY h.start_time DESC;
SPOOL OFF
SET MARKUP HTML OFF
EXIT;
SQLEOF
fi

run_sql "${TMP_SQL}" >> "${LOG_FILE}" 2>&1
SQL_RC=$?

if [ "${SQL_RC}" -ne 0 ] || [ ! -s "${REPORT_FILE}" ]; then
    log "ERROR" "Report        : sqlplus RC=${SQL_RC} or empty file. See ${LOG_FILE}"
    exit 1
fi

log "INFO " "Report        : ${REPORT_FILE}"

##############################################################
# 10. WRITE ORA-20100 TO ALERT LOG  (failures only)
#     Always connect at ROOT - KSDWRT is a SYS package and
#     writes to the instance alert log regardless of container.
##############################################################

if [ "${FAILED_COUNT}" -gt 0 ]; then

    cat > "${TMP_SQL}" << SQLEOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
CONNECT / AS SYSDBA
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT OFF
BEGIN
    SYS.DBMS_SYSTEM.KSDWRT(
        SYS.DBMS_SYSTEM.ALERT_FILE,
        'ORA-20100: OEM_JOB_MONITOR (${ORACLE_SID}) - ${FAILED_COUNT} OEM job(s) FAILED in last 24h. Report: ${REPORT_FILE}'
    );
END;
/
EXIT;
SQLEOF

    run_sql "${TMP_SQL}" >> "${LOG_FILE}" 2>&1
    if [ $? -eq 0 ]; then
        log "INFO " "Alert log     : ORA-20100 written"
    else
        log "WARN " "Alert log     : KSDWRT failed - check EXECUTE on SYS.DBMS_SYSTEM"
    fi

else
    log "INFO " "Alert log     : skipped (0 failures)"
fi

##############################################################
# 11. SEND EMAIL
##############################################################

if [ "${FAILED_COUNT}" -gt 0 ]; then
    SUBJECT="[ALERT] ${FAILED_COUNT} OEM Job Failure(s) on ${ORACLE_SID} - `date +%Y-%m-%d`"
else
    SUBJECT="[OK] OEM Job Report - No Failures on ${ORACLE_SID} - `date +%Y-%m-%d`"
fi

send_mail "${SUBJECT}" "${REPORT_FILE}"

if [ $? -eq 0 ]; then
    log "INFO " "Email         : Sent to ${MAIL_TO}"
else
    log "ERROR" "Email         : sendmail failed - check relay config"
fi

##############################################################
# 12. DONE
##############################################################

log "INFO " "Log file      : ${LOG_FILE}"
log "INFO " "Done."
exit 0
