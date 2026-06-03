#!/bin/sh
# =============================================================================
# Script : oracle19c_healthcheck.sh
# Purpose : Detailed Oracle 19c Database Health Check — all running instances
# Compat : Solaris 10/11 (sh/ksh) and Linux (bash/sh) — POSIX only
# Author : DBA Team
# Usage : ./oracle19c_healthcheck.sh
# LOG_DIR=/custom/path ALERT_EMAIL=dba@co.com ./oracle19c_healthcheck.sh
# Notes : - ORACLE_HOME resolved from oratab for each SID
# - SIDs discovered from live ora_pmon_<SID> processes
# - Skips: ASM (+ASM*), APX (*APX*), MGMT (*MGMT*, *MGMTDB*)
# =============================================================================

# ---------------------------------------------------------------------------
# PORTABLE SHELL — no bashisms; compatible with /bin/sh on Solaris & Linux
# ---------------------------------------------------------------------------
PATH=/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin
export PATH

# ---------------------------------------------------------------------------
# GLOBAL CONFIGURATION
# ---------------------------------------------------------------------------
DBA_USER="/ as sysdba" # OS-authenticated sysdba (no password needed)
LOG_DIR=${LOG_DIR:-/var/log/oracle/healthcheck}
ALERT_EMAIL=${ALERT_EMAIL:-""} # Set to DBA email address for failure alerts
MASTER_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
MASTER_LOG="${LOG_DIR}/hc_master_${MASTER_TIMESTAMP}.log"
MASTER_ISSUES=0
MASTER_WARNINGS=0

# ---------------------------------------------------------------------------
# ORATAB LOCATION — Solaris: /var/opt/oracle/oratab Linux: /etc/oratab
# ---------------------------------------------------------------------------
locate_oratab() {
# Solaris keeps oratab under /var/opt/oracle; Linux under /etc
if [ -f /var/opt/oracle/oratab ]; then
ORATAB=/var/opt/oracle/oratab # Solaris
elif [ -f /etc/oratab ]; then
ORATAB=/etc/oratab # Linux / AIX
else
printf "ERROR: oratab not found in /var/opt/oracle/oratab or /etc/oratab\n" >&2
exit 1
fi
export ORATAB
}

# ---------------------------------------------------------------------------
# DISCOVER RUNNING SIDs FROM PMON PROCESSES
# Exclude: +ASM* (Grid/ASM) *APX* (Apex) *MGMT* / *MGMTDB* (EM repo)
# ---------------------------------------------------------------------------
discover_sids() {
# ps output differs slightly between Solaris and Linux but
# the process name ora_pmon_<SID> is consistent on both
ps -ef 2>/dev/null \
| grep 'ora_pmon_' \
| grep -v grep \
| awk '{
for(i=1;i<=NF;i++){
if($i ~ /^ora_pmon_/){
sub(/^ora_pmon_/,"",$i)
print $i
}
}
}' \
| grep -v '^+ASM' \
| grep -iv 'APX' \
| grep -iv 'MGMT' \
| sort -u
}

# ---------------------------------------------------------------------------
# LOOK UP ORACLE_HOME FOR A GIVEN SID FROM ORATAB
# Format: SID:ORACLE_HOME:Y|N (lines starting with # are comments)
# ---------------------------------------------------------------------------
get_oracle_home() {
TARGET_SID="$1"
# Use awk for portability (no grep -P on Solaris)
awk -F: -v sid="${TARGET_SID}" '
/^[[:space:]]*#/ { next }
/^[[:space:]]*$/ { next }
$1 == sid { print $2; exit }
' "${ORATAB}"
}

# ---------------------------------------------------------------------------
# COLOUR / FORMATTING (terminal only; log file gets plain text)
# ---------------------------------------------------------------------------
setup_colours() {
if [ -t 1 ]; then
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'
C_MAGENTA='\033[0;35m'
C_BOLD='\033[1m'
C_RESET='\033[0m'
else
C_RED=''; C_GREEN=''; C_YELLOW=''
C_CYAN=''; C_MAGENTA=''; C_BOLD=''; C_RESET=''
fi
PASS="${C_GREEN}[PASS]${C_RESET}"
FAIL="${C_RED}[FAIL]${C_RESET}"
WARN="${C_YELLOW}[WARN]${C_RESET}"
INFO="${C_CYAN}[INFO]${C_RESET}"
}

# ---------------------------------------------------------------------------
# LOGGING HELPERS (LOG_FILE must be set before calling these)
# ---------------------------------------------------------------------------
log() {
printf "%s\n" "$*" | tee -a "${LOG_FILE}"
}

print_header() {
TITLE="$1"
LINE="================================================================"
printf "\n${C_BOLD}${C_CYAN}%s${C_RESET}\n" "${LINE}" | tee -a "${LOG_FILE}"
printf "${C_BOLD}${C_CYAN} %-60s${C_RESET}\n" "${TITLE}" | tee -a "${LOG_FILE}"
printf "${C_BOLD}${C_CYAN}%s${C_RESET}\n" "${LINE}" | tee -a "${LOG_FILE}"
# Plain copy to log (tee above already wrote coloured version; append plain for readability)
printf "================================================================\n" >> "${LOG_FILE}"
printf " %s\n" "${TITLE}" >> "${LOG_FILE}"
printf "================================================================\n" >> "${LOG_FILE}"
}

print_result() {
STATUS="$1"
MSG="$2"
case "${STATUS}" in
PASS) TAG="${PASS}" ;;
FAIL) TAG="${FAIL}"; ISSUES=$((ISSUES+1)) ;;
WARN) TAG="${WARN}"; WARNINGS=$((WARNINGS+1)) ;;
*) TAG="${INFO}" ;;
esac
printf " %b %s\n" "${TAG}" "${MSG}" | tee -a "${LOG_FILE}"
}

