#!/usr/bin/env bash
#==============================================================================
# send_tbsp_report.sh
#
# Emails the CSV(s) and HTML file produced by tbsp_report.sh as attachments.
# The email body is short (DB name, run time, RED/AMBER/GREEN counts, and a
# one-line "needs attention soonest" highlight) - the full HTML is attached,
# never inlined into the body.
#
# Portable across Solaris and Linux: builds a MIME multipart message by hand
# and hands it to a sendmail-compatible binary, rather than depending on
# mutt/mailx attachment flags (which vary a lot between platforms/versions).
#
# Usage: send_tbsp_report.sh -r recipients [options]
#   -r RECIPIENTS   Comma-separated recipient list (required)
#   -d DIR          Directory to search for report files (default: .)
#   -N TAG          Tag to match filenames with and to include in the subject
#                    (must match the -N used when tbsp_report.sh ran, if any)
#   -t CSV_FILE     Explicit tablespace CSV path (overrides auto-detection)
#   -g CSV_FILE     Explicit ASM diskgroup CSV path (overrides auto-detection)
#   -w HTML_FILE    Explicit HTML report path (overrides auto-detection)
#   -s SUBJECT      Subject prefix (default: "Oracle Tablespace Capacity Report")
#   -f FROM_ADDR    From address (default: <user>@<hostname>)
#   -h              Show this help and exit
#
# Without -t/-g/-w, the most recently modified file in -d matching the
# tbsp_report.sh naming convention (and the -N tag, if given) is used for
# each part. Run tbsp_report.sh first - this script only sends what already
# exists on disk.
#
# Exit codes: 0 ok, 1 usage/arg error, 2 no matching files found,
#             3 mail send failed.
#==============================================================================
set -u

SCRIPT_NAME=$(basename "$0")

RECIPIENTS=""
SEARCH_DIR="."
TAG=""
CSV_OVERRIDE=""
ASM_CSV_OVERRIDE=""
HTML_OVERRIDE=""
SUBJECT_PREFIX="Oracle Tablespace Capacity Report"
FROM_ADDR=""

usage() {
    sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
}

ts_now() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s] %s\n' "$(ts_now)" "$*" >&2; }
info() { log "INFO:  $*"; }
warn() { log "WARN:  $*"; }
err()  { log "ERROR: $*"; }
die()  { err "$1"; exit "${2:-2}"; }

WORKDIR=""
cleanup() { [ -n "${WORKDIR:-}" ] && [ -d "${WORKDIR:-}" ] && rm -rf "$WORKDIR" 2>/dev/null; }
trap cleanup EXIT INT TERM

make_workdir() {
    _base="${TMPDIR:-/tmp}"
    _dir="${_base}/send_tbsp_report.$$.$(date +%Y%m%d_%H%M%S)"
    mkdir -m 700 "$_dir" 2>/dev/null || die "Could not create work directory '$_dir'" 2
    WORKDIR="$_dir"
}

# ===========================================================================
# Argument parsing
# ===========================================================================
while getopts ":r:d:N:t:g:w:s:f:h" opt; do
    case "$opt" in
        r) RECIPIENTS=$OPTARG ;;
        d) SEARCH_DIR=$OPTARG ;;
        N) TAG=$OPTARG ;;
        t) CSV_OVERRIDE=$OPTARG ;;
        g) ASM_CSV_OVERRIDE=$OPTARG ;;
        w) HTML_OVERRIDE=$OPTARG ;;
        s) SUBJECT_PREFIX=$OPTARG ;;
        f) FROM_ADDR=$OPTARG ;;
        h) usage; exit 0 ;;
        \?) printf 'Unknown option: -%s\n\n' "$OPTARG" >&2; usage; exit 1 ;;
        :) printf 'Option -%s requires an argument\n\n' "$OPTARG" >&2; usage; exit 1 ;;
    esac
done

