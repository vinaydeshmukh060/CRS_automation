#!/bin/sh
#
# crs_orchestrator_final.sh
# Oracle CRS / GI rolling orchestration for Linux + Solaris
# POSIX shell compatible
#

PATH=/usr/bin:/bin:/usr/sbin:/sbin

PROG=$(basename "$0")
BASE=$(cd "$(dirname "$0")" && pwd)
CFG="${BASE}/crs_orchestrator.conf"
LOGDIR="${BASE}/logs"
LOCK="/tmp/${PROG}.lock"

mkdir -p "$LOGDIR" 2>/dev/null
LOGFILE="${LOGDIR}/${PROG}_$(date +%Y%m%d_%H%M%S).log"

WAIT_SECS=600
SLEEP_INT=10
EXCLUDE_DBS=""

[ -f "$CFG" ] && . "$CFG"

##############################################################################
# Logging
##############################################################################
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$LOGFILE"
}

fail() {
    log "ERROR: $*"
    cleanup
    exit 1
}

cleanup() {
    [ -f "$LOCK" ] && rm -f "$LOCK"
}

trap cleanup EXIT INT TERM

##############################################################################
# Lock
##############################################################################
lock() {
    [ -f "$LOCK" ] && fail "Another instance is running"
    echo $$ > "$LOCK"
}

##############################################################################
# Detect oratab
##############################################################################
detect_oratab() {
    if [ -f /etc/oratab ]; then
        ORATAB=/etc/oratab
    elif [ -f /var/opt/oracle/oratab ]; then
        ORATAB=/var/opt/oracle/oratab
    else
        fail "oratab not found"
    fi
}

##############################################################################
# Set Oracle env from ASM
##############################################################################
set_env() {
    detect_oratab

    ASM_LINE=$(grep '^+ASM[0-9]*:' "$ORATAB" | head -1)
    [ -z "$ASM_LINE" ] && fail "ASM entry not found"

    ORACLE_SID=$(echo "$ASM_LINE" | awk -F: '{print $1}')
    ORACLE_HOME=$(echo "$ASM_LINE" | awk -F: '{print $2}')

    export ORACLE_SID
    export ORACLE_HOME
    export PATH="$ORACLE_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$ORACLE_HOME/lib:$LD_LIBRARY_PATH"
    export LIBPATH="$ORACLE_HOME/lib:$LIBPATH"
    export SHLIB_PATH="$ORACLE_HOME/lib:$SHLIB_PATH"

    log "ORACLE_SID=$ORACLE_SID"
    log "ORACLE_HOME=$ORACLE_HOME"
}

##############################################################################
# Validation
##############################################################################
need_tools() {
    for t in crsctl srvctl olsnodes; do
        command -v "$t" >/dev/null 2>&1 || fail "$t not found"
    done
}

user_check() {
    U=$(id -un)

    case "$U" in
        root|grid)
            ;;
        *)
            log "WARNING running as $U"
            ;;
    esac
}

##############################################################################
# Command helpers
##############################################################################
run() {
    CMD="$*"
    log "RUN: $CMD"
    sh -c "$CMD" >> "$LOGFILE" 2>&1
    return $?
}

retry() {
    CMD="$1"
    N=0

    while [ "$N" -lt 3 ]; do
        run "$CMD" && return 0
        N=$((N + 1))
        sleep 10
    done

    return 1
}

##############################################################################
# Node detection
##############################################################################
get_local_node() {
    HOST=$(hostname 2>/dev/null)
    SHORT=$(hostname -s 2>/dev/null)

    NODE=$(olsnodes | grep "^${HOST}$" | head -1)
    [ -n "$NODE" ] && echo "$NODE" && return

    NODE=$(olsnodes | grep "^${SHORT}$" | head -1)
    [ -n "$NODE" ] && echo "$NODE" && return

    echo "$HOST"
}

##############################################################################
# DB exclusion
##############################################################################
is_excluded_db() {
    DB="$1"

    for X in $EXCLUDE_DBS; do
        [ "$X" = "$DB" ] && return 0
    done

    return 1
}

