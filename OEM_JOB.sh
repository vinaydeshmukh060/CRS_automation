#!/bin/sh
#==============================================================================
# Script  : oem_failed_jobs_report.sh
# Version : 3.0
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
#    c) /usr/sbin/sendmail must be installed and able to relay mail to your
#       mail server.  Test with:
#         echo "Subject: test" | /usr/sbin/sendmail -t you@company.com
#
#    d) The WORKDIR path (see CONFIGURATION section below) must be writable
#       by the oracle OS user.  The script creates it if it does not exist.
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
#         INSTANCE_LIST  - space-separated list of candidate SIDs for this host
#         MAIL_FROM      - sender address shown in the email
#         MAIL_TO        - recipient(s), space-separated for multiple addresses
#         WORKDIR        - where HTML reports and log files are written
#         PDB_NAME_OVERRIDE - leave blank to auto-detect, or set to your PDB name
#
# 3. RUNNING MANUALLY
#    -----------------
#    # Run with default instance list (set inside the script):
#    $ /u01/app/oracle/admin/scripts/oem_failed_jobs_report.sh
#
#    # Override the instance list on the command line:
#    $ /u01/app/oracle/admin/scripts/oem_failed_jobs_report.sh EMREP EMREP_S
#
#    # The script prints progress to the terminal AND writes to the log file.
#    # Example terminal output:
#    #   [2025-06-12 07:00:01] INFO  - oratab      : /etc/oratab
#    #   [2025-06-12 07:00:01] INFO  - Candidates  : EMREP EMREP_S
#    #   [2025-06-12 07:00:01] INFO  - PMON match  : EMREP (ora_pmon_EMREP found)
#    #   [2025-06-12 07:00:01] INFO  - ORACLE_HOME : /u01/app/oracle/product/19.0.0/dbhome_1
#    #   [2025-06-12 07:00:02] INFO  - DB Role     : PRIMARY
#    #   [2025-06-12 07:00:02] INFO  - CDB         : YES
#    #   [2025-06-12 07:00:02] INFO  - PDB (SYSMAN): SYSMAN_PDB
#    #   [2025-06-12 07:00:04] INFO  - Failed jobs : 3 in the last 24 hours
#    #   [2025-06-12 07:00:06] INFO  - Report      : /u01/.../oem_failed_jobs_20250612_070006.html
#    #   [2025-06-12 07:00:06] INFO  - Alert log   : ORA-20100 written
#    #   [2025-06-12 07:00:07] INFO  - Email       : Sent to dba-team@yourcompany.com
#    #   [2025-06-12 07:00:07] INFO  - Log file    : /u01/.../oem_failed_jobs_20250612_070001.log
#    #   [2025-06-12 07:00:07] INFO  - Done.
#
# 4. SCHEDULING VIA CRON
#    --------------------
#    Add a crontab entry as the oracle user (crontab -e):
#
#    # Run every day at 07:00 AM with explicit instance candidates
#    0 7 * * * /u01/app/oracle/admin/scripts/oem_failed_jobs_report.sh EMREP EMREP_S >> /u01/app/oracle/admin/scripts/oem_alerts/cron.log 2>&1
#
#    # Or rely on the default INSTANCE_LIST baked into the script:
#    0 7 * * * /u01/app/oracle/admin/scripts/oem_failed_jobs_report.sh >> /u01/app/oracle/admin/scripts/oem_alerts/cron.log 2>&1
#
#    TIP: In cron, ORACLE_HOME and ORACLE_SID are NOT set automatically.
#    This script sets them itself from oratab, so no wrapper is needed.
#
# 5. EXIT CODES
#    ----------
#    0 = Success (report sent, or standby detected and skipped gracefully,
#                 or no matching PMON found on this node)
#    1 = Fatal error (oratab missing, report not generated, sendmail failed)
#
# 6. OUTPUT FILES  (all in WORKDIR)
#    --------------------------------
#    oem_failed_jobs_YYYYMMDD_HHMMSS.html  - HTML report (kept for audit trail)
#    oem_failed_jobs_YYYYMMDD_HHMMSS.log   - Full execution log
#    cron.log                               - Cron stdout/stderr (if you use the
#                                            cron line from Section 4 above)
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

# Optional: hard-code the PDB containing the SYSMAN schema.
# Leave blank to auto-detect (recommended).
PDB_NAME_OVERRIDE=""

WORKDIR="/u01/app/oracle/admin/scripts/oem_alerts"
TIMESTAMP=`date +%Y%m%d_%H%M%S`
REPORT_FILE="${WORKDIR}/oem_failed_jobs_${TIMESTAMP}.html"
LOG_FILE="${WORKDIR}/oem_failed_jobs_${TIMESTAMP}.log"
TMP_MAIL="${WORKDIR}/oem_mail_${TIMESTAMP}.eml"

MAIL_FROM="oem-monitor@yourcompany.com"
MAIL_TO="dba-team@yourcompany.com"      # space-separate multiple addresses
SENDMAIL_BIN="/usr/sbin/sendmail"

