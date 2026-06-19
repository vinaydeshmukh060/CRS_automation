#!/usr/bin/env bash
#==============================================================================
# tbsp_report.sh
#
# Oracle Tablespace Capacity & Growth Report (+ ASM diskgroup space), with
# optional emailing of the result.
# ---------------------------------------------------------------------------
# Portable across Solaris (SunOS) and Linux. CDB/non-CDB aware (Oracle 19c+).
#
# Generates:
#   <tag>_tbsp_capacity_<ts>.csv     - tablespace capacity & growth data
#   <tag>_asm_diskgroup_<ts>.csv     - ASM diskgroup space data (if available)
#   <tag>_capacity_report_<ts>.html  - interactive HTML report (both sections)
#   <tag>_capacity_report_<ts>.log   - run log
#
# ASM diskgroup space is read from V$ASM_DISKGROUP via the same connection
# as everything else - the database instance's ASMB process mirrors this
# metadata for the diskgroups it actually uses, so no separate "/ as
# sysasm" connection to the ASM/grid instance is needed (and on most sites
# the DBA running this has no OS access to the grid home anyway).
#
# Emailing is optional: pass -r to also send the CSV(s)/HTML as attachments
# once they're written, with a short plain-text summary in the body (no
# HTML dump in the body). Without -r, nothing is emailed.
#
# See README.md for full documentation, assumptions and prerequisites.
#
# Usage: tbsp_report.sh [options]
#   -s ORACLE_SID   Target ORACLE_SID (default: current $ORACLE_SID)
#   -c CONNECT_STR  SQL*Plus connect string (default: "/ as sysdba")
#   -p PDB_NAME     For a CDB, restrict report to one PDB (default: ALL)
#   -o OUTDIR       Output directory (default: current directory)
#   -N TAG          Tag appended to CSV/HTML filenames and report title
#   -x              Skip the ASM diskgroup section entirely
#   -r RECIPIENTS   Comma-separated email recipients - if given, email the
#                    report after generating it
#   -f FROM_ADDR    From address for the email (default <user>@<hostname>)
#   -h              Show this help and exit
#
# Exit codes: 0 ok, 1 usage/arg error, 2 environment/prereq error,
#             3 tablespace query failed (fatal), 4 partial (ASM section
#             skipped/failed but tablespace report completed), 5 report
#             completed but -r was given and the email send failed.
#==============================================================================

# ---------------------------------------------------------------------------
# Strict-ish mode. We intentionally do NOT use 'set -e': several steps (ASM
# query, email send) are allowed to fail without aborting the whole run.
# ---------------------------------------------------------------------------
set -u

SCRIPT_NAME=$(basename "$0")
SCRIPT_VERSION="2.0.0"
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
SKIP_ASM=0
RECIPIENTS=""
FROM_ADDR=""

# Paths to SQL files written by write_sql_templates() into WORKDIR
NONCDB_SQL=""
CDB_SQL=""
ASM_SQL=""

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
    sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'
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
while getopts ":s:c:p:o:N:xr:f:h" opt; do
    case "$opt" in
        s) ORACLE_SID_OPT=$OPTARG ;;
        c) CONNECT_STR=$OPTARG ;;
        p) PDB_FILTER=$OPTARG ;;
        o) OUTDIR=$OPTARG ;;
        N) TAG=$OPTARG ;;
        x) SKIP_ASM=1 ;;
        r) RECIPIENTS=$OPTARG ;;
        f) FROM_ADDR=$OPTARG ;;
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
-- ASM diskgroup space report, run through the ordinary database connection
-- (no "/ as sysasm" needed). The database instance's ASMB background
-- process mirrors V$ASM_DISKGROUP metadata for whichever diskgroups this
-- database actually uses, so this view is populated here too - it just
-- only covers this database's diskgroups, not every diskgroup the
-- ASM/grid instance might manage for other databases on the host.
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
# ASM diskgroup helper
# ===========================================================================
# Queried directly through the same database connection as everything
# else - no separate "/ as sysasm" connection to the ASM/grid instance.
# The database's ASMB background process mirrors V$ASM_DISKGROUP metadata
# for the diskgroups it uses, so this works with the ordinary CONNECT_STR
# (e.g. plain "/ as sysdba") and needs no grid-home access at all. The
# trade-off: this only shows diskgroups this database actually uses, not
# every diskgroup the ASM/grid instance might be managing for other
# databases on the same host.
run_asm_query() {
    _outcsv=$1
    if ! run_sql_to_csv "$CONNECT_STR" "$ASM_SQL" "$_outcsv" "ASM diskgroup"; then
        warn "ASM diskgroup query failed or returned nothing. Skipping ASM diskgroup section. Use -x to silence this warning."
        return 1
    fi
    if [ ! -s "$_outcsv" ]; then
        warn "ASM diskgroup query returned no rows. Skipping ASM diskgroup section."
        return 1
    fi
    return 0
}

# ===========================================================================
# Optional email sending (only used if -r RECIPIENTS was given)
# ===========================================================================

# base64 with a fallback chain: base64 -> openssl base64 -> uuencode.
# Solaris boxes without GNU coreutils may lack a standalone 'base64'.
b64encode() {
    _in=$1
    if command -v base64 >/dev/null 2>&1; then
        base64 "$_in" 2>/dev/null && return 0
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl base64 -in "$_in" 2>/dev/null && return 0
    fi
    if command -v uuencode >/dev/null 2>&1; then
        uuencode -m "$_in" attachment 2>/dev/null | sed '1d;$d' && return 0
    fi
    return 1
}

