#!/bin/ksh
# =============================================================================
# Script  : oracle_rac_mgmt.sh
# Purpose : Oracle Grid Infrastructure & RAC Database Local Node Management
# Version : 2.0.0
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
# Security:
#   - Executable only by 'oracle' or 'grid' OS users
#   - Root execution is explicitly blocked
#   - Snapshot files written to a mode-700 private temp directory
#   - All temp artefacts removed on EXIT via trap
# =============================================================================

# ---------------------------------------------------------------------------
# STRICT ERROR HANDLING
# ---------------------------------------------------------------------------
set -o nounset          # Treat unset variables as errors
# Note: We do NOT use -o errexit globally because many srvctl/crsctl
# commands return non-zero for legitimate "already stopped" states.

# ---------------------------------------------------------------------------
# GLOBAL CONSTANTS
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="2.0.0"
readonly REQUIRED_USERS="oracle grid"

# Snapshot / temp directory (created securely at runtime)
WORK_DIR=""
PRE_SNAP_CRS=""
PRE_SNAP_DB=""
POST_SNAP_CRS=""
POST_SNAP_DB=""

# Dry-run flag (0=off, 1=on)
DRY_RUN=0

# Colour codes (disabled automatically if not a tty)
C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_BOLD="" C_RESET=""

# Will be populated by discover_environment()
GRID_HOME=""
ORACLE_BASE=""
CRSCTL=""
SRVCTL=""
LOCAL_NODE=""
ORATAB=""

# Associative-style parallel arrays for discovered databases
# DB_NAMES[i], DB_HOMES[i], DB_INSTANCES[i]  (POSIX arrays, not typeset -A)
DB_NAMES=""          # space-separated list
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
# LOGGING HELPERS
# ---------------------------------------------------------------------------
log_info()    { printf "${C_CYAN}[INFO]${C_RESET}  %s\n"    "$*"; }
log_ok()      { printf "${C_GREEN}[OK]${C_RESET}    %s\n"    "$*"; }
log_warn()    { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n"   "$*"; }
log_error()   { printf "${C_RED}[ERROR]${C_RESET} %s\n"      "$*" >&2; }
log_dryrun()  { printf "${C_YELLOW}[DRY-RUN]${C_RESET} Would execute: %s\n" "$*"; }
log_section() {
    printf "\n${C_BOLD}-----------------------------------------------------${C_RESET}\n"
    printf "${C_BOLD}  %s${C_RESET}\n" "$*"
    printf "${C_BOLD}-----------------------------------------------------${C_RESET}\n"
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
                log_warn "DRY-RUN mode is ACTIVE – no cluster state will be modified."
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift; break ;;
            -*)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                log_error "Unexpected argument: $1"
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
            # Prepend XPG4 POSIX-compliant utilities for Solaris
            PATH="/usr/xpg4/bin:/usr/xpg6/bin:${PATH}"
            export PATH
            ORATAB="/var/opt/oracle/oratab"
            ;;
        Linux)
            OS_FAMILY="linux"
            ORATAB="/etc/oratab"
            ;;
        *)
            log_error "Unsupported operating system: ${OS_TYPE}"
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
        exit 2
    fi
    ALLOWED=0
    for u in ${REQUIRED_USERS}; do
        [ "${CURRENT_USER}" = "${u}" ] && ALLOWED=1 && break
    done
    if [ "${ALLOWED}" -ne 1 ]; then
        log_error "Unauthorised user: '${CURRENT_USER}'."
        log_error "Only the following users may execute this script: ${REQUIRED_USERS}"
        exit 2
    fi
    log_info "User validation passed (running as: ${CURRENT_USER})."
}