separator() {
printf " %s\n" "----------------------------------------------------------------" \
| tee -a "${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# SQL HELPERS
# ---------------------------------------------------------------------------
# run_sql SID ORACLE_HOME "SQL statement" → plain scalar output
run_sql() {
_SID="$1"; _OH="$2"; _SQL="$3"
ORACLE_SID="${_SID}" ORACLE_HOME="${_OH}" \
"${_OH}/bin/sqlplus" -S "${DBA_USER}" <<EOF
SET PAGESIZE 0
SET LINESIZE 220
SET FEEDBACK OFF
SET HEADING OFF
SET TRIMSPOOL ON
SET ECHO OFF
WHENEVER SQLERROR EXIT 1
${_SQL}
EXIT;
EOF
}

# run_sql_table SID ORACLE_HOME "col fmt stmts" "SELECT ..." → tabular output appended to LOG_FILE
run_sql_table() {
_SID="$1"; _OH="$2"; _FMTS="$3"; _SQL="$4"
ORACLE_SID="${_SID}" ORACLE_HOME="${_OH}" \
"${_OH}/bin/sqlplus" -S "${DBA_USER}" <<EOF | tee -a "${LOG_FILE}"
SET PAGESIZE 200
SET LINESIZE 220
SET FEEDBACK OFF
SET TRIMSPOOL ON
SET ECHO OFF
${_FMTS}
${_SQL}
EXIT;
EOF
}

# ---------------------------------------------------------------------------
# ENSURE LOG DIRECTORY EXISTS AND IS WRITABLE
# ---------------------------------------------------------------------------
ensure_log_dir() {
if [ ! -d "${LOG_DIR}" ]; then
mkdir -p "${LOG_DIR}" 2>/dev/null || {
printf "ERROR: Cannot create log directory: %s\n" "${LOG_DIR}" >&2
exit 1
}
fi
if [ ! -w "${LOG_DIR}" ]; then
printf "ERROR: Log directory not writable: %s\n" "${LOG_DIR}" >&2
exit 1
fi
}

# ===========================================================================
# PER-DATABASE HEALTH CHECK FUNCTION
# Called once per discovered SID
# ===========================================================================
run_healthcheck() {
ORACLE_SID="$1"
ORACLE_HOME="$2"
export ORACLE_SID ORACLE_HOME

SQLPLUS="${ORACLE_HOME}/bin/sqlplus"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${LOG_DIR}/hc_${ORACLE_SID}_${TIMESTAMP}.log"
SUMMARY_FILE="${LOG_DIR}/hc_${ORACLE_SID}_${TIMESTAMP}_summary.log"
ISSUES=0
WARNINGS=0

# -----------------------------------------------------------------------
# BANNER
# -----------------------------------------------------------------------
printf "\n${C_BOLD}${C_MAGENTA}"
printf "╔══════════════════════════════════════════════════════════════════╗\n"
printf "║ Oracle 19c Health Check ║\n"
printf "║ SID : %-20s ║\n" "${ORACLE_SID}"
printf "║ HOME : %-55s ║\n" "${ORACLE_HOME}"
printf "║ Time : %-20s ║\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "╚══════════════════════════════════════════════════════════════════╝\n"
printf "${C_RESET}\n"

{
printf "================================================================\n"
printf " Oracle 19c Database Health Check\n"
printf " SID : %s\n" "${ORACLE_SID}"
printf " ORACLE_HOME : %s\n" "${ORACLE_HOME}"
printf " Host : %s\n" "$(uname -n)"
printf " OS : %s %s\n" "$(uname -s)" "$(uname -r)"
printf " Started : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf " Run By : %s\n" "$(id)"
printf " oratab : %s\n" "${ORATAB}"
printf " Log File : %s\n" "${LOG_FILE}"
printf "================================================================\n"
} | tee -a "${LOG_FILE}"

# Verify sqlplus is reachable
if [ ! -x "${SQLPLUS}" ]; then
printf " ${C_RED}[FAIL]${C_RESET} sqlplus not found at %s — skipping SID %s\n" \
"${SQLPLUS}" "${ORACLE_SID}" | tee -a "${LOG_FILE}"
return 1
fi

# =======================================================================
# SECTION 1 — OS & ORACLE ENVIRONMENT
# =======================================================================
print_header "1. OS & ORACLE ENVIRONMENT"

OS_NAME=$(uname -s)
log " OS Type : ${OS_NAME}"
log " Hostname : $(uname -n)"
log " Kernel : $(uname -r)"
log " ORACLE_HOME : ${ORACLE_HOME}"
log " ORACLE_SID : ${ORACLE_SID}"
log " oratab : ${ORATAB}"

if [ -d "${ORACLE_HOME}" ]; then
print_result PASS "ORACLE_HOME exists: ${ORACLE_HOME}"
else
print_result FAIL "ORACLE_HOME not found: ${ORACLE_HOME}"
fi

# PMON still alive?
PROC_COUNT=$(ps -ef 2>/dev/null | grep "ora_pmon_${ORACLE_SID}$" | grep -v grep | wc -l | tr -d ' \t')
if [ "${PROC_COUNT:-0}" -ge 1 ]; then
print_result PASS "PMON process confirmed running (ora_pmon_${ORACLE_SID})"
else
print_result FAIL "PMON process not found for SID: ${ORACLE_SID}"
fi

# Listener
LSNRCTL="${ORACLE_HOME}/bin/lsnrctl"
if [ -x "${LSNRCTL}" ]; then
LSNR_OUT=$(${LSNRCTL} status 2>/dev/null)
if printf "%s\n" "${LSNR_OUT}" | grep -q "STATUS of the LISTENER"; then
print_result PASS "Listener is UP"
printf "%s\n" "${LSNR_OUT}" >> "${LOG_FILE}"
else
print_result WARN "Listener status could not be confirmed"
fi
else
print_result WARN "lsnrctl not found: ${LSNRCTL}"
fi

# =======================================================================
# SECTION 2 — DATABASE INSTANCE STATUS
# =======================================================================
print_header "2. DATABASE INSTANCE STATUS"

DB_STATUS=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT STATUS FROM V\$INSTANCE;" 2>/dev/null | tr -d ' \t\n')
DB_OPEN_MODE=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT REPLACE(OPEN_MODE,' ','') FROM V\$DATABASE;" 2>/dev/null | tr -d ' \t\n')
DB_ROLE=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT DATABASE_ROLE FROM V\$DATABASE;" 2>/dev/null | tr -d ' \t\n')
DB_NAME=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT NAME FROM V\$DATABASE;" 2>/dev/null | tr -d ' \t\n')
DB_VERSION=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT VERSION FROM V\$INSTANCE;" 2>/dev/null | tr -d ' \t\n')
DB_STARTUP=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT TO_CHAR(STARTUP_TIME,'YYYY-MM-DD HH24:MI:SS') FROM V\$INSTANCE;" \
2>/dev/null | tr -d '\t\n')
DB_HOST=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT HOST_NAME FROM V\$INSTANCE;" 2>/dev/null | tr -d ' \t\n')

log " DB Name : ${DB_NAME}"
log " Version : ${DB_VERSION}"
log " Role : ${DB_ROLE}"
log " Open Mode : ${DB_OPEN_MODE}"
log " Instance : ${DB_STATUS}"
log " Startup Time : ${DB_STARTUP}"
log " DB Host : ${DB_HOST}"

if [ "${DB_STATUS}" = "OPEN" ]; then
print_result PASS "Instance status: OPEN"
else
print_result FAIL "Instance status: ${DB_STATUS:-UNKNOWN} (expected OPEN)"
fi

case "${DB_OPEN_MODE}" in
READWRITE) print_result PASS "Open mode: READ WRITE" ;;
READONLYWITHAPPLY) print_result INFO "Open mode: READ ONLY WITH APPLY (Active Data Guard)" ;;
READONLY) print_result WARN "Open mode: READ ONLY" ;;
*) print_result WARN "Open mode: ${DB_OPEN_MODE:-UNKNOWN}" ;;
esac