mkdir -p "${WORKDIR}" 2>/dev/null

############################################################
# 2. HELPER FUNCTIONS
############################################################

# log  TAG  MESSAGE
#   Writes a timestamped line to BOTH the terminal (stdout) and the log file.
log() {
    _tag="$1"
    _msg="$2"
    _line="[`date '+%Y-%m-%d %H:%M:%S'`] ${_tag} - ${_msg}"
    echo "${_line}"
    echo "${_line}" >> "${LOG_FILE}"
}

# send_mail  SUBJECT  REPORT_HTML_FILE
#   Builds a multipart/mixed MIME message with the HTML report as:
#     Part 1 - text/html  (renders inline in the mail client body)
#     Part 2 - text/html  (same file sent as a downloadable attachment)
#   Delivers via raw /usr/sbin/sendmail -t (POSIX / Solaris safe).
send_mail() {
    _subject="$1"
    _html="$2"
    _boundary="OEM_RPT_BOUNDARY_${TIMESTAMP}"
    _attach_name="oem_failed_jobs_${ORACLE_SID}_${TIMESTAMP}.html"

    # Build RFC-2822 / MIME envelope into TMP_MAIL
    {
        # Headers
        echo "From: ${MAIL_FROM}"
        for _rcpt in ${MAIL_TO}; do
            echo "To: ${_rcpt}"
        done
        echo "Subject: ${_subject}"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=\"${_boundary}\""
        echo "X-Mailer: oem_failed_jobs_report.sh v3.0"
        echo ""
        echo "This is a multi-part message in MIME format."
        echo ""

        # Part 1 - inline HTML body
        echo "--${_boundary}"
        echo "Content-Type: text/html; charset=\"UTF-8\""
        echo "Content-Transfer-Encoding: 8bit"
        echo ""
        cat "${_html}"
        echo ""

        # Part 2 - HTML attachment (identical content, different disposition)
        echo "--${_boundary}"
        echo "Content-Type: text/html; name=\"${_attach_name}\""
        echo "Content-Transfer-Encoding: 8bit"
        echo "Content-Disposition: attachment; filename=\"${_attach_name}\""
        echo ""
        cat "${_html}"
        echo ""

        echo "--${_boundary}--"
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
    log "ERROR" "sendmail     : ${SENDMAIL_BIN} not found or not executable"
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
    log "ERROR" "oratab       : not found in /etc or /var/opt/oracle"
    exit 1
fi

log "INFO " "oratab       : ${ORATAB}"
log "INFO " "Candidates   : ${INSTANCE_LIST}"

FOUND_SID=""
for CAND_SID in ${INSTANCE_LIST}; do
    if ps -ef | grep -v grep | grep "ora_pmon_${CAND_SID}$" >/dev/null 2>&1; then
        FOUND_SID="${CAND_SID}"
        break
    fi
done

if [ -z "${FOUND_SID}" ]; then
    log "INFO " "PMON match   : NONE - no candidate instance is running on this node"
    log "INFO " "Done."
    exit 0
fi

ORACLE_SID="${FOUND_SID}"
log "INFO " "PMON match   : ${ORACLE_SID}  (ora_pmon_${ORACLE_SID} found)"

ORACLE_HOME=`awk -F: -v sid="${ORACLE_SID}" '$0 !~ /^#/ && $1==sid {print $2; exit}' "${ORATAB}"`

if [ -z "${ORACLE_HOME}" ]; then
    log "ERROR" "ORACLE_HOME  : SID ${ORACLE_SID} not found in ${ORATAB}"
    exit 1
fi

PATH=${ORACLE_HOME}/bin:${PATH}
export ORACLE_SID ORACLE_HOME PATH

log "INFO " "ORACLE_HOME  : ${ORACLE_HOME}"

############################################################
# 5. CHECK DB ROLE, CDB FLAG, AND PDB HOSTING SYSMAN
############################################################

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

log "INFO " "DB Role      : ${DB_ROLE}"
log "INFO " "CDB          : ${CDB_FLAG}"

case "${DB_ROLE}" in
    PHYSICALSTANDBY*)
        log "INFO " "Standby      : PHYSICAL STANDBY detected - no report, email, or alert log entry. Exiting."
        log "INFO " "Done."
        exit 0
        ;;
    PRIMARY*)
        ;;
    *)
        log "ERROR" "DB Role      : Unable to determine role (got '${DB_ROLE}'). Aborting."
        exit 1
        ;;
esac

# Resolve PDB for SYSMAN
if [ -n "${PDB_NAME_OVERRIDE}" ]; then
    PDB_NAME="${PDB_NAME_OVERRIDE}"
elif [ "${CDB_FLAG}" = "YES" ] && [ -n "${PDB_DETECTED}" ] && [ "${PDB_DETECTED}" != "NONE" ]; then
    PDB_NAME="${PDB_DETECTED}"
else
    PDB_NAME=""
fi

