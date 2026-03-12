#!/usr/bin/env bash
#
# ELK Log Analysis Agent
#
# Agentic workflow: Retrieve -> Analyze -> Report -> Recommend
# Uses curl to query Elasticsearch and jq for JSON processing.
#
# Usage:
#   ./elk-agent.sh [options]
#
# Options:
#   -c, --config FILE       Config file path (default: config.env)
#   -e, --endpoint URL      Elasticsearch endpoint URL
#   -i, --index PATTERN     Index pattern (default: filebeat-*)
#   -t, --time-range RANGE  Time range (default: 1h)
#   -l, --level LEVEL       Log level filter: error|warn|info|debug|all
#   -n, --max-results N     Max results to retrieve (default: 500)
#   -q, --query QUERY       Custom Lucene query filter
#   -o, --output FILE       Output report file path
#   -j, --json              Output raw analysis JSON instead of markdown
#   --skip-health           Skip cluster health check
#   --debug                 Enable debug output
#   -h, --help              Show this help message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library modules
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/retrieve.sh
source "$SCRIPT_DIR/lib/retrieve.sh"
# shellcheck source=lib/analyze.sh
source "$SCRIPT_DIR/lib/analyze.sh"
# shellcheck source=lib/report.sh
source "$SCRIPT_DIR/lib/report.sh"

# CLI defaults
CONFIG_FILE="config.env"
OUTPUT_FILE=""
JSON_OUTPUT=false
SKIP_HEALTH=false

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                CONFIG_FILE="$2"; shift 2 ;;
            -e|--endpoint)
                ELK_ENDPOINT="$2"; shift 2 ;;
            -i|--index)
                ELK_INDEX="$2"; shift 2 ;;
            -t|--time-range)
                ELK_TIME_RANGE="$2"; shift 2 ;;
            -l|--level)
                ELK_LOG_LEVEL="$2"; shift 2 ;;
            -n|--max-results)
                ELK_MAX_RESULTS="$2"; shift 2 ;;
            -q|--query)
                ELK_CUSTOM_QUERY="$2"; shift 2 ;;
            -o|--output)
                OUTPUT_FILE="$2"; shift 2 ;;
            -j|--json)
                JSON_OUTPUT=true; shift ;;
            --skip-health)
                SKIP_HEALTH=true; shift ;;
            --debug)
                ELK_DEBUG=true; shift ;;
            -h|--help)
                usage ;;
            *)
                log_error "Unknown option: $1"
                usage ;;
        esac
    done
}

# Main agentic workflow
main() {
    parse_args "$@"

    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   ELK Log Analysis Agent             ║"
    echo "  ╚══════════════════════════════════════╝"
    echo ""

    # Step 1: Load and validate configuration
    log_info "Step 1/4: Loading configuration..."
    load_config "$CONFIG_FILE"
    validate_config || exit 1

    # Step 2: Check cluster health (unless skipped)
    if [[ "$SKIP_HEALTH" == false ]]; then
        log_info "Step 2/4: Checking cluster health..."
        check_cluster_health || {
            log_error "Cluster health check failed. Use --skip-health to bypass."
            exit 1
        }
    else
        log_info "Step 2/4: Skipping cluster health check"
    fi

    # Step 3: Retrieve logs
    log_info "Step 3/4: Retrieving logs from Elasticsearch..."
    local raw_logs
    raw_logs=$(retrieve_logs) || {
        log_error "Log retrieval failed"
        exit 1
    }

    # Save raw response for debugging
    if [[ "${ELK_DEBUG:-false}" == "true" ]]; then
        local debug_file="${ELK_REPORT_DIR}/debug_raw_response.json"
        mkdir -p "$ELK_REPORT_DIR"
        echo "$raw_logs" | jq '.' > "$debug_file"
        log_debug "Raw response saved to $debug_file"
    fi

    # Step 4: Analyze and generate report
    log_info "Step 4/4: Analyzing logs and generating report..."
    local analysis
    analysis=$(analyze_logs "$raw_logs")

    # Determine output
    if [[ "$JSON_OUTPUT" == true ]]; then
        echo "$analysis" | jq '.'
    else
        # Generate report file
        mkdir -p "$ELK_REPORT_DIR"
        if [[ -z "$OUTPUT_FILE" ]]; then
            OUTPUT_FILE="${ELK_REPORT_DIR}/elk_report_$(date '+%Y%m%d_%H%M%S').md"
        fi

        generate_report "$analysis" "$OUTPUT_FILE"

        # Also save analysis JSON alongside the report
        local json_file="${OUTPUT_FILE%.md}.json"
        echo "$analysis" | jq '.' > "$json_file"
        log_info "Analysis JSON saved to $json_file"

        # Print summary to terminal
        print_report_summary "$analysis"

        echo ""
        log_info "Full report: $OUTPUT_FILE"
        log_info "Analysis data: $json_file"
    fi

    # Final status
    local total_errors
    total_errors=$(echo "$analysis" | jq -r '.summary.total_entries')
    local fatal
    fatal=$(echo "$analysis" | jq -r '.summary.fatal')

    echo ""
    if [[ "$fatal" -gt 0 ]]; then
        log_error "CRITICAL: $fatal fatal errors found. Immediate action required."
        exit 2
    elif [[ "$total_errors" -gt 0 ]]; then
        log_warn "Found $total_errors log entries requiring attention."
        exit 0
    else
        log_info "No errors found in the specified time range."
        exit 0
    fi
}

main "$@"
