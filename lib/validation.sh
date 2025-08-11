#!/bin/bash
# Input Validation and Sanitization Library
# Purpose: Provides functions for validating and sanitizing inputs across the system
# Dependencies: lib/logging.sh

set -e

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/logging.sh" || { echo "ERROR: Failed to source logging.sh"; exit 1; }

# Validation patterns
readonly UUID_PATTERN='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
readonly SESSION_ID_PATTERN='^session-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
readonly TASK_ID_PATTERN='^task-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
readonly AGENT_ID_PATTERN='^[a-zA-Z0-9][a-zA-Z0-9-_]{2,63}$'
readonly SAFE_PATH_PATTERN='^[a-zA-Z0-9/_.-]+$'
readonly EMAIL_PATTERN='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'

# Validate UUID format
validate_uuid() {
    local uuid=$1
    local field_name=${2:-"UUID"}
    
    if [[ -z "$uuid" ]]; then
        log_error "Validation failed: empty value" "{\"field\":\"$field_name\",\"type\":\"uuid\"}"
        return 1
    fi
    
    if ! [[ "$uuid" =~ $UUID_PATTERN ]]; then
        log_error "Validation failed: invalid UUID format" "{\"field\":\"$field_name\",\"value\":\"$uuid\"}"
        return 1
    fi
    
    return 0
}

# Validate session ID format
validate_session_id() {
    local session_id=$1
    
    if [[ -z "$session_id" ]]; then
        log_error "Validation failed: empty session_id" "{\"type\":\"session_id\"}"
        return 1
    fi
    
    if ! [[ "$session_id" =~ $SESSION_ID_PATTERN ]]; then
        log_error "Validation failed: invalid session_id format" "{\"value\":\"$session_id\"}"
        return 1
    fi
    
    return 0
}

# Validate task ID format
validate_task_id() {
    local task_id=$1
    
    if [[ -z "$task_id" ]]; then
        log_error "Validation failed: empty task_id" "{\"type\":\"task_id\"}"
        return 1
    fi
    
    if ! [[ "$task_id" =~ $TASK_ID_PATTERN ]]; then
        log_error "Validation failed: invalid task_id format" "{\"value\":\"$task_id\"}"
        return 1
    fi
    
    return 0
}

# Validate agent ID format
validate_agent_id() {
    local agent_id=$1
    
    if [[ -z "$agent_id" ]]; then
        log_error "Validation failed: empty agent_id" "{\"type\":\"agent_id\"}"
        return 1
    fi
    
    if ! [[ "$agent_id" =~ $AGENT_ID_PATTERN ]]; then
        log_error "Validation failed: invalid agent_id format" "{\"value\":\"$agent_id\"}"
        return 1
    fi
    
    return 0
}

# Validate file path (prevent directory traversal)
validate_safe_path() {
    local path=$1
    local base_dir=${2:-"/"}
    
    if [[ -z "$path" ]]; then
        log_error "Validation failed: empty path" "{\"type\":\"path\"}"
        return 1
    fi
    
    # Check for directory traversal attempts
    if [[ "$path" == *".."* ]] || [[ "$path" == *"~"* ]]; then
        log_error "Validation failed: potential directory traversal" "{\"path\":\"$path\"}"
        return 1
    fi
    
    # Check for valid characters
    if ! [[ "$path" =~ $SAFE_PATH_PATTERN ]]; then
        log_error "Validation failed: invalid path characters" "{\"path\":\"$path\"}"
        return 1
    fi
    
    # Ensure path is within base directory
    local abs_path=$(realpath -m "$base_dir/$path" 2>/dev/null) || abs_path=""
    local abs_base=$(realpath "$base_dir" 2>/dev/null) || abs_base=""
    
    if [[ -z "$abs_path" ]] || [[ -z "$abs_base" ]] || [[ "$abs_path" != "$abs_base"* ]]; then
        log_error "Validation failed: path outside base directory" "{\"path\":\"$path\",\"base\":\"$base_dir\"}"
        return 1
    fi
    
    return 0
}

# Validate email format
validate_email() {
    local email=$1
    
    if [[ -z "$email" ]]; then
        log_error "Validation failed: empty email" "{\"type\":\"email\"}"
        return 1
    fi
    
    if ! [[ "$email" =~ $EMAIL_PATTERN ]]; then
        log_error "Validation failed: invalid email format" "{\"value\":\"$email\"}"
        return 1
    fi
    
    return 0
}

# Validate JSON format
validate_json() {
    local json=$1
    local schema_file=${2:-""}
    
    if [[ -z "$json" ]]; then
        log_error "Validation failed: empty JSON" "{\"type\":\"json\"}"
        return 1
    fi
    
    # Basic JSON validation
    if ! echo "$json" | jq . > /dev/null 2>&1; then
        log_error "Validation failed: invalid JSON format" "{\"error\":\"parse_error\"}"
        return 1
    fi
    
    # Schema validation if provided
    if [[ -n "$schema_file" ]] && [[ -f "$schema_file" ]]; then
        # Note: This would require a JSON schema validator like ajv-cli
        log_warn "JSON schema validation not implemented" "{\"schema\":\"$schema_file\"}"
    fi
    
    return 0
}

