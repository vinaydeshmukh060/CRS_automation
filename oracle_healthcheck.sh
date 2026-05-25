#!/bin/bash
# oracle_healthcheck.sh
# Oracle DB Health Check Framework
# Linux + Solaris Compatible
# RAC / Standalone / ASM / Data Guard Aware

SCRIPT_NAME="oracle_healthcheck"
VERSION="2.0"

DATE_STAMP=$(date '+%Y%m%d_%H%M%S')
HOSTNAME=$(hostname 2>/dev/null || uname -n)
OS_TYPE=$(uname)

BASE_DIR="/tmp/${SCRIPT_NAME}"
LOG_DIR="${BASE_DIR}/logs"
REPORT_DIR="${BASE_DIR}/reports"

mkdir -p "${LOG_DIR}" "${REPORT_DIR}" 2>/dev/null

LOG_FILE="${LOG_DIR}/health_${DATE_STAMP}.log"
HTML_REPORT="${REPORT_DIR}/health_${DATE_STAMP}.html"

EMAIL_ENABLED="N"
EMAIL_TO="dba-team@example.com"

WARN_TBS=80
CRIT_TBS=90
WARN_FRA=80
CRIT_FRA=90
WARN_FS=80
CRIT_FS=90
WARN_SESS=80
CRIT_SESS=95

SQL_TIMEOUT=180
EXIT_CODE=0

ORATAB=""

########################################
# LOGGING
########################################
log() {
    echo "$(date '+%F %T') : $*" | tee -a "$LOG_FILE"
}

set_warn() {
    [ "$EXIT_CODE" -lt 1 ] && EXIT_CODE=1
}

set_crit() {
    EXIT_CODE=2
}

