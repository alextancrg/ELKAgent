#!/usr/bin/env bash
# Configuration loader and validator

set -euo pipefail

# Defaults
ELK_ENDPOINT="${ELK_ENDPOINT:-}"
ELK_USERNAME="${ELK_USERNAME:-}"
ELK_PASSWORD="${ELK_PASSWORD:-}"
ELK_API_KEY="${ELK_API_KEY:-}"
ELK_BEARER_TOKEN="${ELK_BEARER_TOKEN:-}"
ELK_INDEX="${ELK_INDEX:-filebeat-*}"
ELK_TIME_RANGE="${ELK_TIME_RANGE:-1h}"
ELK_MAX_RESULTS="${ELK_MAX_RESULTS:-500}"
ELK_LOG_LEVEL="${ELK_LOG_LEVEL:-error}"
ELK_CUSTOM_QUERY="${ELK_CUSTOM_QUERY:-}"
ELK_TLS_VERIFY="${ELK_TLS_VERIFY:-true}"
ELK_REPORT_DIR="${ELK_REPORT_DIR:-./reports}"

load_config() {
    local config_file="${1:-config.env}"

    if [[ -f "$config_file" ]]; then
        # Source config file, ignoring comments and empty lines
        set -a
        # shellcheck disable=SC1090
        source "$config_file"
        set +a
        log_info "Loaded configuration from $config_file"
    else
        log_warn "No config file found at $config_file, using environment variables"
    fi
}

validate_config() {
    local errors=0

    if [[ -z "$ELK_ENDPOINT" ]]; then
        log_error "ELK_ENDPOINT is required"
        errors=$((errors + 1))
    fi

    # Validate at least one auth method or allow anonymous
    if [[ -z "$ELK_USERNAME" && -z "$ELK_API_KEY" && -z "$ELK_BEARER_TOKEN" ]]; then
        log_warn "No authentication configured. Attempting anonymous access."
    fi

    if [[ -n "$ELK_USERNAME" && -z "$ELK_PASSWORD" ]]; then
        log_error "ELK_PASSWORD required when ELK_USERNAME is set"
        errors=$((errors + 1))
    fi

    # Validate time range format
    if ! [[ "$ELK_TIME_RANGE" =~ ^[0-9]+(m|h|d)$ ]]; then
        log_error "Invalid ELK_TIME_RANGE format: $ELK_TIME_RANGE (expected: 15m, 1h, 7d, etc.)"
        errors=$((errors + 1))
    fi

    # Validate max results is a number
    if ! [[ "$ELK_MAX_RESULTS" =~ ^[0-9]+$ ]]; then
        log_error "ELK_MAX_RESULTS must be a number: $ELK_MAX_RESULTS"
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        log_error "Configuration validation failed with $errors error(s)"
        return 1
    fi

    log_info "Configuration validated successfully"
    return 0
}

# Build curl auth arguments based on configured method
get_curl_auth_args() {
    local -a args=()

    if [[ -n "$ELK_API_KEY" ]]; then
        args+=(-H "Authorization: ApiKey $ELK_API_KEY")
    elif [[ -n "$ELK_BEARER_TOKEN" ]]; then
        args+=(-H "Authorization: Bearer $ELK_BEARER_TOKEN")
    elif [[ -n "$ELK_USERNAME" ]]; then
        args+=(-u "${ELK_USERNAME}:${ELK_PASSWORD}")
    fi

    if [[ "$ELK_TLS_VERIFY" == "false" ]]; then
        args+=(-k)
    fi

    printf '%s\n' "${args[@]}"
}

# Logging helpers
log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_debug() {
    if [[ "${ELK_DEBUG:-false}" == "true" ]]; then
        echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
    fi
}
