#!/usr/bin/env bash
#==============================================================================
# tbsp_report.sh
#
# Oracle Tablespace Capacity & Growth Report (+ ASM diskgroup space)
# ---------------------------------------------------------------------------
# Portable across Solaris (SunOS) and Linux. CDB/non-CDB aware (Oracle 19c+).
#
# Generates:
#   <tag>_tbsp_capacity_<ts>.csv     - tablespace capacity & growth data
#   <tag>_asm_diskgroup_<ts>.csv     - ASM diskgroup space data (if available)
#   <tag>_capacity_report_<ts>.html  - interactive HTML report (both sections)
#   <tag>_capacity_report_<ts>.log   - run log
#
# See README.md for full documentation, assumptions and prerequisites.
#
# Usage: tbsp_report.sh [options]
#   -s ORACLE_SID   Target ORACLE_SID (default: current $ORACLE_SID)
#   -c CONNECT_STR  SQL*Plus connect string (default: "/ as sysdba")
#   -p PDB_NAME     For a CDB, restrict report to one PDB (default: ALL)
#   -o OUTDIR       Output directory (default: current directory)
#   -N TAG          Tag appended to CSV/HTML filenames and report title
#   -a ASM_SID      Override ASM instance SID autodetection
#   -A CONNECT_STR  SQL*Plus connect string for ASM (default: "/ as sysasm")
#   -x              Skip the ASM diskgroup section entirely
#   -h              Show this help and exit
#
# Exit codes: 0 ok, 1 usage/arg error, 2 environment/prereq error,
#             3 tablespace query failed (fatal), 4 partial (ASM section
#             skipped/failed but tablespace report completed).
#==============================================================================

# ---------------------------------------------------------------------------
# Strict-ish mode. We intentionally do NOT use 'set -e': several steps (ASM
# detection, ASM query) are allowed to fail without aborting the whole run.
# ---------------------------------------------------------------------------
set -u

SCRIPT_NAME=$(basename "$0")
SCRIPT_VERSION="1.0.0"
RUN_TS=$(date +%Y%m%d_%H%M%S)
RUN_PID=$$

# ---------------------------------------------------------------------------
# Defaults (edit here to change site-wide behaviour without touching logic)
# ---------------------------------------------------------------------------
ORACLE_SID_OPT=""
CONNECT_STR="/ as sysdba"
PDB_FILTER="ALL"
OUTDIR="."
TAG=""
ASM_SID_OPT=""
ASM_CONNECT_STR="/ as sysasm"
SKIP_ASM=0

# Business rules carried over verbatim from the source query. Adjust here if
# your standards differ (e.g. a different max-datafiles-per-tablespace policy).
DF_RED_THRESHOLD=900     # datafile_count > this  -> RED
DF_AMBER_THRESHOLD=800   # datafile_count > this  -> AMBER
MAX_DATAFILES_PER_TS=1023
MAX_DATAFILE_GB=32

# ASM free-space colour thresholds (percent of total, usable-space basis)
ASM_RED_FREE_PCT=10
ASM_AMBER_FREE_PCT=20

WORKDIR=""
LOGFILE=""

# ===========================================================================
# Generic helpers
# ===========================================================================
usage() {
    sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
}

ts_now() { date '+%Y-%m-%d %H:%M:%S'; }

log()  { printf '[%s] %s\n' "$(ts_now)" "$*" | tee -a "${LOGFILE:-/dev/null}" >&2; }
info() { log "INFO:  $*"; }
warn() { log "WARN:  $*"; }
err()  { log "ERROR: $*"; }
die()  { err "$1"; cleanup; exit "${2:-2}"; }

cleanup() {
    if [ -n "${WORKDIR:-}" ] && [ -d "${WORKDIR:-}" ]; then
        rm -rf "$WORKDIR" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# OS detection. Solaris and Linux differ mainly in: oratab location, ps(1)
# output, and availability of certain GNU-only flags (we avoid those flags
# everywhere rather than branch on every call).
# ---------------------------------------------------------------------------
OS_TYPE=$(uname -s 2>/dev/null)

# ---------------------------------------------------------------------------
# Portable temp workdir (no dependency on mktemp, which is not guaranteed
# present on older Solaris builds).
# ---------------------------------------------------------------------------
make_workdir() {
    _base="${TMPDIR:-/tmp}"
    _dir="${_base}/tbsp_report.${RUN_PID}.${RUN_TS}"
    if ! mkdir -m 700 "$_dir" 2>/dev/null; then
        die "Could not create work directory '$_dir'" 2
    fi
    WORKDIR="$_dir"
}

# ===========================================================================
# Oracle environment helpers
# ===========================================================================

# oratab lives in different places on Linux vs classic Solaris.
find_oratab() {
    for f in /etc/oratab /var/opt/oracle/oratab; do
        if [ -r "$f" ]; then printf '%s\n' "$f"; return 0; fi
    done
    return 1
}

# Resolve ORACLE_HOME for a given SID by reading oratab directly. We do this
# ourselves (rather than only relying on oraenv) so the script still works
# on hosts where oraenv isn't on PATH, and so ASM lookups (different SID,
# different home) are trivial.
home_for_sid() {
    _sid=$1
    _ot=$(find_oratab) || return 1
    awk -F: -v s="$_sid" '$1 == s && $0 !~ /^#/ {print $2; exit}' "$_ot"
}

# If -s was given, switch the *current* shell's Oracle environment to that
# SID before we do anything else. Tries oraenv first (the supported way),
# falls back to setting ORACLE_HOME/PATH/LD_LIBRARY_PATH from oratab.
set_oracle_env_for_sid() {
    _sid=$1
    ORACLE_SID="$_sid"; export ORACLE_SID

    _oraenv=""
    for c in "$(command -v oraenv 2>/dev/null)" /usr/local/bin/oraenv /usr/bin/oraenv; do
        if [ -n "$c" ] && [ -x "$c" ]; then _oraenv="$c"; break; fi
    done

    if [ -n "$_oraenv" ]; then
        ORAENV_ASK=NO
        export ORAENV_ASK ORACLE_SID
        # shellcheck disable=SC1090
        . "$_oraenv" >/dev/null 2>&1
        if [ -n "${ORACLE_HOME:-}" ]; then
            return 0
        fi
        warn "oraenv ran but ORACLE_HOME is still unset; falling back to oratab lookup."
    fi

    _home=$(home_for_sid "$_sid")
    if [ -z "${_home:-}" ]; then
        die "Could not resolve ORACLE_HOME for SID '$_sid' (oraenv not found and no oratab entry). Use -c to supply a full connect string against a pre-set environment instead, or fix oratab." 2
    fi
    ORACLE_HOME="$_home"; export ORACLE_HOME
    PATH="$ORACLE_HOME/bin:$PATH"; export PATH
    LD_LIBRARY_PATH="$ORACLE_HOME/lib:${LD_LIBRARY_PATH:-}"; export LD_LIBRARY_PATH
    if [ "$OS_TYPE" = "SunOS" ]; then
        LD_LIBRARY_PATH_64="$ORACLE_HOME/lib:${LD_LIBRARY_PATH_64:-}"; export LD_LIBRARY_PATH_64
    fi
}

# ===========================================================================
# Argument parsing
# ===========================================================================
while getopts ":s:c:p:o:N:a:A:xh" opt; do
    case "$opt" in
        s) ORACLE_SID_OPT=$OPTARG ;;
        c) CONNECT_STR=$OPTARG ;;
        p) PDB_FILTER=$OPTARG ;;
        o) OUTDIR=$OPTARG ;;
        N) TAG=$OPTARG ;;
        a) ASM_SID_OPT=$OPTARG ;;
        A) ASM_CONNECT_STR=$OPTARG ;;
        x) SKIP_ASM=1 ;;
        h) usage; exit 0 ;;
        \?) printf 'Unknown option: -%s\n\n' "$OPTARG" >&2; usage; exit 1 ;;
        :) printf 'Option -%s requires an argument\n\n' "$OPTARG" >&2; usage; exit 1 ;;
    esac
