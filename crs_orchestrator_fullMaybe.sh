#!/bin/sh
# BEST-EFFORT Oracle CRS Rolling Orchestrator (19c+)
# Linux + Solaris POSIX shell
# STRICT MODE:
# - same local DB instance must return
# - same local services must return
# - same listener/ASM/CRS state must return
#
# TEST IN LOWER ENV FIRST.

PATH=/usr/bin:/bin:/usr/sbin:/sbin

PROG=$(basename "$0")
BASE=$(cd "$(dirname "$0")" && pwd)
CFG="${BASE}/crs_orchestrator.conf"
LOGDIR="${BASE}/logs"
SNAPDIR="${BASE}/snapshots"
LOCK="/tmp/${PROG}.lock"

mkdir -p "$LOGDIR" "$SNAPDIR" 2>/dev/null

LOGFILE="${LOGDIR}/${PROG}_$(date +%Y%m%d_%H%M%S).log"

WAIT_SECS=900
SLEEP_INT=10
EXCLUDE_DBS=""

[ -f "$CFG" ] && . "$CFG"

log() {
    echo "$(date '+%F %T') | $*" | tee -a "$LOGFILE"
}

fail() {
    log "ERROR: $*"
    cleanup
    exit 2
}

cleanup() {
    [ -f "$LOCK" ] && rm -f "$LOCK"
}

trap cleanup EXIT INT TERM

lock() {
    [ -f "$LOCK" ] && fail "Lock exists: $LOCK"
    echo $$ > "$LOCK"
}

detect_oratab() {
    if [ -f /etc/oratab ]; then
        ORATAB=/etc/oratab
    elif [ -f /var/opt/oracle/oratab ]; then
        ORATAB=/var/opt/oracle/oratab
    else
        fail "oratab not found"
    fi
}

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

    log "ORACLE_HOME=$ORACLE_HOME"
    log "ORACLE_SID=$ORACLE_SID"
}

need_tools() {
    for t in crsctl srvctl olsnodes; do
        command -v "$t" >/dev/null 2>&1 || fail "$t not found"
    done
}

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
        N=$((N+1))
        sleep 10
    done

    return 1
}

get_local_node() {
    HOST=$(hostname 2>/dev/null)
    SHORT=$(hostname -s 2>/dev/null)

    NODE=$(olsnodes 2>/dev/null | grep "^${HOST}$" | head -1)
    [ -n "$NODE" ] && { echo "$NODE"; return; }

    NODE=$(olsnodes 2>/dev/null | grep "^${SHORT}$" | head -1)
    [ -n "$NODE" ] && { echo "$NODE"; return; }

    echo "$HOST"
}

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
        is_excluded_db "$DB" && continue
        echo "$DB"
    done
}

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
        ELAPSED=$((ELAPSED+SLEEP_INT))
    done

    rm -f /tmp/crs.$$
    return 1
}

snapshot_pre() {
    LOCAL_NODE=$(get_local_node)
    PRE="${SNAPDIR}/pre.$$"

    rm -f "$PRE"

    echo "NODE=$LOCAL_NODE" > "$PRE"

    crsctl check crs >/dev/null 2>&1 && echo "CRS=UP" >> "$PRE"
    srvctl status asm 2>/dev/null | grep -i running >/dev/null && echo "ASM=UP" >> "$PRE"
    srvctl status listener 2>/dev/null | grep -i running >/dev/null && echo "LISTENER=UP" >> "$PRE"

    for DB in $(list_dbs); do
        srvctl status database -d "$DB" 2>/dev/null | \
        grep "$LOCAL_NODE" | grep "running on instance" | \
        while read L; do
            INST=$(echo "$L" | awk '{print $6}')
            echo "DBINST:${DB}:${INST}" >> "$PRE"
        done

        srvctl status service -d "$DB" 2>/dev/null | \
        grep "$LOCAL_NODE" | \
        while read L; do
            SVC=$(echo "$L" | awk '{print $2}')
            echo "SERVICE:${DB}:${SVC}" >> "$PRE"
        done
    done

    PRE_SNAP="$PRE"
    log "Pre snapshot: $PRE"
}

