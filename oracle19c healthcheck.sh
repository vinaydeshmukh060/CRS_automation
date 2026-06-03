#!/bin/sh
# =============================================================================
# Script  : oracle19c_healthcheck.sh
# Purpose : Detailed Oracle 19c Database Health Check
# Compat  : Solaris (sh/ksh) and Linux (bash/sh)
# Author  : DBA Team
# Usage   : ./oracle19c_healthcheck.sh [ORACLE_SID]
# =============================================================================

# ---------------------------------------------------------------------------
# PORTABLE SHELL SETTINGS
# ---------------------------------------------------------------------------
# Avoid bashisms; use POSIX sh throughout for Solaris compatibility
PATH=/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin
export PATH

# ---------------------------------------------------------------------------
# CONFIGURATION — edit these to match your environment
# ---------------------------------------------------------------------------
ORACLE_BASE=${ORACLE_BASE:-/u01/app/oracle}
ORACLE_HOME=${ORACLE_HOME:-/u01/app/oracle/product/19.0.0/dbhome_1}
ORACLE_SID=${1:-${ORACLE_SID:-ORCL}}
DBA_USER="/ as sysdba"                    # Change if using a named DBA account
LOG_DIR=${LOG_DIR:-/var/log/oracle/healthcheck}
ALERT_EMAIL=${ALERT_EMAIL:-""}            # Set to DBA email to receive alerts

# ---------------------------------------------------------------------------
# DERIVED VARIABLES
# ---------------------------------------------------------------------------
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${LOG_DIR}/hc_${ORACLE_SID}_${TIMESTAMP}.log"
SUMMARY_FILE="${LOG_DIR}/hc_${ORACLE_SID}_${TIMESTAMP}_summary.log"
SQLPLUS="${ORACLE_HOME}/bin/sqlplus"

export ORACLE_HOME ORACLE_SID PATH

# ---------------------------------------------------------------------------
# COLOUR / FORMATTING (terminal only — stripped in log)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

PASS="${C_GREEN}[PASS]${C_RESET}"
FAIL="${C_RED}[FAIL]${C_RESET}"
WARN="${C_YELLOW}[WARN]${C_RESET}"
INFO="${C_CYAN}[INFO]${C_RESET}"

ISSUES=0
WARNINGS=0

# ---------------------------------------------------------------------------
# HELPER FUNCTIONS
# ---------------------------------------------------------------------------

log() {
    # Write to both stdout and log file (plain text in log)
    printf "%s\n" "$*" | tee -a "${LOG_FILE}"
}

log_raw() {
    # Write plain text to log only (no colour codes)
    printf "%s\n" "$*" >> "${LOG_FILE}"
}

print_header() {
    TITLE="$1"
    LINE="============================================================"
    printf "\n${C_BOLD}${C_CYAN}%s${C_RESET}\n" "${LINE}" | tee -a "${LOG_FILE}"
    printf "${C_BOLD}${C_CYAN}  %-56s${C_RESET}\n" "${TITLE}" | tee -a "${LOG_FILE}"
    printf "${C_BOLD}${C_CYAN}%s${C_RESET}\n" "${LINE}" | tee -a "${LOG_FILE}"
    printf "============================================================\n" >> "${LOG_FILE}"
    printf "  %s\n" "${TITLE}" >> "${LOG_FILE}"
    printf "============================================================\n" >> "${LOG_FILE}"
}

print_result() {
    STATUS="$1"   # PASS | FAIL | WARN | INFO
    MSG="$2"
    case "${STATUS}" in
        PASS) TAG="${PASS}" ;;
        FAIL) TAG="${FAIL}"; ISSUES=$((ISSUES+1)) ;;
        WARN) TAG="${WARN}"; WARNINGS=$((WARNINGS+1)) ;;
        *)    TAG="${INFO}" ;;
    esac
    printf "  %b  %s\n" "${TAG}" "${MSG}" | tee -a "${LOG_FILE}"
}

separator() {
    printf "  %s\n" "------------------------------------------------------------" | tee -a "${LOG_FILE}"
}

ensure_log_dir() {
    if [ ! -d "${LOG_DIR}" ]; then
        mkdir -p "${LOG_DIR}" 2>/dev/null
        if [ $? -ne 0 ]; then
            printf "ERROR: Cannot create log directory: %s\n" "${LOG_DIR}" >&2
            exit 1
        fi
    fi
    if [ ! -w "${LOG_DIR}" ]; then
        printf "ERROR: Log directory not writable: %s\n" "${LOG_DIR}" >&2
        exit 1
    fi
}

check_sqlplus() {
    if [ ! -x "${SQLPLUS}" ]; then
        printf "ERROR: sqlplus not found at %s\n" "${SQLPLUS}" >&2
        exit 1
    fi
}

# Run a SQL query; return output as text
run_sql() {
    QUERY="$1"
    "${SQLPLUS}" -S "${DBA_USER}" <<EOF
SET PAGESIZE 200
SET LINESIZE 220
SET FEEDBACK OFF
SET HEADING OFF
SET TRIMSPOOL ON
SET ECHO OFF
WHENEVER SQLERROR EXIT 1
${QUERY}
EXIT;
EOF
}

# Run SQL with headings (for tabular output)
run_sql_table() {
    HEADING="$1"
    QUERY="$2"
    COL_FMTS="${3:-}"
    "${SQLPLUS}" -S "${DBA_USER}" <<EOF
SET PAGESIZE 200
SET LINESIZE 220
SET FEEDBACK OFF
SET TRIMSPOOL ON
SET ECHO OFF
${COL_FMTS}
${QUERY}
EXIT;
EOF
}

# ---------------------------------------------------------------------------
# STARTUP
# ---------------------------------------------------------------------------
ensure_log_dir
check_sqlplus

