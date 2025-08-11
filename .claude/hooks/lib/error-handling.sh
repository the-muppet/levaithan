#!/bin/bash
# lib/error-handling.sh - Comprehensive error management and recovery library
# Provides standardized error handling, recovery mechanisms, and DLQ integration

# Ensure required environment variables
if [[ -z "$CLAUDE_PROJECT_DIR" ]]; then
    echo "FATAL: CLAUDE_PROJECT_DIR not set." >&2
    exit 1
fi

# Source required libraries
# shellcheck source=./logging.sh
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/logging.sh"
# shellcheck source=./state.sh
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/state.sh" 2>/dev/null || true

# ============================================================================
# ERROR CODE DEFINITIONS
# ============================================================================

# Standard exit codes for different error types
readonly EXIT_SUCCESS=0
readonly EXIT_GENERAL_ERROR=1
readonly EXIT_MISUSE_SHELL_BUILTINS=2
readonly EXIT_CANNOT_EXECUTE=126
readonly EXIT_COMMAND_NOT_FOUND=127
readonly EXIT_INVALID_EXIT_ARGUMENT=128
readonly EXIT_FATAL_ERROR_SIGNAL=130

# Custom system exit codes (100-199 reserved for system)
readonly EXIT_SYSTEM_LOCKED=101
readonly EXIT_RESOURCE_UNAVAILABLE=102
readonly EXIT_GOVERNANCE_VIOLATION=103
readonly EXIT_BUDGET_EXCEEDED=104
readonly EXIT_AUTHENTICATION_FAILED=105
readonly EXIT_AUTHORIZATION_FAILED=106
readonly EXIT_RATE_LIMITED=107
readonly EXIT_CIRCUIT_BREAKER_OPEN=108
readonly EXIT_RETRY_EXHAUSTED=109
readonly EXIT_CRITICAL_DEPENDENCY_FAILED=110

# Application exit codes (200-255 available for hooks)
readonly EXIT_INVALID_ENVELOPE=200
readonly EXIT_VALIDATION_FAILED=201
readonly EXIT_DATA_CORRUPTION=202
readonly EXIT_EXTERNAL_SERVICE_ERROR=203
readonly EXIT_TIMEOUT=204
readonly EXIT_RESOURCE_EXHAUSTED=205

# ============================================================================
# ERROR CATEGORIZATION
# ============================================================================

# Error category constants
readonly ERROR_CAT_RECOVERABLE="recoverable"
readonly ERROR_CAT_NON_RECOVERABLE="non_recoverable" 
readonly ERROR_CAT_CRITICAL="critical"
readonly ERROR_CAT_TRANSIENT="transient"
readonly ERROR_CAT_PERMANENT="permanent"

# Map exit codes to categories
_get_error_category() {
    local exit_code="$1"
    case "$exit_code" in
        0) echo "success" ;;
        $EXIT_RESOURCE_UNAVAILABLE|$EXIT_RATE_LIMITED|$EXIT_TIMEOUT) echo "$ERROR_CAT_RECOVERABLE" ;;
        $EXIT_SYSTEM_LOCKED|$EXIT_CIRCUIT_BREAKER_OPEN) echo "$ERROR_CAT_TRANSIENT" ;;
        $EXIT_GOVERNANCE_VIOLATION|$EXIT_BUDGET_EXCEEDED|$EXIT_AUTHENTICATION_FAILED|$EXIT_AUTHORIZATION_FAILED) echo "$ERROR_CAT_NON_RECOVERABLE" ;;
        $EXIT_CRITICAL_DEPENDENCY_FAILED|$EXIT_DATA_CORRUPTION) echo "$ERROR_CAT_CRITICAL" ;;
        $EXIT_INVALID_ENVELOPE|$EXIT_VALIDATION_FAILED) echo "$ERROR_CAT_PERMANENT" ;;
        *) echo "$ERROR_CAT_NON_RECOVERABLE" ;;
    esac
}

# Check if error is recoverable
is_recoverable_error() {
    local exit_code="$1"
    local category
    category=$(_get_error_category "$exit_code")
    [[ "$category" == "$ERROR_CAT_RECOVERABLE" || "$category" == "$ERROR_CAT_TRANSIENT" ]]
}

# ============================================================================
# DEAD LETTER QUEUE (DLQ) INTEGRATION
# ============================================================================