# =======================================================================
# SECTION 3 — DATABASE SIZE
# =======================================================================
print_header "3. DATABASE SIZE & COMPONENTS"

separator
log " Datafile Summary by Tablespace:"
run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL TABLESPACE_NAME FORMAT A30
COL FILES FORMAT 999
COL SIZE_GB FORMAT 9999.99" \
"SELECT TABLESPACE_NAME,
COUNT(*) FILES,
ROUND(SUM(BYTES)/1024/1024/1024,2) SIZE_GB
FROM DBA_DATA_FILES
GROUP BY TABLESPACE_NAME
ORDER BY TABLESPACE_NAME;"

TOTAL_SIZE=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT ROUND(SUM(BYTES)/1024/1024/1024,2)||' GB' FROM DBA_DATA_FILES;" \
2>/dev/null | tr -d '\t\n')
TEMP_SIZE=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT ROUND(SUM(BYTES)/1024/1024/1024,2)||' GB' FROM DBA_TEMP_FILES;" \
2>/dev/null | tr -d '\t\n')
REDO_SIZE=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT ROUND(SUM(BYTES)/1024/1024,2)||' MB' FROM V\$LOG;" \
2>/dev/null | tr -d '\t\n')
separator
log " Total Data File Size : ${TOTAL_SIZE}"
log " Total Temp File Size : ${TEMP_SIZE}"
log " Total Redo Log Size : ${REDO_SIZE}"

# =======================================================================
# SECTION 4 — TABLESPACE USAGE
# =======================================================================
print_header "4. TABLESPACE USAGE"

run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL TABLESPACE_NAME FORMAT A30
COL TOTAL_MB FORMAT 999999.99
COL FREE_MB FORMAT 999999.99
COL USED_MB FORMAT 999999.99
COL PCT_USED FORMAT 999.9
COL STATUS FORMAT A18" \
"SELECT df.TABLESPACE_NAME,
ROUND(df.TOTAL_MB,2) TOTAL_MB,
ROUND(NVL(fs.FREE_MB,0),2) FREE_MB,
ROUND(df.TOTAL_MB - NVL(fs.FREE_MB,0),2) USED_MB,
ROUND((df.TOTAL_MB - NVL(fs.FREE_MB,0))
/ NULLIF(df.TOTAL_MB,0) * 100, 1) PCT_USED,
CASE
WHEN ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))
/NULLIF(df.TOTAL_MB,0)*100,1) >= 90
THEN '*** CRITICAL ***'
WHEN ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))
/NULLIF(df.TOTAL_MB,0)*100,1) >= 80
THEN '** WARNING **'
ELSE 'OK'
END STATUS
FROM (SELECT TABLESPACE_NAME,
SUM(BYTES)/1024/1024 TOTAL_MB
FROM DBA_DATA_FILES
GROUP BY TABLESPACE_NAME) df,
(SELECT TABLESPACE_NAME,
SUM(BYTES)/1024/1024 FREE_MB
FROM DBA_FREE_SPACE
GROUP BY TABLESPACE_NAME) fs
WHERE df.TABLESPACE_NAME = fs.TABLESPACE_NAME(+)
ORDER BY PCT_USED DESC;"

CRIT_TS=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM (
SELECT ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/NULLIF(df.TOTAL_MB,0)*100,1) PCT
FROM (SELECT TABLESPACE_NAME,SUM(BYTES)/1024/1024 TOTAL_MB FROM DBA_DATA_FILES GROUP BY TABLESPACE_NAME) df,
(SELECT TABLESPACE_NAME,SUM(BYTES)/1024/1024 FREE_MB FROM DBA_FREE_SPACE GROUP BY TABLESPACE_NAME) fs
WHERE df.TABLESPACE_NAME=fs.TABLESPACE_NAME(+) AND
ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/NULLIF(df.TOTAL_MB,0)*100,1)>=90);" \
2>/dev/null | tr -d ' \t\n')

WARN_TS=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM (
SELECT ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/NULLIF(df.TOTAL_MB,0)*100,1) PCT
FROM (SELECT TABLESPACE_NAME,SUM(BYTES)/1024/1024 TOTAL_MB FROM DBA_DATA_FILES GROUP BY TABLESPACE_NAME) df,
(SELECT TABLESPACE_NAME,SUM(BYTES)/1024/1024 FREE_MB FROM DBA_FREE_SPACE GROUP BY TABLESPACE_NAME) fs
WHERE df.TABLESPACE_NAME=fs.TABLESPACE_NAME(+) AND
ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/NULLIF(df.TOTAL_MB,0)*100,1) BETWEEN 80 AND 89.9);" \
2>/dev/null | tr -d ' \t\n')

[ "${CRIT_TS:-0}" -gt 0 ] && print_result FAIL "${CRIT_TS} tablespace(s) CRITICAL (>=90% full)"
[ "${WARN_TS:-0}" -gt 0 ] && print_result WARN "${WARN_TS} tablespace(s) WARNING (80-89% full)"
[ "${CRIT_TS:-0}" -eq 0 ] && [ "${WARN_TS:-0}" -eq 0 ] && \
print_result PASS "All tablespaces within acceptable usage thresholds"

