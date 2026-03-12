#!/usr/bin/env bash
# Log analysis engine: classifies errors, detects patterns, and extracts insights

set -euo pipefail

# Analyze raw Elasticsearch response and produce structured analysis JSON
analyze_logs() {
    local raw_response="$1"

    local hit_count
    hit_count=$(echo "$raw_response" | jq '.hits.hits | length')

    if [[ "$hit_count" -eq 0 ]]; then
        echo '{"summary":{"total_errors":0},"categories":[],"patterns":[],"services":[],"timeline":[]}'
        return 0
    fi

    log_info "Analyzing $hit_count log entries..."

    # Extract normalized log entries
    local entries
    entries=$(echo "$raw_response" | jq '[.hits.hits[] | {
        timestamp: ._source["@timestamp"],
        message: (._source.message // ._source["error.message"] // ""),
        level: (._source["log.level"] // ._source.level // ._source.severity // "unknown"),
        service: (._source["service.name"] // ._source["container.name"] // ._source["kubernetes.pod.name"] // "unknown"),
        host: (._source["host.name"] // "unknown"),
        error_type: (._source["error.type"] // ""),
        stack_trace: (._source["error.stack_trace"] // ""),
        http_status: (._source["http.response.status_code"] // null),
        url_path: (._source["url.path"] // ""),
        namespace: (._source["kubernetes.namespace"] // ""),
        id: ._id
    }]')

    # 1. Error categorization
    local categories
    categories=$(categorize_errors "$entries")

    # 2. Pattern detection (repeated errors, bursts)
    local patterns
    patterns=$(detect_patterns "$entries")

    # 3. Service breakdown
    local services
    services=$(echo "$entries" | jq '[group_by(.service)[] | {
        service: .[0].service,
        count: length,
        levels: [.[] | .level] | group_by(.) | map({level: .[0], count: length}),
        first_seen: (sort_by(.timestamp) | first | .timestamp),
        last_seen: (sort_by(.timestamp) | last | .timestamp)
    }] | sort_by(-.count)')

    # 4. Timeline analysis (error frequency over time)
    local timeline
    timeline=$(echo "$entries" | jq '
        [.[] | .timestamp | split("T")[0] + "T" + (split("T")[1] | split(":")[0]) + ":00:00Z"] |
        group_by(.) |
        map({hour: .[0], count: length}) |
        sort_by(.hour)
    ')

    # 5. Summary statistics
    local total_errors fatal_count error_count warn_count unique_services unique_hosts
    total_errors=$hit_count
    fatal_count=$(echo "$entries" | jq '[.[] | select(.level | test("fatal|critical|FATAL|CRITICAL"; "i"))] | length')
    error_count=$(echo "$entries" | jq '[.[] | select(.level | test("^error$|^ERROR$"; "i"))] | length')
    warn_count=$(echo "$entries" | jq '[.[] | select(.level | test("warn|warning|WARN|WARNING"; "i"))] | length')
    unique_services=$(echo "$entries" | jq '[.[] | .service] | unique | length')
    unique_hosts=$(echo "$entries" | jq '[.[] | .host] | unique | length')

    # 6. Top error messages (deduplicated)
    local top_messages
    top_messages=$(echo "$entries" | jq '[.[] | .message | gsub("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"; "<UUID>") | gsub("[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}"; "<IP>") | gsub(":[0-9]+"; ":<PORT>")] | group_by(.) | map({message: .[0], count: length}) | sort_by(-.count) | .[0:10]')

    # Assemble analysis result
    jq -n \
        --argjson total "$total_errors" \
        --argjson fatal "$fatal_count" \
        --argjson errors "$error_count" \
        --argjson warnings "$warn_count" \
        --argjson unique_svc "$unique_services" \
        --argjson unique_hosts "$unique_hosts" \
        --argjson categories "$categories" \
        --argjson patterns "$patterns" \
        --argjson services "$services" \
        --argjson timeline "$timeline" \
        --argjson top_messages "$top_messages" \
        '{
            summary: {
                total_entries: $total,
                fatal: $fatal,
                errors: $errors,
                warnings: $warnings,
                unique_services: $unique_svc,
                unique_hosts: $unique_hosts
            },
            categories: $categories,
            patterns: $patterns,
            services: $services,
            timeline: $timeline,
            top_messages: $top_messages
        }'
}

# Classify errors into categories based on message content
categorize_errors() {
    local entries="$1"

    echo "$entries" | jq '[
        # Connection / Network errors
        {
            category: "Connection/Network",
            entries: [.[] | select(.message | test("connection refused|ECONNREFUSED|timeout|ETIMEDOUT|ECONNRESET|network unreachable|DNS|name resolution|socket hang up|EHOSTUNREACH"; "i"))],
            severity: "high",
            icon: "NET"
        },
        # Out of Memory
        {
            category: "Memory",
            entries: [.[] | select(.message | test("out of memory|OOM|heap|memory limit|GC overhead|java.lang.OutOfMemoryError|Cannot allocate memory"; "i"))],
            severity: "critical",
            icon: "MEM"
        },
        # Disk / Storage
        {
            category: "Disk/Storage",
            entries: [.[] | select(.message | test("disk full|no space left|ENOSPC|storage|disk quota|write failed"; "i"))],
            severity: "critical",
            icon: "DSK"
        },
        # Authentication / Authorization
        {
            category: "Auth",
            entries: [.[] | select(.message | test("unauthorized|forbidden|401|403|authentication failed|access denied|permission denied|invalid token|expired token"; "i"))],
            severity: "high",
            icon: "AUTH"
        },
        # Database
        {
            category: "Database",
            entries: [.[] | select(.message | test("database|SQL|query failed|deadlock|connection pool|too many connections|relation.*does not exist|duplicate key|constraint violation"; "i"))],
            severity: "high",
            icon: "DB"
        },
        # HTTP 5xx errors
        {
            category: "HTTP 5xx",
            entries: [.[] | select(.http_status != null and .http_status >= 500)],
            severity: "high",
            icon: "HTTP"
        },
        # HTTP 4xx errors
        {
            category: "HTTP 4xx",
            entries: [.[] | select(.http_status != null and .http_status >= 400 and .http_status < 500)],
            severity: "medium",
            icon: "HTTP"
        },
        # Application / Runtime errors
        {
            category: "Application",
            entries: [.[] | select(.message | test("NullPointerException|TypeError|ReferenceError|undefined is not|segfault|panic|unhandled exception|uncaught"; "i"))],
            severity: "high",
            icon: "APP"
        },
        # Configuration errors
        {
            category: "Configuration",
            entries: [.[] | select(.message | test("config|missing env|environment variable|not configured|invalid configuration|missing required"; "i"))],
            severity: "medium",
            icon: "CFG"
        },
        # Resource limits (CPU, rate limiting)
        {
            category: "Resource Limits",
            entries: [.[] | select(.message | test("rate limit|throttl|CPU|resource limit|too many requests|429|circuit breaker"; "i"))],
            severity: "medium",
            icon: "RES"
        }
    ] | map(. + {count: (.entries | length)}) | map(del(.entries) | select(.count > 0)) | sort_by(-.count)'
}

# Detect patterns: repeated errors, error bursts, correlations
detect_patterns() {
    local entries="$1"

    local patterns="[]"

    # Detect error bursts (>5 errors within a 5-minute window)
    local burst_info
    burst_info=$(echo "$entries" | jq '
        [.[] | .timestamp] | sort |
        if length < 2 then []
        else
            [range(0; length - 1) as $i |
                {
                    t1: .[$i],
                    t2: .[if ($i + 5) < length then $i + 5 else length - 1 end],
                    window_size: (if ($i + 5) < length then 5 else length - 1 - $i end)
                }
            ] |
            [.[] | select(.window_size >= 5)] |
            if length > 0 then
                [{
                    type: "error_burst",
                    description: "Multiple errors detected in rapid succession",
                    severity: "high",
                    detail: "\(length) potential burst windows detected"
                }]
            else [] end
        end
    ')

    # Detect repeated identical errors
    local repeated
    repeated=$(echo "$entries" | jq '
        [.[] | .message] |
        group_by(.) |
        [.[] | select(length >= 3) | {
            type: "repeated_error",
            description: "Same error repeated \(length) times: \(.[0][:120])",
            severity: (if length >= 10 then "high" elif length >= 5 then "medium" else "low" end),
            count: length
        }] |
        sort_by(-.count) |
        .[0:5]
    ')

    # Detect multi-service failures (same time window, different services)
    local cross_service
    cross_service=$(echo "$entries" | jq '
        [.[] | .service] | unique |
        if length > 2 then
            [{
                type: "cross_service_failure",
                description: "Errors detected across \(length) services - possible cascading failure",
                severity: "high",
                affected_services: .
            }]
        else [] end
    ')

    # Merge all patterns
    echo "$burst_info $repeated $cross_service" | jq -s 'add | [.[] | select(. != null)]'
}
