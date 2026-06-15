#!/bin/sh
#==============================================================================
# Script  : oem_failed_jobs_report.sh
# Version : 3.1  (fix: role parsing, ORA-00942 on SYSMAN views)
#
# Purpose :
#   On a Data Guard pair or RAC node, detect which Oracle instance is running
#   on THIS host (PMON check + oratab lookup), connect as SYSDBA (OS auth),
#   verify the database is PRIMARY (exit silently if PHYSICAL STANDBY),
#   auto-detect whether the OEM repository lives in a PDB (CDB-aware), then:
#     1. Query SYSMAN.MGMT$JOBS / MGMT$JOB_EXECUTION_HISTORY for custom jobs
#        that FAILED in the last 24 hours.
#     2. Pull per-step error text from SYSMAN.MGMT$JOB_STEP_HISTORY.
#     3. Produce an HTML report via SQL*Plus SET MARKUP HTML ON.
#     4. Write a custom ORA-20100 message to the DB alert log (failures only).
#     5. Email the HTML report -- inline in the body AND as an attachment --
#        using raw /usr/sbin/sendmail with a hand-built MIME envelope.
#
# Compatibility:
#   POSIX /bin/sh.  Tested on Oracle Linux 7/8 (bash) and Solaris 11 (ksh/sh).
#   No GNU-specific flags used anywhere.
#
#==============================================================================
# H O W   T O   U S E   T H I S   S C R I P T
#==============================================================================
#
# 1. PREREQUISITES
#    ------------
#    a) Run as the "oracle" OS user (or any OS account in the dba/oinstall
#       group) so that "CONNECT / AS SYSDBA" works via OS authentication.
#       No Oracle password, no wallet, no password file needed.
#
#    b) /etc/oratab (Linux) or /var/opt/oracle/oratab (Solaris) must have
#       an entry for the instance(s) you specify, e.g.:
#         EMREP:/u01/app/oracle/product/19.0.0/dbhome_1:Y
#
#    c) /usr/sbin/sendmail must be installed and able to relay mail.
#       Quick test:
#         echo "Subject: test" | /usr/sbin/sendmail -t you@company.com
#
#    d) The WORKDIR path must be writable by the oracle OS user.
#       The script creates it automatically if it does not exist.
#
# 2. INSTALLATION
#    ------------
#    a) Copy this script to a permanent location, e.g.:
#         /u01/app/oracle/admin/scripts/oem_failed_jobs_report.sh
#
#    b) Make it executable:
#         chmod 750 /u01/app/oracle/admin/scripts/oem_failed_jobs_report.sh
#
#    c) Edit the CONFIGURATION block (Section 1) in this script:
#         INSTANCE_LIST      - space-separated candidate SIDs for this host
#         MAIL_FROM          - sender address shown in the email
#         MAIL_TO            - recipient(s), space-separated for multiple
#         WORKDIR            - where HTML reports and log files are written
#         PDB_NAME_OVERRIDE  - leave blank to auto-detect, or set explicitly
#
# 3. RUNNING MANUALLY
#    -----------------
#    # Use the default instance list baked into the script:
#    $ /u01/app/oracle/admin/scripts/oem_failed_jobs_report.sh
#
#    # Override the instance list on the command line:
#    $ /u01/app/oracle/admin/scripts/oem_failed_jobs_report.sh EMREP EMREP_S
#
#    # Example terminal output (also written to the log file):
#    #   [2026-06-15 09:05:36] INFO  - oratab        : /var/opt/oracle/oratab
#    #   [2026-06-15 09:05:36] INFO  - Candidates    : ROEMC02A1
#    #   [2026-06-15 09:05:36] INFO  - PMON match    : ROEMC02A1  (ora_pmon_ROEMC02A1 found)
#    #   [2026-06-15 09:05:36] INFO  - ORACLE_HOME   : /u01/app/oracle/product/19.29.0/dbhome_1
#    #   [2026-06-15 09:05:37] INFO  - DB Role       : PRIMARY
#    #   [2026-06-15 09:05:37] INFO  - CDB           : YES
#    #   [2026-06-15 09:05:37] INFO  - PDB (SYSMAN)  : ROEM02
#    #   [2026-06-15 09:05:38] INFO  - SYSMAN check  : Views confirmed accessible
#    #   [2026-06-15 09:05:40] INFO  - Failed jobs   : 3 in the last 24 hours
#    #   [2026-06-15 09:05:42] INFO  - Report        : /u01/.../oem_failed_jobs_20260615_090542.html
#    #   [2026-06-15 09:05:42] INFO  - Alert log     : ORA-20100 written
#    #   [2026-06-15 09:05:43] INFO  - Email         : Sent to dba-team@yourcompany.com
#    #   [2026-06-15 09:05:43] INFO  - Log file      : /u01/.../oem_failed_jobs_20260615_090536.log
#    #   [2026-06-15 09:05:43] INFO  - Done.
#
# 4. SCHEDULING VIA CRON
#    --------------------
#    Add a crontab entry as the oracle user (crontab -e):
#
#    # Run every day at 07:00 AM - pass explicit instance names:
#    0 7 * * * /u01/app/oracle/admin/scripts/oem_failed_jobs_report.sh EMREP EMREP_S >> /u01/app/oracle/admin/scripts/oem_alerts/cron.log 2>&1
#
#    TIP: In cron ORACLE_HOME and ORACLE_SID are NOT preset.
#    This script sets them itself from oratab - no wrapper needed.
#
# 5. EXIT CODES
#    ----------
#    0 = Success (report sent, standby detected and skipped gracefully,
#                 or no matching PMON found on this node)
#    1 = Fatal error (oratab missing, SYSMAN views inaccessible, etc.)
#
# 6. OUTPUT FILES  (all in WORKDIR)
#    --------------------------------
#    oem_failed_jobs_YYYYMMDD_HHMMSS.html  - HTML report kept for audit trail
#    oem_failed_jobs_YYYYMMDD_HHMMSS.log   - Full execution log
#
#==============================================================================