# Banner
clear
printf "${C_BOLD}${C_CYAN}"
printf "╔══════════════════════════════════════════════════════════════╗\n"
printf "║       Oracle 19c Database Health Check                      ║\n"
printf "║       SID: %-20s  %-20s  ║\n" "${ORACLE_SID}" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "╚══════════════════════════════════════════════════════════════╝\n"
printf "${C_RESET}"

# Log file header
{
printf "================================================================\n"
printf "  Oracle 19c Database Health Check Report\n"
printf "  Database SID  : %s\n" "${ORACLE_SID}"
printf "  Host          : %s\n" "$(uname -n)"
printf "  OS            : %s %s\n" "$(uname -s)" "$(uname -r)"
printf "  Run Date/Time : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "  Run By        : %s\n" "$(id)"
printf "  Log File      : %s\n" "${LOG_FILE}"
printf "================================================================\n"
} | tee -a "${LOG_FILE}"

# ---------------------------------------------------------------------------
# SECTION 1 — OS / ENVIRONMENT
# ---------------------------------------------------------------------------
print_header "1. OS & ORACLE ENVIRONMENT"

OS_NAME=$(uname -s)
log "  OS Type       : ${OS_NAME}"
log "  Hostname      : $(uname -n)"
log "  Kernel        : $(uname -r)"
log "  ORACLE_HOME   : ${ORACLE_HOME}"
log "  ORACLE_BASE   : ${ORACLE_BASE}"
log "  ORACLE_SID    : ${ORACLE_SID}"

# Check ORACLE_HOME exists
if [ -d "${ORACLE_HOME}" ]; then
    print_result PASS "ORACLE_HOME exists: ${ORACLE_HOME}"
else
    print_result FAIL "ORACLE_HOME not found: ${ORACLE_HOME}"
fi

# Oracle process running?
PROC_COUNT=$(ps -ef 2>/dev/null | grep "ora_pmon_${ORACLE_SID}" | grep -v grep | wc -l | tr -d ' ')
if [ "${PROC_COUNT}" -ge 1 ]; then
    print_result PASS "Oracle PMON process running (ora_pmon_${ORACLE_SID})"
else
    print_result FAIL "Oracle PMON process NOT found for SID: ${ORACLE_SID}"
fi

# Listener check
LSNRCTL="${ORACLE_HOME}/bin/lsnrctl"
if [ -x "${LSNRCTL}" ]; then
    LSNR_STATUS=$(${LSNRCTL} status 2>/dev/null | grep "STATUS of the LISTENER" | head -1)
    if [ -n "${LSNR_STATUS}" ]; then
        print_result PASS "Listener is UP"
        ${LSNRCTL} status 2>/dev/null >> "${LOG_FILE}"
    else
        print_result WARN "Could not determine listener status"
    fi
else
    print_result WARN "lsnrctl not found at ${LSNRCTL}"
fi

# ---------------------------------------------------------------------------
# SECTION 2 — DATABASE STATUS
# ---------------------------------------------------------------------------
print_header "2. DATABASE INSTANCE STATUS"

DB_STATUS=$(run_sql "SELECT STATUS FROM V\$INSTANCE;" 2>/dev/null | tr -d ' ')
DB_OPEN_MODE=$(run_sql "SELECT OPEN_MODE FROM V\$DATABASE;" 2>/dev/null | tr -d ' ')
DB_ROLE=$(run_sql "SELECT DATABASE_ROLE FROM V\$DATABASE;" 2>/dev/null | tr -d ' ')
DB_NAME=$(run_sql "SELECT NAME FROM V\$DATABASE;" 2>/dev/null | tr -d ' ')
DB_VERSION=$(run_sql "SELECT VERSION FROM V\$INSTANCE;" 2>/dev/null | tr -d ' ')
DB_STARTUP=$(run_sql "SELECT TO_CHAR(STARTUP_TIME,'YYYY-MM-DD HH24:MI:SS') FROM V\$INSTANCE;" 2>/dev/null | tr -d ' ')
DB_HOST=$(run_sql "SELECT HOST_NAME FROM V\$INSTANCE;" 2>/dev/null | tr -d ' ')

log "  DB Name       : ${DB_NAME}"
log "  Version       : ${DB_VERSION}"
log "  Role          : ${DB_ROLE}"
log "  Open Mode     : ${DB_OPEN_MODE}"
log "  Instance      : ${DB_STATUS}"
log "  Startup Time  : ${DB_STARTUP}"
log "  DB Host       : ${DB_HOST}"

if [ "${DB_STATUS}" = "OPEN" ]; then
    print_result PASS "Instance status: OPEN"
else
    print_result FAIL "Instance status: ${DB_STATUS} (expected OPEN)"
fi

if [ "${DB_OPEN_MODE}" = "READWRITE" ]; then
    print_result PASS "Open mode: READ WRITE"
elif [ "${DB_OPEN_MODE}" = "READONLYWITHAPPLY" ]; then
    print_result INFO "Open mode: READ ONLY WITH APPLY (Standby/ADG)"
else
    print_result WARN "Open mode: ${DB_OPEN_MODE}"
fi

# ---------------------------------------------------------------------------
# SECTION 3 — DATABASE SIZE & COMPONENTS
# ---------------------------------------------------------------------------
print_header "3. DATABASE SIZE & COMPONENTS"

separator
log "  Datafile Summary:"
run_sql_table "Datafiles" \
"SELECT TABLESPACE_NAME, COUNT(*) FILES, ROUND(SUM(BYTES)/1024/1024/1024,2) SIZE_GB
 FROM DBA_DATA_FILES
 GROUP BY TABLESPACE_NAME
 ORDER BY TABLESPACE_NAME;" \
"COL TABLESPACE_NAME FORMAT A30
 COL FILES FORMAT 999
 COL SIZE_GB FORMAT 9999.99" >> "${LOG_FILE}"

