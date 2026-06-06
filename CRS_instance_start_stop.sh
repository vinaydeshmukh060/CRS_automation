#!/bin/ksh
# =============================================================================
# Script  : oracle_rac_mgmt.sh
# Purpose : Oracle Grid Infrastructure & RAC Database Local Node Management
# Version : 3.0.0
# Author  : Enterprise DBA Toolkit
# License : Internal Use Only
#
# Compatibility:
#   - RHEL / OEL 7.x, 8.x, 9.x
#   - Oracle Solaris 11.x
#   - Oracle Grid Infrastructure 19c / 23c
#   - Requires KornShell (ksh93) or Bash 4+
#
# Usage:
#   oracle_rac_mgmt.sh [-d|--dry-run] [-h|--help]
#
# Flags:
#   -d, --dry-run   Print commands that would execute; do NOT alter cluster state
#   -h, --help      Display this usage message and exit
#
# Audit Logging:
#   - Every action, command, status check, and operator confirmation is
#     timestamped and written to a persistent audit log under LOG_BASE_DIR.
#   - Console output (colours) and log output (plain text) are generated in
#     parallel via a tee pipe; the log file is NEVER written with ANSI codes.
#   - Log files rotate automatically when they exceed LOG_MAX_BYTES.
#   - Log directory and files are created with mode 750/640 (oracle:oinstall).
#
# Security:
#   - Executable only by 'oracle' or 'grid' OS users
#   - Root execution is explicitly blocked
#   - Snapshot files written to a mode-700 private temp directory
#   - All temp artefacts removed on EXIT via trap
#   - No eval on user-supplied input; only on internally-constructed index keys
# =============================================================================

# ---------------------------------------------------------------------------
# STRICT ERROR HANDLING
# ---------------------------------------------------------------------------
set -o nounset
# Note: -o errexit is intentionally omitted; srvctl/crsctl return non-zero
# for valid "already stopped" or "resource not registered" states.

# ---------------------------------------------------------------------------
# GLOBAL CONSTANTS
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="3.0.0"
readonly REQUIRED_USERS="oracle grid"

# ---------------------------------------------------------------------------
# AUDIT LOG CONFIGURATION
# Customise LOG_BASE_DIR to match your site standard.
# ---------------------------------------------------------------------------
LOG_BASE_DIR="/var/log/oracle/rac_mgmt"   # override with env var if desired
LOG_MAX_BYTES=10485760                     # rotate at 10 MB
LOG_FILE=""                                # set after directory is confirmed
SESSION_ID=""                              # unique per invocation

# Snapshot / temp directory (created securely at runtime)
WORK_DIR=""
PRE_SNAP_CRS=""
PRE_SNAP_DB=""
POST_SNAP_CRS=""
POST_SNAP_DB=""

# Dry-run flag (0=off, 1=on)
DRY_RUN=0

# Status-check wait tuning (seconds)
STATUS_POLL_INTERVAL=10
STATUS_MAX_WAIT=300      # 5-minute ceiling per resource

# Colour codes (console only; never written to log)
C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_BOLD="" C_RESET=""

# Environment – populated by discovery functions
GRID_HOME=""
CRSCTL=""
LOCAL_NODE=""
ORATAB=""
OS_FAMILY=""
OS_TYPE=""

# Parallel-array DB registry  (POSIX-safe; no typeset -A)
DB_NAMES=""
DB_COUNT=0

# ---------------------------------------------------------------------------
# TERMINAL COLOUR SETUP
# ---------------------------------------------------------------------------
setup_colours() {
    if [ -t 1 ]; then
        C_RED='\033[0;31m'
        C_GREEN='\033[0;32m'
        C_YELLOW='\033[1;33m'
        C_CYAN='\033[0;36m'
        C_BOLD='\033[1m'
        C_RESET='\033[0m'
    fi
}

# ---------------------------------------------------------------------------
# AUDIT LOG INFRASTRUCTURE
#
# Design:
#   audit_log  – writes a plain-text line to the log file (no ANSI)
#   The log_* helpers write to BOTH stdout (coloured) AND the audit file.
#   A session header/footer bracket every execution.
# ---------------------------------------------------------------------------

# Initialise the log directory and file
init_audit_log() {
    # Allow env-var override of log directory
    LOG_BASE_DIR="${ORACLE_RAC_MGMT_LOGDIR:-${LOG_BASE_DIR}}"

    # Create directory hierarchy with safe permissions
    if [ ! -d "${LOG_BASE_DIR}" ]; then
        mkdir -p "${LOG_BASE_DIR}" 2>/dev/null || {
            # Fallback to home directory if system path not writable
            LOG_BASE_DIR="${HOME}/rac_mgmt_logs"
            mkdir -p "${LOG_BASE_DIR}"
        }
    fi
    chmod 750 "${LOG_BASE_DIR}"

    SESSION_ID=$(date '+%Y%m%d_%H%M%S')_$$
    LOG_FILE="${LOG_BASE_DIR}/rac_mgmt_$(date '+%Y%m%d').log"

    # Rotate if over size limit
    rotate_log_if_needed

    # Write session open banner to log
    audit_log "=========================================================================="
    audit_log "SESSION START  id=${SESSION_ID}"
    audit_log "  Script      : ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    audit_log "  OS User     : $(id -un)  (uid=$(id -u))"
    audit_log "  Invocation  : $0 $*"
    audit_log "  Dry-Run     : ${DRY_RUN}"
    audit_log "  PID         : $$"
    audit_log "  Terminal    : ${TERM:-non-interactive}"
    audit_log "=========================================================================="
}

# Rotate log if it exceeds LOG_MAX_BYTES
rotate_log_if_needed() {
    [ ! -f "${LOG_FILE}" ] && return
    _size=$(wc -c < "${LOG_FILE}" 2>/dev/null || printf '0')
    # Strip leading whitespace (wc output varies by platform)
    _size=$(printf '%s' "${_size}" | sed 's/^[[:space:]]*//')
    if [ "${_size}" -ge "${LOG_MAX_BYTES}" ]; then
        _rotated="${LOG_FILE%.log}_$(date '+%Y%m%d_%H%M%S').log"
        mv "${LOG_FILE}" "${_rotated}"
        # Keep only the 10 most recent rotated files
        ls -1t "${LOG_BASE_DIR}"/rac_mgmt_*.log 2>/dev/null | \
            tail -n +11 | while read -r _old; do rm -f "${_old}"; done
    fi
}