# DLQ Redis key prefix
readonly DLQ_PREFIX="dlq"
readonly DLQ_ENVELOPES_KEY="${DLQ_PREFIX}:envelopes"
readonly DLQ_ERRORS_KEY="${DLQ_PREFIX}:errors"
readonly DLQ_STATS_KEY="${DLQ_PREFIX}:stats"

# Send envelope to Dead Letter Queue
dlq_send_envelope() {
    local envelope="$1"
    local error_details="$2"
    local retry_count="${3:-0}"
    
    local dlq_entry
    dlq_entry=$(jq -n \
        --argjson envelope "$envelope" \
        --arg error_details "$error_details" \
        --arg retry_count "$retry_count" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg workflow_execution_id "${WORKFLOW_EXECUTION_ID:-unknown}" \
        --arg hook_name "${HOOK_NAME:-unknown}" \
        '{
            envelope: $envelope,
            error_details: $error_details,
            retry_count: ($retry_count | tonumber),
            timestamp: $timestamp,
            workflow_execution_id: $workflow_execution_id,
            hook_name: $hook_name,
            dlq_id: ($timestamp + "_" + $workflow_execution_id)
        }')
    
    # Add to DLQ
    redis-cli LPUSH "$DLQ_ENVELOPES_KEY" "$dlq_entry" >/dev/null
    redis-cli EXPIRE "$DLQ_ENVELOPES_KEY" 604800 >/dev/null  # 7 days retention
    
    # Update DLQ statistics
    redis-cli HINCRBY "$DLQ_STATS_KEY" "total_envelopes" 1 >/dev/null
    redis-cli HINCRBY "$DLQ_STATS_KEY" "$(date +%Y-%m-%d)" 1 >/dev/null
    redis-cli EXPIRE "$DLQ_STATS_KEY" 2592000 >/dev/null  # 30 days retention
    
    log_error "dlq_operation" "envelope_sent" "Envelope sent to DLQ: retry_count=$retry_count"
}

# Get DLQ statistics
dlq_get_stats() {
    redis-cli HGETALL "$DLQ_STATS_KEY" | paste - - | while IFS=$'\t' read -r key value; do
        echo "$key: $value"
    done
}

# Peek at latest DLQ entries without removing them
dlq_peek() {
    local limit="${1:-10}"
    redis-cli LRANGE "$DLQ_ENVELOPES_KEY" 0 "$((limit-1))"
}

# ============================================================================
# RETRY LOGIC WITH EXPONENTIAL BACKOFF
# ============================================================================

# Default retry configuration
readonly DEFAULT_MAX_RETRIES=3
readonly DEFAULT_BASE_DELAY=1
readonly DEFAULT_MAX_DELAY=60
readonly DEFAULT_BACKOFF_MULTIPLIER=2

# Execute command with retry logic and exponential backoff
retry_with_backoff() {
    local max_retries="${1:-$DEFAULT_MAX_RETRIES}"
    local base_delay="${2:-$DEFAULT_BASE_DELAY}"
    local max_delay="${3:-$DEFAULT_MAX_DELAY}"
    local backoff_multiplier="${4:-$DEFAULT_BACKOFF_MULTIPLIER}"
    shift 4
    local command=("$@")
    
    local attempt=1
    local delay="$base_delay"
    
    while [[ $attempt -le $max_retries ]]; do
        log_info "retry_attempt" "executing" "Attempt $attempt/$max_retries: ${command[*]}"
        
        if "${command[@]}"; then
            log_info "retry_success" "completed" "Command succeeded on attempt $attempt"
            return 0
        fi
        
        local exit_code=$?
        local category
        category=$(_get_error_category "$exit_code")
        
        # Don't retry permanent errors
        if [[ "$category" == "$ERROR_CAT_PERMANENT" || "$category" == "$ERROR_CAT_NON_RECOVERABLE" ]]; then
            log_error "retry_abort" "permanent_error" "Aborting retry due to permanent error (exit_code=$exit_code, category=$category)"
            return "$exit_code"
        fi
        
        if [[ $attempt -eq $max_retries ]]; then
            log_error "retry_exhausted" "failed" "All retry attempts exhausted (exit_code=$exit_code)"
            return $EXIT_RETRY_EXHAUSTED
        fi
        
        log_warning "retry_delay" "waiting" "Attempt $attempt failed (exit_code=$exit_code), waiting ${delay}s before retry"
        sleep "$delay"
        
        # Calculate next delay with exponential backoff
        delay=$(( delay * backoff_multiplier ))
        if [[ $delay -gt $max_delay ]]; then
            delay="$max_delay"
        fi
        
        ((attempt++))
    done
}