separator
log " TEMP Tablespace Usage:"
run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL TABLESPACE_NAME FORMAT A20
COL TOTAL_MB FORMAT 99999.99
COL USED_MB FORMAT 99999.99
COL FREE_MB FORMAT 99999.99
COL PCT_USED FORMAT 999.9" \
"SELECT tt.NAME TABLESPACE_NAME,
ROUND(tt.BYTES/1024/1024,2) TOTAL_MB,
ROUND(NVL(tu.USED_BLOCKS*8192,0)/1024/1024,2) USED_MB,
ROUND(tt.BYTES/1024/1024
- NVL(tu.USED_BLOCKS*8192,0)/1024/1024, 2) FREE_MB,
ROUND(NVL(tu.USED_BLOCKS*8192,0)/NULLIF(tt.BYTES,0)
*100, 1) PCT_USED
FROM V\$TEMPFILE tt, V\$TEMP_SPACE_HEADER tu
WHERE tt.FILE# = tu.FILE#(+)
ORDER BY PCT_USED DESC;"

# =======================================================================
# SECTION 5 — REDO LOGS
# =======================================================================
print_header "5. REDO LOG STATUS"

run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL GROUP# FORMAT 99
COL MEMBERS FORMAT 9
COL SIZE_MB FORMAT 9999
COL STATUS FORMAT A16
COL ARCHIVED FORMAT A8
COL MEMBER FORMAT A60" \
"SELECT l.GROUP#, l.MEMBERS,
ROUND(l.BYTES/1024/1024,0) SIZE_MB,
l.STATUS, l.ARCHIVED, lf.MEMBER
FROM V\$LOG l, V\$LOGFILE lf
WHERE l.GROUP# = lf.GROUP#
ORDER BY l.GROUP#;"

LOG_SWITCHES=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$LOG_HISTORY WHERE FIRST_TIME > SYSDATE - 1/24;" \
2>/dev/null | tr -d ' \t\n')
log " Log switches in last hour: ${LOG_SWITCHES:-0}"
if [ "${LOG_SWITCHES:-0}" -gt 20 ]; then
print_result WARN "High redo log switch rate: ${LOG_SWITCHES}/hr — consider larger redo logs"
else
print_result PASS "Redo log switch rate normal: ${LOG_SWITCHES:-0} in last hour"
fi

# =======================================================================
# SECTION 6 — ARCHIVE LOG
# =======================================================================
print_header "6. ARCHIVE LOG STATUS"

ARCHIVELOG_MODE=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT LOG_MODE FROM V\$DATABASE;" 2>/dev/null | tr -d ' \t\n')
log " Archive Log Mode: ${ARCHIVELOG_MODE}"

if [ "${ARCHIVELOG_MODE}" = "ARCHIVELOG" ]; then
print_result PASS "Database is in ARCHIVELOG mode"

separator
log " Archive Destinations (active):"
run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL DEST_ID FORMAT 99
COL STATUS FORMAT A10
COL TARGET FORMAT A10
COL ARCHIVER FORMAT A10
COL SCHEDULE FORMAT A10
COL DESTINATION FORMAT A55" \
"SELECT DEST_ID, STATUS, TARGET, ARCHIVER, SCHEDULE, DESTINATION
FROM V\$ARCHIVE_DEST
WHERE STATUS != 'INACTIVE'
ORDER BY DEST_ID;"

FRA_PCT=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT ROUND(SPACE_USED_PERCENT,1) FROM V\$RECOVERY_FILE_DEST;" \
2>/dev/null | tr -d ' \t\n')
if [ -n "${FRA_PCT}" ]; then
log " FRA Usage: ${FRA_PCT}%"
# POSIX-portable numeric comparison via awk
FRA_CRIT=$(awk -v v="${FRA_PCT}" 'BEGIN{print (v+0>=85)?1:0}')
FRA_WARN=$(awk -v v="${FRA_PCT}" 'BEGIN{print (v+0>=70)?1:0}')
if [ "${FRA_CRIT}" -eq 1 ]; then print_result FAIL "FRA CRITICAL: ${FRA_PCT}% used"
elif [ "${FRA_WARN}" -eq 1 ]; then print_result WARN "FRA WARNING: ${FRA_PCT}% used"
else print_result PASS "FRA usage OK: ${FRA_PCT}%"
fi
fi
else
print_result WARN "Database is in NOARCHIVELOG mode — point-in-time recovery not possible"
fi

# =======================================================================
# SECTION 7 — SGA / MEMORY
# =======================================================================
print_header "7. SGA / MEMORY CONFIGURATION"

run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL COMPONENT FORMAT A38
COL CURRENT_MB FORMAT 99999
COL MIN_MB FORMAT 99999
COL MAX_MB FORMAT 99999
COL GRANULE_MB FORMAT 99.9
COL LAST_OPER_TYPE FORMAT A15" \
"SELECT COMPONENT,
ROUND(CURRENT_SIZE/1024/1024,0) CURRENT_MB,
ROUND(MIN_SIZE/1024/1024,0) MIN_MB,
ROUND(MAX_SIZE/1024/1024,0) MAX_MB,
ROUND(GRANULE_SIZE/1024/1024,1) GRANULE_MB,
LAST_OPER_TYPE
FROM V\$SGA_DYNAMIC_COMPONENTS
WHERE CURRENT_SIZE > 0
ORDER BY CURRENT_SIZE DESC;"

SGA_SIZE=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT ROUND(SUM(VALUE)/1024/1024,0)||' MB' FROM V\$SGA;" \
2>/dev/null | tr -d '\t\n')
PGA_SIZE=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT ROUND(VALUE/1024/1024,0)||' MB' FROM V\$PGASTAT WHERE NAME='maximum PGA allocated';" \
2>/dev/null | tr -d '\t\n')
log " Total SGA Allocated : ${SGA_SIZE}"
log " Max PGA Allocated : ${PGA_SIZE}"

BHR=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT ROUND((1-(p.VALUE/(NULLIF(b.VALUE+c.VALUE+p.VALUE,0))))*100,2)
FROM V\$SYSSTAT p, V\$SYSSTAT b, V\$SYSSTAT c
WHERE p.NAME='physical reads'
AND b.NAME='db block gets'
AND c.NAME='consistent gets';" \
2>/dev/null | tr -d ' \t\n')
log " Buffer Cache Hit Ratio: ${BHR}%"
BHR_OK=$(awk -v v="${BHR:-0}" 'BEGIN{print (v+0>=90)?1:0}')
if [ "${BHR_OK}" -eq 1 ]; then
print_result PASS "Buffer Cache Hit Ratio: ${BHR}% (>=90%)"
else
print_result WARN "Buffer Cache Hit Ratio: ${BHR}% (below 90% threshold)"
fi

# =======================================================================
# SECTION 8 — RMAN BACKUP
# =======================================================================
print_header "8. RMAN BACKUP STATUS"

