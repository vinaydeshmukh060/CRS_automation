#!/bin/bash
# =============================================================================
# Script   : ora_rac_baseline_monitor.sh
# Purpose  : Proactive & Predictive Baseline Monitoring for Oracle RAC
# Author   : DBA / DRE Toolkit
# Version  : 2.0
# Platform : Linux / Solaris (POSIX-compatible)
#
# Description:
#   Runs once daily via cron. Connects to the target Oracle RAC database,
#   extracts performance, capacity and storage metrics from GV$ views,
#   appends results to a CSV baseline file, generates an HTML report,
#   and optionally emails the report.
#
# Usage:
#   ora_rac_baseline_monitor.sh -s <SID> [-d <date_override>] [-e <email>] [-n]
#
#   -s  Oracle SID (required) — used to locate ORACLE_HOME from /etc/oratab
#   -d  Date override in YYYY-MM-DD format (optional, defaults to today)
#   -e  Email recipient(s) comma-separated (optional, overrides config)
#   -n  No-email flag — skip email even if EMAIL_TO is configured
#
# Cron example (daily at 06:00):
#   0 6 * * * /opt/dba/scripts/ora_rac_baseline_monitor.sh -s MYRACDB -e dba@company.com
# =============================================================================

# =============================================================================
# SECTION 1: CUSTOMISABLE CONFIGURATION
# =============================================================================

# --- Directory locations ------------------------------------------------------
BASE_DIR="/opt/dba/oracle_baseline"          # Root directory for all output
LOG_DIR="${BASE_DIR}/logs"                    # Script execution logs
CSV_DIR="${BASE_DIR}/csv"                     # Appendable CSV baseline files
HTML_DIR="${BASE_DIR}/html"                   # Generated HTML reports
ARCHIVE_DIR="${BASE_DIR}/archive"             # HTML reports older than ARCHIVE_DAYS

# --- Retention ----------------------------------------------------------------
ARCHIVE_DAYS=30                              # Days before HTML reports are archived
LOG_RETAIN_DAYS=60                           # Days to keep script log files

# --- Oracle connectivity ------------------------------------------------------
ORATAB="/etc/oratab"                         # Default oratab location
DB_USER="/ as sysdba"                        # Connect string (sysdba for GV$ access)
# Alternatively: DB_USER="monitor_user/password@${ORACLE_SID}"

# --- Email configuration ------------------------------------------------------
EMAIL_TO=""                                  # Default recipient(s); overridden by -e
EMAIL_FROM="oracle-dba-monitor@company.com"
EMAIL_SUBJECT_PREFIX="[ORA-RAC Monitor]"
SENDMAIL_BIN="/usr/sbin/sendmail"            # Path to sendmail binary
# Set MAIL_METHOD to "sendmail" or "mailx"
MAIL_METHOD="sendmail"

# --- Thresholds for HTML report colour coding ---------------------------------
TABLESPACE_WARN_PCT=75                       # Yellow warning threshold (%)
TABLESPACE_CRIT_PCT=90                       # Red critical threshold (%)
SESSION_WARN_PCT=70
SESSION_CRIT_PCT=85
PGA_WARN_MB=8192                             # PGA total warn threshold (MB)
PGA_CRIT_MB=16384                            # PGA total critical threshold (MB)

# =============================================================================
# SECTION 2: ARGUMENT PARSING & INITIALISATION
# =============================================================================

SNAPSHOT_DATE=$(date +%Y-%m-%d)
SKIP_EMAIL=0
ORA_SID=""
EMAIL_OVERRIDE=""

usage() {
    echo "Usage: $0 -s <SID> [-d YYYY-MM-DD] [-e email1,email2] [-n]"
    exit 1
}

while getopts "s:d:e:nh" opt; do
    case $opt in
        s) ORA_SID="$OPTARG" ;;
        d) SNAPSHOT_DATE="$OPTARG" ;;
        e) EMAIL_OVERRIDE="$OPTARG" ;;
        n) SKIP_EMAIL=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

[ -z "$ORA_SID" ] && { echo "ERROR: Oracle SID (-s) is required."; usage; }

# Apply email override
[ -n "$EMAIL_OVERRIDE" ] && EMAIL_TO="$EMAIL_OVERRIDE"

# --- Create directories -------------------------------------------------------
for dir in "$LOG_DIR" "$CSV_DIR" "$HTML_DIR" "$ARCHIVE_DIR"; do
    mkdir -p "$dir" || { echo "FATAL: Cannot create directory $dir"; exit 1; }
done

# --- Log file -----------------------------------------------------------------
LOG_FILE="${LOG_DIR}/baseline_${ORA_SID}_${SNAPSHOT_DATE}.log"
exec >> "$LOG_FILE" 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "============================================================"
log "Oracle RAC Baseline Monitor v2.0 — Starting"
log "SID: ${ORA_SID} | Snapshot Date: ${SNAPSHOT_DATE}"
log "============================================================"

# =============================================================================
# SECTION 3: ORACLE ENVIRONMENT SETUP (from oratab)
# =============================================================================

# Detect OS for oratab parsing differences
OS_TYPE=$(uname -s)
log "Detected OS: ${OS_TYPE}"

locate_oratab() {
    # Solaris stores oratab in /var/opt/oracle
    if [ "$OS_TYPE" = "SunOS" ]; then
        [ -f "/var/opt/oracle/oratab" ] && ORATAB="/var/opt/oracle/oratab" || ORATAB="/etc/oratab"
    fi
    log "Using oratab: ${ORATAB}"
}

locate_oratab

# Parse oratab to find ORACLE_HOME for the given SID
# oratab format: SID:ORACLE_HOME:Y|N
# Supports wildcards like *:/oracle/product/19c:N
parse_oratab() {
    local sid="$1"
    local ohome=""
    while IFS=: read -r entry_sid entry_home entry_start; do
        # Skip comments and blank lines
        case "$entry_sid" in
            \#*|"") continue ;;
        esac
        if [ "$entry_sid" = "$sid" ]; then
            ohome="$entry_home"
            break
        fi
    done < "$ORATAB"
    echo "$ohome"
}

ORACLE_HOME=$(parse_oratab "$ORA_SID")

if [ -z "$ORACLE_HOME" ] || [ ! -d "$ORACLE_HOME" ]; then
    log "ERROR: Cannot determine ORACLE_HOME for SID '${ORA_SID}' from ${ORATAB}"
    log "Please ensure the SID is registered in oratab."
    exit 1
fi

export ORACLE_HOME
export ORACLE_SID="$ORA_SID"
export PATH="${ORACLE_HOME}/bin:${PATH}"

# Solaris requires explicit LD_LIBRARY_PATH
if [ "$OS_TYPE" = "SunOS" ]; then
    export LD_LIBRARY_PATH="${ORACLE_HOME}/lib:${LD_LIBRARY_PATH}"
else
    export LD_LIBRARY_PATH="${ORACLE_HOME}/lib:${LD_LIBRARY_PATH}"
fi

log "ORACLE_HOME: ${ORACLE_HOME}"
log "ORACLE_SID : ${ORACLE_SID}"

# Verify sqlplus exists
SQLPLUS="${ORACLE_HOME}/bin/sqlplus"
[ ! -x "$SQLPLUS" ] && { log "ERROR: sqlplus not found at ${SQLPLUS}"; exit 1; }

# =============================================================================
# SECTION 4: FILE PATHS
# =============================================================================

