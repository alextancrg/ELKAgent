#!/usr/bin/env bash
# ELK log retrieval via curl to Elasticsearch REST API

set -euo pipefail

# Convert time range string (e.g., "1h", "30m", "7d") to Elasticsearch "now-X" format
time_range_to_es() {
    echo "now-${ELK_TIME_RANGE}"
}

# Map log level to Elasticsearch query terms
level_to_query() {
    local level="$1"
    case "$level" in
        error)  echo '"error", "fatal", "critical", "ERROR", "FATAL", "CRITICAL"' ;;
        warn)   echo '"error", "fatal", "critical", "warn", "warning", "WARN", "WARNING", "ERROR", "FATAL", "CRITICAL"' ;;
        info)   echo '"error", "fatal", "critical", "warn", "warning", "info", "INFO", "WARN", "WARNING", "ERROR", "FATAL", "CRITICAL"' ;;
        debug)  echo '"error", "fatal", "critical", "warn", "warning", "info", "debug", "trace", "DEBUG", "TRACE", "INFO", "WARN", "WARNING", "ERROR", "FATAL", "CRITICAL"' ;;
        all)    echo "" ;;
        *)      echo '"error", "fatal", "critical", "ERROR", "FATAL", "CRITICAL"' ;;
    esac
}

# Build the Elasticsearch query JSON
build_query() {
    local time_from
    time_from=$(time_range_to_es)
    local level_terms
    level_terms=$(level_to_query "$ELK_LOG_LEVEL")

    local must_clauses=""

    # Time range filter
    must_clauses=$(cat <<EOF
{
    "range": {
        "@timestamp": {
            "gte": "$time_from",
            "lte": "now"
        }
    }
}
EOF
)

    # Log level filter (if not "all")
    if [[ -n "$level_terms" ]]; then
        must_clauses="$must_clauses,"
        must_clauses="$must_clauses"$(cat <<EOF

{
    "bool": {
        "should": [
            { "terms": { "log.level": [$level_terms] } },
            { "terms": { "level": [$level_terms] } },
            { "terms": { "severity": [$level_terms] } },
            { "terms": { "loglevel": [$level_terms] } }
        ],
        "minimum_should_match": 1
    }
}
EOF
)
    fi

    # Custom query filter
    if [[ -n "$ELK_CUSTOM_QUERY" ]]; then
        must_clauses="$must_clauses,"
        must_clauses="$must_clauses"$(cat <<EOF

{
    "query_string": {
        "query": "$ELK_CUSTOM_QUERY"
    }
}
EOF
)
    fi

    cat <<EOF
{
    "size": $ELK_MAX_RESULTS,
    "sort": [{ "@timestamp": { "order": "desc" } }],
    "query": {
        "bool": {
            "must": [
                $must_clauses
            ]
        }
    },
    "_source": [
        "@timestamp", "message", "log.level", "level", "severity",
        "service.name", "host.name", "container.name",
        "error.message", "error.stack_trace", "error.type",
        "http.response.status_code", "url.path",
        "kubernetes.pod.name", "kubernetes.namespace",
        "source", "tags", "fields"
    ]
}
EOF
}

# Execute the search query against Elasticsearch
retrieve_logs() {
    local query
    query=$(build_query)
    local url="${ELK_ENDPOINT}/${ELK_INDEX}/_search"

    log_info "Retrieving logs from: $url"
    log_info "Time range: now-${ELK_TIME_RANGE} to now"
    log_info "Log level filter: ${ELK_LOG_LEVEL}"
    log_info "Max results: ${ELK_MAX_RESULTS}"
    log_debug "Query: $query"

    # Build curl command with auth
    local -a curl_args=(
        -s
        -S
        --max-time 30
        --connect-timeout 10
        -X POST
        -H "Content-Type: application/json"
        -d "$query"
    )

    # Add auth args
    while IFS= read -r arg; do
        [[ -n "$arg" ]] && curl_args+=("$arg")
    done < <(get_curl_auth_args)

    curl_args+=("$url")

    local response
    local http_code

    # Execute with error handling
    response=$(curl -w "\n%{http_code}" "${curl_args[@]}" 2>&1) || {
        log_error "curl request failed: $response"
        return 1
    }

    # Split response body and HTTP status code
    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" -ge 400 ]]; then
        log_error "Elasticsearch returned HTTP $http_code"
        log_error "Response: $(echo "$response" | jq -r '.error.reason // .error // "Unknown error"' 2>/dev/null || echo "$response")"
        return 1
    fi

    # Validate response structure
    local total_hits
    total_hits=$(echo "$response" | jq -r '.hits.total.value // .hits.total // 0' 2>/dev/null)
    local returned_hits
    returned_hits=$(echo "$response" | jq -r '.hits.hits | length' 2>/dev/null)

    log_info "Total matching logs: $total_hits, Retrieved: $returned_hits"

    if [[ "$returned_hits" -eq 0 ]]; then
        log_warn "No log entries found matching the criteria"
    fi

    # Output the raw response for downstream processing
    echo "$response"
}

# Check Elasticsearch cluster health before querying
check_cluster_health() {
    local url="${ELK_ENDPOINT}/_cluster/health"

    local -a curl_args=(
        -s -S --max-time 10 --connect-timeout 5
    )

    while IFS= read -r arg; do
        [[ -n "$arg" ]] && curl_args+=("$arg")
    done < <(get_curl_auth_args)

    curl_args+=("$url")

    local response
    response=$(curl "${curl_args[@]}" 2>&1) || {
        log_error "Cannot reach Elasticsearch at $ELK_ENDPOINT"
        return 1
    }

    local status
    status=$(echo "$response" | jq -r '.status // "unknown"' 2>/dev/null)
    local cluster_name
    cluster_name=$(echo "$response" | jq -r '.cluster_name // "unknown"' 2>/dev/null)

    log_info "Cluster: $cluster_name, Status: $status"

    if [[ "$status" == "red" ]]; then
        log_warn "Cluster health is RED - some data may be unavailable"
    fi

    return 0
}