[ -z "$RECIPIENTS" ] && { printf -- '-r RECIPIENTS is required.\n\n' >&2; usage; exit 1; }
[ -d "$SEARCH_DIR" ] || die "Search directory '$SEARCH_DIR' does not exist." 1
[ -z "$FROM_ADDR" ] && FROM_ADDR="$(id -un 2>/dev/null || echo oracle)@$(hostname 2>/dev/null || echo localhost)"

# ===========================================================================
# Find the most-recently-modified file in SEARCH_DIR matching a glob
# pattern. Plain shell glob + stat, deliberately avoiding 'find -maxdepth'
# since that flag isn't reliably present on older Solaris find(1).
# ===========================================================================
file_mtime() {
    stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo 0
}

find_latest() {
    _pattern=$1
    _best=""
    _best_mtime=-1
    for f in "$SEARCH_DIR"/$_pattern; do
        [ -e "$f" ] || continue
        _mtime=$(file_mtime "$f")
        case "$_mtime" in
            ''|*[!0-9]*) _mtime=0 ;;
        esac
        if [ "$_mtime" -gt "$_best_mtime" ]; then _best_mtime=$_mtime; _best=$f; fi
    done
    [ -n "$_best" ] && printf '%s\n' "$_best"
}

TAG_GLOB="*"
[ -n "$TAG" ] && TAG_GLOB="*_${TAG}"

CSV_FILE="$CSV_OVERRIDE"
[ -z "$CSV_FILE" ] && CSV_FILE=$(find_latest "*_tbsp_capacity_${TAG_GLOB}.csv")
[ -z "$CSV_FILE" ] && die "No tablespace CSV found in '$SEARCH_DIR' (looked for *_tbsp_capacity_${TAG_GLOB}.csv). Run tbsp_report.sh first, or pass -t explicitly." 2
[ -r "$CSV_FILE" ] || die "Tablespace CSV '$CSV_FILE' is not readable." 2

ASM_CSV_FILE="$ASM_CSV_OVERRIDE"
[ -z "$ASM_CSV_FILE" ] && ASM_CSV_FILE=$(find_latest "*_asm_diskgroup_${TAG_GLOB}.csv")
if [ -n "$ASM_CSV_FILE" ] && [ ! -r "$ASM_CSV_FILE" ]; then
    warn "ASM CSV '$ASM_CSV_FILE' is not readable - sending without it."
    ASM_CSV_FILE=""
fi

HTML_FILE="$HTML_OVERRIDE"
[ -z "$HTML_FILE" ] && HTML_FILE=$(find_latest "*_capacity_report_${TAG_GLOB}.html")
[ -z "$HTML_FILE" ] && die "No HTML report found in '$SEARCH_DIR' (looked for *_capacity_report_${TAG_GLOB}.html). Run tbsp_report.sh first, or pass -w explicitly." 2
[ -r "$HTML_FILE" ] || die "HTML report '$HTML_FILE' is not readable." 2

info "Tablespace CSV: $CSV_FILE"
[ -n "$ASM_CSV_FILE" ] && info "ASM CSV:        $ASM_CSV_FILE"
info "HTML report:    $HTML_FILE"

make_workdir

# ===========================================================================
# Build short plain-text highlights from the tablespace CSV (independently
# of tbsp_report.sh - this script is meant to also work standalone against
# any CSV matching the documented column schema).
# ===========================================================================
cat > "${WORKDIR}/csvlib.awk" <<'AWKEOF'
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
AWKEOF

