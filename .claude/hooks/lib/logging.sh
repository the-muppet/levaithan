#!/bin/bash
# lib/logging.sh - Centralized structured logging library.
# All 

# Log level constants (only set if not already defined)
if [[ -z "${LOG_LEVEL_DEBUG:-}" ]]; then
    readonly LOG_LEVEL_DEBUG=0 LOG_LEVEL_INFO=1 LOG_LEVEL_WARNING=2 LOG_LEVEL_ERROR=3 LOG_LEVEL_CRITICAL=4
fi

log_structured() {
    local level="$1" event_type="$2" status="$3" message="$4"
    local level_num; case "$level" in DEBUG) level_num=0;; INFO) level_num=1;; WARNING) level_num=2;; ERROR) level_num=3;; CRITICAL) level_num=4;; esac
    if [[ $level_num -lt "${CLAUDE_LOG_LEVEL:-1}" ]]; then return 0; fi

    local timestamp; timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    # This JSON is sent to the Elasticsearch/Logging service via the DAL
    local log_json; log_json=$(jq -n \
        --arg ts "$timestamp" --arg level "$level" \
        --arg wfe_id "${WORKFLOW_EXECUTION_ID:-unknown}" \
        --arg hook "${HOOK_NAME:-unknown}" --arg event "$event_type" \
        --arg status "$status" --arg msg "$message" \
        '{timestamp: $ts, level: $level, wfe_id: $wfe_id, hook: $hook, event: $event, status: $status, message: $msg}')
    
    # Call data access layer to log the event
    log_to_elasticsearch "$log_json"
}

log_info()    { log_structured "INFO"    "$1" "$2" "$3"; }
log_warning() { log_structured "WARNING" "$1" "$2" "$3"; }
log_error()   { log_structured "ERROR"   "$1" "$2" "$3"; }
log_critical() { log_structured "CRITICAL" "$1" "$2" "$3"; }