done

# Mild safety net: a connect string with an embedded password is visible to
# anyone who can run 'ps' on this host while sqlplus is starting. OS
# authentication ("/ as sysdba") or an external password store / wallet
# ("/@alias as sysdba") avoid that exposure entirely.
case "$CONNECT_STR" in
    /*) : ;;  # "/ as sysdba" or wallet-style "/@alias" - no embedded password
    *"/"*"@"*)
        warn "The -c connect string appears to embed credentials directly. These are briefly visible to other OS users via 'ps'. Prefer OS authentication or an external password store / wallet where possible." ;;
esac

# ===========================================================================
# Setup
# ===========================================================================
if [ -n "$ORACLE_SID_OPT" ]; then
    set_oracle_env_for_sid "$ORACLE_SID_OPT"
fi

if [ -z "${ORACLE_SID:-}" ]; then
    printf 'ORACLE_SID is not set and -s was not given. Pass -s <SID> or export ORACLE_SID first.\n' >&2
    exit 1
fi

if ! command -v sqlplus >/dev/null 2>&1; then
    printf "sqlplus not found on PATH (ORACLE_HOME=%s). Check the environment or use -s to select a SID.\n" "${ORACLE_HOME:-unset}" >&2
    exit 2
fi

if [ ! -d "$OUTDIR" ]; then
    if ! mkdir -p "$OUTDIR" 2>/dev/null; then
        printf "Could not create output directory '%s'\n" "$OUTDIR" >&2
        exit 2
    fi
fi
if [ ! -w "$OUTDIR" ]; then
    printf "Output directory '%s' is not writable\n" "$OUTDIR" >&2
    exit 2
fi

make_workdir
LOGFILE="${WORKDIR}/run.log"
TAG_SFX=""
[ -n "$TAG" ] && TAG_SFX="_${TAG}"

info "Starting $SCRIPT_NAME v$SCRIPT_VERSION (PID $RUN_PID) on host $(hostname 2>/dev/null) [$OS_TYPE]"
info "ORACLE_SID=${ORACLE_SID} ORACLE_HOME=${ORACLE_HOME:-<inherited>}"

# ===========================================================================
# SQL execution helpers
# ===========================================================================

# Run a .sql file through sqlplus in SQL*Plus's built-in CSV markup mode and
# capture the result as a clean CSV file. Returns 1 on any sqlplus/SQL error
# (and dumps the error text to the log) rather than silently producing a
# half-written CSV.
run_sql_to_csv() {
    _conn=$1; _sqlfile=$2; _outcsv=$3; _label=$4
    _errfile="${_outcsv}.err"

    sqlplus -s "$_conn" >"$_outcsv" 2>"$_errfile" <<SQLEOF
SET MARKUP CSV ON QUOTE ON DELIMITER ','
SET FEEDBACK OFF
SET ECHO OFF
SET VERIFY OFF
SET DEFINE OFF
SET TRIMSPOOL ON
SET PAGESIZE 50000
SET LINESIZE 32767
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT 9
@${_sqlfile}
EXIT SQL.SQLCODE
SQLEOF
    _rc=$?
    if [ $_rc -ne 0 ]; then
        err "$_label query failed (sqlplus exit code $_rc)."
        [ -s "$_errfile" ] && sed 's/^/    /' "$_errfile" >&2
        [ -s "$_outcsv" ] && sed 's/^/    /' "$_outcsv" >&2
        return 1
    fi
    if [ ! -s "$_outcsv" ]; then
        warn "$_label query returned no data."
    fi
    return 0
}

# ===========================================================================
# CDB / version detection
# ===========================================================================
CDB_MODE="NO"
DB_NAME=""
DB_MAJOR_VERSION=""

detect_db() {
    _out="${WORKDIR}/db_info.txt"
    sqlplus -s "$CONNECT_STR" >"$_out" 2>"${_out}.err" <<SQLEOF
SET HEADING OFF FEEDBACK OFF ECHO OFF VERIFY OFF DEFINE OFF PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT d.name || '|' || d.cdb || '|' || NVL((SELECT REGEXP_SUBSTR(version_full,'^[0-9]+') FROM v\$instance),'0')
FROM v\$database d;
EXIT SQL.SQLCODE
SQLEOF
    _rc=$?
    if [ $_rc -ne 0 ]; then
        err "Could not connect to '$CONNECT_STR' / query v\$database (sqlplus exit code $_rc)."
        [ -s "${_out}.err" ] && sed 's/^/    /' "${_out}.err" >&2
        [ -s "$_out" ] && sed 's/^/    /' "$_out" >&2
        return 1
    fi

    _line=$(grep -v '^[[:space:]]*$' "$_out" | head -1 | tr -d '\r')
    DB_NAME=$(printf '%s' "$_line" | awk -F'|' '{print $1}' | sed 's/^ *//;s/ *$//')
    CDB_MODE=$(printf '%s' "$_line" | awk -F'|' '{print $2}' | sed 's/^ *//;s/ *$//')
    DB_MAJOR_VERSION=$(printf '%s' "$_line" | awk -F'|' '{print $3}' | sed 's/^ *//;s/ *$//')

    if [ -z "$DB_NAME" ]; then
        err "Empty response from v\$database - check connectivity/privileges for '$CONNECT_STR'."
        return 1
    fi
    info "Target database: $DB_NAME   CDB=$CDB_MODE   major_version=${DB_MAJOR_VERSION:-unknown}"
    case "$DB_MAJOR_VERSION" in
        ''|*[!0-9]*) : ;;
        *) if [ "$DB_MAJOR_VERSION" -lt 19 ]; then
               warn "Detected Oracle major version $DB_MAJOR_VERSION. This report targets 19c+; dba_hist_*/cdb_hist_* behaviour on older versions has not been validated."
           fi ;;
    esac
    return 0
}

# ===========================================================================
# SQL templates
# ===========================================================================
# Written out as static .sql files (no shell interpolation - all dynamic
# filtering, such as -p PDB_NAME, is applied afterwards on the resulting CSV
# rather than via SQL*Plus substitution variables). This keeps the SQL text
# below identical to what you'd run by hand at a sqlplus prompt.