cat > "${WORKDIR}/highlights.awk" <<'AWKEOF'
NR == 1 {
    ncols = csv_split($0, hdr)
    for (i = 1; i <= ncols; i++) colidx[hdr[i]] = i
    next
}
$0 == "" { next }
{
    n = csv_split($0, f)
    if (dbname == "") dbname = f[colidx["db_name"]]
    pdb   = f[colidx["pdb_name"]]
    tsn   = f[colidx["tablespace_name"]]
    color = f[colidx["color"]]
    sw_s  = f[colidx["sustainable_weeks"]]
    total++
    cnt[color]++
    if (sw_s != "") {
        m++
        sw_val[m] = sw_s + 0
        sw_label[m] = pdb " / " tsn " (" color ")"
    }
}
END {
    print "DB_NAME=" dbname
    print "TS_TOTAL=" (total + 0)
    print "TS_RED=" (cnt["RED"] + 0)
    print "TS_AMBER=" (cnt["AMBER"] + 0)
    print "TS_GREEN=" (cnt["GREEN"] + 0)
    for (pick = 1; pick <= 3 && pick <= m; pick++) {
        best = -1
        for (i = 1; i <= m; i++) {
            if (used[i]) continue
            if (best == -1 || sw_val[i] < sw_val[best]) best = i
        }
        if (best == -1) break
        used[best] = 1
        print "TOP" pick "=" sw_label[best] " - " sw_val[best] " wks"
    }
}
AWKEOF

HIGHLIGHTS="${WORKDIR}/highlights.txt"
awk -f "${WORKDIR}/csvlib.awk" -f "${WORKDIR}/highlights.awk" "$CSV_FILE" > "$HIGHLIGHTS"

DB_NAME=""; TS_TOTAL=0; TS_RED=0; TS_AMBER=0; TS_GREEN=0
TOP1=""; TOP2=""; TOP3=""
while IFS='=' read -r _k _v; do
    case "$_k" in
        DB_NAME)  DB_NAME=$_v ;;
        TS_TOTAL) TS_TOTAL=$_v ;;
        TS_RED)   TS_RED=$_v ;;
        TS_AMBER) TS_AMBER=$_v ;;
        TS_GREEN) TS_GREEN=$_v ;;
        TOP1)     TOP1=$_v ;;
        TOP2)     TOP2=$_v ;;
        TOP3)     TOP3=$_v ;;
    esac
done < "$HIGHLIGHTS"
[ -z "$DB_NAME" ] && DB_NAME="(unknown)"

ASM_LINE=""
if [ -n "$ASM_CSV_FILE" ]; then
    ASM_COUNTS=$(awk -F',' 'NR>1{gsub(/"/,"");split($0,f,",");c[f[length(f)]]++} END{printf "%d/%d/%d", c["RED"]+0,c["AMBER"]+0,c["GREEN"]+0}' "$ASM_CSV_FILE")
    ASM_LINE="ASM diskgroups (RED/AMBER/GREEN): ${ASM_COUNTS}"
fi

file_mtime_human() {
    _r=$(stat -c '%y' "$1" 2>/dev/null)
    if [ -n "$_r" ]; then printf '%s\n' "${_r%%.*}"; return; fi
    _r=$(stat -f '%Sm' "$1" 2>/dev/null)
    if [ -n "$_r" ]; then printf '%s\n' "$_r"; return; fi
    printf 'unknown\n'
}
REPORT_TIME=$(file_mtime_human "$HTML_FILE")
HOST_NAME=$(hostname 2>/dev/null || echo unknown)

TAG_SUBJ=""
[ -n "$TAG" ] && TAG_SUBJ=" [$TAG]"
SUBJECT="${SUBJECT_PREFIX} - ${DB_NAME}${TAG_SUBJ} - $(date '+%Y-%m-%d')"

BODY_FILE="${WORKDIR}/body.txt"
{
    printf '%s\n\n' "${SUBJECT_PREFIX} for ${DB_NAME}"
    printf 'Host:           %s\n' "$HOST_NAME"
    printf 'Report file ts: %s\n' "$REPORT_TIME"
    printf 'Tablespaces:    %s total - RED=%s AMBER=%s GREEN=%s\n' "$TS_TOTAL" "$TS_RED" "$TS_AMBER" "$TS_GREEN"
    [ -n "$ASM_LINE" ] && printf '%s\n' "$ASM_LINE"
    if [ -n "$TOP1" ]; then
        printf '\nNeeds attention soonest (lowest estimated weeks until full):\n'
        [ -n "$TOP1" ] && printf '  1. %s\n' "$TOP1"
        [ -n "$TOP2" ] && printf '  2. %s\n' "$TOP2"
        [ -n "$TOP3" ] && printf '  3. %s\n' "$TOP3"
    fi
    printf '\nFull detail is in the attached CSV/HTML files. Open the HTML report in a browser for sortable, filterable tables.\n'
} > "$BODY_FILE"