find_mailer() {
    if [ -n "${MAILER_BIN:-}" ] && [ -x "${MAILER_BIN}" ]; then printf '%s\n' "$MAILER_BIN"; return 0; fi
    for c in /usr/sbin/sendmail /usr/lib/sendmail /opt/csw/sbin/sendmail; do
        [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    _c=$(command -v sendmail 2>/dev/null)
    [ -n "$_c" ] && [ -x "$_c" ] && { printf '%s\n' "$_c"; return 0; }
    return 1
}

# Builds a short plain-text body (no HTML dump) and a hand-rolled MIME
# multipart message attaching the CSV(s)/HTML, then hands it to a
# sendmail-compatible binary. Avoids depending on mutt/mailx attachment
# flags, which vary a lot between Solaris and Linux and between versions.
send_report_email() {
    _from="$FROM_ADDR"
    [ -z "$_from" ] && _from="$(id -un 2>/dev/null || echo oracle)@$(hostname 2>/dev/null || echo localhost)"

    _report_tag="${TAG:-${DB_LABEL}}"
    _subject="Oracle Tablespace Capacity Report [${_report_tag}] $(date '+%Y-%m-%d')"

    _asm_line=""
    [ "$ASM_OK" -eq 0 ] && _asm_line="ASM diskgroups: $ASM_TOTAL total - RED=$ASM_RED AMBER=$ASM_AMBER GREEN=$ASM_GREEN"

    _body="${WORKDIR}/email_body.txt"
    {
        printf 'Oracle Tablespace Capacity Report - Tag: %s\n\n' "$_report_tag"
        printf 'Host:        %s\n' "$(hostname 2>/dev/null || echo unknown)"
        printf 'Generated:   %s\n' "$RUN_TS_DISPLAY"
        printf 'Databases:   %s\n' "$DB_COUNT"
        printf 'Tablespaces: %s total - RED=%s AMBER=%s GREEN=%s\n' "$TS_TOTAL" "$TS_RED" "$TS_AMBER" "$TS_GREEN"
        [ -n "$_asm_line" ] && printf '%s\n' "$_asm_line"
        if [ -n "$TOP1" ]; then
            printf '\nNeeds attention soonest (lowest estimated weeks until full):\n'
            printf '  1. %s\n' "$TOP1"
            [ -n "$TOP2" ] && printf '  2. %s\n' "$TOP2"
            [ -n "$TOP3" ] && printf '  3. %s\n' "$TOP3"
        fi
        printf '\nAttachments: today'"'"'s data CSV (date=%s) and the full HTML report.\nOpen the HTML file in a browser for per-database tabs, sortable/filterable tables.\n' "$TODAY"
    } > "$_body"

    # Extract just today's rows for the CSV attachment (not the whole master)
    _today_tbsp_csv="${WORKDIR}/today_tbsp.csv"
    extract_today_csv "$MASTER_TBSP_CSV" "$_today_tbsp_csv" "$TODAY"
    _today_tbsp_name="${_report_tag}_tbsp_capacity_${TODAY}.csv"

    _today_asm_csv=""
    if [ "$ASM_OK" -eq 0 ] && [ -f "$MASTER_ASM_CSV" ]; then
        _today_asm_csv="${WORKDIR}/today_asm.csv"
        extract_today_csv "$MASTER_ASM_CSV" "$_today_asm_csv" "$TODAY"
    fi

    _boundary="----=_TBSPRPT_$(date +%s)_$$"

    _mime_attach() {
        __path=$1; __ctype=$2; __name=$3
        printf -- '--%s\r\n' "$_boundary"
        printf 'Content-Type: %s; name="%s"\r\n' "$__ctype" "$__name"
        printf 'Content-Disposition: attachment; filename="%s"\r\n' "$__name"
        printf 'Content-Transfer-Encoding: base64\r\n\r\n'
        b64encode "$__path" || { err "base64 encoding failed for $__path"; return 1; }
        printf '\r\n'
    }

    _msg="${WORKDIR}/email_message.eml"
    {
        printf 'From: %s\r\n' "$_from"
        printf 'To: %s\r\n' "$RECIPIENTS"
        printf 'Subject: %s\r\n' "$_subject"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: multipart/mixed; boundary="%s"\r\n' "$_boundary"
        printf '\r\n'
        printf 'This is a multi-part message in MIME format.\r\n'
        printf -- '--%s\r\n' "$_boundary"
        printf 'Content-Type: text/plain; charset=us-ascii\r\n'
        printf 'Content-Transfer-Encoding: 7bit\r\n\r\n'
        cat "$_body"
        printf '\r\n'
        _mime_attach "$_today_tbsp_csv" "text/csv" "$_today_tbsp_name"
        [ -n "$_today_asm_csv" ] && _mime_attach "$_today_asm_csv" "text/csv" "${_report_tag}_asm_diskgroup_${TODAY}.csv"
        _mime_attach "$HTML_OUT" "text/html" "$(basename "$HTML_OUT")"
        printf -- '--%s--\r\n' "$_boundary"
    } > "$_msg"

    _mailer=$(find_mailer)
    if [ -z "$_mailer" ]; then
        err "No sendmail-compatible binary found (checked \$MAILER_BIN, /usr/sbin/sendmail, /usr/lib/sendmail, PATH). Set MAILER_BIN=/path/to/sendmail to override. Report files still written to $OUTDIR."
        return 1
    fi
    info "Emailing to $RECIPIENTS via $_mailer (tag=$_report_tag, date=$TODAY)"
    "$_mailer" -t -oi < "$_msg"
    _rc=$?
    if [ $_rc -ne 0 ]; then
        err "Mail send failed (mailer exit code $_rc). Report files still written to $OUTDIR."
        return 1
    fi
    info "Email sent to: $RECIPIENTS"
    return 0
}

# ===========================================================================

# ===========================================================================
# CSV management: add run_date column + consolidated master CSV per -N tag
# ===========================================================================

# Prepends a "run_date" column (YYYY-MM-DD) to every row of a CSV file.
# For the ASM CSV we also inject db_name since the SQL doesn't include it.
add_date_column() {
    _raw=$1; _dated=$2; _today=$3; _dbname=${4:-}
    awk -v today="$_today" -v db="$_dbname" '
    NR==1 {
        if (db != "") print "\"run_date\",\"db_name\"," $0
        else           print "\"run_date\"," $0
        next
    }
    {
        if (db != "") print "\"" today "\",\"" db "\"," $0
        else          print "\"" today "\"," $0
    }' "$_raw" > "$_dated"
}

# Merges the dated CSV into the master CSV at OUTDIR/<TAG>_<suffix>.csv.
# Logic: remove all existing rows for (today, this DB), then append new rows.
# On first run the master CSV is created. Header is always kept.
update_master_csv() {
    _master=$1; _dated=$2; _today=$3; _dbname=$4

    if [ ! -f "$_master" ]; then
        cp "$_dated" "$_master"
        info "Created master CSV: $_master"
        return 0
    fi

    _tmp="${_master}.tmp.$$"
    # Keep header + all rows NOT matching (today, this db)
    awk -v today="$_today" -v db="$_dbname" '
    BEGIN { hdr=1 }
    hdr { print; hdr=0; next }
    {
        # Check first two quoted fields: run_date and db_name
        line=$0
        # strip leading quote, grab first field
        f1=line; sub(/^"/, "", f1); sub(/".*/, "", f1)
        rest=line; sub(/^"[^"]*","/, "", rest); f2=rest; sub(/".*/, "", f2)
        if (f1 == today && f2 == db) next
        print
    }' "$_master" > "$_tmp"
    # Append new rows (skip header of dated CSV)
    tail -n +2 "$_dated" >> "$_tmp"
    mv "$_tmp" "$_master"
    info "Updated master CSV: $_master"
}

# Extracts just today's rows from the master CSV (for email attachment).
extract_today_csv() {
    _master=$1; _out=$2; _today=$3
    awk -v today="$_today" '
    NR==1 { print; next }
    {
        f1=$0; sub(/^"/, "", f1); sub(/".*/, "", f1)
        if (f1 == today) print
    }' "$_master" > "$_out"
}


# ===========================================================================
# Report assets: awk libraries written to WORKDIR at runtime
# ===========================================================================
write_report_assets() {

# ---- Shared CSV parser (mawk/nawk/gawk portable) ----
cat > "${WORKDIR}/csvlib.awk" <<'AWKEOF'
function csv_split(line, arr,    i, c, field, inquote, n) {
    n=0; field=""; inquote=0
    for (i=1; i<=length(line); i++) {
        c=substr(line,i,1)
        if (inquote) {
            if (c=="\"") {
                if (substr(line,i+1,1)=="\"") { field=field "\""; i++ }
                else inquote=0
            } else field=field c
        } else {
            if (c=="\"") inquote=1
            else if (c==",") { arr[++n]=field; field="" }
            else field=field c
        }
    }
    arr[++n]=field; return n
}
function htmlesc(s) {
    gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s)
    gsub(/>/,"\\&gt;",s);  gsub(/"/,"\\&quot;",s)
    return s
}
function sanitize(s) { gsub(/[^A-Za-z0-9]/,"_",s); return s }
AWKEOF

# ---- Tablespace tab generator ----
# Reads the master tablespace CSV (run_date,db_name,pdb_name,...).
# For each db_name shows only its most-recent run_date rows.
# Outputs:
#   stdout        -> tab panels HTML  (one <div class=tab-panel> per db)
#   tabsfile      -> tab button HTML
#   cardsfile     -> global summary cards HTML
#   calloutfile   -> closest-to-capacity callout HTML
#   summaryfile   -> KEY=VALUE stats (read back by shell for email body)
cat > "${WORKDIR}/gen_tabs.awk" <<'AWKEOF'
BEGIN { attn_weeks=26 }

function offer_top3(sw, label) {
    if (!t1set || sw<t1sw) {
        t3sw=t2sw;t3label=t2label;t3set=t2set
        t2sw=t1sw;t2label=t1label;t2set=t1set
        t1sw=sw;  t1label=label;  t1set=1
    } else if (!t2set || sw<t2sw) {
        t3sw=t2sw;t3label=t2label;t3set=t2set
        t2sw=sw;  t2label=label;  t2set=1
    } else if (!t3set || sw<t3sw) {
        t3sw=sw; t3label=label; t3set=1
    }
}

NR==1 {
    ncols=csv_split($0,hdr)
    # NOTE: sqlplus outputs column names in UPPERCASE; tolower() normalises them.
    for (i=1;i<=ncols;i++) colidx[tolower(hdr[i])]=i
    next
}
$0=="" { next }
{
    n=csv_split($0,f)
    db=f[colidx["db_name"]]; rdate=f[colidx["run_date"]]
    if (!seen_db[db]) { dbs[++ndb]=db; seen_db[db]=1 }
    if (rdate > max_date[db]) max_date[db]=rdate
    rows[++total]=$0; row_db[total]=db; row_date[total]=rdate
}

END {
    # Alphabetical sort of db names (insertion sort)
    for (i=2;i<=ndb;i++) {
        key=dbs[i]; j=i-1
        while (j>=1 && dbs[j]>key) { dbs[j+1]=dbs[j]; j-- }
        dbs[j+1]=key
    }

    # Global aggregates over each db's latest snapshot
    for (r=1;r<=total;r++) {
        db=row_db[r]
        if (row_date[r]!=max_date[db]) continue
        n=csv_split(rows[r],f)
        color=f[colidx["color"]]
        alloc=f[colidx["allocated_gb"]]+0
        used =f[colidx["used_gb"]]+0
        sw_s =f[colidx["sustainable_weeks"]]
        pdb  =f[colidx["pdb_name"]]
        tsn  =f[colidx["tablespace_name"]]
        g_total++; g_color[color]++
        g_alloc+=alloc; g_used+=used
        db_total[db]++; db_color[db SUBSEP color]++
        db_alloc[db]+=alloc; db_used[db]+=used
        if (sw_s!="") offer_top3(sw_s+0, db " / " pdb " / " tsn " (" color ")")
    }

    # Summary file (shell reads this back)
    if (summaryfile!="") {
        print "TS_TOTAL=" (g_total+0)           > summaryfile
        print "TS_RED="   (g_color["RED"]+0)     > summaryfile
        print "TS_AMBER=" (g_color["AMBER"]+0)   > summaryfile
        print "TS_GREEN=" (g_color["GREEN"]+0)   > summaryfile
        print "DB_COUNT=" ndb                    > summaryfile
        if (t1set) print "TOP1=" t1label " - " t1sw " wks" > summaryfile
        if (t2set) print "TOP2=" t2label " - " t2sw " wks" > summaryfile
        if (t3set) print "TOP3=" t3label " - " t3sw " wks" > summaryfile
        close(summaryfile)
    }

    # Cards
    if (cardsfile!="") {
        printf "<div class=\"card red\"><div class=\"n\">%d</div><div class=\"l\">RED (all DBs)</div></div>\n",   g_color["RED"]+0   > cardsfile
        printf "<div class=\"card amber\"><div class=\"n\">%d</div><div class=\"l\">AMBER (all DBs)</div></div>\n", g_color["AMBER"]+0 > cardsfile
        printf "<div class=\"card green\"><div class=\"n\">%d</div><div class=\"l\">GREEN (all DBs)</div></div>\n", g_color["GREEN"]+0 > cardsfile
        printf "<div class=\"card\"><div class=\"n\">%.0f / %.0f GB</div><div class=\"l\">Used / Allocated &mdash; %d database(s)</div></div>\n", g_used, g_alloc, ndb > cardsfile
        close(cardsfile)
    }

    # Callout
    if (calloutfile!="") {
        if (t1set && t1sw<attn_weeks)
            printf "<div class=\"callout callout-warn\">&#9888; Closest to capacity: <b>%s</b> &mdash; approx. <b>%.1f weeks</b> of headroom (including addable files) at current growth rate.</div>\n", htmlesc(t1label), t1sw > calloutfile
        else if (t1set)
            printf "<div class=\"callout\">All growing tablespaces have more than %d weeks of headroom. Closest: <b>%s</b> at <b>%.1f weeks</b>.</div>\n", attn_weeks, htmlesc(t1label), t1sw > calloutfile
        else
            printf "<div class=\"callout\">No tablespace shows positive sustained growth &mdash; fill-by forecast not applicable.</div>\n" > calloutfile
        close(calloutfile)
    }

    # Tab buttons
    if (tabsfile!="") {
        for (d=1;d<=ndb;d++) {
            db=dbs[d]; cls=(d==1)?"tab-btn active":"tab-btn"
            red=db_color[db SUBSEP "RED"]+0; amber=db_color[db SUBSEP "AMBER"]+0
            badge=""
            if      (red>0)   badge=" <span class=\"tbadge b-red\">"   red   "</span>"
            else if (amber>0) badge=" <span class=\"tbadge b-amber\">" amber "</span>"
            printf "<button class=\"%s\" data-tab=\"%s\">%s%s</button>\n", cls, sanitize(db), htmlesc(db), badge > tabsfile
        }
        close(tabsfile)
    }

    # Tab panels (stdout)
    for (d=1;d<=ndb;d++) {
        db=dbs[d]; tid=sanitize(db); cls=(d==1)?"tab-panel active":"tab-panel"
        red=db_color[db SUBSEP "RED"]+0; amber=db_color[db SUBSEP "AMBER"]+0; green=db_color[db SUBSEP "GREEN"]+0
        printf "<div class=\"%s\" id=\"%s\">\n", cls, tid
        printf "<div class=\"db-meta\">%d tablespaces &nbsp;|&nbsp; RED: %d &nbsp; AMBER: %d &nbsp; GREEN: %d &nbsp;|&nbsp; Used: %.0f / %.0f GB &nbsp;|&nbsp; Data as of: <b>%s</b></div>\n", db_total[db], red, amber, green, db_used[db], db_alloc[db], max_date[db]
        printf "<input class=\"search\" type=\"text\" placeholder=\"Filter tablespace or PDB...\" data-filter-target=\"#tbody-%s\">\n", tid
        printf "<div class=\"tablewrap\"><table data-sortable><thead><tr>\n"
        printf "<th class=\"tip\" data-tip=\"Pluggable DB (N/A for non-CDB)\">PDB</th>\n"
        printf "<th class=\"tip\" data-tip=\"Tablespace name\">Tablespace</th>\n"
        printf "<th data-type=\"num\" class=\"tip\" data-tip=\"Datafile count. RED &gt;900, AMBER &gt;800.\">Datafiles</th>\n"
        printf "<th data-type=\"num\">Allocated (GB)</th>\n"
        printf "<th data-type=\"num\">Used (GB)</th>\n"
        printf "<th data-type=\"num\">Free (GB)</th>\n"
        printf "<th data-type=\"num\" class=\"tip\" data-tip=\"Extra space available by adding more datafiles (up to 1023 files x 32GB at 8K block size).\">Addable (GB)</th>\n"
        printf "<th data-type=\"num\">Used %%</th>\n"
        printf "<th data-type=\"num\" class=\"tip\" data-tip=\"Average weekly growth over trailing 26 weeks of AWR history.\">Avg Wkly Growth (GB)</th>\n"
        printf "<th>Trend</th>\n"
        printf "<th data-type=\"num\" class=\"tip\" data-tip=\"Estimated weeks until full at current growth rate, including addable space. Hover for note.\">Sustainable (wks)</th>\n"
        printf "<th>Status</th>\n"
        printf "</tr></thead><tbody id=\"tbody-%s\">\n", tid

        for (r=1;r<=total;r++) {
            if (row_db[r]!=db || row_date[r]!=max_date[db]) continue
            n=csv_split(rows[r],f)
            pdb    =f[colidx["pdb_name"]]
            tsn    =f[colidx["tablespace_name"]]
            dfc    =f[colidx["datafile_count"]]+0
            alloc  =f[colidx["allocated_gb"]]+0
            used   =f[colidx["used_gb"]]+0
            free   =f[colidx["free_gb"]]+0
            addable=f[colidx["addable_gb"]]+0
            growth =f[colidx["avg_weekly_growth_gb"]]+0
            trend  =f[colidx["growth_trend"]]
            sw_s   =f[colidx["sustainable_weeks"]]
            swnote =f[colidx["sustainable_weeks_note"]]
            color  =f[colidx["color"]]
            pct=(alloc>0)?(used/alloc*100):0
            if (pct>100) pct=100; if (pct<0) pct=0
            tclass="stable"
            if (trend=="INCREASING") tclass="up"
            else if (trend~/DECREASING/) tclass="down"
            printf "<tr class=\"r-%s\" data-pdb=\"%s\" data-ts=\"%s\">\n", tolower(color), htmlesc(pdb), htmlesc(tsn)
            printf "<td>%s</td><td class=\"mono\">%s</td>\n", htmlesc(pdb), htmlesc(tsn)
            printf "<td class=\"num\">%d</td>\n", dfc
            printf "<td class=\"num\">%.2f</td><td class=\"num\">%.2f</td><td class=\"num\">%.2f</td><td class=\"num\">%.2f</td>\n", alloc, used, free, addable
            printf "<td class=\"barcell\"><div class=\"bar\"><div class=\"barfill bf-%s\" style=\"width:%.1f%%\"></div></div><span class=\"barlabel\">%.1f%%</span></td>\n", tolower(color), pct, pct
            printf "<td class=\"num\">%.2f</td>\n", growth
            printf "<td><span class=\"pill p-%s\">%s</span></td>\n", tclass, htmlesc(trend)
            if (sw_s!="") printf "<td class=\"num tip\" data-tip=\"%s\">%.1f</td>\n", htmlesc(swnote), sw_s+0
            else          printf "<td class=\"num tip\" data-tip=\"%s\">-</td>\n",    htmlesc(swnote)
            printf "<td><span class=\"badge b-%s\">%s</span></td>\n", tolower(color), color
            print  "</tr>"
        }
        printf "</tbody></table></div></div>\n"
    }
}
AWKEOF

# ---- ASM tab generator ----
# Reads master ASM CSV (run_date, db_name, diskgroup_name, ...).
cat > "${WORKDIR}/gen_asm_tabs.awk" <<'AWKEOF'
NR==1 {
    ncols=csv_split($0,hdr)
    for (i=1;i<=ncols;i++) colidx[tolower(hdr[i])]=i
    next
}
$0=="" { next }
{
    n=csv_split($0,f)
    db=f[colidx["db_name"]]; rdate=f[colidx["run_date"]]
    if (!seen_db[db]) { dbs[++ndb]=db; seen_db[db]=1 }
    if (rdate > max_date[db]) max_date[db]=rdate
    rows[++total]=$0; row_db[total]=db; row_date[total]=rdate
}
END {
    for (i=2;i<=ndb;i++) {
        key=dbs[i]; j=i-1
        while (j>=1 && dbs[j]>key) { dbs[j+1]=dbs[j]; j-- }
        dbs[j+1]=key
    }
    for (r=1;r<=total;r++) {
        db=row_db[r]
        if (row_date[r]!=max_date[db]) continue
        n=csv_split(rows[r],f)
        color=f[colidx["color"]]
        g_total++; g_color[color]++
        db_color[db SUBSEP color]++
    }
    if (summaryfile!="") {
        print "ASM_TOTAL=" (g_total+0)         > summaryfile
        print "ASM_RED="   (g_color["RED"]+0)   > summaryfile
        print "ASM_AMBER=" (g_color["AMBER"]+0) > summaryfile
        print "ASM_GREEN=" (g_color["GREEN"]+0) > summaryfile
        close(summaryfile)
    }
    if (cardsfile!="") {
        at_risk=(g_color["RED"]+0)+(g_color["AMBER"]+0)
        cls=(at_risk>0)?" red":""
        printf "<div class=\"card%s\"><div class=\"n\">%d / %d</div><div class=\"l\">ASM at-risk (red+amber) / total diskgroups</div></div>\n", cls, at_risk, g_total > cardsfile
        close(cardsfile)
    }
    if (tabsfile!="") {
        for (d=1;d<=ndb;d++) {
            db=dbs[d]; cls=(d==1)?"tab-btn active":"tab-btn"
            red=db_color[db SUBSEP "RED"]+0; amber=db_color[db SUBSEP "AMBER"]+0
            badge=""
            if      (red>0)   badge=" <span class=\"tbadge b-red\">"   red   "</span>"
            else if (amber>0) badge=" <span class=\"tbadge b-amber\">" amber "</span>"
            printf "<button class=\"%s\" data-tab=\"asm-%s\">%s%s</button>\n", cls, sanitize(db), htmlesc(db), badge > tabsfile
        }
        close(tabsfile)
    }
    for (d=1;d<=ndb;d++) {
        db=dbs[d]; tid="asm-" sanitize(db); cls=(d==1)?"tab-panel active":"tab-panel"
        printf "<div class=\"%s\" id=\"%s\">\n", cls, tid
        printf "<div class=\"db-meta\">Data as of: <b>%s</b></div>\n", max_date[db]
        printf "<div class=\"tablewrap\"><table data-sortable><thead><tr>\n"
        printf "<th>Diskgroup</th><th>State</th><th>Redundancy</th>"
        printf "<th data-type=\"num\">Total (GB)</th><th data-type=\"num\">Free (GB)</th>"
        printf "<th data-type=\"num\">Used %%</th>"
        printf "<th data-type=\"num\" class=\"tip\" data-tip=\"Usable space after mirroring overhead - the realistic free-space figure for NORMAL/HIGH redundancy.\">Usable Free (GB)</th>"
        printf "<th data-type=\"num\" class=\"tip\" data-tip=\"Space ASM must keep free to restore redundancy after a disk failure.\">Req Mirror Free (GB)</th>"
        printf "<th data-type=\"num\">Offline Disks</th><th>Status</th>\n"
        printf "</tr></thead><tbody>\n"
        for (r=1;r<=total;r++) {
            if (row_db[r]!=db || row_date[r]!=max_date[db]) continue
            n=csv_split(rows[r],f)
            dg     =f[colidx["diskgroup_name"]]
            state  =f[colidx["state"]]
            rtype  =f[colidx["redundancy_type"]]
            totgb  =f[colidx["total_gb"]]+0
            freegb =f[colidx["free_gb"]]+0
            pctused=f[colidx["pct_used"]]+0
            usable =f[colidx["usable_free_gb"]]+0
            reqmir =f[colidx["required_mirror_free_gb"]]+0
            offdsk =f[colidx["offline_disks"]]+0
            color  =f[colidx["color"]]
            printf "<tr class=\"r-%s\">\n", tolower(color)
            printf "<td class=\"mono\">%s</td><td>%s</td><td>%s</td>\n", htmlesc(dg), htmlesc(state), htmlesc(rtype)
            printf "<td class=\"num\">%.2f</td><td class=\"num\">%.2f</td><td class=\"num\">%.1f%%</td>\n", totgb, freegb, pctused
            printf "<td class=\"num\">%.2f</td><td class=\"num\">%.2f</td><td class=\"num\">%d</td>\n", usable, reqmir, offdsk
            printf "<td><span class=\"badge b-%s\">%s</span></td></tr>\n", tolower(color), color
        }
        printf "</tbody></table></div></div>\n"
    }
}
AWKEOF

write_html_templates
}


# ===========================================================================
# HTML/CSS/JS templates
# ===========================================================================
write_html_templates() {

cat > "${WORKDIR}/template_head.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Tablespace Capacity Report - __REPORT_TAG__</title>
<style>
:root{
  --bg:#11161c; --panel:#161d26; --panel2:#1c2530; --border:#27313d;
  --text:#e8edf2; --text-dim:#8b97a7; --accent:#5eb8ff;
  --red:#ef5765; --red-bg:rgba(239,87,101,.14);
  --amber:#f5a623; --amber-bg:rgba(245,166,35,.14);
  --green:#36c98f; --green-bg:rgba(54,201,143,.14);
  --mono: ui-monospace,"SF Mono","Cascadia Mono","Consolas",monospace;
  --sans: -apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
}
*{box-sizing:border-box}
html,body{margin:0;padding:0;background:var(--bg);color:var(--text);font-family:var(--sans);font-size:14px;line-height:1.45}
.topbar{padding:22px 28px 16px;border-bottom:1px solid var(--border)}
.topbar h1{margin:0 0 6px;font-size:19px;font-weight:650}
.meta{color:var(--text-dim);font-size:12px;font-family:var(--mono)}
.meta span{margin-right:18px}
.wrap{padding:20px 28px 48px;max-width:1360px;margin:0 auto}
/* Cards */
.cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:14px}
.card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:13px 17px;min-width:150px;flex:1}
.card .n{font-family:var(--mono);font-size:24px;font-weight:600}
.card .l{color:var(--text-dim);font-size:12px;margin-top:3px}
.card.red .n{color:var(--red)} .card.amber .n{color:var(--amber)} .card.green .n{color:var(--green)}
/* Callout */
.callout{background:var(--panel);border:1px solid var(--border);border-left:3px solid var(--accent);border-radius:8px;padding:10px 15px;margin-bottom:22px;font-size:13px;color:var(--text-dim)}
.callout b{color:var(--text)} .callout-warn{border-left-color:var(--amber)}
/* Section headings */
.section-h{display:flex;align-items:center;justify-content:space-between;margin:28px 0 10px;flex-wrap:wrap;gap:8px}
.section-h h2{font-size:12.5px;margin:0;text-transform:uppercase;letter-spacing:.7px;color:var(--text-dim);font-weight:700}
/* Tabs */
.tabs{display:flex;gap:4px;flex-wrap:wrap;margin-bottom:12px;border-bottom:1px solid var(--border);padding-bottom:8px}
.tab-btn{background:var(--panel);border:1px solid var(--border);color:var(--text-dim);border-radius:7px;padding:6px 14px;font-size:13px;cursor:pointer;font-family:inherit;transition:background .15s}
.tab-btn:hover{background:var(--panel2);color:var(--text)}
.tab-btn.active{background:var(--panel2);color:var(--text);border-color:var(--accent)}
.tab-btn:focus-visible{outline:2px solid var(--accent)}
.tab-panel{display:none} .tab-panel.active{display:block}
.tbadge{display:inline-block;padding:1px 6px;border-radius:99px;font-size:10px;font-weight:700;margin-left:4px}
/* Per-tab db meta line */
.db-meta{font-size:12px;color:var(--text-dim);margin-bottom:8px;font-family:var(--mono)}
/* Search */
.search{background:var(--panel);border:1px solid var(--border);color:var(--text);border-radius:7px;padding:7px 11px;font-size:13px;width:260px;margin-bottom:10px;display:block}
.search::placeholder{color:var(--text-dim)} .search:focus{outline:2px solid var(--accent)}
/* Table */
.tablewrap{border:1px solid var(--border);border-radius:10px;overflow:auto;max-height:62vh}
table{border-collapse:collapse;width:100%;font-size:13px}
thead th{position:sticky;top:0;background:var(--panel2);color:var(--text-dim);text-align:left;padding:9px 11px;font-weight:600;border-bottom:1px solid var(--border);cursor:pointer;user-select:none;white-space:nowrap}
thead th:hover{color:var(--text)}
thead th.sorted-asc::after{content:" \25B2";font-size:9px}
thead th.sorted-desc::after{content:" \25BC";font-size:9px}
tbody td{padding:8px 11px;border-bottom:1px solid var(--border);vertical-align:middle}
tbody tr:last-child td{border-bottom:none}
tbody tr:hover{background:var(--panel)}
.mono{font-family:var(--mono)} .num{font-family:var(--mono);text-align:right}
.badge{display:inline-block;padding:2px 8px;border-radius:99px;font-size:11px;font-weight:700;letter-spacing:.3px}
.badge.b-red,.tbadge.b-red{background:var(--red-bg);color:var(--red)}
.badge.b-amber,.tbadge.b-amber{background:var(--amber-bg);color:var(--amber)}
.badge.b-green,.tbadge.b-green{background:var(--green-bg);color:var(--green)}
.pill{display:inline-block;padding:2px 8px;border-radius:6px;font-size:11.5px;background:var(--panel2);color:var(--text-dim)}
.pill.p-up{color:var(--amber)} .pill.p-down{color:var(--accent)} .pill.p-stable{color:var(--text-dim)}
/* Bar */
.barcell{min-width:120px}
.bar{background:var(--panel2);border-radius:4px;height:7px;width:84px;display:inline-block;overflow:hidden;vertical-align:middle}
.barfill{height:100%}
.bf-red{background:var(--red)} .bf-amber{background:var(--amber)} .bf-green{background:var(--green)}
.barlabel{font-family:var(--mono);font-size:11px;color:var(--text-dim);margin-left:7px}
/* Row colours */
.r-red td{background:rgba(239,87,101,.04)} .r-amber td{background:rgba(245,166,35,.04)}
/* Tooltip */
.tip{position:relative}
.tip[data-tip]:hover::after{content:attr(data-tip);position:absolute;left:0;bottom:120%;background:#0a0d11;color:var(--text);border:1px solid var(--border);padding:6px 10px;border-radius:6px;font-size:11.5px;font-family:var(--sans);white-space:normal;width:220px;z-index:30;box-shadow:0 6px 18px rgba(0,0,0,.45)}
th.tip[data-tip]:hover::after{bottom:auto;top:120%}
.note{color:var(--text-dim);font-size:13px;padding:12px 0}
footer{margin-top:30px;padding-top:14px;border-top:1px solid var(--border);color:var(--text-dim);font-size:12px}
footer code{font-family:var(--mono);background:var(--panel);padding:1px 5px;border-radius:4px}
@media(max-width:720px){.cards{flex-direction:column}.search{width:100%}}
@media(prefers-reduced-motion:reduce){*{transition:none !important}}
</style>
</head>
<body>
<div class="topbar">
  <h1>Oracle Tablespace Capacity &amp; Growth Report</h1>
  <div class="meta">
    <span>Tag: <b>__REPORT_TAG__</b></span>
    <span>Generated: __GENERATED_AT__</span>
    <span>Generator v__VERSION__</span>
  </div>
</div>
<div class="wrap">
HTMLEOF

cat > "${WORKDIR}/template_foot.html" <<'HTMLEOF'
<footer>
  <p>Assumptions: smallfile tablespace limit 1023 datafiles, up to ~32GB/file (8K block size); status RED &gt;900 files / AMBER &gt;800; growth from trailing 26 weeks of AWR history in <code>dba_hist_tbspc_space_usage</code> / <code>cdb_hist_tbspc_space_usage</code> (Diagnostics Pack required); ASM status RED &lt;10% / AMBER &lt;20% usable free space.</p>
  <p>Generated by <code>tbsp_report.sh</code>. See accompanying CSV file(s) for raw data.</p>
</footer>
</div>
<script>
(function(){
  // Tab switching
  document.querySelectorAll('.tabs').forEach(function(tabs){
    tabs.querySelectorAll('.tab-btn').forEach(function(btn){
      btn.addEventListener('click',function(){
        var tid=btn.getAttribute('data-tab')
        tabs.querySelectorAll('.tab-btn').forEach(function(b){b.classList.remove('active')})
        btn.classList.add('active')
        // find sibling tab panels (next siblings of tabs container)
        var el=tabs.nextElementSibling
        while(el && (el.classList.contains('tab-panel')||el.tagName==='DIV')){
          if(el.classList.contains('tab-panel')){
            el.classList.toggle('active', el.id===tid)
          }
          el=el.nextElementSibling
        }
      })
    })
  })
  // Column sort
  document.querySelectorAll('table[data-sortable]').forEach(function(t){
    var tb=t.tBodies[0]
    Array.prototype.forEach.call(t.tHead.querySelectorAll('th'),function(th,idx){
      th.tabIndex=0
      function sort(){
        var type=th.getAttribute('data-type')||'text'
        var asc=!th.classList.contains('sorted-asc')
        Array.prototype.forEach.call(t.tHead.querySelectorAll('th'),function(h){h.classList.remove('sorted-asc','sorted-desc')})
        th.classList.add(asc?'sorted-asc':'sorted-desc')
        Array.prototype.slice.call(tb.rows).sort(function(a,b){
          var va=a.cells[idx].textContent, vb=b.cells[idx].textContent
          if(type==='num'){va=parseFloat(va)||(-Infinity);vb=parseFloat(vb)||(-Infinity);return asc?va-vb:vb-va}
          va=va.trim().toLowerCase();vb=vb.trim().toLowerCase()
          return asc?(va<vb?-1:va>vb?1:0):(vb<va?-1:vb>va?1:0)
        }).forEach(function(r){tb.appendChild(r)})
      }
      th.addEventListener('click',sort)
      th.addEventListener('keypress',function(e){if(e.key==='Enter'||e.key===' ')sort()})
    })
  })
  // Search/filter
  document.querySelectorAll('input[data-filter-target]').forEach(function(inp){
    var tb=document.querySelector(inp.getAttribute('data-filter-target'))
    if(!tb)return
    inp.addEventListener('input',function(){
      var q=inp.value.trim().toLowerCase()
      Array.prototype.forEach.call(tb.rows,function(r){
        var hay=(r.getAttribute('data-pdb')||'')+(r.getAttribute('data-ts')||'')+r.textContent
        r.style.display=(!q||hay.toLowerCase().indexOf(q)>-1)?'':'none'
      })
    })
  })
})()
</script>
</body></html>
HTMLEOF
}