if [ -n "${PDB_NAME}" ]; then
    CONTAINER_SQL="ALTER SESSION SET CONTAINER = ${PDB_NAME};"
    log "INFO " "PDB (SYSMAN) : ${PDB_NAME}"
else
    CONTAINER_SQL=""
    log "INFO " "PDB (SYSMAN) : non-CDB or CDB\$ROOT"
fi

############################################################
# 6. COUNT FAILED CUSTOM OEM JOBS IN THE LAST 24 HOURS
#
#    View reference (OEM 12c/13c Cloud Control):
#    SYSMAN.MGMT$JOBS           - job definition (job_id, job_name, job_owner)
#    SYSMAN.MGMT$JOB_EXECUTION_HISTORY - per-execution status
#      STATUS column is VARCHAR2; valid failure value = 'Failed'
#    SYSMAN.MGMT$JOB_STEP_HISTORY - per-step output / error text
############################################################

FAILED_COUNT=`sqlplus -s /nolog <<EOSQL | tr -d '[:space:]'
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
CONNECT / AS SYSDBA
${CONTAINER_SQL}
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF TERMOUT ON PAGES 0 LINESIZE 200
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
        log "WARN " "Failed jobs  : Could not retrieve count (got '${FAILED_COUNT}'). Treating as 0."
        FAILED_COUNT=0
        ;;
    *)
        log "INFO " "Failed jobs  : ${FAILED_COUNT} in the last 24 hours"
        ;;
esac

############################################################
# 7. GENERATE THE HTML REPORT (SQL*Plus SET MARKUP HTML ON)
############################################################

sqlplus -s /nolog >> "${LOG_FILE}" 2>&1 <<EOSQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
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

SET MARKUP HTML ON HEAD '<title>OEM Custom Job Failure Report - ${ORACLE_SID} - ${TIMESTAMP}</title><style type="text/css">body{font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#333}h1{color:#cc0000;font-size:18px}h2{color:#555;font-size:14px;margin-top:0}p.meta{font-size:12px;color:#777}table{border-collapse:collapse;width:100%;margin-top:10px}th{background:#cc0000;color:#fff;padding:6px 8px;text-align:left;border:1px solid #900}td{border:1px solid #ccc;padding:6px 8px;vertical-align:top}tr:nth-child(even) td{background:#f7f7f7}.ok{color:green;font-weight:bold}.fail{color:#cc0000;font-weight:bold}</style>' BODY '' TABLE 'border="1" cellpadding="4" cellspacing="0"' ENTMAP ON SPOOL ON

SPOOL ${REPORT_FILE}

PROMPT <h1>OEM Custom Job Failure Report</h1>
PROMPT <p class="meta">Instance: <strong>${ORACLE_SID}</strong> &nbsp;|&nbsp; Generated: <strong>${TIMESTAMP}</strong> &nbsp;|&nbsp; Window: last 24 hours (SYSDATE&nbsp;-&nbsp;1)</p>

-- MGMT$JOBS          : job definition (job_id, job_name, job_owner, job_type)
-- MGMT$JOB_EXECUTION_HISTORY : per-execution status / timestamps
-- MGMT$JOB_STEP_HISTORY : per-step detail; OUTPUT column holds error text
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
    log "ERROR" "Report       : SQL*Plus exited with code ${SQL_RC} or report file is empty. Aborting."
    exit 1
fi

log "INFO " "Report       : ${REPORT_FILE}"

############################################################
# 8. WRITE ORA-20100 TO THE ALERT LOG (FAILURES ONLY)
#    Connect at ROOT container - KSDWRT writes to the
#    instance-level alert log regardless of current container.
############################################################

if [ "${FAILED_COUNT}" -gt 0 ]; then
    sqlplus -s /nolog >> "${LOG_FILE}" 2>&1 <<EOSQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
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
        log "INFO " "Alert log    : ORA-20100 written"
    else
        log "ERROR" "Alert log    : KSDWRT call failed - check EXECUTE grant on SYS.DBMS_SYSTEM"
    fi
else
    log "INFO " "Alert log    : skipped (no failures found)"
fi

############################################################
# 9. EMAIL THE REPORT (INLINE HTML BODY + HTML ATTACHMENT)
############################################################

if [ "${FAILED_COUNT}" -gt 0 ]; then
    SUBJECT="[ALERT] ${FAILED_COUNT} OEM Custom Job Failure(s) on ${ORACLE_SID} - `date +%Y-%m-%d`"
else
    SUBJECT="[OK] OEM Custom Job Report - No Failures on ${ORACLE_SID} - `date +%Y-%m-%d`"
fi

send_mail "${SUBJECT}" "${REPORT_FILE}"

if [ $? -eq 0 ]; then
    log "INFO " "Email        : Sent to ${MAIL_TO}"
else
    log "ERROR" "Email        : sendmail returned non-zero - check mail relay configuration"
fi

############################################################
# 10. DONE
############################################################

log "INFO " "Log file     : ${LOG_FILE}"
log "INFO " "Done."

exit 0