write_sql_templates() {
    NONCDB_SQL="${WORKDIR}/tablespace_noncdb.sql"
    CDB_SQL="${WORKDIR}/tablespace_cdb.sql"
    ASM_SQL="${WORKDIR}/asm_diskgroup.sql"

    cat > "$NONCDB_SQL" <<'SQLEOF'
-- Tablespace capacity & growth report - non-CDB (Oracle 19c+)
WITH db_info AS (
    SELECT name AS db_name FROM v$database
),
ts_current AS (
    SELECT
        ts.tablespace_name,
        COUNT(df.file_id) AS datafile_count,
        ROUND(SUM(df.bytes) / 1024/1024/1024, 2) AS allocated_gb,
        ROUND((SUM(df.bytes) - NVL(MAX(free.free_bytes), 0)) / 1024/1024/1024, 2) AS used_gb,
        ROUND(NVL(MAX(free.free_bytes), 0) / 1024/1024/1024, 2) AS free_gb,
        ts.block_size
    FROM dba_tablespaces ts
    JOIN dba_data_files df
      ON ts.tablespace_name = df.tablespace_name
    LEFT JOIN (
        SELECT tablespace_name, SUM(bytes) AS free_bytes
        FROM dba_free_space
        GROUP BY tablespace_name
    ) free
      ON free.tablespace_name = ts.tablespace_name
    GROUP BY ts.tablespace_name, ts.block_size
),
ts_with_capacity AS (
    SELECT
        tablespace_name,
        datafile_count,
        allocated_gb,
        used_gb,
        free_gb,
        CASE
            WHEN datafile_count < 1023 THEN (1023 - datafile_count) * 32
            ELSE 0
        END AS addable_gb
    FROM ts_current
),
ts_snap AS (
    SELECT
        v.name AS tablespace_name,
        TRUNC(s.begin_interval_time, 'IW') AS week_start_date,
        TRUNC(s.begin_interval_time)       AS snap_date,
        s.begin_interval_time              AS snap_time,
        (u.tablespace_usedsize * dt.block_size) AS used_bytes
    FROM dba_hist_tbspc_space_usage u
    JOIN dba_hist_snapshot s
      ON s.snap_id = u.snap_id
     AND s.dbid    = u.dbid
    JOIN v$tablespace v
      ON v.ts# = u.tablespace_id
    JOIN dba_tablespaces dt
      ON dt.tablespace_name = v.name
    WHERE s.end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(26*7, 'DAY')
),
daily_last_snap AS (
    SELECT
        tablespace_name,
        week_start_date,
        TRUNC(snap_time) AS day_date,
        used_bytes,
        ROW_NUMBER() OVER (
            PARTITION BY tablespace_name, TRUNC(snap_time)
            ORDER BY snap_time DESC
        ) AS rn
    FROM ts_snap
),
daily AS (
    SELECT tablespace_name, week_start_date, day_date AS snap_date, used_bytes
    FROM daily_last_snap
    WHERE rn = 1
),
daily_growth AS (
    SELECT
        tablespace_name,
        week_start_date,
        snap_date,
        used_bytes,
        LAG(used_bytes) OVER (PARTITION BY tablespace_name ORDER BY snap_date) AS prev_used_bytes,
        (used_bytes - LAG(used_bytes) OVER (PARTITION BY tablespace_name ORDER BY snap_date)) AS growth_bytes
    FROM daily
),
weekly_growth AS (
    SELECT tablespace_name, week_start_date, SUM(growth_bytes) AS weekly_growth_bytes
    FROM daily_growth
    GROUP BY tablespace_name, week_start_date
),
growth_summary AS (
    SELECT tablespace_name, COUNT(*) AS num_weeks, SUM(weekly_growth_bytes) AS total_growth_bytes
    FROM weekly_growth
    GROUP BY tablespace_name
)
SELECT
    db.db_name                                                        AS db_name,
    'N/A'                                                              AS pdb_name,
    c.tablespace_name                                                 AS tablespace_name,
    c.datafile_count                                                  AS datafile_count,
    c.allocated_gb                                                    AS allocated_gb,
    c.used_gb                                                         AS used_gb,
    c.free_gb                                                         AS free_gb,
    c.addable_gb                                                      AS addable_gb,
    ROUND(NVL(g.total_growth_bytes / NULLIF(g.num_weeks, 0), 0) / (1024*1024*1024), 2) AS avg_weekly_growth_gb,
    CASE
        WHEN NVL(g.total_growth_bytes, 0) > 0 THEN 'INCREASING'
        WHEN NVL(g.total_growth_bytes, 0) < 0 THEN 'DECREASING (PURGING)'
        ELSE 'STABLE'
    END                                                                AS growth_trend,
    CASE
        WHEN (g.total_growth_bytes / NULLIF(g.num_weeks,0)) <= 0 THEN NULL
        ELSE ROUND((c.free_gb + c.addable_gb) / ((g.total_growth_bytes / g.num_weeks) / (1024*1024*1024)), 2)
    END                                                                AS sustainable_weeks,
    CASE
        WHEN (g.total_growth_bytes / NULLIF(g.num_weeks,0)) <= 0 THEN 'No positive growth - sustainability not applicable.'
        ELSE 'Weeks until tablespace fills (includes addable files).'
    END                                                                AS sustainable_weeks_note,
    CASE
        WHEN c.datafile_count > 900 THEN 'RED'
        WHEN c.datafile_count > 800 THEN 'AMBER'
        ELSE 'GREEN'
    END                                                                AS color
FROM db_info db
CROSS JOIN ts_with_capacity c
LEFT JOIN growth_summary g
  ON g.tablespace_name = c.tablespace_name
ORDER BY c.tablespace_name;
SQLEOF

    cat > "$CDB_SQL" <<'SQLEOF'
-- Tablespace capacity & growth report - CDB-aware (Oracle 19c+)
-- Run connected to CDB$ROOT as a common user with access to CDB_* views
-- (e.g. SYSDBA, or SELECT_CATALOG_ROLE + SELECT ANY DICTIONARY).
-- dba_hist_*/cdb_hist_* sources require the Diagnostics Pack, same as the
-- non-CDB version of this query. NOTE: this CDB path has been built against
-- documented CDB_*/V$CONTAINERS semantics but has not been run against a
-- live multitenant instance - validate in a non-prod CDB before relying on it.
WITH db_info AS (
    SELECT name AS db_name, cdb FROM v$database
),
pdb_names AS (
    SELECT con_id, name AS pdb_name FROM v$containers
),
ts_current AS (
    SELECT
        t.con_id,
        t.tablespace_name,
        COUNT(df.file_id) AS datafile_count,
        ROUND(SUM(df.bytes) / 1024/1024/1024, 2) AS allocated_gb,
        ROUND((SUM(df.bytes) - NVL(MAX(free.free_bytes), 0)) / 1024/1024/1024, 2) AS used_gb,
        ROUND(NVL(MAX(free.free_bytes), 0) / 1024/1024/1024, 2) AS free_gb,
        t.block_size
    FROM cdb_tablespaces t
    JOIN cdb_data_files df
      ON t.tablespace_name = df.tablespace_name
     AND t.con_id          = df.con_id
    LEFT JOIN (
        SELECT con_id, tablespace_name, SUM(bytes) AS free_bytes
        FROM cdb_free_space
        GROUP BY con_id, tablespace_name
    ) free
      ON free.tablespace_name = t.tablespace_name
     AND free.con_id          = t.con_id
    WHERE t.con_id != 2  -- exclude PDB$SEED
    GROUP BY t.con_id, t.tablespace_name, t.block_size
),
ts_with_capacity AS (
    SELECT
        con_id,
        tablespace_name,
        datafile_count,
        allocated_gb,
        used_gb,
        free_gb,
        CASE
            WHEN datafile_count < 1023 THEN (1023 - datafile_count) * 32
            ELSE 0
        END AS addable_gb
    FROM ts_current
),
ts_snap AS (
    SELECT
        u.con_id,
        v.name AS tablespace_name,
        TRUNC(s.begin_interval_time, 'IW') AS week_start_date,
        TRUNC(s.begin_interval_time)       AS snap_date,
        s.begin_interval_time              AS snap_time,
        (u.tablespace_usedsize * dt.block_size) AS used_bytes
    FROM cdb_hist_tbspc_space_usage u
    JOIN cdb_hist_snapshot s
      ON s.snap_id = u.snap_id
     AND s.dbid    = u.dbid
     AND s.con_id  = u.con_id
    JOIN (SELECT con_id, ts#, name FROM CONTAINERS(v$tablespace)) v
      ON v.con_id = u.con_id
     AND v.ts#    = u.tablespace_id
    JOIN cdb_tablespaces dt
      ON dt.tablespace_name = v.name
     AND dt.con_id          = v.con_id
    WHERE s.end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(26*7, 'DAY')
      AND u.con_id != 2
),
daily_last_snap AS (
    SELECT
        con_id, tablespace_name, week_start_date,
        TRUNC(snap_time) AS day_date,
        used_bytes,
        ROW_NUMBER() OVER (
            PARTITION BY con_id, tablespace_name, TRUNC(snap_time)
            ORDER BY snap_time DESC
        ) AS rn
    FROM ts_snap
),
daily AS (
    SELECT con_id, tablespace_name, week_start_date, day_date AS snap_date, used_bytes
    FROM daily_last_snap
    WHERE rn = 1
),
daily_growth AS (
    SELECT
        con_id, tablespace_name, week_start_date, snap_date, used_bytes,
        LAG(used_bytes) OVER (PARTITION BY con_id, tablespace_name ORDER BY snap_date) AS prev_used_bytes,
        (used_bytes - LAG(used_bytes) OVER (PARTITION BY con_id, tablespace_name ORDER BY snap_date)) AS growth_bytes
    FROM daily
),
weekly_growth AS (
    SELECT con_id, tablespace_name, week_start_date, SUM(growth_bytes) AS weekly_growth_bytes
    FROM daily_growth
    GROUP BY con_id, tablespace_name, week_start_date
),
growth_summary AS (
    SELECT con_id, tablespace_name, COUNT(*) AS num_weeks, SUM(weekly_growth_bytes) AS total_growth_bytes
    FROM weekly_growth
    GROUP BY con_id, tablespace_name
)
SELECT
    db.db_name                                                        AS db_name,
    NVL(p.pdb_name, 'CON_ID_'||TO_CHAR(c.con_id))                     AS pdb_name,
    c.tablespace_name                                                 AS tablespace_name,
    c.datafile_count                                                  AS datafile_count,
    c.allocated_gb                                                    AS allocated_gb,
    c.used_gb                                                         AS used_gb,
    c.free_gb                                                         AS free_gb,
    c.addable_gb                                                      AS addable_gb,
    ROUND(NVL(g.total_growth_bytes / NULLIF(g.num_weeks, 0), 0) / (1024*1024*1024), 2) AS avg_weekly_growth_gb,
    CASE
        WHEN NVL(g.total_growth_bytes, 0) > 0 THEN 'INCREASING'
        WHEN NVL(g.total_growth_bytes, 0) < 0 THEN 'DECREASING (PURGING)'
        ELSE 'STABLE'
    END                                                                AS growth_trend,
    CASE
        WHEN (g.total_growth_bytes / NULLIF(g.num_weeks,0)) <= 0 THEN NULL
        ELSE ROUND((c.free_gb + c.addable_gb) / ((g.total_growth_bytes / g.num_weeks) / (1024*1024*1024)), 2)
    END                                                                AS sustainable_weeks,
    CASE
        WHEN (g.total_growth_bytes / NULLIF(g.num_weeks,0)) <= 0 THEN 'No positive growth - sustainability not applicable.'
        ELSE 'Weeks until tablespace fills (includes addable files).'
    END                                                                AS sustainable_weeks_note,
    CASE
        WHEN c.datafile_count > 900 THEN 'RED'
        WHEN c.datafile_count > 800 THEN 'AMBER'
        ELSE 'GREEN'
    END                                                                AS color
FROM db_info db
CROSS JOIN ts_with_capacity c
LEFT JOIN growth_summary g
  ON g.tablespace_name = c.tablespace_name AND g.con_id = c.con_id
LEFT JOIN pdb_names p
  ON p.con_id = c.con_id
ORDER BY p.pdb_name, c.tablespace_name;
SQLEOF

    cat > "$ASM_SQL" <<'SQLEOF'
-- ASM diskgroup space report. Run against the ASM instance ("/ as sysasm"),
-- not the RDBMS instance - v$asm_diskgroup is only populated there.
-- usable_file_mb already accounts for NORMAL/HIGH redundancy mirroring and
-- is generally the more meaningful "real" free-space figure than free_mb.
SELECT
    name                                              AS diskgroup_name,
    state                                              AS state,
    type                                                AS redundancy_type,
    ROUND(total_mb/1024, 2)                            AS total_gb,
    ROUND(free_mb/1024, 2)                             AS free_gb,
    ROUND((total_mb-free_mb)/total_mb*100, 2)          AS pct_used,
    ROUND(NVL(usable_file_mb, free_mb)/1024, 2)        AS usable_free_gb,
    ROUND(NVL(required_mirror_free_mb, 0)/1024, 2)     AS required_mirror_free_gb,
    offline_disks                                       AS offline_disks,
    CASE
        WHEN NVL(usable_file_mb, free_mb) / total_mb * 100 < 10 THEN 'RED'
        WHEN NVL(usable_file_mb, free_mb) / total_mb * 100 < 20 THEN 'AMBER'
        ELSE 'GREEN'
    END                                                  AS color
FROM v$asm_diskgroup
WHERE total_mb > 0
ORDER BY name;
SQLEOF
}

# ===========================================================================
# ASM diskgroup helpers
# ===========================================================================

# Looks for a running ASM instance first (ps -ef | asm_pmon_<SID>), falling
# back to an oratab entry whose SID starts with '+ASM'. Works the same way
# on Solaris and Linux since ps -ef output is equivalent on both.
detect_asm_sid() {
    # Exclude any candidate line whose command contains 'awk' first - that
    # can only be this very lookup (or another awk-based pipeline) matching
    # itself in the process table, never a real asm_pmon_<SID> background
    # process. Anchoring the field match to '^asm_pmon_' (a whole token,
    # not just a substring) is the main fix: it stops an unrelated field
    # like a literal '/asm_pmon_/' regex-with-delimiters (which can appear
    # in our own command line) from being mistaken for a real SID.
    _sid=$(ps -ef 2>/dev/null | awk '
        $0 !~ /awk/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^asm_pmon_/) {
                    n = $i
                    sub(/^asm_pmon_/, "", n)
                    print n
                    exit
                }
            }
        }')
    if [ -n "${_sid:-}" ]; then printf '%s\n' "$_sid"; return 0; fi

    _ot=$(find_oratab) || return 1
    _sid=$(awk -F: '$1 ~ /^\+ASM/ && $0 !~ /^#/ {print $1; exit}' "$_ot")
    if [ -n "${_sid:-}" ]; then printf '%s\n' "$_sid"; return 0; fi
    return 1
}