############################################################
# 1. CONFIGURATION - EDIT FOR YOUR SITE
############################################################

# Space-separated candidate SIDs for THIS host.  Overridable on command line.
INSTANCE_LIST="inst1 inst2"

if [ $# -ge 1 ]; then
    INSTANCE_LIST="$*"
fi

# Optional: hard-code the PDB that contains the SYSMAN schema.
# Leave blank ("") to auto-detect (recommended).
PDB_NAME_OVERRIDE=""

WORKDIR="/u01/app/oracle/admin/scripts/oem_alerts"
TIMESTAMP=`date +%Y%m%d_%H%M%S`
REPORT_FILE="${WORKDIR}/oem_failed_jobs_${TIMESTAMP}.html"
LOG_FILE="${WORKDIR}/oem_failed_jobs_${TIMESTAMP}.log"
TMP_MAIL="${WORKDIR}/oem_mail_${TIMESTAMP}.eml"

MAIL_FROM="oem-monitor@yourcompany.com"
MAIL_TO="dba-team@yourcompany.com"   # space-separate for multiple recipients
SENDMAIL_BIN="/usr/sbin/sendmail"

mkdir -p "${WORKDIR}" 2>/dev/null

############################################################
# 2. HELPER FUNCTIONS
############################################################

# log  "LEVEL"  "message"
#   Prints a timestamped line to BOTH stdout (terminal) and the log file.
log() {
    _lvl="$1"
    _msg="$2"
    _line="[`date '+%Y-%m-%d %H:%M:%S'`] ${_lvl} - ${_msg}"
    echo "${_line}"
    echo "${_line}" >> "${LOG_FILE}"
}

# send_mail  "subject"  "/path/to/report.html"
#   Builds a multipart/mixed MIME envelope:
#     Part 1 - text/html inline   (renders in the mail client body)
#     Part 2 - text/html attachment (same file, downloadable)
#   Delivered via /usr/sbin/sendmail -t (POSIX / Solaris compatible).
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
        echo "X-Mailer: oem_failed_jobs_report.sh v3.1"
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

############################################################
# 3. SANITY CHECKS
############################################################

if [ ! -x "${SENDMAIL_BIN}" ]; then
    log "ERROR" "sendmail      : ${SENDMAIL_BIN} not found or not executable"
    exit 1
fi

############################################################
# 4. FIND RUNNING INSTANCE VIA PMON + ORATAB
############################################################

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
for CAND_SID in ${INSTANCE_LIST}; do
    if ps -ef | grep -v grep | grep "ora_pmon_${CAND_SID}$" >/dev/null 2>&1; then
        FOUND_SID="${CAND_SID}"
        break
    fi
done

if [ -z "${FOUND_SID}" ]; then
    log "INFO " "PMON match    : NONE - no candidate instance running on this node"
    log "INFO " "Done."
    exit 0
fi

ORACLE_SID="${FOUND_SID}"
log "INFO " "PMON match    : ${ORACLE_SID}  (ora_pmon_${ORACLE_SID} found)"

ORACLE_HOME=`awk -F: -v sid="${ORACLE_SID}" \
    '$0 !~ /^#/ && $1==sid {print $2; exit}' "${ORATAB}"`

if [ -z "${ORACLE_HOME}" ]; then
    log "ERROR" "ORACLE_HOME   : SID ${ORACLE_SID} not found in ${ORATAB}"
    exit 1
fi

PATH=${ORACLE_HOME}/bin:${PATH}
export ORACLE_SID ORACLE_HOME PATH

log "INFO " "ORACLE_HOME   : ${ORACLE_HOME}"

############################################################
# 5. CHECK DB ROLE, CDB FLAG, AND PDB HOSTING SYSMAN
#
# FIX v3.1: Run each SELECT in its own sqlplus call so that
# the output of one query cannot pollute the parsing of
# another.  The previous single-call approach caused the
# raw CDB/PDB lines to bleed into the ROLE= grep when
# sqlplus emitted them without the expected prefix.
############################################################

# --- 5a. Database role ---
DB_ROLE=`sqlplus -s /nolog <<EOSQL | grep -v '^$' | tail -1 | tr -d '[:space:]'
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
CONNECT / AS SYSDBA
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT ON PAGES 0 LINESIZE 200 TRIMSPOOL ON
SELECT DATABASE_ROLE FROM V\$DATABASE;
EXIT;
EOSQL`

log "INFO " "DB Role       : ${DB_ROLE}"

case "${DB_ROLE}" in
    PHYSICALSTANDBY*)
        log "INFO " "Standby       : PHYSICAL STANDBY detected - exiting without report or email."
        log "INFO " "Done."
        exit 0
        ;;
    PRIMARY*)
        # continue
        ;;
    *)
        log "ERROR" "DB Role       : Unable to determine role. Got '${DB_ROLE}'. Aborting."
        exit 1
        ;;
