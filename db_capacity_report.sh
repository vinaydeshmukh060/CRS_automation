#!/bin/bash
# ==============================================================================
# Script: db_capacity_report.sh
# Purpose: Oracle 19c+ Tablespace & ASM Capacity Report (Multi-Instance/Host-wide)
# OS Support: Linux, Solaris (POSIX compliant bash & awk)
# ==============================================================================

# Default Variables
ID_NAME="$(hostname)_DB_Report"
EMAIL_TO=""
SINGLE_INSTANCE=""

# Parse command line options
while getopts "N:e:i:" opt; do
  case $opt in
    N) ID_NAME="$OPTARG" ;;
    e) EMAIL_TO="$OPTARG" ;;
    i) SINGLE_INSTANCE="$OPTARG" ;;
    *) echo "Usage: $0 [-N identifier] [-e email_address] [-i specific_instance]" >&2; exit 1 ;;
  esac
done

TIMESTAMP=$(date +%Y%m%d_%H%M)
PREFIX="Capacity_${ID_NAME}_${TIMESTAMP}"
TS_CSV="${PREFIX}_tablespace.csv"
ASM_CSV="${PREFIX}_asm.csv"
HTML_OUT="${PREFIX}.html"
SQL_FILE="/tmp/run_report_$$.sql"

# Clear/Initialize master CSVs
> "$TS_CSV"
> "$ASM_CSV"

# ------------------------------------------------------------------------------
# 1. Instance Auto-Discovery & Environment Setup
# ------------------------------------------------------------------------------
if [ -n "$SINGLE_INSTANCE" ]; then
    TARGET_SIDS="$SINGLE_INSTANCE"
    echo "Targeting specific instance: $TARGET_SIDS"
else
    # Find PMON processes, extract SID, exclude asm, apex, mgmt_
    TARGET_SIDS=$(ps -ef | grep '[p]mon_' | sed 's/.*pmon_//g' | grep -v -i -E 'asm|apex|mgmt_')
    echo "Discovered instances for reporting: $(echo $TARGET_SIDS | tr '\n' ' ')"
fi

if [ -z "$TARGET_SIDS" ]; then
    echo "Error: No valid Oracle instances found or specified." >&2
    exit 1
fi

set_oracle_env() {
    local sid=$1
    export ORACLE_SID=$sid
    export ORAENV_ASK=NO
    
    # Try standard oraenv locations
    if command -v oraenv >/dev/null 2>&1; then
        . oraenv > /dev/null 2>&1
    elif [ -f /usr/local/bin/oraenv ]; then
        . /usr/local/bin/oraenv > /dev/null 2>&1
    else
        # Fallback to parsing oratab (Linux/Solaris paths)
        local oratab_file=""
        [ -f /etc/oratab ] && oratab_file="/etc/oratab"
        [ -f /var/opt/oracle/oratab ] && oratab_file="/var/opt/oracle/oratab"
        
        if [ -n "$oratab_file" ]; then
            export ORACLE_HOME=$(grep "^${sid}:" "$oratab_file" | cut -d: -f2)
            export PATH=$ORACLE_HOME/bin:$PATH
        else
            echo "Warning: Could not source environment for $sid."
        fi
    fi
}

# ------------------------------------------------------------------------------
# 2. Define the Oracle SQL Query
# ------------------------------------------------------------------------------
cat << 'EOF' > "$SQL_FILE"
SET MARKUP CSV ON DELIMITER ',' QUOTE OFF
SET FEEDBACK OFF HEADING ON PAGESIZE 0 LINESIZE 32000 TRIMSPOOL ON
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