# Core audit writer – plain text only, always timestamped
audit_log() {
    _ts=$(date '+%Y-%m-%dT%H:%M:%S')
    printf '%s  %s\n' "${_ts}" "$*" >> "${LOG_FILE}"
}

# Write the session-close footer
close_audit_log() {
    audit_log "=========================================================================="
    audit_log "SESSION END    id=${SESSION_ID}  exit_code=${1:-0}"
    audit_log "=========================================================================="
}

# ---------------------------------------------------------------------------
# LOGGING HELPERS (console + audit file)
# Strip ANSI sequences when writing to log using tr/sed
# ---------------------------------------------------------------------------
_strip_ansi() {
    # Remove ESC [ ... m sequences (POSIX sed with BRE)
    printf '%s' "$*" | sed 's/\x1b\[[0-9;]*m//g; s/\\033\[[0-9;]*m//g'
}

log_info() {
    printf "${C_CYAN}[INFO]${C_RESET}  %s\n" "$*"
    audit_log "[INFO]   $(_strip_ansi "$*")"
}
log_ok() {
    printf "${C_GREEN}[OK]${C_RESET}    %s\n" "$*"
    audit_log "[OK]     $(_strip_ansi "$*")"
}
log_warn() {
    printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$*"
    audit_log "[WARN]   $(_strip_ansi "$*")"
}
log_error() {
    printf "${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2
    audit_log "[ERROR]  $(_strip_ansi "$*")"
}
log_dryrun() {
    printf "${C_YELLOW}[DRY-RUN]${C_RESET} Would execute: %s\n" "$*"
    audit_log "[DRY-RUN] Would execute: $(_strip_ansi "$*")"
}
log_audit() {
    # Explicit audit event – highlighted on console, structured in log
    printf "${C_BOLD}[AUDIT]${C_RESET}  %s\n" "$*"
    audit_log "[AUDIT]  $(_strip_ansi "$*")"
}
log_section() {
    printf "\n${C_BOLD}-----------------------------------------------------${C_RESET}\n"
    printf "${C_BOLD}  %s${C_RESET}\n" "$*"
    printf "${C_BOLD}-----------------------------------------------------${C_RESET}\n"
    audit_log "--- SECTION: $(_strip_ansi "$*") ---"
}

# ---------------------------------------------------------------------------
# STATUS CAPTURE HELPERS
# These write both to console and to the audit log for a complete record.
# ---------------------------------------------------------------------------

# Capture and log the CRS resource table
log_crs_status() {
    _label="${1:-CRS Resource Status}"
    printf "\n${C_BOLD}=== %s ===${C_RESET}\n" "${_label}"
    audit_log ">>> BEGIN: ${_label}"
    "${CRSCTL}" stat res -t 2>&1 | while IFS= read -r _line; do
        printf '%s\n' "${_line}"
        audit_log "    ${_line}"
    done
    audit_log "<<< END: ${_label}"
}

# Capture and log srvctl status for one database
log_db_status() {
    _oh="$1"; _db="$2"; _label="${3:-Database Status}"
    printf "\n${C_CYAN}  [%s] %s${C_RESET}\n" "${_label}" "${_db}"
    audit_log ">>> BEGIN: ${_label} db=${_db}"
    ORACLE_HOME="${_oh}" "${_oh}/bin/srvctl" status database -d "${_db}" -v 2>&1 | \
        while IFS= read -r _line; do
            printf '    %s\n' "${_line}"
            audit_log "    ${_line}"
        done
    audit_log "<<< END: ${_label} db=${_db}"
}

# Capture and log srvctl status for one instance
log_inst_status() {
    _oh="$1"; _db="$2"; _sid="$3"; _label="${4:-Instance Status}"
    printf "\n${C_CYAN}  [%s] %s / %s${C_RESET}\n" "${_label}" "${_db}" "${_sid}"
    audit_log ">>> BEGIN: ${_label} db=${_db} instance=${_sid}"
    ORACLE_HOME="${_oh}" "${_oh}/bin/srvctl" status instance -d "${_db}" -i "${_sid}" 2>&1 | \
        while IFS= read -r _line; do
            printf '    %s\n' "${_line}"
            audit_log "    ${_line}"
        done
    audit_log "<<< END: ${_label} db=${_db} instance=${_sid}"
}

# ---------------------------------------------------------------------------
# POST-OPERATION STATE VALIDATOR
#
# Polls srvctl until the target instance/database reaches the expected state,
# or until STATUS_MAX_WAIT seconds elapse.
#
# Usage:
#   verify_instance_state  <oracle_home> <db_name> <instance_sid> \
#                          <expected_keyword>  <timeout_secs>
#   verify_database_state  <oracle_home> <db_name> \
#                          <expected_keyword>  <timeout_secs>
#   verify_crs_state       <expected_keyword>  <timeout_secs>
#
# <expected_keyword> is matched case-insensitively against srvctl/crsctl output.
# Common values: "running", "stopped", "online", "offline"
# ---------------------------------------------------------------------------

verify_instance_state() {
    _voh="$1"; _vdb="$2"; _vsid="$3"; _expect="$4"
    _timeout="${5:-${STATUS_MAX_WAIT}}"
    _elapsed=0

    log_info "Verifying instance '${_vsid}' reaches state '${_expect}' (timeout=${_timeout}s)..."
    audit_log "[VERIFY] Waiting for instance ${_vsid} (db=${_vdb}) to reach state '${_expect}'"

    while [ "${_elapsed}" -lt "${_timeout}" ]; do
        _out=$(ORACLE_HOME="${_voh}" "${_voh}/bin/srvctl" status instance \
               -d "${_vdb}" -i "${_vsid}" 2>&1)
        _match=$(printf '%s' "${_out}" | grep -i "${_expect}" | head -1)
        if [ -n "${_match}" ]; then
            log_ok "VERIFIED: Instance '${_vsid}' is ${_expect} (elapsed ${_elapsed}s)."
            audit_log "[VERIFY-PASS] instance=${_vsid} state=${_expect} elapsed=${_elapsed}s"
            audit_log "[VERIFY-OUT]  ${_out}"
            return 0
        fi
        sleep "${STATUS_POLL_INTERVAL}"
        _elapsed=$((_elapsed + STATUS_POLL_INTERVAL))
        log_info "  Still waiting... (${_elapsed}/${_timeout}s) – current: ${_out}"
    done

    log_error "VERIFY FAILED: Instance '${_vsid}' did NOT reach '${_expect}' within ${_timeout}s."
    audit_log "[VERIFY-FAIL] instance=${_vsid} expected=${_expect} timeout=${_timeout}s"
    audit_log "[VERIFY-LAST] ${_out}"
    return 1
}