esac

# --- 5b. CDB flag ---
CDB_FLAG=`sqlplus -s /nolog <<EOSQL | grep -v '^$' | tail -1 | tr -d '[:space:]'
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
CONNECT / AS SYSDBA
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT ON PAGES 0 LINESIZE 200 TRIMSPOOL ON
SELECT CDB FROM V\$DATABASE;
EXIT;
EOSQL`

log "INFO " "CDB           : ${CDB_FLAG}"

# --- 5c. PDB that owns SYSMAN (CDB only) ---
PDB_DETECTED=""
if [ "${CDB_FLAG}" = "YES" ]; then
    PDB_DETECTED=`sqlplus -s /nolog <<EOSQL | grep -v '^$' | tail -1 | tr -d '[:space:]'
WHENEVER SQLERROR CONTINUE
WHENEVER OSERROR  CONTINUE
CONNECT / AS SYSDBA
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT ON PAGES 0 LINESIZE 200 TRIMSPOOL ON
SELECT NVL(MAX(c.name),'NONE')
FROM   CDB_USERS u, V\$CONTAINERS c
WHERE  u.username = 'SYSMAN'
AND    u.con_id   = c.con_id
AND    c.name    != 'CDB\$ROOT';
EXIT;
EOSQL`
fi

# --- 5d. Resolve which container to use ---
if [ -n "${PDB_NAME_OVERRIDE}" ]; then
    PDB_NAME="${PDB_NAME_OVERRIDE}"
elif [ -n "${PDB_DETECTED}" ] && [ "${PDB_DETECTED}" != "NONE" ]; then
    PDB_NAME="${PDB_DETECTED}"
else
    PDB_NAME=""
fi

if [ -n "${PDB_NAME}" ]; then
    CONTAINER_SQL="ALTER SESSION SET CONTAINER = ${PDB_NAME};"
    log "INFO " "PDB (SYSMAN)  : ${PDB_NAME}"
else
    CONTAINER_SQL=""
    log "INFO " "PDB (SYSMAN)  : non-CDB or CDB\$ROOT"
fi

############################################################
# 6. VERIFY SYSMAN VIEWS ARE ACCESSIBLE IN THE RESOLVED CONTAINER
#
# FIX v3.1: Before running the real queries, confirm that the
# three SYSMAN views we rely on actually exist and are visible
# in this container.  This gives a clean error instead of
# ORA-00942 buried mid-report.
############################################################

