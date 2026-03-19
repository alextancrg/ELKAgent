#!/usr/bin/env bash
# Daily Wave E Local Interfaces Scope Report Generator
# Queries ELK Prod for 14 interfaces across EMEA (11) and APAC (8) systems.
# Generates CSV + HTML dashboard with regional grouping.
#
# Usage:
#   ./daily_wave_e_report.sh              # Report for yesterday
#   ./daily_wave_e_report.sh 2026-03-19   # Report for specific date
#
# Configuration: Edit the variables below or set them as environment variables.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---
ELK_PROD_ENDPOINT="${ELK_PROD_ENDPOINT:-https://integration-monitoring-lb.roche.com:9200}"
ELK_PROD_APIKEY="${ELK_PROD_APIKEY:-XzFMdDRKd0I4aUlwVE54eEJwZHc6elRSNmNQWkJRMlNkZThBYTlnbUxPUQ==}"
ELK_INDEX="${ELK_INDEX:-mulesoft-pharma-prod-*}"
REPORT_DIR="${REPORT_DIR:-$SCRIPT_DIR/reports}"
CURL_TIMEOUT="${CURL_TIMEOUT:-120}"

# Date handling: use argument or default to yesterday
if [[ $# -ge 1 ]]; then
    REPORT_DATE="$1"
else
    REPORT_DATE="$(date -u -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || date -u -v-1d '+%Y-%m-%d')"
fi
DATE_START="${REPORT_DATE}T00:00:00Z"
DATE_END="$(date -u -d "$REPORT_DATE + 1 day" '+%Y-%m-%d' 2>/dev/null || date -u -v+1d -j -f '%Y-%m-%d' "$REPORT_DATE" '+%Y-%m-%d')T00:00:00Z"
DISPLAY_DATE="$(date -u -d "$REPORT_DATE" '+%d %b %Y' 2>/dev/null || date -u -j -f '%Y-%m-%d' "$REPORT_DATE" '+%d %b %Y')"
FILE_DATE="$(echo "$REPORT_DATE" | tr -d '-')"

# Systems
EMEA_SYSTEMS=("GH_PH_IL" "SI_PH_KE" "DPWorld" "DSV" "SK_PH_DS" "GRIT" "XCZ_PH_GR" "MYSUPPLY" "XDK_DI_MS" "CZ_PH_AH" "XSI_PH_SE")
APAC_SYSTEMS=("SALEHIYAH" "EPX" "KUEHNENAGELUAE" "DKSH" "EG_PH_EP" "AE_PH_KN" "SA_PH_SL" "MY_DI_DK")
ALL_SYSTEMS=("${EMEA_SYSTEMS[@]}" "${APAC_SYSTEMS[@]}")

# 14 Interfaces: name|entity|direction
INTERFACES=(
    "Inbound Delivery|SHP_IBDLV_SAVE_REPLICA|O"
    "Outbound Delivery|SHP_OBDLV_SAVE_REPLICA|O"
    "Inbound Delivery Confirmation|SHP_OBDLV_CONFIRM_DECENTRAL|I"
    "Outbound Delivery Confirmation|SHPCON|I"
    "Sales Orders|ORDERS|I"
    "Stock Adjustments/Movements|MBGMCR|I"
    "Information on Delivery|STATUS|I"
    "Customer Invoice|INVOIC|O"
    "Material Master Outbound|/TNESP/MASTER|O"
    "Sales Order Outbound|ORDERS|O"
    "BPCOUT|BusinessPartnerBulkReplicationOut|O"
    "Delivery Note|OBDDLN|I"
    "Stock Reconciliation|ZREC|I"
    "SETCCE_Invoice|INVOIC_SETCCE|O"
)

mkdir -p "$REPORT_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

# --- ELK Query Functions ---
build_systems_json() {
    local arr=("$@")
    printf '"%s"' "${arr[0]}"
    for s in "${arr[@]:1}"; do printf ',"%s"' "$s"; done
}

query_main() {
    local systems_json
    systems_json="[$(build_systems_json "${ALL_SYSTEMS[@]}")]"
    log "Querying ELK Prod for $REPORT_DATE (${#ALL_SYSTEMS[@]} systems)..."
    curl -s -k --max-time "$CURL_TIMEOUT" \
        -X POST "${ELK_PROD_ENDPOINT}/${ELK_INDEX}/_search" \
        -H "Authorization: ApiKey ${ELK_PROD_APIKEY}" \
        -H "Content-Type: application/json" \
        -d '{
        "size": 0,
        "query": {"bool": {"must": [{"range": {"@timestamp": {"gte": "'"$DATE_START"'", "lt": "'"$DATE_END"'"}}}],
            "filter": [{"exists": {"field": "MuleMessage.metadata.txnStatus"}},
                {"bool": {"should": [
                    {"terms": {"sourceSystem.keyword": '"$systems_json"'}},
                    {"terms": {"targetSystem.keyword": '"$systems_json"'}}
                ], "minimum_should_match": 1}}]}},
        "aggs": {"by_entity": {"terms": {"field": "MuleMessage.metadata.entity.keyword", "size": 50},
            "aggs": {"by_status": {"terms": {"field": "MuleMessage.metadata.txnStatus.keyword", "size": 10}},
                "by_source": {"terms": {"field": "sourceSystem.keyword", "size": 50}},
                "by_target": {"terms": {"field": "targetSystem.keyword", "size": 50}},
                "by_direction": {"terms": {"field": "MuleMessage.metadata.direction.keyword", "size": 5}}}}}
    }' 2>/dev/null
}

query_setcce() {
    log "Querying SETCCE/XSI_PH_SE..."
    curl -s -k --max-time "$CURL_TIMEOUT" \
        -X POST "${ELK_PROD_ENDPOINT}/${ELK_INDEX}/_search" \
        -H "Authorization: ApiKey ${ELK_PROD_APIKEY}" \
        -H "Content-Type: application/json" \
        -d '{
        "size": 0,
        "query": {"bool": {"must": [
            {"range": {"@timestamp": {"gte": "'"$DATE_START"'", "lt": "'"$DATE_END"'"}}},
            {"term": {"targetSystem.keyword": "XSI_PH_SE"}}
        ]}},
        "aggs": {"unique_correlations": {"cardinality": {"field": "correlationId.keyword"}}}
    }' 2>/dev/null
}