verify_database_state() {
    _voh="$1"; _vdb="$2"; _expect="$3"
    _timeout="${4:-${STATUS_MAX_WAIT}}"
    _elapsed=0

    log_info "Verifying database '${_vdb}' reaches state '${_expect}' (timeout=${_timeout}s)..."
    audit_log "[VERIFY] Waiting for database ${_vdb} to reach state '${_expect}'"

    while [ "${_elapsed}" -lt "${_timeout}" ]; do
        _out=$(ORACLE_HOME="${_voh}" "${_voh}/bin/srvctl" status database \
               -d "${_vdb}" -v 2>&1)
        # All lines must contain the expected keyword for a database-level check
        _total=$(printf '%s\n' "${_out}" | grep -c 'Instance\|instance' 2>/dev/null || printf '0')
        _matched=$(printf '%s\n' "${_out}" | grep -i "${_expect}" | grep -c 'Instance\|instance' 2>/dev/null || printf '0')
        if [ "${_total}" -gt 0 ] && [ "${_matched}" -eq "${_total}" ]; then
            log_ok "VERIFIED: All instances of '${_vdb}' are ${_expect} (elapsed ${_elapsed}s)."
            audit_log "[VERIFY-PASS] database=${_vdb} state=${_expect} elapsed=${_elapsed}s"
            audit_log "[VERIFY-OUT]  ${_out}"
            return 0
        fi
        # Partial match — show which instances are not yet in desired state
        _not_matched=$(printf '%s\n' "${_out}" | grep -v -i "${_expect}" | grep -i 'Instance\|instance')
        sleep "${STATUS_POLL_INTERVAL}"
        _elapsed=$((_elapsed + STATUS_POLL_INTERVAL))
        log_info "  Still waiting... (${_elapsed}/${_timeout}s) – not yet ${_expect}: ${_not_matched}"
    done

    log_error "VERIFY FAILED: Database '${_vdb}' did NOT fully reach '${_expect}' within ${_timeout}s."
    audit_log "[VERIFY-FAIL] database=${_vdb} expected=${_expect} timeout=${_timeout}s"
    audit_log "[VERIFY-LAST] ${_out}"
    return 1
}

verify_crs_state() {
    _expect="$1"
    _timeout="${2:-${STATUS_MAX_WAIT}}"
    _elapsed=0

    log_info "Verifying CRS stack reaches state '${_expect}' (timeout=${_timeout}s)..."
    audit_log "[VERIFY] Waiting for CRS to reach state '${_expect}'"

    while [ "${_elapsed}" -lt "${_timeout}" ]; do
        _out=$("${CRSCTL}" check crs 2>&1)
        _match=$(printf '%s' "${_out}" | grep -i "${_expect}" | head -1)
        if [ -n "${_match}" ]; then
            log_ok "VERIFIED: CRS stack is ${_expect} (elapsed ${_elapsed}s)."
            audit_log "[VERIFY-PASS] resource=CRS state=${_expect} elapsed=${_elapsed}s"
            audit_log "[VERIFY-OUT]  ${_out}"
            return 0
        fi
        sleep "${STATUS_POLL_INTERVAL}"
        _elapsed=$((_elapsed + STATUS_POLL_INTERVAL))
        log_info "  CRS not yet ${_expect}... (${_elapsed}/${_timeout}s)"
    done

    log_error "VERIFY FAILED: CRS stack did NOT reach '${_expect}' within ${_timeout}s."
    audit_log "[VERIFY-FAIL] resource=CRS expected=${_expect} timeout=${_timeout}s"
    audit_log "[VERIFY-LAST] ${_out}"
    return 1
}

# ---------------------------------------------------------------------------
# USAGE / HELP
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

USAGE:
  ${SCRIPT_NAME} [-d|--dry-run] [-h|--help]

OPTIONS:
  -d, --dry-run   Simulate all stop/start actions; no cluster state is changed.
  -h, --help      Show this help text and exit.

ENVIRONMENT:
  ORACLE_RAC_MGMT_LOGDIR   Override the default audit log directory.
                           Default: /var/log/oracle/rac_mgmt

AUDIT LOGS:
  Written to: \${ORACLE_RAC_MGMT_LOGDIR}/rac_mgmt_YYYYMMDD.log
  Rotated at: ${LOG_MAX_BYTES} bytes (10 retentions kept)

AUTHORISED USERS: oracle, grid
SUPPORTED OS    : RHEL/OEL 7-9, Oracle Solaris 11.x
SUPPORTED CRS   : Oracle Grid Infrastructure 19c, 23c
EOF
}

# ---------------------------------------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--dry-run)
                DRY_RUN=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift; break ;;
            -*)
                printf 'ERROR: Unknown option: %s\n' "$1" >&2
                usage
                exit 1
                ;;
            *)
                printf 'ERROR: Unexpected argument: %s\n' "$1" >&2
                usage
                exit 1
                ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# OS DETECTION & PATH NORMALISATION
# ---------------------------------------------------------------------------
detect_os() {
    OS_TYPE=$(uname -s)
    case "${OS_TYPE}" in
        SunOS)
            OS_FAMILY="solaris"
            PATH="/usr/xpg4/bin:/usr/xpg6/bin:${PATH}"
            export PATH
            ORATAB="/var/opt/oracle/oratab"
            ;;
        Linux)
            OS_FAMILY="linux"
            ORATAB="/etc/oratab"
            ;;
        *)
            printf 'ERROR: Unsupported operating system: %s\n' "${OS_TYPE}" >&2
            exit 1
            ;;
    esac
    readonly OS_FAMILY ORATAB
}