# ---------------------------------------------------------------------------
# GRID INFRASTRUCTURE DISCOVERY
# ---------------------------------------------------------------------------
discover_grid_home() {
    # Strategy 1: olsnodes / crsctl in well-known locations
    for candidate in \
        /u01/app/grid/product/19.0.0/grid \
        /u01/app/19.0.0/grid \
        /u01/app/grid/product/23.0.0/grid \
        /u01/app/23.0.0/grid \
        /opt/oracle/grid \
        /oracle/grid; do
        if [ -x "${candidate}/bin/crsctl" ]; then
            GRID_HOME="${candidate}"
            break
        fi
    done

    # Strategy 2: Derive from running ocssd.bin process
    if [ -z "${GRID_HOME}" ]; then
        _ocssd=$(ps -ef | grep 'ocssd\.bin' | grep -v grep | head -1 | awk '{print $NF}')
        if [ -n "${_ocssd}" ]; then
            GRID_HOME=$(dirname "$(dirname "${_ocssd}")")
        fi
    fi

    # Strategy 3: ASM PMON → oratab
    if [ -z "${GRID_HOME}" ]; then
        _asm_sid=$(ps -ef | grep 'ora_pmon_+ASM' | grep -v grep | head -1 | awk '{print $NF}' | sed 's/ora_pmon_//')
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
    SRVCTL="${GRID_HOME}/bin/srvctl"   # placeholder; overridden per-DB later
    LOCAL_NODE=$("${GRID_HOME}/bin/olsnodes" -l 2>/dev/null) || LOCAL_NODE=$(hostname)
    readonly GRID_HOME CRSCTL LOCAL_NODE
    log_info "Grid Home   : ${GRID_HOME}"
    log_info "Local Node  : ${LOCAL_NODE}"
}

# ---------------------------------------------------------------------------
# DYNAMIC DATABASE / INSTANCE DISCOVERY
# Maps PMON processes → srvctl config database → local instance names
# ---------------------------------------------------------------------------
discover_databases() {
    DB_COUNT=0
    DB_NAMES=""

    # Build list of database names from oratab (authoritative source)
    if [ ! -r "${ORATAB}" ]; then
        log_warn "Cannot read ${ORATAB}; database discovery may be incomplete."
    fi

    # Get all PMON SIDs currently running on this node
    RUNNING_SIDS=$(ps -ef | grep 'ora_pmon_' | grep -v grep | awk '{print $NF}' | sed 's/ora_pmon_//')

    for sid in ${RUNNING_SIDS}; do
        # Skip ASM and MGMTDB pseudo-instances
        case "${sid}" in
            +ASM*|+APX*|-MGMTDB|_MGMTDB) continue ;;
        esac

        # Look up ORACLE_HOME from oratab
        OH=""
        if [ -r "${ORATAB}" ]; then
            OH=$(grep "^${sid}:" "${ORATAB}" | cut -d: -f2 | head -1)
        fi

        # Fallback: derive ORACLE_HOME from /proc (Linux) or pargs (Solaris)
        if [ -z "${OH}" ]; then
            _pid=$(ps -ef | grep "ora_pmon_${sid}" | grep -v grep | awk '{print $2}' | head -1)
            if [ -n "${_pid}" ]; then
                case "${OS_FAMILY}" in
                    linux)
                        OH=$(strings "/proc/${_pid}/environ" 2>/dev/null | grep '^ORACLE_HOME=' | cut -d= -f2)
                        ;;
                    solaris)
                        OH=$(pargs -e "${_pid}" 2>/dev/null | grep 'ORACLE_HOME' | cut -d= -f2)
                        ;;
                esac
            fi
        fi

        [ -z "${OH}" ] && log_warn "Could not resolve ORACLE_HOME for SID=${sid}; skipping." && continue
        [ ! -x "${OH}/bin/srvctl" ] && log_warn "srvctl not found in ${OH}/bin for SID=${sid}; skipping." && continue

        # Discover the database (db_unique_name) that owns this instance via srvctl
        DB_UNIQUE=$(ORACLE_HOME="${OH}" "${OH}/bin/srvctl" config database 2>/dev/null | \
            while read -r dbn; do
                inst=$( ORACLE_HOME="${OH}" "${OH}/bin/srvctl" status database -d "${dbn}" -v 2>/dev/null | \
                         grep "${LOCAL_NODE}" | grep -i 'running' | grep "${sid}" )
                [ -n "${inst}" ] && printf '%s' "${dbn}" && break
            done)

        # Fallback: match SID prefix to db_unique_name
        if [ -z "${DB_UNIQUE}" ]; then
            DB_UNIQUE=$(ORACLE_HOME="${OH}" "${OH}/bin/srvctl" config database 2>/dev/null | \
                grep -i "^${sid%[0-9]*}" | head -1)
        fi

        [ -z "${DB_UNIQUE}" ] && DB_UNIQUE="${sid%[0-9]*}"   # best-effort

        # Deduplicate
        _dup=0
        for existing in ${DB_NAMES}; do
            [ "${existing}" = "${DB_UNIQUE}" ] && _dup=1 && break
        done
        [ "${_dup}" -eq 1 ] && continue

        DB_COUNT=$((DB_COUNT + 1))
        DB_NAMES="${DB_NAMES} ${DB_UNIQUE}"

        # Store per-index values using indirect naming (POSIX-safe)
        eval "DB_NAME_${DB_COUNT}='${DB_UNIQUE}'"
        eval "DB_HOME_${DB_COUNT}='${OH}'"
        eval "DB_SID_${DB_COUNT}='${sid}'"
    done

    DB_NAMES=$(printf '%s' "${DB_NAMES}" | sed 's/^[[:space:]]*//')
    log_info "Databases discovered on ${LOCAL_NODE}: ${DB_COUNT}"
}