CSV_FILE="${CSV_DIR}/oracle_rac_baseline_${ORA_SID}.csv"
HTML_FILE="${HTML_DIR}/oracle_rac_report_${ORA_SID}_${SNAPSHOT_DATE}.html"
SQL_TMPFILE="/tmp/ora_baseline_$$.sql"
CSV_TMPFILE="/tmp/ora_baseline_csv_$$.tmp"

# Write CSV header if file is new
if [ ! -f "$CSV_FILE" ]; then
    echo "SNAPSHOT_DATE,INST_ID,METRIC_CATEGORY,METRIC_NAME,METRIC_VALUE" > "$CSV_FILE"
    log "Created new CSV baseline file: ${CSV_FILE}"
fi

# =============================================================================
# SECTION 5: SQL EXTRACTION — BUILD SQL SCRIPT
# =============================================================================

log "Building SQL extraction script..."

cat > "$SQL_TMPFILE" << 'ENDSQL'
-- ============================================================
-- Oracle RAC Baseline Metrics Extraction
-- Outputs clean CSV: SNAPSHOT_DATE,INST_ID,METRIC_CATEGORY,METRIC_NAME,METRIC_VALUE
-- ============================================================
SET PAGESIZE 0
SET FEEDBACK OFF
SET VERIFY OFF
SET HEADING OFF
SET TRIMSPOOL ON
SET LINESIZE 500
SET TERMOUT OFF
SET ECHO OFF
SET SQLPROMPT ""
WHENEVER SQLERROR CONTINUE

-- Use bind variable for consistent snapshot date across all queries
VARIABLE snap_date VARCHAR2(10)
BEGIN
  :snap_date := TO_CHAR(SYSDATE, 'YYYY-MM-DD');
END;
/

-- ============================================================
-- 1. WAIT EVENTS — Cumulative time by wait class (GV$SYSTEM_EVENT)
--    These are cumulative since instance startup → use daily delta to trend
-- ============================================================
SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'WAIT_EVENTS' || ',' ||
       'WAIT_CLASS_' || REPLACE(UPPER(wait_class), ' ', '_') || '_TIME_SECS' || ',' ||
       ROUND(SUM(time_waited) / 100, 2)
FROM   gv$system_event
WHERE  wait_class IN ('Cluster','User I/O','System I/O','Concurrency','Other','Application')
GROUP  BY inst_id, wait_class
ORDER  BY inst_id, wait_class
/

-- Cumulative wait counts per class
SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'WAIT_EVENTS' || ',' ||
       'WAIT_CLASS_' || REPLACE(UPPER(wait_class), ' ', '_') || '_TOTAL_WAITS' || ',' ||
       SUM(total_waits)
FROM   gv$system_event
WHERE  wait_class IN ('Cluster','User I/O','System I/O','Concurrency','Other','Application')
GROUP  BY inst_id, wait_class
ORDER  BY inst_id, wait_class
/

-- Top 10 individual wait events by time waited per instance
SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'TOP_WAIT_EVENTS' || ',' ||
       'EVENT_' || REPLACE(REPLACE(UPPER(event), ' ', '_'), '/', '_') || '_TIME_SECS' || ',' ||
       ROUND(time_waited / 100, 2)
FROM (
  SELECT inst_id, event, time_waited,
         ROW_NUMBER() OVER (PARTITION BY inst_id ORDER BY time_waited DESC) rn
  FROM   gv$system_event
  WHERE  wait_class NOT IN ('Idle')
)
WHERE rn <= 10
ORDER BY inst_id, time_waited DESC
/

-- ============================================================
-- 2. SYSTEM STATISTICS — Key workload counters (GV$SYSSTAT)
--    Cumulative since startup → trend via daily delta
-- ============================================================
SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'SYS_STATS'  || ',' ||
       REPLACE(REPLACE(UPPER(name), ' ', '_'), '/', '_') || ',' ||
       value
FROM   gv$sysstat
WHERE  name IN (
         'execute count',
         'user calls',
         'user commits',
         'user rollbacks',
         'physical reads',
         'physical writes',
         'physical read total bytes',
         'physical write total bytes',
         'redo size',
         'db block gets',
         'consistent gets',
         'CPU used by this session',
         'parse count (total)',
         'parse count (hard)',
         'sorts (memory)',
         'sorts (disk)',
         'table scans (long tables)',
         'gc cr blocks received',
         'gc current blocks received'
       )
ORDER  BY inst_id, name
/

-- ============================================================
-- 3. MEMORY — SGA Component breakdown (GV$SGASTAT)
--    Point-in-time snapshot — monitor trend directly
-- ============================================================
SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'MEMORY_SGA' || ',' ||
       'SGA_' || REPLACE(REPLACE(UPPER(name), ' ', '_'), '/', '_') || '_MB' || ',' ||
       ROUND(SUM(bytes) / 1048576, 2)
FROM   gv$sgastat
WHERE  name IN ('free memory','db_block_buffers','buffer_cache',
                'log_buffer','fixed_sga','shared pool','large pool',
                'java pool','streams pool')
GROUP  BY inst_id, name
ORDER  BY inst_id, name
/

-- SGA total per instance
SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'MEMORY_SGA' || ',' ||
       'SGA_TOTAL_MB' || ',' ||
       ROUND(SUM(bytes) / 1048576, 2)
FROM   gv$sgastat
GROUP  BY inst_id
ORDER  BY inst_id
/

-- ============================================================
-- 4. MEMORY — PGA statistics (GV$PGASTAT)
--    Point-in-time — monitor aggregate PGA pressure
-- ============================================================
SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'MEMORY_PGA' || ',' ||
       REPLACE(REPLACE(UPPER(name), ' ', '_'), '/', '_') || '_MB' || ',' ||
       ROUND(value / 1048576, 2)
FROM   gv$pgastat
WHERE  name IN (
         'total PGA inuse',
         'total PGA allocated',
         'maximum PGA allocated',
         'total freeable PGA memory',
         'PGA memory freed back to OS',
         'over allocation count'
       )
ORDER  BY inst_id, name
/

-- ============================================================
-- 5. CAPACITY — Sessions and Processes vs limits (GV$RESOURCE_LIMIT)
--    Point-in-time — critical for exhaustion prediction
-- ============================================================
SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'CAPACITY'  || ',' ||
       UPPER(resource_name) || '_CURRENT' || ',' ||
       current_utilization
FROM   gv$resource_limit
WHERE  resource_name IN ('sessions','processes','enqueue_locks',
                         'enqueue_resources','gcs_resources')
ORDER  BY inst_id, resource_name
/

SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'CAPACITY'  || ',' ||
       UPPER(resource_name) || '_MAX_EVER' || ',' ||
       max_utilization
FROM   gv$resource_limit
WHERE  resource_name IN ('sessions','processes','enqueue_locks',
                         'enqueue_resources','gcs_resources')
ORDER  BY inst_id, resource_name
/

SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'CAPACITY'  || ',' ||
       UPPER(resource_name) || '_LIMIT' || ',' ||
       CASE limit_value WHEN 'UNLIMITED' THEN -1 ELSE TO_NUMBER(limit_value) END
FROM   gv$resource_limit
WHERE  resource_name IN ('sessions','processes','enqueue_locks',
                         'enqueue_resources','gcs_resources')
ORDER  BY inst_id, resource_name
/

-- Active sessions by type (point-in-time)
SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'CAPACITY'  || ',' ||
       'ACTIVE_SESSIONS_' || REPLACE(UPPER(status), ' ', '_') || ',' ||
       COUNT(*)
FROM   gv$session
WHERE  type = 'USER'
GROUP  BY inst_id, status
ORDER  BY inst_id, status
/