# ---------------------------------------------------------------------------
# STRICT USER VALIDATION
# ---------------------------------------------------------------------------
validate_user() {
    CURRENT_USER=$(id -un)
    if [ "${CURRENT_USER}" = "root" ]; then
        log_error "Execution as 'root' is explicitly prohibited."
        log_error "Switch to the 'oracle' or 'grid' OS user and retry."
        audit_log "[SECURITY] BLOCKED: root execution attempt from PID=$$"
        exit 2
    fi
    _allowed=0
    for _u in ${REQUIRED_USERS}; do
        [ "${CURRENT_USER}" = "${_u}" ] && _allowed=1 && break
    done
    if [ "${_allowed}" -ne 1 ]; then
        log_error "Unauthorised user: '${CURRENT_USER}'."
        log_error "Only the following users may execute this script: ${REQUIRED_USERS}"
        audit_log "[SECURITY] BLOCKED: unauthorised user '${CURRENT_USER}'"
        exit 2
    fi
    log_info "User validation passed (running as: ${CURRENT_USER})."
    audit_log "[SECURITY] User validated: ${CURRENT_USER} uid=$(id -u) gid=$(id -g)"
}

# ---------------------------------------------------------------------------
# GRID INFRASTRUCTURE DISCOVERY
# ---------------------------------------------------------------------------
discover_grid_home() {
    for _candidate in \
        /u01/app/grid/product/19.0.0/grid \
        /u01/app/19.0.0/grid \
        /u01/app/grid/product/23.0.0/grid \
        /u01/app/23.0.0/grid \
        /opt/oracle/grid \
        /oracle/grid; do
        if [ -x "${_candidate}/bin/crsctl" ]; then
            GRID_HOME="${_candidate}"
            break
        fi
    done

    if [ -z "${GRID_HOME}" ]; then
        _ocssd=$(ps -ef | grep 'ocssd\.bin' | grep -v grep | head -1 | awk '{print $NF}')
        [ -n "${_ocssd}" ] && GRID_HOME=$(dirname "$(dirname "${_ocssd}")")
    fi

    if [ -z "${GRID_HOME}" ]; then
        _asm_sid=$(ps -ef | grep 'ora_pmon_+ASM' | grep -v grep | head -1 \
                   | awk '{print $NF}' | sed 's/ora_pmon_//')
        if [ -n "${_asm_sid}" ] && [ -r "${ORATAB}" ]; then
            GRID_HOME=$(grep "^${_asm_sid}:" "${ORATAB}" | cut -d: -f2)
        fi
    fi

    if [ -z "${GRID_HOME}" ] || [ ! -x "${GRID_HOME}/bin/crsctl" ]; then
        log_error "Cannot locate Grid Infrastructure home (GRID_HOME)."
        log_error "Verify that Oracle Clusterware is installed and running."
        exit 3
    fi

    CRSCTL="${GRID_HOME}/bin/crsctl"
    LOCAL_NODE=$("${GRID_HOME}/bin/olsnodes" -l 2>/dev/null) || LOCAL_NODE=$(hostname)
    readonly GRID_HOME CRSCTL LOCAL_NODE
    log_info "Grid Home  : ${GRID_HOME}"
    log_info "Local Node : ${LOCAL_NODE}"
    audit_log "[ENV] GRID_HOME=${GRID_HOME} LOCAL_NODE=${LOCAL_NODE} CRSCTL=${CRSCTL}"
}

# ---------------------------------------------------------------------------
# DYNAMIC DATABASE / INSTANCE DISCOVERY
# ---------------------------------------------------------------------------
discover_databases() {
    DB_COUNT=0
    DB_NAMES=""

    if [ ! -r "${ORATAB}" ]; then
        log_warn "Cannot read ${ORATAB}; database discovery may be incomplete."
    fi

    _running_sids=$(ps -ef | grep 'ora_pmon_' | grep -v grep \
                    | awk '{print $NF}' | sed 's/ora_pmon_//')

    for _sid in ${_running_sids}; do
        case "${_sid}" in
            +ASM*|+APX*|-MGMTDB|_MGMTDB) continue ;;
        esac

        _oh=""
        [ -r "${ORATAB}" ] && \
            _oh=$(grep "^${_sid}:" "${ORATAB}" | cut -d: -f2 | head -1)

        if [ -z "${_oh}" ]; then
            _pid=$(ps -ef | grep "ora_pmon_${_sid}" | grep -v grep \
                   | awk '{print $2}' | head -1)
            if [ -n "${_pid}" ]; then
                case "${OS_FAMILY}" in
                    linux)
                        _oh=$(strings "/proc/${_pid}/environ" 2>/dev/null \
                              | grep '^ORACLE_HOME=' | cut -d= -f2) ;;
                    solaris)
                        _oh=$(pargs -e "${_pid}" 2>/dev/null \
                              | grep 'ORACLE_HOME' | cut -d= -f2) ;;
                esac
            fi
        fi

        [ -z "${_oh}" ] && \
            log_warn "Could not resolve ORACLE_HOME for SID=${_sid}; skipping." && continue
        [ ! -x "${_oh}/bin/srvctl" ] && \
            log_warn "srvctl not found in ${_oh}/bin for SID=${_sid}; skipping." && continue

        _db_unique=$(ORACLE_HOME="${_oh}" "${_oh}/bin/srvctl" config database 2>/dev/null | \
            while read -r _dbn; do
                _inst=$(ORACLE_HOME="${_oh}" "${_oh}/bin/srvctl" status database \
                        -d "${_dbn}" -v 2>/dev/null | \
                        grep "${LOCAL_NODE}" | grep -i 'running' | grep "${_sid}")
                [ -n "${_inst}" ] && printf '%s' "${_dbn}" && break
            done)

        if [ -z "${_db_unique}" ]; then
            _db_unique=$(ORACLE_HOME="${_oh}" "${_oh}/bin/srvctl" config database 2>/dev/null | \
                grep -i "^${_sid%[0-9]*}" | head -1)
        fi
        [ -z "${_db_unique}" ] && _db_unique="${_sid%[0-9]*}"

        # Deduplicate
        _dup=0
        for _existing in ${DB_NAMES}; do
            [ "${_existing}" = "${_db_unique}" ] && _dup=1 && break
        done
        [ "${_dup}" -eq 1 ] && continue

        DB_COUNT=$((DB_COUNT + 1))
        DB_NAMES="${DB_NAMES} ${_db_unique}"
        eval "DB_NAME_${DB_COUNT}='${_db_unique}'"
        eval "DB_HOME_${DB_COUNT}='${_oh}'"
        eval "DB_SID_${DB_COUNT}='${_sid}'"

        audit_log "[DISCOVERY] db[${DB_COUNT}] name=${_db_unique} home=${_oh} sid=${_sid}"
    done

    DB_NAMES=$(printf '%s' "${DB_NAMES}" | sed 's/^[[:space:]]*//')
    log_info "Databases discovered on ${LOCAL_NODE}: ${DB_COUNT}"
}