########################################
# HTML REPORT
########################################
html_init() {
cat > "$HTML_REPORT" <<EOF
<html>
<head>
<title>Oracle Health Report</title>
<style>
body { font-family: Arial; font-size: 12px; }
table { border-collapse: collapse; width:100%; }
th,td { border:1px solid #ccc; padding:6px; }
th { background:#333; color:white; }
.ok { background:#66cc66; }
.warn { background:#ffcc00; }
.crit { background:#ff4d4d; color:white; }
.info { background:#4da6ff; color:white; }
pre { white-space: pre-wrap; }
</style>
</head>
<body>
<h2>Oracle Health Check Report</h2>
<p><b>Host:</b> ${HOSTNAME}</p>
<p><b>Date:</b> $(date)</p>
<table>
<tr>
<th>Component</th>
<th>Status</th>
<th>Details</th>
</tr>
EOF
}

html_add() {
    COMP="$1"
    STATUS="$2"
    DETAILS="$3"

    CSS="ok"

    case "$STATUS" in
        OK) CSS="ok" ;;
        WARN) CSS="warn" ;;
        CRITICAL) CSS="crit" ;;
        INFO) CSS="info" ;;
    esac

cat >> "$HTML_REPORT" <<EOF
<tr>
<td>${COMP}</td>
<td class="${CSS}">${STATUS}</td>
<td><pre>${DETAILS}</pre></td>
</tr>
EOF
}

html_close() {
cat >> "$HTML_REPORT" <<EOF
</table>
</body>
</html>
EOF
}

########################################
# ORATAB DETECTION
########################################
detect_oratab() {
    if [ -f /etc/oratab ]; then
        ORATAB="/etc/oratab"
    elif [ -f /var/opt/oracle/oratab ]; then
        ORATAB="/var/opt/oracle/oratab"
    else
        log "oratab not found"
        exit 1
    fi
}

########################################
# DB FILTER
########################################
skip_db() {
    SID="$1"

    case "$SID" in
        +ASM*|ASM*|-MGMTDB|MGMTDB|APS*|APEX*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

########################################
# PMON DISCOVERY
########################################
discover_dbs() {
    DB_LIST=""

    ps -ef | grep pmon | grep -v grep | while read LINE
    do
        SID=$(echo "$LINE" | awk -F'ora_pmon_' '{print $2}')
        [ -z "$SID" ] && continue

        skip_db "$SID"
        [ $? -eq 0 ] && continue

        echo "$SID"
    done | sort -u
}

########################################
# ORACLE ENV
########################################
set_oracle_env() {
    SID="$1"

    ORACLE_HOME=$(grep "^${SID}:" "$ORATAB" 2>/dev/null | head -1 | awk -F: '{print $2}')

    [ -z "$ORACLE_HOME" ] && return 1

    export ORACLE_SID="$SID"
    export ORACLE_HOME
    export PATH=$ORACLE_HOME/bin:$PATH

    if [ "$OS_TYPE" = "SunOS" ]; then
        export LD_LIBRARY_PATH=$ORACLE_HOME/lib:$LD_LIBRARY_PATH
    else
        export LD_LIBRARY_PATH=$ORACLE_HOME/lib:$LD_LIBRARY_PATH
    fi

    return 0
}

########################################
# SQL EXECUTION
########################################
run_sql() {
    SQL="$1"

    timeout "$SQL_TIMEOUT" sqlplus -s / as sysdba <<EOF
set pages 500
set lines 300
set trimspool on
set feedback off
set heading on
set verify off
${SQL}
exit
EOF
}
########################################
# PLATFORM SAFE TIMEOUT
########################################
run_sql_safe() {
    SQL="$1"

    if command -v timeout >/dev/null 2>&1; then
        timeout "$SQL_TIMEOUT" sqlplus -s / as sysdba <<EOF
set pages 500
set lines 300
set trimspool on
set feedback off
set heading on
set verify off
${SQL}
exit
EOF
    else
        sqlplus -s / as sysdba <<EOF
set pages 500
set lines 300
set trimspool on
set feedback off
set heading on
set verify off
${SQL}
exit
EOF
    fi
}

########################################
# RAC DETECTION
########################################
is_rac() {
    command -v srvctl >/dev/null 2>&1
    return $?
}

########################################
# CRS CHECK
########################################
check_crs() {
    command -v crsctl >/dev/null 2>&1 || return

    OUT=$(crsctl check cluster -all 2>&1)

    if echo "$OUT" | grep -qi "CRS"; then
        html_add "CRS Cluster" "INFO" "$OUT"
    else
        html_add "CRS Cluster" "CRITICAL" "$OUT"
        set_crit
    fi
}

########################################
# CRS RESOURCES
########################################
check_crs_resources() {
    command -v crsctl >/dev/null 2>&1 || return

    OUT=$(crsctl stat res -t 2>&1)

    if echo "$OUT" | grep -E "OFFLINE|INTERMEDIATE"; then
        html_add "CRS Resources" "WARN" "$OUT"
        set_warn
    else
        html_add "CRS Resources" "OK" "$OUT"
    fi
}

########################################
# SRVCTL DB STATUS
########################################
check_srvctl_db() {
    DB="$1"

    command -v srvctl >/dev/null 2>&1 || return

    OUT=$(srvctl status database -d "$DB" 2>&1)
    html_add "${DB} srvctl database" "INFO" "$OUT"
}

########################################
# SRVCTL SERVICES
########################################
check_srvctl_services() {
    DB="$1"

    command -v srvctl >/dev/null 2>&1 || return

    OUT=$(srvctl status service -d "$DB" 2>&1)
    html_add "${DB} srvctl services" "INFO" "$OUT"
}

########################################
# LISTENER
########################################
check_listener() {
    command -v lsnrctl >/dev/null 2>&1 || return

    OUT=$(lsnrctl status 2>&1)

    if echo "$OUT" | grep -qi "READY"; then
        html_add "Listener" "OK" "$OUT"
    else
        html_add "Listener" "CRITICAL" "$OUT"
        set_crit
    fi
}

########################################
# ASM
########################################
check_asm() {
    command -v srvctl >/dev/null 2>&1 || return

    OUT=$(srvctl status asm 2>&1)
    html_add "ASM Status" "INFO" "$OUT"
}

########################################
# DISKGROUP
########################################
check_diskgroup() {
    OUT=$(run_sql_safe "
select name,
       state,
       type,
       total_mb,
       free_mb,
       round((1-(free_mb/total_mb))*100,2) pct_used
from v\\$asm_diskgroup;
")

    html_add "ASM Diskgroups" "INFO" "$OUT"
}

########################################
# DB STATUS
########################################
check_db_status() {
    DB="$1"

    OUT=$(run_sql_safe "
select instance_name,status,database_status
from gv\\$instance;

select name,open_mode,database_role
from v\\$database;
")

    if echo "$OUT" | grep -qi "OPEN"; then
        html_add "${DB} Database Status" "OK" "$OUT"
    else
        html_add "${DB} Database Status" "CRITICAL" "$OUT"
        set_crit
    fi
}

########################################
# INVALID OBJECTS
########################################
check_invalid_objects() {
    DB="$1"

    OUT=$(run_sql_safe "
select owner,object_type,count(*)
from dba_objects
where status='INVALID'
and owner not in ('SYS','SYSTEM','XDB','MDSYS','ORDSYS')
group by owner,object_type;
")

    if echo "$OUT" | grep -q "[0-9]"; then
        html_add "${DB} Invalid Objects" "WARN" "$OUT"
        set_warn
    else
        html_add "${DB} Invalid Objects" "OK" "No invalid objects"
    fi
}

########################################
# INVALID COMPONENTS
########################################
check_invalid_components() {
    DB="$1"

    OUT=$(run_sql_safe "
select comp_name,status,version
from dba_registry
where status <> 'VALID';
")

    if echo "$OUT" | grep -qi VALID; then
        html_add "${DB} Registry Components" "WARN" "$OUT"
        set_warn
    else
        html_add "${DB} Registry Components" "OK" "All VALID"
    fi
}
########################################
# BLOCKING SESSIONS
########################################
check_blocking_sessions() {
    DB="$1"

    OUT=$(run_sql_safe "
select inst_id,
       sid,
       serial#,
       username,
       blocking_session,
       event
from gv\\$session
where blocking_session is not null;
")

    if echo "$OUT" | grep -q "[0-9]"; then
        html_add "${DB} Blocking Sessions" "WARN" "$OUT"
        set_warn
    else
        html_add "${DB} Blocking Sessions" "OK" "No blocking sessions"
    fi
}

########################################
# LONG RUNNING ACTIVE
########################################
check_long_running() {
    DB="$1"

    OUT=$(run_sql_safe "
select inst_id,
       sid,
       serial#,
       username,
       status,
       last_call_et,
       event
from gv\\$session
where status='ACTIVE'
and username is not null
and last_call_et > 3600;
")

    if echo "$OUT" | grep -q "[0-9]"; then
        html_add "${DB} Long Running Sessions" "WARN" "$OUT"
        set_warn
    else
        html_add "${DB} Long Running Sessions" "OK" "No long active sessions"
    fi
}

########################################
# SESSIONS / PROCESSES
########################################
check_resource_limits() {
    DB="$1"

    OUT=$(run_sql_safe "
select resource_name,
       current_utilization,
       max_utilization,
       limit_value
from v\\$resource_limit
where resource_name in ('sessions','processes');
")

    html_add "${DB} Resource Limits" "INFO" "$OUT"
}

########################################
# TABLESPACE
########################################
check_tablespace() {
    DB="$1"

    OUT=$(run_sql_safe "
select tablespace_name,
       round(used_percent,2) pct_used
from dba_tablespace_usage_metrics
where used_percent > ${WARN_TBS}
order by used_percent desc;
")

    if echo "$OUT" | grep -q "[0-9]"; then
        html_add "${DB} Tablespace Usage" "WARN" "$OUT"
        set_warn
    else
        html_add "${DB} Tablespace Usage" "OK" "All below threshold"
    fi
}

########################################
# TEMP
########################################
check_temp() {
    DB="$1"

    OUT=$(run_sql_safe "
select tablespace_name,
       sum(bytes_used)/1024/1024 MB_USED,
       sum(bytes_free)/1024/1024 MB_FREE
from v\\$temp_space_header
group by tablespace_name;
")

    html_add "${DB} TEMP Usage" "INFO" "$OUT"
}

########################################
# FRA
########################################
check_fra() {
    DB="$1"

    OUT=$(run_sql_safe "
select name,
       round(space_used/space_limit*100,2) pct_used
from v\\$recovery_file_dest;
")

    if echo "$OUT" | grep -E '[8-9][0-9]\.'; then
        html_add "${DB} FRA Usage" "WARN" "$OUT"
        set_warn
    else
        html_add "${DB} FRA Usage" "OK" "$OUT"
    fi
}

########################################
# INVALID COPY / COMPONENT CHECK
########################################
check_invalid_cop() {
    DB="$1"

    OUT=$(run_sql_safe "
select comp_name,status
from dba_registry
where status <> 'VALID';
")

    html_add "${DB} Invalid Components" "INFO" "$OUT"
}

########################################
# RMAN
########################################
check_rman() {
    DB="$1"

    OUT=$(run_sql_safe "
select status,
       input_type,
       start_time,
       end_time
from v\\$rman_backup_job_details
where start_time > sysdate-7
order by start_time desc;
")

    html_add "${DB} RMAN Backup" "INFO" "$OUT"
}

########################################
# SCHEDULER FAILURES
########################################
check_scheduler_failures() {
    DB="$1"

    OUT=$(run_sql_safe "
select owner,
       job_name,
       status,
       log_date
from dba_scheduler_job_run_details
where status <> 'SUCCEEDED'
and log_date > sysdate-1;
")

    if echo "$OUT" | grep -q "[A-Z]"; then
        html_add "${DB} Scheduler Failures" "WARN" "$OUT"
        set_warn
    else
        html_add "${DB} Scheduler Failures" "OK" "No failures"
    fi
}
########################################
# ORA ERRORS LAST 24 HOURS
########################################
check_ora_errors() {
    DB="$1"

    if command -v adrci >/dev/null 2>&1; then
        OUT=$(adrci exec="show alert -term -p \"MESSAGE_TEXT like '%ORA-%' and originating_timestamp > systimestamp-1\"" 2>/dev/null)

        if [ -n "$OUT" ]; then
            html_add "${DB} ORA Errors (24h)" "WARN" "$OUT"
            set_warn
        else
            html_add "${DB} ORA Errors (24h)" "OK" "No ORA errors"
        fi
    else
        html_add "${DB} ORA Errors (24h)" "INFO" "ADRCI not available"
    fi
}

########################################
# ARCHIVE LOG
########################################
check_archivelog() {
    DB="$1"

    OUT=$(run_sql_safe "
archive log list;
select count(*) ARCHIVES_LAST_24H
from v\\$archived_log
where first_time > sysdate-1;
")

    html_add "${DB} Archive Log" "INFO" "$OUT"
}

########################################
# DATAGUARD DETECTION
########################################
is_dataguard() {
    OUT=$(run_sql_safe "
select database_role from v\\$database;
")
    echo "$OUT" | grep -q "PRIMARY\|STANDBY"
    return $?
}

########################################
# DATAGUARD HEALTH
########################################
check_dataguard() {
    DB="$1"

    OUT=$(run_sql_safe "
select name,value,unit from v\\$dataguard_stats;
select process,status,thread#,sequence# from v\\$managed_standby;
")

    html_add "${DB} Data Guard" "INFO" "$OUT"
}

########################################
# FILESYSTEM
########################################
check_filesystem() {
    if [ "$OS_TYPE" = "SunOS" ]; then
        OUT=$(df -k 2>/dev/null)
    else
        OUT=$(df -h 2>/dev/null)
    fi

    html_add "Filesystem Usage" "INFO" "$OUT"
}

########################################
# MEMORY
########################################
check_memory() {
    if [ "$OS_TYPE" = "SunOS" ]; then
        OUT=$(vmstat 2 5 2>/dev/null)
    else
        OUT=$(free -m 2>/dev/null)
    fi

    html_add "Memory Usage" "INFO" "$OUT"
}

########################################
# CPU
########################################
check_cpu() {
    if command -v mpstat >/dev/null 2>&1; then
        OUT=$(mpstat 2 3 2>/dev/null)
    else
        OUT=$(uptime 2>/dev/null)
    fi

    html_add "CPU Usage" "INFO" "$OUT"
}

########################################
# LOCKED OBJECTS
########################################
check_locked_objects() {
    DB="$1"

    OUT=$(run_sql_safe "
select s.sid,
       s.serial#,
       s.username,
       o.object_name
from v\\$locked_object l,
     dba_objects o,
     v\\$session s
where l.object_id = o.object_id
and l.session_id = s.sid;
")

    if echo "$OUT" | grep -q "[A-Z]"; then
        html_add "${DB} Locked Objects" "WARN" "$OUT"
        set_warn
    else
        html_add "${DB} Locked Objects" "OK" "No locked objects"
    fi
}

########################################
# MAIN DB CHECK
########################################
run_db_checks() {
    DB="$1"

    log "Running checks for $DB"

    check_srvctl_db "$DB"
    check_srvctl_services "$DB"
    check_db_status "$DB"
    check_invalid_objects "$DB"
    check_invalid_components "$DB"
    check_invalid_cop "$DB"
    check_blocking_sessions "$DB"
    check_locked_objects "$DB"
    check_long_running "$DB"
    check_resource_limits "$DB"
    check_tablespace "$DB"
    check_temp "$DB"
    check_fra "$DB"
    check_rman "$DB"
    check_scheduler_failures "$DB"
    check_archivelog "$DB"
    check_ora_errors "$DB"

    if is_dataguard; then
        check_dataguard "$DB"
    fi
}
########################################
# EMAIL REPORT
########################################
send_email() {
    [ "$EMAIL_ENABLED" != "Y" ] && return

    if command -v mailx >/dev/null 2>&1; then
        mailx -s "Oracle Health Report - ${HOSTNAME}" \
            -a "$HTML_REPORT" \
            "$EMAIL_TO" < /dev/null
    elif command -v mail >/dev/null 2>&1; then
        mail -s "Oracle Health Report - ${HOSTNAME}" \
            "$EMAIL_TO" < "$HTML_REPORT"
    fi
}

########################################
# VALIDATE SQLPLUS
########################################
validate_tools() {
    command -v sqlplus >/dev/null 2>&1 || {
        echo "sqlplus not found"
        exit 1
    }
}

########################################
# MAIN
########################################
main() {
    log "Starting ${SCRIPT_NAME} ${VERSION}"

    validate_tools
    detect_oratab
    html_init

    check_crs
    check_crs_resources
    check_listener
    check_asm
    check_filesystem
    check_memory
    check_cpu

    DBS=$(discover_dbs)

    if [ -z "$DBS" ]; then
        html_add "Database Discovery" "CRITICAL" "No running databases discovered"
        set_crit
    else
        for DB in $DBS
        do
            set_oracle_env "$DB"

            if [ $? -ne 0 ]; then
                html_add "$DB Environment" "CRITICAL" "ORACLE_HOME not found in oratab"
                set_crit
                continue
            fi

            run_db_checks "$DB"
        done
    fi

    html_close
    send_email

    log "Report generated: $HTML_REPORT"
    log "Completed with exit code ${EXIT_CODE}"

    exit "$EXIT_CODE"
}

main "$@"