snapshot_post() {
    POST="${SNAPDIR}/post.$$"
    LOCAL_NODE=$(get_local_node)

    rm -f "$POST"

    echo "NODE=$LOCAL_NODE" > "$POST"

    crsctl check crs >/dev/null 2>&1 && echo "CRS=UP" >> "$POST"
    srvctl status asm 2>/dev/null | grep -i running >/dev/null && echo "ASM=UP" >> "$POST"
    srvctl status listener 2>/dev/null | grep -i running >/dev/null && echo "LISTENER=UP" >> "$POST"

    for DB in $(list_dbs); do
        srvctl status database -d "$DB" 2>/dev/null | \
        grep "$LOCAL_NODE" | grep "running on instance" | \
        while read L; do
            INST=$(echo "$L" | awk '{print $6}')
            echo "DBINST:${DB}:${INST}" >> "$POST"
        done

        srvctl status service -d "$DB" 2>/dev/null | \
        grep "$LOCAL_NODE" | \
        while read L; do
            SVC=$(echo "$L" | awk '{print $2}')
            echo "SERVICE:${DB}:${SVC}" >> "$POST"
        done
    done

    POST_SNAP="$POST"
    log "Post snapshot: $POST"
}

validate_diff() {
    FAIL=0

    while read ITEM; do
        grep -F "$ITEM" "$POST_SNAP" >/dev/null 2>&1 || {
            log "MISMATCH: missing after restart -> $ITEM"
            FAIL=1
        }
    done < "$PRE_SNAP"

    if [ "$FAIL" -ne 0 ]; then
        fail "Snapshot validation failed"
    fi

    log "Snapshot validation passed"
}

health() {
    log "===== HEALTH START ====="

    run "crsctl check crs"
    run "crsctl stat res -t"
    run "crsctl query css votedisk"
    run "ocrcheck"
    run "srvctl status asm"
    run "srvctl status listener"

    if command -v asmcmd >/dev/null 2>&1; then
        run "asmcmd lsdg"
    fi

    for DB in $(list_dbs); do
        run "srvctl status database -d $DB"
        run "srvctl status service -d $DB"
    done

    run "df -h"
    run "uptime"

    log "===== HEALTH END ====="
}

stop_all() {
    LOCAL_NODE=$(get_local_node)

    for DB in $(list_dbs); do
        srvctl status database -d "$DB" 2>/dev/null | \
        grep "$LOCAL_NODE" | grep "running on instance" | \
        while read L; do
            INST=$(echo "$L" | awk '{print $6}')

            retry "srvctl stop service -d $DB -n $LOCAL_NODE"
            retry "srvctl stop instance -d $DB -i $INST -o immediate" || fail "Failed stop $DB/$INST"
        done
    done

    retry "srvctl stop listener"
    retry "srvctl stop asm"
    retry "crsctl stop crs" || fail "CRS stop failed"

    wait_crs down || fail "CRS down timeout"
}

start_all() {
    LOCAL_NODE=$(get_local_node)

    retry "crsctl start crs" || fail "CRS start failed"
    wait_crs up || fail "CRS up timeout"

    retry "srvctl start asm"
    retry "srvctl start listener"

    grep '^DBINST:' "$PRE_SNAP" | while IFS=: read T DB INST; do
        retry "srvctl start instance -d $DB -i $INST" || fail "Failed start $DB/$INST"
    done

    grep '^SERVICE:' "$PRE_SNAP" | while IFS=: read T DB SVC; do
        retry "srvctl start service -d $DB -s $SVC" || fail "Failed start service $SVC"
    done
}

usage() {
    echo "Usage: $PROG {start|stop|restart|status|health}"
    exit 1
}

main() {
    [ $# -ne 1 ] && usage

    lock
    set_env
    need_tools

    case "$1" in
        health)
            health
            ;;
        status)
            health
            ;;
        stop)
            snapshot_pre
            health
            stop_all
            snapshot_post
            ;;
        start)
            snapshot_pre
            health
            start_all
            snapshot_post
            validate_diff
            health
            ;;
        restart)
            snapshot_pre
            health
            stop_all
            start_all
            snapshot_post
            validate_diff
            health
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"