# ---------------------------------------------------------------------------
# SECURE TEMP DIRECTORY
# ---------------------------------------------------------------------------
create_work_dir() {
    if [ "${OS_FAMILY}" = "solaris" ]; then
        WORK_DIR=$(mktemp -d /tmp/.rac_mgmt_XXXXXX)
    else
        WORK_DIR=$(mktemp -d --tmpdir=/tmp .rac_mgmt_XXXXXX 2>/dev/null \
                   || mktemp -d /tmp/.rac_mgmt_XXXXXX)
    fi
    chmod 700 "${WORK_DIR}"
    PRE_SNAP_CRS="${WORK_DIR}/pre_snap_crs.txt"
    PRE_SNAP_DB="${WORK_DIR}/pre_snap_db.txt"
    POST_SNAP_CRS="${WORK_DIR}/post_snap_crs.txt"
    POST_SNAP_DB="${WORK_DIR}/post_snap_db.txt"
    audit_log "[WORKDIR] Temp directory created: ${WORK_DIR}"
}

# ---------------------------------------------------------------------------
# CLEANUP TRAP
# ---------------------------------------------------------------------------
cleanup() {
    _exit_code=$?
    close_audit_log "${_exit_code}"
    [ -n "${WORK_DIR}" ] && [ -d "${WORK_DIR}" ] && rm -rf "${WORK_DIR}"
}
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# SNAPSHOT ENGINE
# ---------------------------------------------------------------------------
take_snapshot() {
    _snap_crs="$1"
    _snap_db="$2"
    _label="${3:-snapshot}"
    log_info "Taking cluster state snapshot [${_label}]..."
    audit_log "[SNAPSHOT-${_label}] Capturing crsctl stat res -t -init"
    "${CRSCTL}" stat res -t -init > "${_snap_crs}" 2>&1 || true

    printf '' > "${_snap_db}"
    _i=1
    while [ "${_i}" -le "${DB_COUNT}" ]; do
        eval "_soh=\${DB_HOME_${_i}}"
        eval "_sdb=\${DB_NAME_${_i}}"
        audit_log "[SNAPSHOT-${_label}] Capturing srvctl status database -d ${_sdb} -v"
        ORACLE_HOME="${_soh}" "${_soh}/bin/srvctl" status database \
            -d "${_sdb}" -v >> "${_snap_db}" 2>&1 || true
        _i=$((_i + 1))
    done
    audit_log "[SNAPSHOT-${_label}] Complete. Files: ${_snap_crs} | ${_snap_db}"
}

compare_snapshots() {
    log_section "Snapshot Comparison: Pre-Stop vs Post-Start"
    _dcrs=$(diff "${PRE_SNAP_CRS}" "${POST_SNAP_CRS}" 2>&1)
    _ddb=$(diff  "${PRE_SNAP_DB}"  "${POST_SNAP_DB}"  2>&1)

    if [ -z "${_dcrs}" ] && [ -z "${_ddb}" ]; then
        log_ok "Snapshot comparison PASSED – post-start state matches pre-stop baseline."
        audit_log "[SNAPSHOT-COMPARE] PASS – no divergence detected"
    else
        log_warn "Snapshot comparison FAILED – variances detected (see below and audit log)."
        audit_log "[SNAPSHOT-COMPARE] FAIL – divergence detected"
        if [ -n "${_dcrs}" ]; then
            printf "\n${C_YELLOW}-- CRS Diff  (< pre-stop  |  > post-start) --%s\n${C_RESET}" ""
            printf '%s\n' "${_dcrs}"
            audit_log "[SNAPSHOT-CRS-DIFF]"
            printf '%s\n' "${_dcrs}" | while IFS= read -r _l; do audit_log "  ${_l}"; done
        fi
        if [ -n "${_ddb}" ]; then
            printf "\n${C_YELLOW}-- DB Status Diff  (< pre-stop  |  > post-start) --%s\n${C_RESET}" ""
            printf '%s\n' "${_ddb}"
            audit_log "[SNAPSHOT-DB-DIFF]"
            printf '%s\n' "${_ddb}" | while IFS= read -r _l; do audit_log "  ${_l}"; done
        fi
    fi
}

# ---------------------------------------------------------------------------
# COMMAND EXECUTOR (respects DRY_RUN; records to audit log)
# ---------------------------------------------------------------------------
run_cmd() {
    _rc=0
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_dryrun "$*"
    else
        log_info "Executing: $*"
        audit_log "[CMD-START] $*"
        _ts_start=$(date '+%Y-%m-%dT%H:%M:%S')
        eval "$*"
        _rc=$?
        _ts_end=$(date '+%Y-%m-%dT%H:%M:%S')
        if [ "${_rc}" -eq 0 ]; then
            audit_log "[CMD-OK]    rc=${_rc} start=${_ts_start} end=${_ts_end} cmd=$*"
        else
            audit_log "[CMD-FAIL]  rc=${_rc} start=${_ts_start} end=${_ts_end} cmd=$*"
            log_warn "Command returned non-zero exit code: ${_rc}"
        fi
    fi
    return ${_rc}
}

# Record operator confirmation in the audit log
record_confirmation() {
    _action="$1"; _reply="$2"
    audit_log "[OPERATOR-CONFIRM] action='${_action}' reply='${_reply}' user=$(id -un)"
}