-- Tablespace Report
SPOOL __ts_output.csv
WITH db_info AS ( SELECT name AS db_name FROM v$database ),
ts_current AS (
    SELECT ts.con_id, ts.tablespace_name, COUNT(df.file_id) AS datafile_count,
           ROUND(SUM(df.bytes) / 1024/1024/1024, 2) AS allocated_gb,
           ROUND((SUM(df.bytes) - NVL(MAX(free.free_bytes), 0)) / 1024/1024/1024, 2) AS used_gb,
           ROUND(NVL(MAX(free.free_bytes), 0) / 1024/1024/1024, 2) AS free_gb, ts.block_size
    FROM cdb_tablespaces ts
    JOIN cdb_data_files df ON ts.tablespace_name = df.tablespace_name AND ts.con_id = df.con_id
    LEFT JOIN ( SELECT con_id, tablespace_name, SUM(bytes) AS free_bytes FROM cdb_free_space GROUP BY con_id, tablespace_name ) free 
    ON free.tablespace_name = ts.tablespace_name AND free.con_id = ts.con_id
    GROUP BY ts.con_id, ts.tablespace_name, ts.block_size
),
ts_with_capacity AS (
    SELECT con_id, tablespace_name, datafile_count, allocated_gb, used_gb, free_gb,
           CASE WHEN datafile_count < 1023 THEN (1023 - datafile_count) * 32 ELSE 0 END AS addable_gb
    FROM ts_current
),
ts_snap AS (
    SELECT v.con_id, v.name AS tablespace_name, TRUNC(s.begin_interval_time, 'IW') AS week_start_date,
           s.begin_interval_time AS snap_time, (u.tablespace_usedsize * dt.block_size) AS used_bytes
    FROM dba_hist_tbspc_space_usage u
    JOIN dba_hist_snapshot s ON s.snap_id = u.snap_id AND s.dbid = u.dbid AND s.instance_number = u.instance_number
    JOIN v$tablespace v ON v.ts# = u.tablespace_id AND v.con_id = u.con_id
    JOIN cdb_tablespaces dt ON dt.tablespace_name = v.name AND dt.con_id = v.con_id
    WHERE s.end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(26*7, 'DAY')
),
daily_last_snap AS (
    SELECT con_id, tablespace_name, week_start_date, TRUNC(snap_time) AS snap_date, used_bytes,
           ROW_NUMBER() OVER (PARTITION BY con_id, tablespace_name, TRUNC(snap_time) ORDER BY snap_time DESC) AS rn
    FROM ts_snap
),
daily_growth AS (
    SELECT con_id, tablespace_name, week_start_date, snap_date, used_bytes,
           (used_bytes - LAG(used_bytes) OVER (PARTITION BY con_id, tablespace_name ORDER BY snap_date)) AS growth_bytes
    FROM daily_last_snap WHERE rn = 1
),
weekly_growth AS ( SELECT con_id, tablespace_name, week_start_date, SUM(growth_bytes) AS weekly_growth_bytes FROM daily_growth GROUP BY con_id, tablespace_name, week_start_date ),
growth_summary AS (
    SELECT con_id, tablespace_name, COUNT(*) AS num_weeks, SUM(weekly_growth_bytes) AS total_growth_bytes,
           NVL(STDDEV(weekly_growth_bytes), 0) AS growth_volatility
    FROM weekly_growth GROUP BY con_id, tablespace_name
)
SELECT
    NVL(pdbs.name, db.db_name) AS CONTAINER_NAME, c.tablespace_name AS TABLESPACE_NAME, c.datafile_count AS DATAFILE_COUNT,
    c.allocated_gb AS ALLOCATED_GB, c.used_gb AS USED_GB, c.free_gb AS FREE_GB, c.addable_gb AS ADDABLE_GB,
    ROUND(NVL(g.total_growth_bytes / NULLIF(g.num_weeks, 0), 0) / (1024*1024*1024), 2) AS AVG_WEEK_GROWTH_GB,
    CASE 
        WHEN NVL(g.growth_volatility,0) > (ABS(NVL(g.total_growth_bytes,0) / NULLIF(g.num_weeks, 0)) * 2) AND NVL(g.growth_volatility,0) > (1024*1024*1024) 
        THEN 'HIGH (Spiky)' ELSE 'NORMAL' 
    END AS VOLATILITY,
    CASE WHEN NVL(g.total_growth_bytes, 0) <= 0 THEN NULL ELSE ROUND((c.free_gb + c.addable_gb) / (g.total_growth_bytes / g.num_weeks / (1024*1024*1024)), 2) END AS SUSTAINABLE_WEEKS,
    CASE WHEN c.datafile_count > 900 THEN 'RED' WHEN c.datafile_count > 800 THEN 'AMBER' ELSE 'GREEN' END AS ALERT_COLOR