# ---------------------------------------------------------------------------
# SECURE TEMP DIRECTORY CREATION
# ---------------------------------------------------------------------------
create_work_dir() {
    if [ "${OS_FAMILY}" = "solaris" ]; then
        WORK_DIR=$(mktemp -d /tmp/.rac_mgmt_XXXXXX)
    else
        WORK_DIR=$(mktemp -d --tmpdir=/tmp .rac_mgmt_XXXXXX 2>/dev/null || mktemp -d /tmp/.rac_mgmt_XXXXXX)
    fi
    chmod 700 "${WORK_DIR}"
    PRE_SNAP_CRS="${WORK_DIR}/pre_snap_crs.txt"
    PRE_SNAP_DB="${WORK_DIR}/pre_snap_db.txt"
    POST_SNAP_CRS="${WORK_DIR}/post_snap_crs.txt"
    POST_SNAP_DB="${WORK_DIR}/post_snap_db.txt"
}

# ---------------------------------------------------------------------------
# CLEANUP TRAP
# ---------------------------------------------------------------------------
cleanup() {
    if [ -n "${WORK_DIR}" ] && [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# SNAPSHOT ENGINE
# ---------------------------------------------------------------------------
take_snapshot() {
    _snap_crs="$1"
    _snap_db="$2"
    log_info "Taking cluster state snapshot..."
    "${CRSCTL}" stat res -t -init > "${_snap_crs}" 2>&1  || true
    # Append per-database status
    printf '' > "${_snap_db}"
    i=1
    while [ "${i}" -le "${DB_COUNT}" ]; do
        eval "_oh=\${DB_HOME_${i}}"
        eval "_db=\${DB_NAME_${i}}"
        ORACLE_HOME="${_oh}" "${_oh}/bin/srvctl" status database -d "${_db}" -v >> "${_snap_db}" 2>&1 || true
        i=$((i + 1))
    done
}

compare_snapshots() {
    log_section "Snapshot Comparison: Pre-Stop vs Post-Start"
    _diff_crs=$(diff "${PRE_SNAP_CRS}" "${POST_SNAP_CRS}" 2>&1)
    _diff_db=$(diff  "${PRE_SNAP_DB}"  "${POST_SNAP_DB}"  2>&1)

    if [ -z "${_diff_crs}" ] && [ -z "${_diff_db}" ]; then
        log_ok "State comparison PASSED – cluster resources match the pre-stop snapshot."
    else
        log_warn "State comparison FAILED – variances detected:"
        if [ -n "${_diff_crs}" ]; then
            printf "\n${C_YELLOW}-- CRS Resource Diff (< pre-stop | > post-start) --%s\n${C_RESET}" ""
            printf '%s\n' "${_diff_crs}"
        fi
        if [ -n "${_diff_db}" ]; then
            printf "\n${C_YELLOW}-- Database Status Diff (< pre-stop | > post-start) --%s\n${C_RESET}" ""
            printf '%s\n' "${_diff_db}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# COMMAND EXECUTOR (respects DRY_RUN)
# ---------------------------------------------------------------------------
run_cmd() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_dryrun "$*"
        return 0
    else
        log_info "Executing: $*"
        eval "$*"
        return $?
    fi
}

# ---------------------------------------------------------------------------
# MENU ACTION: VIEW STATUS
# ---------------------------------------------------------------------------
action_view_status() {
    log_section "CRS & Database Status on Node: ${LOCAL_NODE}"
    printf "\n${C_BOLD}=== Cluster Resource Status ===${C_RESET}\n"
    "${CRSCTL}" stat res -t 2>&1 || log_warn "crsctl stat res returned non-zero."

    printf "\n${C_BOLD}=== Database Instance Status ===${C_RESET}\n"
    i=1
    while [ "${i}" -le "${DB_COUNT}" ]; do
        eval "_oh=\${DB_HOME_${i}}"
        eval "_db=\${DB_NAME_${i}}"
        eval "_sid=\${DB_SID_${i}}"
        printf "\n${C_CYAN}Database: %s  (Instance: %s)${C_RESET}\n" "${_db}" "${_sid}"
        ORACLE_HOME="${_oh}" "${_oh}/bin/srvctl" status database -d "${_db}" -v 2>&1 || true
        i=$((i + 1))
    done

    if [ "${DB_COUNT}" -eq 0 ]; then
        log_warn "No running database instances discovered on this node."
    fi
}

# ---------------------------------------------------------------------------
# MENU ACTION: STOP ALL (CRS + All Instances)
# ---------------------------------------------------------------------------
action_stop_all() {
    log_section "Stop All Instances + CRS on Node: ${LOCAL_NODE}"
    printf "${C_RED}${C_BOLD}WARNING: This will stop ALL database instances and CRS on this node.${C_RESET}\n"
    printf "Type  YES  to confirm, or anything else to abort: "
    read -r CONFIRM
    if [ "${CONFIRM}" != "YES" ]; then
        log_warn "Stop-all aborted by user."
        return
    fi

    # Pre-stop snapshot
    take_snapshot "${PRE_SNAP_CRS}" "${PRE_SNAP_DB}"

    # Stop databases first, then CRS
    i=1
    while [ "${i}" -le "${DB_COUNT}" ]; do
        eval "_oh=\${DB_HOME_${i}}"
        eval "_db=\${DB_NAME_${i}}"
        printf "\n${C_YELLOW}Stopping database: %s${C_RESET}\n" "${_db}"
        run_cmd "ORACLE_HOME='${_oh}' '${_oh}/bin/srvctl' stop database -d '${_db}' -o immediate"
        i=$((i + 1))
    done

    printf "\n${C_YELLOW}Stopping Oracle CRS stack (crsctl stop crs)...${C_RESET}\n"
    run_cmd "'${CRSCTL}' stop crs"
    log_ok "Stop-all sequence completed."
}

# ---------------------------------------------------------------------------
# MENU ACTION: START ALL (CRS + All Instances)
# ---------------------------------------------------------------------------
action_start_all() {
    log_section "Start CRS + All Instances on Node: ${LOCAL_NODE}"

    printf "\n${C_YELLOW}Starting Oracle CRS stack (crsctl start crs)...${C_RESET}\n"
    run_cmd "'${CRSCTL}' start crs"

    if [ "${DRY_RUN}" -ne 1 ]; then
        log_info "Waiting 60 seconds for CRS to stabilise before starting databases..."
        sleep 60
    fi

    i=1
    while [ "${i}" -le "${DB_COUNT}" ]; do
        eval "_oh=\${DB_HOME_${i}}"
        eval "_db=\${DB_NAME_${i}}"
        printf "\n${C_YELLOW}Starting database: %s${C_RESET}\n" "${_db}"
        run_cmd "ORACLE_HOME='${_oh}' '${_oh}/bin/srvctl' start database -d '${_db}'"
        i=$((i + 1))
    done

    log_ok "Start-all sequence completed."

    if [ "${DRY_RUN}" -ne 1 ] && [ -f "${PRE_SNAP_CRS}" ]; then
        take_snapshot "${POST_SNAP_CRS}" "${POST_SNAP_DB}"
        compare_snapshots
    fi
}

# ---------------------------------------------------------------------------
# MENU ACTION: STOP SPECIFIC DATABASE INSTANCE  (nested sub-menu)
# ---------------------------------------------------------------------------
action_stop_specific() {
    log_section "Stop Specific Database Instance"

    if [ "${DB_COUNT}" -eq 0 ]; then
        log_warn "No running database instances found on this node."
        return
    fi

    # Build and display sub-menu
    printf "\n${C_BOLD}Select the database instance to STOP:${C_RESET}\n"
    printf "  %-4s %-30s %-20s\n" "Num" "DB Unique Name" "Local Instance (SID)"
    printf "  %-4s %-30s %-20s\n" "---" "--------------" "--------------------"
    i=1
    while [ "${i}" -le "${DB_COUNT}" ]; do
        eval "_db=\${DB_NAME_${i}}"
        eval "_sid=\${DB_SID_${i}}"
        printf "  %-4d %-30s %-20s\n" "${i}" "${_db}" "${_sid}"
        i=$((i + 1))
    done
    printf "  %-4s %-30s\n" "0" "Return to Main Menu"
    printf "\nEnter selection: "
    read -r SEL

    case "${SEL}" in
        0) return ;;
        *[!0-9]*|'')
            log_error "Invalid selection: '${SEL}'"; return ;;
    esac

    if [ "${SEL}" -lt 1 ] || [ "${SEL}" -gt "${DB_COUNT}" ]; then
        log_error "Selection out of range."; return
    fi

    eval "_oh=\${DB_HOME_${SEL}}"
    eval "_db=\${DB_NAME_${SEL}}"
    eval "_sid=\${DB_SID_${SEL}}"

    # Nested: offer instance-only or database-level stop
    printf "\n${C_BOLD}Stop Options for database '${_db}' (instance '${_sid}'):${C_RESET}\n"
    printf "  1) Stop THIS local instance only    (srvctl stop instance)\n"
    printf "  2) Stop ENTIRE database (all nodes) (srvctl stop database)\n"
    printf "  0) Return to Main Menu\n"
    printf "Enter selection: "
    read -r STOP_OPT

    case "${STOP_OPT}" in
        0) return ;;
        1)
            # Pre-stop snapshot
            take_snapshot "${PRE_SNAP_CRS}" "${PRE_SNAP_DB}"
            printf "${C_RED}Stopping instance '${_sid}' on node '${LOCAL_NODE}'...${C_RESET}\n"
            run_cmd "ORACLE_HOME='${_oh}' '${_oh}/bin/srvctl' stop instance -d '${_db}' -i '${_sid}' -o immediate"
            log_ok "Instance '${_sid}' stop command issued."
            ;;
        2)
            printf "${C_RED}${C_BOLD}WARNING: This will stop ALL instances of '${_db}' across ALL nodes.${C_RESET}\n"
            printf "Type  YES  to confirm: "
            read -r CONFIRM
            if [ "${CONFIRM}" != "YES" ]; then
                log_warn "Aborted."; return
            fi
            take_snapshot "${PRE_SNAP_CRS}" "${PRE_SNAP_DB}"
            printf "${C_RED}Stopping entire database '${_db}'...${C_RESET}\n"
            run_cmd "ORACLE_HOME='${_oh}' '${_oh}/bin/srvctl' stop database -d '${_db}' -o immediate"
            log_ok "Database '${_db}' stop command issued."
            ;;
        *)
            log_error "Invalid option."; return ;;
    esac
}