log " RMAN Jobs — Last 7 Days:"
run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL SESSION_KEY FORMAT 9999999
COL INPUT_TYPE FORMAT A22
COL STATUS FORMAT A12
COL START_TIME FORMAT A18
COL END_TIME FORMAT A18
COL ELAPSED_MIN FORMAT 9999.9" \
"SELECT SESSION_KEY,
INPUT_TYPE,
STATUS,
TO_CHAR(START_TIME,'YYYY-MM-DD HH24:MI') START_TIME,
TO_CHAR(END_TIME, 'YYYY-MM-DD HH24:MI') END_TIME,
ROUND(ELAPSED_SECONDS/60,1) ELAPSED_MIN
FROM V\$RMAN_BACKUP_JOB_DETAILS
WHERE START_TIME > SYSDATE - 7
ORDER BY START_TIME DESC
FETCH FIRST 20 ROWS ONLY;"

FAILED_BK=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$RMAN_BACKUP_JOB_DETAILS
WHERE STATUS NOT IN ('COMPLETED','COMPLETED WITH WARNINGS')
AND START_TIME > SYSDATE - 7;" \
2>/dev/null | tr -d ' \t\n')
LAST_FULL=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT TO_CHAR(MAX(END_TIME),'YYYY-MM-DD HH24:MI:SS')
FROM V\$RMAN_BACKUP_JOB_DETAILS
WHERE INPUT_TYPE LIKE 'DB FULL%' AND STATUS='COMPLETED';" \
2>/dev/null | tr -d '\t\n')

log " Last successful full backup: ${LAST_FULL:-NONE FOUND}"
if [ "${FAILED_BK:-0}" -gt 0 ]; then
print_result FAIL "${FAILED_BK} failed/incomplete RMAN job(s) in last 7 days"
else
print_result PASS "No failed RMAN jobs in last 7 days"
fi

# =======================================================================
# SECTION 9 — ALERT LOG ERRORS
# =======================================================================
print_header "9. ALERT LOG — ERRORS (Last 5000 Lines)"

DIAG_DEST=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT VALUE FROM V\$DIAG_INFO WHERE NAME='Diag Trace';" \
2>/dev/null | tr -d ' \t\n')
ALERT_LOG="${DIAG_DEST}/alert_${ORACLE_SID}.log"
log " Alert Log Path: ${ALERT_LOG}"

if [ -f "${ALERT_LOG}" ]; then
ORA_COUNT=$(tail -5000 "${ALERT_LOG}" 2>/dev/null | grep -c "ORA-" || true)
log " ORA- error count (last 5000 lines): ${ORA_COUNT}"

ALERT_ERRORS=$(tail -5000 "${ALERT_LOG}" 2>/dev/null \
| grep -i "ORA-\|FATAL\|error" | grep -v "^$" | head -40)
if [ -n "${ALERT_ERRORS}" ]; then
print_result WARN "Errors found in alert log — top 40 shown:"
printf "%s\n" "${ALERT_ERRORS}" | while IFS= read -r aline; do
log " ${aline}"
done
else
print_result PASS "No ORA-/FATAL errors in last 5000 lines of alert log"
fi
else
print_result WARN "Alert log not accessible: ${ALERT_LOG}"
fi

# =======================================================================
# SECTION 10 — INVALID OBJECTS
# =======================================================================
print_header "10. INVALID DATABASE OBJECTS"

INVALID_CNT=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_OBJECTS WHERE STATUS='INVALID';" \
2>/dev/null | tr -d ' \t\n')
log " Total invalid objects: ${INVALID_CNT:-0}"

if [ "${INVALID_CNT:-0}" -gt 0 ]; then
print_result WARN "${INVALID_CNT} invalid object(s) — top 50 listed:"
run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL OWNER FORMAT A20
COL OBJECT_NAME FORMAT A35
COL OBJECT_TYPE FORMAT A20
COL LAST_DDL_TIME FORMAT A20" \
"SELECT OWNER, OBJECT_NAME, OBJECT_TYPE,
TO_CHAR(LAST_DDL_TIME,'YYYY-MM-DD HH24:MI') LAST_DDL_TIME
FROM DBA_OBJECTS
WHERE STATUS='INVALID'
ORDER BY OWNER, OBJECT_TYPE, OBJECT_NAME
FETCH FIRST 50 ROWS ONLY;"
else
print_result PASS "No invalid objects found"
fi

# =======================================================================
# SECTION 11 — SESSIONS
# =======================================================================
print_header "11. SESSIONS — BLOCKED & LONG RUNNING"

separator
log " Active Session Summary:"
run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL STATUS FORMAT A12
COL CNT FORMAT 9999" \
"SELECT STATUS, COUNT(*) CNT
FROM V\$SESSION
WHERE TYPE='USER'
GROUP BY STATUS
ORDER BY CNT DESC;"

BLOCKED=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$SESSION WHERE BLOCKING_SESSION IS NOT NULL;" \
2>/dev/null | tr -d ' \t\n')
log " Blocked sessions: ${BLOCKED:-0}"
if [ "${BLOCKED:-0}" -gt 0 ]; then
print_result WARN "${BLOCKED} blocked session(s) found:"
run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL SID FORMAT 9999
COL SERIAL# FORMAT 999999
COL USERNAME FORMAT A15
COL STATUS FORMAT A10
COL BLOCKING_SID FORMAT 9999
COL WAIT_CLASS FORMAT A15
COL EVENT FORMAT A30
COL WAIT_MIN FORMAT 9999.9
COL SQL_ID FORMAT A15" \
"SELECT s.SID, s.SERIAL#, s.USERNAME, s.STATUS,
s.BLOCKING_SESSION BLOCKING_SID,
s.WAIT_CLASS, s.EVENT,
ROUND(s.SECONDS_IN_WAIT/60,1) WAIT_MIN,
s.SQL_ID
FROM V\$SESSION s
WHERE s.BLOCKING_SESSION IS NOT NULL
ORDER BY s.SECONDS_IN_WAIT DESC;"
else
print_result PASS "No blocked sessions"
fi