# ===========================================================================
# PDB post-filter (CDB mode, applied to raw per-run CSV before merging)
# ===========================================================================
filter_pdb() {
    _csv=$1
    if [ "$CDB_MODE" != "YES" ] || [ "$PDB_FILTER" = "ALL" ]; then return 0; fi
    _tmp="${_csv}.fpdb.$$"
    awk -v pdb="$PDB_FILTER" '
    NR==1 {
        ncols=split($0,hdr,","); for(i=1;i<=ncols;i++){h=hdr[i];gsub(/"/,"",h);if(tolower(h)=="pdb_name")col=i}
        print; next
    }
    {
        n=split($0,f,","); v=f[col]; gsub(/"/,"",v)
        if (toupper(v)==toupper(pdb)) print
    }' "$_csv" > "$_tmp"
    _kept=$(( $(wc -l < "$_tmp") - 1 )); [ "$_kept" -lt 0 ] && _kept=0
    mv "$_tmp" "$_csv"
    info "PDB filter '$PDB_FILTER' applied: $_kept row(s) kept."
}

# ===========================================================================
# Main
# ===========================================================================
EXIT_CODE=0
TODAY=$(date '+%Y-%m-%d')
RUN_TS_DISPLAY=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')

if ! detect_db; then
    die "Could not determine target database / CDB mode. Aborting." 2
fi

DB_LABEL=$(printf '%s' "$DB_NAME" | tr -c 'A-Za-z0-9' '_')

write_sql_templates
write_report_assets   # writes awk files + html templates into WORKDIR

if [ "$CDB_MODE" = "YES" ]; then
    REPORT_MODE_LABEL="CDB"
    [ "$PDB_FILTER" != "ALL" ] && REPORT_MODE_LABEL="CDB (PDB=$PDB_FILTER)"
    SQL_TO_RUN="$CDB_SQL"
else
    REPORT_MODE_LABEL="non-CDB"
    SQL_TO_RUN="$NONCDB_SQL"
fi

# ---- Determine output file names (tag-based when -N given) ----
if [ -n "$TAG" ]; then
    MASTER_TBSP_CSV="${OUTDIR}/${TAG}_tbsp_capacity.csv"
    MASTER_ASM_CSV="${OUTDIR}/${TAG}_asm_diskgroup.csv"
    HTML_OUT="${OUTDIR}/${TAG}_capacity_report.html"
    RUNLOG_OUT="${OUTDIR}/${TAG}_$(date '+%Y%m%d_%H%M%S').log"
else
    MASTER_TBSP_CSV="${OUTDIR}/${DB_LABEL}_tbsp_capacity_${RUN_TS}.csv"
    MASTER_ASM_CSV="${OUTDIR}/${DB_LABEL}_asm_diskgroup_${RUN_TS}.csv"
    HTML_OUT="${OUTDIR}/${DB_LABEL}_capacity_report_${RUN_TS}.html"
    RUNLOG_OUT="${OUTDIR}/${DB_LABEL}_capacity_report_${RUN_TS}.log"
fi

# ---- Run tablespace query -> raw CSV -> add date -> merge into master ----
TBSP_RAW="${WORKDIR}/tbsp_raw.csv"
if ! run_sql_to_csv "$CONNECT_STR" "$SQL_TO_RUN" "$TBSP_RAW" "Tablespace capacity/growth"; then
    die "Tablespace capacity/growth query failed. See log above. Nothing written to $OUTDIR." 3
fi
filter_pdb "$TBSP_RAW"

TBSP_DATED="${WORKDIR}/tbsp_dated.csv"
add_date_column "$TBSP_RAW" "$TBSP_DATED" "$TODAY"
update_master_csv "$MASTER_TBSP_CSV" "$TBSP_DATED" "$TODAY" "$DB_NAME"

# ---- ASM query -> raw CSV -> add date+db_name -> merge into master ----
ASM_OK=1; ASM_CSV_OUT=""
if [ "$SKIP_ASM" -eq 1 ]; then
    info "ASM diskgroup section skipped (-x)."
else
    ASM_RAW="${WORKDIR}/asm_raw.csv"
    if run_asm_query "$ASM_RAW"; then
        ASM_OK=0
        ASM_DATED="${WORKDIR}/asm_dated.csv"
        add_date_column "$ASM_RAW" "$ASM_DATED" "$TODAY" "$DB_NAME"
        update_master_csv "$MASTER_ASM_CSV" "$ASM_DATED" "$TODAY" "$DB_NAME"
        ASM_CSV_OUT="$MASTER_ASM_CSV"
    fi
fi

# ---- Generate HTML from master CSVs ----
TS_TABS="${WORKDIR}/ts_tab_btns.html"
TS_PANELS="${WORKDIR}/ts_panels.html"
TS_CARDS="${WORKDIR}/ts_cards.html"
TS_CALLOUT="${WORKDIR}/ts_callout.html"
TS_SUMMARY="${WORKDIR}/ts_summary.txt"

awk -v tabsfile="$TS_TABS" -v cardsfile="$TS_CARDS" \
    -v calloutfile="$TS_CALLOUT" -v summaryfile="$TS_SUMMARY" \
    -f "${WORKDIR}/csvlib.awk" -f "${WORKDIR}/gen_tabs.awk" \
    "$MASTER_TBSP_CSV" > "$TS_PANELS"

TS_TOTAL=0; TS_RED=0; TS_AMBER=0; TS_GREEN=0; DB_COUNT=0
TOP1=""; TOP2=""; TOP3=""
if [ -s "$TS_SUMMARY" ]; then
    while IFS='=' read -r _k _v; do
        case "$_k" in
            TS_TOTAL)  TS_TOTAL=$_v  ;;
            TS_RED)    TS_RED=$_v    ;;
            TS_AMBER)  TS_AMBER=$_v  ;;
            TS_GREEN)  TS_GREEN=$_v  ;;
            DB_COUNT)  DB_COUNT=$_v  ;;
            TOP1)      TOP1=$_v      ;;
            TOP2)      TOP2=$_v      ;;
            TOP3)      TOP3=$_v      ;;
        esac
    done < "$TS_SUMMARY"