# ---------------------------------------------------------------------------
# MENU ACTION: VIEW STATUS
# ---------------------------------------------------------------------------
action_view_status() {
    log_section "CRS & Database Status on Node: ${LOCAL_NODE}"
    log_audit "Action: View Status"

    log_crs_status "CRS Resource Status (crsctl stat res -t)"

    printf "\n${C_BOLD}=== Database Instance Status ===${C_RESET}\n"
    _i=1
    while [ "${_i}" -le "${DB_COUNT}" ]; do
        eval "_oh=\${DB_HOME_${_i}}"
        eval "_db=\${DB_NAME_${_i}}"
        eval "_sid=\${DB_SID_${_i}}"
        log_db_status "${_oh}" "${_db}" "srvctl status"
        _i=$((_i + 1))
    done

    [ "${DB_COUNT}" -eq 0 ] && \
        log_warn "No running database instances discovered on this node."
}

# ---------------------------------------------------------------------------
# MENU ACTION: STOP ALL (CRS + All Instances)
# ---------------------------------------------------------------------------
action_stop_all() {
    log_section "Stop All Instances + CRS on Node: ${LOCAL_NODE}"
    log_audit "Action initiated: STOP ALL (databases + CRS)"

    printf "${C_RED}${C_BOLD}WARNING: This will stop ALL database instances and CRS on this node.${C_RESET}\n"
    printf "Type  YES  to confirm, or anything else to abort: "
    read -r _confirm
    record_confirmation "STOP_ALL" "${_confirm}"

    if [ "${_confirm}" != "YES" ]; then
        log_warn "Stop-all aborted by operator."
        audit_log "[ABORT] STOP_ALL cancelled by operator"
        return
    fi

    # ── PRE-STOP STATUS CAPTURE ──────────────────────────────────────────
    log_section "PRE-STOP Status Capture"
    log_crs_status "PRE-STOP CRS Status"
    _i=1
    while [ "${_i}" -le "${DB_COUNT}" ]; do
        eval "_oh=\${DB_HOME_${_i}}"
        eval "_db=\${DB_NAME_${_i}}"
        log_db_status "${_oh}" "${_db}" "PRE-STOP"
        _i=$((_i + 1))
    done
    take_snapshot "${PRE_SNAP_CRS}" "${PRE_SNAP_DB}" "PRE-STOP"

    # ── STOP DATABASES ───────────────────────────────────────────────────
    _i=1
    while [ "${_i}" -le "${DB_COUNT}" ]; do
        eval "_oh=\${DB_HOME_${_i}}"
        eval "_db=\${DB_NAME_${_i}}"
        eval "_sid=\${DB_SID_${_i}}"
        printf "\n${C_YELLOW}Stopping database: %s${C_RESET}\n" "${_db}"
        audit_log "[ACTION] Stopping database ${_db} (instance ${_sid})"
        run_cmd "ORACLE_HOME='${_oh}' '${_oh}/bin/srvctl' stop database -d '${_db}' -o immediate"
        if [ "${DRY_RUN}" -ne 1 ]; then
            verify_database_state "${_oh}" "${_db}" "stopped"
            log_db_status "${_oh}" "${_db}" "POST-STOP Verify"
        fi
        _i=$((_i + 1))
    done

    # ── STOP CRS ─────────────────────────────────────────────────────────
    printf "\n${C_YELLOW}Stopping Oracle CRS stack...${C_RESET}\n"
    audit_log "[ACTION] Stopping CRS stack"
    run_cmd "'${CRSCTL}' stop crs"
    # Note: crsctl check crs is not callable after CRS stops; log the intent
    audit_log "[ACTION-COMPLETE] CRS stop command issued; cluster stack halted."
    log_ok "Stop-all sequence completed."
    audit_log "[ACTION-DONE] STOP_ALL complete on node ${LOCAL_NODE}"
}

# ---------------------------------------------------------------------------
# MENU ACTION: START ALL (CRS + All Instances)
# ---------------------------------------------------------------------------
action_start_all() {
    log_section "Start CRS + All Instances on Node: ${LOCAL_NODE}"
    log_audit "Action initiated: START ALL (CRS + databases)"

    # ── START CRS ─────────────────────────────────────────────────────────
    printf "\n${C_YELLOW}Starting Oracle CRS stack...${C_RESET}\n"
    audit_log "[ACTION] Starting CRS stack"
    run_cmd "'${CRSCTL}' start crs"

    if [ "${DRY_RUN}" -ne 1 ]; then
        verify_crs_state "active" 300
        log_crs_status "POST-CRS-START Status"

        log_info "Waiting 60 seconds for CRS to fully stabilise..."
        audit_log "[WAIT] 60s CRS stabilisation pause"
        sleep 60
    fi

    # ── START DATABASES ───────────────────────────────────────────────────
    _i=1
    while [ "${_i}" -le "${DB_COUNT}" ]; do
        eval "_oh=\${DB_HOME_${_i}}"
        eval "_db=\${DB_NAME_${_i}}"
        eval "_sid=\${DB_SID_${_i}}"
        printf "\n${C_YELLOW}Starting database: %s${C_RESET}\n" "${_db}"
        audit_log "[ACTION] Starting database ${_db}"
        run_cmd "ORACLE_HOME='${_oh}' '${_oh}/bin/srvctl' start database -d '${_db}'"
        if [ "${DRY_RUN}" -ne 1 ]; then
            verify_database_state "${_oh}" "${_db}" "running"
            log_db_status "${_oh}" "${_db}" "POST-START Verify"
        fi
        _i=$((_i + 1))
    done

    log_ok "Start-all sequence completed."
    audit_log "[ACTION-DONE] START_ALL complete on node ${LOCAL_NODE}"

    # ── SNAPSHOT COMPARISON ───────────────────────────────────────────────
    if [ "${DRY_RUN}" -ne 1 ] && [ -f "${PRE_SNAP_CRS}" ]; then
        take_snapshot "${POST_SNAP_CRS}" "${POST_SNAP_DB}" "POST-START"
        compare_snapshots
    fi
}