separator
log " Long Running Operations (>5 minutes):"
LR_COUNT=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$SESSION_LONGOPS
WHERE TIME_REMAINING > 0 AND ELAPSED_SECONDS > 300;" \
2>/dev/null | tr -d ' \t\n')
if [ "${LR_COUNT:-0}" -gt 0 ]; then
print_result WARN "${LR_COUNT} long-running operation(s) active:"
run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL OPNAME FORMAT A25
COL TARGET FORMAT A25
COL PCT_DONE FORMAT 999.9
COL ELAPSED_MIN FORMAT 99999.9
COL REMAIN_MIN FORMAT 99999.9
COL SQL_ID FORMAT A15" \
"SELECT SID, SERIAL#, OPNAME, TARGET,
ROUND(SOFAR/NULLIF(TOTALWORK,0)*100,1) PCT_DONE,
ROUND(ELAPSED_SECONDS/60,1) ELAPSED_MIN,
ROUND(TIME_REMAINING/60,1) REMAIN_MIN,
SQL_ID
FROM V\$SESSION_LONGOPS
WHERE TIME_REMAINING > 0 AND ELAPSED_SECONDS > 300
ORDER BY ELAPSED_SECONDS DESC;"
else
print_result PASS "No long-running operations (>5 min)"
fi

# =======================================================================
# SECTION 12 — TOP WAIT EVENTS
# =======================================================================
print_header "12. TOP WAIT EVENTS"

run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL EVENT FORMAT A40
COL TOTAL_WAITS FORMAT 9999999999
COL TIME_WAITED_S FORMAT 999999.99
COL AVG_WAIT_MS FORMAT 99999.99" \
"SELECT EVENT,
TOTAL_WAITS,
ROUND(TIME_WAITED_MICRO/1000000,2) TIME_WAITED_S,
ROUND(AVERAGE_WAIT_MICRO/1000,2) AVG_WAIT_MS
FROM V\$SYSTEM_EVENT
WHERE WAIT_CLASS != 'Idle'
AND TOTAL_WAITS > 0
ORDER BY TIME_WAITED_MICRO DESC
FETCH FIRST 15 ROWS ONLY;"

# =======================================================================
# SECTION 13 — DATA GUARD
# =======================================================================
print_header "13. DATA GUARD STATUS"

DG_COUNT=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$DATAGUARD_CONFIG;" 2>/dev/null | tr -d ' \t\n')
if [ "${DG_COUNT:-0}" -gt 0 ] 2>/dev/null; then
run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL DB_UNIQUE_NAME FORMAT A25
COL ROLE FORMAT A20
COL DEST_ID FORMAT 9
COL STATUS FORMAT A15" \
"SELECT DB_UNIQUE_NAME, ROLE, DEST_ID, STATUS
FROM V\$DATAGUARD_CONFIG;"

MRP_STATUS=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT STATUS FROM V\$MANAGED_STANDBY WHERE PROCESS='MRP0';" \
2>/dev/null | tr -d ' \t\n')
if [ -n "${MRP_STATUS}" ]; then
log " MRP0 Status: ${MRP_STATUS}"
[ "${MRP_STATUS}" = "APPLYING_LOG" ] && print_result PASS "MRP0 actively applying redo logs"
fi
LOG_GAP=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT VALUE FROM V\$DATAGUARD_STATS WHERE NAME='apply lag';" \
2>/dev/null | tr -d '\t\n')
[ -n "${LOG_GAP}" ] && log " Apply Lag: ${LOG_GAP}"
else
print_result INFO "Data Guard not configured"
fi

# =======================================================================
# SECTION 14 — TABLESPACE FRAGMENTATION
# =======================================================================
print_header "14. TABLESPACE FRAGMENTATION"

run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL TABLESPACE_NAME FORMAT A30
COL FREE_CHUNKS FORMAT 99999
COL LARGEST_FREE_MB FORMAT 99999.99
COL TOTAL_FREE_MB FORMAT 99999.99" \
"SELECT TABLESPACE_NAME,
COUNT(*) FREE_CHUNKS,
ROUND(MAX(BYTES)/1024/1024,2) LARGEST_FREE_MB,
ROUND(SUM(BYTES)/1024/1024,2) TOTAL_FREE_MB
FROM DBA_FREE_SPACE
GROUP BY TABLESPACE_NAME
HAVING COUNT(*) > 5
ORDER BY FREE_CHUNKS DESC
FETCH FIRST 10 ROWS ONLY;"

# =======================================================================
# SECTION 15 — USER ACCOUNT STATUS
# =======================================================================
print_header "15. DATABASE USER ACCOUNT STATUS"

run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL USERNAME FORMAT A25
COL ACCOUNT_STATUS FORMAT A20
COL EXPIRY_DATE FORMAT A20
COL PROFILE FORMAT A15
COL DEFAULT_TABLESPACE FORMAT A20" \
"SELECT USERNAME, ACCOUNT_STATUS,
TO_CHAR(EXPIRY_DATE,'YYYY-MM-DD') EXPIRY_DATE,
PROFILE, DEFAULT_TABLESPACE
FROM DBA_USERS
WHERE ACCOUNT_STATUS != 'OPEN'
AND USERNAME NOT IN (
'SYS','SYSTEM','DBSNMP','SYSMAN','OUTLN','ORACLE_OCM',
'ANONYMOUS','XDB','XS\$NULL','GSMADMIN_INTERNAL',
'GSMCATUSER','GSMROOTUSER','DBSFWUSER','SYSBACKUP',
'SYSDG','SYSKM','SYSRAC','AUDSYS','APPQOSSYS',
'OJVMSYS','DVSYS','DVF','LBACSYS','ORDDATA',
'SI_INFORMTN_SCHEMA','ORDPLUGINS','ORDSYS','MDSYS',
'WMSYS','CTXSYS','OLAPSYS','MDDATA','SPATIAL_CSW_ADMIN_USR',
'SPATIAL_WFS_ADMIN_USR','FLOWS_FILES','APEX_PUBLIC_USER')
ORDER BY ACCOUNT_STATUS, USERNAME;"

LOCKED_CNT=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_USERS
WHERE ACCOUNT_STATUS LIKE '%LOCKED%'
AND USERNAME NOT IN ('SYS','SYSTEM','DBSNMP','OUTLN','ORACLE_OCM',
'ANONYMOUS','XDB','XS\$NULL','GSMADMIN_INTERNAL','AUDSYS',
'GSMCATUSER','GSMROOTUSER','DBSFWUSER','SYSBACKUP',
'SYSDG','SYSKM','SYSRAC','APPQOSSYS','OJVMSYS');" \
2>/dev/null | tr -d ' \t\n')
EXPIRED_CNT=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_USERS WHERE ACCOUNT_STATUS='EXPIRED';" \
2>/dev/null | tr -d ' \t\n')

