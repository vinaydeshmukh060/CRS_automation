#!/bin/sh
# =============================================================================
# Script      : oracle19c_healthcheck.sh
# Purpose     : Comprehensive Oracle 19c Multi-Instance Health Check
#               Linux and Solaris 10/11 compatible (POSIX /bin/sh)
# Version     : 3.0
# =============================================================================
# USAGE:
#   ./oracle19c_healthcheck.sh [OPTIONS]
#
# OPTIONS:
#   -s SID    Check a specific SID only (default: all running instances)
#   -l DIR    Log/report directory (default: /var/log/oracle/healthcheck)
#   -e EMAIL  Email HTML report after run (requires -H)
#   -H        Generate HTML report
#   -h        Show this help and exit
#
# EXAMPLES:
#   ./oracle19c_healthcheck.sh                         # all instances
#   ./oracle19c_healthcheck.sh -s ORCL                 # one instance
#   ./oracle19c_healthcheck.sh -H                      # with HTML report
#   ./oracle19c_healthcheck.sh -H -e dba@company.com   # HTML + email
#   ./oracle19c_healthcheck.sh -s ORCL -H -e dba@co.com
#
# EXCLUSIONS (always skipped):
#   +ASM*  — Grid/ASM   |  *APX* — APEX   |  *MGMT* — EM repository
# =============================================================================

PATH=/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin
export PATH

# ---------------------------------------------------------------------------
# DEFAULTS
# ---------------------------------------------------------------------------
OPT_SID=""; OPT_LOG_DIR="/var/log/oracle/healthcheck"
OPT_EMAIL=""; OPT_HTML=0
DBA_USER="/ as sysdba"

# ---------------------------------------------------------------------------
# HELP
# ---------------------------------------------------------------------------
show_help() {
cat << 'HELP'
Oracle 19c Comprehensive Database Health Check  v3.0
Platforms: Linux, Solaris 10/11 (POSIX /bin/sh)

USAGE:
  ./oracle19c_healthcheck.sh [OPTIONS]

OPTIONS:
  -s SID    Target a specific SID only
  -l DIR    Output directory for logs/reports  [/var/log/oracle/healthcheck]
  -e EMAIL  Send HTML report by email (enables -H automatically)
  -H        Generate HTML report
  -h        Show this help and exit

CHECKS PERFORMED (19 categories):
  1.  OS & Environment       10. Top Wait Events
  2.  Instance Status        11. Data Guard Status
  3.  Tablespace Usage       12. ASM Disk Groups
  4.  Temp Tablespace        13. User Account Status
  5.  Redo Log Status        14. Scheduler Failed Jobs
  6.  Archive Log & FRA      15. Patch Level & Components
  7.  RMAN Backup History    16. Top SQL (Elapsed/CPU/IO)
  8.  Alert Log Errors       17. SGA/PGA/Memory Detail
  9.  Invalid Objects        18. Undo & Locking
                             19. Security Checks

EXAMPLES:
  All instances, HTML report + email:
    ./oracle19c_healthcheck.sh -H -e dba@company.com

  Specific instance, custom log dir:
    ./oracle19c_healthcheck.sh -s PROD1 -l /dba/logs -H
HELP
}

# ---------------------------------------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------------------------------------
while getopts "s:l:e:Hh" _O; do
    case "${_O}" in
        s) OPT_SID="${OPTARG}" ;;
        l) OPT_LOG_DIR="${OPTARG}" ;;
        e) OPT_EMAIL="${OPTARG}"; OPT_HTML=1 ;;
        H) OPT_HTML=1 ;;
        h) show_help; exit 0 ;;
        *) show_help; exit 1 ;;
    esac
done

LOG_DIR="${OPT_LOG_DIR}"
MASTER_TS=$(date +"%Y%m%d_%H%M%S")
MASTER_LOG="${LOG_DIR}/hc_master_${MASTER_TS}.log"
HTML_REPORT="${LOG_DIR}/hc_report_${MASTER_TS}.html"

# ---------------------------------------------------------------------------
# COLOURS (terminal only)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    CR='\033[0;31m' CG='\033[0;32m' CY='\033[1;33m'
    CC='\033[0;36m' CM='\033[0;35m' CB='\033[1m'  CZ='\033[0m'
else
    CR='' CG='' CY='' CC='' CM='' CB='' CZ=''
fi
T_PASS="${CG}[PASS]${CZ}"; T_FAIL="${CR}[FAIL]${CZ}"
T_WARN="${CY}[WARN]${CZ}"; T_INFO="${CC}[INFO]${CZ}"

# ---------------------------------------------------------------------------
# ORATAB — Solaris: /var/opt/oracle/oratab  |  Linux: /etc/oratab
# ---------------------------------------------------------------------------
locate_oratab() {
    if   [ -f /var/opt/oracle/oratab ]; then ORATAB=/var/opt/oracle/oratab
    elif [ -f /etc/oratab ];            then ORATAB=/etc/oratab
    else printf "ERROR: oratab not found\n" >&2; exit 1; fi
    export ORATAB
}

get_oracle_home() {
    awk -F: -v sid="$1" '
        /^[[:space:]]*#/  { next }
        /^[[:space:]]*$/  { next }
        $1 == sid { print $2; exit }
    ' "${ORATAB}"
}

# ---------------------------------------------------------------------------
# DISCOVER RUNNING SIDs FROM PMON — exclude ASM / APX / MGMT
# ---------------------------------------------------------------------------
discover_sids() {
    ps -ef 2>/dev/null | grep 'ora_pmon_' | grep -v grep \
    | awk '{for(i=1;i<=NF;i++) if($i~/^ora_pmon_/){sub(/^ora_pmon_/,"",$i);print $i}}' \
    | grep -v '^+ASM' | grep -iv 'APX' | grep -iv 'MGMT' | sort -u
}

# ---------------------------------------------------------------------------
# INFRASTRUCTURE HELPERS
# ---------------------------------------------------------------------------
ensure_log_dir() {
    mkdir -p "${LOG_DIR}" 2>/dev/null || { printf "ERROR: Cannot create log dir: %s\n" "${LOG_DIR}" >&2; exit 1; }
    [ -w "${LOG_DIR}" ] || { printf "ERROR: Log dir not writable: %s\n" "${LOG_DIR}" >&2; exit 1; }
}

log()    { printf "%s\n" "$*" | tee -a "${LOG_FILE}"; }
logsep() { printf "  %s\n" "--------------------------------------------------------------" | tee -a "${LOG_FILE}"; }

print_hdr() {
    L="================================================================"
    printf "\n${CB}${CC}%s\n  %-62s\n%s${CZ}\n" "${L}" "$1" "${L}" | tee -a "${LOG_FILE}"
}

result() {
    _S="$1"; _M="$2"
    case "${_S}" in
        PASS) _T="${T_PASS}" ;;
        FAIL) _T="${T_FAIL}"; ISSUES=$((ISSUES+1)) ;;
        WARN) _T="${T_WARN}"; WARNINGS=$((WARNINGS+1)) ;;
        *)    _T="${T_INFO}" ;;
    esac
    printf "  %b  %s\n" "${_T}" "${_M}" | tee -a "${LOG_FILE}"
    # stash for HTML
    printf "%s|%s\n" "${_S}" "${_M}" >> "${LOG_DIR}/.hc_results_${ORACLE_SID}"
}

# ---------------------------------------------------------------------------
# SQL HELPERS
# ---------------------------------------------------------------------------
# Scalar value — strips all whitespace
sqv() {
    ORACLE_SID="$1" ORACLE_HOME="$2" \
    "$2/bin/sqlplus" -S "${DBA_USER}" 2>/dev/null <<EOF | tr -d ' \t\n\r'
SET PAGESIZE 0 LINESIZE 500 FEEDBACK OFF HEADING OFF TRIMSPOOL ON ECHO OFF
WHENEVER SQLERROR EXIT 1
$3
EXIT;
EOF
}

# Multi-line value — preserves formatting, strips trailing blank lines
sqm() {
    ORACLE_SID="$1" ORACLE_HOME="$2" \
    "$2/bin/sqlplus" -S "${DBA_USER}" 2>/dev/null <<EOF | sed '/^[[:space:]]*$/d'
SET PAGESIZE 200 LINESIZE 220 FEEDBACK OFF TRIMSPOOL ON ECHO OFF
$3
$4
EXIT;
EOF
}

# Tabular: print to stdout AND append to log
sqt() {
    _OUT=$(sqm "$1" "$2" "$3" "$4")
    printf "%s\n" "${_OUT}" | tee -a "${LOG_FILE}"
    printf "%s" "${_OUT}"   # return for capture
}

# ===========================================================================
# HTML ENGINE
# ===========================================================================
H="${HTML_REPORT}"   # shorthand

hi() { printf "%s\n" "$*" >> "${H}"; }   # append raw HTML line