-- ============================================================
-- 6. STORAGE — Tablespace utilization (point-in-time)
--    Uses DBA_TABLESPACE_USAGE_METRICS + DBA_TABLESPACES
--    Runs from instance 1 perspective (global tablespace data)
-- ============================================================
SELECT :snap_date || ',' ||
       '0'         || ',' ||
       'STORAGE'   || ',' ||
       'TS_' || REPLACE(UPPER(m.tablespace_name), ' ', '_') || '_TOTAL_MB' || ',' ||
       ROUND(m.tablespace_size * t.block_size / 1048576, 2)
FROM   dba_tablespace_usage_metrics m
JOIN   dba_tablespaces t ON t.tablespace_name = m.tablespace_name
ORDER  BY m.tablespace_name
/

SELECT :snap_date || ',' ||
       '0'         || ',' ||
       'STORAGE'   || ',' ||
       'TS_' || REPLACE(UPPER(m.tablespace_name), ' ', '_') || '_USED_MB' || ',' ||
       ROUND(m.used_space * t.block_size / 1048576, 2)
FROM   dba_tablespace_usage_metrics m
JOIN   dba_tablespaces t ON t.tablespace_name = m.tablespace_name
ORDER  BY m.tablespace_name
/

SELECT :snap_date || ',' ||
       '0'         || ',' ||
       'STORAGE'   || ',' ||
       'TS_' || REPLACE(UPPER(m.tablespace_name), ' ', '_') || '_USED_PCT' || ',' ||
       ROUND(m.used_percent, 2)
FROM   dba_tablespace_usage_metrics m
ORDER  BY m.tablespace_name
/

-- ============================================================
-- 7. RAC INTERCONNECT — Cluster cache coherency (GV$CACHE_TRANSFER)
--    Cumulative → trend via daily delta
-- ============================================================
SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'RAC_INTERCONNECT' || ',' ||
       'GC_' || REPLACE(UPPER(class), ' ', '_') || '_BLOCKS_RECEIVED' || ',' ||
       blocks_received
FROM   gv$cache_transfer
ORDER  BY inst_id, class
/

-- GES locking traffic (RAC-specific)
SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'RAC_INTERCONNECT' || ',' ||
       'GES_MSGS_SENT_TOTAL' || ',' ||
       SUM(msgs_sent)
FROM   gv$ges_statistics
GROUP  BY inst_id
ORDER  BY inst_id
/

-- ============================================================
-- 8. REDO LOG — Generation rate (GV$LOG) + archiver status
-- ============================================================
SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'REDO_LOGS' || ',' ||
       'LOG_SWITCHES_TODAY' || ',' ||
       COUNT(*)
FROM   gv$log_history
WHERE  first_time >= TRUNC(SYSDATE)
GROUP  BY inst_id
ORDER  BY inst_id
/

SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'REDO_LOGS' || ',' ||
       'REDO_SIZE_LAST_HOUR_MB' || ',' ||
       ROUND(SUM(blocks * block_size) / 1048576, 2)
FROM   gv$archived_log
WHERE  first_time >= SYSDATE - 1/24
  AND  standby_dest = 'NO'
GROUP  BY inst_id
ORDER  BY inst_id
/

-- ============================================================
-- 9. DB TIME — Overall database load (GV$SYS_TIME_MODEL)
-- ============================================================
SELECT :snap_date || ',' ||
       inst_id    || ',' ||
       'DB_TIME_MODEL' || ',' ||
       REPLACE(REPLACE(UPPER(stat_name), ' ', '_'), '/', '_') || '_USECS' || ',' ||
       value
FROM   gv$sys_time_model
WHERE  stat_name IN (
         'DB time',
         'DB CPU',
         'background cpu time',
         'sequence load elapsed time',
         'parse time elapsed',
         'hard parse elapsed time',
         'PL/SQL execution elapsed time',
         'inbound PL/SQL rpc elapsed time',
         'PL/SQL compilation elapsed time',
         'Java execution elapsed time',
         'connection management call elapsed time'
       )
ORDER  BY inst_id, stat_name
/

EXIT
ENDSQL

# =============================================================================
# SECTION 6: EXECUTE SQL AND CAPTURE CSV OUTPUT
# =============================================================================

log "Connecting to Oracle (${ORA_SID}) and extracting metrics..."

"$SQLPLUS" -S "$DB_USER" < "$SQL_TMPFILE" > "$CSV_TMPFILE" 2>&1
SQL_RC=$?

if [ $SQL_RC -ne 0 ]; then
    log "ERROR: SQL*Plus exited with code ${SQL_RC}. Check log for ORA- errors."
    grep "ORA-\|SP2-\|ERROR" "$CSV_TMPFILE" | head -20 | while IFS= read -r line; do
        log "  SQL ERROR: $line"
    done
    rm -f "$SQL_TMPFILE" "$CSV_TMPFILE"
    exit 1
fi

# Validate output — check for Oracle errors embedded in CSV
if grep -q "ORA-\|SP2-" "$CSV_TMPFILE"; then
    log "WARNING: Oracle errors detected in SQL output (partial data may have been captured):"
    grep "ORA-\|SP2-" "$CSV_TMPFILE" | head -10 | while IFS= read -r line; do
        log "  $line"
    done
fi

# Filter to valid CSV lines only: YYYY-MM-DD,digit(s),...,...,...
VALID_ROWS=0
while IFS= read -r line; do
    # Must match: date,inst_id,category,name,value pattern
    if echo "$line" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2},[0-9]+,[A-Z_]+,[A-Z0-9_./_-]+,[0-9.-]+$'; then
        echo "$line" >> "$CSV_FILE"
        VALID_ROWS=$((VALID_ROWS + 1))
    fi
done < "$CSV_TMPFILE"

log "Appended ${VALID_ROWS} metric rows to ${CSV_FILE}"
rm -f "$SQL_TMPFILE" "$CSV_TMPFILE"

[ $VALID_ROWS -eq 0 ] && { log "ERROR: No valid metric rows extracted. Aborting HTML generation."; exit 1; }

# =============================================================================
# SECTION 7: PARSE TODAY'S CSV DATA FOR HTML REPORT
# =============================================================================

log "Parsing extracted data for HTML report..."

# Helper: extract first value matching category+name pattern for given inst
get_metric() {
    local category="$1" name="$2" inst="$3"
    grep "^${SNAPSHOT_DATE},${inst},${category},${name}," "$CSV_FILE" 2>/dev/null | \
        tail -1 | cut -d',' -f5
}

# Build associative arrays from today's CSV data
# We use temp files for Solaris compat (no associative arrays in sh/ksh88)
TODAY_DATA=$(grep "^${SNAPSHOT_DATE}," "$CSV_FILE")

# Get distinct instance IDs
INST_LIST=$(echo "$TODAY_DATA" | awk -F',' '{print $2}' | sort -un | grep -v '^0$')
log "RAC Instances detected: $(echo $INST_LIST | tr '\n' ' ')"

# Get tablespace data (inst_id=0 = global)
TS_DATA=$(echo "$TODAY_DATA" | grep ",STORAGE," | grep "_USED_PCT,")

# =============================================================================
# SECTION 8: GENERATE HTML REPORT
# =============================================================================

log "Generating HTML report: ${HTML_FILE}"

# Determine overall health colour for subject line
HEALTH_STATUS="HEALTHY"
HEALTH_COLOR="#27ae60"