# Validate numeric value with range
validate_number() {
    local value=$1
    local min=${2:-""}
    local max=${3:-""}
    local field_name=${4:-"number"}
    
    if [[ -z "$value" ]]; then
        log_error "Validation failed: empty value" "{\"field\":\"$field_name\",\"type\":\"number\"}"
        return 1
    fi
    
    # Check if it's a valid number
    if ! [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        log_error "Validation failed: not a number" "{\"field\":\"$field_name\",\"value\":\"$value\"}"
        return 1
    fi
    
    # Check range if specified
    if [[ -n "$min" ]] && (( $(echo "$value < $min" | bc -l) )); then
        log_error "Validation failed: below minimum" "{\"field\":\"$field_name\",\"value\":$value,\"min\":$min}"
        return 1
    fi
    
    if [[ -n "$max" ]] && (( $(echo "$value > $max" | bc -l) )); then
        log_error "Validation failed: above maximum" "{\"field\":\"$field_name\",\"value\":$value,\"max\":$max}"
        return 1
    fi
    
    return 0
}

# Validate timestamp format
validate_timestamp() {
    local timestamp=$1
    local format=${2:-"%Y-%m-%dT%H:%M:%SZ"}  # ISO 8601 by default
    
    if [[ -z "$timestamp" ]]; then
        log_error "Validation failed: empty timestamp" "{\"type\":\"timestamp\"}"
        return 1
    fi
    
    # Try to parse the timestamp
    if ! date -d "$timestamp" "+$format" > /dev/null 2>&1; then
        log_error "Validation failed: invalid timestamp format" "{\"value\":\"$timestamp\",\"expected_format\":\"$format\"}"
        return 1
    fi
    
    return 0
}

# Sanitize string for safe shell usage
sanitize_string() {
    local input=$1
    local max_length=${2:-1024}
    
    # Remove null bytes
    local sanitized="${input//\\x00/}"
    
    # Escape special characters
    sanitized="${sanitized//\\/\\\\}"
    sanitized="${sanitized//\"/\\\"}"
    sanitized="${sanitized//\$/\\\$}"
    sanitized="${sanitized//\`/\\\`}"
    
    # Truncate if too long
    if [[ ${#sanitized} -gt $max_length ]]; then
        sanitized="${sanitized:0:$max_length}"
        log_warn "String truncated during sanitization" "{\"original_length\":${#input},\"max_length\":$max_length}"
    fi
    
    echo "$sanitized"
}

# Sanitize path for safe usage
sanitize_path() {
    local path=$1
    
    # Remove potentially dangerous characters
    local sanitized="${path//[^a-zA-Z0-9._\/-]/}"
    
    # Remove leading/trailing slashes
    sanitized="${sanitized#/}"
    sanitized="${sanitized%/}"
    
    # Collapse multiple slashes
    sanitized="${sanitized//\/\//\/}"
    
    echo "$sanitized"
}

# Validate required fields in JSON
validate_required_fields() {
    local json=$1
    shift
    local required_fields=("$@")
    
    for field in "${required_fields[@]}"; do
        if ! echo "$json" | jq -e ".$field" > /dev/null 2>&1; then
            log_error "Validation failed: missing required field" "{\"field\":\"$field\"}"
            return 1
        fi
        
        # Check if field is not null or empty
        local value=$(echo "$json" | jq -r ".$field")
        if [[ "$value" == "null" ]] || [[ -z "$value" ]]; then
            log_error "Validation failed: empty required field" "{\"field\":\"$field\"}"
            return 1
        fi
    done
    
    return 0
}

# Validate enum value
validate_enum() {
    local value=$1
    local field_name=$2
    shift 2
    local valid_values=("$@")
    
    if [[ -z "$value" ]]; then
        log_error "Validation failed: empty value" "{\"field\":\"$field_name\",\"type\":\"enum\"}"
        return 1
    fi
    
    for valid in "${valid_values[@]}"; do
        if [[ "$value" == "$valid" ]]; then
            return 0
        fi
    done
    
    log_error "Validation failed: invalid enum value" "{\"field\":\"$field_name\",\"value\":\"$value\",\"valid_values\":\"${valid_values[*]}\"}"
    return 1
}

# Validate ACP envelope structure
validate_acp_envelope() {
    local envelope=$1
    
    # Validate JSON format
    if ! validate_json "$envelope"; then
        return 1
    fi
    
    # Check required fields
    local required_fields=("protocol_version" "agent_id" "task_id" "session_id" "event_type" "timestamp" "payload")
    if ! validate_required_fields "$envelope" "${required_fields[@]}"; then
        return 1
    fi
    
    # Validate specific field formats
    local agent_id=$(echo "$envelope" | jq -r '.agent_id')
    local task_id=$(echo "$envelope" | jq -r '.task_id')
    local session_id=$(echo "$envelope" | jq -r '.session_id')
    local event_type=$(echo "$envelope" | jq -r '.event_type')
    local timestamp=$(echo "$envelope" | jq -r '.timestamp')
    
    validate_agent_id "$agent_id" || return 1
    validate_task_id "$task_id" || return 1
    validate_session_id "$session_id" || return 1
    validate_timestamp "$timestamp" || return 1
    validate_enum "$event_type" "event_type" "task_declaration" "activity_report" "completion_report" "error_report" || return 1
    
    return 0
}

# Export functions
export -f validate_uuid
export -f validate_session_id
export -f validate_task_id
export -f validate_agent_id
export -f validate_safe_path
export -f validate_email
export -f validate_json
export -f validate_number
export -f validate_timestamp
export -f sanitize_string
export -f sanitize_path
export -f validate_required_fields
export -f validate_enum
export -f validate_acp_envelope