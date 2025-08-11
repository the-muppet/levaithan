#!/bin/bash
# Error Handling Library
# Purpose: Standardized error management and recovery strategies
# Dependencies: lib/logging.sh

set -e

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/logging.sh" || { echo "ERROR: Failed to source logging.sh"; exit 1; }

# Error codes
readonly ERR_SUCCESS=0
readonly ERR_GENERAL=1
readonly ERR_CONFIG=2
readonly ERR_VALIDATION=3
readonly ERR_DATABASE=4
readonly ERR_NETWORK=5
readonly ERR_PERMISSION=6
readonly ERR_RESOURCE_LOCKED=7
readonly ERR_TIMEOUT=8
readonly ERR_NOT_FOUND=9
readonly ERR_ALREADY_EXISTS=10
readonly ERR_BUDGET_EXCEEDED=11
readonly ERR_RATE_LIMIT=12
readonly ERR_DEPENDENCY=13
readonly ERR_STATE_INVALID=14
readonly ERR_AGENT_FAILURE=15

# Error code descriptions
declare -A ERROR_DESCRIPTIONS=(
    [ERR_SUCCESS]="Operation completed successfully"
    [ERR_GENERAL]="General error occurred"
    [ERR_CONFIG]="Configuration error"
    [ERR_VALIDATION]="Input validation failed"
    [ERR_DATABASE]="Database operation failed"
    [ERR_NETWORK]="Network error occurred"
    [ERR_PERMISSION]="Permission denied"
    [ERR_RESOURCE_LOCKED]="Resource is locked by another process"
    [ERR_TIMEOUT]="Operation timed out"
    [ERR_NOT_FOUND]="Resource not found"
    [ERR_ALREADY_EXISTS]="Resource already exists"
    [ERR_BUDGET_EXCEEDED]="Budget limit exceeded"
    [ERR_RATE_LIMIT]="Rate limit exceeded"
    [ERR_DEPENDENCY]="Required dependency not available"
    [ERR_STATE_INVALID]="Invalid state transition"
    [ERR_AGENT_FAILURE]="Agent execution failed"
)

# Global error context
declare -g ERROR_CONTEXT=""
declare -g ERROR_STACK=()
declare -g ERROR_RECOVERY_ATTEMPTED=0

# Set error context
set_error_context() {
    local context=$1
    ERROR_CONTEXT="$context"
    log_debug "Error context set" "{\"context\":\"$context\"}"
}

# Clear error context
clear_error_context() {
    ERROR_CONTEXT=""
    ERROR_STACK=()
    ERROR_RECOVERY_ATTEMPTED=0
}

# Handle error with structured logging
handle_error() {
    local error_code=$1
    local error_message=$2
    local error_details=${3:-"{}"}
    local exit_on_error=${4:-1}
    
    # Get description for known error codes
    local description="${ERROR_DESCRIPTIONS[$error_code]:-Unknown error}"
    
    # Build error object
    local error_json=$(jq -n \
        --arg code "$error_code" \
        --arg message "$error_message" \
        --arg description "$description" \
        --arg context "$ERROR_CONTEXT" \
        --argjson details "$error_details" \
        '{
            error_code: $code,
            error_message: $message,
            error_description: $description,
            context: $context,
            details: $details,
            timestamp: now | strftime("%Y-%m-%dT%H:%M:%SZ")
        }')
    
    # Log the error
    log_error "$error_message" "$error_json"
    
    # Add to error stack
    ERROR_STACK+=("$error_json")
    
    # Attempt recovery if handler is defined
    local recovery_func="recover_${error_code}"
    if declare -f "$recovery_func" > /dev/null && [[ $ERROR_RECOVERY_ATTEMPTED -eq 0 ]]; then
        ERROR_RECOVERY_ATTEMPTED=1
        log_info "Attempting error recovery" "{\"error_code\":\"$error_code\",\"recovery_func\":\"$recovery_func\"}"
        if $recovery_func "$error_details"; then
            log_info "Error recovery successful" "{\"error_code\":\"$error_code\"}"
            return 0
        else
            log_error "Error recovery failed" "{\"error_code\":\"$error_code\"}"
        fi
    fi
    
    # Exit if requested
    if [[ $exit_on_error -eq 1 ]]; then
        exit "${!error_code:-1}"
    fi
    
    return "${!error_code:-1}"
}

# Trap errors and provide context
trap_errors() {
    local exit_code=$?
    local line_number=$1
    local bash_lineno=$2
    local command="$3"
    
    if [[ $exit_code -ne 0 ]]; then
        local error_details=$(jq -n \
            --arg line "$line_number" \
            --arg bash_line "$bash_lineno" \
            --arg cmd "$command" \
            --arg file "${BASH_SOURCE[1]}" \
            '{
                line_number: $line,
                bash_line_number: $bash_line,
                command: $cmd,
                source_file: $file
            }')
        
        handle_error "ERR_GENERAL" "Command failed" "$error_details"
    fi
}

# Enable error trapping for a script
enable_error_trapping() {
    set -E
    set -o pipefail
    trap 'trap_errors $LINENO $BASH_LINENO "$BASH_COMMAND"' ERR
}