separator
log "  Total DB Size:"
TOTAL_SIZE=$(run_sql "SELECT ROUND(SUM(BYTES)/1024/1024/1024,2)||' GB' FROM DBA_DATA_FILES;" 2>/dev/null | tr -d ' ')
log "    Data Files Total  : ${TOTAL_SIZE}"

TEMP_SIZE=$(run_sql "SELECT ROUND(SUM(BYTES)/1024/1024/1024,2)||' GB' FROM DBA_TEMP_FILES;" 2>/dev/null | tr -d ' ')
log "    Temp Files Total  : ${TEMP_SIZE}"

REDO_SIZE=$(run_sql "SELECT ROUND(SUM(BYTES)/1024/1024,2)||' MB' FROM V\$LOG;" 2>/dev/null | tr -d ' ')
log "    Redo Log Total    : ${REDO_SIZE}"

# ---------------------------------------------------------------------------
# SECTION 4 — TABLESPACE USAGE
# ---------------------------------------------------------------------------
print_header "4. TABLESPACE USAGE"

run_sql_table "Tablespace Usage" \
"SELECT df.TABLESPACE_NAME,
        ROUND(df.TOTAL_MB,2)                        TOTAL_MB,
        ROUND(NVL(fs.FREE_MB,0),2)                  FREE_MB,
        ROUND(df.TOTAL_MB - NVL(fs.FREE_MB,0),2)    USED_MB,
        ROUND((df.TOTAL_MB - NVL(fs.FREE_MB,0))/df.TOTAL_MB*100,1) PCT_USED,
        CASE WHEN ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/df.TOTAL_MB*100,1) >= 90 THEN '*** CRITICAL ***'
             WHEN ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/df.TOTAL_MB*100,1) >= 80 THEN '** WARNING **'
             ELSE 'OK' END STATUS
   FROM (SELECT TABLESPACE_NAME, SUM(BYTES)/1024/1024 TOTAL_MB FROM DBA_DATA_FILES GROUP BY TABLESPACE_NAME) df,
        (SELECT TABLESPACE_NAME, SUM(BYTES)/1024/1024 FREE_MB  FROM DBA_FREE_SPACE   GROUP BY TABLESPACE_NAME) fs
  WHERE df.TABLESPACE_NAME = fs.TABLESPACE_NAME(+)
  ORDER BY PCT_USED DESC;" \
"COL TABLESPACE_NAME FORMAT A30
 COL TOTAL_MB        FORMAT 999999.99
 COL FREE_MB         FORMAT 999999.99
 COL USED_MB         FORMAT 999999.99
 COL PCT_USED        FORMAT 999.9
 COL STATUS          FORMAT A18" | tee -a "${LOG_FILE}"

# Flag critical tablespaces
CRIT_TS=$(run_sql "SELECT COUNT(*) FROM (
  SELECT df.TABLESPACE_NAME,
         ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/df.TOTAL_MB*100,1) PCT_USED
  FROM   (SELECT TABLESPACE_NAME, SUM(BYTES)/1024/1024 TOTAL_MB FROM DBA_DATA_FILES GROUP BY TABLESPACE_NAME) df,
         (SELECT TABLESPACE_NAME, SUM(BYTES)/1024/1024 FREE_MB  FROM DBA_FREE_SPACE  GROUP BY TABLESPACE_NAME) fs
  WHERE  df.TABLESPACE_NAME = fs.TABLESPACE_NAME(+)
    AND  ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/NULLIF(df.TOTAL_MB,0)*100,1) >= 90
);" 2>/dev/null | tr -d ' ')

WARN_TS=$(run_sql "SELECT COUNT(*) FROM (
  SELECT df.TABLESPACE_NAME,
         ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/df.TOTAL_MB*100,1) PCT_USED
  FROM   (SELECT TABLESPACE_NAME, SUM(BYTES)/1024/1024 TOTAL_MB FROM DBA_DATA_FILES GROUP BY TABLESPACE_NAME) df,
         (SELECT TABLESPACE_NAME, SUM(BYTES)/1024/1024 FREE_MB  FROM DBA_FREE_SPACE  GROUP BY TABLESPACE_NAME) fs
  WHERE  df.TABLESPACE_NAME = fs.TABLESPACE_NAME(+)
    AND  ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/NULLIF(df.TOTAL_MB,0)*100,1) BETWEEN 80 AND 89.9
);" 2>/dev/null | tr -d ' ')

[ "${CRIT_TS}" -gt 0 ] && print_result FAIL "${CRIT_TS} tablespace(s) >= 90% full — CRITICAL"
[ "${WARN_TS}" -gt 0 ] && print_result WARN "${WARN_TS} tablespace(s) between 80-89% full"
[ "${CRIT_TS}" -eq 0 ] && [ "${WARN_TS}" -eq 0 ] && print_result PASS "All tablespaces within acceptable usage thresholds"

# TEMP tablespace
separator
log "  TEMP Tablespace Usage:"
run_sql_table "Temp Usage" \
"SELECT tt.NAME TABLESPACE_NAME,
        ROUND(tt.BYTES/1024/1024,2)                      TOTAL_MB,
        ROUND(NVL(tu.USED_BLOCKS*8192,0)/1024/1024,2)    USED_MB,
        ROUND(tt.BYTES/1024/1024 - NVL(tu.USED_BLOCKS*8192,0)/1024/1024,2) FREE_MB,
        ROUND(NVL(tu.USED_BLOCKS*8192,0)/tt.BYTES*100,1) PCT_USED
 FROM   V\$TEMPFILE tt,
        V\$TEMP_SPACE_HEADER tu
 WHERE  tt.FILE# = tu.FILE#(+)
 ORDER BY PCT_USED DESC;" \
"COL TABLESPACE_NAME FORMAT A20
 COL TOTAL_MB        FORMAT 99999.99
 COL USED_MB         FORMAT 99999.99
 COL FREE_MB         FORMAT 99999.99
 COL PCT_USED        FORMAT 999.9" | tee -a "${LOG_FILE}"

