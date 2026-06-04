#!/bin/sh
# =============================================================================
# Script      : oracle19c_healthcheck.sh
# Purpose     : Oracle 19c Multi-Instance Health Check
#               Supports Linux and Solaris 10/11 (POSIX /bin/sh)
# Author      : DBA Team
# =============================================================================
# USAGE:
#   ./oracle19c_healthcheck.sh [OPTIONS]
#
# OPTIONS:
#   -s SID       Run health check for a specific SID only (optional)
#   -l DIR       Log directory  (default: /var/log/oracle/healthcheck)
#   -e EMAIL     Send HTML report by email after completion
#   -H           Generate HTML report (auto-enabled when -e is used)
#   -h           Show this help message
#
# EXAMPLES:
#   ./oracle19c_healthcheck.sh
#   ./oracle19c_healthcheck.sh -s MYDB
#   ./oracle19c_healthcheck.sh -H
#   ./oracle19c_healthcheck.sh -H -e dba@company.com
#   ./oracle19c_healthcheck.sh -s MYDB -H -e dba@company.com
#   ./oracle19c_healthcheck.sh -l /dba/logs -H -e dba@company.com
#
# EXCLUSIONS (always skipped):
#   +ASM*   — Grid / ASM instances
#   *APX*   — Oracle APEX engine
#   *MGMT*  — Enterprise Manager repository
# =============================================================================

PATH=/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin
export PATH

# ---------------------------------------------------------------------------
# DEFAULTS (overridden by CLI flags)
# ---------------------------------------------------------------------------
OPT_SID=""
OPT_LOG_DIR="/var/log/oracle/healthcheck"
OPT_EMAIL=""
OPT_HTML=0
DBA_USER="/ as sysdba"

# ---------------------------------------------------------------------------
# HELP
# ---------------------------------------------------------------------------
show_help() {
cat <<HELP
Oracle 19c Multi-Instance Database Health Check
Compatible with: Linux and Solaris 10/11

USAGE:
  ./oracle19c_healthcheck.sh [OPTIONS]

OPTIONS:
  -s SID    Target a specific SID (default: all running non-system instances)
  -l DIR    Directory for logs and reports (default: /var/log/oracle/healthcheck)
  -e EMAIL  Email address to send the HTML report to after completion
  -H        Generate an HTML report in the log directory
  -h        Show this help and exit

EXAMPLES:
  Check all instances, generate HTML, email report:
    ./oracle19c_healthcheck.sh -H -e dba@company.com

  Check one instance only:
    ./oracle19c_healthcheck.sh -s ORCL

  Check one instance with HTML + email:
    ./oracle19c_healthcheck.sh -s ORCL -H -e dba@company.com

  Custom log directory:
    ./oracle19c_healthcheck.sh -l /dba/healthcheck_logs -H

OUTPUT:
  - Timestamped plain-text log per instance: hc_<SID>_<TIMESTAMP>.log
  - Consolidated HTML report (with -H):       hc_report_<TIMESTAMP>.html
  - Master run log:                            hc_master_<TIMESTAMP>.log

NOTES:
  - Always skips: +ASM*, *APX*, *MGMT* instances
  - Requires OS authentication (/ as sysdba); run as oracle OS user
  - ORACLE_HOME is resolved from oratab for each SID
  - oratab locations: /var/opt/oracle/oratab (Solaris) | /etc/oratab (Linux)
HELP
}

# ---------------------------------------------------------------------------
# PARSE ARGUMENTS
# ---------------------------------------------------------------------------
while getopts "s:l:e:Hh" OPT; do
    case "${OPT}" in
        s) OPT_SID="${OPTARG}" ;;
        l) OPT_LOG_DIR="${OPTARG}" ;;
        e) OPT_EMAIL="${OPTARG}"; OPT_HTML=1 ;;
        H) OPT_HTML=1 ;;
        h) show_help; exit 0 ;;
        *) show_help; exit 1 ;;
    esac
done

LOG_DIR="${OPT_LOG_DIR}"
MASTER_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
MASTER_LOG="${LOG_DIR}/hc_master_${MASTER_TIMESTAMP}.log"
HTML_REPORT="${LOG_DIR}/hc_report_${MASTER_TIMESTAMP}.html"

# Global counters (accumulated across all SIDs)
MASTER_ISSUES=0
MASTER_WARNINGS=0
MASTER_PASS=0
MASTER_DB_COUNT=0

# ---------------------------------------------------------------------------
# COLOUR (terminal only; log files get plain text)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    CR='\033[0;31m' CG='\033[0;32m' CY='\033[1;33m'
    CC='\033[0;36m' CM='\033[0;35m' CB='\033[1m' CZ='\033[0m'
else
    CR='' CG='' CY='' CC='' CM='' CB='' CZ=''
fi
TAG_PASS="${CG}[PASS]${CZ}"
TAG_FAIL="${CR}[FAIL]${CZ}"
TAG_WARN="${CY}[WARN]${CZ}"
TAG_INFO="${CC}[INFO]${CZ}"

# ---------------------------------------------------------------------------
# ORATAB DETECTION
# ---------------------------------------------------------------------------
locate_oratab() {
    if   [ -f /var/opt/oracle/oratab ]; then ORATAB=/var/opt/oracle/oratab   # Solaris
    elif [ -f /etc/oratab ];            then ORATAB=/etc/oratab               # Linux
    else
        printf "ERROR: oratab not found (/var/opt/oracle/oratab or /etc/oratab)\n" >&2
        exit 1
    fi
    export ORATAB
}

# ---------------------------------------------------------------------------
# RESOLVE ORACLE_HOME FROM ORATAB FOR A GIVEN SID
# oratab format:  SID:ORACLE_HOME:Y|N
# ---------------------------------------------------------------------------
get_oracle_home() {
    awk -F: -v sid="$1" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        $1 == sid { print $2; exit }
    ' "${ORATAB}"
}

# ---------------------------------------------------------------------------
# DISCOVER RUNNING SIDs VIA PMON (exclude ASM / APX / MGMT)
# ---------------------------------------------------------------------------
discover_sids() {
    ps -ef 2>/dev/null \
        | grep 'ora_pmon_' | grep -v grep \
        | awk '{for(i=1;i<=NF;i++) if($i~/^ora_pmon_/){sub(/^ora_pmon_/,"",$i);print $i}}' \
        | grep -v '^+ASM' \
        | grep -iv 'APX' \
        | grep -iv 'MGMT' \
        | sort -u
}

# ---------------------------------------------------------------------------
# LOGGING HELPERS  (LOG_FILE must be set before calling)
# ---------------------------------------------------------------------------
log() { printf "%s\n" "$*" | tee -a "${LOG_FILE}"; }

print_header() {
    LINE="================================================================"
    printf "\n${CB}${CC}%s${CZ}\n  ${CB}%-62s${CZ}\n${CB}${CC}%s${CZ}\n" \
        "${LINE}" "$1" "${LINE}" | tee -a "${LOG_FILE}"
}

print_result() {
    _ST="$1"; _MSG="$2"
    case "${_ST}" in
        PASS) _TAG="${TAG_PASS}" ;;
        FAIL) _TAG="${TAG_FAIL}"; ISSUES=$((ISSUES+1)) ;;
        WARN) _TAG="${TAG_WARN}"; WARNINGS=$((WARNINGS+1)) ;;
        *)    _TAG="${TAG_INFO}" ;;
    esac
    printf "  %b  %s\n" "${_TAG}" "${_MSG}" | tee -a "${LOG_FILE}"
}

sep() { printf "  %s\n" "----------------------------------------------------------------" | tee -a "${LOG_FILE}"; }