# Runs the ASM diskgroup query in a subshell so the temporary ORACLE_SID /
# ORACLE_HOME / *PATH switch never leaks into the rest of this script.
run_asm_query() {
    _outcsv=$1
    _asm_sid="${ASM_SID_OPT:-$(detect_asm_sid)}"
    if [ -z "${_asm_sid:-}" ]; then
        warn "No ASM instance found (no asm_pmon_* process and no +ASM* oratab entry). Skipping ASM diskgroup section. Use -a <ASM_SID> to override detection, or -x to silence this."
        return 1
    fi
    _asm_home=$(home_for_sid "$_asm_sid")
    if [ -z "${_asm_home:-}" ]; then
        warn "Found ASM SID '$_asm_sid' but could not resolve its ORACLE_HOME from oratab. Skipping ASM diskgroup section."
        return 1
    fi
    info "ASM instance detected: $_asm_sid ($_asm_home)"

    (
        ORACLE_SID="$_asm_sid"; export ORACLE_SID
        ORACLE_HOME="$_asm_home"; export ORACLE_HOME
        PATH="$ORACLE_HOME/bin:$PATH"; export PATH
        LD_LIBRARY_PATH="$ORACLE_HOME/lib:${LD_LIBRARY_PATH:-}"; export LD_LIBRARY_PATH
        if [ "$OS_TYPE" = "SunOS" ]; then
            LD_LIBRARY_PATH_64="$ORACLE_HOME/lib:${LD_LIBRARY_PATH_64:-}"; export LD_LIBRARY_PATH_64
        fi
        "$ORACLE_HOME/bin/sqlplus" -s "$ASM_CONNECT_STR" <<SQLEOF
SET MARKUP CSV ON QUOTE ON DELIMITER ','
SET FEEDBACK OFF
SET ECHO OFF
SET VERIFY OFF
SET DEFINE OFF
SET TRIMSPOOL ON
SET PAGESIZE 50000
SET LINESIZE 32767
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT 9
@${ASM_SQL}
EXIT SQL.SQLCODE
SQLEOF
    ) >"$_outcsv" 2>"${_outcsv}.err"
    _rc=$?
    if [ $_rc -ne 0 ]; then
        warn "ASM diskgroup query failed (sqlplus exit code $_rc). Skipping ASM diskgroup section."
        [ -s "${_outcsv}.err" ] && sed 's/^/    /' "${_outcsv}.err" >&2
        [ -s "$_outcsv" ] && sed 's/^/    /' "$_outcsv" >&2
        return 1
    fi
    if [ ! -s "$_outcsv" ]; then
        warn "ASM diskgroup query returned no rows."
        return 1
    fi
    return 0
}