fi

ASM_TABS="${WORKDIR}/asm_tab_btns.html"; : > "$ASM_TABS"
ASM_PANELS="${WORKDIR}/asm_panels.html"; : > "$ASM_PANELS"
ASM_CARDS="${WORKDIR}/asm_cards.html";  : > "$ASM_CARDS"
ASM_SUMMARY="${WORKDIR}/asm_summary.txt"
ASM_TOTAL=0; ASM_RED=0; ASM_AMBER=0; ASM_GREEN=0
if [ "$ASM_OK" -eq 0 ]; then
    awk -v tabsfile="$ASM_TABS" -v cardsfile="$ASM_CARDS" -v summaryfile="$ASM_SUMMARY" \
        -f "${WORKDIR}/csvlib.awk" -f "${WORKDIR}/gen_asm_tabs.awk" \
        "$MASTER_ASM_CSV" > "$ASM_PANELS"
    if [ -s "$ASM_SUMMARY" ]; then
        while IFS='=' read -r _k _v; do
            case "$_k" in
                ASM_TOTAL) ASM_TOTAL=$_v ;;
                ASM_RED)   ASM_RED=$_v   ;;
                ASM_AMBER) ASM_AMBER=$_v ;;
                ASM_GREEN) ASM_GREEN=$_v ;;
            esac
        done < "$ASM_SUMMARY"
    fi