list_dbs() {
    srvctl config database 2>/dev/null | while read DB; do
        [ -z "$DB" ] && continue

        if is_excluded_db "$DB"; then
            log "Skipping excluded DB $DB"
            continue
        fi

        echo "$DB"
    done
}

##############################################################################
# Wait CRS
##############################################################################
wait_crs() {
    TARGET="$1"
    ELAPSED=0

    while [ "$ELAPSED" -lt "$WAIT_SECS" ]; do
        crsctl check crs >/tmp/crs.$$ 2>&1
        RC=$?

        if [ "$TARGET" = "up" ] && [ "$RC" -eq 0 ]; then
            rm -f /tmp/crs.$$
            return 0
        fi

        if [ "$TARGET" = "down" ] && [ "$RC" -ne 0 ]; then
            rm -f /tmp/crs.$$
            return 0
        fi

        sleep "$SLEEP_INT"
        ELAPSED=$((ELAPSED + SLEEP_INT))
    done

    rm -f /tmp/crs.$$
    return 1
}

##############################################################################
# Health
##############################################################################
health() {
    log "========== HEALTH START =========="

    run "crsctl check crs"
    run "crsctl stat res -t"
    run "crsctl query crs activeversion"
    run "crsctl query css votedisk"
    run "ocrcheck"
    run "srvctl status asm"

    if command -v asmcmd >/dev/null 2>&1; then
        run "asmcmd lsdg"
    fi

    run "srvctl status listener"

    for DB in $(list_dbs); do
        run "srvctl status database -d $DB"
        run "srvctl status service -d $DB"
    done

    run "df -h"
    run "uptime"

    log "========== HEALTH END =========="
}

##############################################################################
# Stop rolling
##############################################################################
stop_all() {
    LOCAL_NODE=$(get_local_node)

    log "Rolling stop on node $LOCAL_NODE"

    for DB in $(list_dbs); do
        INST=$(srvctl status database -d "$DB" 2>/dev/null | \
            grep "is running on instance" | \
            grep "$LOCAL_NODE" | \
            awk '{print $6}' | \
            head -1)

        if [ -n "$INST" ]; then
            log "Stopping services DB=$DB NODE=$LOCAL_NODE"
            retry "srvctl stop service -d $DB -n $LOCAL_NODE"

            log "Stopping instance $INST"
            retry "srvctl stop instance -d $DB -i $INST -o immediate" \
                || fail "Failed stopping instance $INST"
        else
            log "No local instance for DB=$DB"
        fi
    done

    retry "srvctl stop listener"
    retry "srvctl stop asm"

    retry "crsctl stop crs" || fail "CRS stop failed"

    wait_crs down || fail "CRS did not stop"
}

##############################################################################
# Start rolling
##############################################################################
start_all() {
    LOCAL_NODE=$(get_local_node)

    log "Rolling start on node $LOCAL_NODE"

    retry "crsctl start crs" || fail "CRS start failed"

    wait_crs up || fail "CRS did not start"

    retry "srvctl start asm"
    retry "srvctl start listener"

    for DB in $(list_dbs); do
        log "Starting DB instance for $DB"
        retry "srvctl start instance -d $DB -n $LOCAL_NODE" \
            || fail "Failed starting DB $DB"

        retry "srvctl start service -d $DB -n $LOCAL_NODE"
    done
}

##############################################################################
# Status
##############################################################################
status() {
    run "crsctl check crs"
    run "crsctl stat res -t"
}

##############################################################################
# Main
##############################################################################
usage() {
    echo "Usage: $PROG {start|stop|restart|status|health}"
    exit 1
}

main() {
    [ $# -ne 1 ] && usage

    lock
    user_check
    set_env
    need_tools

    case "$1" in
        start)
            health
            start_all
            health
            ;;
        stop)
            health
            stop_all
            health
            ;;
        restart)
            health
            stop_all
            start_all
            health
            ;;
        status)
            status
            ;;
        health)
            health
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"