# ===========================================================================
# Report-building assets (awk libraries + HTML template fragments)
# ===========================================================================
write_report_assets() {

cat > "${WORKDIR}/csvlib.awk" <<'AWKEOF'
# Shared helpers for the row-generator awk scripts.

# RFC4180-style CSV split (handles "quoted, fields" and doubled "" quotes).
# Deliberately written with only basic string ops (substr/length) so it runs
# under any awk - mawk, nawk, busybox awk, gawk - not just gawk's FPAT.
function csv_split(line, arr,    i, c, field, inquote, n) {
    n = 0; field = ""; inquote = 0
    for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (inquote) {
            if (c == "\"") {
                if (substr(line, i + 1, 1) == "\"") { field = field "\""; i++ }
                else { inquote = 0 }
            } else field = field c
        } else {
            if (c == "\"") inquote = 1
            else if (c == ",") { arr[++n] = field; field = "" }
            else field = field c
        }
    }
    arr[++n] = field
    return n
}

function htmlesc(s) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    gsub(/"/, "\\&quot;", s)
    return s
}
AWKEOF

cat > "${WORKDIR}/gen_tbsp_rows.awk" <<'AWKEOF'
# Reads the tablespace CSV (header + rows) and emits <tr> HTML to stdout.
# Aggregates written on END to: summaryfile (plain KEY=VALUE numbers, read
# back by the calling shell) and cardsfile (ready-to-embed HTML for the
# summary cards / callout, fully self-contained so no further escaping is
# needed by the shell).
BEGIN { attn_weeks = 26 }
NR == 1 {
    ncols = csv_split($0, hdr)
    for (i = 1; i <= ncols; i++) colidx[hdr[i]] = i
    next
}
$0 == "" { next }
{
    n = csv_split($0, f)
    pdb     = f[colidx["pdb_name"]]
    tsn     = f[colidx["tablespace_name"]]
    dfc     = f[colidx["datafile_count"]] + 0
    alloc   = f[colidx["allocated_gb"]] + 0
    used    = f[colidx["used_gb"]] + 0
    free    = f[colidx["free_gb"]] + 0
    addable = f[colidx["addable_gb"]] + 0
    growth  = f[colidx["avg_weekly_growth_gb"]] + 0
    trend   = f[colidx["growth_trend"]]
    sweeks_s = f[colidx["sustainable_weeks"]]
    swnote  = f[colidx["sustainable_weeks_note"]]
    color   = f[colidx["color"]]

    pct = (alloc > 0) ? (used / alloc * 100) : 0
    if (pct > 100) pct = 100
    if (pct < 0) pct = 0

    total++
    cnt[color]++
    sum_alloc += alloc; sum_used += used; sum_free += free

    has_sw = (sweeks_s != "")
    if (has_sw) {
        sw = sweeks_s + 0
        if (!have_min || sw < min_sw) { have_min = 1; min_sw = sw; min_pdb = pdb; min_ts = tsn; min_color = color }
    }

    tclass = "stable"
    if (trend == "INCREASING") tclass = "up"
    else if (trend ~ /DECREASING/) tclass = "down"

    printf "<tr class=\"r-%s\" data-pdb=\"%s\" data-ts=\"%s\">\n", tolower(color), htmlesc(pdb), htmlesc(tsn)
    printf "<td>%s</td>\n", htmlesc(pdb)
    printf "<td class=\"mono\">%s</td>\n", htmlesc(tsn)
    printf "<td class=\"num\">%d</td>\n", dfc
    printf "<td class=\"num\">%.2f</td>\n", alloc
    printf "<td class=\"num\">%.2f</td>\n", used
    printf "<td class=\"num\">%.2f</td>\n", free
    printf "<td class=\"num\">%.2f</td>\n", addable
    printf "<td class=\"barcell\"><div class=\"bar\"><div class=\"barfill bf-%s\" style=\"width:%.1f%%\"></div></div><span class=\"barlabel\">%.1f%%</span></td>\n", tolower(color), pct, pct
    printf "<td class=\"num\">%.2f</td>\n", growth
    printf "<td><span class=\"pill p-%s\">%s</span></td>\n", tclass, htmlesc(trend)
    if (has_sw)
        printf "<td class=\"num tip\" data-tip=\"%s\">%.1f</td>\n", htmlesc(swnote), sw
    else
        printf "<td class=\"num tip\" data-tip=\"%s\">-</td>\n", htmlesc(swnote)
    printf "<td><span class=\"badge b-%s\">%s</span></td>\n", tolower(color), color
    print "</tr>"
}
END {
    if (summaryfile != "") {
        print  "TS_TOTAL=" (total + 0)          > summaryfile
        print  "TS_RED="   (cnt["RED"] + 0)      > summaryfile
        print  "TS_AMBER=" (cnt["AMBER"] + 0)    > summaryfile
        print  "TS_GREEN=" (cnt["GREEN"] + 0)    > summaryfile
        close(summaryfile)
    }
    if (cardsfile != "") {
        printf "<div class=\"card red\"><div class=\"n\">%d</div><div class=\"l\">Tablespaces RED</div></div>\n", cnt["RED"] + 0 > cardsfile
        printf "<div class=\"card amber\"><div class=\"n\">%d</div><div class=\"l\">Tablespaces AMBER</div></div>\n", cnt["AMBER"] + 0 > cardsfile
        printf "<div class=\"card green\"><div class=\"n\">%d</div><div class=\"l\">Tablespaces GREEN</div></div>\n", cnt["GREEN"] + 0 > cardsfile
        printf "<div class=\"card\"><div class=\"n\">%.0f / %.0f</div><div class=\"l\">Used / Allocated (GB), %d tablespaces</div></div>\n", sum_used, sum_alloc, total + 0 > cardsfile
        close(cardsfile)
    }
    if (calloutfile != "") {
        if (have_min && min_sw < attn_weeks) {
            printf "<div class=\"callout\">Closest to capacity: <b>%s / %s</b> (status %s) - approximately <b>%.1f weeks</b> of headroom left at its current average growth rate, including any addable datafile space.</div>\n", htmlesc(min_pdb), htmlesc(min_ts), min_color, min_sw > calloutfile
        } else if (have_min) {
            printf "<div class=\"callout\">All growing tablespaces have more than %d weeks of headroom at current growth rates. Closest is <b>%s / %s</b> at approximately <b>%.1f weeks</b>.</div>\n", attn_weeks, htmlesc(min_pdb), htmlesc(min_ts), min_sw > calloutfile
        } else {
            printf "<div class=\"callout\">No tablespace currently shows positive sustained growth over the observed history, so a fill-by forecast cannot be computed for any of them.</div>\n" > calloutfile
        }
        close(calloutfile)
    }
}
AWKEOF