FROM db_info db
CROSS JOIN ts_with_capacity c
LEFT JOIN growth_summary g ON g.tablespace_name = c.tablespace_name AND g.con_id = c.con_id
LEFT JOIN v$containers pdbs ON pdbs.con_id = c.con_id
ORDER BY CONTAINER_NAME, c.tablespace_name;
SPOOL OFF

-- ASM Report
SPOOL __asm_output.csv
SELECT name AS DISKGROUP_NAME, state AS STATE, type AS REDUNDANCY_TYPE, ROUND(total_mb / 1024, 2) AS TOTAL_GB, ROUND(free_mb / 1024, 2) AS FREE_GB, ROUND((total_mb - free_mb) / 1024, 2) AS USED_GB, ROUND((total_mb - free_mb) / NULLIF(total_mb, 0) * 100, 2) AS PCT_USED
FROM v$asm_diskgroup ORDER BY name;
SPOOL OFF
EXIT;
EOF

# ------------------------------------------------------------------------------
# 3. Execute Loop & Aggregate Data
# ------------------------------------------------------------------------------
IS_FIRST_RUN=1

for SID in $TARGET_SIDS; do
    echo "Processing Instance: $SID..."
    set_oracle_env "$SID"
    
    # Execute SQL
    sqlplus -s / as sysdba @"$SQL_FILE" > /dev/null
    
    # Append to Master CSVs (handling headers)
    if [ -s __ts_output.csv ]; then
        if [ $IS_FIRST_RUN -eq 1 ]; then
            cat __ts_output.csv > "$TS_CSV"
            cat __asm_output.csv > "$ASM_CSV"
            IS_FIRST_RUN=0
        else
            tail -n +2 __ts_output.csv >> "$TS_CSV"
            tail -n +2 __asm_output.csv >> "$ASM_CSV"
        fi
    fi
    rm -f __ts_output.csv __asm_output.csv
done
rm -f "$SQL_FILE"

# Deduplicate ASM output (since multiple DBs on the same host see the same diskgroups)
if [ -s "$ASM_CSV" ]; then
    head -n 1 "$ASM_CSV" > __tmp_asm.csv
    tail -n +2 "$ASM_CSV" | sort -t, -u >> __tmp_asm.csv
    mv __tmp_asm.csv "$ASM_CSV"
fi

# ------------------------------------------------------------------------------
# 4. Generate Interactive HTML Dashboard via AWK (CSS & JS Embedded)
# ------------------------------------------------------------------------------
AWK_CMD="awk"
if command -v nawk >/dev/null 2>&1; then AWK_CMD="nawk"; fi