# ============================================================================
# CIRCUIT BREAKER PATTERN
# ============================================================================

# Circuit breaker states
readonly CB_STATE_CLOSED="closed"
readonly CB_STATE_OPEN="open" 
readonly CB_STATE_HALF_OPEN="half_open"

# Circuit breaker configuration
readonly CB_FAILURE_THRESHOLD=5
readonly CB_RECOVERY_TIMEOUT=60
readonly CB_SUCCESS_THRESHOLD=2

# Get circuit breaker key for a service
_cb_get_key() {
    local service="$1"
    echo "cb:${service}"
}

# Initialize circuit breaker for a service
cb_init() {
    local service="$1"
    local key
    key=$(_cb_get_key "$service")
    
    redis-cli HMSET "$key" \
        "state" "$CB_STATE_CLOSED" \
        "failure_count" 0 \
        "success_count" 0 \
        "last_failure_time" 0 \
        "failure_threshold" "$CB_FAILURE_THRESHOLD" \
        "recovery_timeout" "$CB_RECOVERY_TIMEOUT" \
        "success_threshold" "$CB_SUCCESS_THRESHOLD" >/dev/null
    
    redis-cli EXPIRE "$key" 3600 >/dev/null  # 1 hour expiry
}

# Get circuit breaker state
cb_get_state() {
    local service="$1"
    local key
    key=$(_cb_get_key "$service")
    
    local state
    state=$(redis-cli HGET "$key" "state")
    echo "${state:-$CB_STATE_CLOSED}"
}

# Check if circuit breaker allows request
cb_can_execute() {
    local service="$1"
    local key
    key=$(_cb_get_key "$service")
    
    local state
    state=$(cb_get_state "$service")
    
    case "$state" in
        "$CB_STATE_CLOSED")
            return 0  # Allow execution
            ;;
        "$CB_STATE_OPEN")
            local last_failure_time recovery_timeout current_time
            last_failure_time=$(redis-cli HGET "$key" "last_failure_time")
            recovery_timeout=$(redis-cli HGET "$key" "recovery_timeout")
            current_time=$(date +%s)
            
            if [[ $((current_time - last_failure_time)) -gt $recovery_timeout ]]; then
                # Transition to half-open
                redis-cli HSET "$key" "state" "$CB_STATE_HALF_OPEN" >/dev/null
                log_info "circuit_breaker" "state_transition" "Circuit breaker for $service: OPEN -> HALF_OPEN"
                return 0
            else
                log_warning "circuit_breaker" "blocked" "Circuit breaker for $service is OPEN, blocking request"
                return 1
            fi
            ;;
        "$CB_STATE_HALF_OPEN")
            return 0  # Allow limited execution
            ;;
    esac
}

# Record circuit breaker success
cb_record_success() {
    local service="$1"
    local key
    key=$(_cb_get_key "$service")
    
    local state
    state=$(cb_get_state "$service")
    
    case "$state" in
        "$CB_STATE_CLOSED")
            redis-cli HSET "$key" "failure_count" 0 >/dev/null
            ;;
        "$CB_STATE_HALF_OPEN")
            local success_count success_threshold
            success_count=$(redis-cli HINCRBY "$key" "success_count" 1)
            success_threshold=$(redis-cli HGET "$key" "success_threshold")
            
            if [[ $success_count -ge $success_threshold ]]; then
                # Transition to closed
                redis-cli HMSET "$key" \
                    "state" "$CB_STATE_CLOSED" \
                    "failure_count" 0 \
                    "success_count" 0 >/dev/null
                log_info "circuit_breaker" "state_transition" "Circuit breaker for $service: HALF_OPEN -> CLOSED"
            fi
            ;;
    esac
}

# Record circuit breaker failure
cb_record_failure() {
    local service="$1"
    local key
    key=$(_cb_get_key "$service")
    
    local failure_count failure_threshold current_time
    failure_count=$(redis-cli HINCRBY "$key" "failure_count" 1)
    failure_threshold=$(redis-cli HGET "$key" "failure_threshold")
    current_time=$(date +%s)
    
    redis-cli HMSET "$key" \
        "last_failure_time" "$current_time" \
        "success_count" 0 >/dev/null
    
    local state
    state=$(cb_get_state "$service")
    
    if [[ $failure_count -ge $failure_threshold ]] && [[ "$state" != "$CB_STATE_OPEN" ]]; then
        # Transition to open
        redis-cli HSET "$key" "state" "$CB_STATE_OPEN" >/dev/null
        log_error "circuit_breaker" "state_transition" "Circuit breaker for $service: $state -> OPEN (failures: $failure_count)"
    fi
}