cat > "${WORKDIR}/gen_asm_rows.awk" <<'AWKEOF'
# Reads the ASM diskgroup CSV (header + rows) and emits <tr> HTML to stdout,
# plus summary/cards files on END (same convention as gen_tbsp_rows.awk).
NR == 1 {
    ncols = csv_split($0, hdr)
    for (i = 1; i <= ncols; i++) colidx[hdr[i]] = i
    next
}
$0 == "" { next }
{
    n = csv_split($0, f)
    dg      = f[colidx["diskgroup_name"]]
    state   = f[colidx["state"]]
    rtype   = f[colidx["redundancy_type"]]
    totgb   = f[colidx["total_gb"]] + 0
    freegb  = f[colidx["free_gb"]] + 0
    pctused = f[colidx["pct_used"]] + 0
    usable  = f[colidx["usable_free_gb"]] + 0
    reqmir  = f[colidx["required_mirror_free_gb"]] + 0
    offdsk  = f[colidx["offline_disks"]] + 0
    color   = f[colidx["color"]]

    total++
    cnt[color]++
    sum_total += totgb; sum_usable += usable

    printf "<tr class=\"r-%s\">\n", tolower(color)
    printf "<td class=\"mono\">%s</td>\n", htmlesc(dg)
    printf "<td>%s</td>\n", htmlesc(state)
    printf "<td>%s</td>\n", htmlesc(rtype)
    printf "<td class=\"num\">%.2f</td>\n", totgb
    printf "<td class=\"num\">%.2f</td>\n", freegb
    printf "<td class=\"num\">%.1f%%</td>\n", pctused
    printf "<td class=\"num\">%.2f</td>\n", usable
    printf "<td class=\"num\">%.2f</td>\n", reqmir
    printf "<td class=\"num\">%d</td>\n", offdsk
    printf "<td><span class=\"badge b-%s\">%s</span></td>\n", tolower(color), color
    print "</tr>"
}
END {
    if (summaryfile != "") {
        print "ASM_TOTAL=" (total + 0)       > summaryfile
        print "ASM_RED="   (cnt["RED"] + 0)   > summaryfile
        print "ASM_AMBER=" (cnt["AMBER"] + 0) > summaryfile
        print "ASM_GREEN=" (cnt["GREEN"] + 0) > summaryfile
        close(summaryfile)
    }
    if (cardsfile != "") {
        at_risk = (cnt["RED"] + 0) + (cnt["AMBER"] + 0)
        printf "<div class=\"card%s\"><div class=\"n\">%d / %d</div><div class=\"l\">ASM diskgroups at risk (red+amber) / total</div></div>\n", (at_risk > 0 ? " red" : ""), at_risk, total + 0 > cardsfile
        close(cardsfile)
    }
}
AWKEOF

write_html_templates
}

# ===========================================================================
# Static HTML/CSS/JS fragments. Header metadata (__DB_NAME__ etc.) is filled
# in later via a literal awk gsub pass - kept out of these heredocs so this
# text never has to be shell-interpolated (avoids sed-delimiter and
# heredoc-quoting pitfalls with the embedded CSS/JS).
# ===========================================================================
write_html_templates() {

cat > "${WORKDIR}/template_a.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Tablespace Capacity Report - __DB_NAME__</title>
<style>
:root{
  --bg:#11161c; --panel:#161d26; --panel2:#1c2530; --border:#27313d;
  --text:#e8edf2; --text-dim:#8b97a7; --accent:#5eb8ff;
  --red:#ef5765; --red-bg:rgba(239,87,101,.14);
  --amber:#f5a623; --amber-bg:rgba(245,166,35,.14);
  --green:#36c98f; --green-bg:rgba(54,201,143,.14);
  --mono: ui-monospace, "SF Mono", "Cascadia Mono", "Consolas", monospace;
  --sans: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
}
*{box-sizing:border-box;}
html,body{margin:0;padding:0;background:var(--bg);color:var(--text);font-family:var(--sans);font-size:14px;line-height:1.45;}
a{color:var(--accent);}
.topbar{padding:24px 28px 18px;border-bottom:1px solid var(--border);}
.topbar h1{margin:0 0 6px;font-size:20px;font-weight:650;letter-spacing:.2px;}
.meta{color:var(--text-dim);font-size:12.5px;font-family:var(--mono);}
.meta span{margin-right:18px;}
.wrap{padding:20px 28px 48px;max-width:1320px;margin:0 auto;}
.cards{display:flex;gap:14px;flex-wrap:wrap;margin-bottom:16px;}
.card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:14px 18px;min-width:160px;flex:1;}
.card .n{font-family:var(--mono);font-size:26px;font-weight:600;}
.card .l{color:var(--text-dim);font-size:12px;margin-top:3px;}
.card.red .n{color:var(--red);}
.card.amber .n{color:var(--amber);}
.card.green .n{color:var(--green);}
.callout{background:var(--panel);border:1px solid var(--border);border-left:3px solid var(--amber);border-radius:8px;padding:11px 16px;margin-bottom:24px;font-size:13px;color:var(--text-dim);}
.callout b{color:var(--text);}
.section-h{display:flex;align-items:center;justify-content:space-between;margin:30px 0 10px;flex-wrap:wrap;gap:10px;}
.section-h h2{font-size:13px;margin:0;text-transform:uppercase;letter-spacing:.7px;color:var(--text-dim);font-weight:700;}
.search{background:var(--panel);border:1px solid var(--border);color:var(--text);border-radius:7px;padding:7px 11px;font-size:13px;width:240px;}
.search::placeholder{color:var(--text-dim);}
.search:focus{outline:2px solid var(--accent);outline-offset:1px;}
.tablewrap{border:1px solid var(--border);border-radius:10px;overflow:auto;max-height:65vh;}
table{border-collapse:collapse;width:100%;font-size:13px;}
thead th{position:sticky;top:0;background:var(--panel2);color:var(--text-dim);text-align:left;padding:10px 12px;font-weight:600;border-bottom:1px solid var(--border);cursor:pointer;user-select:none;white-space:nowrap;}
thead th:hover{color:var(--text);}
thead th:focus-visible{outline:2px solid var(--accent);outline-offset:-2px;}
thead th.sorted-asc::after{content:" \25B2";font-size:9px;position:relative;top:-1px;}
thead th.sorted-desc::after{content:" \25BC";font-size:9px;position:relative;top:-1px;}
tbody td{padding:9px 12px;border-bottom:1px solid var(--border);vertical-align:middle;}
tbody tr:hover{background:var(--panel);}
.mono{font-family:var(--mono);}
.num{font-family:var(--mono);text-align:right;}
.badge{display:inline-block;padding:2px 9px;border-radius:99px;font-size:11px;font-weight:700;letter-spacing:.4px;}
.badge.b-red{background:var(--red-bg);color:var(--red);}
.badge.b-amber{background:var(--amber-bg);color:var(--amber);}
.badge.b-green{background:var(--green-bg);color:var(--green);}
.pill{display:inline-block;padding:2px 9px;border-radius:6px;font-size:11.5px;background:var(--panel2);color:var(--text-dim);}
.pill.p-up{color:var(--amber);}
.pill.p-down{color:var(--accent);}
.pill.p-stable{color:var(--text-dim);}
.barcell{min-width:130px;}
.bar{background:var(--panel2);border-radius:4px;height:7px;width:90px;display:inline-block;overflow:hidden;vertical-align:middle;}
.barfill{height:100%;}
.bf-red{background:var(--red);}
.bf-amber{background:var(--amber);}
.bf-green{background:var(--green);}
.barlabel{font-family:var(--mono);font-size:11.5px;color:var(--text-dim);margin-left:8px;}
.tip{position:relative;}
.tip[data-tip]:hover::after{
  content:attr(data-tip);
  position:absolute;left:0;bottom:120%;
  background:#0a0d11;color:var(--text);
  border:1px solid var(--border);
  padding:7px 10px;border-radius:6px;
  font-size:11.5px;font-family:var(--sans);
  white-space:normal;width:230px;z-index:20;
  box-shadow:0 6px 18px rgba(0,0,0,.45);
}
th.tip[data-tip]:hover::after{bottom:auto;top:120%;}
.note{color:var(--text-dim);font-size:13px;padding:14px 0;}
footer{margin-top:34px;padding-top:16px;border-top:1px solid var(--border);color:var(--text-dim);font-size:12px;}
footer code{font-family:var(--mono);background:var(--panel);padding:1px 5px;border-radius:4px;}
footer ul{margin:8px 0;padding-left:18px;}
@media (max-width:720px){ .cards{flex-direction:column;} .search{width:100%;} }
@media (prefers-reduced-motion: reduce){ *{transition:none !important;} }
</style>
</head>
<body>
<div class="topbar">
  <h1>Oracle Tablespace Capacity &amp; Growth Report</h1>
  <div class="meta">
    <span>DB: __DB_NAME__</span><span>Mode: __MODE__</span><span>Generated: __GENERATED_AT__</span><span>Tag: __TAG__</span><span>Generator v__VERSION__</span>
  </div>