[ "${LOCKED_CNT:-0}" -gt 0 ] && print_result WARN "${LOCKED_CNT} non-system user(s) locked"
[ "${EXPIRED_CNT:-0}" -gt 0 ] && print_result WARN "${EXPIRED_CNT} user account(s) expired"
[ "${LOCKED_CNT:-0}" -eq 0 ] && [ "${EXPIRED_CNT:-0}" -eq 0 ] && \
print_result PASS "All non-system user accounts are in normal status"

# =======================================================================
# SECTION 16 — ASM DISK GROUPS
# =======================================================================
print_header "16. ASM DISK GROUP STATUS"

ASM_CNT=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$ASM_DISKGROUP;" 2>/dev/null | tr -d ' \t\n')
if [ "${ASM_CNT:-0}" -gt 0 ] 2>/dev/null; then
run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL NAME FORMAT A20
COL STATE FORMAT A12
COL TYPE FORMAT A8
COL TOTAL_GB FORMAT 99999.99
COL FREE_GB FORMAT 99999.99
COL PCT_USED FORMAT 999.9" \
"SELECT NAME, STATE, TYPE,
ROUND(TOTAL_MB/1024,2) TOTAL_GB,
ROUND(FREE_MB/1024,2) FREE_GB,
ROUND((1-FREE_MB/NULLIF(TOTAL_MB,0))*100,1) PCT_USED
FROM V\$ASM_DISKGROUP
ORDER BY NAME;"

ASM_CRIT=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$ASM_DISKGROUP
WHERE ROUND((1-FREE_MB/NULLIF(TOTAL_MB,0))*100,1)>=85;" \
2>/dev/null | tr -d ' \t\n')
if [ "${ASM_CRIT:-0}" -gt 0 ]; then
print_result FAIL "${ASM_CRIT} ASM disk group(s) >= 85% full"
else
print_result PASS "ASM disk groups within acceptable usage"
fi
else
print_result INFO "ASM not configured / V\$ASM_DISKGROUP not accessible from this instance"
fi

# =======================================================================
# SECTION 17 — SCHEDULER FAILED JOBS
# =======================================================================
print_header "17. DBMS_SCHEDULER FAILED JOBS (Last 7 Days)"

SCHED_FAIL=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_SCHEDULER_JOB_RUN_DETAILS
WHERE STATUS='FAILED' AND ACTUAL_START_DATE > SYSTIMESTAMP - 7;" \
2>/dev/null | tr -d ' \t\n')
log " Failed scheduler jobs (last 7 days): ${SCHED_FAIL:-0}"

if [ "${SCHED_FAIL:-0}" -gt 0 ]; then
print_result WARN "${SCHED_FAIL} failed scheduler job run(s):"
run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL OWNER FORMAT A15
COL JOB_NAME FORMAT A30
COL START_TIME FORMAT A18
COL STATUS FORMAT A10
COL ADDITIONAL_INFO FORMAT A50" \
"SELECT OWNER, JOB_NAME,
TO_CHAR(ACTUAL_START_DATE,'YYYY-MM-DD HH24:MI') START_TIME,
STATUS, SUBSTR(ADDITIONAL_INFO,1,50) ADDITIONAL_INFO
FROM DBA_SCHEDULER_JOB_RUN_DETAILS
WHERE STATUS='FAILED'
AND ACTUAL_START_DATE > SYSTIMESTAMP - 7
ORDER BY ACTUAL_START_DATE DESC
FETCH FIRST 20 ROWS ONLY;"
else
print_result PASS "No failed scheduler jobs in last 7 days"
fi

# =======================================================================
# SECTION 18 — KEY PERFORMANCE INDICATORS
# =======================================================================
print_header "18. KEY PERFORMANCE INDICATORS"

log " Top 10 SQL by Total Elapsed Time:"
run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL ELAPSED_S FORMAT 9999999.99
COL EXECUTIONS FORMAT 9999999
COL ELAPSED_PER_EXEC_S FORMAT 9999.9999
COL SQL_ID FORMAT A15
COL SQL_SNIPPET FORMAT A70" \
"SELECT ROUND(ELAPSED_TIME/1000000,2) ELAPSED_S,
EXECUTIONS,
ROUND(ELAPSED_TIME/NULLIF(EXECUTIONS,0)/1000000,4) ELAPSED_PER_EXEC_S,
SQL_ID,
SUBSTR(SQL_TEXT,1,70) SQL_SNIPPET
FROM V\$SQLAREA
WHERE ELAPSED_TIME > 0
ORDER BY ELAPSED_TIME DESC
FETCH FIRST 10 ROWS ONLY;"

separator
log " System Statistics Snapshot:"
run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL NAME FORMAT A35
COL VALUE FORMAT 9999999999999" \
"SELECT NAME, ROUND(VALUE,0) VALUE
FROM V\$SYSSTAT
WHERE NAME IN ('user calls','user commits','user rollbacks',
'parse count (hard)','parse count (total)',
'physical reads','physical writes',
'redo writes','redo size')
ORDER BY NAME;"

# =======================================================================
# SECTION 19 — PATCH LEVEL
# =======================================================================
print_header "19. PATCH INFORMATION"

run_sql_table "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL PATCH_ID FORMAT 9999999999
COL PATCH_UID FORMAT 9999999999
COL VERSION FORMAT A12
COL ACTION FORMAT A10
COL STATUS FORMAT A10
COL APPLIED_TIME FORMAT A18
COL DESCRIPTION FORMAT A55" \
"SELECT PATCH_ID, PATCH_UID, VERSION, ACTION, STATUS,
TO_CHAR(ACTION_TIME,'YYYY-MM-DD HH24:MI') APPLIED_TIME,
SUBSTR(DESCRIPTION,1,55) DESCRIPTION
FROM DBA_REGISTRY_SQLPATCH
ORDER BY ACTION_TIME DESC
FETCH FIRST 10 ROWS ONLY;"

# =======================================================================
# PER-DB SUMMARY
# =======================================================================
print_header "HEALTH CHECK SUMMARY — ${ORACLE_SID}"

END_TIME=$(date "+%Y-%m-%d %H:%M:%S")
log ""
log " SID : ${ORACLE_SID}"
log " ORACLE_HOME : ${ORACLE_HOME}"
log " Completed : ${END_TIME}"
log " Log File : ${LOG_FILE}"
log ""
log " Total FAIL (Critical) : ${ISSUES}"
log " Total WARN (Warning) : ${WARNINGS}"
log ""