# ---------------------------------------------------------------------------
# MENU ACTION: START SPECIFIC DATABASE INSTANCE  (nested sub-menu)
# ---------------------------------------------------------------------------
action_start_specific() {
    log_section "Start Specific Database Instance"

    if [ "${DB_COUNT}" -eq 0 ]; then
        log_warn "No registered databases found. Cannot build instance sub-menu."
        return
    fi

    printf "\n${C_BOLD}Select the database instance to START:${C_RESET}\n"
    printf "  %-4s %-30s %-20s\n" "Num" "DB Unique Name" "Local Instance (SID)"
    printf "  %-4s %-30s %-20s\n" "---" "--------------" "--------------------"
    i=1
    while [ "${i}" -le "${DB_COUNT}" ]; do
        eval "_db=\${DB_NAME_${i}}"
        eval "_sid=\${DB_SID_${i}}"
        printf "  %-4d %-30s %-20s\n" "${i}" "${_db}" "${_sid}"
        i=$((i + 1))
    done
    printf "  %-4s %-30s\n" "0" "Return to Main Menu"
    printf "\nEnter selection: "
    read -r SEL

    case "${SEL}" in
        0) return ;;
        *[!0-9]*|'')
            log_error "Invalid selection: '${SEL}'"; return ;;
    esac

    if [ "${SEL}" -lt 1 ] || [ "${SEL}" -gt "${DB_COUNT}" ]; then
        log_error "Selection out of range."; return
    fi

    eval "_oh=\${DB_HOME_${SEL}}"
    eval "_db=\${DB_NAME_${SEL}}"
    eval "_sid=\${DB_SID_${SEL}}"

    printf "\n${C_BOLD}Start Options for database '${_db}' (instance '${_sid}'):${C_RESET}\n"
    printf "  1) Start THIS local instance only    (srvctl start instance)\n"
    printf "  2) Start ENTIRE database (all nodes) (srvctl start database)\n"
    printf "  0) Return to Main Menu\n"
    printf "Enter selection: "
    read -r START_OPT

    case "${START_OPT}" in
        0) return ;;
        1)
            printf "${C_GREEN}Starting instance '${_sid}' on node '${LOCAL_NODE}'...${C_RESET}\n"
            run_cmd "ORACLE_HOME='${_oh}' '${_oh}/bin/srvctl' start instance -d '${_db}' -i '${_sid}'"
            log_ok "Instance '${_sid}' start command issued."
            ;;
        2)
            printf "${C_GREEN}Starting entire database '${_db}'...${C_RESET}\n"
            run_cmd "ORACLE_HOME='${_oh}' '${_oh}/bin/srvctl' start database -d '${_db}'"
            log_ok "Database '${_db}' start command issued."
            ;;
        *)
            log_error "Invalid option."; return ;;
    esac

    if [ "${DRY_RUN}" -ne 1 ] && [ -f "${PRE_SNAP_CRS}" ]; then
        take_snapshot "${POST_SNAP_CRS}" "${POST_SNAP_DB}"
        compare_snapshots
    fi
}