</div>
<div class="wrap">
<div class="cards">
HTMLEOF

cat > "${WORKDIR}/template_b.html" <<'HTMLEOF'
<div class="section-h">
  <h2>Tablespaces</h2>
  <input class="search" type="text" placeholder="Filter by PDB or tablespace..." data-filter-target="#tbsp-body">
</div>
<div class="tablewrap">
<table data-sortable>
<thead>
<tr>
<th class="tip" data-tip="Pluggable database / container. Shows N/A for non-CDB databases.">PDB</th>
<th class="tip" data-tip="Tablespace name.">Tablespace</th>
<th data-type="num" class="tip" data-tip="Number of datafiles. Smallfile tablespaces are capped at 1023 files; status turns AMBER above 800 and RED above 900.">Datafiles</th>
<th data-type="num" class="tip" data-tip="Sum of current datafile sizes.">Allocated (GB)</th>
<th data-type="num" class="tip" data-tip="Allocated minus current free space.">Used (GB)</th>
<th data-type="num" class="tip" data-tip="Free space inside existing datafiles.">Free (GB)</th>
<th data-type="num" class="tip" data-tip="Estimated extra space obtainable by adding more datafiles, assuming up to 1023 files at up to ~32GB each (8K block size).">Addable (GB)</th>
<th data-type="num" class="tip" data-tip="Used GB as a percentage of allocated GB.">Used %</th>
<th data-type="num" class="tip" data-tip="Average weekly growth in GB over roughly the trailing 26 weeks of AWR history.">Avg Weekly Growth (GB)</th>
<th class="tip" data-tip="INCREASING / DECREASING (PURGING) / STABLE, based on total growth over the observed period.">Trend</th>
<th data-type="num" class="tip" data-tip="Estimated weeks until full at the current average growth rate, including addable datafile space. Hover a row's value for the exact note.">Sustainable (wks)</th>
<th class="tip" data-tip="RED: more than 900 datafiles. AMBER: more than 800. GREEN: otherwise.">Status</th>
</tr>
</thead>
<tbody id="tbsp-body">
HTMLEOF

cat > "${WORKDIR}/template_c.html" <<'HTMLEOF'
</tbody>
</table>
</div>
HTMLEOF

cat > "${WORKDIR}/template_asm_head.html" <<'HTMLEOF'
<div class="section-h">
  <h2>ASM Diskgroups</h2>
  <input class="search" type="text" placeholder="Filter by diskgroup..." data-filter-target="#asm-body">
</div>
<div class="tablewrap">
<table data-sortable>
<thead>
<tr>
<th class="tip" data-tip="ASM diskgroup name.">Diskgroup</th>
<th class="tip" data-tip="MOUNTED / DISMOUNTED / etc.">State</th>
<th class="tip" data-tip="EXTERNAL, NORMAL, HIGH, or FLEX redundancy.">Redundancy</th>
<th data-type="num" class="tip" data-tip="Raw total diskgroup capacity.">Total (GB)</th>
<th data-type="num" class="tip" data-tip="Raw free space before accounting for mirroring overhead.">Free (GB)</th>
<th data-type="num" class="tip" data-tip="(Total - Free) / Total.">Used %</th>
<th data-type="num" class="tip" data-tip="USABLE_FILE_MB: space actually usable for new files once redundancy/mirroring overhead is accounted for - the more realistic free-space figure for NORMAL/HIGH redundancy diskgroups.">Usable Free (GB)</th>
<th data-type="num" class="tip" data-tip="Minimum free space ASM must keep available to restore full redundancy after a disk failure.">Required Mirror Free (GB)</th>
<th data-type="num" class="tip" data-tip="Disks currently offline in this diskgroup.">Offline Disks</th>
<th class="tip" data-tip="RED: usable free below 10% of total. AMBER: below 20%. GREEN: otherwise.">Status</th>
</tr>
</thead>
<tbody id="asm-body">
HTMLEOF

cat > "${WORKDIR}/template_asm_tail.html" <<'HTMLEOF'
</tbody>
</table>
</div>
HTMLEOF

cat > "${WORKDIR}/template_d.html" <<'HTMLEOF'
<footer>
  <p>Assumptions baked into this report: smallfile tablespace limit of 1023 datafiles, up to ~32GB per datafile (8K block size); datafile-count status thresholds RED &gt;900 / AMBER &gt;800; growth figures derived from roughly the trailing 26 weeks of AWR history in <code>dba_hist_tbspc_space_usage</code> / <code>cdb_hist_tbspc_space_usage</code> (requires Diagnostics Pack); ASM status thresholds RED &lt;10% / AMBER &lt;20% usable free space.</p>
  <p>Generated by <code>tbsp_report.sh</code>. See the accompanying CSV file(s) for the underlying data and README.md for prerequisites and customization notes.</p>
</footer>
</div>
<script>
(function(){
  function norm(s){ return s.trim().toLowerCase(); }
  document.querySelectorAll('table[data-sortable]').forEach(function(table){
    var thead = table.tHead, tbody = table.tBodies[0];
    Array.prototype.forEach.call(thead.querySelectorAll('th'), function(th, idx){
      th.setAttribute('tabindex', '0');
      function doSort(){
        var type = th.getAttribute('data-type') || 'text';
        var asc = !th.classList.contains('sorted-asc');
        Array.prototype.forEach.call(thead.querySelectorAll('th'), function(h){ h.classList.remove('sorted-asc','sorted-desc'); });
        th.classList.add(asc ? 'sorted-asc' : 'sorted-desc');
        var rows = Array.prototype.slice.call(tbody.rows);
        rows.sort(function(a, b){
          var va = a.cells[idx].textContent, vb = b.cells[idx].textContent;
          if (type === 'num'){
            va = parseFloat(va); if (isNaN(va)) va = -Infinity;
            vb = parseFloat(vb); if (isNaN(vb)) vb = -Infinity;
            return asc ? va - vb : vb - va;
          }
          va = norm(va); vb = norm(vb);
          if (va < vb) return asc ? -1 : 1;
          if (va > vb) return asc ? 1 : -1;
          return 0;
        });
        rows.forEach(function(r){ tbody.appendChild(r); });
      }
      th.addEventListener('click', doSort);
      th.addEventListener('keypress', function(e){ if (e.key === 'Enter' || e.key === ' ') doSort(); });
    });
  });

  Array.prototype.forEach.call(document.querySelectorAll('input[data-filter-target]'), function(inp){
    var tbody = document.querySelector(inp.getAttribute('data-filter-target'));
    if (!tbody) return;
    inp.addEventListener('input', function(){
      var q = norm(inp.value);
      Array.prototype.forEach.call(tbody.rows, function(r){
        var pdb = norm(r.getAttribute('data-pdb') || '');
        var ts  = norm(r.getAttribute('data-ts') || '');
        var hay = pdb + ' ' + ts + ' ' + norm(r.textContent);
        r.style.display = (!q || hay.indexOf(q) > -1) ? '' : 'none';
      });
    });
  });
})();
</script>
</body>
</html>
HTMLEOF
}

# ===========================================================================
# PDB filtering (post-hoc, on the CSV - see header comment for rationale)
# ===========================================================================
filter_pdb() {
    _csv=$1
    if [ "$CDB_MODE" != "YES" ] || [ "$PDB_FILTER" = "ALL" ]; then
        return 0
    fi
    _awk="${WORKDIR}/filter_pdb.awk"
    cat > "$_awk" <<'AWKEOF'
NR == 1 {
    ncols = csv_split($0, hdr)
    for (i = 1; i <= ncols; i++) if (hdr[i] == "pdb_name") col = i
    print
    next
}
$0 == "" { next }
{
    n = csv_split($0, f)
    if (toupper(f[col]) == toupper(pdb)) print
}
AWKEOF
    _tmp="${_csv}.filtered"
    awk -v pdb="$PDB_FILTER" -f "${WORKDIR}/csvlib.awk" -f "$_awk" "$_csv" > "$_tmp"
    _kept=$(( $(wc -l < "$_tmp") - 1 ))
    [ "$_kept" -lt 0 ] && _kept=0
    mv "$_tmp" "$_csv"
    info "PDB filter '$PDB_FILTER' applied: $_kept tablespace row(s) kept."
}