# Retry with exponential backoff
retry_with_backoff() {
    local max_attempts=$1
    local initial_delay=$2
    shift 2
    local command=("$@")
    
    local attempt=1
    local delay=$initial_delay
    
    while [[ $attempt -le $max_attempts ]]; do
        log_debug "Executing command with retry" "{\"attempt\":$attempt,\"max_attempts\":$max_attempts}"
        
        if "${command[@]}"; then
            return 0
        fi
        
        local exit_code=$?
        log_warn "Command failed, retrying" "{\"attempt\":$attempt,\"exit_code\":$exit_code,\"delay\":$delay}"
        
        if [[ $attempt -lt $max_attempts ]]; then
            sleep $delay
            delay=$((delay * 2))
        fi
        
        ((attempt++))
    done
    
    handle_error "ERR_GENERAL" "Command failed after $max_attempts attempts" "{\"command\":\"${command[*]}\"}" 0
    return 1
}

# Check dependencies
check_dependencies() {
    local deps=("$@")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        handle_error "ERR_DEPENDENCY" "Missing required dependencies" "{\"missing\":\"${missing[*]}\"}"
        return 1
    fi
    
    return 0
}

# Validate environment
validate_environment() {
    local required_vars=("$@")
    local missing=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing+=("$var")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        handle_error "ERR_CONFIG" "Missing required environment variables" "{\"missing\":\"${missing[*]}\"}"
        return 1
    fi
    
    return 0
}

# Recovery functions for specific error types
recover_ERR_DATABASE() {
    local details=$1
    log_info "Attempting database recovery" "$details"
    
    # Check if database is accessible
    if command -v psql &> /dev/null; then
        if psql -U "$POSTGRES_USER" -h "$POSTGRES_HOST" -c "SELECT 1" &> /dev/null; then
            log_info "Database connection restored"
            return 0
        fi
    fi
    
    return 1
}

recover_ERR_RESOURCE_LOCKED() {
    local details=$1
    local lock_id=$(echo "$details" | jq -r '.lock_id // empty')
    
    if [[ -n "$lock_id" ]]; then
        log_info "Checking lock status" "{\"lock_id\":\"$lock_id\"}"
        # Check if lock is stale (implementation would check Redis/DB)
        # For now, just return failure
    fi
    
    return 1
}

recover_ERR_RATE_LIMIT() {
    local details=$1
    local retry_after=$(echo "$details" | jq -r '.retry_after // 60')
    
    log_info "Rate limited, waiting before retry" "{\"retry_after\":$retry_after}"
    sleep "$retry_after"
    return 0
}

# Create error report
create_error_report() {
    local session_id=$1
    local task_id=$2
    
    local report=$(jq -n \
        --arg session "$session_id" \
        --arg task "$task_id" \
        --argjson errors "$(printf '%s\n' "${ERROR_STACK[@]}" | jq -s .)" \
        '{
            session_id: $session,
            task_id: $task,
            error_count: ($errors | length),
            errors: $errors,
            generated_at: now | strftime("%Y-%m-%dT%H:%M:%SZ")
        }')
    
    echo "$report"
}

# Safe execution wrapper
safe_execute() {
    local context=$1
    shift
    local command=("$@")
    
    set_error_context "$context"
    
    if "${command[@]}"; then
        clear_error_context
        return 0
    else
        local exit_code=$?
        handle_error "ERR_GENERAL" "Command execution failed in context: $context" "{\"exit_code\":$exit_code}" 0
        return $exit_code
    fi
}

# Assert condition with error handling
assert() {
    local condition=$1
    local error_message=$2
    local error_details=${3:-"{}"}
    
    if ! eval "$condition"; then
        handle_error "ERR_VALIDATION" "Assertion failed: $error_message" "$error_details"
        return 1
    fi
    
    return 0
}

# Graceful shutdown handler
graceful_shutdown() {
    local signal=$1
    local session_id=${2:-""}
    
    log_info "Graceful shutdown initiated" "{\"signal\":\"$signal\",\"session_id\":\"$session_id\"}"
    
    # Cleanup operations would go here
    # - Release locks
    # - Save state
    # - Notify dependent services
    
    exit 0
}

# Install signal handlers
install_signal_handlers() {
    local session_id=$1
    
    trap "graceful_shutdown SIGTERM '$session_id'" SIGTERM
    trap "graceful_shutdown SIGINT '$session_id'" SIGINT
    trap "graceful_shutdown SIGHUP '$session_id'" SIGHUP
}

# Export functions and variables
export -f handle_error
export -f set_error_context
export -f clear_error_context
export -f trap_errors
export -f enable_error_trapping
export -f retry_with_backoff
export -f check_dependencies
export -f validate_environment
export -f create_error_report
export -f safe_execute
export -f assert
export -f graceful_shutdown
export -f install_signal_handlers

# Export error codes
export ERR_SUCCESS ERR_GENERAL ERR_CONFIG ERR_VALIDATION ERR_DATABASE
export ERR_NETWORK ERR_PERMISSION ERR_RESOURCE_LOCKED ERR_TIMEOUT
export ERR_NOT_FOUND ERR_ALREADY_EXISTS ERR_BUDGET_EXCEEDED
export ERR_RATE_LIMIT ERR_DEPENDENCY ERR_STATE_INVALID ERR_AGENT_FAILURE