fi

# ---- Fill tokens in head template ----
REPORT_TAG="${TAG:-${DB_LABEL}}"
FILLED_HEAD="${WORKDIR}/head.html"
awk -v rtag="$REPORT_TAG" -v gen="$RUN_TS_DISPLAY" -v ver="$SCRIPT_VERSION" '
{ gsub(/__REPORT_TAG__/,rtag); gsub(/__GENERATED_AT__/,gen); gsub(/__VERSION__/,ver); print }
' "${WORKDIR}/template_head.html" > "$FILLED_HEAD"

# ---- Assemble final HTML ----
{
    cat "$FILLED_HEAD"
    # Cards row
    printf '<div class="cards">\n'
    cat "$TS_CARDS"
    [ -s "$ASM_CARDS" ] && cat "$ASM_CARDS"
    printf '</div>\n'
    # Callout
    cat "$TS_CALLOUT"
    # Tablespace section
    printf '<div class="section-h"><h2>Tablespaces</h2></div>\n'
    printf '<div class="tabs">\n'; cat "$TS_TABS"; printf '</div>\n'
    cat "$TS_PANELS"
    # ASM section
    if [ "$ASM_OK" -eq 0 ]; then
        printf '<div class="section-h"><h2>ASM Diskgroups</h2></div>\n'
        printf '<div class="tabs">\n'; cat "$ASM_TABS"; printf '</div>\n'
        cat "$ASM_PANELS"
    else
        printf '<div class="section-h"><h2>ASM Diskgroups</h2></div>\n<p class="note">ASM data not available (database may use filesystem storage, query failed, or -x used). See the run log for details.</p>\n'
    fi
    cat "${WORKDIR}/template_foot.html"
} > "$HTML_OUT"
info "HTML report written: $HTML_OUT"