# Execute command with circuit breaker protection
cb_execute() {
    local service="$1"
    shift
    local command=("$@")
    
    # Initialize circuit breaker if it doesn't exist
    if [[ -z "$(redis-cli HGET "$(_cb_get_key "$service")" "state")" ]]; then
        cb_init "$service"
    fi
    
    # Check if execution is allowed
    if ! cb_can_execute "$service"; then
        return $EXIT_CIRCUIT_BREAKER_OPEN
    fi
    
    # Execute command
    if "${command[@]}"; then
        cb_record_success "$service"
        return 0
    else
        local exit_code=$?
        cb_record_failure "$service"
        return "$exit_code"
    fi
}

# ============================================================================
# ERROR TRAP AND RECOVERY MECHANISMS
# ============================================================================

# Global error tracking
declare -g ERROR_TRAP_ENABLED=false
declare -g ERROR_CLEANUP_FUNCTIONS=()

# Enable error trap
enable_error_trap() {
    if [[ "$ERROR_TRAP_ENABLED" == "true" ]]; then
        return 0
    fi
    
    set -eE  # Exit on error, inherit traps in functions
    trap '_error_trap_handler $? $LINENO $BASH_COMMAND' ERR
    trap '_exit_trap_handler $?' EXIT
    ERROR_TRAP_ENABLED=true
    
    log_info "error_trap" "enabled" "Error trap enabled for script"
}

# Disable error trap
disable_error_trap() {
    if [[ "$ERROR_TRAP_ENABLED" == "false" ]]; then
        return 0
    fi
    
    trap - ERR EXIT
    ERROR_TRAP_ENABLED=false
    
    log_info "error_trap" "disabled" "Error trap disabled for script"
}

# Register cleanup function
register_cleanup_function() {
    local func_name="$1"
    ERROR_CLEANUP_FUNCTIONS+=("$func_name")
    log_info "cleanup" "registered" "Cleanup function registered: $func_name"
}

# Execute all cleanup functions
_execute_cleanup_functions() {
    for func in "${ERROR_CLEANUP_FUNCTIONS[@]}"; do
        if declare -F "$func" >/dev/null; then
            log_info "cleanup" "executing" "Executing cleanup function: $func"
            "$func" || log_error "cleanup" "failed" "Cleanup function failed: $func"
        fi
    done
    ERROR_CLEANUP_FUNCTIONS=()
}

# Error trap handler
_error_trap_handler() {
    local exit_code="$1"
    local line_no="$2"
    local command="$3"
    
    # Get stack trace
    local stack_trace
    stack_trace=$(get_stack_trace)
    
    # Log structured error with context
    log_error "error_trap" "caught" "Script error caught: exit_code=$exit_code, line=$line_no, command='$command', stack_trace='$stack_trace'"
    
    # Execute cleanup functions
    _execute_cleanup_functions
    
    # Send to DLQ if envelope is available
    if [[ -n "${INTERACTION_ENVELOPE:-}" ]]; then
        local error_details
        error_details=$(jq -n \
            --arg exit_code "$exit_code" \
            --arg line_no "$line_no" \
            --arg command "$command" \
            --arg stack_trace "$stack_trace" \
            --arg hook_name "${HOOK_NAME:-unknown}" \
            '{
                error_type: "script_error",
                exit_code: ($exit_code | tonumber),
                line_no: ($line_no | tonumber), 
                command: $command,
                stack_trace: $stack_trace,
                hook_name: $hook_name
            }')
        
        dlq_send_envelope "$INTERACTION_ENVELOPE" "$error_details" "${RETRY_COUNT:-0}"
    fi
    
    return "$exit_code"
}

# Exit trap handler
_exit_trap_handler() {
    local exit_code="$1"
    
    if [[ "$exit_code" -ne 0 ]]; then
        log_error "exit_trap" "non_zero_exit" "Script exiting with non-zero code: $exit_code"
    fi
    
    # Clean up workflow state on exit
    if [[ -n "${WORKFLOW_EXECUTION_ID:-}" ]] && command -v state_destroy >/dev/null 2>&1; then
        state_destroy || true
    fi
}

# ============================================================================
# STACK TRACE AND DEBUGGING
# ============================================================================