info "Subject: $SUBJECT"

# ===========================================================================
# Base64 encoding with a fallback chain: base64 -> openssl base64 -> uuencode.
# Solaris boxes without GNU coreutils may lack a standalone 'base64'.
# ===========================================================================
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

# ===========================================================================
# MIME construction
# ===========================================================================
BOUNDARY="----=_TBSPRPT_$(date +%s)_$$"

mime_attach() {
    _path=$1; _ctype=$2; _name=$3
    printf -- '--%s\r\n' "$BOUNDARY"
    printf 'Content-Type: %s; name="%s"\r\n' "$_ctype" "$_name"
    printf 'Content-Disposition: attachment; filename="%s"\r\n' "$_name"
    printf 'Content-Transfer-Encoding: base64\r\n\r\n'
    b64encode "$_path" || { err "base64 encoding failed for $_path (no base64/openssl/uuencode found)"; return 1; }
    printf '\r\n'
}

MSG_FILE="${WORKDIR}/message.eml"
{
    printf 'From: %s\r\n' "$FROM_ADDR"
    printf 'To: %s\r\n' "$RECIPIENTS"
    printf 'Subject: %s\r\n' "$SUBJECT"
    printf 'MIME-Version: 1.0\r\n'
    printf 'Content-Type: multipart/mixed; boundary="%s"\r\n' "$BOUNDARY"
    printf '\r\n'
    printf 'This is a multi-part message in MIME format.\r\n'
    printf -- '--%s\r\n' "$BOUNDARY"
    printf 'Content-Type: text/plain; charset=us-ascii\r\n'
    printf 'Content-Transfer-Encoding: 7bit\r\n\r\n'
    cat "$BODY_FILE"
    printf '\r\n'
    mime_attach "$CSV_FILE" "text/csv" "$(basename "$CSV_FILE")"
    [ -n "$ASM_CSV_FILE" ] && mime_attach "$ASM_CSV_FILE" "text/csv" "$(basename "$ASM_CSV_FILE")"
    mime_attach "$HTML_FILE" "text/html" "$(basename "$HTML_FILE")"
    printf -- '--%s--\r\n' "$BOUNDARY"
} > "$MSG_FILE"

# ===========================================================================
# Dispatch via a sendmail-compatible binary (works the same on Solaris and
# Linux; avoids depending on mutt/mailx attachment-flag differences).
# Override with the MAILER_BIN environment variable if needed.
# ===========================================================================
find_mailer() {
    if [ -n "${MAILER_BIN:-}" ] && [ -x "${MAILER_BIN}" ]; then printf '%s\n' "$MAILER_BIN"; return 0; fi
    for c in /usr/sbin/sendmail /usr/lib/sendmail /opt/csw/sbin/sendmail; do
        [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    _c=$(command -v sendmail 2>/dev/null)
    [ -n "$_c" ] && [ -x "$_c" ] && { printf '%s\n' "$_c"; return 0; }
    return 1
}

MAILER=$(find_mailer) || die "No sendmail-compatible binary found (checked \$MAILER_BIN, /usr/sbin/sendmail, /usr/lib/sendmail, and PATH). Set MAILER_BIN=/path/to/sendmail to override." 3
info "Using mailer: $MAILER"

"$MAILER" -t -oi < "$MSG_FILE"
RC=$?
if [ $RC -ne 0 ]; then
    die "Mail send failed (mailer exit code $RC)." 3
fi
info "Mail sent to: $RECIPIENTS"
exit 0