# ---- Summary ----
info "Tablespaces: $TS_TOTAL across $DB_COUNT DB(s) - RED=$TS_RED AMBER=$TS_AMBER GREEN=$TS_GREEN"
[ "$ASM_OK" -eq 0 ] && info "ASM: $ASM_TOTAL diskgroup(s) - RED=$ASM_RED AMBER=$ASM_AMBER GREEN=$ASM_GREEN"
[ "$ASM_OK" -ne 0 ] && [ "$SKIP_ASM" -eq 0 ] && EXIT_CODE=4

# ---- Optional email: send today's slice of the master CSV ----
MAIL_SENT=0
if [ -n "$RECIPIENTS" ]; then
    send_report_email && MAIL_SENT=1 || EXIT_CODE=5
fi

cp "$LOGFILE" "$RUNLOG_OUT" 2>/dev/null

printf '\nDone. Output directory: %s\n' "$OUTDIR"
printf '  Tablespace CSV: %s\n' "$MASTER_TBSP_CSV"
[ -n "$ASM_CSV_OUT" ] && printf '  ASM CSV:        %s\n' "$ASM_CSV_OUT"
printf '  HTML report:    %s\n' "$HTML_OUT"
printf '  Log:            %s\n' "$RUNLOG_OUT"
[ "$MAIL_SENT" -eq 1 ] && printf '\nEmailed to: %s\n' "$RECIPIENTS"

exit $EXIT_CODE