$AWK_CMD -v name_opt="$ID_NAME" '
BEGIN {
    FS = ","
    print "<!DOCTYPE html><html><head><meta charset=\"UTF-8\">"
    print "<title>Capacity Report - " name_opt "</title>"
    print "<style>"
    print "  :root { --primary: #2563eb; --bg: #f1f5f9; --surface: #ffffff; --text: #334155; --border: #e2e8f0; }"
    print "  body { font-family: \"Segoe UI\", system-ui, sans-serif; background-color: var(--bg); color: var(--text); padding: 20px; margin: 0; }"
    print "  .container { max-width: 1400px; margin: 0 auto; }"
    print "  .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }"
    print "  h2 { color: var(--primary); margin: 0; font-size: 1.5rem; }"
    print "  input.search { padding: 10px 16px; border: 1px solid var(--border); border-radius: 6px; width: 300px; font-size: 14px; box-shadow: 0 1px 2px rgba(0,0,0,0.05); }"
    print "  .card { background: var(--surface); border-radius: 8px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); overflow: hidden; margin-bottom: 30px; }"
    print "  table { width: 100%; border-collapse: collapse; text-align: left; }"
    print "  th { background-color: #f8fafc; padding: 12px 16px; font-weight: 600; color: #475569; border-bottom: 2px solid var(--border); cursor: pointer; user-select: none; transition: background 0.2s; }"
    print "  th:hover { background-color: #e2e8f0; }"
    print "  th::after { content: \" \\21D5\"; opacity: 0.3; font-size: 0.8em; }"
    print "  td { padding: 12px 16px; border-bottom: 1px solid var(--border); font-size: 14px; }"
    print "  tr:hover { background-color: #f8fafc; }"
    print "  .num { text-align: right; font-variant-numeric: tabular-nums; }"
    print "  .badge { padding: 4px 8px; border-radius: 12px; font-size: 12px; font-weight: bold; }"
    print "  .status-RED td { background-color: #fef2f2; color: #991b1b; }"
    print "  .status-AMBER td { background-color: #fefce8; color: #854d0e; }"
    print "  .volatility-HIGH { color: #ea580c; font-weight: bold; }"
    print "  .tooltip { position: relative; border-bottom: 1px dashed var(--primary); cursor: help; color: var(--primary); font-weight: 600; }"
    print "  .tooltip .tooltiptext { visibility: hidden; width: 220px; background: #1e293b; color: #fff; text-align: center; border-radius: 6px; padding: 8px; position: absolute; z-index: 10; bottom: 125%; left: 50%; transform: translateX(-50%); opacity: 0; transition: opacity 0.2s; font-size: 12px; font-weight: normal; box-shadow: 0 4px 6px rgba(0,0,0,0.3); line-height: 1.4; }"
    print "  .tooltip .tooltiptext::after { content: \"\"; position: absolute; top: 100%; left: 50%; margin-left: -5px; border-width: 5px; border-style: solid; border-color: #1e293b transparent transparent transparent; }"
    print "  .tooltip:hover .tooltiptext { visibility: visible; opacity: 1; }"
    print "</style>"
    print "<script>"
    print "  function filterTable(inputId, tableId) {"
    print "    let input = document.getElementById(inputId), filter = input.value.toUpperCase();"
    print "    let rows = document.getElementById(tableId).getElementsByTagName(\"tr\");"
    print "    for (let i = 1; i < rows.length; i++) {"
    print "      let show = false, cells = rows[i].getElementsByTagName(\"td\");"
    print "      for (let j = 0; j < cells.length; j++) { if (cells[j].innerText.toUpperCase().indexOf(filter) > -1) { show = true; break; } }"
    print "      rows[i].style.display = show ? \"\" : \"none\";"
    print "    }"
    print "  }"
    print "  function sortTable(tableId, n) {"
    print "    let table = document.getElementById(tableId), rows, switching = true, i, x, y, shouldSwitch, dir = \"asc\", switchcount = 0;"
    print "    while (switching) {"
    print "      switching = false; rows = table.rows;"
    print "      for (i = 1; i < (rows.length - 1); i++) {"
    print "        shouldSwitch = false; x = rows[i].getElementsByTagName(\"td\")[n]; y = rows[i + 1].getElementsByTagName(\"td\")[n];"
    print "        let valX = x.innerText.replace(/,/g, \"\").trim(), valY = y.innerText.replace(/,/g, \"\").trim();"
    print "        let isNum = !isNaN(parseFloat(valX)) && isFinite(valX);"
    print "        if (dir == \"asc\") { if ((isNum && parseFloat(valX) > parseFloat(valY)) || (!isNum && valX.toLowerCase() > valY.toLowerCase())) { shouldSwitch = true; break; } }"
    print "        else if (dir == \"desc\") { if ((isNum && parseFloat(valX) < parseFloat(valY)) || (!isNum && valX.toLowerCase() < valY.toLowerCase())) { shouldSwitch = true; break; } }"
    print "      }"
    print "      if (shouldSwitch) { rows[i].parentNode.insertBefore(rows[i + 1], rows[i]); switching = true; switchcount++; }"
    print "      else if (switchcount == 0 && dir == \"asc\") { dir = \"desc\"; switching = true; }"
    print "    }"
    print "  }"
    print "</script>"
    print "</head><body><div class=\"container\">"
}
FILENAME == ARGV[1] {
    if (FNR == 1) {
        print "<div class=\"header\"><h2><svg style=\"width:24px;height:24px;vertical-align:bottom;margin-right:8px;\" fill=\"none\" stroke=\"currentColor\" viewBox=\"0 0 24 24\"><path stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4m0 5c0 2.21-3.582 4-8 4s-8-1.79-8-4\"></path></svg>Host Tablespace Dashboard</h2>"
        print "<input type=\"text\" id=\"searchTS\" class=\"search\" onkeyup=\"filterTable(\x27searchTS\x27, \x27tsTable\x27)\" placeholder=\"Search Container, Tablespace...\"></div>"
        print "<div class=\"card\"><table id=\"tsTable\">"
        print "<tr><th onclick=\"sortTable(\x27tsTable\x27, 0)\">Container</th><th onclick=\"sortTable(\x27tsTable\x27, 1)\">Tablespace</th><th class=\"num\" onclick=\"sortTable(\x27tsTable\x27, 2)\">Files</th><th class=\"num\" onclick=\"sortTable(\x27tsTable\x27, 3)\">Allocated (GB)</th><th class=\"num\" onclick=\"sortTable(\x27tsTable\x27, 4)\">Used (GB)</th><th class=\"num\" onclick=\"sortTable(\x27tsTable\x27, 5)\">Free (GB)</th><th class=\"num\" onclick=\"sortTable(\x27tsTable\x27, 6)\">Addable (GB)</th><th class=\"num\" onclick=\"sortTable(\x27tsTable\x27, 7)\">Weekly Growth (GB)</th><th onclick=\"sortTable(\x27tsTable\x27, 8)\">Volatility</th><th class=\"num\" onclick=\"sortTable(\x27tsTable\x27, 9)\">Sustainable Weeks</th></tr>"
    } else {
        color_class = ""
        if ($11 == "RED") color_class = " class=\"status-RED\""
        if ($11 == "AMBER") color_class = " class=\"status-AMBER\""
        
        sust_content = $10 == "" ? "-" : $10
        sust_html = "<div class=\"tooltip\">" sust_content "<span class=\"tooltiptext\">Weeks until space exhausts (Current Free + Addable Capacity).</span></div>"
        
        df_html = "<div class=\"tooltip\">" $3 "<span class=\"tooltiptext\">Nearing 1023 datafile hard limit per tablespace. Database expansion required.</span></div>"
        if ($11 == "GREEN") df_html = $3

        vol_html = $9
        if (index($9, "HIGH") > 0) vol_html = "<div class=\"tooltip volatility-HIGH\">" $9 "<span class=\"tooltiptext\">Growth is erratic. The \"Sustainable Weeks\" forecast may be unreliable due to recent spikes.</span></div>"

        print "<tr" color_class "><td>" $1 "</td><td>" $2 "</td><td class=\"num\">" df_html "</td><td class=\"num\">" $4 "</td><td class=\"num\">" $5 "</td><td class=\"num\">" $6 "</td><td class=\"num\">" $7 "</td><td class=\"num\">" $8 "</td><td>" vol_html "</td><td class=\"num\">" sust_html "</td></tr>"
    }
}
FILENAME == ARGV[2] {
    if (FNR == 1) {
        print "</table></div>"
        print "<br><div class=\"header\"><h2><svg style=\"width:24px;height:24px;vertical-align:bottom;margin-right:8px;\" fill=\"none\" stroke=\"currentColor\" viewBox=\"0 0 24 24\"><path stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M5 8h14M5 8a2 2 0 110-4h14a2 2 0 110 4M5 8v10a2 2 0 002 2h10a2 2 0 002-2V8m-9 4h4\"></path></svg>Host ASM Diskgroup Storage</h2>"
        print "<input type=\"text\" id=\"searchASM\" class=\"search\" onkeyup=\"filterTable(\x27searchASM\x27, \x27asmTable\x27)\" placeholder=\"Search Diskgroup...\"></div>"
        print "<div class=\"card\"><table id=\"asmTable\">"
        print "<tr><th onclick=\"sortTable(\x27asmTable\x27, 0)\">Diskgroup</th><th onclick=\"sortTable(\x27asmTable\x27, 1)\">State</th><th onclick=\"sortTable(\x27asmTable\x27, 2)\">Redundancy</th><th class=\"num\" onclick=\"sortTable(\x27asmTable\x27, 3)\">Total (GB)</th><th class=\"num\" onclick=\"sortTable(\x27asmTable\x27, 4)\">Free (GB)</th><th class=\"num\" onclick=\"sortTable(\x27asmTable\x27, 5)\">Used (GB)</th><th class=\"num\" onclick=\"sortTable(\x27asmTable\x27, 6)\">% Used</th></tr>"
    } else {
        pct = $7 + 0
        row_style = ""
        if (pct >= 90) row_style = " class=\"status-RED\""
        else if (pct >= 80) row_style = " class=\"status-AMBER\""

        pct_html = $7 "%"
        if (pct >= 80) pct_html = "<div class=\"tooltip\">" $7 "%<span class=\"tooltiptext\">Diskgroup exceeding 80% capacity threshold. Add LUNs immediately.</span></div>"

        print "<tr" row_style "><td>" $1 "</td><td>" $2 "</td><td>" $3 "</td><td class=\"num\">" $4 "</td><td class=\"num\">" $5 "</td><td class=\"num\">" $6 "</td><td class=\"num\">" pct_html "</td></tr>"
    }
}
END {
    print "</table></div>"
    print "<p style=\"text-align:center; font-size: 13px; color: #94a3b8; margin-top: 40px;\">Generated on " strftime("%Y-%m-%d %H:%M:%S") " | Interactive Dashboard</p>"
    print "</div></body></html>"
}' "$TS_CSV" "$ASM_CSV" > "$HTML_OUT"