# ===========================================================================
# Main
# ===========================================================================
EXIT_CODE=0

if ! detect_db; then
    die "Could not determine target database / CDB mode. Aborting." 2
fi

DB_LABEL=$(printf '%s' "$DB_NAME" | tr -c 'A-Za-z0-9' '_')

write_sql_templates
write_report_assets

if [ "$CDB_MODE" = "YES" ]; then
    REPORT_MODE_LABEL="CDB"
    [ "$PDB_FILTER" != "ALL" ] && REPORT_MODE_LABEL="CDB (PDB=$PDB_FILTER)"
    SQL_TO_RUN="$CDB_SQL"
else
    REPORT_MODE_LABEL="non-CDB"
    SQL_TO_RUN="$NONCDB_SQL"
fi

TBSP_CSV_RAW="${WORKDIR}/tbsp_raw.csv"
if ! run_sql_to_csv "$CONNECT_STR" "$SQL_TO_RUN" "$TBSP_CSV_RAW" "Tablespace capacity/growth"; then
    die "Tablespace capacity/growth query failed. See log above for the SQL*Plus error. Nothing was written to $OUTDIR." 3
fi
filter_pdb "$TBSP_CSV_RAW"

RUN_TS_DISPLAY=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
TBSP_CSV_OUT="${OUTDIR}/${DB_LABEL}_tbsp_capacity_${RUN_TS}${TAG_SFX}.csv"
cp "$TBSP_CSV_RAW" "$TBSP_CSV_OUT" || die "Could not write $TBSP_CSV_OUT" 2
info "Tablespace CSV written: $TBSP_CSV_OUT"

ASM_OK=1
ASM_CSV_OUT=""
if [ "$SKIP_ASM" -eq 1 ]; then
    info "ASM diskgroup section skipped (-x)."
else
    ASM_CSV_RAW="${WORKDIR}/asm_raw.csv"
    if run_asm_query "$ASM_CSV_RAW"; then
        ASM_OK=0
        ASM_CSV_OUT="${OUTDIR}/${DB_LABEL}_asm_diskgroup_${RUN_TS}${TAG_SFX}.csv"
        cp "$ASM_CSV_RAW" "$ASM_CSV_OUT" || die "Could not write $ASM_CSV_OUT" 2
        info "ASM diskgroup CSV written: $ASM_CSV_OUT"
    fi
fi

# ---- Generate dynamic HTML fragments from the CSV data ----
TS_ROWS="${WORKDIR}/ts_rows.html"
TS_SUMMARY="${WORKDIR}/ts_summary.txt"
TS_CARDS="${WORKDIR}/ts_cards.html"
TS_CALLOUT="${WORKDIR}/ts_callout.html"
awk -v summaryfile="$TS_SUMMARY" -v cardsfile="$TS_CARDS" -v calloutfile="$TS_CALLOUT" \
    -f "${WORKDIR}/csvlib.awk" -f "${WORKDIR}/gen_tbsp_rows.awk" "$TBSP_CSV_RAW" > "$TS_ROWS"

TS_TOTAL=0; TS_RED=0; TS_AMBER=0; TS_GREEN=0
if [ -s "$TS_SUMMARY" ]; then
    while IFS='=' read -r _k _v; do
        case "$_k" in
            TS_TOTAL) TS_TOTAL=$_v ;;
            TS_RED)   TS_RED=$_v ;;
            TS_AMBER) TS_AMBER=$_v ;;
            TS_GREEN) TS_GREEN=$_v ;;
        esac
    done < "$TS_SUMMARY"
fi

ASM_TOTAL=0; ASM_RED=0; ASM_AMBER=0; ASM_GREEN=0
ASM_ROWS="${WORKDIR}/asm_rows.html"
ASM_CARDS="${WORKDIR}/asm_cards.html"
: > "$ASM_CARDS"
if [ "$ASM_OK" -eq 0 ]; then
    ASM_SUMMARY="${WORKDIR}/asm_summary.txt"
    awk -v summaryfile="$ASM_SUMMARY" -v cardsfile="$ASM_CARDS" \
        -f "${WORKDIR}/csvlib.awk" -f "${WORKDIR}/gen_asm_rows.awk" "$ASM_CSV_RAW" > "$ASM_ROWS"
    if [ -s "$ASM_SUMMARY" ]; then
        while IFS='=' read -r _k _v; do
            case "$_k" in
                ASM_TOTAL) ASM_TOTAL=$_v ;;
                ASM_RED)   ASM_RED=$_v ;;
                ASM_AMBER) ASM_AMBER=$_v ;;
                ASM_GREEN) ASM_GREEN=$_v ;;
            esac
        done < "$ASM_SUMMARY"
    fi
fi

# ---- Fill header metadata tokens in template_a.html ----
FILLED_A="${WORKDIR}/filled_a.html"
awk -v dbname="$DB_NAME" -v gen="$RUN_TS_DISPLAY" -v mode="$REPORT_MODE_LABEL" \
    -v tag="${TAG:-none}" -v ver="$SCRIPT_VERSION" '
{
    gsub(/__DB_NAME__/, dbname)
    gsub(/__GENERATED_AT__/, gen)
    gsub(/__MODE__/, mode)
    gsub(/__TAG__/, tag)
    gsub(/__VERSION__/, ver)
    print
}' "${WORKDIR}/template_a.html" > "$FILLED_A"

# ---- Assemble the final HTML in order ----
HTML_OUT="${OUTDIR}/${DB_LABEL}_capacity_report_${RUN_TS}${TAG_SFX}.html"
{
    cat "$FILLED_A"
    cat "$TS_CARDS"
    [ "$ASM_OK" -eq 0 ] && cat "$ASM_CARDS"
    printf '</div>\n'
    cat "$TS_CALLOUT"
    cat "${WORKDIR}/template_b.html"
    cat "$TS_ROWS"
    cat "${WORKDIR}/template_c.html"
    if [ "$ASM_OK" -eq 0 ]; then
        cat "${WORKDIR}/template_asm_head.html"
        cat "$ASM_ROWS"
        cat "${WORKDIR}/template_asm_tail.html"
    else
        printf '<div class="section-h"><h2>ASM Diskgroups</h2></div>\n<p class="note">ASM diskgroup data not available for this run (no ASM instance detected, or -x was used). See the run log for details.</p>\n'
    fi
    cat "${WORKDIR}/template_d.html"
} > "$HTML_OUT"
info "HTML report written: $HTML_OUT"

# ---- Final summary ----
info "Summary: $TS_TOTAL tablespace(s) evaluated - RED=$TS_RED AMBER=$TS_AMBER GREEN=$TS_GREEN"
if [ "$ASM_OK" -eq 0 ]; then
    info "ASM: $ASM_TOTAL diskgroup(s) evaluated - RED=$ASM_RED AMBER=$ASM_AMBER GREEN=$ASM_GREEN"
    EXIT_CODE=0
else
    [ "$SKIP_ASM" -eq 0 ] && EXIT_CODE=4
fi

RUNLOG_OUT="${OUTDIR}/${DB_LABEL}_capacity_report_${RUN_TS}${TAG_SFX}.log"
cp "$LOGFILE" "$RUNLOG_OUT" 2>/dev/null

printf '\nDone. Files written to %s:\n  %s\n' "$OUTDIR" "$TBSP_CSV_OUT"
[ -n "$ASM_CSV_OUT" ] && printf '  %s\n' "$ASM_CSV_OUT"
printf '  %s\n  %s\n' "$HTML_OUT" "$RUNLOG_OUT"

exit $EXIT_CODE