# Check tablespace thresholds
while IFS=',' read -r snap inst cat name val; do
    pct=$(echo "$val" | awk '{printf "%d", $1}')
    if [ "$pct" -ge "$TABLESPACE_CRIT_PCT" ] 2>/dev/null; then
        HEALTH_STATUS="CRITICAL"
        HEALTH_COLOR="#e74c3c"
        break
    elif [ "$pct" -ge "$TABLESPACE_WARN_PCT" ] 2>/dev/null; then
        [ "$HEALTH_STATUS" != "CRITICAL" ] && HEALTH_STATUS="WARNING" && HEALTH_COLOR="#f39c12"
    fi
done << EOF
$(echo "$TS_DATA")
EOF

# ---- Begin HTML ----------------------------------------------------------
cat > "$HTML_FILE" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Oracle RAC Baseline Report — ${ORA_SID} — ${SNAPSHOT_DATE}</title>
<style>
  /* ---- Reset & Base ---- */
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
    background: #0f1117;
    color: #e2e8f0;
    font-size: 14px;
    line-height: 1.5;
  }
  a { color: #63b3ed; }

  /* ---- Layout ---- */
  .wrapper { max-width: 1400px; margin: 0 auto; padding: 20px; }

  /* ---- Header ---- */
  .header {
    background: linear-gradient(135deg, #1a202c 0%, #2d3748 100%);
    border-left: 5px solid ${HEALTH_COLOR};
    border-radius: 8px;
    padding: 24px 28px;
    margin-bottom: 24px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 12px;
  }
  .header h1 { font-size: 22px; font-weight: 700; color: #f7fafc; }
  .header h1 span { color: #63b3ed; }
  .header .meta { color: #a0aec0; font-size: 13px; margin-top: 4px; }
  .status-badge {
    background: ${HEALTH_COLOR};
    color: #fff;
    font-weight: 700;
    font-size: 13px;
    padding: 6px 18px;
    border-radius: 20px;
    letter-spacing: 1px;
    text-transform: uppercase;
  }

  /* ---- Section titles ---- */
  .section-title {
    font-size: 15px;
    font-weight: 700;
    color: #90cdf4;
    text-transform: uppercase;
    letter-spacing: 1px;
    margin: 28px 0 12px;
    padding-bottom: 6px;
    border-bottom: 1px solid #2d3748;
  }

  /* ---- KPI Cards ---- */
  .kpi-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
    gap: 14px;
    margin-bottom: 8px;
  }
  .kpi-card {
    background: #1a202c;
    border: 1px solid #2d3748;
    border-radius: 8px;
    padding: 16px;
    transition: border-color 0.2s;
  }
  .kpi-card:hover { border-color: #4a5568; }
  .kpi-card .label { color: #a0aec0; font-size: 11px; text-transform: uppercase; letter-spacing: 0.8px; margin-bottom: 6px; }
  .kpi-card .value { font-size: 24px; font-weight: 700; color: #f7fafc; }
  .kpi-card .sub   { font-size: 11px; color: #718096; margin-top: 2px; }
  .kpi-card.warn   { border-left: 3px solid #f39c12; }
  .kpi-card.crit   { border-left: 3px solid #e74c3c; }
  .kpi-card.ok     { border-left: 3px solid #27ae60; }
  .kpi-card.info   { border-left: 3px solid #63b3ed; }

  /* ---- Tables ---- */
  .tbl-wrap { overflow-x: auto; margin-bottom: 8px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th {
    background: #2d3748;
    color: #90cdf4;
    font-weight: 600;
    text-transform: uppercase;
    font-size: 11px;
    letter-spacing: 0.7px;
    padding: 10px 12px;
    text-align: left;
    white-space: nowrap;
  }
  td { padding: 9px 12px; border-bottom: 1px solid #1a202c; }
  tr:hover td { background: #1e2533; }
  tr:nth-child(even) td { background: #171e2b; }
  tr:nth-child(even):hover td { background: #1e2533; }

  /* ---- Progress bars ---- */
  .bar-wrap { display: flex; align-items: center; gap: 10px; min-width: 140px; }
  .bar-bg {
    flex: 1; height: 8px; background: #2d3748; border-radius: 4px; overflow: hidden;
  }
  .bar-fg { height: 100%; border-radius: 4px; transition: width 0.3s; }
  .bar-ok   { background: #27ae60; }
  .bar-warn { background: #f39c12; }
  .bar-crit { background: #e74c3c; }
  .bar-pct  { min-width: 40px; text-align: right; font-weight: 600; font-size: 12px; }

  /* ---- Sparkline chart canvas ---- */
  .chart-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(340px, 1fr));
    gap: 16px;
    margin-bottom: 8px;
  }
  .chart-card {
    background: #1a202c;
    border: 1px solid #2d3748;
    border-radius: 8px;
    padding: 16px;
  }
  .chart-card h4 { font-size: 12px; color: #a0aec0; text-transform: uppercase; margin-bottom: 10px; letter-spacing: 0.7px; }
  .chart-card canvas { width: 100% !important; }

  /* ---- Instance tabs ---- */
  .tab-bar { display: flex; gap: 6px; margin-bottom: 16px; flex-wrap: wrap; }
  .tab-btn {
    padding: 7px 18px;
    border-radius: 6px;
    border: 1px solid #4a5568;
    background: #2d3748;
    color: #a0aec0;
    cursor: pointer;
    font-size: 13px;
    font-weight: 600;
    transition: all 0.15s;
  }
  .tab-btn.active, .tab-btn:hover {
    background: #2b6cb0;
    color: #fff;
    border-color: #2b6cb0;
  }
  .tab-pane { display: none; }
  .tab-pane.active { display: block; }

  /* ---- Footer ---- */
  .footer {
    margin-top: 32px;
    padding-top: 16px;
    border-top: 1px solid #2d3748;
    color: #718096;
    font-size: 12px;
    text-align: center;
  }
  .methodology {
    background: #1a202c;
    border: 1px solid #2d3748;
    border-left: 4px solid #63b3ed;
    border-radius: 8px;
    padding: 18px 20px;
    margin: 24px 0;
    font-size: 13px;
    color: #a0aec0;
  }
  .methodology h3 { color: #90cdf4; margin-bottom: 10px; font-size: 14px; }
  .methodology ul { padding-left: 18px; }
  .methodology li { margin-bottom: 6px; }
  .tag { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; margin-left: 4px; }
  .tag-pt  { background: #2b4c7e; color: #90cdf4; }
  .tag-cum { background: #3d2b00; color: #f6ad55; }
</style>
</head>
<body>
<div class="wrapper">

<!-- ===== HEADER ===== -->
<div class="header">
  <div>
    <h1>&#9889; Oracle RAC Baseline Monitor &mdash; <span>${ORA_SID}</span></h1>
    <div class="meta">Snapshot Date: <strong>${SNAPSHOT_DATE}</strong> &nbsp;|&nbsp;
    Generated: $(date '+%Y-%m-%d %H:%M:%S %Z') &nbsp;|&nbsp;
    RAC Instances: $(echo "$INST_LIST" | wc -w | tr -d ' ')
    </div>
  </div>
  <div class="status-badge">${HEALTH_STATUS}</div>
</div>

HTMLEOF

# ---- Methodology Box ---------------------------------------------------------
cat >> "$HTML_FILE" << 'HTMLEOF'
<div class="methodology">
  <h3>&#128270; Predictive Analysis Methodology</h3>
  <ul>
    <li><span class="tag tag-pt">Point-in-Time</span> <strong>Tablespace usage, Session counts, PGA usage</strong> — Read directly from today's row. Plot daily values to forecast exhaustion via linear regression or simple trend extrapolation.</li>
    <li><span class="tag tag-cum">Cumulative</span> <strong>Wait events, System stats, DB Time</strong> — Values only grow since instance startup. Calculate the <em>Daily Delta</em> (Today &minus; Yesterday) to get the actual workload per day. Rising deltas signal degradation before users notice.</li>
    <li><strong>Exhaustion forecast</strong>: For tablespaces — <em>Days to Full = (100% &minus; Current%) &divide; Avg daily growth rate</em>. For sessions — <em>Days to limit = (Limit &minus; Max_Ever) &divide; Avg daily peak increase</em>.</li>
  </ul>
</div>
HTMLEOF

# ---- TABLESPACE SECTION ------------------------------------------------------
cat >> "$HTML_FILE" << HTMLEOF
<div class="section-title">&#128200; Storage &mdash; Tablespace Utilisation <span class="tag tag-pt">Point-in-Time</span></div>
<div class="tbl-wrap">
<table>
<thead><tr>
  <th>Tablespace</th>
  <th>Total (MB)</th>
  <th>Used (MB)</th>
  <th>Free (MB)</th>
  <th>Utilisation</th>
  <th>Status</th>
</tr></thead>
<tbody>
HTMLEOF

# Parse tablespace data
echo "$TODAY_DATA" | grep ",STORAGE,TS_" | grep "_TOTAL_MB," | sort -t'_' -k1 | \
while IFS=',' read -r snap inst cat name val; do
    ts_name=$(echo "$name" | sed 's/^TS_//;s/_TOTAL_MB$//')
    total_mb="$val"
    used_mb=$(echo "$TODAY_DATA" | grep ",STORAGE,TS_${ts_name}_USED_MB," | tail -1 | cut -d',' -f5)
    pct=$(echo "$TODAY_DATA" | grep ",STORAGE,TS_${ts_name}_USED_PCT," | tail -1 | cut -d',' -f5)

    [ -z "$total_mb" ] || [ -z "$used_mb" ] || [ -z "$pct" ] && continue

    free_mb=$(echo "$total_mb $used_mb" | awk '{printf "%.2f", $1 - $2}')
    pct_int=$(echo "$pct" | awk '{printf "%d", $1}')
    pct_disp=$(echo "$pct" | awk '{printf "%.1f", $1}')

    if [ "$pct_int" -ge "$TABLESPACE_CRIT_PCT" ] 2>/dev/null; then
        bar_class="bar-crit"; status_txt="&#128308; CRITICAL"; row_style=""
    elif [ "$pct_int" -ge "$TABLESPACE_WARN_PCT" ] 2>/dev/null; then
        bar_class="bar-warn"; status_txt="&#128993; WARNING"; row_style=""
    else
        bar_class="bar-ok"; status_txt="&#128994; OK"; row_style=""
    fi

    cat >> "$HTML_FILE" << ROWEOF
<tr>
  <td><strong>${ts_name}</strong></td>
  <td>${total_mb}</td>
  <td>${used_mb}</td>
  <td>${free_mb}</td>
  <td>
    <div class="bar-wrap">
      <div class="bar-bg"><div class="bar-fg ${bar_class}" style="width:${pct_int}%"></div></div>
      <span class="bar-pct">${pct_disp}%</span>
    </div>
  </td>
  <td>${status_txt}</td>
</tr>
ROWEOF
done

cat >> "$HTML_FILE" << 'HTMLEOF'
</tbody></table>
</div>
HTMLEOF

# ---- CAPACITY SECTION --------------------------------------------------------
cat >> "$HTML_FILE" << HTMLEOF
<div class="section-title">&#128101; Capacity &mdash; Sessions &amp; Processes <span class="tag tag-pt">Point-in-Time</span></div>
<div class="kpi-grid">
HTMLEOF

for inst in $INST_LIST; do
    sess_cur=$(echo "$TODAY_DATA" | grep "^${SNAPSHOT_DATE},${inst},CAPACITY,SESSIONS_CURRENT," | tail -1 | cut -d',' -f5)
    sess_lim=$(echo "$TODAY_DATA" | grep "^${SNAPSHOT_DATE},${inst},CAPACITY,SESSIONS_LIMIT,"   | tail -1 | cut -d',' -f5)
    sess_max=$(echo "$TODAY_DATA" | grep "^${SNAPSHOT_DATE},${inst},CAPACITY,SESSIONS_MAX_EVER,"| tail -1 | cut -d',' -f5)
    proc_cur=$(echo "$TODAY_DATA" | grep "^${SNAPSHOT_DATE},${inst},CAPACITY,PROCESSES_CURRENT,"| tail -1 | cut -d',' -f5)
    proc_lim=$(echo "$TODAY_DATA" | grep "^${SNAPSHOT_DATE},${inst},CAPACITY,PROCESSES_LIMIT,"  | tail -1 | cut -d',' -f5)

    [ -z "$sess_cur" ] && sess_cur="N/A"
    [ -z "$sess_lim" ] && sess_lim="N/A"

    if [ "$sess_lim" != "N/A" ] && [ "$sess_cur" != "N/A" ]; then
        sess_pct=$(echo "$sess_cur $sess_lim" | awk '{printf "%d", ($1/$2)*100}')
    else
        sess_pct=0
    fi

    if   [ "$sess_pct" -ge "$SESSION_CRIT_PCT" ] 2>/dev/null; then css_cls="crit"
    elif [ "$sess_pct" -ge "$SESSION_WARN_PCT"  ] 2>/dev/null; then css_cls="warn"
    else css_cls="ok"; fi

    cat >> "$HTML_FILE" << KPIEOF
<div class="kpi-card ${css_cls}">
  <div class="label">Instance ${inst} &mdash; Sessions</div>
  <div class="value">${sess_cur}</div>
  <div class="sub">of ${sess_lim} limit &nbsp;|&nbsp; Peak: ${sess_max:-N/A}</div>
</div>
<div class="kpi-card info">
  <div class="label">Instance ${inst} &mdash; Processes</div>
  <div class="value">${proc_cur:-N/A}</div>
  <div class="sub">of ${proc_lim:-N/A} limit</div>
</div>
KPIEOF
done

echo '</div>' >> "$HTML_FILE"

# ---- MEMORY SECTION ----------------------------------------------------------
cat >> "$HTML_FILE" << HTMLEOF
<div class="section-title">&#128190; Memory &mdash; SGA &amp; PGA <span class="tag tag-pt">Point-in-Time</span></div>
<div class="kpi-grid">
HTMLEOF

for inst in $INST_LIST; do
    sga_total=$(echo "$TODAY_DATA" | grep "^${SNAPSHOT_DATE},${inst},MEMORY_SGA,SGA_TOTAL_MB,"       | tail -1 | cut -d',' -f5)
    sga_free=$(echo "$TODAY_DATA"  | grep "^${SNAPSHOT_DATE},${inst},MEMORY_SGA,SGA_FREE_MEMORY_MB," | tail -1 | cut -d',' -f5)
    sga_bc=$(echo "$TODAY_DATA"    | grep "^${SNAPSHOT_DATE},${inst},MEMORY_SGA,SGA_BUFFER_CACHE_MB,"| tail -1 | cut -d',' -f5)
    sga_sp=$(echo "$TODAY_DATA"    | grep "^${SNAPSHOT_DATE},${inst},MEMORY_SGA,SGA_SHARED_POOL_MB," | tail -1 | cut -d',' -f5)
    pga_total=$(echo "$TODAY_DATA" | grep "^${SNAPSHOT_DATE},${inst},MEMORY_PGA,TOTAL_PGA_ALLOCATED_MB," | tail -1 | cut -d',' -f5)
    pga_max=$(echo "$TODAY_DATA"   | grep "^${SNAPSHOT_DATE},${inst},MEMORY_PGA,MAXIMUM_PGA_ALLOCATED_MB," | tail -1 | cut -d',' -f5)

    if [ -n "$pga_total" ] && [ "$pga_total" != "N/A" ]; then
        pga_int=$(echo "$pga_total" | awk '{printf "%d", $1}')
        if   [ "$pga_int" -ge "$PGA_CRIT_MB" ] 2>/dev/null; then pga_cls="crit"
        elif [ "$pga_int" -ge "$PGA_WARN_MB"  ] 2>/dev/null; then pga_cls="warn"
        else pga_cls="ok"; fi
    else pga_cls="ok"; fi

    cat >> "$HTML_FILE" << MEMEOF
<div class="kpi-card info">
  <div class="label">Inst ${inst} — SGA Total</div>
  <div class="value">${sga_total:-N/A} <span style="font-size:14px;color:#a0aec0">MB</span></div>
  <div class="sub">Free: ${sga_free:-N/A} MB</div>
</div>
<div class="kpi-card info">
  <div class="label">Inst ${inst} — Buffer Cache</div>
  <div class="value">${sga_bc:-N/A} <span style="font-size:14px;color:#a0aec0">MB</span></div>
  <div class="sub">Shared Pool: ${sga_sp:-N/A} MB</div>
</div>
<div class="kpi-card ${pga_cls}">
  <div class="label">Inst ${inst} — PGA Allocated</div>
  <div class="value">${pga_total:-N/A} <span style="font-size:14px;color:#a0aec0">MB</span></div>
  <div class="sub">Peak ever: ${pga_max:-N/A} MB</div>
</div>
MEMEOF
done

echo '</div>' >> "$HTML_FILE"

# ---- WAIT EVENTS SECTION -----------------------------------------------------
cat >> "$HTML_FILE" << HTMLEOF
<div class="section-title">&#9203; Wait Events &mdash; Cumulative by Class <span class="tag tag-cum">Cumulative &rarr; Use Daily Delta</span></div>
<div class="tbl-wrap"><table>
<thead><tr>
  <th>Instance</th>
  <th>Wait Class</th>
  <th>Total Time Waited (secs)</th>
  <th>Total Waits</th>
</tr></thead>
<tbody>
HTMLEOF

echo "$TODAY_DATA" | grep ",WAIT_EVENTS,WAIT_CLASS_" | grep "_TIME_SECS," | \
    sort -t',' -k2,2n -k4,4 | \
while IFS=',' read -r snap inst cat name val; do
    class=$(echo "$name" | sed 's/^WAIT_CLASS_//;s/_TIME_SECS$//')
    waits=$(echo "$TODAY_DATA" | grep "^${SNAPSHOT_DATE},${inst},WAIT_EVENTS,WAIT_CLASS_${class}_TOTAL_WAITS," | tail -1 | cut -d',' -f5)
    cat >> "$HTML_FILE" << WEOF
<tr><td>Instance ${inst}</td><td>${class}</td><td>${val}</td><td>${waits:-N/A}</td></tr>
WEOF
done

cat >> "$HTML_FILE" << 'HTMLEOF'
</tbody></table></div>
HTMLEOF

# ---- SYSTEM STATS SECTION ----------------------------------------------------
cat >> "$HTML_FILE" << HTMLEOF
<div class="section-title">&#128202; System Statistics &mdash; Key Workload Counters <span class="tag tag-cum">Cumulative &rarr; Use Daily Delta</span></div>
<div class="tbl-wrap"><table>
<thead><tr><th>Instance</th><th>Statistic</th><th>Cumulative Value</th></tr></thead>
<tbody>
HTMLEOF

echo "$TODAY_DATA" | grep ",SYS_STATS," | sort -t',' -k2,2n -k4,4 | \
while IFS=',' read -r snap inst cat name val; do
    cat >> "$HTML_FILE" << SSEOF
<tr><td>Instance ${inst}</td><td>${name}</td><td>${val}</td></tr>
SSEOF
done

cat >> "$HTML_FILE" << 'HTMLEOF'
</tbody></table></div>
HTMLEOF

# ---- RAC INTERCONNECT SECTION ------------------------------------------------
cat >> "$HTML_FILE" << HTMLEOF
<div class="section-title">&#128268; RAC Interconnect &amp; DB Time <span class="tag tag-cum">Cumulative &rarr; Use Daily Delta</span></div>
<div class="tbl-wrap"><table>
<thead><tr><th>Instance</th><th>Metric</th><th>Cumulative Value</th></tr></thead>
<tbody>
HTMLEOF

echo "$TODAY_DATA" | grep -E ",RAC_INTERCONNECT,|,DB_TIME_MODEL," | sort -t',' -k2,2n -k3,3 -k4,4 | \
while IFS=',' read -r snap inst cat name val; do
    cat >> "$HTML_FILE" << RCEOF
<tr><td>Instance ${inst}</td><td>[${cat}] ${name}</td><td>${val}</td></tr>
RCEOF
done

cat >> "$HTML_FILE" << 'HTMLEOF'
</tbody></table></div>
HTMLEOF

# ---- REDO SECTION ------------------------------------------------------------
cat >> "$HTML_FILE" << HTMLEOF
<div class="section-title">&#128196; Redo Logs &amp; Archiver Activity <span class="tag tag-pt">Point-in-Time (Today)</span></div>
<div class="kpi-grid">
HTMLEOF

for inst in $INST_LIST; do
    switches=$(echo "$TODAY_DATA" | grep "^${SNAPSHOT_DATE},${inst},REDO_LOGS,LOG_SWITCHES_TODAY,"     | tail -1 | cut -d',' -f5)
    redo_mb=$(echo "$TODAY_DATA"  | grep "^${SNAPSHOT_DATE},${inst},REDO_LOGS,REDO_SIZE_LAST_HOUR_MB," | tail -1 | cut -d',' -f5)
    cat >> "$HTML_FILE" << REDEOF
<div class="kpi-card info">
  <div class="label">Inst ${inst} — Log Switches Today</div>
  <div class="value">${switches:-0}</div>
  <div class="sub">High switches may indicate log sizing issue</div>
</div>
<div class="kpi-card info">
  <div class="label">Inst ${inst} — Redo Last Hour</div>
  <div class="value">${redo_mb:-0} <span style="font-size:14px;color:#a0aec0">MB</span></div>
  <div class="sub">Archived log generation rate</div>
</div>
REDEOF
done

echo '</div>' >> "$HTML_FILE"

# ---- INLINE CHARTS (Canvas/JS) -----------------------------------------------
cat >> "$HTML_FILE" << 'HTMLEOF'
<div class="section-title">&#128202; Visual Trends (Historical Data from CSV)</div>
<p style="color:#718096;font-size:12px;margin-bottom:16px;">
  Charts below render the last 30 days from the cumulative CSV baseline file.
  Embed the CSV data into the page by extending this script with a CSV-to-JSON pre-processor.
</p>
<div class="chart-grid">
  <div class="chart-card">
    <h4>Tablespace Usage % — Trend (last 30 days)</h4>
    <canvas id="chartTS" height="180"></canvas>
  </div>
  <div class="chart-card">
    <h4>Session Count — Peak vs Limit</h4>
    <canvas id="chartSess" height="180"></canvas>
  </div>
  <div class="chart-card">
    <h4>Wait Class — Daily Delta (secs/day)</h4>
    <canvas id="chartWait" height="180"></canvas>
  </div>
  <div class="chart-card">
    <h4>Physical I/O — Daily Delta</h4>
    <canvas id="chartIO" height="180"></canvas>
  </div>
</div>

<script>
// ----------------------------------------------------------------
// Inline Chart Rendering using Canvas API (no external dependency)
// Data would be injected here by the shell script's CSV parser.
// This provides the chart framework; extend with real parsed data.
// ----------------------------------------------------------------
(function() {
  const COLORS = ['#63b3ed','#68d391','#f6ad55','#fc8181','#b794f4','#76e4f7'];

  function drawBarChart(canvasId, labels, datasets, options) {
    const canvas = document.getElementById(canvasId);
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    const W = canvas.parentElement.clientWidth - 32;
    const H = options.height || 180;
    canvas.width = W; canvas.height = H;

    const PAD = { top: 20, right: 20, bottom: 40, left: 55 };
    const cW = W - PAD.left - PAD.right;
    const cH = H - PAD.top  - PAD.bottom;

    const allVals = datasets.flatMap(d => d.data).filter(v => v != null);
    const maxVal  = Math.max(...allVals, 1);
    const minVal  = 0;
    const range   = maxVal - minVal || 1;

    ctx.fillStyle = '#1a202c';
    ctx.fillRect(0, 0, W, H);

    // Grid lines
    ctx.strokeStyle = '#2d3748'; ctx.lineWidth = 1;
    for (let i = 0; i <= 4; i++) {
      const y = PAD.top + cH - (i / 4) * cH;
      ctx.beginPath(); ctx.moveTo(PAD.left, y); ctx.lineTo(PAD.left + cW, y); ctx.stroke();
      ctx.fillStyle = '#718096'; ctx.font = '10px sans-serif'; ctx.textAlign = 'right';
      ctx.fillText(((minVal + (range * i / 4)).toFixed(0)), PAD.left - 6, y + 4);
    }

    const barGroupW = cW / (labels.length || 1);
    const barW = (barGroupW * 0.7) / (datasets.length || 1);

    datasets.forEach((ds, di) => {
      ctx.fillStyle = COLORS[di % COLORS.length];
      ds.data.forEach((val, i) => {
        if (val == null) return;
        const x  = PAD.left + i * barGroupW + barGroupW * 0.15 + di * barW;
        const bH = ((val - minVal) / range) * cH;
        const y  = PAD.top + cH - bH;
        ctx.fillRect(x, y, barW - 2, bH);
      });
    });

    // X labels
    ctx.fillStyle = '#a0aec0'; ctx.font = '9px sans-serif'; ctx.textAlign = 'center';
    labels.forEach((lbl, i) => {
      const x = PAD.left + i * barGroupW + barGroupW / 2;
      ctx.fillText(lbl.slice(-5), x, H - PAD.bottom + 14);
    });

    // Legend
    datasets.forEach((ds, di) => {
      ctx.fillStyle = COLORS[di % COLORS.length];
      ctx.fillRect(PAD.left + di * 110, H - 10, 10, 10);
      ctx.fillStyle = '#a0aec0'; ctx.font = '10px sans-serif'; ctx.textAlign = 'left';
      ctx.fillText(ds.label, PAD.left + di * 110 + 14, H - 1);
    });
  }

  function drawLineChart(canvasId, labels, datasets, options) {
    const canvas = document.getElementById(canvasId);
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    const W = canvas.parentElement.clientWidth - 32;
    const H = options.height || 180;
    canvas.width = W; canvas.height = H;
    const PAD = { top: 20, right: 20, bottom: 40, left: 55 };
    const cW = W - PAD.left - PAD.right;
    const cH = H - PAD.top  - PAD.bottom;

    const allVals = datasets.flatMap(d => d.data).filter(v => v != null);
    const maxVal  = Math.max(...allVals, 1);
    const range   = maxVal || 1;

    ctx.fillStyle = '#1a202c'; ctx.fillRect(0, 0, W, H);
    ctx.strokeStyle = '#2d3748'; ctx.lineWidth = 1;
    for (let i = 0; i <= 4; i++) {
      const y = PAD.top + cH - (i / 4) * cH;
      ctx.beginPath(); ctx.moveTo(PAD.left, y); ctx.lineTo(PAD.left + cW, y); ctx.stroke();
      ctx.fillStyle = '#718096'; ctx.font = '10px sans-serif'; ctx.textAlign = 'right';
      ctx.fillText((maxVal * i / 4).toFixed(0), PAD.left - 6, y + 4);
    }

    datasets.forEach((ds, di) => {
      ctx.strokeStyle = COLORS[di % COLORS.length];
      ctx.lineWidth = 2; ctx.beginPath();
      let started = false;
      ds.data.forEach((val, i) => {
        if (val == null) { started = false; return; }
        const x = PAD.left + (i / (labels.length - 1 || 1)) * cW;
        const y = PAD.top  + cH - (val / range) * cH;
        if (!started) { ctx.moveTo(x, y); started = true; } else { ctx.lineTo(x, y); }
      });
      ctx.stroke();
      // Dots
      ctx.fillStyle = COLORS[di % COLORS.length];
      ds.data.forEach((val, i) => {
        if (val == null) return;
        const x = PAD.left + (i / (labels.length - 1 || 1)) * cW;
        const y = PAD.top  + cH - (val / range) * cH;
        ctx.beginPath(); ctx.arc(x, y, 3, 0, Math.PI * 2); ctx.fill();
      });
    });

    ctx.fillStyle = '#a0aec0'; ctx.font = '9px sans-serif'; ctx.textAlign = 'center';
    labels.forEach((lbl, i) => {
      const x = PAD.left + (i / (labels.length - 1 || 1)) * cW;
      ctx.fillText(lbl.slice(-5), x, H - PAD.bottom + 14);
    });

    datasets.forEach((ds, di) => {
      ctx.fillStyle = COLORS[di % COLORS.length];
      ctx.fillRect(PAD.left + di * 110, H - 10, 10, 10);
      ctx.fillStyle = '#a0aec0'; ctx.font = '10px sans-serif'; ctx.textAlign = 'left';
      ctx.fillText(ds.label, PAD.left + di * 110 + 14, H - 1);
    });
  }

  // ---------- INJECT CHART DATA FROM EMBEDDED JSON (generated by shell) ----------
  const chartData = window._oraChartData || {};

  if (chartData.ts) {
    drawLineChart('chartTS', chartData.ts.labels, chartData.ts.datasets, { height: 180 });
  } else {
    // Placeholder skeleton
    drawBarChart('chartTS', ['(No data yet)'], [{ label: 'Run for 2+ days to populate', data: [0] }], {});
  }
  if (chartData.sess) {
    drawBarChart('chartSess', chartData.sess.labels, chartData.sess.datasets, {});
  } else {
    drawBarChart('chartSess', ['(No data)'], [{ label: 'Sessions', data: [0] }, { label: 'Limit', data: [0] }], {});
  }
  if (chartData.wait) {
    drawLineChart('chartWait', chartData.wait.labels, chartData.wait.datasets, {});
  } else {
    drawLineChart('chartWait', ['(No data)'], [{ label: 'Cluster', data: [0] }, { label: 'User I/O', data: [0] }], {});
  }
  if (chartData.io) {
    drawLineChart('chartIO', chartData.io.labels, chartData.io.datasets, {});
  } else {
    drawLineChart('chartIO', ['(No data)'], [{ label: 'Phys Reads', data: [0] }, { label: 'Phys Writes', data: [0] }], {});
  }

})();
</script>
HTMLEOF

# ---- Inject real chart data from last 30 days of CSV -------------------------
# Build JSON data block for chart rendering
log "Building chart data JSON from CSV history..."

python3 -c "
import csv, json, sys, os
from collections import defaultdict

csv_file = '${CSV_FILE}'
snap_date = '${SNAPSHOT_DATE}'

if not os.path.exists(csv_file):
    print('<script>window._oraChartData={};</script>')
    sys.exit(0)

rows = []
with open(csv_file) as f:
    reader = csv.DictReader(f)
    for r in reader:
        rows.append(r)

# Last 30 unique dates
dates = sorted(set(r['SNAPSHOT_DATE'] for r in rows))[-30:]

def get_vals(rows, dates, inst, cat, name):
    m = {r['SNAPSHOT_DATE']: float(r['METRIC_VALUE'])
         for r in rows if r['INST_ID']==str(inst)
         and r['METRIC_CATEGORY']==cat and r['METRIC_NAME']==name}
    return [m.get(d) for d in dates]

# Detect instance IDs (exclude 0)
insts = sorted(set(r['INST_ID'] for r in rows if r['INST_ID'] != '0'))

# Tablespace chart — SYSAUX used pct
ts_names = sorted(set(r['METRIC_NAME'].replace('TS_','').replace('_USED_PCT','')
    for r in rows if r['METRIC_CATEGORY']=='STORAGE' and '_USED_PCT' in r['METRIC_NAME']))[:6]
ts_datasets = [{'label': ts, 'data': [
    next((float(r['METRIC_VALUE']) for r in rows if r['SNAPSHOT_DATE']==d
         and r['METRIC_NAME']=='TS_'+ts+'_USED_PCT' and r['INST_ID']=='0'), None)
    for d in dates]} for ts in ts_names]

# Session chart
sess_datasets = []
for inst in insts:
    sess_datasets.append({'label': 'Sess Inst'+inst,
        'data': get_vals(rows, dates, inst, 'CAPACITY', 'SESSIONS_CURRENT')})

# Wait events daily delta
wait_classes = ['CLUSTER','USER_I/O','SYSTEM_I/O','CONCURRENCY']
wait_datasets = []
for wc in wait_classes:
    for inst in insts[:2]:  # limit to first 2 instances for clarity
        raw = get_vals(rows, dates, inst, 'WAIT_EVENTS', 'WAIT_CLASS_'+wc+'_TIME_SECS')
        delta = [None] + [round(raw[i]-raw[i-1],2) if raw[i] is not None and raw[i-1] is not None and raw[i]>=raw[i-1] else None
                          for i in range(1, len(raw))]
        wait_datasets.append({'label': wc[:8]+' I'+inst, 'data': delta})

# IO daily delta
io_datasets = []
for inst in insts[:2]:
    pr = get_vals(rows, dates, inst, 'SYS_STATS', 'PHYSICAL_READS')
    pw = get_vals(rows, dates, inst, 'SYS_STATS', 'PHYSICAL_WRITES')
    pr_d = [None]+[round(pr[i]-pr[i-1],0) if pr[i] is not None and pr[i-1] is not None else None for i in range(1,len(pr))]
    pw_d = [None]+[round(pw[i]-pw[i-1],0) if pw[i] is not None and pw[i-1] is not None else None for i in range(1,len(pw))]
    io_datasets.append({'label':'PhysRd I'+inst,'data':pr_d})
    io_datasets.append({'label':'PhysWr I'+inst,'data':pw_d})

out = {'ts':{'labels':dates,'datasets':ts_datasets},
       'sess':{'labels':dates,'datasets':sess_datasets},
       'wait':{'labels':dates,'datasets':wait_datasets},
       'io':{'labels':dates,'datasets':io_datasets}}
print('<script>window._oraChartData=' + json.dumps(out) + ';</script>')
" 2>/dev/null >> "$HTML_FILE" || echo '<script>window._oraChartData={};</script>' >> "$HTML_FILE"

# ---- FOOTER ------------------------------------------------------------------
cat >> "$HTML_FILE" << HTMLEOF
<div class="footer">
  Oracle RAC Baseline Monitor &mdash; ${ORA_SID} &mdash; ${SNAPSHOT_DATE} &nbsp;|&nbsp;
  CSV Baseline: ${CSV_FILE} &nbsp;|&nbsp;
  Generated by <strong>ora_rac_baseline_monitor.sh v2.0</strong>
</div>
</div><!-- /wrapper -->
</body></html>
HTMLEOF

log "HTML report generated: ${HTML_FILE}"

# =============================================================================
# SECTION 9: ARCHIVE OLD HTML REPORTS
# =============================================================================

log "Archiving HTML reports older than ${ARCHIVE_DAYS} days..."
find "$HTML_DIR" -name "oracle_rac_report_${ORA_SID}_*.html" \
     -mtime "+${ARCHIVE_DAYS}" -exec mv {} "$ARCHIVE_DIR/" \; 2>/dev/null

# Clean old log files
find "$LOG_DIR" -name "baseline_${ORA_SID}_*.log" \
     -mtime "+${LOG_RETAIN_DAYS}" -delete 2>/dev/null

# =============================================================================
# SECTION 10: EMAIL REPORT
# =============================================================================

send_email() {
    local recipient="$1"
    local subject="${EMAIL_SUBJECT_PREFIX} ${ORA_SID} — ${SNAPSHOT_DATE} — ${HEALTH_STATUS}"
    local html_body
    html_body=$(cat "$HTML_FILE")

    log "Sending email to: ${recipient}"

    if [ "$MAIL_METHOD" = "sendmail" ] && [ -x "$SENDMAIL_BIN" ]; then
        # Build MIME email with inline HTML
        {
            echo "From: ${EMAIL_FROM}"
            echo "To: ${recipient}"
            echo "Subject: ${subject}"
            echo "MIME-Version: 1.0"
            echo "Content-Type: text/html; charset=UTF-8"
            echo "Content-Transfer-Encoding: 7bit"
            echo ""
            echo "$html_body"
        } | "$SENDMAIL_BIN" -t
        log "Email sent via sendmail."

    elif command -v mailx > /dev/null 2>&1; then
        # mailx fallback
        echo "$html_body" | mailx -a "Content-Type: text/html" \
            -s "$subject" -r "$EMAIL_FROM" "$recipient"
        log "Email sent via mailx."
    else
        log "WARNING: No mail transport available. Email not sent."
        log "  Install sendmail or mailx, or set MAIL_METHOD appropriately."
    fi
}

if [ $SKIP_EMAIL -eq 0 ] && [ -n "$EMAIL_TO" ]; then
    # Support comma-separated recipients
    OLD_IFS="$IFS"; IFS=','
    for addr in $EMAIL_TO; do
        IFS="$OLD_IFS"
        addr=$(echo "$addr" | tr -d ' ')
        [ -n "$addr" ] && send_email "$addr"
        IFS=','
    done
    IFS="$OLD_IFS"
elif [ $SKIP_EMAIL -eq 1 ]; then
    log "Email skipped (--no-email flag set)."
else
    log "No email recipient configured. Set EMAIL_TO in script or use -e flag."
fi

# =============================================================================
# SECTION 11: SUMMARY
# =============================================================================

CSV_SIZE=$(wc -l < "$CSV_FILE" 2>/dev/null || echo "?")

log "============================================================"
log "Run complete."
log "  CSV rows total   : ${CSV_SIZE}"
log "  Rows this run    : ${VALID_ROWS}"
log "  HTML report      : ${HTML_FILE}"
log "  Overall status   : ${HEALTH_STATUS}"
log "  Log file         : ${LOG_FILE}"
log "============================================================"

exit 0