# ---------------------------------------------------------------------------
# SECTION 5 — REDO LOGS
# ---------------------------------------------------------------------------
print_header "5. REDO LOG STATUS"

run_sql_table "Redo Logs" \
"SELECT l.GROUP#, l.MEMBERS, ROUND(l.BYTES/1024/1024,0) SIZE_MB, l.STATUS, l.ARCHIVED, lf.MEMBER
 FROM   V\$LOG l, V\$LOGFILE lf
 WHERE  l.GROUP# = lf.GROUP#
 ORDER BY l.GROUP#;" \
"COL GROUP#   FORMAT 99
 COL MEMBERS  FORMAT 9
 COL SIZE_MB  FORMAT 9999
 COL STATUS   FORMAT A16
 COL ARCHIVED FORMAT A8
 COL MEMBER   FORMAT A60" | tee -a "${LOG_FILE}"

LOG_SWITCHES=$(run_sql "SELECT COUNT(*) FROM V\$LOG_HISTORY WHERE FIRST_TIME > SYSDATE - 1/24;" 2>/dev/null | tr -d ' ')
log "  Log switches in last 1 hour: ${LOG_SWITCHES}"
if [ "${LOG_SWITCHES}" -gt 20 ]; then
    print_result WARN "High redo log switch rate: ${LOG_SWITCHES} in last hour (consider larger redo logs)"
else
    print_result PASS "Redo log switch rate normal: ${LOG_SWITCHES} in last hour"
fi

# ---------------------------------------------------------------------------
# SECTION 6 — ARCHIVE LOG
# ---------------------------------------------------------------------------
print_header "6. ARCHIVE LOG STATUS"

ARCHIVELOG_MODE=$(run_sql "SELECT LOG_MODE FROM V\$DATABASE;" 2>/dev/null | tr -d ' ')
log "  Archive Log Mode: ${ARCHIVELOG_MODE}"

if [ "${ARCHIVELOG_MODE}" = "ARCHIVELOG" ]; then
    print_result PASS "Database is in ARCHIVELOG mode"
    separator
    log "  Archive Log Destinations:"
    run_sql_table "Archive Dest" \
    "SELECT DEST_ID, STATUS, TARGET, ARCHIVER, SCHEDULE, DESTINATION
     FROM   V\$ARCHIVE_DEST
     WHERE  STATUS != 'INACTIVE'
     ORDER BY DEST_ID;" \
    "COL DEST_ID     FORMAT 99
     COL STATUS      FORMAT A10
     COL TARGET      FORMAT A10
     COL ARCHIVER    FORMAT A10
     COL SCHEDULE    FORMAT A10
     COL DESTINATION FORMAT A50" | tee -a "${LOG_FILE}"
    
    # Archive dest disk usage (FRA)
    FRA_PCT=$(run_sql "SELECT ROUND(SPACE_USED_PERCENT,1) FROM V\$RECOVERY_FILE_DEST;" 2>/dev/null | tr -d ' ')
    if [ -n "${FRA_PCT}" ]; then
        log "  FRA (Fast Recovery Area) Usage: ${FRA_PCT}%"
        if [ "$(printf '%s\n' "${FRA_PCT}" '85' | sort -n | head -1)" != "${FRA_PCT}" ] && [ "${FRA_PCT}" != "85" ]; then
            print_result FAIL "FRA usage CRITICAL: ${FRA_PCT}% used"
        elif [ "$(printf '%s\n' "${FRA_PCT}" '70' | sort -n | head -1)" != "${FRA_PCT}" ] && [ "${FRA_PCT}" != "70" ]; then
            print_result WARN "FRA usage WARNING: ${FRA_PCT}% used"
        else
            print_result PASS "FRA usage OK: ${FRA_PCT}%"
        fi
    fi
else
    print_result WARN "Database is in NOARCHIVELOG mode — no point-in-time recovery possible"
fi

# ---------------------------------------------------------------------------
# SECTION 7 — SGA / MEMORY
# ---------------------------------------------------------------------------
print_header "7. SGA / MEMORY CONFIGURATION"

run_sql_table "SGA Components" \
"SELECT COMPONENT, ROUND(CURRENT_SIZE/1024/1024,0) CURRENT_MB,
        ROUND(MIN_SIZE/1024/1024,0) MIN_MB,
        ROUND(MAX_SIZE/1024/1024,0) MAX_MB,
        GRANULE_SIZE/1024/1024      GRANULE_MB,
        LAST_OPER_TYPE
 FROM   V\$SGA_DYNAMIC_COMPONENTS
 WHERE  CURRENT_SIZE > 0
 ORDER BY CURRENT_SIZE DESC;" \
"COL COMPONENT      FORMAT A35
 COL CURRENT_MB     FORMAT 99999
 COL MIN_MB         FORMAT 99999
 COL MAX_MB         FORMAT 99999
 COL GRANULE_MB     FORMAT 999.9
 COL LAST_OPER_TYPE FORMAT A15" | tee -a "${LOG_FILE}"

SGA_SIZE=$(run_sql "SELECT ROUND(SUM(VALUE)/1024/1024,0)||' MB' FROM V\$SGA;" 2>/dev/null | tr -d ' ')
PGA_SIZE=$(run_sql "SELECT ROUND(VALUE/1024/1024,0)||' MB' FROM V\$PGASTAT WHERE NAME='maximum PGA allocated';" 2>/dev/null | tr -d ' ')
log "  Total SGA Allocated  : ${SGA_SIZE}"
log "  Max PGA Allocated    : ${PGA_SIZE}"