# ---------------------------------------------------------------------------
# MAIN MENU LOOP
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        printf "\n"
        printf "${C_BOLD}=====================================================${C_RESET}\n"
        printf "${C_BOLD}   ORACLE RAC LOCAL NODE MANAGEMENT UTILITY v%s${C_RESET}\n" "${SCRIPT_VERSION}"
        printf "${C_BOLD}=====================================================${C_RESET}\n"
        printf "  Node     : ${C_CYAN}%s${C_RESET}\n" "${LOCAL_NODE}"
        printf "  User     : ${C_CYAN}%s${C_RESET}\n" "$(id -un)"
        printf "  Grid Home: ${C_CYAN}%s${C_RESET}\n" "${GRID_HOME}"
        if [ "${DRY_RUN}" -eq 1 ]; then
            printf "  Mode     : ${C_YELLOW}DRY-RUN (no cluster changes will be made)${C_RESET}\n"
        fi
        printf "${C_BOLD}-----------------------------------------------------${C_RESET}\n"
        printf "  1) View Local CRS & Database Status\n"
        printf "  2) Stop Local CRS & All Instances  ${C_RED}(Requires Confirmation)${C_RESET}\n"
        printf "  3) Start Local CRS & All Instances\n"
        printf "  4) Stop Specific Database Instance ${C_YELLOW}(Nested Options)${C_RESET}\n"
        printf "  5) Start Specific Database Instance${C_YELLOW}(Nested Options)${C_RESET}\n"
        printf "  6) Refresh Database Discovery\n"
        printf "  7) Exit\n"
        printf "${C_BOLD}-----------------------------------------------------${C_RESET}\n"
        printf "Enter selection [1-7]: "
        read -r CHOICE

        case "${CHOICE}" in
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
                log_info "Exiting. Goodbye."
                exit 0
                ;;
            '')
                # blank input – just redraw
                ;;
            *)
                log_error "Invalid selection: '${CHOICE}'. Enter a number from 1 to 7."
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# ENTRY POINT
# ---------------------------------------------------------------------------
main() {
    setup_colours
    parse_args "$@"

    log_section "Oracle RAC Node Management Utility v${SCRIPT_VERSION} – Initialising"

    detect_os
    log_info "OS Family   : ${OS_FAMILY} (${OS_TYPE})"

    validate_user
    discover_grid_home
    create_work_dir
    discover_databases

    main_menu
}

main "$@"