# --- Data Extraction ---
extract_interface_data() {
    local raw="$1" entity="$2" direction="$3"
    # For ORDERS, need to distinguish I vs O by direction
    if [[ "$entity" == "ORDERS" ]]; then
        # ORDERS appears once in ELK; use direction bucket to get the count for I or O
        local dir_count
        dir_count=$(echo "$raw" | jq -r --arg e "$entity" --arg d "$direction" '
            [.aggregations.by_entity.buckets[] | select(.key == $e) |
             .by_direction.buckets[] | select(.key == $d) | .doc_count] | add // 0' 2>/dev/null)
        if [[ "$dir_count" -gt 0 ]]; then
            echo "$raw" | jq -r --arg e "$entity" --arg d "$direction" --argjson dc "$dir_count" '
                .aggregations.by_entity.buckets[] | select(.key == $e) |
                {
                    total: $dc,
                    success: $dc,
                    failed: 0,
                    sources: [.by_source.buckets[] | "\(.key)(\(.doc_count))"] | join(", "),
                    targets: [.by_target.buckets[] | "\(.key)(\(.doc_count))"] | join(", ")
                }' 2>/dev/null
        else
            echo '{"total":0,"success":0,"failed":0,"sources":"-","targets":"-"}'
        fi
    else
        echo "$raw" | jq -r --arg e "$entity" '
            .aggregations.by_entity.buckets[] |
            select(.key == $e) |
            {
                total: .doc_count,
                success: ([.by_status.buckets[] | select(.key == "Success") | .doc_count] | add // 0),
                failed: ([.by_status.buckets[] | select(.key != "Success") | .doc_count] | add // 0),
                sources: [.by_source.buckets[] | "\(.key)(\(.doc_count))"] | join(", "),
                targets: [.by_target.buckets[] | "\(.key)(\(.doc_count))"] | join(", ")
            }' 2>/dev/null
    fi
}

get_system_region() {
    local sys="$1"
    for s in "${EMEA_SYSTEMS[@]}"; do [[ "$s" == "$sys" ]] && echo "EMEA" && return; done
    for s in "${APAC_SYSTEMS[@]}"; do [[ "$s" == "$sys" ]] && echo "APAC" && return; done
    echo "OTHER"
}

# --- Main Execution ---
main() {
    log "=== Wave E Overall Local Interfaces Scope Report ==="
    log "Date: $REPORT_DATE ($DISPLAY_DATE)"
    log "Output: $REPORT_DIR"

    # Query ELK
    local raw_data setcce_data
    raw_data=$(query_main)
    setcce_data=$(query_setcce)

    local total_hits
    total_hits=$(echo "$raw_data" | jq '.hits.total.value')
    local setcce_count
    setcce_count=$(echo "$setcce_data" | jq '.aggregations.unique_correlations.value // 0')
    log "Main query: $total_hits hits | SETCCE: $setcce_count unique correlations"

    # Parse each interface
    declare -A IF_TOTAL IF_SUCCESS IF_FAILED IF_SOURCES IF_TARGETS
    local grand_total=0 grand_success=0 grand_failed=0

    for i in "${!INTERFACES[@]}"; do
        IFS='|' read -r name entity direction <<< "${INTERFACES[$i]}"

        if [[ "$entity" == "INVOIC_SETCCE" ]]; then
            IF_TOTAL[$i]=$setcce_count
            IF_SUCCESS[$i]=$setcce_count
            IF_FAILED[$i]=0
            IF_SOURCES[$i]="-"
            IF_TARGETS[$i]="XSI_PH_SE"
        else
            local data
            data=$(extract_interface_data "$raw_data" "$entity" "$direction")
            if [[ -n "$data" && "$data" != "null" ]]; then
                IF_TOTAL[$i]=$(echo "$data" | jq -r '.total // 0')
                IF_SUCCESS[$i]=$(echo "$data" | jq -r '.success // 0')
                IF_FAILED[$i]=$(echo "$data" | jq -r '.failed // 0')
                IF_SOURCES[$i]=$(echo "$data" | jq -r '.sources // "-"')
                IF_TARGETS[$i]=$(echo "$data" | jq -r '.targets // "-"')
            else
                IF_TOTAL[$i]=0; IF_SUCCESS[$i]=0; IF_FAILED[$i]=0
                IF_SOURCES[$i]="-"; IF_TARGETS[$i]="-"
            fi
        fi

        grand_total=$((grand_total + ${IF_TOTAL[$i]}))
        grand_success=$((grand_success + ${IF_SUCCESS[$i]}))
        grand_failed=$((grand_failed + ${IF_FAILED[$i]}))
    done

    # Add SETCCE to grand total
    grand_total=$((grand_total + setcce_count))
    grand_success=$((grand_success + setcce_count))

    local success_rate="0.0"
    if [[ $grand_total -gt 0 ]]; then
        success_rate=$(awk "BEGIN{printf \"%.1f\", ($grand_success/$grand_total)*100}")
    fi

    # Compute system activity from raw aggregation data
    declare -A SYS_SOURCE SYS_TARGET
    for sys in "${ALL_SYSTEMS[@]}"; do SYS_SOURCE[$sys]=0; SYS_TARGET[$sys]=0; done

    # Parse source counts from all entity buckets
    while IFS=$'\t' read -r sys count; do
        [[ -n "$sys" ]] && SYS_SOURCE[$sys]=$((${SYS_SOURCE[$sys]:-0} + count))
    done < <(echo "$raw_data" | jq -r '.aggregations.by_entity.buckets[].by_source.buckets[] | [.key, .doc_count] | @tsv' 2>/dev/null)

    while IFS=$'\t' read -r sys count; do
        [[ -n "$sys" ]] && SYS_TARGET[$sys]=$((${SYS_TARGET[$sys]:-0} + count))
    done < <(echo "$raw_data" | jq -r '.aggregations.by_entity.buckets[].by_target.buckets[] | [.key, .doc_count] | @tsv' 2>/dev/null)

    # --- Generate CSV ---
    local csv_file="$REPORT_DIR/wave_e_overall_local_interfaces_scope_${FILE_DATE}_prod.csv"
    log "Generating CSV: $csv_file"
    {
        echo "Wave E Overall Local Interfaces Scope - $DISPLAY_DATE"
        echo "Environment: Prod"
        echo "Regions: EMEA, APAC"
        echo "EMEA Systems: ${EMEA_SYSTEMS[*]}"
        echo "APAC Systems: ${APAC_SYSTEMS[*]}"
        echo "Date Range: $REPORT_DATE 00:00:00 UTC - next day 00:00:00 UTC"
        echo "Total Transactions: $grand_total"
        echo "Success Rate: ${success_rate}%"
        echo ""
        echo "Interface,Entity,Direction,Total,Success,Failed,Source Systems,Target Systems,Region"

        for i in "${!INTERFACES[@]}"; do
            IFS='|' read -r name entity direction <<< "${INTERFACES[$i]}"
            local display_entity="$entity"
            [[ "$entity" == "INVOIC_SETCCE" ]] && display_entity="INVOIC (SETCCE)"
            [[ "$entity" == "ORDERS" && "$direction" == "I" ]] && display_entity="ORDERS (I)"
            [[ "$entity" == "ORDERS" && "$direction" == "O" ]] && display_entity="ORDERS (O)"

            # Determine region from sources/targets
            local region="EMEA/APAC"
            echo "$name,$display_entity,$direction,${IF_TOTAL[$i]},${IF_SUCCESS[$i]},${IF_FAILED[$i]},\"${IF_SOURCES[$i]}\",\"${IF_TARGETS[$i]}\",$region"
        done

        echo ""
        echo "EMEA Systems Activity Summary"
        echo "System,As Source,As Target,Total,Region"
        for sys in "${EMEA_SYSTEMS[@]}"; do
            local src=${SYS_SOURCE[$sys]:-0} tgt=${SYS_TARGET[$sys]:-0}
            echo "$sys,$src,$tgt,$((src + tgt)),EMEA"
        done

        echo ""
        echo "APAC Systems Activity Summary"
        echo "System,As Source,As Target,Total,Region"
        for sys in "${APAC_SYSTEMS[@]}"; do
            local src=${SYS_SOURCE[$sys]:-0} tgt=${SYS_TARGET[$sys]:-0}
            echo "$sys,$src,$tgt,$((src + tgt)),APAC"
        done
    } > "$csv_file"

    # --- Generate HTML ---
    local html_file="$REPORT_DIR/wave_e_overall_local_interfaces_scope_${FILE_DATE}_prod.html"
    log "Generating HTML: $html_file"
    generate_html "$html_file" "$grand_total" "$grand_success" "$grand_failed" "$success_rate"

    log "=== Report generation complete ==="
    log "CSV: $csv_file"
    log "HTML: $html_file"
}

# --- HTML Generation (split into 3 parts to avoid heredoc issues) ---
generate_html() {
    local html_file="$1" grand_total="$2" grand_success="$3" grand_failed="$4" success_rate="$5"

    generate_html_part1 "$html_file" "$grand_total" "$grand_success" "$grand_failed" "$success_rate"
    generate_html_part2 "$html_file"
    generate_html_part3 "$html_file"
}

generate_html_part1() {
    local f="$1" gt="$2" gs="$3" gf="$4" sr="$5"

    # Compute bar heights (max 200px)
    local max_val=1
    for i in "${!INTERFACES[@]}"; do
        [[ ${IF_TOTAL[$i]} -gt $max_val ]] && max_val=${IF_TOTAL[$i]}
    done

    cat > "$f" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Wave E Overall Local Interfaces Scope - $DISPLAY_DATE</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;background:#1a1a2e;color:#e0e0e0;padding:20px}
.container{max-width:1400px;margin:0 auto}
.header{background:linear-gradient(135deg,#16213e,#0f3460);border-radius:12px;padding:30px;margin-bottom:25px;text-align:center;border:1px solid #1a3a6a}
.header h1{font-size:28px;color:#4fc3f7;margin-bottom:8px}
.header p{color:#90caf9;font-size:14px}
.region-badge{display:inline-block;padding:3px 10px;border-radius:12px;font-size:11px;font-weight:600;margin-left:6px}
.region-emea{background:#1b5e20;color:#a5d6a7}
.region-apac{background:#0d47a1;color:#90caf9}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:15px;margin-bottom:25px}
.card{background:#16213e;border-radius:10px;padding:20px;text-align:center;border:1px solid #1a3a6a}
.card .value{font-size:32px;font-weight:700;color:#4fc3f7}
.card .label{font-size:13px;color:#90caf9;margin-top:5px}
.card.success .value{color:#66bb6a}
.card.failed .value{color:#ef5350}
.card.rate .value{color:#ffa726}
.chart-container{background:#16213e;border-radius:10px;padding:20px;margin-bottom:25px;border:1px solid #1a3a6a}
.chart-container h2{color:#4fc3f7;margin-bottom:15px;font-size:18px}
.bar-chart{display:flex;align-items:flex-end;gap:8px;height:200px;padding:10px 0;border-bottom:1px solid #2a3a5a}
.bar-group{display:flex;flex-direction:column;align-items:center;flex:1}
.bar{width:100%;max-width:60px;border-radius:4px 4px 0 0;position:relative;min-height:2px;transition:height 0.3s}
.bar.success-bar{background:linear-gradient(180deg,#66bb6a,#388e3c)}
.bar.failed-bar{background:linear-gradient(180deg,#ef5350,#c62828)}
.bar-label{font-size:9px;color:#90caf9;margin-top:6px;text-align:center;word-break:break-all;max-width:70px}
.bar-value{font-size:10px;color:#e0e0e0;margin-bottom:3px}
table{width:100%;border-collapse:collapse;margin-bottom:20px}
th{background:#0f3460;color:#4fc3f7;padding:12px 10px;text-align:left;font-size:13px;border-bottom:2px solid #1a3a6a}
td{padding:10px;border-bottom:1px solid #1a2a4a;font-size:13px}
tr:hover{background:#1a2a4a}
.section{background:#16213e;border-radius:10px;padding:20px;margin-bottom:20px;border:1px solid #1a3a6a}
.section h2{color:#4fc3f7;margin-bottom:15px;font-size:18px}
.section h3{color:#90caf9;margin-bottom:10px;font-size:15px}
.status-success{color:#66bb6a;font-weight:600}
.status-failed{color:#ef5350;font-weight:600}
.footer{text-align:center;padding:20px;color:#546e7a;font-size:12px}
</style>
</head>
<body>
<div class="container">
<div class="header">
<h1>Wave E Overall Local Interfaces Scope - $DISPLAY_DATE</h1>
<p>Environment: Prod | Regions: EMEA + APAC | Date: $REPORT_DATE 00:00 - next day 00:00 UTC</p>
<p style="margin-top:5px">EMEA: ${EMEA_SYSTEMS[*]} | APAC: ${APAC_SYSTEMS[*]}</p>
</div>

<div class="cards">
<div class="card"><div class="value">$gt</div><div class="label">Total Transactions</div></div>
<div class="card success"><div class="value">$gs</div><div class="label">Successful</div></div>
<div class="card failed"><div class="value">$gf</div><div class="label">Failed</div></div>
<div class="card rate"><div class="value">${sr}%</div><div class="label">Success Rate</div></div>
<div class="card"><div class="value">14</div><div class="label">Interfaces Monitored</div></div>
<div class="card"><div class="value">${#ALL_SYSTEMS[@]}</div><div class="label">Systems (${#EMEA_SYSTEMS[@]} EMEA + ${#APAC_SYSTEMS[@]} APAC)</div></div>
</div>

<div class="chart-container">
<h2>Transaction Volume by Interface</h2>
<div class="bar-chart">
HTMLEOF

    # Add bars
    local bar_labels=("IBDLV" "OBDLV" "IB Conf" "SHPCON" "ORDERS(I)" "MBGMCR" "STATUS" "INVOIC" "MASTER" "ORDERS(O)" "BPCOUT" "OBDDLN" "ZREC" "SETCCE")
    for i in "${!INTERFACES[@]}"; do
        local val=${IF_TOTAL[$i]}
        local height=2
        [[ $max_val -gt 0 && $val -gt 0 ]] && height=$(awk "BEGIN{h=int(($val/$max_val)*200); if(h<2) h=2; print h}")
        cat >> "$f" << BAREOF
<div class="bar-group"><div class="bar-value">$val</div><div class="bar success-bar" style="height:${height}px"></div><div class="bar-label">${bar_labels[$i]}</div></div>
BAREOF
    done

    cat >> "$f" << HTMLEOF
</div>
</div>
HTMLEOF
}

generate_html_part2() {
    local f="$1"

    # Summary table
    cat >> "$f" << HTMLEOF
<div class="section">
<h2>Summary Table</h2>
<table>
<tr><th>#</th><th>Interface</th><th>Entity</th><th>Dir</th><th>Total</th><th>Success</th><th>Failed</th><th>Source</th><th>Target</th><th>Region</th></tr>
HTMLEOF

    for i in "${!INTERFACES[@]}"; do
        IFS='|' read -r name entity direction <<< "${INTERFACES[$i]}"
        local display_entity="$entity" region_badge='<span class="region-badge region-emea">EMEA</span><span class="region-badge region-apac">APAC</span>'
        [[ "$entity" == "INVOIC_SETCCE" ]] && display_entity="INVOIC (SETCCE)"
        [[ "$entity" == "ORDERS" && "$direction" == "I" ]] && display_entity="ORDERS (I)"
        [[ "$entity" == "ORDERS" && "$direction" == "O" ]] && display_entity="ORDERS (O)"

        local success_class=""
        [[ ${IF_SUCCESS[$i]} -gt 0 ]] && success_class=' class="status-success"'
        local failed_class=""
        [[ ${IF_FAILED[$i]} -gt 0 ]] && failed_class=' class="status-failed"'

        local src="${IF_SOURCES[$i]}"
        local tgt="${IF_TARGETS[$i]}"
        [[ -z "$src" || "$src" == "null" ]] && src="-"
        [[ -z "$tgt" || "$tgt" == "null" ]] && tgt="-"

        cat >> "$f" << ROWEOF
<tr><td>$((i+1))</td><td>$name</td><td>$display_entity</td><td>$direction</td><td>${IF_TOTAL[$i]}</td><td${success_class}>${IF_SUCCESS[$i]}</td><td${failed_class}>${IF_FAILED[$i]}</td><td>$src</td><td>$tgt</td><td>$region_badge</td></tr>
ROWEOF
    done

    echo "</table></div>" >> "$f"

    # Interface details
    echo '<div class="section"><h2>Interface Details</h2>' >> "$f"

    for i in "${!INTERFACES[@]}"; do
        IFS='|' read -r name entity direction <<< "${INTERFACES[$i]}"
        local display_entity="$entity" dir_label="Inbound (I)"
        [[ "$entity" == "INVOIC_SETCCE" ]] && display_entity="INVOIC (SETCCE)"
        [[ "$entity" == "ORDERS" && "$direction" == "I" ]] && display_entity="ORDERS (I)"
        [[ "$entity" == "ORDERS" && "$direction" == "O" ]] && display_entity="ORDERS (O)"
        [[ "$direction" == "O" ]] && dir_label="Outbound (O)"

        local src="${IF_SOURCES[$i]}" tgt="${IF_TARGETS[$i]}"
        [[ -z "$src" || "$src" == "null" ]] && src="-"
        [[ -z "$tgt" || "$tgt" == "null" ]] && tgt="-"

        local success_td="${IF_SUCCESS[$i]}"
        [[ ${IF_SUCCESS[$i]} -gt 0 ]] && success_td="<span class=\"status-success\">${IF_SUCCESS[$i]}</span>"

        # Only output first 7 in part2
        if [[ $i -lt 7 ]]; then
            cat >> "$f" << DETEOF
<h3>$((i+1)). $name - $display_entity ($direction) <span class="region-badge region-emea">EMEA</span><span class="region-badge region-apac">APAC</span></h3>
<table>
<tr><th>Metric</th><th>Value</th></tr>
<tr><td>Total Transactions</td><td>${IF_TOTAL[$i]}</td></tr>
<tr><td>Success</td><td>$success_td</td></tr>
<tr><td>Failed</td><td>${IF_FAILED[$i]}</td></tr>
<tr><td>Direction</td><td>$dir_label</td></tr>
<tr><td>Source Systems</td><td>$src</td></tr>
<tr><td>Target Systems</td><td>$tgt</td></tr>
</table>
DETEOF
        fi
    done
}

generate_html_part3() {
    local f="$1"

    # Interface details 8-14
    for i in "${!INTERFACES[@]}"; do
        [[ $i -lt 7 ]] && continue
        IFS='|' read -r name entity direction <<< "${INTERFACES[$i]}"
        local display_entity="$entity" dir_label="Inbound (I)"
        [[ "$entity" == "INVOIC_SETCCE" ]] && display_entity="INVOIC (SETCCE)"
        [[ "$entity" == "ORDERS" && "$direction" == "I" ]] && display_entity="ORDERS (I)"
        [[ "$entity" == "ORDERS" && "$direction" == "O" ]] && display_entity="ORDERS (O)"
        [[ "$direction" == "O" ]] && dir_label="Outbound (O)"

        local src="${IF_SOURCES[$i]}" tgt="${IF_TARGETS[$i]}"
        [[ -z "$src" || "$src" == "null" ]] && src="-"
        [[ -z "$tgt" || "$tgt" == "null" ]] && tgt="-"

        local success_td="${IF_SUCCESS[$i]}"
        [[ ${IF_SUCCESS[$i]} -gt 0 ]] && success_td="<span class=\"status-success\">${IF_SUCCESS[$i]}</span>"

        cat >> "$f" << DETEOF
<h3>$((i+1)). $name - $display_entity ($direction) <span class="region-badge region-emea">EMEA</span><span class="region-badge region-apac">APAC</span></h3>
<table>
<tr><th>Metric</th><th>Value</th></tr>
<tr><td>Total Transactions</td><td>${IF_TOTAL[$i]}</td></tr>
<tr><td>Success</td><td>$success_td</td></tr>
<tr><td>Failed</td><td>${IF_FAILED[$i]}</td></tr>
<tr><td>Direction</td><td>$dir_label</td></tr>
<tr><td>Source Systems</td><td>$src</td></tr>
<tr><td>Target Systems</td><td>$tgt</td></tr>
</table>
DETEOF
    done

    echo "</div>" >> "$f"

    # EMEA Systems Summary
    cat >> "$f" << HTMLEOF
<div class="section">
<h2>EMEA Systems Activity Summary <span class="region-badge region-emea">EMEA</span></h2>
<table>
<tr><th>System</th><th>As Source</th><th>As Target</th><th>Total</th><th>Region</th></tr>
HTMLEOF

    for sys in "${EMEA_SYSTEMS[@]}"; do
        local src=${SYS_SOURCE[$sys]:-0} tgt=${SYS_TARGET[$sys]:-0}
        echo "<tr><td>$sys</td><td>$src</td><td>$tgt</td><td>$((src + tgt))</td><td><span class=\"region-badge region-emea\">EMEA</span></td></tr>" >> "$f"
    done

    echo "</table></div>" >> "$f"

    # APAC Systems Summary
    cat >> "$f" << HTMLEOF
<div class="section">
<h2>APAC Systems Activity Summary <span class="region-badge region-apac">APAC</span></h2>
<table>
<tr><th>System</th><th>As Source</th><th>As Target</th><th>Total</th><th>Region</th></tr>
HTMLEOF

    for sys in "${APAC_SYSTEMS[@]}"; do
        local src=${SYS_SOURCE[$sys]:-0} tgt=${SYS_TARGET[$sys]:-0}
        echo "<tr><td>$sys</td><td>$src</td><td>$tgt</td><td>$((src + tgt))</td><td><span class=\"region-badge region-apac\">APAC</span></td></tr>" >> "$f"
    done

    cat >> "$f" << HTMLEOF
</table>
</div>

<div class="footer">
<p>Generated by ELK Log Agent | Wave E Overall Local Interfaces Scope | $DISPLAY_DATE</p>
</div>
</div>
</body>
</html>
HTMLEOF
}

main "$@"