# ---------------------------------------------------------------------------
# SHARED: RENDER INSTANCE SELECTION SUB-MENU
# Returns selected index in global SELECTED_IDX, or 0 to go back.
# ---------------------------------------------------------------------------
render_instance_submenu() {
    _prompt_verb="$1"
    SELECTED_IDX=0

    printf "\n${C_BOLD}Select the database instance to %s:${C_RESET}\n" "${_prompt_verb}"
    printf "  %-4s %-30s %-20s %-40s\n" \
           "Num" "DB Unique Name" "Local SID" "ORACLE_HOME"
    printf "  %-4s %-30s %-20s %-40s\n" \
           "---" "--------------" "---------" "-----------"
    _i=1
    while [ "${_i}" -le "${DB_COUNT}" ]; do
        eval "_db=\${DB_NAME_${_i}}"
        eval "_sid=\${DB_SID_${_i}}"
        eval "_oh=\${DB_HOME_${_i}}"
        printf "  %-4d %-30s %-20s %-40s\n" "${_i}" "${_db}" "${_sid}" "${_oh}"
        _i=$((_i + 1))
    done
    printf "  %-4s %-30s\n" "0" "Return to Main Menu"
    printf "\nEnter selection: "
    read -r _sel

    case "${_sel}" in
        0) SELECTED_IDX=0; return 0 ;;
        *[!0-9]*|'')
            log_error "Invalid selection: '${_sel}'"; SELECTED_IDX=0; return 1 ;;
    esac
    if [ "${_sel}" -lt 1 ] || [ "${_sel}" -gt "${DB_COUNT}" ]; then
        log_error "Selection out of range."; SELECTED_IDX=0; return 1
    fi
    SELECTED_IDX="${_sel}"
}

# ---------------------------------------------------------------------------
# MENU ACTION: STOP SPECIFIC DATABASE INSTANCE
# ---------------------------------------------------------------------------
action_stop_specific() {
    log_section "Stop Specific Database Instance"
    log_audit "Action initiated: STOP SPECIFIC INSTANCE"

    if [ "${DB_COUNT}" -eq 0 ]; then
        log_warn "No running database instances found on this node."; return
    fi

    render_instance_submenu "STOP" || return
    [ "${SELECTED_IDX}" -eq 0 ] && return

    eval "_oh=\${DB_HOME_${SELECTED_IDX}}"
    eval "_db=\${DB_NAME_${SELECTED_IDX}}"
    eval "_sid=\${DB_SID_${SELECTED_IDX}}"
    audit_log "[ACTION] STOP SPECIFIC selected: db=${_db} sid=${_sid}"

    printf "\n${C_BOLD}Stop Options for '${_db}' (instance '${_sid}'):${C_RESET}\n"
    printf "  1) Stop THIS local instance only    (srvctl stop instance)\n"
    printf "  2) Stop ENTIRE database (all nodes) (srvctl stop database)\n"
    printf "  0) Return to Main Menu\n"
    printf "Enter selection: "
    read -r _opt
    audit_log "[OPERATOR] stop scope selected: '${_opt}'"

    case "${_opt}" in
        0) return ;;

        1)  # ── STOP INSTANCE ────────────────────────────────────────────
            # Pre-stop status
            log_section "PRE-STOP Instance Status"
            log_inst_status "${_oh}" "${_db}" "${_sid}" "PRE-STOP"
            take_snapshot "${PRE_SNAP_CRS}" "${PRE_SNAP_DB}" "PRE-STOP"

            printf "${C_RED}Stopping instance '${_sid}' on '${LOCAL_NODE}'...${C_RESET}\n"
            audit_log "[ACTION] srvctl stop instance db=${_db} sid=${_sid}"
            run_cmd "ORACLE_HOME='${_oh}' '${_oh}/bin/srvctl' stop instance \
                     -d '${_db}' -i '${_sid}' -o immediate"

            if [ "${DRY_RUN}" -ne 1 ]; then
                # Post-stop verification
                verify_instance_state "${_oh}" "${_db}" "${_sid}" "stopped"
                log_section "POST-STOP Instance Status"
                log_inst_status "${_oh}" "${_db}" "${_sid}" "POST-STOP Verify"
            fi
            log_ok "Instance '${_sid}' stop sequence complete."
            ;;

        2)  # ── STOP DATABASE (ALL NODES) ─────────────────────────────────
            printf "${C_RED}${C_BOLD}WARNING: Stops ALL instances of '${_db}' on ALL nodes.${C_RESET}\n"
            printf "Type  YES  to confirm: "
            read -r _confirm
            record_confirmation "STOP_DATABASE:${_db}" "${_confirm}"
            if [ "${_confirm}" != "YES" ]; then
                log_warn "Aborted by operator."; return
            fi

            log_section "PRE-STOP Database Status"
            log_db_status "${_oh}" "${_db}" "PRE-STOP"
            take_snapshot "${PRE_SNAP_CRS}" "${PRE_SNAP_DB}" "PRE-STOP"

            printf "${C_RED}Stopping entire database '${_db}'...${C_RESET}\n"
            audit_log "[ACTION] srvctl stop database db=${_db}"
            run_cmd "ORACLE_HOME='${_oh}' '${_oh}/bin/srvctl' stop database \
                     -d '${_db}' -o immediate"

            if [ "${DRY_RUN}" -ne 1 ]; then
                verify_database_state "${_oh}" "${_db}" "stopped"
                log_section "POST-STOP Database Status"
                log_db_status "${_oh}" "${_db}" "POST-STOP Verify"
            fi
            log_ok "Database '${_db}' stop sequence complete."
            ;;

        *)  log_error "Invalid option: '${_opt}'"; return ;;
    esac

    audit_log "[ACTION-DONE] STOP SPECIFIC complete: db=${_db} sid=${_sid}"
}