VIEW_CHECK=`sqlplus -s /nolog <<EOSQL | grep -v '^$' | tail -1 | tr -d '[:space:]'
WHENEVER SQLERROR CONTINUE
WHENEVER OSERROR  CONTINUE
CONNECT / AS SYSDBA
${CONTAINER_SQL}
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT ON PAGES 0 LINESIZE 200 TRIMSPOOL ON
SELECT COUNT(*)
FROM   ALL_VIEWS
WHERE  owner      = 'SYSMAN'
AND    view_name IN ('MGMT\$JOBS','MGMT\$JOB_EXECUTION_HISTORY','MGMT\$JOB_STEP_HISTORY');
EXIT;
EOSQL`

log "INFO " "SYSMAN views  : ${VIEW_CHECK}/3 found in container '${PDB_NAME:-CDB\$ROOT}'"

if [ "${VIEW_CHECK}" != "3" ]; then
    log "ERROR" "SYSMAN views  : Expected 3 views, found ${VIEW_CHECK}."
    log "ERROR" "              : Check that PDB '${PDB_NAME:-CDB\$ROOT}' is the OEM repository"
    log "ERROR" "              : container, or set PDB_NAME_OVERRIDE in the script config."
    exit 1
fi

log "INFO " "SYSMAN check  : Views confirmed accessible"

############################################################
# 7. COUNT FAILED CUSTOM OEM JOBS IN THE LAST 24 HOURS
#
# View reference (OEM 12c/13c Cloud Control Repository Views):
#   SYSMAN.MGMT$JOBS                  - job definition
#   SYSMAN.MGMT$JOB_EXECUTION_HISTORY - per-execution status (STATUS VARCHAR2)
#     STATUS = 'Failed' means one or more steps of the execution failed.
#   SYSMAN.MGMT$JOB_STEP_HISTORY      - per-step OUTPUT / error text
############################################################

FAILED_COUNT=`sqlplus -s /nolog <<EOSQL | grep -v '^$' | tail -1 | tr -d '[:space:]'
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
CONNECT / AS SYSDBA
${CONTAINER_SQL}
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT ON PAGES 0 LINESIZE 200 TRIMSPOOL ON
SELECT COUNT(*)
FROM   SYSMAN.MGMT\$JOBS j,
       SYSMAN.MGMT\$JOB_EXECUTION_HISTORY h
WHERE  j.job_id     = h.job_id
AND    h.status     = 'Failed'
AND    h.start_time >= SYSDATE - 1;
EXIT;
EOSQL`

case "${FAILED_COUNT}" in
    ''|*[!0-9]*)
        # sqlplus returned something non-numeric -- treat as query failure,
        # abort rather than send a misleadingly empty "OK" report.
        log "ERROR" "Failed jobs   : SQL count query failed. Got '${FAILED_COUNT}'. Aborting to avoid false OK report."
        exit 1
        ;;
    *)
        log "INFO " "Failed jobs   : ${FAILED_COUNT} in the last 24 hours"
        ;;
esac

############################################################
# 8. GENERATE THE HTML REPORT (SQL*Plus SET MARKUP HTML ON)
############################################################

sqlplus -s /nolog >> "${LOG_FILE}" 2>&1 <<EOSQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
CONNECT / AS SYSDBA
${CONTAINER_SQL}

SET ECHO          OFF
SET FEEDBACK      OFF
SET VERIFY        OFF
SET TERMOUT       OFF
SET TRIMSPOOL     ON
SET TRIMOUT       ON
SET WRAP          OFF
SET PAGESIZE      50000
SET LINESIZE      32767
SET LONG          4000
SET LONGCHUNKSIZE 4000

SET MARKUP HTML ON HEAD '<title>OEM Custom Job Failure Report - ${ORACLE_SID} - ${TIMESTAMP}</title><style type="text/css">body{font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#333}h1{color:#cc0000;font-size:18px}p.meta{font-size:12px;color:#777;margin-bottom:16px}table{border-collapse:collapse;width:100%;margin-top:10px}th{background:#cc0000;color:#fff;padding:7px 9px;text-align:left;border:1px solid #900}td{border:1px solid #ccc;padding:6px 9px;vertical-align:top}tr:nth-child(even) td{background:#f7f7f7}td.fail{color:#cc0000;font-weight:bold}</style>' BODY '' TABLE 'border="1" cellpadding="4" cellspacing="0"' ENTMAP ON SPOOL ON

SPOOL ${REPORT_FILE}