# ------------------------------------------------------------------------------
# 5. Email Dispatch
# ------------------------------------------------------------------------------
if [ -n "$EMAIL_TO" ]; then
    BOUNDARY="DB_MAIL_BOUNDARY_$(date +%Y%m%d%H%M%S)"
    
    (
        echo "To: $EMAIL_TO"
        echo "Subject: Multi-Instance DB Capacity Report: $ID_NAME"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=\"$BOUNDARY\""
        echo ""
        echo "--$BOUNDARY"
        echo "Content-Type: text/html; charset=\"UTF-8\""
        echo ""
        echo "<div style=\"font-family: sans-serif; color: #333;\">"
        echo "  <h3 style=\"color: #2563eb;\">Host-wide Oracle Capacity Report</h3>"
        echo "  <p>Please find attached the capacity reports for instances discovered on this host.</p>"
        echo "  <p><strong>Processed Instances:</strong> $TARGET_SIDS</p>"
        echo "  <ul>"
        echo "    <li><strong>$HTML_OUT</strong>: Open this file in any web browser to view the interactive dashboard.</li>"
        echo "    <li><strong>$TS_CSV / $ASM_CSV</strong>: Raw aggregated data extracts.</li>"
        echo "  </ul>"
        echo "</div>"
        echo ""
        
        # Attach HTML
        echo "--$BOUNDARY"
        echo "Content-Type: text/html; name=\"$HTML_OUT\""
        echo "Content-Disposition: attachment; filename=\"$HTML_OUT\""
        echo ""
        cat "$HTML_OUT"
        echo ""
        
        # Attach Tablespace CSV
        echo "--$BOUNDARY"
        echo "Content-Type: text/csv; name=\"$TS_CSV\""
        echo "Content-Disposition: attachment; filename=\"$TS_CSV\""
        echo ""
        cat "$TS_CSV"
        echo ""
        
        # Attach ASM CSV
        echo "--$BOUNDARY"
        echo "Content-Type: text/csv; name=\"$ASM_CSV\""
        echo "Content-Disposition: attachment; filename=\"$ASM_CSV\""
        echo ""
        cat "$ASM_CSV"
        echo ""
        echo "--$BOUNDARY--"
    ) | /usr/sbin/sendmail -t

    echo "Report generated and emailed to $EMAIL_TO"
else
    echo "Report generated locally."
fi

echo "Summary of generated files:"
echo "  - Dashboard: $HTML_OUT"
echo "  - TS Data:   $TS_CSV"
echo "  - ASM Data:  $ASM_CSV"