# ---------------------------------------------------------------------------
# MENU ACTION: START SPECIFIC DATABASE INSTANCE
# ---------------------------------------------------------------------------
action_start_specific() {
    log_section "Start Specific Database Instance"
    log_audit "Action initiated: START SPECIFIC INSTANCE"

    if [ "${DB_COUNT}" -eq 0 ]; then
        log_warn "No registered databases found. Cannot build sub-menu."; return
    fi

    render_instance_submenu "START" || return
    [ "${SELECTED_IDX}" -eq 0 ] && return

    eval "_oh=\${DB_HOME_${SELECTED_IDX}}"
    eval "_db=\${DB_NAME_${SELECTED_IDX}}"
    eval "_sid=\${DB_SID_${SELECTED_IDX}}"
    audit_log "[ACTION] START SPECIFIC selected: db=${_db} sid=${_sid}"

    printf "\n${C_BOLD}Start Options for '${_db}' (instance '${_sid}'):${C_RESET}\n"
    printf "  1) Start THIS local instance only    (srvctl start instance)\n"
    printf "  2) Start ENTIRE database (all nodes) (srvctl start database)\n"
    printf "  0) Return to Main Menu\n"
    printf "Enter selection: "
    read -r _opt
    audit_log "[OPERATOR] start scope selected: '${_opt}'"

    case "${_opt}" in
        0) return ;;

        1)  # ── START INSTANCE ───────────────────────────────────────────
            log_section "PRE-START Instance Status"
            log_inst_status "${_oh}" "${_db}" "${_sid}" "PRE-START"

            printf "${C_GREEN}Starting instance '${_sid}' on '${LOCAL_NODE}'...${C_RESET}\n"
            audit_log "[ACTION] srvctl start instance db=${_db} sid=${_sid}"
            run_cmd "ORACLE_HOME='${_oh}' '${_oh}/bin/srvctl' start instance \
                     -d '${_db}' -i '${_sid}'"

            if [ "${DRY_RUN}" -ne 1 ]; then
                verify_instance_state "${_oh}" "${_db}" "${_sid}" "running"
                log_section "POST-START Instance Status"
                log_inst_status "${_oh}" "${_db}" "${_sid}" "POST-START Verify"
            fi
            log_ok "Instance '${_sid}' start sequence complete."
            ;;

        2)  # ── START DATABASE (ALL NODES) ────────────────────────────────
            log_section "PRE-START Database Status"
            log_db_status "${_oh}" "${_db}" "PRE-START"

            printf "${C_GREEN}Starting entire database '${_db}'...${C_RESET}\n"
            audit_log "[ACTION] srvctl start database db=${_db}"
            run_cmd "ORACLE_HOME='${_oh}' '${_oh}/bin/srvctl' start database \
                     -d '${_db}'"

            if [ "${DRY_RUN}" -ne 1 ]; then
                verify_database_state "${_oh}" "${_db}" "running"
                log_section "POST-START Database Status"
                log_db_status "${_oh}" "${_db}" "POST-START Verify"
            fi
            log_ok "Database '${_db}' start sequence complete."
            ;;

        *)  log_error "Invalid option: '${_opt}'"; return ;;
    esac

    # Snapshot comparison if we have a prior baseline
    if [ "${DRY_RUN}" -ne 1 ] && [ -f "${PRE_SNAP_CRS}" ]; then
        take_snapshot "${POST_SNAP_CRS}" "${POST_SNAP_DB}" "POST-START"
        compare_snapshots
    fi

    audit_log "[ACTION-DONE] START SPECIFIC complete: db=${_db} sid=${_sid}"
}

# ---------------------------------------------------------------------------
# MAIN MENU LOOP
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        printf "\n"
        printf "${C_BOLD}=====================================================${C_RESET}\n"
        printf "${C_BOLD}  ORACLE RAC LOCAL NODE MANAGEMENT UTILITY v%s${C_RESET}\n" \
               "${SCRIPT_VERSION}"
        printf "${C_BOLD}=====================================================${C_RESET}\n"
        printf "  Node     : ${C_CYAN}%s${C_RESET}\n"  "${LOCAL_NODE}"
        printf "  User     : ${C_CYAN}%s${C_RESET}\n"  "$(id -un)"
        printf "  Grid Home: ${C_CYAN}%s${C_RESET}\n"  "${GRID_HOME}"
        printf "  Audit Log: ${C_CYAN}%s${C_RESET}\n"  "${LOG_FILE}"
        if [ "${DRY_RUN}" -eq 1 ]; then
            printf "  Mode     : ${C_YELLOW}DRY-RUN (no cluster changes)${C_RESET}\n"
        fi
        printf "${C_BOLD}-----------------------------------------------------${C_RESET}\n"
        printf "  1) View Local CRS & Database Status\n"
        printf "  2) Stop Local CRS & All Instances  ${C_RED}(Confirmation Required)${C_RESET}\n"
        printf "  3) Start Local CRS & All Instances\n"
        printf "  4) Stop Specific Database Instance  ${C_YELLOW}(Nested)${C_RESET}\n"
        printf "  5) Start Specific Database Instance ${C_YELLOW}(Nested)${C_RESET}\n"
        printf "  6) Refresh Database Discovery\n"
        printf "  7) Exit\n"
        printf "${C_BOLD}-----------------------------------------------------${C_RESET}\n"
        printf "Enter selection [1-7]: "
        read -r _choice
        audit_log "[MENU] Operator selected: '${_choice}'"

        case "${_choice}" in
            1) action_view_status ;;
            2) action_stop_all ;;
            3) action_start_all ;;
            4) action_stop_specific ;;
            5) action_start_specific ;;
            6)
                log_info "Re-running database discovery..."
                discover_databases
                log_ok "Discovery refreshed. Found ${DB_COUNT} database(s)."
                ;;
            7)
                log_audit "Operator selected Exit."
                log_info "Exiting. Audit log: ${LOG_FILE}"
                exit 0
                ;;
            '')
                ;;   # blank → redraw
            *)
                log_error "Invalid selection: '${_choice}'. Enter 1-7." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# ENTRY POINT
# ---------------------------------------------------------------------------
main() {
    setup_colours
    parse_args "$@"

    detect_os

    # Audit log must be initialised BEFORE any log_* calls
    init_audit_log "$@"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_warn "DRY-RUN mode is ACTIVE – no cluster state will be modified."
    fi

    log_section "Oracle RAC Node Management Utility v${SCRIPT_VERSION} – Initialising"
    log_info "OS Family  : ${OS_FAMILY} (${OS_TYPE})"

    validate_user
    discover_grid_home
    create_work_dir
    discover_databases

    main_menu
}

main "$@"