ensure_log_dir() {
    mkdir -p "${LOG_DIR}" 2>/dev/null || { printf "ERROR: Cannot create log dir: %s\n" "${LOG_DIR}" >&2; exit 1; }
    [ -w "${LOG_DIR}" ] || { printf "ERROR: Log dir not writable: %s\n" "${LOG_DIR}" >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# SQL EXECUTION HELPERS
# ---------------------------------------------------------------------------
# Scalar query → trimmed single value
run_sql() {
    _SID="$1"; _OH="$2"; _SQL="$3"
    ORACLE_SID="${_SID}" ORACLE_HOME="${_OH}" \
    "${_OH}/bin/sqlplus" -S "${DBA_USER}" 2>/dev/null <<EOF
SET PAGESIZE 0 LINESIZE 300 FEEDBACK OFF HEADING OFF TRIMSPOOL ON ECHO OFF
WHENEVER SQLERROR EXIT 1
${_SQL}
EXIT;
EOF
}

# Tabular query → written to LOG_FILE via tee
run_sql_table() {
    _SID="$1"; _OH="$2"; _FMT="$3"; _SQL="$4"
    ORACLE_SID="${_SID}" ORACLE_HOME="${_OH}" \
    "${_OH}/bin/sqlplus" -S "${DBA_USER}" 2>/dev/null <<EOF | tee -a "${LOG_FILE}"
SET PAGESIZE 200 LINESIZE 220 FEEDBACK OFF TRIMSPOOL ON ECHO OFF
${_FMT}
${_SQL}
EXIT;
EOF
}

# Scalar — trim all whitespace/newlines
sql_val() { run_sql "$1" "$2" "$3" | tr -d ' \t\n\r'; }

# ---------------------------------------------------------------------------
# HTML REPORT BUILDER  (writes to global HTML_REPORT file)
# ---------------------------------------------------------------------------
html_init() {
    cat > "${HTML_REPORT}" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Oracle 19c Health Check Report</title>
<style>
  :root{--pass:#1a7f3c;--fail:#c0392b;--warn:#d68910;--info:#1a6fa8;--bg:#f4f6f8;--card:#fff;--border:#dde1e7;}
  *{box-sizing:border-box;margin:0;padding:0;}
  body{font-family:'Segoe UI',Arial,sans-serif;background:var(--bg);color:#222;font-size:13px;}
  header{background:linear-gradient(135deg,#1a2a4a 0%,#2c5282 100%);color:#fff;padding:24px 32px;}
  header h1{font-size:22px;font-weight:700;margin-bottom:6px;}
  header .meta{font-size:12px;opacity:.85;display:flex;gap:24px;flex-wrap:wrap;margin-top:8px;}
  .container{max-width:1400px;margin:0 auto;padding:20px 24px;}
  /* Scorecard */
  .scorecard{display:flex;gap:16px;flex-wrap:wrap;margin-bottom:24px;}
  .score-box{flex:1;min-width:150px;background:var(--card);border-radius:10px;
             padding:18px 20px;box-shadow:0 1px 4px rgba(0,0,0,.08);border-top:4px solid #ccc;text-align:center;}
  .score-box.pass{border-color:var(--pass);}
  .score-box.fail{border-color:var(--fail);}
  .score-box.warn{border-color:var(--warn);}
  .score-box.info{border-color:var(--info);}
  .score-box .num{font-size:36px;font-weight:800;line-height:1;}
  .score-box .lbl{font-size:11px;text-transform:uppercase;letter-spacing:.6px;margin-top:4px;opacity:.7;}
  .score-box.pass .num{color:var(--pass);}
  .score-box.fail .num{color:var(--fail);}
  .score-box.warn .num{color:var(--warn);}
  .score-box.info .num{color:var(--info);}
  /* Progress bar */
  .pbar-wrap{background:var(--card);border-radius:10px;padding:16px 20px;
             margin-bottom:24px;box-shadow:0 1px 4px rgba(0,0,0,.08);}
  .pbar-wrap h3{font-size:13px;margin-bottom:10px;color:#555;}
  .pbar{display:flex;height:22px;border-radius:6px;overflow:hidden;width:100%;}
  .pbar .seg{display:flex;align-items:center;justify-content:center;
             font-size:11px;font-weight:700;color:#fff;transition:width .5s;}
  .pbar .seg.pass{background:var(--pass);}
  .pbar .seg.fail{background:var(--fail);}
  .pbar .seg.warn{background:var(--warn);}
  .pbar-legend{display:flex;gap:16px;margin-top:8px;font-size:11px;}
  .pbar-legend span{display:flex;align-items:center;gap:5px;}
  .pbar-legend .dot{width:10px;height:10px;border-radius:50%;}
  /* DB Nav tabs */
  .tab-nav{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:4px;}
  .tab-btn{padding:7px 16px;border-radius:6px 6px 0 0;border:1px solid var(--border);
           border-bottom:none;cursor:pointer;background:#e8ecf0;font-size:12px;
           font-weight:600;transition:background .2s;}
  .tab-btn.active,.tab-btn:hover{background:var(--card);}
  .tab-btn.has-fail{border-top:3px solid var(--fail);}
  .tab-btn.has-warn{border-top:3px solid var(--warn);}
  .tab-btn.all-pass{border-top:3px solid var(--pass);}
  /* DB panels */
  .db-panel{display:none;background:var(--card);border:1px solid var(--border);
            border-radius:0 10px 10px 10px;padding:20px;
            box-shadow:0 2px 8px rgba(0,0,0,.06);}
  .db-panel.active{display:block;}
  /* Section cards */
  .section{margin-bottom:16px;border:1px solid var(--border);border-radius:8px;overflow:hidden;}
  .section-head{padding:10px 16px;font-weight:700;font-size:12px;
                display:flex;align-items:center;gap:8px;cursor:pointer;
                background:#f0f3f7;user-select:none;}
  .section-head .arrow{margin-left:auto;transition:transform .2s;}
  .section-head.open .arrow{transform:rotate(90deg);}
  .section-body{padding:12px 16px;display:none;}
  .section-body.open{display:block;}
  /* Result rows */
  .result{display:flex;align-items:flex-start;gap:10px;padding:5px 0;
          border-bottom:1px solid #f0f0f0;font-size:12px;}
  .result:last-child{border-bottom:none;}
  .badge{display:inline-flex;align-items:center;justify-content:center;
         padding:2px 8px;border-radius:4px;font-size:10px;font-weight:800;
         letter-spacing:.4px;min-width:52px;color:#fff;white-space:nowrap;}
  .badge.PASS{background:var(--pass);}
  .badge.FAIL{background:var(--fail);}
  .badge.WARN{background:var(--warn);}
  .badge.INFO{background:var(--info);}
  /* Tables */
  .sql-table{width:100%;border-collapse:collapse;font-size:11px;margin-top:8px;}
  .sql-table th{background:#2c5282;color:#fff;padding:6px 10px;text-align:left;white-space:nowrap;}
  .sql-table td{padding:5px 10px;border-bottom:1px solid #eee;}
  .sql-table tr:nth-child(even) td{background:#f9fafb;}
  .sql-table tr:hover td{background:#edf2ff;}
  /* DB info bar */
  .db-info-bar{display:flex;gap:12px;flex-wrap:wrap;background:#f8f9fb;
               border-radius:6px;padding:10px 14px;margin-bottom:14px;font-size:11px;}
  .db-info-bar .kv{display:flex;flex-direction:column;}
  .db-info-bar .kv span:first-child{font-weight:700;color:#555;font-size:10px;text-transform:uppercase;}
  /* Summary mini-table */
  .summary-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:10px;margin-bottom:20px;}
  .sdb-card{border-radius:8px;padding:12px 14px;font-size:12px;
            border-left:4px solid #ccc;background:var(--card);
            box-shadow:0 1px 3px rgba(0,0,0,.06);}
  .sdb-card.pass{border-color:var(--pass);}
  .sdb-card.fail{border-color:var(--fail);}
  .sdb-card.warn{border-color:var(--warn);}
  .sdb-card .sdb-sid{font-weight:800;font-size:13px;margin-bottom:4px;}
  .sdb-card .sdb-counts{display:flex;gap:8px;margin-top:4px;}
  .sdb-card .sdb-cnt{font-size:11px;padding:1px 7px;border-radius:3px;color:#fff;}
  .sdb-card .sdb-cnt.f{background:var(--fail);}
  .sdb-card .sdb-cnt.w{background:var(--warn);}
  .sdb-card .sdb-cnt.p{background:var(--pass);}
  footer{text-align:center;padding:16px;font-size:11px;color:#999;margin-top:20px;}
  pre{font-family:Consolas,'Courier New',monospace;white-space:pre-wrap;word-break:break-all;
      background:#f5f5f5;padding:8px;border-radius:4px;font-size:11px;max-height:300px;overflow-y:auto;}
  @media(max-width:700px){.scorecard{flex-direction:column;}.meta{flex-direction:column;gap:4px;}}
</style>
</head>
<body>
HTMLHEAD
}

html_header() {
    _HOST="$1"; _DATE="$2"; _ORATAB="$3"; _OS="$4"
    cat >> "${HTML_REPORT}" << HDREOF
<header>
  <h1>&#128202; Oracle 19c Database Health Check Report</h1>
  <div class="meta">
    <span>&#128197; Generated: ${_DATE}</span>
    <span>&#128421; Host: ${_HOST}</span>
    <span>&#128295; OS: ${_OS}</span>
    <span>&#128196; oratab: ${_ORATAB}</span>
  </div>
</header>
<div class="container">
HDREOF
}

html_scorecards() {
    _TOTAL="$1"; _PASS="$2"; _WARN="$3"; _FAIL="$4"
    # Compute percentages via awk (POSIX portable)
    PCT_PASS=$(awk -v p="${_PASS}" -v t="${_TOTAL}" 'BEGIN{if(t>0)printf "%.0f",p/t*100;else print 0}')
    PCT_FAIL=$(awk -v f="${_FAIL}" -v t="${_TOTAL}" 'BEGIN{if(t>0)printf "%.0f",f/t*100;else print 0}')
    PCT_WARN=$(awk -v w="${_WARN}" -v t="${_TOTAL}" 'BEGIN{if(t>0)printf "%.0f",w/t*100;else print 0}')
    # Clamp so bar always sums to 100
    PCT_REST=$((100 - PCT_PASS - PCT_FAIL - PCT_WARN))
    [ "${PCT_REST}" -lt 0 ] && PCT_REST=0
    cat >> "${HTML_REPORT}" << SCEOF
<div class="scorecard">
  <div class="score-box info"><div class="num">${_TOTAL}</div><div class="lbl">Databases Checked</div></div>
  <div class="score-box pass"><div class="num">${PCT_PASS}%</div><div class="lbl">Pass Rate</div></div>
  <div class="score-box fail"><div class="num">${_FAIL}</div><div class="lbl">Critical Issues</div></div>
  <div class="score-box warn"><div class="num">${_WARN}</div><div class="lbl">Warnings</div></div>
</div>
<div class="pbar-wrap">
  <h3>Overall Health Distribution</h3>
  <div class="pbar">
    <div class="seg pass" style="width:${PCT_PASS}%">${PCT_PASS}%</div>
    <div class="seg warn" style="width:${PCT_WARN}%">${PCT_WARN}%</div>
    <div class="seg fail" style="width:${PCT_FAIL}%">${PCT_FAIL}%</div>
  </div>
  <div class="pbar-legend">
    <span><span class="dot" style="background:var(--pass)"></span>Pass ${PCT_PASS}%</span>
    <span><span class="dot" style="background:var(--warn)"></span>Warning ${PCT_WARN}%</span>
    <span><span class="dot" style="background:var(--fail)"></span>Critical ${PCT_FAIL}%</span>
  </div>
</div>
SCEOF
}

html_summary_grid_start() { printf '<h3 style="margin-bottom:10px;font-size:14px;">Database Summary</h3>\n<div class="summary-grid">\n' >> "${HTML_REPORT}"; }
html_summary_grid_end()   { printf '</div>\n' >> "${HTML_REPORT}"; }

html_summary_card() {
    _SID="$1"; _FAIL="$2"; _WARN="$3"; _OH="$4"
    if   [ "${_FAIL:-0}" -gt 0 ]; then _CLS="fail"
    elif [ "${_WARN:-0}" -gt 0 ]; then _CLS="warn"
    else                               _CLS="pass"; fi
    cat >> "${HTML_REPORT}" << CARDEOF
<div class="sdb-card ${_CLS}">
  <div class="sdb-sid">${_SID}</div>
  <div style="font-size:10px;color:#666;margin-bottom:4px;word-break:break-all">${_OH}</div>
  <div class="sdb-counts">
    <span class="sdb-cnt f">FAIL: ${_FAIL:-0}</span>
    <span class="sdb-cnt w">WARN: ${_WARN:-0}</span>
  </div>
</div>
CARDEOF
}

html_tabs_start() { printf '<div class="tab-nav" id="tabNav">\n' >> "${HTML_REPORT}"; }
html_tab_btn()    {
    _SID="$1"; _FAIL="$2"; _WARN="$3"; _FIRST="$4"
    if   [ "${_FAIL:-0}" -gt 0 ]; then _CLS="has-fail"
    elif [ "${_WARN:-0}" -gt 0 ]; then _CLS="has-warn"
    else                               _CLS="all-pass"; fi
    _ACTIVE=""; [ "${_FIRST}" = "1" ] && _ACTIVE=" active"
    printf '<button class="tab-btn %s%s" onclick="showDB(this,'"'"'%s'"'"')">%s</button>\n' \
        "${_CLS}" "${_ACTIVE}" "${_SID}" "${_SID}" >> "${HTML_REPORT}"
}
html_tabs_end()   { printf '</div>\n' >> "${HTML_REPORT}"; }

html_db_panel_start() {
    _SID="$1"; _FIRST="$2"
    _ACTIVE=""; [ "${_FIRST}" = "1" ] && _ACTIVE=" active"
    printf '<div class="db-panel%s" id="db_%s">\n' "${_ACTIVE}" "${_SID}" >> "${HTML_REPORT}"
}
html_db_panel_end()   { printf '</div>\n' >> "${HTML_REPORT}"; }

html_db_info() {
    cat >> "${HTML_REPORT}" << DBINFOEOF
<div class="db-info-bar">
  <div class="kv"><span>SID</span><span>$1</span></div>
  <div class="kv"><span>DB Name</span><span>$2</span></div>
  <div class="kv"><span>Version</span><span>$3</span></div>
  <div class="kv"><span>Role</span><span>$4</span></div>
  <div class="kv"><span>Open Mode</span><span>$5</span></div>
  <div class="kv"><span>Startup</span><span>$6</span></div>
  <div class="kv"><span>Host</span><span>$7</span></div>
  <div class="kv"><span>ORACLE_HOME</span><span>$8</span></div>
</div>
DBINFOEOF
}

html_section_start() {
    _TITLE="$1"; _ID="$2"
    cat >> "${HTML_REPORT}" << SECEOF
<div class="section">
  <div class="section-head" onclick="toggleSection(this)" id="sh_${_ID}">
    <span>${_TITLE}</span><span class="arrow">&#9658;</span>
  </div>
  <div class="section-body" id="sb_${_ID}">
SECEOF
}
html_section_end() { printf '  </div>\n</div>\n' >> "${HTML_REPORT}"; }

html_result() {
    _BADGE="$1"; _MSG="$2"
    printf '    <div class="result"><span class="badge %s">%s</span><span>%s</span></div>\n' \
        "${_BADGE}" "${_BADGE}" "${_MSG}" >> "${HTML_REPORT}"
}

# Append raw SQL output as an HTML <pre> block
html_pre() { printf '    <pre>%s</pre>\n' "$1" >> "${HTML_REPORT}"; }

html_table_from_sql() {
    # Takes multi-line SQL output and renders as HTML table
    # First line = header (space-delimited), rest = data rows
    _DATA="$1"
    if [ -z "${_DATA}" ]; then return; fi
    printf '    <table class="sql-table">\n' >> "${HTML_REPORT}"
    _FIRST=1
    printf '%s\n' "${_DATA}" | while IFS= read -r _ROW; do
        [ -z "$(printf '%s' "${_ROW}" | tr -d ' \t-')" ] && continue
        if [ "${_FIRST}" -eq 1 ]; then
            printf '      <thead><tr>' >> "${HTML_REPORT}"
            for _COL in ${_ROW}; do
                printf '<th>%s</th>' "${_COL}" >> "${HTML_REPORT}"
            done
            printf '</tr></thead>\n<tbody>\n' >> "${HTML_REPORT}"
            _FIRST=0
        else
            printf '      <tr>' >> "${HTML_REPORT}"
            for _CELL in ${_ROW}; do
                printf '<td>%s</td>' "${_CELL}" >> "${HTML_REPORT}"
            done
            printf '</tr>\n' >> "${HTML_REPORT}"
        fi
    done
    printf '    </tbody></table>\n' >> "${HTML_REPORT}"
}

html_footer() {
    cat >> "${HTML_REPORT}" << 'FOOTEOF'
</div><!-- /container -->
<footer>Oracle 19c Health Check &mdash; Generated by oracle19c_healthcheck.sh</footer>
<script>
function showDB(btn,sid){
  document.querySelectorAll('.tab-btn').forEach(b=>b.classList.remove('active'));
  document.querySelectorAll('.db-panel').forEach(p=>p.classList.remove('active'));
  btn.classList.add('active');
  var p=document.getElementById('db_'+sid);
  if(p) p.classList.add('active');
}
function toggleSection(hdr){
  hdr.classList.toggle('open');
  var body=hdr.nextElementSibling;
  if(body) body.classList.toggle('open');
}
// Auto-open sections with FAIL results
document.addEventListener('DOMContentLoaded',function(){
  document.querySelectorAll('.badge.FAIL').forEach(function(b){
    var body=b.closest('.section-body');
    if(body){
      body.classList.add('open');
      var hdr=body.previousElementSibling;
      if(hdr) hdr.classList.add('open');
    }
  });
  // Open first section of active panel
  var ap=document.querySelector('.db-panel.active');
  if(ap){
    var fh=ap.querySelector('.section-head');
    var fb=ap.querySelector('.section-body');
    if(fh) fh.classList.add('open');
    if(fb) fb.classList.add('open');
  }
});
</script>
</body>
</html>
FOOTEOF
}

# ---------------------------------------------------------------------------
# COLLECT ONE TABLE AS STRING (for HTML embedding)
# ---------------------------------------------------------------------------
sql_table_str() {
    _SID="$1"; _OH="$2"; _FMT="$3"; _SQL="$4"
    ORACLE_SID="${_SID}" ORACLE_HOME="${_OH}" \
    "${_OH}/bin/sqlplus" -S "${DBA_USER}" 2>/dev/null <<EOF
SET PAGESIZE 200 LINESIZE 220 FEEDBACK OFF TRIMSPOOL ON ECHO OFF
${_FMT}
${_SQL}
EXIT;
EOF
}

# ===========================================================================
# PER-DATABASE HEALTH CHECK
# ===========================================================================
run_healthcheck() {
    ORACLE_SID="$1"; ORACLE_HOME="$2"; IS_FIRST="$3"
    export ORACLE_SID ORACLE_HOME
    SQLPLUS="${ORACLE_HOME}/bin/sqlplus"

    _TS=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="${LOG_DIR}/hc_${ORACLE_SID}_${_TS}.log"
    ISSUES=0; WARNINGS=0

    # -- Log header --
    {
    printf "================================================================\n"
    printf "  Oracle 19c Health Check: %s\n" "${ORACLE_SID}"
    printf "  ORACLE_HOME : %s\n" "${ORACLE_HOME}"
    printf "  Host        : %s\n" "$(uname -n)"
    printf "  OS          : %s %s\n" "$(uname -s)" "$(uname -r)"
    printf "  Started     : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "  oratab      : %s\n" "${ORATAB}"
    printf "================================================================\n"
    } | tee -a "${LOG_FILE}"

    printf "\n${CB}${CM}  ═══ Checking SID: %-12s ════════════════════════${CZ}\n\n" "${ORACLE_SID}"

    # -- Fetch core instance info --
    DB_STATUS=$(sql_val  "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT STATUS FROM V\$INSTANCE;")
    DB_OPENMODE=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT REPLACE(OPEN_MODE,' ','') FROM V\$DATABASE;")
    DB_ROLE=$(sql_val    "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT DATABASE_ROLE FROM V\$DATABASE;")
    DB_NAME=$(sql_val    "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT NAME FROM V\$DATABASE;")
    DB_VER=$(sql_val     "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT VERSION FROM V\$INSTANCE;")
    DB_STARTUP=$(run_sql  "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT TO_CHAR(STARTUP_TIME,'YYYY-MM-DD HH24:MI:SS') FROM V\$INSTANCE;" | tr -d '\t\n')
    DB_HOST=$(sql_val    "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT HOST_NAME FROM V\$INSTANCE;")

    log "  DB Name : ${DB_NAME}  Version: ${DB_VER}  Role: ${DB_ROLE}  Open: ${DB_OPENMODE}"

    # HTML: open panel & info bar
    if [ "${OPT_HTML}" -eq 1 ]; then
        html_db_panel_start "${ORACLE_SID}" "${IS_FIRST}"
        html_db_info "${ORACLE_SID}" "${DB_NAME:-?}" "${DB_VER:-?}" "${DB_ROLE:-?}" \
            "${DB_OPENMODE:-?}" "${DB_STARTUP:-?}" "${DB_HOST:-?}" "${ORACLE_HOME}"
    fi

    # -----------------------------------------------------------------------
    # S1 — INSTANCE STATUS
    # -----------------------------------------------------------------------
    print_header "1. INSTANCE STATUS"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "1. Instance Status" "s1_${ORACLE_SID}"

    if [ "${DB_STATUS}" = "OPEN" ]; then
        print_result PASS "Instance status: OPEN"
        [ "${OPT_HTML}" -eq 1 ] && html_result PASS "Instance status: OPEN"
    else
        print_result FAIL "Instance status: ${DB_STATUS:-UNKNOWN}"
        [ "${OPT_HTML}" -eq 1 ] && html_result FAIL "Instance status: ${DB_STATUS:-UNKNOWN}"
    fi

    case "${DB_OPENMODE}" in
        READWRITE)
            print_result PASS "Open mode: READ WRITE"
            [ "${OPT_HTML}" -eq 1 ] && html_result PASS "Open mode: READ WRITE" ;;
        READONLYWITHAPPLY)
            print_result INFO "Open mode: READ ONLY WITH APPLY (Active Data Guard)"
            [ "${OPT_HTML}" -eq 1 ] && html_result INFO "Open mode: READ ONLY WITH APPLY (Active Data Guard)" ;;
        READONLY)
            print_result WARN "Open mode: READ ONLY"
            [ "${OPT_HTML}" -eq 1 ] && html_result WARN "Open mode: READ ONLY" ;;
        *)
            print_result WARN "Open mode: ${DB_OPENMODE:-UNKNOWN}"
            [ "${OPT_HTML}" -eq 1 ] && html_result WARN "Open mode: ${DB_OPENMODE:-UNKNOWN}" ;;
    esac

    # Listener
    LSNRCTL="${ORACLE_HOME}/bin/lsnrctl"
    if [ -x "${LSNRCTL}" ]; then
        if ${LSNRCTL} status 2>/dev/null | grep -q "STATUS of the LISTENER"; then
            print_result PASS "Listener is UP"
            [ "${OPT_HTML}" -eq 1 ] && html_result PASS "Listener is UP"
        else
            print_result WARN "Listener status could not be confirmed"
            [ "${OPT_HTML}" -eq 1 ] && html_result WARN "Listener status could not be confirmed"
        fi
    fi

    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S2 — TABLESPACE USAGE
    # -----------------------------------------------------------------------
    print_header "2. TABLESPACE USAGE"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "2. Tablespace Usage" "s2_${ORACLE_SID}"

    TS_OUT=$(sql_table_str "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL TABLESPACE_NAME FORMAT A28
 COL TOTAL_MB        FORMAT 999999.9
 COL FREE_MB         FORMAT 999999.9
 COL USED_MB         FORMAT 999999.9
 COL PCT_USED        FORMAT 999.9
 COL STATUS          FORMAT A16" \
"SELECT df.TABLESPACE_NAME,
        ROUND(df.TOTAL_MB,1)                                   TOTAL_MB,
        ROUND(NVL(fs.FREE_MB,0),1)                             FREE_MB,
        ROUND(df.TOTAL_MB-NVL(fs.FREE_MB,0),1)                USED_MB,
        ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))
              /NULLIF(df.TOTAL_MB,0)*100,1)                    PCT_USED,
        CASE
          WHEN ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))
               /NULLIF(df.TOTAL_MB,0)*100,1)>=90 THEN '*** CRITICAL ***'
          WHEN ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))
               /NULLIF(df.TOTAL_MB,0)*100,1)>=80 THEN '** WARNING **'
          ELSE 'OK'
        END STATUS
   FROM (SELECT TABLESPACE_NAME,SUM(BYTES)/1024/1024 TOTAL_MB
           FROM DBA_DATA_FILES GROUP BY TABLESPACE_NAME) df,
        (SELECT TABLESPACE_NAME,SUM(BYTES)/1024/1024 FREE_MB
           FROM DBA_FREE_SPACE GROUP BY TABLESPACE_NAME) fs
  WHERE df.TABLESPACE_NAME=fs.TABLESPACE_NAME(+)
  ORDER BY PCT_USED DESC;")
    printf "%s\n" "${TS_OUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${TS_OUT}"

    CRIT_TS=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM(SELECT ROUND((df.T-NVL(fs.F,0))/NULLIF(df.T,0)*100,1) P
 FROM(SELECT SUM(BYTES)/1024/1024 T FROM DBA_DATA_FILES) df,
     (SELECT SUM(BYTES)/1024/1024 F FROM DBA_FREE_SPACE) fs
 HAVING ROUND((df.T-NVL(fs.F,0))/NULLIF(df.T,0)*100,1)>=90);")
    WARN_TS=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM(
 SELECT df.TABLESPACE_NAME,
        ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/NULLIF(df.TOTAL_MB,0)*100,1) P
 FROM(SELECT TABLESPACE_NAME,SUM(BYTES)/1024/1024 TOTAL_MB FROM DBA_DATA_FILES GROUP BY TABLESPACE_NAME) df,
     (SELECT TABLESPACE_NAME,SUM(BYTES)/1024/1024 FREE_MB  FROM DBA_FREE_SPACE  GROUP BY TABLESPACE_NAME) fs
 WHERE df.TABLESPACE_NAME=fs.TABLESPACE_NAME(+)
 HAVING ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/NULLIF(df.TOTAL_MB,0)*100,1) BETWEEN 80 AND 89.9);")

    if [ "${CRIT_TS:-0}" -gt 0 ]; then
        print_result FAIL "${CRIT_TS} tablespace(s) >= 90% full — CRITICAL"
        [ "${OPT_HTML}" -eq 1 ] && html_result FAIL "${CRIT_TS} tablespace(s) >= 90% full"
    fi
    if [ "${WARN_TS:-0}" -gt 0 ]; then
        print_result WARN "${WARN_TS} tablespace(s) 80-89% full"
        [ "${OPT_HTML}" -eq 1 ] && html_result WARN "${WARN_TS} tablespace(s) 80-89% full"
    fi
    if [ "${CRIT_TS:-0}" -eq 0 ] && [ "${WARN_TS:-0}" -eq 0 ]; then
        print_result PASS "All tablespaces within acceptable thresholds"
        [ "${OPT_HTML}" -eq 1 ] && html_result PASS "All tablespaces within acceptable thresholds"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S3 — REDO LOGS
    # -----------------------------------------------------------------------
    print_header "3. REDO LOG STATUS"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "3. Redo Logs" "s3_${ORACLE_SID}"

    REDO_OUT=$(sql_table_str "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL GROUP#   FORMAT 99
 COL MEMBERS  FORMAT 9
 COL SIZE_MB  FORMAT 9999
 COL STATUS   FORMAT A16
 COL ARCHIVED FORMAT A8
 COL MEMBER   FORMAT A55" \
"SELECT l.GROUP#,l.MEMBERS,ROUND(l.BYTES/1024/1024,0) SIZE_MB,
        l.STATUS,l.ARCHIVED,lf.MEMBER
 FROM V\$LOG l,V\$LOGFILE lf
 WHERE l.GROUP#=lf.GROUP# ORDER BY l.GROUP#;")
    printf "%s\n" "${REDO_OUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${REDO_OUT}"

    LOG_SW=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT COUNT(*) FROM V\$LOG_HISTORY WHERE FIRST_TIME>SYSDATE-1/24;")
    log "  Log switches last hour: ${LOG_SW:-0}"
    if [ "${LOG_SW:-0}" -gt 20 ]; then
        print_result WARN "High log switch rate: ${LOG_SW}/hr — consider larger redo logs"
        [ "${OPT_HTML}" -eq 1 ] && html_result WARN "High log switch rate: ${LOG_SW}/hr"
    else
        print_result PASS "Log switch rate normal: ${LOG_SW:-0}/hr"
        [ "${OPT_HTML}" -eq 1 ] && html_result PASS "Log switch rate normal: ${LOG_SW:-0}/hr"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S4 — ARCHIVE LOG & FRA
    # -----------------------------------------------------------------------
    print_header "4. ARCHIVE LOG & FRA"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "4. Archive Log & FRA" "s4_${ORACLE_SID}"

    ALOG_MODE=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT LOG_MODE FROM V\$DATABASE;")
    log "  Archive Log Mode: ${ALOG_MODE}"
    if [ "${ALOG_MODE}" = "ARCHIVELOG" ]; then
        print_result PASS "Database is in ARCHIVELOG mode"
        [ "${OPT_HTML}" -eq 1 ] && html_result PASS "Database is in ARCHIVELOG mode"
    else
        print_result WARN "Database is in NOARCHIVELOG mode"
        [ "${OPT_HTML}" -eq 1 ] && html_result WARN "Database is in NOARCHIVELOG mode"
    fi

    FRA_PCT=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT ROUND(SPACE_USED_PERCENT,1) FROM V\$RECOVERY_FILE_DEST;")
    if [ -n "${FRA_PCT}" ] && [ "${FRA_PCT}" != "0" ]; then
        log "  FRA Usage: ${FRA_PCT}%"
        FRA_CRIT=$(awk -v v="${FRA_PCT}" 'BEGIN{print(v+0>=85)?1:0}')
        FRA_WARN=$(awk -v v="${FRA_PCT}" 'BEGIN{print(v+0>=70)?1:0}')
        if   [ "${FRA_CRIT}" -eq 1 ]; then
            print_result FAIL "FRA CRITICAL: ${FRA_PCT}% used"
            [ "${OPT_HTML}" -eq 1 ] && html_result FAIL "FRA CRITICAL: ${FRA_PCT}% used"
        elif [ "${FRA_WARN}" -eq 1 ]; then
            print_result WARN "FRA WARNING: ${FRA_PCT}% used"
            [ "${OPT_HTML}" -eq 1 ] && html_result WARN "FRA WARNING: ${FRA_PCT}% used"
        else
            print_result PASS "FRA usage OK: ${FRA_PCT}%"
            [ "${OPT_HTML}" -eq 1 ] && html_result PASS "FRA usage OK: ${FRA_PCT}%"
        fi
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S5 — RMAN BACKUP
    # -----------------------------------------------------------------------
    print_header "5. RMAN BACKUP STATUS"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "5. RMAN Backup" "s5_${ORACLE_SID}"

    RMAN_OUT=$(sql_table_str "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL INPUT_TYPE  FORMAT A22
 COL STATUS      FORMAT A32
 COL START_TIME  FORMAT A17
 COL END_TIME    FORMAT A17
 COL ELAPSED_MIN FORMAT 9999.9" \
"SELECT INPUT_TYPE,STATUS,
        TO_CHAR(START_TIME,'YYYY-MM-DD HH24:MI') START_TIME,
        TO_CHAR(END_TIME,  'YYYY-MM-DD HH24:MI') END_TIME,
        ROUND(ELAPSED_SECONDS/60,1) ELAPSED_MIN
 FROM V\$RMAN_BACKUP_JOB_DETAILS
 WHERE START_TIME>SYSDATE-7
 ORDER BY START_TIME DESC FETCH FIRST 15 ROWS ONLY;")
    printf "%s\n" "${RMAN_OUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${RMAN_OUT}"

    FAIL_BK=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$RMAN_BACKUP_JOB_DETAILS
 WHERE STATUS NOT IN ('COMPLETED','COMPLETED WITH WARNINGS')
   AND START_TIME>SYSDATE-7;")
    LAST_FULL=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT TO_CHAR(MAX(END_TIME),'YYYY-MM-DD HH24:MI') FROM V\$RMAN_BACKUP_JOB_DETAILS
 WHERE INPUT_TYPE LIKE 'DB FULL%' AND STATUS='COMPLETED';" | tr -d '\n')
    log "  Last full backup: ${LAST_FULL:-NONE}"
    if [ "${FAIL_BK:-0}" -gt 0 ]; then
        print_result FAIL "${FAIL_BK} failed RMAN job(s) in last 7 days"
        [ "${OPT_HTML}" -eq 1 ] && html_result FAIL "${FAIL_BK} failed RMAN job(s) in last 7 days"
    else
        print_result PASS "No failed RMAN jobs in last 7 days"
        [ "${OPT_HTML}" -eq 1 ] && html_result PASS "No failed RMAN jobs in last 7 days (last full: ${LAST_FULL:-N/A})"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S6 — ALERT LOG
    # -----------------------------------------------------------------------
    print_header "6. ALERT LOG (last 5000 lines)"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "6. Alert Log Errors" "s6_${ORACLE_SID}"

    DIAG_DEST=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT VALUE FROM V\$DIAG_INFO WHERE NAME='Diag Trace';")
    ALERT_LOG="${DIAG_DEST}/alert_${ORACLE_SID}.log"
    log "  Alert log: ${ALERT_LOG}"

    if [ -f "${ALERT_LOG}" ]; then
        ORA_CNT=$(tail -5000 "${ALERT_LOG}" 2>/dev/null | grep -c "ORA-" || true)
        log "  ORA- error count (last 5000 lines): ${ORA_CNT}"
        AL_ERRORS=$(tail -5000 "${ALERT_LOG}" 2>/dev/null \
            | grep -i "ORA-\|FATAL" | grep -v "^$" | head -30)
        if [ -n "${AL_ERRORS}" ]; then
            print_result WARN "${ORA_CNT} ORA- error(s) in alert log"
            printf "%s\n" "${AL_ERRORS}" >> "${LOG_FILE}"
            [ "${OPT_HTML}" -eq 1 ] && html_result WARN "${ORA_CNT} ORA- error(s) found in alert log"
            [ "${OPT_HTML}" -eq 1 ] && html_pre "${AL_ERRORS}"
        else
            print_result PASS "No ORA-/FATAL errors in last 5000 lines"
            [ "${OPT_HTML}" -eq 1 ] && html_result PASS "No ORA-/FATAL errors in last 5000 lines"
        fi
    else
        print_result WARN "Alert log not accessible: ${ALERT_LOG}"
        [ "${OPT_HTML}" -eq 1 ] && html_result WARN "Alert log not accessible: ${ALERT_LOG}"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S7 — INVALID OBJECTS
    # -----------------------------------------------------------------------
    print_header "7. INVALID OBJECTS"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "7. Invalid Objects" "s7_${ORACLE_SID}"

    INVALID_CNT=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT COUNT(*) FROM DBA_OBJECTS WHERE STATUS='INVALID';")
    if [ "${INVALID_CNT:-0}" -gt 0 ]; then
        print_result WARN "${INVALID_CNT} invalid object(s)"
        [ "${OPT_HTML}" -eq 1 ] && html_result WARN "${INVALID_CNT} invalid object(s)"
        INV_OUT=$(sql_table_str "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL OWNER       FORMAT A20
 COL OBJECT_NAME FORMAT A35
 COL OBJECT_TYPE FORMAT A20" \
"SELECT OWNER,OBJECT_NAME,OBJECT_TYPE
 FROM DBA_OBJECTS WHERE STATUS='INVALID'
 ORDER BY OWNER,OBJECT_TYPE,OBJECT_NAME FETCH FIRST 30 ROWS ONLY;")
        printf "%s\n" "${INV_OUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${INV_OUT}"
    else
        print_result PASS "No invalid objects"
        [ "${OPT_HTML}" -eq 1 ] && html_result PASS "No invalid objects"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S8 — SESSIONS & BLOCKING
    # -----------------------------------------------------------------------
    print_header "8. SESSIONS & BLOCKING"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "8. Sessions & Blocking" "s8_${ORACLE_SID}"

    BLOCKED=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT COUNT(*) FROM V\$SESSION WHERE BLOCKING_SESSION IS NOT NULL;")
    if [ "${BLOCKED:-0}" -gt 0 ]; then
        print_result WARN "${BLOCKED} blocked session(s)"
        [ "${OPT_HTML}" -eq 1 ] && html_result WARN "${BLOCKED} blocked session(s)"
        BLK_OUT=$(sql_table_str "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL SID          FORMAT 9999
 COL USERNAME     FORMAT A15
 COL BLOCKING_SID FORMAT 9999
 COL EVENT        FORMAT A30
 COL WAIT_MIN     FORMAT 999.9" \
"SELECT s.SID,s.USERNAME,s.BLOCKING_SESSION BLOCKING_SID,
        s.EVENT,ROUND(s.SECONDS_IN_WAIT/60,1) WAIT_MIN
 FROM V\$SESSION s WHERE s.BLOCKING_SESSION IS NOT NULL
 ORDER BY s.SECONDS_IN_WAIT DESC;")
        printf "%s\n" "${BLK_OUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${BLK_OUT}"
    else
        print_result PASS "No blocked sessions"
        [ "${OPT_HTML}" -eq 1 ] && html_result PASS "No blocked sessions"
    fi

    LR_CNT=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$SESSION_LONGOPS
 WHERE TIME_REMAINING>0 AND ELAPSED_SECONDS>300;")
    if [ "${LR_CNT:-0}" -gt 0 ]; then
        print_result WARN "${LR_CNT} long-running operation(s) >5 min"
        [ "${OPT_HTML}" -eq 1 ] && html_result WARN "${LR_CNT} long-running operation(s) >5 min"
    else
        print_result PASS "No long-running operations (>5 min)"
        [ "${OPT_HTML}" -eq 1 ] && html_result PASS "No long-running operations (>5 min)"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S9 — SGA & MEMORY
    # -----------------------------------------------------------------------
    print_header "9. SGA / MEMORY"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "9. SGA / Memory" "s9_${ORACLE_SID}"

    SGA_SIZE=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT ROUND(SUM(VALUE)/1024/1024,0)||' MB' FROM V\$SGA;" | tr -d '\n')
    PGA_SIZE=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT ROUND(VALUE/1024/1024,0)||' MB' FROM V\$PGASTAT WHERE NAME='maximum PGA allocated';" | tr -d '\n')
    log "  Total SGA: ${SGA_SIZE}   Max PGA: ${PGA_SIZE}"
    [ "${OPT_HTML}" -eq 1 ] && html_result INFO "Total SGA: ${SGA_SIZE} | Max PGA: ${PGA_SIZE}"

    BHR=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT ROUND((1-(p.VALUE/NULLIF(b.VALUE+c.VALUE+p.VALUE,0)))*100,2)
 FROM V\$SYSSTAT p,V\$SYSSTAT b,V\$SYSSTAT c
 WHERE p.NAME='physical reads'
   AND b.NAME='db block gets'
   AND c.NAME='consistent gets';")
    log "  Buffer Cache Hit Ratio: ${BHR}%"
    BHR_OK=$(awk -v v="${BHR:-0}" 'BEGIN{print(v+0>=90)?1:0}')
    if [ "${BHR_OK}" -eq 1 ]; then
        print_result PASS "Buffer Cache Hit Ratio: ${BHR}%"
        [ "${OPT_HTML}" -eq 1 ] && html_result PASS "Buffer Cache Hit Ratio: ${BHR}% (>=90%)"
    else
        print_result WARN "Buffer Cache Hit Ratio: ${BHR}% (below 90%)"
        [ "${OPT_HTML}" -eq 1 ] && html_result WARN "Buffer Cache Hit Ratio: ${BHR}% (below 90%)"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S10 — TOP WAIT EVENTS
    # -----------------------------------------------------------------------
    print_header "10. TOP WAIT EVENTS"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "10. Top Wait Events" "s10_${ORACLE_SID}"
    WAIT_OUT=$(sql_table_str "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL EVENT         FORMAT A38
 COL TOTAL_WAITS   FORMAT 9999999999
 COL TIME_WAITED_S FORMAT 999999.99
 COL AVG_WAIT_MS   FORMAT 99999.99" \
"SELECT EVENT,TOTAL_WAITS,
        ROUND(TIME_WAITED_MICRO/1000000,2) TIME_WAITED_S,
        ROUND(AVERAGE_WAIT_MICRO/1000,2)   AVG_WAIT_MS
 FROM V\$SYSTEM_EVENT
 WHERE WAIT_CLASS!='Idle' AND TOTAL_WAITS>0
 ORDER BY TIME_WAITED_MICRO DESC FETCH FIRST 10 ROWS ONLY;")
    printf "%s\n" "${WAIT_OUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${WAIT_OUT}"
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S11 — DATA GUARD
    # -----------------------------------------------------------------------
    print_header "11. DATA GUARD"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "11. Data Guard" "s11_${ORACLE_SID}"
    DG_CNT=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT COUNT(*) FROM V\$DATAGUARD_CONFIG;" 2>/dev/null)
    if [ "${DG_CNT:-0}" -gt 0 ] 2>/dev/null; then
        DG_OUT=$(sql_table_str "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL DB_UNIQUE_NAME FORMAT A25
 COL ROLE           FORMAT A20
 COL STATUS         FORMAT A15" \
"SELECT DB_UNIQUE_NAME,ROLE,STATUS FROM V\$DATAGUARD_CONFIG;")
        printf "%s\n" "${DG_OUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${DG_OUT}"
        MRP=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
            "SELECT STATUS FROM V\$MANAGED_STANDBY WHERE PROCESS='MRP0';")
        LAG=$(run_sql "${ORACLE_SID}" "${ORACLE_HOME}" \
            "SELECT VALUE FROM V\$DATAGUARD_STATS WHERE NAME='apply lag';" | tr -d '\n')
        [ -n "${MRP}" ] && log "  MRP0: ${MRP}" && [ "${OPT_HTML}" -eq 1 ] && html_result INFO "MRP0 Status: ${MRP}"
        [ -n "${LAG}" ] && log "  Apply Lag: ${LAG}" && [ "${OPT_HTML}" -eq 1 ] && html_result INFO "Apply Lag: ${LAG}"
        print_result PASS "Data Guard configured"
        [ "${OPT_HTML}" -eq 1 ] && html_result PASS "Data Guard configured"
    else
        print_result INFO "Data Guard not configured"
        [ "${OPT_HTML}" -eq 1 ] && html_result INFO "Data Guard not configured"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S12 — USER ACCOUNTS
    # -----------------------------------------------------------------------
    print_header "12. USER ACCOUNT STATUS"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "12. User Accounts" "s12_${ORACLE_SID}"
    LOCKED_CNT=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_USERS
 WHERE ACCOUNT_STATUS LIKE '%LOCKED%'
   AND USERNAME NOT IN ('SYS','SYSTEM','DBSNMP','OUTLN','ORACLE_OCM',
       'ANONYMOUS','XDB','XS\$NULL','GSMADMIN_INTERNAL','AUDSYS',
       'GSMCATUSER','GSMROOTUSER','DBSFWUSER','SYSBACKUP',
       'SYSDG','SYSKM','SYSRAC','APPQOSSYS','OJVMSYS');")
    EXPIRED_CNT=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT COUNT(*) FROM DBA_USERS WHERE ACCOUNT_STATUS='EXPIRED';")
    [ "${LOCKED_CNT:-0}"  -gt 0 ] && print_result WARN "${LOCKED_CNT} non-system user(s) locked" \
        && [ "${OPT_HTML}" -eq 1 ] && html_result WARN "${LOCKED_CNT} non-system user(s) locked"
    [ "${EXPIRED_CNT:-0}" -gt 0 ] && print_result WARN "${EXPIRED_CNT} user account(s) expired" \
        && [ "${OPT_HTML}" -eq 1 ] && html_result WARN "${EXPIRED_CNT} user account(s) expired"
    [ "${LOCKED_CNT:-0}" -eq 0 ] && [ "${EXPIRED_CNT:-0}" -eq 0 ] \
        && print_result PASS "All non-system accounts in normal status" \
        && [ "${OPT_HTML}" -eq 1 ] && html_result PASS "All non-system accounts in normal status"
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S13 — SCHEDULER FAILED JOBS
    # -----------------------------------------------------------------------
    print_header "13. SCHEDULER FAILED JOBS (7 days)"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "13. Scheduler Jobs" "s13_${ORACLE_SID}"
    SCHED_FAIL=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_SCHEDULER_JOB_RUN_DETAILS
 WHERE STATUS='FAILED' AND ACTUAL_START_DATE>SYSTIMESTAMP-7;")
    if [ "${SCHED_FAIL:-0}" -gt 0 ]; then
        print_result WARN "${SCHED_FAIL} failed scheduler job(s)"
        [ "${OPT_HTML}" -eq 1 ] && html_result WARN "${SCHED_FAIL} failed scheduler job(s) in last 7 days"
        SCH_OUT=$(sql_table_str "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL OWNER    FORMAT A15
 COL JOB_NAME FORMAT A30
 COL STATUS   FORMAT A10" \
"SELECT OWNER,JOB_NAME,STATUS
 FROM DBA_SCHEDULER_JOB_RUN_DETAILS
 WHERE STATUS='FAILED' AND ACTUAL_START_DATE>SYSTIMESTAMP-7
 ORDER BY ACTUAL_START_DATE DESC FETCH FIRST 10 ROWS ONLY;")
        printf "%s\n" "${SCH_OUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${SCH_OUT}"
    else
        print_result PASS "No failed scheduler jobs in last 7 days"
        [ "${OPT_HTML}" -eq 1 ] && html_result PASS "No failed scheduler jobs in last 7 days"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S14 — ASM DISK GROUPS
    # -----------------------------------------------------------------------
    print_header "14. ASM DISK GROUPS"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "14. ASM Disk Groups" "s14_${ORACLE_SID}"
    ASM_CNT=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT COUNT(*) FROM V\$ASM_DISKGROUP;" 2>/dev/null)
    if [ "${ASM_CNT:-0}" -gt 0 ] 2>/dev/null; then
        ASM_OUT=$(sql_table_str "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL NAME     FORMAT A20
 COL STATE    FORMAT A12
 COL TYPE     FORMAT A8
 COL TOTAL_GB FORMAT 99999.9
 COL FREE_GB  FORMAT 99999.9
 COL PCT_USED FORMAT 999.1" \
"SELECT NAME,STATE,TYPE,
        ROUND(TOTAL_MB/1024,1) TOTAL_GB,
        ROUND(FREE_MB/1024,1)  FREE_GB,
        ROUND((1-FREE_MB/NULLIF(TOTAL_MB,0))*100,1) PCT_USED
 FROM V\$ASM_DISKGROUP ORDER BY NAME;")
        printf "%s\n" "${ASM_OUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${ASM_OUT}"
        ASM_CRIT=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$ASM_DISKGROUP
 WHERE ROUND((1-FREE_MB/NULLIF(TOTAL_MB,0))*100,1)>=85;")
        if [ "${ASM_CRIT:-0}" -gt 0 ]; then
            print_result FAIL "${ASM_CRIT} ASM disk group(s) >= 85% full"
            [ "${OPT_HTML}" -eq 1 ] && html_result FAIL "${ASM_CRIT} ASM disk group(s) >= 85% full"
        else
            print_result PASS "ASM disk groups within acceptable usage"
            [ "${OPT_HTML}" -eq 1 ] && html_result PASS "ASM disk groups within acceptable usage"
        fi
    else
        print_result INFO "ASM not accessible from this instance"
        [ "${OPT_HTML}" -eq 1 ] && html_result INFO "ASM not accessible from this instance"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S15 — PATCH LEVEL  (validated queries for Oracle 19c)
    # -----------------------------------------------------------------------
    print_header "15. PATCH LEVEL"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "15. Patch Level" "s15_${ORACLE_SID}"

    # DBA_REGISTRY_SQLPATCH — available 12.2+; reliable on 19c
    PATCH_OUT=$(sql_table_str "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL PATCH_ID     FORMAT 9999999999
 COL VERSION      FORMAT A14
 COL ACTION       FORMAT A10
 COL STATUS       FORMAT A12
 COL APPLIED_TIME FORMAT A18
 COL DESCRIPTION  FORMAT A50" \
"SELECT PATCH_ID,
        TO_CHAR(VERSION) VERSION,
        ACTION,
        STATUS,
        TO_CHAR(ACTION_TIME,'YYYY-MM-DD HH24:MI') APPLIED_TIME,
        SUBSTR(DESCRIPTION,1,50) DESCRIPTION
 FROM DBA_REGISTRY_SQLPATCH
 ORDER BY ACTION_TIME DESC
 FETCH FIRST 5 ROWS ONLY;")

    if printf '%s' "${PATCH_OUT}" | grep -qi "no rows\|ORA-"; then
        # Fallback: V$VERSION + V$PATCH_INFO (available without needing OPATCH catalog)
        log "  DBA_REGISTRY_SQLPATCH returned no rows — falling back to V\$VERSION"
        VER_OUT=$(sql_table_str "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL BANNER_FULL FORMAT A80" \
"SELECT BANNER_FULL FROM V\$VERSION WHERE ROWNUM=1;")
        printf "%s\n" "${VER_OUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${VER_OUT}"
        print_result INFO "Patch registry empty — check opatch lsinventory on OS"
        [ "${OPT_HTML}" -eq 1 ] && html_result INFO "Patch registry empty — run opatch lsinventory for full detail"
    else
        printf "%s\n" "${PATCH_OUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${PATCH_OUT}"

        # Check if latest patch is FAILED
        PATCH_FAIL=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_REGISTRY_SQLPATCH
 WHERE STATUS NOT IN ('SUCCESS','WITH ERRORS')
   AND ACTION_TIME=(SELECT MAX(ACTION_TIME) FROM DBA_REGISTRY_SQLPATCH);")
        if [ "${PATCH_FAIL:-0}" -gt 0 ]; then
            print_result FAIL "Latest patch has non-SUCCESS status"
            [ "${OPT_HTML}" -eq 1 ] && html_result FAIL "Latest patch has non-SUCCESS status"
        else
            print_result PASS "Patch registry looks healthy"
            [ "${OPT_HTML}" -eq 1 ] && html_result PASS "Patch registry looks healthy"
        fi
    fi

    # Also show component registry (DBA_REGISTRY)
    COMP_OUT=$(sql_table_str "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL COMP_NAME FORMAT A40
 COL VERSION   FORMAT A15
 COL STATUS    FORMAT A12" \
"SELECT COMP_NAME,VERSION,STATUS FROM DBA_REGISTRY ORDER BY COMP_NAME;")
    printf "%s\n" "${COMP_OUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${COMP_OUT}"

    COMP_FAIL=$(sql_val "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_REGISTRY WHERE STATUS NOT IN ('VALID','OPTION OFF');")
    if [ "${COMP_FAIL:-0}" -gt 0 ]; then
        print_result FAIL "${COMP_FAIL} DB component(s) not VALID in DBA_REGISTRY"
        [ "${OPT_HTML}" -eq 1 ] && html_result FAIL "${COMP_FAIL} DB component(s) not VALID"
    else
        print_result PASS "All DB components VALID in DBA_REGISTRY"
        [ "${OPT_HTML}" -eq 1 ] && html_result PASS "All DB components VALID in DBA_REGISTRY"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # S16 — TOP SQL PERFORMANCE
    # -----------------------------------------------------------------------
    print_header "16. TOP SQL (Elapsed Time)"
    [ "${OPT_HTML}" -eq 1 ] && html_section_start "16. Top SQL Performance" "s16_${ORACLE_SID}"
    SQL_OUT=$(sql_table_str "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL SQL_ID       FORMAT A15
 COL ELAPSED_S    FORMAT 9999999.9
 COL EXECUTIONS   FORMAT 9999999
 COL AVG_ELAP_S   FORMAT 9999.9
 COL SQL_TEXT     FORMAT A60" \
"SELECT SQL_ID,
        ROUND(ELAPSED_TIME/1000000,1)                    ELAPSED_S,
        EXECUTIONS,
        ROUND(ELAPSED_TIME/NULLIF(EXECUTIONS,0)/1000000,2) AVG_ELAP_S,
        SUBSTR(SQL_TEXT,1,60)                            SQL_TEXT
 FROM V\$SQLAREA WHERE ELAPSED_TIME>0
 ORDER BY ELAPSED_TIME DESC FETCH FIRST 10 ROWS ONLY;")
    printf "%s\n" "${SQL_OUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${SQL_OUT}"
    [ "${OPT_HTML}" -eq 1 ] && html_section_end

    # -----------------------------------------------------------------------
    # PER-DB SUMMARY
    # -----------------------------------------------------------------------
    _TOTAL_CHECKS=$((ISSUES + WARNINGS))
    _ALL=$((ISSUES + WARNINGS + 1))  # rough denominator
    PCT_PASS_DB=0; PCT_FAIL_DB=0; PCT_WARN_DB=0
    if [ "${_ALL}" -gt 0 ]; then
        PCT_FAIL_DB=$(awk -v f="${ISSUES}"   -v t="${_ALL}" 'BEGIN{printf "%.0f",f/t*100}')
        PCT_WARN_DB=$(awk -v w="${WARNINGS}" -v t="${_ALL}" 'BEGIN{printf "%.0f",w/t*100}')
        PCT_PASS_DB=$((100 - PCT_FAIL_DB - PCT_WARN_DB))
        [ "${PCT_PASS_DB}" -lt 0 ] && PCT_PASS_DB=0
    fi

    print_header "SUMMARY — ${ORACLE_SID}"
    log ""
    log "  Critical Issues  (FAIL) : ${ISSUES}"
    log "  Warnings         (WARN) : ${WARNINGS}"
    log "  Log file         : ${LOG_FILE}"
    log ""

    if [ "${ISSUES}" -gt 0 ]; then
        print_result FAIL "${ORACLE_SID} — ${ISSUES} CRITICAL, ${WARNINGS} warnings"
    elif [ "${WARNINGS}" -gt 0 ]; then
        print_result WARN "${ORACLE_SID} — ${WARNINGS} warnings"
    else
        print_result PASS "${ORACLE_SID} — All checks PASSED"
    fi

    # Console quick bar
    printf "\n  ${CB}Health:${CZ}  ${CG}PASS %d%%${CZ}  ${CY}WARN %d%%${CZ}  ${CR}FAIL %d%%${CZ}\n\n" \
        "${PCT_PASS_DB}" "${PCT_WARN_DB}" "${PCT_FAIL_DB}"

    # HTML: close panel
    [ "${OPT_HTML}" -eq 1 ] && html_db_panel_end

    # Return counters to caller via files (subshell-safe)
    printf "%d" "${ISSUES}"   > "${LOG_DIR}/.hc_issues_${ORACLE_SID}"
    printf "%d" "${WARNINGS}" > "${LOG_DIR}/.hc_warnings_${ORACLE_SID}"
    printf "%s" "${LOG_FILE}"  > "${LOG_DIR}/.hc_logfile_${ORACLE_SID}"
}

# ===========================================================================
# SEND EMAIL
# ===========================================================================
send_email() {
    _TO="$1"; _SUBJECT="$2"; _ATTACH="$3"
    # Try mutt first (supports HTML attachment), then mailx
    if command -v mutt >/dev/null 2>&1; then
        echo "Oracle 19c Health Check Report — see attached HTML." \
            | mutt -s "${_SUBJECT}" -a "${_ATTACH}" -- "${_TO}"
        return $?
    elif command -v mailx >/dev/null 2>&1; then
        # mailx: inline the HTML (many servers accept it)
        mailx -s "${_SUBJECT}" \
            -a "Content-Type: text/html" \
            "${_TO}" < "${_ATTACH}"
        return $?
    elif command -v sendmail >/dev/null 2>&1; then
        {
        printf "To: %s\n" "${_TO}"
        printf "Subject: %s\n" "${_SUBJECT}"
        printf "MIME-Version: 1.0\n"
        printf "Content-Type: text/html; charset=UTF-8\n\n"
        cat "${_ATTACH}"
        } | sendmail -t
        return $?
    else
        printf "  [WARN]  No mail client found (mutt/mailx/sendmail). Email not sent.\n"
        return 1
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================
ensure_log_dir
locate_oratab

# Determine SID list
if [ -n "${OPT_SID}" ]; then
    # Single SID specified via -s
    SID_LIST="${OPT_SID}"
else
    SID_LIST=$(discover_sids)
fi

if [ -z "${SID_LIST}" ]; then
    printf "${CR}ERROR: No eligible Oracle instances found.\n${CZ}"
    printf "  Excluded: +ASM*, *APX*, *MGMT*\n"
    printf "  Use -s SID to specify a SID manually.\n"
    exit 1
fi

# Collect SID metadata for HTML (need counts before writing scorecards)
DB_COUNT=$(printf '%s\n' "${SID_LIST}" | grep -c '[^[:space:]]')
printf '%s\n' "${SID_LIST}" | while IFS= read -r S; do
    OH=$(get_oracle_home "${S}")
    printf "%s:%s\n" "${S}" "${OH:-UNKNOWN}"
done > "${LOG_DIR}/.hc_sidmap_${MASTER_TIMESTAMP}"

# Console master banner
printf "\n${CB}${CC}"
printf "╔══════════════════════════════════════════════════════════════════╗\n"
printf "║    Oracle 19c Multi-Instance Health Check                       ║\n"
printf "║    Host    : %-52s║\n" "$(uname -n)"
printf "║    OS      : %-52s║\n" "$(uname -s) $(uname -r)"
printf "║    oratab  : %-52s║\n" "${ORATAB}"
printf "║    LogDir  : %-52s║\n" "${LOG_DIR}"
printf "║    HTML    : %-52s║\n" "$([ ${OPT_HTML} -eq 1 ] && echo YES || echo NO)"
printf "║    Email   : %-52s║\n" "${OPT_EMAIL:-none}"
printf "╚══════════════════════════════════════════════════════════════════╝\n"
printf "${CZ}\n"
printf "${CB}  Instances to check (${DB_COUNT}):${CZ}\n"
printf '%s\n' "${SID_LIST}" | while IFS= read -r S; do
    OH=$(get_oracle_home "${S}")
    printf "    ${CC}► %-15s${CZ}  %s\n" "${S}" "${OH:-NOT IN ORATAB}"
done
printf "\n"

# HTML init
if [ "${OPT_HTML}" -eq 1 ]; then
    html_init
    html_header "$(uname -n)" "$(date '+%Y-%m-%d %H:%M:%S')" "${ORATAB}" "$(uname -s) $(uname -r)"
fi

# Run health checks — collect results
_FIRST_DB=1
printf '%s\n' "${SID_LIST}" | while IFS= read -r SID; do
    [ -z "${SID}" ] && continue
    OH=$(get_oracle_home "${SID}")
    if [ -z "${OH}" ]; then
        printf "${CY}  [WARN]${CZ}  SID '%s' not in oratab — skipping\n" "${SID}"
        continue
    fi
    if [ ! -d "${OH}" ]; then
        printf "${CR}  [FAIL]${CZ}  ORACLE_HOME '%s' does not exist — skipping %s\n" "${OH}" "${SID}"
        continue
    fi
    run_healthcheck "${SID}" "${OH}" "${_FIRST_DB}"
    _FIRST_DB=0
done

# Accumulate master totals from temp files
MASTER_ISSUES=0; MASTER_WARNINGS=0; MASTER_PASS=0; MASTER_DB_COUNT=0
for _TF in "${LOG_DIR}"/.hc_issues_*; do
    [ -f "${_TF}" ] || continue
    _V=$(cat "${_TF}"); MASTER_ISSUES=$((MASTER_ISSUES+_V))
    _SID_TMP=$(printf '%s' "${_TF}" | sed 's/.*\.hc_issues_//')
    _WF="${LOG_DIR}/.hc_warnings_${_SID_TMP}"
    _W=0; [ -f "${_WF}" ] && _W=$(cat "${_WF}")
    MASTER_WARNINGS=$((MASTER_WARNINGS+_W))
    [ "${_V}" -eq 0 ] && [ "${_W}" -eq 0 ] && MASTER_PASS=$((MASTER_PASS+1))
    MASTER_DB_COUNT=$((MASTER_DB_COUNT+1))
done

# HTML: scorecards + summary grid + tabs
if [ "${OPT_HTML}" -eq 1 ]; then
    html_scorecards "${MASTER_DB_COUNT}" "${MASTER_PASS}" "${MASTER_WARNINGS}" "${MASTER_ISSUES}"

    html_summary_grid_start
    _FDB=1
    printf '%s\n' "${SID_LIST}" | while IFS= read -r SID; do
        [ -z "${SID}" ] && continue
        OH=$(get_oracle_home "${SID}")
        [ -z "${OH}" ] && continue
        _IF="${LOG_DIR}/.hc_issues_${SID}";   _F=0; [ -f "${_IF}" ] && _F=$(cat "${_IF}")
        _WF="${LOG_DIR}/.hc_warnings_${SID}"; _W=0; [ -f "${_WF}" ] && _W=$(cat "${_WF}")
        html_summary_card "${SID}" "${_F}" "${_W}" "${OH}"
        _FDB=0
    done
    html_summary_grid_end

    html_tabs_start
    _FDB=1
    printf '%s\n' "${SID_LIST}" | while IFS= read -r SID; do
        [ -z "${SID}" ] && continue
        OH=$(get_oracle_home "${SID}"); [ -z "${OH}" ] && continue
        _IF="${LOG_DIR}/.hc_issues_${SID}";   _F=0; [ -f "${_IF}" ] && _F=$(cat "${_IF}")
        _WF="${LOG_DIR}/.hc_warnings_${SID}"; _W=0; [ -f "${_WF}" ] && _W=$(cat "${_WF}")
        html_tab_btn "${SID}" "${_F}" "${_W}" "${_FDB}"
        _FDB=0
    done
    html_tabs_end
    html_footer
fi

# Clean temp files
rm -f "${LOG_DIR}"/.hc_issues_* "${LOG_DIR}"/.hc_warnings_* \
      "${LOG_DIR}"/.hc_logfile_* "${LOG_DIR}"/.hc_sidmap_* 2>/dev/null

# -------------------------------------------------------------------------
# MASTER SUMMARY — console
# -------------------------------------------------------------------------
PCT_PASS_M=0
[ "${MASTER_DB_COUNT}" -gt 0 ] && \
    PCT_PASS_M=$(awk -v p="${MASTER_PASS}" -v t="${MASTER_DB_COUNT}" \
        'BEGIN{printf "%.0f",p/t*100}')
PCT_FAIL_M=0
[ "${MASTER_DB_COUNT}" -gt 0 ] && \
    PCT_FAIL_M=$(awk -v f="${MASTER_ISSUES}" -v t="${MASTER_DB_COUNT}" \
        'BEGIN{printf "%.0f",f/t*100}')

printf "\n${CB}${CC}"
printf "╔══════════════════════════════════════════════════════════════════╗\n"
printf "║                   MASTER RUN SUMMARY                            ║\n"
printf "╚══════════════════════════════════════════════════════════════════╝${CZ}\n"
printf "\n"
printf "  %-25s : %s\n"  "Host"               "$(uname -n)"
printf "  %-25s : %s\n"  "Completed"          "$(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-25s : %d\n"  "Databases Checked"  "${MASTER_DB_COUNT}"
printf "  %-25s : %s%%\n" "DB Pass Rate"      "${PCT_PASS_M}"
printf "  %-25s : %d\n"  "Total CRITICAL"     "${MASTER_ISSUES}"
printf "  %-25s : %d\n"  "Total WARNINGS"     "${MASTER_WARNINGS}"

if [ "${OPT_HTML}" -eq 1 ]; then
    printf "  %-25s : %s\n" "HTML Report" "${HTML_REPORT}"
fi
printf "  %-25s : %s\n" "Master Log" "${MASTER_LOG}"
printf "\n"

# Per-DB quick summary table
printf "  ${CB}%-15s %-8s %-8s %-8s %s${CZ}\n" "SID" "FAIL" "WARN" "RESULT" "LOG"
printf "  %s\n" "---------------------------------------------------------------------"
printf '%s\n' "${SID_LIST}" | while IFS= read -r SID; do
    [ -z "${SID}" ] && continue
    OH=$(get_oracle_home "${SID}"); [ -z "${OH}" ] && continue
    _F=0; _W=0
    [ -f "${LOG_DIR}/.hc_issues_${SID}"   ] && _F=$(cat "${LOG_DIR}/.hc_issues_${SID}")   2>/dev/null
    [ -f "${LOG_DIR}/.hc_warnings_${SID}" ] && _W=$(cat "${LOG_DIR}/.hc_warnings_${SID}") 2>/dev/null
    if   [ "${_F:-0}" -gt 0 ]; then _RES="${CR}CRITICAL${CZ}"
    elif [ "${_W:-0}" -gt 0 ]; then _RES="${CY}WARNING${CZ}"
    else                            _RES="${CG}PASS${CZ}"
    fi
    printf "  %-15s %-8s %-8s %b\n" "${SID}" "${_F:-0}" "${_W:-0}" "${_RES}"
done

printf "\n"
if [ "${MASTER_ISSUES}" -gt 0 ]; then
    printf "  ${CR}${CB}[CRITICAL]${CZ}  ${MASTER_ISSUES} critical issue(s) across ${MASTER_DB_COUNT} database(s)\n"
elif [ "${MASTER_WARNINGS}" -gt 0 ]; then
    printf "  ${CY}${CB}[WARNING]${CZ}   ${MASTER_WARNINGS} warning(s) — review recommended\n"
else
    printf "  ${CG}${CB}[ALL PASS]${CZ}  All ${MASTER_DB_COUNT} database(s) passed health check\n"
fi

# -------------------------------------------------------------------------
# EMAIL
# -------------------------------------------------------------------------
if [ -n "${OPT_EMAIL}" ] && [ "${OPT_HTML}" -eq 1 ] && [ -f "${HTML_REPORT}" ]; then
    printf "\n  Sending HTML report to %s ...\n" "${OPT_EMAIL}"
    _SUBJ="Oracle DB Health Check — $(uname -n) — $(date '+%Y-%m-%d') — "
    if [ "${MASTER_ISSUES}" -gt 0 ]; then
        _SUBJ="${_SUBJ}CRITICAL: ${MASTER_ISSUES} issue(s)"
    elif [ "${MASTER_WARNINGS}" -gt 0 ]; then
        _SUBJ="${_SUBJ}WARNING: ${MASTER_WARNINGS} warning(s)"
    else
        _SUBJ="${_SUBJ}ALL PASS"
    fi
    if send_email "${OPT_EMAIL}" "${_SUBJ}" "${HTML_REPORT}"; then
        printf "  ${CG}Email sent successfully${CZ}\n"
    else
        printf "  ${CY}Email send failed — report saved at: %s${CZ}\n" "${HTML_REPORT}"
    fi
elif [ -n "${OPT_EMAIL}" ] && [ "${OPT_HTML}" -eq 0 ]; then
    printf "\n  ${CY}[WARN]  -e requires -H (HTML report) to be enabled. Use: -H -e %s${CZ}\n" "${OPT_EMAIL}"
fi

printf "\n"
exit ${MASTER_ISSUES}