# Get current stack trace
get_stack_trace() {
    local frame=1
    local stack_trace=""
    
    while [[ $frame -lt ${#BASH_SOURCE[@]} ]]; do
        local filename="${BASH_SOURCE[$frame]}"
        local function_name="${FUNCNAME[$frame]}"
        local line_no="${BASH_LINENO[$((frame-1))]}"
        
        if [[ -n "$stack_trace" ]]; then
            stack_trace="$stack_trace -> "
        fi
        
        stack_trace="${stack_trace}${function_name}() at ${filename##*/}:${line_no}"
        ((frame++))
    done
    
    echo "$stack_trace"
}

# Get function call hierarchy
get_call_stack() {
    local frame=1
    local call_stack=()
    
    while [[ $frame -lt ${#FUNCNAME[@]} ]]; do
        call_stack+=("${FUNCNAME[$frame]}")
        ((frame++))
    done
    
    printf '%s\n' "${call_stack[@]}"
}

# ============================================================================
# ERROR AGGREGATION AND REPORTING
# ============================================================================

# Redis key for error aggregation
readonly ERROR_STATS_KEY="error_stats"

# Record error statistics
record_error_stats() {
    local error_type="$1"
    local exit_code="$2"
    local hook_name="${3:-${HOOK_NAME:-unknown}}"
    local date_key
    date_key=$(date +%Y-%m-%d)
    
    # Increment counters
    redis-cli HINCRBY "${ERROR_STATS_KEY}:${date_key}" "total_errors" 1 >/dev/null
    redis-cli HINCRBY "${ERROR_STATS_KEY}:${date_key}" "error_type_${error_type}" 1 >/dev/null
    redis-cli HINCRBY "${ERROR_STATS_KEY}:${date_key}" "exit_code_${exit_code}" 1 >/dev/null
    redis-cli HINCRBY "${ERROR_STATS_KEY}:${date_key}" "hook_${hook_name}" 1 >/dev/null
    
    # Set expiration (30 days)
    redis-cli EXPIRE "${ERROR_STATS_KEY}:${date_key}" 2592000 >/dev/null
}

# Get error statistics for a date range
get_error_stats() {
    local start_date="${1:-$(date -d '7 days ago' +%Y-%m-%d)}"
    local end_date="${2:-$(date +%Y-%m-%d)}"
    
    local current_date="$start_date"
    local total_errors=0
    
    echo "Error Statistics from $start_date to $end_date:"
    echo "================================================"
    
    while [[ "$current_date" <= "$end_date" ]]; do
        local date_stats
        date_stats=$(redis-cli HGETALL "${ERROR_STATS_KEY}:${current_date}" 2>/dev/null)
        
        if [[ -n "$date_stats" ]]; then
            echo "Date: $current_date"
            echo "$date_stats" | paste - - | while IFS=$'\t' read -r key value; do
                echo "  $key: $value"
                if [[ "$key" == "total_errors" ]]; then
                    total_errors=$((total_errors + value))
                fi
            done
            echo ""
        fi
        
        # Move to next date
        current_date=$(date -d "$current_date + 1 day" +%Y-%m-%d)
    done
    
    echo "Total errors in period: $total_errors"
}

# ============================================================================
# RESOURCE CLEANUP ON ERROR
# ============================================================================

# Default cleanup function for common resources
default_cleanup() {
    local session_id="${SESSION_ID:-}"
    local temp_files=("${TEMP_FILES[@]:-}")
    
    # Release resource locks
    if [[ -n "$session_id" ]] && command -v release_all_locks_for_session >/dev/null 2>&1; then
        log_info "cleanup" "releasing_locks" "Releasing all locks for session: $session_id"
        release_all_locks_for_session "$session_id" || log_warning "cleanup" "lock_release_failed" "Failed to release locks for session: $session_id"
    fi
    
    # Clean up temporary files
    for temp_file in "${temp_files[@]}"; do
        if [[ -f "$temp_file" ]]; then
            log_info "cleanup" "removing_temp_file" "Removing temporary file: $temp_file"
            rm -f "$temp_file" || log_warning "cleanup" "temp_file_removal_failed" "Failed to remove temporary file: $temp_file"
        fi
    done
    
    # Update session status to error if applicable
    if [[ -n "$session_id" ]] && command -v update_session_status >/dev/null 2>&1; then
        log_info "cleanup" "updating_session_status" "Updating session status to error: $session_id"
        update_session_status "$session_id" "error" || log_warning "cleanup" "session_update_failed" "Failed to update session status: $session_id"
    fi
}

# ============================================================================
# HIGH-LEVEL ERROR HANDLING FUNCTIONS
# ============================================================================

# Handle error with automatic categorization and appropriate response
handle_error() {
    local exit_code="$1"
    local context="${2:-unknown}"
    local envelope="${3:-${INTERACTION_ENVELOPE:-}}"
    
    local category
    category=$(_get_error_category "$exit_code")
    
    # Record error statistics
    record_error_stats "handled_error" "$exit_code" "$context"
    
    # Log the error
    log_error "error_handler" "processing" "Handling error: exit_code=$exit_code, category=$category, context=$context"
    
    # Handle based on category
    case "$category" in
        "$ERROR_CAT_CRITICAL")
            log_critical "error_handler" "critical_error" "Critical error detected, initiating emergency procedures"
            _execute_cleanup_functions
            if [[ -n "$envelope" ]]; then
                dlq_send_envelope "$envelope" "Critical error: exit_code=$exit_code, context=$context"
            fi
            return "$exit_code"
            ;;
        "$ERROR_CAT_NON_RECOVERABLE"|"$ERROR_CAT_PERMANENT")
            log_error "error_handler" "permanent_error" "Permanent error, no retry will be attempted"
            if [[ -n "$envelope" ]]; then
                dlq_send_envelope "$envelope" "Permanent error: exit_code=$exit_code, context=$context"
            fi
            return "$exit_code"
            ;;
        "$ERROR_CAT_RECOVERABLE"|"$ERROR_CAT_TRANSIENT")
            log_warning "error_handler" "recoverable_error" "Recoverable error detected, may retry"
            return "$exit_code"  # Let caller decide on retry
            ;;
        *)
            log_error "error_handler" "unknown_error" "Unknown error category"
            return "$exit_code"
            ;;
    esac
}

# Execute command with full error handling (retry + circuit breaker + DLQ)
execute_with_error_handling() {
    local service="$1"
    local max_retries="${2:-$DEFAULT_MAX_RETRIES}"
    shift 2
    local command=("$@")
    
    # Initialize circuit breaker
    if [[ -z "$(redis-cli HGET "$(_cb_get_key "$service")" "state")" ]]; then
        cb_init "$service"
    fi
    
    # Execute with retry and circuit breaker
    local attempt=1
    local delay="$DEFAULT_BASE_DELAY"
    
    while [[ $attempt -le $max_retries ]]; do
        # Check circuit breaker
        if ! cb_can_execute "$service"; then
            log_error "error_handling" "circuit_breaker_open" "Circuit breaker open for service: $service"
            return $EXIT_CIRCUIT_BREAKER_OPEN
        fi
        
        log_info "error_handling" "executing" "Executing command (attempt $attempt/$max_retries): ${command[*]}"
        
        # Execute command
        if "${command[@]}"; then
            cb_record_success "$service"
            log_info "error_handling" "success" "Command succeeded on attempt $attempt"
            return 0
        fi
        
        local exit_code=$?
        cb_record_failure "$service"
        
        # Handle the error
        local category
        category=$(_get_error_category "$exit_code")
        
        # Don't retry permanent errors
        if [[ "$category" == "$ERROR_CAT_PERMANENT" || "$category" == "$ERROR_CAT_NON_RECOVERABLE" ]]; then
            log_error "error_handling" "permanent_error" "Permanent error, aborting retry (exit_code=$exit_code)"
            return "$exit_code"
        fi
        
        if [[ $attempt -eq $max_retries ]]; then
            log_error "error_handling" "retry_exhausted" "All retry attempts exhausted (exit_code=$exit_code)"
            
            # Send to DLQ if envelope available
            if [[ -n "${INTERACTION_ENVELOPE:-}" ]]; then
                dlq_send_envelope "$INTERACTION_ENVELOPE" "Retry exhausted: exit_code=$exit_code, service=$service" "$max_retries"
            fi
            
            return $EXIT_RETRY_EXHAUSTED
        fi
        
        log_warning "error_handling" "retry_delay" "Command failed (exit_code=$exit_code), waiting ${delay}s before retry $((attempt+1))"
        sleep "$delay"
        
        # Exponential backoff
        delay=$(( delay * DEFAULT_BACKOFF_MULTIPLIER ))
        if [[ $delay -gt $DEFAULT_MAX_DELAY ]]; then
            delay="$DEFAULT_MAX_DELAY"
        fi
        
        ((attempt++))
    done
}

# ============================================================================
# INITIALIZATION
# ============================================================================

# Register default cleanup function
register_cleanup_function "default_cleanup"

# Log library initialization
log_info "error_handling" "initialized" "Error handling library loaded successfully"