PROMPT <h1>OEM Custom Job Failure Report</h1>
PROMPT <p class="meta">Instance: <strong>${ORACLE_SID}</strong> &nbsp;|&nbsp; Container: <strong>${PDB_NAME:-CDB\$ROOT}</strong> &nbsp;|&nbsp; Generated: <strong>${TIMESTAMP}</strong> &nbsp;|&nbsp; Window: last 24 hours</p>

SELECT
    j.job_name                                          AS "Job Name",
    j.job_owner                                         AS "Owner",
    j.job_type                                          AS "Job Type",
    h.status                                            AS "Status",
    TO_CHAR(h.scheduled_time,'YYYY-MM-DD HH24:MI:SS')  AS "Scheduled Time",
    TO_CHAR(h.start_time,    'YYYY-MM-DD HH24:MI:SS')  AS "Start Time (UTC)",
    TO_CHAR(h.end_time,      'YYYY-MM-DD HH24:MI:SS')  AS "End Time (UTC)",
    h.target_name                                       AS "Target",
    h.execution_id                                      AS "Execution ID",
    (SELECT SUBSTR(s.output, 1, 4000)
       FROM SYSMAN.MGMT\$JOB_STEP_HISTORY s
      WHERE s.job_id       = h.job_id
        AND s.execution_id = h.execution_id
        AND s.status       = 'Failed'
        AND ROWNUM         = 1)                         AS "Step Error Output"
FROM
    SYSMAN.MGMT\$JOBS j,
    SYSMAN.MGMT\$JOB_EXECUTION_HISTORY h
WHERE  j.job_id     = h.job_id
AND    h.status     = 'Failed'
AND    h.start_time >= SYSDATE - 1
ORDER BY h.start_time DESC;

SPOOL OFF
SET MARKUP HTML OFF
EXIT;
EOSQL

SQL_RC=$?

if [ ${SQL_RC} -ne 0 ] || [ ! -s "${REPORT_FILE}" ]; then
    log "ERROR" "Report        : SQL*Plus exited RC=${SQL_RC} or report file is empty. Check ${LOG_FILE}."
    exit 1
fi

log "INFO " "Report        : ${REPORT_FILE}"

############################################################
# 9. WRITE ORA-20100 TO THE ALERT LOG (FAILURES ONLY)
#    Must connect at ROOT (no CONTAINER_SQL) because
#    KSDWRT writes to the instance-level alert log and the
#    package may not be resolvable inside a PDB.
############################################################

if [ "${FAILED_COUNT}" -gt 0 ]; then
    sqlplus -s /nolog >> "${LOG_FILE}" 2>&1 <<EOSQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
CONNECT / AS SYSDBA
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT OFF
BEGIN
    SYS.DBMS_SYSTEM.KSDWRT(
        SYS.DBMS_SYSTEM.ALERT_FILE,
        'ORA-20100: OEM_JOB_MONITOR (${ORACLE_SID}) - ${FAILED_COUNT} custom OEM ' ||
        'job execution(s) reported FAILED in the last 24 hours. ' ||
        'Report: ${REPORT_FILE}  Run: ${TIMESTAMP}'
    );
END;
/
EXIT;
EOSQL

    if [ $? -eq 0 ]; then
        log "INFO " "Alert log     : ORA-20100 written"
    else
        log "WARN " "Alert log     : KSDWRT call failed - check EXECUTE grant on SYS.DBMS_SYSTEM"
    fi
else
    log "INFO " "Alert log     : skipped (no failures found)"
fi

############################################################
# 10. EMAIL THE REPORT (INLINE HTML BODY + HTML ATTACHMENT)
############################################################

if [ "${FAILED_COUNT}" -gt 0 ]; then
    SUBJECT="[ALERT] ${FAILED_COUNT} OEM Custom Job Failure(s) on ${ORACLE_SID} - `date +%Y-%m-%d`"
else
    SUBJECT="[OK] OEM Custom Job Report - No Failures on ${ORACLE_SID} - `date +%Y-%m-%d`"
fi

send_mail "${SUBJECT}" "${REPORT_FILE}"

if [ $? -eq 0 ]; then
    log "INFO " "Email         : Sent to ${MAIL_TO}"
else
    log "ERROR" "Email         : sendmail returned non-zero - check mail relay config"
fi

############################################################
# 11. DONE
############################################################

log "INFO " "Log file      : ${LOG_FILE}"
log "INFO " "Done."

exit 0