html_init() {
cat > "${H}" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Oracle 19c Health Check</title>
<style>
:root{
  --pass:#1a7f3c;--fail:#c0392b;--warn:#d68910;--info:#1a6fa8;
  --bg:#f0f2f5;--card:#fff;--bdr:#dde3ea;--hdr:#1e3a5f;
}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;background:var(--bg);color:#1a1a2e;font-size:13px}
/* ── TOP HEADER ── */
.page-header{background:linear-gradient(135deg,#1e3a5f 0%,#2e6da4 100%);
  color:#fff;padding:22px 32px 18px}
.page-header h1{font-size:20px;font-weight:700;display:flex;align-items:center;gap:10px}
.page-meta{display:flex;flex-wrap:wrap;gap:20px;margin-top:10px;font-size:11px;opacity:.88}
.page-meta span{display:flex;align-items:center;gap:5px}
/* ── SCORECARD ── */
.scorebar{display:flex;flex-wrap:wrap;gap:14px;padding:18px 28px;
  background:#fff;border-bottom:1px solid var(--bdr)}
.sc{flex:1;min-width:130px;border-radius:10px;padding:14px 16px;text-align:center;
  box-shadow:0 1px 4px rgba(0,0,0,.08)}
.sc.pass{border-top:4px solid var(--pass);background:#f0faf4}
.sc.fail{border-top:4px solid var(--fail);background:#fdf3f2}
.sc.warn{border-top:4px solid var(--warn);background:#fdf8ee}
.sc.info{border-top:4px solid var(--info);background:#eef5fd}
.sc .n{font-size:34px;font-weight:800;line-height:1}
.sc .l{font-size:10px;text-transform:uppercase;letter-spacing:.6px;margin-top:3px;opacity:.65}
.sc.pass .n{color:var(--pass)} .sc.fail .n{color:var(--fail)}
.sc.warn .n{color:var(--warn)} .sc.info .n{color:var(--info)}
/* ── HEALTH BAR ── */
.hbar-wrap{padding:14px 28px;background:#fff;border-bottom:1px solid var(--bdr)}
.hbar-wrap h4{font-size:11px;text-transform:uppercase;letter-spacing:.5px;
  color:#666;margin-bottom:8px}
.hbar{display:flex;height:20px;border-radius:6px;overflow:hidden}
.hbar .seg{display:flex;align-items:center;justify-content:center;
  font-size:10px;font-weight:700;color:#fff;min-width:0}
.hbar .seg.pass{background:var(--pass)} .hbar .seg.fail{background:var(--fail)}
.hbar .seg.warn{background:var(--warn)}
.hbar-leg{display:flex;gap:14px;margin-top:6px;font-size:11px}
.hbar-leg span{display:flex;align-items:center;gap:5px}
.dot{width:9px;height:9px;border-radius:50%;display:inline-block}
/* ── DB SUMMARY GRID ── */
.db-grid{display:flex;flex-wrap:wrap;gap:10px;padding:16px 28px;
  background:#fff;border-bottom:1px solid var(--bdr)}
.db-card{border-radius:8px;padding:11px 14px;min-width:180px;
  border-left:4px solid #ccc;background:var(--bg);cursor:pointer;
  transition:box-shadow .15s;user-select:none}
.db-card:hover{box-shadow:0 2px 8px rgba(0,0,0,.12)}
.db-card.pass{border-color:var(--pass)} .db-card.fail{border-color:var(--fail)}
.db-card.warn{border-color:var(--warn)}
.db-card .dc-sid{font-weight:800;font-size:13px}
.db-card .dc-oh{font-size:10px;color:#777;margin:2px 0 5px;word-break:break-all}
.db-card .dc-badges{display:flex;gap:6px}
.dc-b{font-size:10px;font-weight:700;padding:2px 7px;border-radius:3px;color:#fff}
.dc-b.f{background:var(--fail)} .dc-b.w{background:var(--warn)} .dc-b.p{background:var(--pass)}
/* ── TAB BAR (TOP of detail) ── */
.tab-bar{display:flex;flex-wrap:wrap;gap:0;background:#1e3a5f;
  padding:0 28px;border-bottom:3px solid #2e6da4;position:sticky;top:0;z-index:100}
.tab-btn{padding:10px 18px;color:rgba(255,255,255,.7);font-size:12px;font-weight:600;
  border:none;background:none;cursor:pointer;border-bottom:3px solid transparent;
  margin-bottom:-3px;transition:all .15s;white-space:nowrap}
.tab-btn:hover{color:#fff;background:rgba(255,255,255,.08)}
.tab-btn.active{color:#fff;border-bottom-color:#5bb8f5}
.tab-btn .tab-dot{width:7px;height:7px;border-radius:50%;
  display:inline-block;margin-left:6px;vertical-align:middle}
/* ── DB PANELS ── */
.detail-area{padding:20px 28px}
.db-panel{display:none} .db-panel.active{display:block}
/* ── DB INFO BAR ── */
.db-infobar{display:flex;flex-wrap:wrap;gap:10px;background:#fff;
  border-radius:8px;padding:12px 16px;margin-bottom:16px;
  border:1px solid var(--bdr);font-size:11px}
.db-infobar .kv{display:flex;flex-direction:column;min-width:110px}
.db-infobar .kv .k{font-weight:700;font-size:10px;text-transform:uppercase;
  color:#888;margin-bottom:2px}
.db-infobar .kv .v{color:#1a1a2e;word-break:break-all}
/* ── SECTION CARDS ── */
.sec{border:1px solid var(--bdr);border-radius:8px;margin-bottom:12px;overflow:hidden}
.sec-hdr{padding:9px 14px;font-weight:700;font-size:12px;cursor:pointer;
  display:flex;align-items:center;gap:8px;background:#f7f9fc;
  border-bottom:1px solid transparent;user-select:none;transition:background .15s}
.sec-hdr:hover{background:#eef2f8}
.sec-hdr.open{border-bottom-color:var(--bdr);background:#eef2f8}
.sec-hdr .sec-arrow{margin-left:auto;font-size:10px;transition:transform .2s}
.sec-hdr.open .sec-arrow{transform:rotate(90deg)}
.sec-hdr .sec-tag{display:flex;gap:5px;margin-left:8px}
.stag{font-size:9px;font-weight:800;padding:1px 6px;border-radius:3px;color:#fff}
.stag.F{background:var(--fail)} .stag.W{background:var(--warn)} .stag.P{background:var(--pass)}
.sec-body{display:none;padding:12px 16px}
.sec-body.open{display:block}
/* ── RESULT ROWS ── */
.res{display:flex;align-items:flex-start;gap:9px;padding:5px 2px;
  border-bottom:1px solid #f2f2f2;font-size:12px}
.res:last-child{border:none}
.badge{display:inline-flex;align-items:center;justify-content:center;
  padding:2px 7px;border-radius:4px;font-size:9px;font-weight:800;
  min-width:44px;color:#fff;letter-spacing:.3px;white-space:nowrap;flex-shrink:0}
.badge.PASS{background:var(--pass)} .badge.FAIL{background:var(--fail)}
.badge.WARN{background:var(--warn)} .badge.INFO{background:var(--info)}
/* ── PRE / TABLES ── */
pre{font-family:Consolas,'Courier New',monospace;font-size:11px;
  background:#1a1a2e;color:#a8d8a8;padding:12px 14px;border-radius:6px;
  overflow-x:auto;max-height:320px;overflow-y:auto;margin-top:8px;
  white-space:pre;line-height:1.5}
/* ── FOOTER ── */
footer{text-align:center;padding:16px;font-size:11px;color:#999;
  border-top:1px solid var(--bdr);margin-top:20px;background:#fff}
@media(max-width:700px){.scorebar,.db-grid{flex-direction:column}
  .tab-bar{overflow-x:auto} .tab-btn{padding:8px 12px;font-size:11px}}
</style>
</head>
<body>
HTMLEOF
}

html_page_header() {
    hi "<div class='page-header'>"
    hi "  <h1>&#128202; Oracle 19c Database Health Check</h1>"
    hi "  <div class='page-meta'>"
    hi "    <span>&#128197; <b>Generated:</b> $1</span>"
    hi "    <span>&#128421; <b>Host:</b> $2</span>"
    hi "    <span>&#9881; <b>OS:</b> $3</span>"
    hi "    <span>&#128196; <b>oratab:</b> $4</span>"
    [ -n "$5" ] && hi "    <span>&#128231; <b>Emailed to:</b> $5</span>"
    hi "  </div>"
    hi "</div>"
}

html_scorecards() {
    _TOT="$1"; _PASS="$2"; _WARN="$3"; _FAIL="$4"
    _PP=$(awk -v p="${_PASS}" -v t="${_TOT}" 'BEGIN{printf "%.0f",(t>0?p/t*100:0)}')
    _PF=$(awk -v f="${_FAIL}" -v t="${_TOT}" 'BEGIN{printf "%.0f",(t>0?f/t*100:0)}')
    _PW=$(awk -v w="${_WARN}" -v t="${_TOT}" 'BEGIN{printf "%.0f",(t>0?w/t*100:0)}')
    _PR=$((100-_PP-_PF-_PW)); [ "${_PR}" -lt 0 ] && _PR=0
    hi "<div class='scorebar'>"
    hi "  <div class='sc info'><div class='n'>${_TOT}</div><div class='l'>Databases</div></div>"
    hi "  <div class='sc pass'><div class='n'>${_PP}%</div><div class='l'>Pass Rate</div></div>"
    hi "  <div class='sc fail'><div class='n'>${_FAIL}</div><div class='l'>Critical</div></div>"
    hi "  <div class='sc warn'><div class='n'>${_WARN}</div><div class='l'>Warnings</div></div>"
    hi "</div>"
    hi "<div class='hbar-wrap'>"
    hi "  <h4>Overall Health Distribution</h4>"
    hi "  <div class='hbar'>"
    [ "${_PP}" -gt 0 ] && hi "    <div class='seg pass' style='width:${_PP}%'>${_PP}%</div>"
    [ "${_PW}" -gt 0 ] && hi "    <div class='seg warn' style='width:${_PW}%'>${_PW}%</div>"
    [ "${_PF}" -gt 0 ] && hi "    <div class='seg fail' style='width:${_PF}%'>${_PF}%</div>"
    hi "  </div>"
    hi "  <div class='hbar-leg'>"
    hi "    <span><span class='dot' style='background:var(--pass)'></span>Pass ${_PP}%</span>"
    hi "    <span><span class='dot' style='background:var(--warn)'></span>Warning ${_PW}%</span>"
    hi "    <span><span class='dot' style='background:var(--fail)'></span>Critical ${_PF}%</span>"
    hi "  </div>"
    hi "</div>"
}

html_db_grid_start() { hi "<div class='db-grid' id='dbGrid'>"; }
html_db_grid_end()   { hi "</div>"; }

html_db_card() {
    _SID="$1"; _F="$2"; _W="$3"; _OH="$4"
    if   [ "${_F:-0}" -gt 0 ]; then _CLS="fail"
    elif [ "${_W:-0}" -gt 0 ]; then _CLS="warn"
    else                            _CLS="pass"; fi
    hi "<div class='db-card ${_CLS}' onclick=\"showDB('${_SID}')\">"
    hi "  <div class='dc-sid'>${_SID}</div>"
    hi "  <div class='dc-oh'>${_OH}</div>"
    hi "  <div class='dc-badges'>"
    hi "    <span class='dc-b f'>FAIL: ${_F:-0}</span>"
    hi "    <span class='dc-b w'>WARN: ${_W:-0}</span>"
    if [ "${_F:-0}" -eq 0 ] && [ "${_W:-0}" -eq 0 ]; then
        hi "    <span class='dc-b p'>PASS</span>"
    fi
    hi "  </div>"
    hi "</div>"
}

# TAB BAR — sticky at top of detail area
html_tabbar_start() { hi "<div class='tab-bar' id='tabBar'>"; }
html_tab_btn() {
    _SID="$1"; _F="$2"; _W="$3"; _FIRST="$4"
    if   [ "${_F:-0}" -gt 0 ]; then _DC="background:var(--fail)"
    elif [ "${_W:-0}" -gt 0 ]; then _DC="background:var(--warn)"
    else                            _DC="background:var(--pass)"; fi
    _ACT=""; [ "${_FIRST}" = "1" ] && _ACT=" active"
    hi "<button class='tab-btn${_ACT}' onclick=\"showDB('${_SID}')\">${_SID}<span class='tab-dot' style='${_DC}'></span></button>"
}
html_tabbar_end()  { hi "</div>"; }

html_detail_start() { hi "<div class='detail-area' id='detailArea'>"; }
html_detail_end()   { hi "</div>"; }

html_panel_start() {
    _FIRST="$2"; _ACT=""; [ "${_FIRST}" = "1" ] && _ACT=" active"
    hi "<div class='db-panel${_ACT}' id='db_$1'>"
}
html_panel_end() { hi "</div>"; }

html_infobar() {
    hi "<div class='db-infobar'>"
    hi "  <div class='kv'><span class='k'>SID</span><span class='v'>$1</span></div>"
    hi "  <div class='kv'><span class='k'>DB Name</span><span class='v'>$2</span></div>"
    hi "  <div class='kv'><span class='k'>Version</span><span class='v'>$3</span></div>"
    hi "  <div class='kv'><span class='k'>Role</span><span class='v'>$4</span></div>"
    hi "  <div class='kv'><span class='k'>Open Mode</span><span class='v'>$5</span></div>"
    hi "  <div class='kv'><span class='k'>Startup Time</span><span class='v'>$6</span></div>"
    hi "  <div class='kv'><span class='k'>Host</span><span class='v'>$7</span></div>"
    hi "  <div class='kv'><span class='k'>ORACLE_HOME</span><span class='v'>$8</span></div>"
    hi "</div>"
}

html_sec_start() {
    _ID="$1"; _TITLE="$2"
    # scan result stash for this section
    _SF=0; _SW=0
    if [ -f "${LOG_DIR}/.hc_sec_${ORACLE_SID}_${_ID}" ]; then
        while IFS='|' read -r _ST _; do
            case "${_ST}" in FAIL) _SF=$((_SF+1));; WARN) _SW=$((_SW+1));; esac
        done < "${LOG_DIR}/.hc_sec_${ORACLE_SID}_${_ID}"
    fi
    _TAGS=""
    [ "${_SF}" -gt 0 ] && _TAGS="${_TAGS}<span class='stag F'>FAIL ${_SF}</span>"
    [ "${_SW}" -gt 0 ] && _TAGS="${_TAGS}<span class='stag W'>WARN ${_SW}</span>"
    [ "${_SF}" -eq 0 ] && [ "${_SW}" -eq 0 ] && _TAGS="<span class='stag P'>OK</span>"
    hi "<div class='sec'>"
    hi "  <div class='sec-hdr' onclick='toggleSec(this)'>"
    hi "    <span>${_TITLE}</span><span class='sec-tag'>${_TAGS}</span>"
    hi "    <span class='sec-arrow'>&#9658;</span>"
    hi "  </div>"
    hi "  <div class='sec-body'>"
}
html_sec_end() { hi "  </div></div>"; }

html_res() {
    hi "    <div class='res'><span class='badge $1'>$1</span><span>$2</span></div>"
    # Stash for section summary tags
    printf "%s|%s\n" "$1" "$2" >> "${LOG_DIR}/.hc_sec_${ORACLE_SID}_${_CUR_SEC_ID}"
}

html_pre() { hi "    <pre>$1</pre>"; }

html_footer() {
cat >> "${H}" << 'FTEOF'
<footer>Oracle 19c Health Check &mdash; oracle19c_healthcheck.sh v3.0</footer>
<script>
function showDB(sid){
  document.querySelectorAll('.db-panel').forEach(p=>p.classList.remove('active'));
  document.querySelectorAll('.tab-btn').forEach(b=>b.classList.remove('active'));
  var p=document.getElementById('db_'+sid);
  if(p) p.classList.add('active');
  document.querySelectorAll('.tab-btn').forEach(b=>{
    if(b.textContent.trim().startsWith(sid)) b.classList.add('active');
  });
  document.getElementById('detailArea').scrollIntoView({behavior:'smooth'});
}
function toggleSec(hdr){
  hdr.classList.toggle('open');
  var b=hdr.nextElementSibling;
  if(b) b.classList.toggle('open');
}
document.addEventListener('DOMContentLoaded',function(){
  // Auto-open sections that have FAIL
  document.querySelectorAll('.badge.FAIL').forEach(function(b){
    var sb=b.closest('.sec-body');
    if(sb){sb.classList.add('open');sb.previousElementSibling.classList.add('open');}
  });
  // Open first section of active panel
  var ap=document.querySelector('.db-panel.active');
  if(ap){var fh=ap.querySelector('.sec-hdr'),fb=ap.querySelector('.sec-body');
    if(fh)fh.classList.add('open'); if(fb)fb.classList.add('open');}
});
</script>
</body></html>
FTEOF
}

# ===========================================================================
# PER-DATABASE HEALTH CHECK
# ===========================================================================
run_hc() {
    ORACLE_SID="$1"; ORACLE_HOME="$2"; _IS_FIRST="$3"
    export ORACLE_SID ORACLE_HOME
    _TS=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="${LOG_DIR}/hc_${ORACLE_SID}_${_TS}.log"
    ISSUES=0; WARNINGS=0
    # Clear any stale section stash files
    rm -f "${LOG_DIR}"/.hc_sec_${ORACLE_SID}_* 2>/dev/null

    # -- log header --
    { printf "================================================================\n"
      printf "  Oracle 19c HC: %s  |  Home: %s\n" "${ORACLE_SID}" "${ORACLE_HOME}"
      printf "  Host: %s  OS: %s %s\n" "$(uname -n)" "$(uname -s)" "$(uname -r)"
      printf "  Started: %s  oratab: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "${ORATAB}"
      printf "================================================================\n"
    } | tee -a "${LOG_FILE}"

    printf "\n${CB}${CM}══════ SID: %-10s ══════════════════════════════════${CZ}\n\n" "${ORACLE_SID}"

    # ---- Fetch core instance facts ----------------------------------------
    DB_NAME=$(   sqv "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT NAME        FROM V\$DATABASE;")
    DB_VER=$(    sqv "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT VERSION     FROM V\$INSTANCE;")
    DB_ROLE=$(   sqv "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT DATABASE_ROLE FROM V\$DATABASE;")
    DB_STATUS=$( sqv "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT STATUS      FROM V\$INSTANCE;")
    DB_OPENMODE=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT REPLACE(OPEN_MODE,' ','') FROM V\$DATABASE;")
    DB_STARTUP=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT TO_CHAR(STARTUP_TIME,'YYYY-MM-DD HH24:MI:SS') FROM V\$INSTANCE;")
    DB_HOST=$(   sqv "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT HOST_NAME   FROM V\$INSTANCE;")
    DB_ARCH=$(   sqv "${ORACLE_SID}" "${ORACLE_HOME}" "SELECT LOG_MODE    FROM V\$DATABASE;")

    log "  ${DB_NAME} | ${DB_VER} | ${DB_ROLE} | ${DB_OPENMODE} | Up: ${DB_STARTUP}"

    # HTML: open panel
    if [ "${OPT_HTML}" -eq 1 ]; then
        html_panel_start "${ORACLE_SID}" "${_IS_FIRST}"
        html_infobar "${ORACLE_SID}" "${DB_NAME:-?}" "${DB_VER:-?}" "${DB_ROLE:-?}" \
            "${DB_OPENMODE:-?}" "${DB_STARTUP:-?}" "${DB_HOST:-?}" "${ORACLE_HOME}"
    fi

    # =========================================================================
    # SECTION 1 — INSTANCE & LISTENER
    # =========================================================================
    _CUR_SEC_ID="s01"
    print_hdr "1. INSTANCE & LISTENER STATUS"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "1. Instance &amp; Listener Status"

    if [ "${DB_STATUS}" = "OPEN" ]; then
        result PASS "Instance status: OPEN"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "Instance status: OPEN"
    else
        result FAIL "Instance status: ${DB_STATUS:-UNKNOWN} (expected OPEN)"
        [ "${OPT_HTML}" -eq 1 ] && html_res FAIL "Instance status: ${DB_STATUS:-UNKNOWN}"
    fi

    case "${DB_OPENMODE}" in
        READWRITE)
            result PASS "Open mode: READ WRITE"
            [ "${OPT_HTML}" -eq 1 ] && html_res PASS "Open mode: READ WRITE" ;;
        READONLYWITHAPPLY)
            result INFO "Open mode: READ ONLY WITH APPLY (Active Data Guard)"
            [ "${OPT_HTML}" -eq 1 ] && html_res INFO "Open mode: READ ONLY WITH APPLY" ;;
        READONLY)
            result WARN "Open mode: READ ONLY"
            [ "${OPT_HTML}" -eq 1 ] && html_res WARN "Open mode: READ ONLY" ;;
        *)
            result WARN "Open mode: ${DB_OPENMODE:-UNKNOWN}"
            [ "${OPT_HTML}" -eq 1 ] && html_res WARN "Open mode: ${DB_OPENMODE:-UNKNOWN}" ;;
    esac

    # Listener
    _LC="${ORACLE_HOME}/bin/lsnrctl"
    if [ -x "${_LC}" ]; then
        if "${_LC}" status 2>/dev/null | grep -q "STATUS of the LISTENER"; then
            result PASS "Listener is UP"
            [ "${OPT_HTML}" -eq 1 ] && html_res PASS "Listener is UP"
        else
            result WARN "Listener status could not be confirmed"
            [ "${OPT_HTML}" -eq 1 ] && html_res WARN "Listener status could not be confirmed"
        fi
    fi

    # Restricted mode / read-only FS
    _RESTR=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT LOGINS FROM V\$INSTANCE;")
    if [ "${_RESTR}" = "RESTRICTED" ]; then
        result WARN "Database is in RESTRICTED mode"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "Database is in RESTRICTED mode"
    else
        result PASS "Database not in restricted mode"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "Database not in restricted mode"
    fi

    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 2 — TABLESPACE USAGE
    # =========================================================================
    _CUR_SEC_ID="s02"
    print_hdr "2. TABLESPACE USAGE"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "2. Tablespace Usage"

    _TSOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL TABLESPACE_NAME FORMAT A28
COL TOTAL_MB FORMAT 999999.9
COL USED_MB  FORMAT 999999.9
COL FREE_MB  FORMAT 999999.9
COL PCT_USED FORMAT 990.0
COL STATUS   FORMAT A16" \
"SELECT df.TABLESPACE_NAME,
        ROUND(df.TOTAL_MB,1)                                   TOTAL_MB,
        ROUND(df.TOTAL_MB - NVL(fs.FREE_MB,0),1)              USED_MB,
        ROUND(NVL(fs.FREE_MB,0),1)                             FREE_MB,
        ROUND((df.TOTAL_MB - NVL(fs.FREE_MB,0))
              / NULLIF(df.TOTAL_MB,0) * 100, 0)               PCT_USED,
        CASE
          WHEN ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))
               /NULLIF(df.TOTAL_MB,0)*100,0) >= 90 THEN '*** CRITICAL ***'
          WHEN ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))
               /NULLIF(df.TOTAL_MB,0)*100,0) >= 80 THEN '** WARNING **'
          ELSE 'OK'
        END STATUS
   FROM (SELECT TABLESPACE_NAME, SUM(BYTES)/1024/1024 TOTAL_MB
           FROM DBA_DATA_FILES GROUP BY TABLESPACE_NAME) df
        LEFT OUTER JOIN
        (SELECT TABLESPACE_NAME, SUM(BYTES)/1024/1024 FREE_MB
           FROM DBA_FREE_SPACE GROUP BY TABLESPACE_NAME) fs
        ON df.TABLESPACE_NAME = fs.TABLESPACE_NAME
  ORDER BY PCT_USED DESC;")
    printf "%s\n" "${_TSOUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_TSOUT}"

    _CRIT=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM (
  SELECT ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/NULLIF(df.TOTAL_MB,0)*100,0) P
  FROM (SELECT TABLESPACE_NAME,SUM(BYTES)/1024/1024 TOTAL_MB FROM DBA_DATA_FILES GROUP BY TABLESPACE_NAME) df
  LEFT OUTER JOIN (SELECT TABLESPACE_NAME,SUM(BYTES)/1024/1024 FREE_MB FROM DBA_FREE_SPACE GROUP BY TABLESPACE_NAME) fs
  ON df.TABLESPACE_NAME=fs.TABLESPACE_NAME
) WHERE P >= 90;")
    _WARN=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM (
  SELECT ROUND((df.TOTAL_MB-NVL(fs.FREE_MB,0))/NULLIF(df.TOTAL_MB,0)*100,0) P
  FROM (SELECT TABLESPACE_NAME,SUM(BYTES)/1024/1024 TOTAL_MB FROM DBA_DATA_FILES GROUP BY TABLESPACE_NAME) df
  LEFT OUTER JOIN (SELECT TABLESPACE_NAME,SUM(BYTES)/1024/1024 FREE_MB FROM DBA_FREE_SPACE GROUP BY TABLESPACE_NAME) fs
  ON df.TABLESPACE_NAME=fs.TABLESPACE_NAME
) WHERE P BETWEEN 80 AND 89;")

    [ "${_CRIT:-0}" -gt 0 ] && result FAIL "${_CRIT} tablespace(s) >= 90% full — CRITICAL" \
        && [ "${OPT_HTML}" -eq 1 ] && html_res FAIL "${_CRIT} tablespace(s) >= 90% full"
    [ "${_WARN:-0}" -gt 0 ] && result WARN "${_WARN} tablespace(s) 80-89% full" \
        && [ "${OPT_HTML}" -eq 1 ] && html_res WARN "${_WARN} tablespace(s) 80-89% full"
    if [ "${_CRIT:-0}" -eq 0 ] && [ "${_WARN:-0}" -eq 0 ]; then
        result PASS "All tablespaces within acceptable thresholds"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "All tablespaces within acceptable thresholds"
    fi

    # Autoextend report
    _AX=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL TABLESPACE_NAME FORMAT A28
COL FILE_NAME FORMAT A50
COL AUTOEXTENSIBLE FORMAT A4" \
"SELECT TABLESPACE_NAME, SUBSTR(FILE_NAME,1,50) FILE_NAME, AUTOEXTENSIBLE
 FROM DBA_DATA_FILES WHERE AUTOEXTENSIBLE='YES' ORDER BY 1;")
    logsep; log "  Autoextend-ON datafiles:"; printf "%s\n" "${_AX}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_AX}"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 3 — TEMP TABLESPACE
    # =========================================================================
    _CUR_SEC_ID="s03"
    print_hdr "3. TEMP TABLESPACE"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "3. Temp Tablespace"
    _TMPOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL NAME   FORMAT A20
COL TOTAL_MB FORMAT 99999.0
COL USED_MB  FORMAT 99999.0
COL FREE_MB  FORMAT 99999.0
COL PCT_USED FORMAT 990.0" \
"SELECT t.NAME,
        ROUND(t.BYTES/1024/1024,0)                           TOTAL_MB,
        ROUND(NVL(h.USED_BLOCKS,0)*8192/1024/1024,0)         USED_MB,
        ROUND(t.BYTES/1024/1024
              - NVL(h.USED_BLOCKS,0)*8192/1024/1024, 0)      FREE_MB,
        ROUND(NVL(h.USED_BLOCKS,0)*8192/NULLIF(t.BYTES,0)*100,0) PCT_USED
 FROM   V\$TEMPFILE t
        LEFT OUTER JOIN V\$TEMP_SPACE_HEADER h ON t.FILE#=h.FILE#
 ORDER BY PCT_USED DESC;")
    printf "%s\n" "${_TMPOUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_TMPOUT}"
    result INFO "Temp tablespace usage displayed above"
    [ "${OPT_HTML}" -eq 1 ] && html_res INFO "Temp tablespace usage displayed above"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 4 — REDO LOGS
    # =========================================================================
    _CUR_SEC_ID="s04"
    print_hdr "4. REDO LOG STATUS"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "4. Redo Log Status"
    _REDOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL GRP    FORMAT 99
COL MEMBERS FORMAT 9
COL SIZE_MB FORMAT 9999
COL STATUS  FORMAT A16
COL ARC     FORMAT A3
COL MEMBER  FORMAT A55" \
"SELECT l.GROUP# GRP, l.MEMBERS, ROUND(l.BYTES/1024/1024,0) SIZE_MB,
        l.STATUS, l.ARCHIVED ARC, lf.MEMBER
 FROM V\$LOG l JOIN V\$LOGFILE lf ON l.GROUP#=lf.GROUP#
 ORDER BY l.GROUP#;")
    printf "%s\n" "${_REDOUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_REDOUT}"

    _LSW=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT COUNT(*) FROM V\$LOG_HISTORY WHERE FIRST_TIME > SYSDATE-1/24;")
    log "  Log switches last hour: ${_LSW:-0}"
    if [ "${_LSW:-0}" -gt 20 ]; then
        result WARN "High log switch rate: ${_LSW}/hr — consider larger redo logs"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "High log switch rate: ${_LSW}/hr"
    else
        result PASS "Log switch rate normal: ${_LSW:-0}/hr"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "Log switch rate normal: ${_LSW:-0}/hr"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 5 — ARCHIVE LOG & FRA
    # =========================================================================
    _CUR_SEC_ID="s05"
    print_hdr "5. ARCHIVE LOG & FRA"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "5. Archive Log &amp; FRA"

    log "  Archive Log Mode: ${DB_ARCH}"
    if [ "${DB_ARCH}" = "ARCHIVELOG" ]; then
        result PASS "Database is in ARCHIVELOG mode"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "Database is in ARCHIVELOG mode"
    else
        result WARN "Database is in NOARCHIVELOG mode — PITR not possible"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "Database is in NOARCHIVELOG mode"
    fi

    _ARCDST=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL DEST_ID FORMAT 99
COL STATUS   FORMAT A10
COL TARGET   FORMAT A8
COL ARCHIVER FORMAT A10
COL DESTINATION FORMAT A50" \
"SELECT DEST_ID,STATUS,TARGET,ARCHIVER,DESTINATION
 FROM V\$ARCHIVE_DEST WHERE STATUS != 'INACTIVE' ORDER BY DEST_ID;")
    printf "%s\n" "${_ARCDST}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_ARCDST}"

    # FRA
    _FRAPCT=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT ROUND(SPACE_USED_PERCENT,1) FROM V\$RECOVERY_FILE_DEST;")
    _FRASZ=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT ROUND(SPACE_LIMIT/1024/1024/1024,2) FROM V\$RECOVERY_FILE_DEST;")
    _FRAUSED=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT ROUND(SPACE_USED/1024/1024/1024,2)  FROM V\$RECOVERY_FILE_DEST;")
    if [ -n "${_FRAPCT}" ]; then
        log "  FRA Size: ${_FRASZ} GB  Used: ${_FRAUSED} GB  (${_FRAPCT}%)"
        _FC=$(awk -v v="${_FRAPCT}" 'BEGIN{print(v+0>=85)?1:0}')
        _FW=$(awk -v v="${_FRAPCT}" 'BEGIN{print(v+0>=70)?1:0}')
        if   [ "${_FC}" -eq 1 ]; then result FAIL "FRA CRITICAL: ${_FRAPCT}% used" \
            && [ "${OPT_HTML}" -eq 1 ] && html_res FAIL "FRA CRITICAL: ${_FRAPCT}% used"
        elif [ "${_FW}" -eq 1 ]; then result WARN "FRA WARNING: ${_FRAPCT}% used" \
            && [ "${OPT_HTML}" -eq 1 ] && html_res WARN "FRA WARNING: ${_FRAPCT}% used"
        else result PASS "FRA OK: ${_FRAPCT}% used (${_FRAUSED}/${_FRASZ} GB)" \
            && [ "${OPT_HTML}" -eq 1 ] && html_res PASS "FRA OK: ${_FRAPCT}% (${_FRAUSED}/${_FRASZ} GB)"
        fi
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 6 — RMAN BACKUP
    # =========================================================================
    _CUR_SEC_ID="s06"
    print_hdr "6. RMAN BACKUP STATUS"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "6. RMAN Backup"
    _RMANOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL INPUT_TYPE  FORMAT A22
COL STATUS      FORMAT A32
COL START_TIME  FORMAT A17
COL END_TIME    FORMAT A17
COL MINS        FORMAT 9999.9" \
"SELECT INPUT_TYPE, STATUS,
        TO_CHAR(START_TIME,'YYYY-MM-DD HH24:MI') START_TIME,
        TO_CHAR(END_TIME,'YYYY-MM-DD HH24:MI')   END_TIME,
        ROUND(ELAPSED_SECONDS/60,1)              MINS
 FROM V\$RMAN_BACKUP_JOB_DETAILS
 WHERE START_TIME > SYSDATE-7
 ORDER BY START_TIME DESC FETCH FIRST 15 ROWS ONLY;")
    printf "%s\n" "${_RMANOUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_RMANOUT}"

    _FAILBK=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$RMAN_BACKUP_JOB_DETAILS
 WHERE STATUS NOT IN ('COMPLETED','COMPLETED WITH WARNINGS')
   AND START_TIME > SYSDATE-7;")
    _LASTFULL=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT TO_CHAR(MAX(END_TIME),'YYYY-MM-DD HH24:MI')
 FROM V\$RMAN_BACKUP_JOB_DETAILS
 WHERE INPUT_TYPE LIKE 'DB FULL%' AND STATUS='COMPLETED';")
    log "  Last full backup: ${_LASTFULL:-NONE FOUND}"
    if [ "${_FAILBK:-0}" -gt 0 ]; then
        result FAIL "${_FAILBK} failed RMAN job(s) in last 7 days"
        [ "${OPT_HTML}" -eq 1 ] && html_res FAIL "${_FAILBK} failed RMAN job(s) in last 7 days"
    else
        result PASS "No failed RMAN jobs last 7 days | Last full: ${_LASTFULL:-N/A}"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "No failed RMAN jobs | Last full: ${_LASTFULL:-N/A}"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 7 — ALERT LOG
    # =========================================================================
    _CUR_SEC_ID="s07"
    print_hdr "7. ALERT LOG (last 5000 lines)"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "7. Alert Log Errors"
    _DIAG=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT VALUE FROM V\$DIAG_INFO WHERE NAME='Diag Trace';")
    _ALOG="${_DIAG}/alert_${ORACLE_SID}.log"
    log "  Path: ${_ALOG}"
    if [ -f "${_ALOG}" ]; then
        _ORACNT=$(tail -5000 "${_ALOG}" 2>/dev/null | grep -c "ORA-" || true)
        log "  ORA- count (last 5000 lines): ${_ORACNT}"
        _ALERR=$(tail -5000 "${_ALOG}" 2>/dev/null | grep -i "ORA-\|FATAL" | head -40)
        if [ -n "${_ALERR}" ]; then
            result WARN "${_ORACNT} ORA-/FATAL entries in alert log"
            [ "${OPT_HTML}" -eq 1 ] && html_res WARN "${_ORACNT} ORA-/FATAL entries found"
            [ "${OPT_HTML}" -eq 1 ] && html_pre "${_ALERR}"
            printf "%s\n" "${_ALERR}" >> "${LOG_FILE}"
        else
            result PASS "No ORA-/FATAL errors in last 5000 lines"
            [ "${OPT_HTML}" -eq 1 ] && html_res PASS "No ORA-/FATAL errors in last 5000 lines"
        fi
    else
        result WARN "Alert log not accessible: ${_ALOG}"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "Alert log not accessible: ${_ALOG}"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 8 — INVALID OBJECTS
    # =========================================================================
    _CUR_SEC_ID="s08"
    print_hdr "8. INVALID OBJECTS"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "8. Invalid Objects"
    _INVCNT=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT COUNT(*) FROM DBA_OBJECTS WHERE STATUS='INVALID';")
    if [ "${_INVCNT:-0}" -gt 0 ]; then
        result WARN "${_INVCNT} invalid object(s) found"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "${_INVCNT} invalid object(s)"
        _INVOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL OWNER FORMAT A20
COL OBJECT_NAME FORMAT A35
COL OBJECT_TYPE FORMAT A20" \
"SELECT OWNER,OBJECT_NAME,OBJECT_TYPE
 FROM DBA_OBJECTS WHERE STATUS='INVALID'
 ORDER BY OWNER,OBJECT_TYPE,OBJECT_NAME FETCH FIRST 50 ROWS ONLY;")
        printf "%s\n" "${_INVOUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${_INVOUT}"
    else
        result PASS "No invalid objects"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "No invalid objects"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 9 — SESSIONS, BLOCKING & LONG OPS
    # =========================================================================
    _CUR_SEC_ID="s09"
    print_hdr "9. SESSIONS, BLOCKING & LONG OPS"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "9. Sessions &amp; Blocking"

    _SESSOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL STATUS FORMAT A12
COL CNT    FORMAT 9999" \
"SELECT STATUS,COUNT(*) CNT FROM V\$SESSION WHERE TYPE='USER'
 GROUP BY STATUS ORDER BY CNT DESC;")
    printf "%s\n" "${_SESSOUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_SESSOUT}"

    _BLKCNT=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT COUNT(*) FROM V\$SESSION WHERE BLOCKING_SESSION IS NOT NULL;")
    if [ "${_BLKCNT:-0}" -gt 0 ]; then
        result WARN "${_BLKCNT} blocked session(s)"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "${_BLKCNT} blocked session(s)"
        _BLKOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL SID         FORMAT 9999
COL BLOCKER_SID FORMAT 9999
COL USERNAME    FORMAT A15
COL EVENT       FORMAT A35
COL WAIT_MIN    FORMAT 9999.9" \
"SELECT s.SID, s.BLOCKING_SESSION BLOCKER_SID, s.USERNAME,
        s.EVENT, ROUND(s.SECONDS_IN_WAIT/60,1) WAIT_MIN
 FROM V\$SESSION s WHERE s.BLOCKING_SESSION IS NOT NULL
 ORDER BY s.SECONDS_IN_WAIT DESC;")
        printf "%s\n" "${_BLKOUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${_BLKOUT}"
    else
        result PASS "No blocked sessions"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "No blocked sessions"
    fi

    _LRCNT=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$SESSION_LONGOPS
 WHERE TIME_REMAINING>0 AND ELAPSED_SECONDS>300;")
    if [ "${_LRCNT:-0}" -gt 0 ]; then
        result WARN "${_LRCNT} long-running operation(s) >5 min"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "${_LRCNT} long-running operation(s) >5 min"
        _LROUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL OPNAME     FORMAT A30
COL TARGET      FORMAT A25
COL PCT_DONE    FORMAT 990.0
COL ELAPSED_MIN FORMAT 9999.9
COL REMAIN_MIN  FORMAT 9999.9" \
"SELECT SID,OPNAME,TARGET,
        ROUND(SOFAR/NULLIF(TOTALWORK,0)*100,0) PCT_DONE,
        ROUND(ELAPSED_SECONDS/60,1) ELAPSED_MIN,
        ROUND(TIME_REMAINING/60,1)  REMAIN_MIN
 FROM V\$SESSION_LONGOPS
 WHERE TIME_REMAINING>0 AND ELAPSED_SECONDS>300
 ORDER BY ELAPSED_SECONDS DESC;")
        printf "%s\n" "${_LROUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${_LROUT}"
    else
        result PASS "No long-running operations >5 min"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "No long-running operations >5 min"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 10 — TOP WAIT EVENTS  (fixed: use V$SESSION_WAIT_CLASS)
    # =========================================================================
    _CUR_SEC_ID="s10"
    print_hdr "10. TOP WAIT EVENTS"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "10. Top Wait Events"

    # V$SYSTEM_EVENT is reliable; key fix: cast TIME_WAITED correctly
    _WAITOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL EVENT        FORMAT A40
COL WAIT_CLASS   FORMAT A18
COL TOTAL_WAITS  FORMAT 9999999999
COL TIME_SECS    FORMAT 9999999.9
COL AVG_MS       FORMAT 99999.9" \
"SELECT e.EVENT,
        e.WAIT_CLASS,
        e.TOTAL_WAITS,
        ROUND(e.TIME_WAITED/100, 1)                        TIME_SECS,
        ROUND(e.TIME_WAITED/NULLIF(e.TOTAL_WAITS,0)*10, 2) AVG_MS
 FROM V\$SYSTEM_EVENT e
 WHERE e.WAIT_CLASS NOT IN ('Idle','System I/O')
   AND e.TOTAL_WAITS > 0
 ORDER BY e.TIME_WAITED DESC
 FETCH FIRST 15 ROWS ONLY;")
    printf "%s\n" "${_WAITOUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_WAITOUT}"
    result INFO "Top 15 non-idle wait events shown above"
    [ "${OPT_HTML}" -eq 1 ] && html_res INFO "Top 15 non-idle wait events shown above"

    # Wait class summary
    _WCLSOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL WAIT_CLASS  FORMAT A20
COL TOTAL_WAITS FORMAT 9999999999
COL TIME_SECS   FORMAT 9999999.9" \
"SELECT WAIT_CLASS,
        SUM(TOTAL_WAITS) TOTAL_WAITS,
        ROUND(SUM(TIME_WAITED)/100,1) TIME_SECS
 FROM V\$SYSTEM_EVENT
 WHERE WAIT_CLASS NOT IN ('Idle','System I/O')
 GROUP BY WAIT_CLASS
 ORDER BY TIME_SECS DESC;")
    logsep; log "  Wait Class Summary:"; printf "%s\n" "${_WCLSOUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_WCLSOUT}"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 11 — DATA GUARD  (fixed: proper V$ queries)
    # =========================================================================
    _CUR_SEC_ID="s11"
    print_hdr "11. DATA GUARD STATUS"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "11. Data Guard Status"

    # Use V$DATABASE.PROTECTION_MODE and V$DATAGUARD_STATUS — always present
    _DG_PROT=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT PROTECTION_MODE FROM V\$DATABASE;")
    _DG_PRLVL=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT PROTECTION_LEVEL FROM V\$DATABASE;")
    log "  Protection Mode  : ${_DG_PROT:-N/A}"
    log "  Protection Level : ${_DG_PRLVL:-N/A}"
    [ "${OPT_HTML}" -eq 1 ] && html_res INFO "DG Protection Mode: ${_DG_PROT:-N/A} | Level: ${_DG_PRLVL:-N/A}"

    # Check if any standby destinations are configured
    _DGDST=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL DEST_ID  FORMAT 99
COL DEST_NAME FORMAT A20
COL STATUS    FORMAT A12
COL TARGET    FORMAT A10
COL DB_UNIQUE_NAME FORMAT A25
COL ERROR     FORMAT A40" \
"SELECT DEST_ID, DEST_NAME, STATUS, TARGET, DB_UNIQUE_NAME, ERROR
 FROM V\$ARCHIVE_DEST_STATUS
 WHERE STATUS != 'INACTIVE'
   AND TARGET IN ('STANDBY','PRIMARY')
 ORDER BY DEST_ID;")
    printf "%s\n" "${_DGDST}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_DGDST}"

    # MRP / Redo Apply (standby only)
    _MRPOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL PROCESS  FORMAT A12
COL STATUS   FORMAT A20
COL SEQUENCE# FORMAT 99999
COL BLOCK#   FORMAT 9999999" \
"SELECT PROCESS, STATUS, SEQUENCE#, BLOCK#
 FROM V\$MANAGED_STANDBY
 ORDER BY PROCESS;")
    if [ -n "${_MRPOUT}" ]; then
        logsep; log "  Managed Standby Processes:"; printf "%s\n" "${_MRPOUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${_MRPOUT}"
        _MRPSTAT=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
            "SELECT STATUS FROM V\$MANAGED_STANDBY WHERE PROCESS='MRP0';")
        [ -n "${_MRPSTAT}" ] && log "  MRP0 Status: ${_MRPSTAT}"
        [ "${_MRPSTAT}" = "APPLYING_LOG" ] && result PASS "MRP0 actively applying redo" \
            && [ "${OPT_HTML}" -eq 1 ] && html_res PASS "MRP0 actively applying redo"
    fi

    # Apply / Transport lag from V$DATAGUARD_STATS (available on 11g+)
    _DGLAG=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL NAME  FORMAT A30
COL VALUE FORMAT A20
COL UNIT  FORMAT A25" \
"SELECT NAME, VALUE, UNIT FROM V\$DATAGUARD_STATS
 WHERE NAME IN ('apply lag','transport lag','estimated startup time')
 ORDER BY NAME;")
    if [ -n "${_DGLAG}" ]; then
        logsep; log "  DG Lag Stats:"; printf "%s\n" "${_DGLAG}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${_DGLAG}"
    fi

    if [ "${_DG_PROT}" = "MAXIMUM PERFORMANCE" ] || [ "${_DG_PROT}" = "MAXIMUM AVAILABILITY" ] \
       || [ "${_DG_PROT}" = "MAXIMUM PROTECTION" ]; then
        result PASS "Data Guard configured: ${_DG_PROT}"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "Data Guard configured: ${_DG_PROT}"
    else
        result INFO "No Data Guard / standalone instance"
        [ "${OPT_HTML}" -eq 1 ] && html_res INFO "No Data Guard / standalone instance"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 12 — ASM DISK GROUPS  (fixed FORMAT strings)
    # =========================================================================
    _CUR_SEC_ID="s12"
    print_hdr "12. ASM DISK GROUPS"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "12. ASM Disk Groups"

    _ASMCNT=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT COUNT(*) FROM V\$ASM_DISKGROUP;" 2>/dev/null)
    if [ "${_ASMCNT:-0}" -gt 0 ] 2>/dev/null; then
        # Note: PCT_USED formatted as integer to avoid illegal format issues
        _ASMOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL NAME     FORMAT A20
COL STATE    FORMAT A12
COL TYPE     FORMAT A8
COL TOTAL_GB FORMAT 99999
COL FREE_GB  FORMAT 99999
COL USED_GB  FORMAT 99999
COL PCT_USED FORMAT 999" \
"SELECT NAME, STATE, TYPE,
        ROUND(TOTAL_MB/1024)                          TOTAL_GB,
        ROUND(FREE_MB/1024)                           FREE_GB,
        ROUND((TOTAL_MB-FREE_MB)/1024)                USED_GB,
        ROUND((1 - FREE_MB/NULLIF(TOTAL_MB,0))*100)   PCT_USED
 FROM V\$ASM_DISKGROUP
 ORDER BY NAME;")
        printf "%s\n" "${_ASMOUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${_ASMOUT}"
        _ASMCRIT=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$ASM_DISKGROUP
 WHERE ROUND((1-FREE_MB/NULLIF(TOTAL_MB,0))*100) >= 85;")
        _ASMWARN=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$ASM_DISKGROUP
 WHERE ROUND((1-FREE_MB/NULLIF(TOTAL_MB,0))*100) BETWEEN 70 AND 84;")
        [ "${_ASMCRIT:-0}" -gt 0 ] && result FAIL "${_ASMCRIT} ASM disk group(s) >= 85% full" \
            && [ "${OPT_HTML}" -eq 1 ] && html_res FAIL "${_ASMCRIT} ASM disk group(s) >= 85% full"
        [ "${_ASMWARN:-0}" -gt 0 ] && result WARN "${_ASMWARN} ASM disk group(s) 70-84% full" \
            && [ "${OPT_HTML}" -eq 1 ] && html_res WARN "${_ASMWARN} ASM disk group(s) 70-84% full"
        if [ "${_ASMCRIT:-0}" -eq 0 ] && [ "${_ASMWARN:-0}" -eq 0 ]; then
            result PASS "All ASM disk groups within acceptable usage"
            [ "${OPT_HTML}" -eq 1 ] && html_res PASS "All ASM disk groups within acceptable usage"
        fi
    else
        result INFO "ASM not accessible from this instance"
        [ "${OPT_HTML}" -eq 1 ] && html_res INFO "ASM not accessible from this instance"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 13 — USER ACCOUNTS
    # =========================================================================
    _CUR_SEC_ID="s13"
    print_hdr "13. USER ACCOUNT STATUS"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "13. User Account Status"

    _USROUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL USERNAME        FORMAT A25
COL ACCOUNT_STATUS  FORMAT A20
COL EXPIRY_DATE     FORMAT A12
COL PROFILE         FORMAT A15" \
"SELECT USERNAME,ACCOUNT_STATUS,
        TO_CHAR(EXPIRY_DATE,'YYYY-MM-DD') EXPIRY_DATE,PROFILE
 FROM DBA_USERS
 WHERE ACCOUNT_STATUS != 'OPEN'
   AND USERNAME NOT IN (
       'SYS','SYSTEM','DBSNMP','SYSMAN','OUTLN','ORACLE_OCM','ANONYMOUS',
       'XDB','XS\$NULL','GSMADMIN_INTERNAL','AUDSYS','GSMCATUSER',
       'GSMROOTUSER','DBSFWUSER','SYSBACKUP','SYSDG','SYSKM','SYSRAC',
       'APPQOSSYS','OJVMSYS','DVSYS','DVF','LBACSYS','ORDDATA',
       'ORDPLUGINS','ORDSYS','MDSYS','WMSYS','CTXSYS','OLAPSYS',
       'FLOWS_FILES','APEX_PUBLIC_USER','MDDATA','DIP')
 ORDER BY ACCOUNT_STATUS,USERNAME;")
    printf "%s\n" "${_USROUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_USROUT}"

    _LOCKD=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_USERS WHERE ACCOUNT_STATUS LIKE '%LOCKED%'
 AND USERNAME NOT IN ('SYS','SYSTEM','DBSNMP','OUTLN','ORACLE_OCM',
 'ANONYMOUS','XDB','XS\$NULL','GSMADMIN_INTERNAL','AUDSYS',
 'GSMCATUSER','GSMROOTUSER','DBSFWUSER','SYSBACKUP','SYSDG',
 'SYSKM','SYSRAC','APPQOSSYS','OJVMSYS');")
    _EXPRD=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
        "SELECT COUNT(*) FROM DBA_USERS WHERE ACCOUNT_STATUS='EXPIRED';")
    _EXPRING=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_USERS
 WHERE ACCOUNT_STATUS='OPEN' AND EXPIRY_DATE < SYSDATE+30
   AND EXPIRY_DATE IS NOT NULL;")
    [ "${_LOCKD:-0}"  -gt 0 ] && result WARN "${_LOCKD} non-system user(s) locked" \
        && [ "${OPT_HTML}" -eq 1 ] && html_res WARN "${_LOCKD} non-system user(s) locked"
    [ "${_EXPRD:-0}"  -gt 0 ] && result WARN "${_EXPRD} user account(s) expired" \
        && [ "${OPT_HTML}" -eq 1 ] && html_res WARN "${_EXPRD} user account(s) expired"
    [ "${_EXPRING:-0}" -gt 0 ] && result WARN "${_EXPRING} account(s) expiring within 30 days" \
        && [ "${OPT_HTML}" -eq 1 ] && html_res WARN "${_EXPRING} account(s) expiring within 30 days"
    if [ "${_LOCKD:-0}" -eq 0 ] && [ "${_EXPRD:-0}" -eq 0 ] && [ "${_EXPRING:-0}" -eq 0 ]; then
        result PASS "All non-system accounts in normal status"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "All non-system accounts in normal status"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 14 — SCHEDULER JOBS
    # =========================================================================
    _CUR_SEC_ID="s14"
    print_hdr "14. SCHEDULER FAILED JOBS (7 days)"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "14. Scheduler Jobs"
    _SCFAIL=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_SCHEDULER_JOB_RUN_DETAILS
 WHERE STATUS='FAILED' AND ACTUAL_START_DATE > SYSTIMESTAMP-7;")
    if [ "${_SCFAIL:-0}" -gt 0 ]; then
        result WARN "${_SCFAIL} failed scheduler job(s) last 7 days"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "${_SCFAIL} failed scheduler job(s)"
        _SCOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL OWNER    FORMAT A15
COL JOB_NAME FORMAT A30
COL STATUS   FORMAT A12
COL RUN_TIME FORMAT A18" \
"SELECT OWNER,JOB_NAME,STATUS,
        TO_CHAR(ACTUAL_START_DATE,'YYYY-MM-DD HH24:MI') RUN_TIME
 FROM DBA_SCHEDULER_JOB_RUN_DETAILS
 WHERE STATUS='FAILED' AND ACTUAL_START_DATE > SYSTIMESTAMP-7
 ORDER BY ACTUAL_START_DATE DESC FETCH FIRST 20 ROWS ONLY;")
        printf "%s\n" "${_SCOUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${_SCOUT}"
    else
        result PASS "No failed scheduler jobs last 7 days"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "No failed scheduler jobs last 7 days"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 15 — PATCH LEVEL & COMPONENTS
    # =========================================================================
    _CUR_SEC_ID="s15"
    print_hdr "15. PATCH LEVEL & COMPONENTS"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "15. Patch Level"

    # Full DB version from V$VERSION (always works)
    _FULLVER=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL BANNER_FULL FORMAT A80" \
"SELECT BANNER_FULL FROM V\$VERSION WHERE ROWNUM=1;")
    log "  ${_FULLVER}"; [ "${OPT_HTML}" -eq 1 ] && html_res INFO "${_FULLVER}"

    # DBA_REGISTRY_SQLPATCH — 12.2+, status column name varies; use safe columns only
    _PTCHOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL PATCH_ID     FORMAT 9999999999
COL VERSION      FORMAT A15
COL ACTION       FORMAT A10
COL STATUS       FORMAT A12
COL APPLIED_TIME FORMAT A18
COL DESCRIPTION  FORMAT A55" \
"SELECT PATCH_ID,
        TO_CHAR(VERSION) VERSION,
        ACTION,
        STATUS,
        TO_CHAR(ACTION_TIME,'YYYY-MM-DD HH24:MI') APPLIED_TIME,
        SUBSTR(DESCRIPTION,1,55) DESCRIPTION
 FROM DBA_REGISTRY_SQLPATCH
 ORDER BY ACTION_TIME DESC
 FETCH FIRST 5 ROWS ONLY;" 2>/dev/null)

    if printf '%s' "${_PTCHOUT}" | grep -qi "ORA-\|no rows"; then
        _PTCHOUT=""
    fi

    if [ -z "${_PTCHOUT}" ]; then
        result INFO "DBA_REGISTRY_SQLPATCH empty — no PSU/RU applied or query unavailable"
        [ "${OPT_HTML}" -eq 1 ] && html_res INFO "DBA_REGISTRY_SQLPATCH empty — no PSU/RU recorded"
    else
        printf "%s\n" "${_PTCHOUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${_PTCHOUT}"
        # Check latest patch status using ACTION_TIME subquery (avoids column name issues)
        _PFAIL=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_REGISTRY_SQLPATCH
 WHERE STATUS NOT IN ('SUCCESS','WITH ERRORS')
   AND ACTION_TIME = (SELECT MAX(ACTION_TIME) FROM DBA_REGISTRY_SQLPATCH);" 2>/dev/null)
        if [ "${_PFAIL:-0}" -gt 0 ]; then
            result FAIL "Latest SQL patch has non-SUCCESS status"
            [ "${OPT_HTML}" -eq 1 ] && html_res FAIL "Latest SQL patch has non-SUCCESS status"
        else
            result PASS "SQL patch history looks healthy"
            [ "${OPT_HTML}" -eq 1 ] && html_res PASS "SQL patch history healthy"
        fi
    fi

    # DBA_REGISTRY component status — VALID/OPTION OFF only accepted
    _COMPOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL COMP_NAME FORMAT A40
COL VERSION   FORMAT A15
COL STATUS    FORMAT A14" \
"SELECT COMP_NAME, VERSION, STATUS FROM DBA_REGISTRY ORDER BY COMP_NAME;")
    logsep; log "  DB Components (DBA_REGISTRY):"
    printf "%s\n" "${_COMPOUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_COMPOUT}"
    _COMPFAIL=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_REGISTRY
 WHERE STATUS NOT IN ('VALID','OPTION OFF','LOADING');")
    if [ "${_COMPFAIL:-0}" -gt 0 ]; then
        result FAIL "${_COMPFAIL} component(s) not VALID in DBA_REGISTRY"
        [ "${OPT_HTML}" -eq 1 ] && html_res FAIL "${_COMPFAIL} component(s) not VALID"
    else
        result PASS "All DB components VALID"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "All DB components VALID"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 16 — TOP SQL (Elapsed / CPU / Physical Reads)
    # =========================================================================
    _CUR_SEC_ID="s16"
    print_hdr "16. TOP SQL PERFORMANCE"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "16. Top SQL Performance"

    _SQLET=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL SQL_ID      FORMAT A15
COL ELAPSED_S   FORMAT 9999999
COL EXECS       FORMAT 9999999
COL AVG_S       FORMAT 9999.99
COL SQL_TEXT    FORMAT A60" \
"SELECT SQL_ID,
        ROUND(ELAPSED_TIME/1000000)                      ELAPSED_S,
        EXECUTIONS                                        EXECS,
        ROUND(ELAPSED_TIME/NULLIF(EXECUTIONS,0)/1000000,2) AVG_S,
        SUBSTR(SQL_TEXT,1,60)                             SQL_TEXT
 FROM V\$SQLAREA WHERE ELAPSED_TIME > 0
 ORDER BY ELAPSED_TIME DESC FETCH FIRST 10 ROWS ONLY;")
    logsep; log "  Top 10 by Elapsed Time:"; printf "%s\n" "${_SQLET}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_SQLET}"

    _SQLCPU=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL SQL_ID    FORMAT A15
COL CPU_S     FORMAT 9999999
COL EXECS     FORMAT 9999999
COL AVG_CPU_S FORMAT 9999.99
COL SQL_TEXT  FORMAT A60" \
"SELECT SQL_ID,
        ROUND(CPU_TIME/1000000)                       CPU_S,
        EXECUTIONS                                     EXECS,
        ROUND(CPU_TIME/NULLIF(EXECUTIONS,0)/1000000,2) AVG_CPU_S,
        SUBSTR(SQL_TEXT,1,60)                          SQL_TEXT
 FROM V\$SQLAREA WHERE CPU_TIME > 0
 ORDER BY CPU_TIME DESC FETCH FIRST 10 ROWS ONLY;")
    logsep; log "  Top 10 by CPU Time:"; printf "%s\n" "${_SQLCPU}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_SQLCPU}"

    _SQLIO=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL SQL_ID      FORMAT A15
COL PHYS_READS  FORMAT 9999999
COL EXECS       FORMAT 9999999
COL SQL_TEXT    FORMAT A60" \
"SELECT SQL_ID,
        DISK_READS                   PHYS_READS,
        EXECUTIONS                    EXECS,
        SUBSTR(SQL_TEXT,1,60)         SQL_TEXT
 FROM V\$SQLAREA WHERE DISK_READS > 0
 ORDER BY DISK_READS DESC FETCH FIRST 10 ROWS ONLY;")
    logsep; log "  Top 10 by Physical Reads:"; printf "%s\n" "${_SQLIO}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_SQLIO}"
    result INFO "Top SQL by Elapsed, CPU and Physical Reads shown above"
    [ "${OPT_HTML}" -eq 1 ] && html_res INFO "Top SQL by Elapsed, CPU and Physical Reads shown above"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 17 — SGA / PGA / MEMORY (comprehensive)
    # =========================================================================
    _CUR_SEC_ID="s17"
    print_hdr "17. SGA / PGA / MEMORY DETAIL"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "17. SGA / PGA / Memory"

    # Overall SGA
    _SGAOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL NAME  FORMAT A35
COL MB    FORMAT 999999" \
"SELECT NAME, ROUND(VALUE/1024/1024) MB FROM V\$SGA ORDER BY VALUE DESC;")
    logsep; log "  SGA Summary:"; printf "%s\n" "${_SGAOUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_SGAOUT}"

    # SGA dynamic components
    _SGADYN=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL COMPONENT     FORMAT A38
COL CURRENT_MB    FORMAT 99999
COL MIN_MB        FORMAT 99999
COL MAX_MB        FORMAT 99999
COL LAST_OPER     FORMAT A15" \
"SELECT COMPONENT,
        ROUND(CURRENT_SIZE/1024/1024) CURRENT_MB,
        ROUND(MIN_SIZE/1024/1024)     MIN_MB,
        ROUND(MAX_SIZE/1024/1024)     MAX_MB,
        LAST_OPER_TYPE                LAST_OPER
 FROM V\$SGA_DYNAMIC_COMPONENTS
 WHERE CURRENT_SIZE > 0
 ORDER BY CURRENT_SIZE DESC;")
    logsep; log "  SGA Dynamic Components:"; printf "%s\n" "${_SGADYN}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_SGADYN}"

    # PGA stats
    _PGAOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL NAME  FORMAT A40
COL MB    FORMAT 9999999" \
"SELECT NAME, ROUND(VALUE/1024/1024) MB
 FROM V\$PGASTAT
 WHERE NAME IN ('aggregate PGA target parameter',
                'aggregate PGA auto target',
                'total PGA inuse',
                'total PGA allocated',
                'maximum PGA allocated',
                'total freeable PGA memory',
                'PGA memory freed back to OS',
                'bytes processed',
                'extra bytes read/written',
                'cache hit percentage',
                'recompute count (total)')
 ORDER BY VALUE DESC;")
    logsep; log "  PGA Statistics:"; printf "%s\n" "${_PGAOUT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_PGAOUT}"

    # Memory init parameters
    _MEMPAR=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL NAME  FORMAT A35
COL VALUE FORMAT A20" \
"SELECT NAME, VALUE FROM V\$PARAMETER
 WHERE NAME IN ('sga_max_size','sga_target','pga_aggregate_target',
                'pga_aggregate_limit','memory_target','memory_max_target',
                'db_cache_size','shared_pool_size','large_pool_size',
                'java_pool_size','streams_pool_size','use_large_pages')
 ORDER BY NAME;")
    logsep; log "  Memory Init Parameters:"; printf "%s\n" "${_MEMPAR}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_MEMPAR}"

    # Buffer cache hit ratio
    _BHR=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT ROUND((1-(p.VALUE/NULLIF(b.VALUE+c.VALUE+p.VALUE,0)))*100,2)
 FROM V\$SYSSTAT p, V\$SYSSTAT b, V\$SYSSTAT c
 WHERE p.NAME='physical reads'
   AND b.NAME='db block gets'
   AND c.NAME='consistent gets';")
    # Shared pool free %
    _SPFREE=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT ROUND(SUM(CASE WHEN NAME='free memory' THEN BYTES ELSE 0 END)
       / NULLIF(SUM(BYTES),0) * 100, 1)
 FROM V\$SGASTAT WHERE POOL='shared pool';")
    # Library cache hit ratio
    _LCHR=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT ROUND(SUM(PINHITS)/NULLIF(SUM(PINS),0)*100,2) FROM V\$LIBRARYCACHE;")
    # Redo log buffer space waits
    _RLOGWAIT=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT VALUE FROM V\$SYSSTAT WHERE NAME='redo log space requests';")

    log ""
    log "  Buffer Cache Hit Ratio  : ${_BHR}%"
    log "  Shared Pool Free        : ${_SPFREE}%"
    log "  Library Cache Hit Ratio : ${_LCHR}%"
    log "  Redo Log Space Waits    : ${_RLOGWAIT}"

    [ "${OPT_HTML}" -eq 1 ] && html_res INFO "Buffer Cache Hit: ${_BHR}%  |  Shared Pool Free: ${_SPFREE}%  |  LibCache Hit: ${_LCHR}%  |  Redo Waits: ${_RLOGWAIT}"

    _BHROK=$(awk -v v="${_BHR:-0}"    'BEGIN{print(v+0>=90)?1:0}')
    _SPOK=$(awk  -v v="${_SPFREE:-0}" 'BEGIN{print(v+0>=10)?1:0}')
    if [ "${_BHROK}" -eq 1 ]; then
        result PASS "Buffer Cache Hit Ratio: ${_BHR}% (good, >=90%)"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "Buffer Cache Hit Ratio: ${_BHR}%"
    else
        result WARN "Buffer Cache Hit Ratio: ${_BHR}% (below 90%)"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "Buffer Cache Hit Ratio: ${_BHR}%"
    fi
    if [ "${_SPOK}" -eq 1 ]; then
        result PASS "Shared Pool free space: ${_SPFREE}% (>=10%)"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "Shared Pool free space: ${_SPFREE}%"
    else
        result WARN "Shared Pool free space low: ${_SPFREE}%"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "Shared Pool free space low: ${_SPFREE}%"
    fi
    if [ "${_RLOGWAIT:-0}" -gt 100 ]; then
        result WARN "Redo log space requests high: ${_RLOGWAIT} — consider larger redo log buffer"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "Redo log space requests: ${_RLOGWAIT}"
    else
        result PASS "Redo log space waits OK: ${_RLOGWAIT}"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "Redo log space waits OK: ${_RLOGWAIT}"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 18 — UNDO & LOCKING
    # =========================================================================
    _CUR_SEC_ID="s18"
    print_hdr "18. UNDO & LOCKING"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "18. Undo &amp; Locking"

    _UNDOOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL TABLESPACE_NAME FORMAT A20
COL STATUS          FORMAT A15
COL TOTAL_MB        FORMAT 99999
COL USED_MB         FORMAT 99999
COL EXPIRED_MB      FORMAT 99999
COL UNEXPIRED_MB    FORMAT 99999" \
"SELECT t.TABLESPACE_NAME,
        t.STATUS,
        ROUND(t.TOTAL_MB)      TOTAL_MB,
        ROUND(t.USED_MB)       USED_MB,
        ROUND(t.EXPIRED_MB)    EXPIRED_MB,
        ROUND(t.UNEXPIRED_MB)  UNEXPIRED_MB
 FROM (
   SELECT r.TABLESPACE_NAME,
          SUM(CASE WHEN r.STATUS='ACTIVE'    THEN r.BYTES/1024/1024 ELSE 0 END) USED_MB,
          SUM(CASE WHEN r.STATUS='EXPIRED'   THEN r.BYTES/1024/1024 ELSE 0 END) EXPIRED_MB,
          SUM(CASE WHEN r.STATUS='UNEXPIRED' THEN r.BYTES/1024/1024 ELSE 0 END) UNEXPIRED_MB,
          SUM(r.BYTES)/1024/1024  TOTAL_MB,
          'N/A' STATUS
   FROM V\$UNDOSTAT u, DBA_SEGMENTS r
   WHERE r.SEGMENT_TYPE LIKE 'ROLLBACK%'
     AND ROWNUM < 2
   GROUP BY r.TABLESPACE_NAME
 ) t;")
    # Simpler fallback that always works
    if [ -z "${_UNDOOUT}" ]; then
        _UNDOOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL NAME    FORMAT A30
COL VALUE   FORMAT A25" \
"SELECT NAME, VALUE FROM V\$PARAMETER
 WHERE NAME IN ('undo_tablespace','undo_retention','undo_management')
 ORDER BY NAME;")
        log "  Undo Parameters:"; printf "%s\n" "${_UNDOOUT}" | tee -a "${LOG_FILE}"
    else
        printf "%s\n" "${_UNDOOUT}" | tee -a "${LOG_FILE}"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_UNDOOUT}"

    # Undo stats from V$UNDOSTAT
    _UNDOSTAT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL BEGIN_TIME  FORMAT A18
COL UNDOTSN     FORMAT 9999
COL TXNCOUNT    FORMAT 99999
COL MAXCONCURRENCY FORMAT 99999
COL SSOLDERRCNT FORMAT 9999
COL NOSPACEERRCNT FORMAT 9999" \
"SELECT TO_CHAR(BEGIN_TIME,'YYYY-MM-DD HH24:MI') BEGIN_TIME,
        UNDOTSN, TXNCOUNT, MAXCONCURRENCY,
        SSOLDERRCNT, NOSPACEERRCNT
 FROM V\$UNDOSTAT
 ORDER BY BEGIN_TIME DESC FETCH FIRST 5 ROWS ONLY;")
    logsep; log "  Undo Stats (last intervals):"; printf "%s\n" "${_UNDOSTAT}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_UNDOSTAT}"

    # Snapshot too old errors
    _STOE=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT SUM(SSOLDERRCNT) FROM V\$UNDOSTAT WHERE BEGIN_TIME > SYSDATE-1;")
    if [ "${_STOE:-0}" -gt 0 ]; then
        result WARN "Snapshot too old errors in last 24h: ${_STOE} — increase undo_retention"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "Snapshot too old errors: ${_STOE}"
    else
        result PASS "No snapshot too old errors in last 24h"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "No snapshot too old errors"
    fi

    # Active locks
    _LCKCNT=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM V\$LOCK WHERE TYPE IN ('TM','TX') AND BLOCK=1;")
    logsep; log "  Blocking locks: ${_LCKCNT:-0}"
    if [ "${_LCKCNT:-0}" -gt 0 ]; then
        result WARN "${_LCKCNT} blocking lock(s) detected"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "${_LCKCNT} blocking lock(s) detected"
        _LCKOUT=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL SID    FORMAT 9999
COL TYPE   FORMAT A6
COL LMODE  FORMAT A12
COL OBJECT FORMAT A30" \
"SELECT l.SID, l.TYPE,
        DECODE(l.LMODE,0,'None',1,'Null',2,'Row-S',3,'Row-X',
               4,'Share',5,'S/Row-X',6,'Exclusive') LMODE,
        NVL(o.OBJECT_NAME,'N/A') OBJECT
 FROM V\$LOCK l LEFT OUTER JOIN DBA_OBJECTS o ON l.ID1=o.OBJECT_ID
 WHERE l.TYPE IN ('TM','TX') AND l.BLOCK=1
 ORDER BY l.SID;")
        printf "%s\n" "${_LCKOUT}" | tee -a "${LOG_FILE}"
        [ "${OPT_HTML}" -eq 1 ] && html_pre "${_LCKOUT}"
    else
        result PASS "No blocking locks"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "No blocking locks"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # SECTION 19 — SECURITY CHECKS
    # =========================================================================
    _CUR_SEC_ID="s19"
    print_hdr "19. SECURITY CHECKS"
    [ "${OPT_HTML}" -eq 1 ] && html_sec_start "${_CUR_SEC_ID}" "19. Security Checks"

    # DBA-role users (non-default)
    _DBAUSRS=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_ROLE_PRIVS
 WHERE GRANTED_ROLE='DBA'
   AND GRANTEE NOT IN ('SYS','SYSTEM','DBA','AQ_ADMINISTRATOR_ROLE',
                       'DV_ACCTMGR','WMSYS');")
    log "  Non-default DBA-role grantees: ${_DBAUSRS:-0}"
    if [ "${_DBAUSRS:-0}" -gt 3 ]; then
        result WARN "${_DBAUSRS} users with DBA role — review required"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "${_DBAUSRS} users with DBA role — review"
    else
        result PASS "DBA role grants within normal range (${_DBAUSRS})"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "DBA role grants: ${_DBAUSRS}"
    fi

    # Users with SYSDBA/SYSOPER from password file
    _SYSDBAUSRS=$(sqm "${ORACLE_SID}" "${ORACLE_HOME}" \
"COL USERNAME FORMAT A25
COL SYSDBA   FORMAT A6
COL SYSOPER  FORMAT A7" \
"SELECT USERNAME,SYSDBA,SYSOPER FROM V\$PWFILE_USERS ORDER BY USERNAME;")
    logsep; log "  Password file users (SYSDBA/SYSOPER):"; printf "%s\n" "${_SYSDBAUSRS}" | tee -a "${LOG_FILE}"
    [ "${OPT_HTML}" -eq 1 ] && html_pre "${_SYSDBAUSRS}"

    # Default passwords check (11g+ feature table)
    _DEFPWD=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_USERS_WITH_DEFPWD WHERE USERNAME NOT IN
 ('APEX_PUBLIC_USER','FLOWS_FILES','ANONYMOUS','XDB') AND ROWNUM<=20;" 2>/dev/null)
    if [ "${_DEFPWD:-0}" -gt 0 ]; then
        result FAIL "${_DEFPWD} user(s) using default passwords — SECURITY RISK"
        [ "${OPT_HTML}" -eq 1 ] && html_res FAIL "${_DEFPWD} user(s) using default passwords"
    else
        result PASS "No users with default passwords detected"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "No users with default passwords"
    fi

    # Audit settings
    _AUDITTRAIL=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT VALUE FROM V\$PARAMETER WHERE NAME='audit_trail';")
    _UNIFIEDAUD=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT VALUE FROM V\$PARAMETER WHERE NAME='unified_audit_trail';")
    log "  Audit Trail: ${_AUDITTRAIL:-N/A}  Unified Audit: ${_UNIFIEDAUD:-N/A}"
    [ "${OPT_HTML}" -eq 1 ] && html_res INFO "Audit Trail: ${_AUDITTRAIL:-N/A} | Unified Audit: ${_UNIFIEDAUD:-N/A}"

    # Public execute on UTL packages
    _UTLPUB=$(sqv "${ORACLE_SID}" "${ORACLE_HOME}" \
"SELECT COUNT(*) FROM DBA_TAB_PRIVS
 WHERE GRANTEE='PUBLIC' AND PRIVILEGE='EXECUTE'
   AND OWNER='SYS'
   AND TABLE_NAME IN ('UTL_FILE','UTL_HTTP','UTL_SMTP','UTL_TCP',
                      'DBMS_ADVISOR','DBMS_SCHEDULER','DBMS_JOB',
                      'DBMS_LOB','DBMS_SQL');")
    if [ "${_UTLPUB:-0}" -gt 0 ]; then
        result WARN "${_UTLPUB} sensitive SYS package(s) granted EXECUTE to PUBLIC"
        [ "${OPT_HTML}" -eq 1 ] && html_res WARN "${_UTLPUB} sensitive package(s) granted to PUBLIC"
    else
        result PASS "No sensitive SYS packages granted to PUBLIC"
        [ "${OPT_HTML}" -eq 1 ] && html_res PASS "No sensitive packages granted to PUBLIC"
    fi
    [ "${OPT_HTML}" -eq 1 ] && html_sec_end

    # =========================================================================
    # PER-DB SUMMARY
    # =========================================================================
    _TOTAL_CHKS=$((ISSUES + WARNINGS))
    _PP=0; _PF=0; _PW=0
    [ "${ISSUES:-0}"   -gt 0 ] && _PF=$(awk -v f="${ISSUES}"   -v t="$((_TOTAL_CHKS+1))" 'BEGIN{printf "%.0f",f/t*100}')
    [ "${WARNINGS:-0}" -gt 0 ] && _PW=$(awk -v w="${WARNINGS}" -v t="$((_TOTAL_CHKS+1))" 'BEGIN{printf "%.0f",w/t*100}')
    _PP=$((100 - _PF - _PW)); [ "${_PP}" -lt 0 ] && _PP=0

    print_hdr "SUMMARY — ${ORACLE_SID}"
    log "  Critical (FAIL) : ${ISSUES}"
    log "  Warnings (WARN) : ${WARNINGS}"
    log "  Log             : ${LOG_FILE}"
    printf "\n  ${CB}Health:${CZ}  ${CG}PASS %d%%${CZ}  ${CY}WARN %d%%${CZ}  ${CR}FAIL %d%%${CZ}\n\n" \
        "${_PP}" "${_PW}" "${_PF}"

    if [ "${ISSUES}" -gt 0 ]; then
        result FAIL "${ORACLE_SID} — ${ISSUES} CRITICAL issue(s), ${WARNINGS} warning(s)"
    elif [ "${WARNINGS}" -gt 0 ]; then
        result WARN "${ORACLE_SID} — ${WARNINGS} warning(s) — review recommended"
    else
        result PASS "${ORACLE_SID} — All checks PASSED"
    fi

    # HTML close panel
    [ "${OPT_HTML}" -eq 1 ] && html_panel_end

    # Write counters for master accumulation
    printf "%d" "${ISSUES}"   > "${LOG_DIR}/.hc_i_${ORACLE_SID}"
    printf "%d" "${WARNINGS}" > "${LOG_DIR}/.hc_w_${ORACLE_SID}"
    printf "%s" "${LOG_FILE}" > "${LOG_DIR}/.hc_l_${ORACLE_SID}"
}

# ===========================================================================
# EMAIL — format matching your mailx usage pattern from screenshot
# mailx -s "SUBJECT" -a "ATTACHMENT" RECIPIENT
# ===========================================================================
send_email() {
    _TO="$1"; _SUBJ="$2"; _FILE="$3"
    _SENT=0
    if command -v mutt >/dev/null 2>&1; then
        echo "Oracle 19c Health Check Report attached." \
            | mutt -s "${_SUBJ}" -a "${_FILE}" -- "${_TO}" && _SENT=1
    fi
    if [ "${_SENT}" -eq 0 ] && command -v mailx >/dev/null 2>&1; then
        # Format: mailx -s "SUBJECT" -a "FILE" RECIPIENT
        echo "Oracle 19c Health Check Report for $(uname -n) attached for $(date +'%d-%b-%Y')" \
            | mailx -s "${_SUBJ}" -a "${_FILE}" "${_TO}" && _SENT=1
    fi
    if [ "${_SENT}" -eq 0 ] && command -v sendmail >/dev/null 2>&1; then
        {
        printf "To: %s\n" "${_TO}"
        printf "Subject: %s\n" "${_SUBJ}"
        printf "MIME-Version: 1.0\n"
        printf "Content-Type: text/html; charset=UTF-8\n\n"
        cat "${_FILE}"
        } | sendmail -t && _SENT=1
    fi
    return $((1-_SENT))
}

# ===========================================================================
# MAIN
# ===========================================================================
ensure_log_dir
locate_oratab

# Clean up any stale temp files from previous runs
rm -f "${LOG_DIR}"/.hc_i_* "${LOG_DIR}"/.hc_w_* "${LOG_DIR}"/.hc_l_* \
      "${LOG_DIR}"/.hc_sec_* "${LOG_DIR}"/.hc_sidmap_* 2>/dev/null

if [ -n "${OPT_SID}" ]; then
    SID_LIST="${OPT_SID}"
else
    SID_LIST=$(discover_sids)
fi

if [ -z "${SID_LIST}" ]; then
    printf "${CR}ERROR: No eligible Oracle instances found.\n${CZ}"
    printf "  Excluded: +ASM*, *APX*, *MGMT*\n"
    printf "  Use -s SID to target a specific instance.\n"
    exit 1
fi

DB_COUNT=$(printf '%s\n' "${SID_LIST}" | grep -c '[^[:space:]]')

# -- Console banner --
printf "\n${CB}${CC}"
printf "╔═══════════════════════════════════════════════════════════════════╗\n"
printf "║   Oracle 19c Comprehensive Database Health Check  v3.0           ║\n"
printf "║   Host   : %-56s║\n" "$(uname -n)"
printf "║   OS     : %-56s║\n" "$(uname -s) $(uname -r)"
printf "║   oratab : %-56s║\n" "${ORATAB}"
printf "║   LogDir : %-56s║\n" "${LOG_DIR}"
printf "║   HTML   : %-56s║\n" "$([ ${OPT_HTML} -eq 1 ] && printf 'YES  => %s' "${HTML_REPORT}" || echo 'NO')"
printf "║   Email  : %-56s║\n" "${OPT_EMAIL:-none}"
printf "╚═══════════════════════════════════════════════════════════════════╝\n"
printf "${CZ}\n"
printf "${CB}  Instances to check (${DB_COUNT}):${CZ}\n"
printf '%s\n' "${SID_LIST}" | while IFS= read -r _S; do
    _OH=$(get_oracle_home "${_S}")
    printf "    ${CC}► %-15s${CZ}  %s\n" "${_S}" "${_OH:-NOT IN ORATAB}"
done
printf "\n"

# -- HTML initialise (before per-DB runs so panels can append) --
if [ "${OPT_HTML}" -eq 1 ]; then
    html_init
    html_page_header \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$(uname -n)" \
        "$(uname -s) $(uname -r)" \
        "${ORATAB}" \
        "${OPT_EMAIL}"
fi

# -- Run per-DB checks --
_FIRST=1
printf '%s\n' "${SID_LIST}" | while IFS= read -r SID; do
    [ -z "${SID}" ] && continue
    OH=$(get_oracle_home "${SID}")
    if [ -z "${OH}" ]; then
        printf "${CY}  [WARN]  SID '%s' not found in %s — skipping${CZ}\n" "${SID}" "${ORATAB}"
        continue
    fi
    if [ ! -d "${OH}" ]; then
        printf "${CR}  [FAIL]  ORACLE_HOME '%s' does not exist — skipping %s${CZ}\n" "${OH}" "${SID}"
        continue
    fi
    run_hc "${SID}" "${OH}" "${_FIRST}"
    _FIRST=0
done

# -- Accumulate master totals --
MASTER_ISSUES=0; MASTER_WARNINGS=0; MASTER_PASS=0; MASTER_RAN=0
for _IF in "${LOG_DIR}"/.hc_i_*; do
    [ -f "${_IF}" ] || continue
    _FV=$(cat "${_IF}"); _SN=$(printf '%s' "${_IF}" | sed 's|.*\.hc_i_||')
    _WF="${LOG_DIR}/.hc_w_${_SN}"; _WV=0; [ -f "${_WF}" ] && _WV=$(cat "${_WF}")
    MASTER_ISSUES=$((MASTER_ISSUES+_FV))
    MASTER_WARNINGS=$((MASTER_WARNINGS+_WV))
    [ "${_FV}" -eq 0 ] && [ "${_WV}" -eq 0 ] && MASTER_PASS=$((MASTER_PASS+1))
    MASTER_RAN=$((MASTER_RAN+1))
done

# -- HTML: scorecards, db-grid, tabs, detail area --
if [ "${OPT_HTML}" -eq 1 ]; then
    html_scorecards "${MASTER_RAN}" "${MASTER_PASS}" "${MASTER_WARNINGS}" "${MASTER_ISSUES}"

    # DB summary cards
    html_db_grid_start
    _F1=1
    printf '%s\n' "${SID_LIST}" | while IFS= read -r SID; do
        [ -z "${SID}" ] && continue
        OH=$(get_oracle_home "${SID}"); [ -z "${OH}" ] && continue
        _F=0; _W=0
        [ -f "${LOG_DIR}/.hc_i_${SID}" ] && _F=$(cat "${LOG_DIR}/.hc_i_${SID}")
        [ -f "${LOG_DIR}/.hc_w_${SID}" ] && _W=$(cat "${LOG_DIR}/.hc_w_${SID}")
        html_db_card "${SID}" "${_F}" "${_W}" "${OH}"
    done
    html_db_grid_end

    # ── TAB BAR (sticky, rendered BEFORE detail area) ──
    html_tabbar_start
    _F1=1
    printf '%s\n' "${SID_LIST}" | while IFS= read -r SID; do
        [ -z "${SID}" ] && continue
        OH=$(get_oracle_home "${SID}"); [ -z "${OH}" ] && continue
        _F=0; _W=0
        [ -f "${LOG_DIR}/.hc_i_${SID}" ] && _F=$(cat "${LOG_DIR}/.hc_i_${SID}")
        [ -f "${LOG_DIR}/.hc_w_${SID}" ] && _W=$(cat "${LOG_DIR}/.hc_w_${SID}")
        html_tab_btn "${SID}" "${_F}" "${_W}" "${_F1}"
        _F1=0
    done
    html_tabbar_end

    html_detail_start
    # Re-inject pre-generated DB panels from temp file
    for _PF in "${LOG_DIR}"/.hc_panel_*; do
        [ -f "${_PF}" ] && cat "${_PF}" >> "${H}"
    done
    html_detail_end
    html_footer
fi

# -- Clean temp files --
rm -f "${LOG_DIR}"/.hc_i_* "${LOG_DIR}"/.hc_w_* "${LOG_DIR}"/.hc_l_* \
      "${LOG_DIR}"/.hc_sec_* "${LOG_DIR}"/.hc_panel_* "${LOG_DIR}"/.hc_sidmap_* 2>/dev/null

# -- Console master summary --
_MPP=0
[ "${MASTER_RAN}" -gt 0 ] && \
    _MPP=$(awk -v p="${MASTER_PASS}" -v t="${MASTER_RAN}" 'BEGIN{printf "%.0f",p/t*100}')
_MFF=0
[ "${MASTER_RAN}" -gt 0 ] && \
    _MFF=$(awk -v f="${MASTER_ISSUES}" -v t="${MASTER_RAN}" 'BEGIN{printf "%.0f",f/t*100}')

printf "\n${CB}${CC}"
printf "╔═══════════════════════════════════════════════════════════════════╗\n"
printf "║                    MASTER RUN SUMMARY                            ║\n"
printf "╚═══════════════════════════════════════════════════════════════════╝${CZ}\n\n"
printf "  %-28s : %s\n"   "Host"                 "$(uname -n)"
printf "  %-28s : %s\n"   "Completed"            "$(date '+%Y-%m-%d %H:%M:%S')"
printf "  %-28s : %d\n"   "Databases Checked"    "${MASTER_RAN}"
printf "  %-28s : %s%%\n" "DB Pass Rate"         "${_MPP}"
printf "  %-28s : %d\n"   "Total CRITICAL (FAIL)""${MASTER_ISSUES}"
printf "  %-28s : %d\n"   "Total WARNINGS"       "${MASTER_WARNINGS}"
[ "${OPT_HTML}" -eq 1 ] && printf "  %-28s : %s\n" "HTML Report" "${HTML_REPORT}"
printf "  %-28s : %s\n"   "Master Log"           "${MASTER_LOG}"
printf "\n"

# Per-DB table
printf "  ${CB}%-15s  %6s  %6s  %6s  %-10s${CZ}\n" "SID" "FAIL" "WARN" "PASS%" "STATUS"
printf "  %s\n" "-------------------------------------------------------------"
printf '%s\n' "${SID_LIST}" | while IFS= read -r SID; do
    [ -z "${SID}" ] && continue
    OH=$(get_oracle_home "${SID}"); [ -z "${OH}" ] && continue
    _F=0; _W=0
    [ -f "${LOG_DIR}/.hc_i_${SID}" ] && _F=$(cat "${LOG_DIR}/.hc_i_${SID}") 2>/dev/null
    [ -f "${LOG_DIR}/.hc_w_${SID}" ] && _W=$(cat "${LOG_DIR}/.hc_w_${SID}") 2>/dev/null
    _D=$((_F+_W)); _P=$(awk -v d="${_D}" 'BEGIN{if(d==0)print 100;else print 0}')
    if   [ "${_F:-0}" -gt 0 ]; then _R="${CR}CRITICAL${CZ}"
    elif [ "${_W:-0}" -gt 0 ]; then _R="${CY}WARNING${CZ}"
    else                            _R="${CG}PASS${CZ}"; fi
    printf "  %-15s  %6d  %6d  %5d%%  %b\n" "${SID}" "${_F:-0}" "${_W:-0}" "${_P}" "${_R}"
done

printf "\n"
if [ "${MASTER_ISSUES}" -gt 0 ]; then
    printf "  ${CR}${CB}[CRITICAL]${CZ} ${MASTER_ISSUES} critical issue(s) across ${MASTER_RAN} DB(s)\n"
elif [ "${MASTER_WARNINGS}" -gt 0 ]; then
    printf "  ${CY}${CB}[WARNING]${CZ}  ${MASTER_WARNINGS} warning(s) — review recommended\n"
else
    printf "  ${CG}${CB}[ALL PASS]${CZ} All ${MASTER_RAN} database(s) passed\n"
fi

# ── EMAIL (using mailx -s "SUBJECT" -a "FILE" RECIPIENT) ──
if [ -n "${OPT_EMAIL}" ] && [ "${OPT_HTML}" -eq 1 ] && [ -f "${HTML_REPORT}" ]; then
    printf "\n  Sending report to %s ...\n" "${OPT_EMAIL}"
    _SUBJ="Oracle DB Health Check for $(uname -n) attached for $(date +'%d-%b-%Y')"
    if   [ "${MASTER_ISSUES}"   -gt 0 ]; then _SUBJ="[CRITICAL] ${_SUBJ} — ${MASTER_ISSUES} issue(s)"
    elif [ "${MASTER_WARNINGS}" -gt 0 ]; then _SUBJ="[WARNING]  ${_SUBJ} — ${MASTER_WARNINGS} warning(s)"
    else                                      _SUBJ="[ALL PASS] ${_SUBJ}"; fi
    if send_email "${OPT_EMAIL}" "${_SUBJ}" "${HTML_REPORT}"; then
        printf "  ${CG}Email sent OK${CZ}\n"
    else
        printf "  ${CY}Email failed — report at: %s${CZ}\n" "${HTML_REPORT}"
    fi
elif [ -n "${OPT_EMAIL}" ] && [ "${OPT_HTML}" -eq 0 ]; then
    printf "\n  ${CY}[WARN] -e requires -H. Use: -H -e %s${CZ}\n" "${OPT_EMAIL}"
fi

printf "\n"
exit ${MASTER_ISSUES}