if [ "${ISSUES}" -gt 0 ]; then
print_result FAIL "${ORACLE_SID} — ${ISSUES} CRITICAL issue(s), ${WARNINGS} warning(s)"
elif [ "${WARNINGS}" -gt 0 ]; then
print_result WARN "${ORACLE_SID} — ${WARNINGS} warning(s) — review recommended"
else
print_result PASS "${ORACLE_SID} — all checks PASSED"
fi
log ""

# Write per-DB summary file
{
printf "Oracle 19c Health Check Summary\n"
printf "SID : %s\n" "${ORACLE_SID}"
printf "ORACLE_HOME : %s\n" "${ORACLE_HOME}"
printf "Host : %s\n" "$(uname -n)"
printf "Completed : %s\n" "${END_TIME}"
printf "CRITICAL : %s\n" "${ISSUES}"
printf "WARNINGS : %s\n" "${WARNINGS}"
printf "Log File : %s\n" "${LOG_FILE}"
} > "${SUMMARY_FILE}"

# Accumulate into master counters
MASTER_ISSUES=$((MASTER_ISSUES + ISSUES))
MASTER_WARNINGS=$((MASTER_WARNINGS + WARNINGS))

# Optional email alert per DB
if [ -n "${ALERT_EMAIL}" ] && [ "${ISSUES}" -gt 0 ]; then
if command -v mailx >/dev/null 2>&1; then
mailx -s "[ALERT] Oracle HC ${ORACLE_SID} on $(uname -n) — ${ISSUES} CRITICAL" \
"${ALERT_EMAIL}" < "${SUMMARY_FILE}"
fi
fi
}

# ===========================================================================
# MAIN — discover SIDs, resolve homes, iterate
# ===========================================================================
ensure_log_dir
setup_colours
locate_oratab

# Discover all running non-excluded SIDs
SID_LIST=$(discover_sids)

if [ -z "${SID_LIST}" ]; then
printf "${C_RED}ERROR: No eligible Oracle PMON processes found on this host.${C_RESET}\n"
printf " Excluded patterns: +ASM* , *APX* , *MGMT*\n"
exit 1
fi

# Show startup banner
printf "\n${C_BOLD}${C_CYAN}"
printf "╔══════════════════════════════════════════════════════════════════╗\n"
printf "║ Oracle 19c Multi-Instance Health Check ║\n"
printf "║ Host : %-48s║\n" "$(uname -n)"
printf "║ OS : %-48s║\n" "$(uname -s) $(uname -r)"
printf "║ oratab : %-48s║\n" "${ORATAB}"
printf "║ Time : %-48s║\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "╚══════════════════════════════════════════════════════════════════╝\n"
printf "${C_RESET}\n"

printf "${C_BOLD} Discovered SIDs to check:${C_RESET}\n"
printf "%s\n" "${SID_LIST}" | while IFS= read -r s; do
printf " ${C_CYAN}► %s${C_RESET}\n" "${s}"
done
printf "\n"

# ---------------------------------------------------------------------------
# LOOP THROUGH EACH SID
# ---------------------------------------------------------------------------
printf "%s\n" "${SID_LIST}" | while IFS= read -r SID; do

[ -z "${SID}" ] && continue

# Resolve ORACLE_HOME from oratab
OH=$(get_oracle_home "${SID}")

if [ -z "${OH}" ]; then
printf "${C_YELLOW} [WARN]${C_RESET} SID '%s' not found in %s — skipping\n" \
"${SID}" "${ORATAB}" | tee -a "${MASTER_LOG}"
continue
fi

if [ ! -d "${OH}" ]; then
printf "${C_RED} [FAIL]${C_RESET} ORACLE_HOME '%s' for SID '%s' does not exist — skipping\n" \
"${OH}" "${SID}" | tee -a "${MASTER_LOG}"
continue
fi

printf "${C_BOLD}${C_MAGENTA} ┌─ Starting health check for SID: %s${C_RESET}\n" "${SID}"
printf "${C_BOLD}${C_MAGENTA} └─ ORACLE_HOME: %s${C_RESET}\n\n" "${OH}"

run_healthcheck "${SID}" "${OH}"

done

# ---------------------------------------------------------------------------
# MASTER SUMMARY
# ---------------------------------------------------------------------------
printf "\n${C_BOLD}${C_CYAN}"
printf "╔══════════════════════════════════════════════════════════════════╗\n"
printf "║ MASTER RUN SUMMARY ║\n"
printf "╚══════════════════════════════════════════════════════════════════╝\n"
printf "${C_RESET}\n"

{
printf "================================================================\n"
printf " MASTER HEALTH CHECK SUMMARY\n"
printf " Host : %s\n" "$(uname -n)"
printf " OS : %s %s\n" "$(uname -s)" "$(uname -r)"
printf " oratab : %s\n" "${ORATAB}"
printf " Completed : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf " SIDs run :\n"
printf "%s\n" "${SID_LIST}" | while IFS= read -r s; do
OH2=$(get_oracle_home "${s}")
printf " %-20s -> %s\n" "${s}" "${OH2:-NOT IN ORATAB}"
done
printf " Log Dir : %s\n" "${LOG_DIR}"
printf "================================================================\n"
} | tee -a "${MASTER_LOG}"

printf " Databases checked : %s\n" "$(printf '%s\n' "${SID_LIST}" | wc -l | tr -d ' \t')" \
| tee -a "${MASTER_LOG}"
printf " Total CRITICAL : %s\n" "${MASTER_ISSUES}" | tee -a "${MASTER_LOG}"
printf " Total WARNINGS : %s\n" "${MASTER_WARNINGS}" | tee -a "${MASTER_LOG}"
printf " Master log : %s\n" "${MASTER_LOG}" | tee -a "${MASTER_LOG}"
printf "\n"

if [ "${MASTER_ISSUES}" -gt 0 ]; then
printf " %b Master result: %s CRITICAL issue(s) across all instances\n" \
"${FAIL}" "${MASTER_ISSUES}" | tee -a "${MASTER_LOG}"
elif [ "${MASTER_WARNINGS}" -gt 0 ]; then
printf " %b Master result: %s warning(s) — review recommended\n" \
"${WARN}" "${MASTER_WARNINGS}" | tee -a "${MASTER_LOG}"
else
printf " %b Master result: all instances PASSED\n" \
"${PASS}" | tee -a "${MASTER_LOG}"
fi
printf "\n"

exit ${MASTER_ISSUES}
ENDOFSCRIPT
echo "Exit: $?"