# Buffer cache hit ratio
BHR=$(run_sql "SELECT ROUND((1-(phy.VALUE/(cur.VALUE+con.VALUE+phy.VALUE)))*100,2)
 FROM V\$SYSSTAT phy, V\$SYSSTAT cur, V\$SYSSTAT con
 WHERE phy.NAME='physical reads' AND cur.NAME='db block gets' AND con.NAME='consistent gets';" 2>/dev/null | tr -d ' ')
log "  Buffer Cache Hit Ratio : ${BHR}%"
if [ "$(printf '%s\n' "${BHR}" '90' | sort -n | tail -1)" = "${BHR}" ] || [ "${BHR}" = "90" ]; then
    print_result PASS "Buffer Cache Hit Ratio: ${BHR}% (>=90%)"
else
    print_result WARN "Buffer Cache Hit Ratio: ${BHR}% (below 90% threshold)"
fi

# ---------------------------------------------------------------------------
# SECTION 8 — BACKUP STATUS (RMAN)
# ---------------------------------------------------------------------------
print_header "8. RMAN BACKUP STATUS"

separator
log "  Last 7 Days RMAN Jobs:"
run_sql_table "RMAN Jobs" \
"SELECT SESSION_KEY,
        INPUT_TYPE,
        STATUS,
        TO_CHAR(START_TIME,'YYYY-MM-DD HH24:MI') START_TIME,
        TO_CHAR(END_TIME  ,'YYYY-MM-DD HH24:MI') END_TIME,
        ROUND(ELAPSED_SECONDS/60,1)              ELAPSED_MIN
 FROM   V\$RMAN_BACKUP_JOB_DETAILS
 WHERE  START_TIME > SYSDATE - 7
 ORDER BY START_TIME DESC
 FETCH FIRST 20 ROWS ONLY;" \
"COL SESSION_KEY  FORMAT 9999999
 COL INPUT_TYPE   FORMAT A20
 COL STATUS       FORMAT A12
 COL START_TIME   FORMAT A18
 COL END_TIME     FORMAT A18
 COL ELAPSED_MIN  FORMAT 9999.9" | tee -a "${LOG_FILE}"

FAILED_BK=$(run_sql "SELECT COUNT(*) FROM V\$RMAN_BACKUP_JOB_DETAILS
 WHERE STATUS NOT IN ('COMPLETED','COMPLETED WITH WARNINGS')
   AND START_TIME > SYSDATE - 7;" 2>/dev/null | tr -d ' ')
LAST_FULL=$(run_sql "SELECT TO_CHAR(MAX(END_TIME),'YYYY-MM-DD HH24:MI:SS') FROM V\$RMAN_BACKUP_JOB_DETAILS
 WHERE INPUT_TYPE LIKE 'DB FULL%' AND STATUS='COMPLETED';" 2>/dev/null | tr -d ' ')

log "  Last successful full backup: ${LAST_FULL}"
[ "${FAILED_BK}" -gt 0 ] && print_result FAIL "${FAILED_BK} failed/incomplete RMAN job(s) in last 7 days"
[ "${FAILED_BK}" -eq 0 ] && print_result PASS "No failed RMAN jobs in last 7 days"

# ---------------------------------------------------------------------------
# SECTION 9 — ALERT LOG ERRORS (last 24 h)
# ---------------------------------------------------------------------------
print_header "9. ALERT LOG — ERRORS (Last 24 Hours)"

DIAG_DEST=$(run_sql "SELECT VALUE FROM V\$DIAG_INFO WHERE NAME='Diag Trace';" 2>/dev/null | tr -d ' ')
ALERT_LOG="${DIAG_DEST}/alert_${ORACLE_SID}.log"
log "  Alert Log: ${ALERT_LOG}"

if [ -f "${ALERT_LOG}" ]; then
    # Grab last 24h errors (approximate: last 5000 lines)
    ALERT_ERRORS=$(tail -5000 "${ALERT_LOG}" 2>/dev/null | grep -i "ORA-\|error\|warning\|FATAL" | grep -v "^$" | head -50)
    if [ -n "${ALERT_ERRORS}" ]; then
        print_result WARN "Errors/warnings found in alert log (last 5000 lines):"
        printf "%s\n" "${ALERT_ERRORS}" | while IFS= read -r line; do
            log "    ${line}"
        done
    else
        print_result PASS "No ORA- errors found in alert log (last 5000 lines)"
    fi

    # ORA- count
    ORA_COUNT=$(tail -5000 "${ALERT_LOG}" 2>/dev/null | grep -c "ORA-" || true)
    log "  ORA- error count (last 5000 lines): ${ORA_COUNT}"
else
    print_result WARN "Alert log not accessible at: ${ALERT_LOG}"
fi

# ---------------------------------------------------------------------------
# SECTION 10 — INVALID OBJECTS
# ---------------------------------------------------------------------------
print_header "10. INVALID DATABASE OBJECTS"

INVALID_CNT=$(run_sql "SELECT COUNT(*) FROM DBA_OBJECTS WHERE STATUS='INVALID';" 2>/dev/null | tr -d ' ')
log "  Total invalid objects: ${INVALID_CNT}"

if [ "${INVALID_CNT}" -gt 0 ]; then
    print_result WARN "${INVALID_CNT} invalid object(s) found:"
    run_sql_table "Invalid Objects" \
    "SELECT OWNER, OBJECT_NAME, OBJECT_TYPE, LAST_DDL_TIME
     FROM   DBA_OBJECTS
     WHERE  STATUS='INVALID'
     ORDER BY OWNER, OBJECT_TYPE, OBJECT_NAME
     FETCH FIRST 50 ROWS ONLY;" \
    "COL OWNER        FORMAT A20
     COL OBJECT_NAME  FORMAT A35
     COL OBJECT_TYPE  FORMAT A20
     COL LAST_DDL_TIME FORMAT A20" | tee -a "${LOG_FILE}"
else
    print_result PASS "No invalid objects found"
fi

# ---------------------------------------------------------------------------
# SECTION 11 — BLOCKED / LONG RUNNING SESSIONS
# ---------------------------------------------------------------------------
print_header "11. SESSIONS — BLOCKED & LONG RUNNING"

separator
log "  Active Sessions Summary:"
run_sql_table "Session Summary" \
"SELECT STATUS, COUNT(*) CNT FROM V\$SESSION WHERE TYPE='USER' GROUP BY STATUS ORDER BY CNT DESC;" \
"COL STATUS FORMAT A15
 COL CNT    FORMAT 9999" | tee -a "${LOG_FILE}"

BLOCKED=$(run_sql "SELECT COUNT(*) FROM V\$SESSION WHERE BLOCKING_SESSION IS NOT NULL;" 2>/dev/null | tr -d ' ')
log "  Blocked sessions: ${BLOCKED}"
if [ "${BLOCKED}" -gt 0 ]; then
    print_result WARN "${BLOCKED} blocked session(s) found:"
    run_sql_table "Blocked Sessions" \
    "SELECT s.SID, s.SERIAL#, s.USERNAME, s.STATUS,
            s.BLOCKING_SESSION BLOCKING_SID,
            s.WAIT_CLASS, s.EVENT,
            ROUND(s.SECONDS_IN_WAIT/60,1) WAIT_MIN,
            s.SQL_ID
     FROM   V\$SESSION s
     WHERE  s.BLOCKING_SESSION IS NOT NULL
     ORDER BY s.SECONDS_IN_WAIT DESC;" \
    "COL SID          FORMAT 9999
     COL USERNAME     FORMAT A15
     COL STATUS       FORMAT A10
     COL BLOCKING_SID FORMAT 9999
     COL WAIT_CLASS   FORMAT A15
     COL EVENT        FORMAT A30
     COL WAIT_MIN     FORMAT 9999.9
     COL SQL_ID       FORMAT A15" | tee -a "${LOG_FILE}"
else
    print_result PASS "No blocked sessions"
fi

separator
log "  Long Running Queries (> 5 minutes):"
LR_COUNT=$(run_sql "SELECT COUNT(*) FROM V\$SESSION_LONGOPS
 WHERE TIME_REMAINING > 0 AND ELAPSED_SECONDS > 300;" 2>/dev/null | tr -d ' ')
if [ "${LR_COUNT}" -gt 0 ]; then
    print_result WARN "${LR_COUNT} long-running operation(s) detected"
    run_sql_table "Long Ops" \
    "SELECT SID, SERIAL#, OPNAME, TARGET,
            ROUND(SOFAR/TOTALWORK*100,1) PCT_DONE,
            ROUND(ELAPSED_SECONDS/60,1) ELAPSED_MIN,
            ROUND(TIME_REMAINING/60,1)  REMAIN_MIN,
            SQL_ID
     FROM   V\$SESSION_LONGOPS
     WHERE  TIME_REMAINING > 0 AND ELAPSED_SECONDS > 300
     ORDER BY ELAPSED_SECONDS DESC;" \
    "COL OPNAME       FORMAT A25
     COL TARGET       FORMAT A25
     COL PCT_DONE     FORMAT 999.9
     COL ELAPSED_MIN  FORMAT 99999.9
     COL REMAIN_MIN   FORMAT 99999.9
     COL SQL_ID       FORMAT A15" | tee -a "${LOG_FILE}"
else
    print_result PASS "No long-running operations (>5 min) detected"
fi

# ---------------------------------------------------------------------------
# SECTION 12 — TOP WAIT EVENTS
# ---------------------------------------------------------------------------
print_header "12. TOP WAIT EVENTS (Current)"

run_sql_table "Wait Events" \
"SELECT EVENT, TOTAL_WAITS, TOTAL_TIMEOUTS,
        ROUND(TIME_WAITED_MICRO/1000000,2) TIME_WAITED_S,
        ROUND(AVERAGE_WAIT_MICRO/1000,2)   AVG_WAIT_MS
 FROM   V\$SYSTEM_EVENT
 WHERE  WAIT_CLASS != 'Idle'
   AND  TOTAL_WAITS > 0
 ORDER BY TIME_WAITED_MICRO DESC
 FETCH FIRST 15 ROWS ONLY;" \
"COL EVENT          FORMAT A40
 COL TOTAL_WAITS    FORMAT 999999999
 COL TOTAL_TIMEOUTS FORMAT 999999999
 COL TIME_WAITED_S  FORMAT 999999999.99
 COL AVG_WAIT_MS    FORMAT 99999.99" | tee -a "${LOG_FILE}"

# ---------------------------------------------------------------------------
# SECTION 13 — DATA GUARD (if applicable)
# ---------------------------------------------------------------------------
print_header "13. DATA GUARD STATUS"

DG_COUNT=$(run_sql "SELECT COUNT(*) FROM V\$DATAGUARD_CONFIG;" 2>/dev/null | tr -d ' ')
if [ "${DG_COUNT}" -gt 0 ] 2>/dev/null; then
    run_sql_table "DataGuard Config" \
    "SELECT DB_UNIQUE_NAME, ROLE, DEST_ID, STATUS FROM V\$DATAGUARD_CONFIG;" \
    "COL DB_UNIQUE_NAME FORMAT A25
     COL ROLE           FORMAT A15
     COL DEST_ID        FORMAT 9
     COL STATUS         FORMAT A15" | tee -a "${LOG_FILE}"

    MRP_STATUS=$(run_sql "SELECT STATUS FROM V\$MANAGED_STANDBY WHERE PROCESS='MRP0';" 2>/dev/null | tr -d ' ')
    if [ -n "${MRP_STATUS}" ]; then
        log "  MRP0 Process Status: ${MRP_STATUS}"
        [ "${MRP_STATUS}" = "APPLYING_LOG" ] && print_result PASS "MRP0 applying logs (standby active)"
    fi

    LOG_GAP=$(run_sql "SELECT VALUE FROM V\$DATAGUARD_STATS WHERE NAME='apply lag';" 2>/dev/null | tr -d ' ')
    [ -n "${LOG_GAP}" ] && log "  Apply Lag: ${LOG_GAP}"
else
    print_result INFO "Data Guard not configured / not applicable"
fi

# ---------------------------------------------------------------------------
# SECTION 14 — FRAGMENTATION & HIGH WATER MARK
# ---------------------------------------------------------------------------
print_header "14. TOP FRAGMENTED TABLESPACES"

run_sql_table "Fragmentation" \
"SELECT TABLESPACE_NAME,
        COUNT(*)                                   FREE_CHUNKS,
        ROUND(MAX(BYTES)/1024/1024,2)              LARGEST_FREE_MB,
        ROUND(SUM(BYTES)/1024/1024,2)              TOTAL_FREE_MB
 FROM   DBA_FREE_SPACE
 GROUP BY TABLESPACE_NAME
 HAVING COUNT(*) > 5
 ORDER BY FREE_CHUNKS DESC
 FETCH FIRST 10 ROWS ONLY;" \
"COL TABLESPACE_NAME FORMAT A30
 COL FREE_CHUNKS     FORMAT 99999
 COL LARGEST_FREE_MB FORMAT 99999.99
 COL TOTAL_FREE_MB   FORMAT 99999.99" | tee -a "${LOG_FILE}"

# ---------------------------------------------------------------------------
# SECTION 15 — USER ACCOUNT STATUS
# ---------------------------------------------------------------------------
print_header "15. DATABASE USER ACCOUNT STATUS"

run_sql_table "User Accounts" \
"SELECT USERNAME, ACCOUNT_STATUS, EXPIRY_DATE, PROFILE, DEFAULT_TABLESPACE
 FROM   DBA_USERS
 WHERE  ACCOUNT_STATUS != 'OPEN'
   AND  USERNAME NOT IN ('SYS','SYSTEM','DBSNMP','SYSMAN','OUTLN',
                         'ORACLE_OCM','ANONYMOUS','XDB','XS\$NULL',
                         'GSMADMIN_INTERNAL','GSMCATUSER','GSMROOTUSER')
 ORDER BY ACCOUNT_STATUS, USERNAME;" \
"COL USERNAME           FORMAT A25
 COL ACCOUNT_STATUS     FORMAT A20
 COL EXPIRY_DATE        FORMAT A20
 COL PROFILE            FORMAT A15
 COL DEFAULT_TABLESPACE FORMAT A20" | tee -a "${LOG_FILE}"

LOCKED_CNT=$(run_sql "SELECT COUNT(*) FROM DBA_USERS WHERE ACCOUNT_STATUS LIKE '%LOCKED%'
  AND USERNAME NOT IN ('SYS','SYSTEM','DBSNMP','OUTLN','ORACLE_OCM','ANONYMOUS',
                       'XDB','XS\$NULL','GSMADMIN_INTERNAL','GSMCATUSER','GSMROOTUSER');" 2>/dev/null | tr -d ' ')
EXPIRING_CNT=$(run_sql "SELECT COUNT(*) FROM DBA_USERS WHERE ACCOUNT_STATUS='EXPIRED';" 2>/dev/null | tr -d ' ')

[ "${LOCKED_CNT}" -gt 0 ]   && print_result WARN "${LOCKED_CNT} non-system user account(s) locked"
[ "${EXPIRING_CNT}" -gt 0 ] && print_result WARN "${EXPIRING_CNT} user account(s) expired"
[ "${LOCKED_CNT}" -eq 0 ] && [ "${EXPIRING_CNT}" -eq 0 ] && print_result PASS "All non-system user accounts are in normal status"

# ---------------------------------------------------------------------------
# SECTION 16 — ASM (if applicable)
# ---------------------------------------------------------------------------
print_header "16. ASM DISK GROUP STATUS"

ASM_CNT=$(run_sql "SELECT COUNT(*) FROM V\$ASM_DISKGROUP;" 2>/dev/null | tr -d ' ')
if [ -n "${ASM_CNT}" ] && [ "${ASM_CNT}" -gt 0 ] 2>/dev/null; then
    run_sql_table "ASM Disk Groups" \
    "SELECT NAME, STATE, TYPE,
            ROUND(TOTAL_MB/1024,2)       TOTAL_GB,
            ROUND(FREE_MB/1024,2)        FREE_GB,
            ROUND((1-FREE_MB/NULLIF(TOTAL_MB,0))*100,1) PCT_USED
     FROM   V\$ASM_DISKGROUP
     ORDER BY NAME;" \
    "COL NAME      FORMAT A20
     COL STATE     FORMAT A12
     COL TYPE      FORMAT A8
     COL TOTAL_GB  FORMAT 99999.99
     COL FREE_GB   FORMAT 99999.99
     COL PCT_USED  FORMAT 999.9" | tee -a "${LOG_FILE}"

    ASM_CRITICAL=$(run_sql "SELECT COUNT(*) FROM V\$ASM_DISKGROUP
     WHERE ROUND((1-FREE_MB/NULLIF(TOTAL_MB,0))*100,1) >= 85;" 2>/dev/null | tr -d ' ')
    [ "${ASM_CRITICAL}" -gt 0 ] && print_result FAIL "${ASM_CRITICAL} ASM disk group(s) >= 85% full"
    [ "${ASM_CRITICAL}" -eq 0 ] && print_result PASS "ASM disk groups within acceptable usage"
else
    print_result INFO "ASM not configured / V\$ASM_DISKGROUP not accessible"
fi

# ---------------------------------------------------------------------------
# SECTION 17 — SCHEDULER JOBS (failed)
# ---------------------------------------------------------------------------
print_header "17. DBMS_SCHEDULER — FAILED JOBS (Last 7 Days)"

SCHED_FAIL=$(run_sql "SELECT COUNT(*) FROM DBA_SCHEDULER_JOB_RUN_DETAILS
 WHERE STATUS='FAILED' AND ACTUAL_START_DATE > SYSTIMESTAMP - 7;" 2>/dev/null | tr -d ' ')
log "  Failed scheduler jobs (last 7 days): ${SCHED_FAIL}"

if [ "${SCHED_FAIL}" -gt 0 ]; then
    print_result WARN "${SCHED_FAIL} failed scheduler job run(s):"
    run_sql_table "Failed Jobs" \
    "SELECT OWNER, JOB_NAME,
            TO_CHAR(ACTUAL_START_DATE,'YYYY-MM-DD HH24:MI') START_TIME,
            STATUS, ADDITIONAL_INFO
     FROM   DBA_SCHEDULER_JOB_RUN_DETAILS
     WHERE  STATUS='FAILED'
       AND  ACTUAL_START_DATE > SYSTIMESTAMP - 7
     ORDER BY ACTUAL_START_DATE DESC
     FETCH FIRST 20 ROWS ONLY;" \
    "COL OWNER           FORMAT A15
     COL JOB_NAME        FORMAT A30
     COL START_TIME      FORMAT A18
     COL STATUS          FORMAT A10
     COL ADDITIONAL_INFO FORMAT A50" | tee -a "${LOG_FILE}"
else
    print_result PASS "No failed scheduler jobs in last 7 days"
fi

# ---------------------------------------------------------------------------
# SECTION 18 — PERFORMANCE METRICS
# ---------------------------------------------------------------------------
print_header "18. KEY PERFORMANCE INDICATORS"

run_sql_table "Top SQL by Elapsed Time" \
"SELECT ROUND(ELAPSED_TIME/1000000,2) ELAPSED_S,
        EXECUTIONS,
        ROUND(ELAPSED_TIME/NULLIF(EXECUTIONS,0)/1000000,4) ELAPSED_PER_EXEC_S,
        SQL_ID,
        SUBSTR(SQL_TEXT,1,80) SQL_SNIPPET
 FROM   V\$SQLAREA
 WHERE  ELAPSED_TIME > 0
 ORDER BY ELAPSED_TIME DESC
 FETCH FIRST 10 ROWS ONLY;" \
"COL ELAPSED_S           FORMAT 9999999.99
 COL EXECUTIONS          FORMAT 9999999
 COL ELAPSED_PER_EXEC_S  FORMAT 9999.9999
 COL SQL_ID              FORMAT A15
 COL SQL_SNIPPET         FORMAT A80" | tee -a "${LOG_FILE}"

separator
log "  System Statistics:"
run_sql_table "Sys Stats" \
"SELECT NAME, ROUND(VALUE,0) VALUE
 FROM   V\$SYSSTAT
 WHERE  NAME IN ('user calls','user commits','user rollbacks',
                 'parse count (hard)','parse count (total)',
                 'physical reads','physical writes',
                 'redo writes','redo size')
 ORDER BY NAME;" \
"COL NAME  FORMAT A35
 COL VALUE FORMAT 9999999999999" | tee -a "${LOG_FILE}"

# ---------------------------------------------------------------------------
# SECTION 19 — PATCH INFO
# ---------------------------------------------------------------------------
print_header "19. PATCH INFORMATION"

run_sql_table "Applied Patches" \
"SELECT PATCH_ID, PATCH_UID, VERSION, ACTION, STATUS,
        TO_CHAR(ACTION_TIME,'YYYY-MM-DD HH24:MI') APPLIED_TIME,
        DESCRIPTION
 FROM   DBA_REGISTRY_SQLPATCH
 ORDER BY ACTION_TIME DESC
 FETCH FIRST 10 ROWS ONLY;" \
"COL PATCH_ID     FORMAT 9999999999
 COL PATCH_UID    FORMAT 9999999999
 COL VERSION      FORMAT A12
 COL ACTION       FORMAT A10
 COL STATUS       FORMAT A10
 COL APPLIED_TIME FORMAT A18
 COL DESCRIPTION  FORMAT A55" | tee -a "${LOG_FILE}"

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------
print_header "HEALTH CHECK SUMMARY"

END_TIME=$(date "+%Y-%m-%d %H:%M:%S")
log ""
log "  SID           : ${ORACLE_SID}"
log "  Completed     : ${END_TIME}"
log "  Log File      : ${LOG_FILE}"
log ""
log "  Total Issues  (FAIL) : ${ISSUES}"
log "  Total Warnings (WARN): ${WARNINGS}"
log ""

if [ "${ISSUES}" -gt 0 ]; then
    print_result FAIL "Health check completed with ${ISSUES} CRITICAL issue(s) and ${WARNINGS} warning(s)"
elif [ "${WARNINGS}" -gt 0 ]; then
    print_result WARN "Health check completed with ${WARNINGS} warning(s) — review recommended"
else
    print_result PASS "Health check completed — all checks PASSED"
fi

log ""
log "  Full details logged to: ${LOG_FILE}"
log ""

# Write summary file
{
printf "Oracle 19c Health Check — SUMMARY\n"
printf "Database : %s\n" "${ORACLE_SID}"
printf "Run Date : %s\n" "${END_TIME}"
printf "Host     : %s\n" "$(uname -n)"
printf "FAILS    : %s\n" "${ISSUES}"
printf "WARNINGS : %s\n" "${WARNINGS}"
printf "Log File : %s\n" "${LOG_FILE}"
} > "${SUMMARY_FILE}"

# Optional email alert
if [ -n "${ALERT_EMAIL}" ] && [ "${ISSUES}" -gt 0 ]; then
    if command -v mailx >/dev/null 2>&1; then
        mailx -s "[ALERT] Oracle HC ${ORACLE_SID} — ${ISSUES} CRITICAL issue(s)" "${ALERT_EMAIL}" < "${SUMMARY_FILE}"
    fi
fi

exit ${ISSUES}
