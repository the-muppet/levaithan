#!/bin/bash
# lib/validation.sh - Comprehensive input validation and sanitization library.
# Provides robust validation for the LevAIthan agent coordination system.

# Source dependencies
if [[ -z "$CLAUDE_PROJECT_DIR" ]]; then
    echo "FATAL: CLAUDE_PROJECT_DIR not set." >&2
    exit 1
fi

# Only source logging if not already sourced
if ! declare -f log_error >/dev/null 2>&1; then
    source "$CLAUDE_PROJECT_DIR/.claude/hooks/lib/logging.sh"
fi

# Validation result constants
readonly VALIDATION_SUCCESS=0
readonly VALIDATION_FAILURE=1
readonly VALIDATION_CRITICAL=2

# JSON Schema constants for InteractionEnvelope
readonly INTERACTION_ENVELOPE_REQUIRED_FIELDS="protocol_version agent_id task_id session_id event_type timestamp payload"
readonly VALID_EVENT_TYPES="task_declaration activity_report completion_report self_improvement_cycle"
readonly PROTOCOL_VERSION="1.0"

# =============================================================================
# CORE VALIDATION FUNCTIONS
# =============================================================================

# Validates that a string contains valid JSON
validate_json_structure() {
    local json_string="$1"
    local error_context="${2:-unknown}"
    
    if [[ -z "$json_string" ]]; then
        log_error "validation" "failed" "Empty JSON input in context: $error_context"
        return $VALIDATION_FAILURE
    fi
    
    if ! echo "$json_string" | jq empty 2>/dev/null; then
        log_error "validation" "failed" "Invalid JSON structure in context: $error_context"
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

# Validates that required fields exist in JSON object
validate_required_fields() {
    local json_string="$1"
    local required_fields="$2"
    local error_context="${3:-unknown}"
    
    if ! validate_json_structure "$json_string" "$error_context"; then
        return $VALIDATION_FAILURE
    fi
    
    local missing_fields=""
    for field in $required_fields; do
        if [[ $(echo "$json_string" | jq -r "has(\"$field\")") != "true" ]]; then
            missing_fields="$missing_fields $field"
        fi
    done
    
    if [[ -n "$missing_fields" ]]; then
        log_error "validation" "failed" "Missing required fields in $error_context:$missing_fields"
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

# Validates that fields contain non-null, non-empty values
validate_field_values() {
    local json_string="$1"
    local fields_to_check="$2"
    local error_context="${3:-unknown}"
    
    for field in $fields_to_check; do
        local value
        value=$(echo "$json_string" | jq -r ".$field // \"\"")
        
        if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
            log_error "validation" "failed" "Field '$field' is null or empty in context: $error_context"
            return $VALIDATION_FAILURE
        fi
    done
    
    return $VALIDATION_SUCCESS
}

# =============================================================================
# INTERACTION ENVELOPE VALIDATION
# =============================================================================

# Validates complete InteractionEnvelope structure and content
validate_interaction_envelope() {
    local envelope="$1"
    local error_context="${2:-interaction_envelope}"
    
    # Basic JSON structure validation
    if ! validate_json_structure "$envelope" "$error_context"; then
        return $VALIDATION_FAILURE
    fi
    
    # Required fields validation
    if ! validate_required_fields "$envelope" "$INTERACTION_ENVELOPE_REQUIRED_FIELDS" "$error_context"; then
        return $VALIDATION_FAILURE
    fi
    
    # Field value validation
    if ! validate_field_values "$envelope" "$INTERACTION_ENVELOPE_REQUIRED_FIELDS" "$error_context"; then
        return $VALIDATION_FAILURE
    fi
    
    # Protocol version validation
    local protocol_version
    protocol_version=$(echo "$envelope" | jq -r '.protocol_version')
    if [[ "$protocol_version" != "$PROTOCOL_VERSION" ]]; then
        log_error "validation" "failed" "Invalid protocol version '$protocol_version', expected '$PROTOCOL_VERSION'"
        return $VALIDATION_FAILURE
    fi
    
    # Event type validation
    local event_type
    event_type=$(echo "$envelope" | jq -r '.event_type')
    if ! validate_enum_value "$event_type" "$VALID_EVENT_TYPES" "event_type"; then
        return $VALIDATION_FAILURE
    fi
    
    # UUID validation for IDs
    local agent_id task_id session_id
    agent_id=$(echo "$envelope" | jq -r '.agent_id')
    task_id=$(echo "$envelope" | jq -r '.task_id')
    session_id=$(echo "$envelope" | jq -r '.session_id')
    
    if ! validate_uuid "$agent_id" "agent_id"; then return $VALIDATION_FAILURE; fi
    if ! validate_uuid "$task_id" "task_id"; then return $VALIDATION_FAILURE; fi
    if ! validate_uuid "$session_id" "session_id"; then return $VALIDATION_FAILURE; fi
    
    # Timestamp validation
    local timestamp
    timestamp=$(echo "$envelope" | jq -r '.timestamp')
    if ! validate_iso8601_timestamp "$timestamp" "timestamp"; then
        return $VALIDATION_FAILURE
    fi
    
    # Payload validation (must be an object)
    local payload
    payload=$(echo "$envelope" | jq -r '.payload | type')
    if [[ "$payload" != "object" ]]; then
        log_error "validation" "failed" "Payload must be an object, got: $payload"
        return $VALIDATION_FAILURE
    fi
    
    log_info "validation" "success" "InteractionEnvelope validation passed for event_type: $event_type"
    return $VALIDATION_SUCCESS
}

# Validates event-specific payload structure
validate_event_payload() {
    local envelope="$1"
    local event_type
    event_type=$(echo "$envelope" | jq -r '.event_type')
    
    case "$event_type" in
        "task_declaration")
            validate_task_declaration_payload "$envelope"
            ;;
        "activity_report")
            validate_activity_report_payload "$envelope"
            ;;
        "completion_report")
            validate_completion_report_payload "$envelope"
            ;;
        "self_improvement_cycle")
            validate_self_improvement_payload "$envelope"
            ;;
        *)
            log_error "validation" "failed" "Unknown event type for payload validation: $event_type"
            return $VALIDATION_FAILURE
            ;;
    esac
}

validate_task_declaration_payload() {
    local envelope="$1"
    local payload
    payload=$(echo "$envelope" | jq '.payload')
    
    # Required fields for task declaration
    local required_fields="objective"
    if ! validate_required_fields "$payload" "$required_fields" "task_declaration_payload"; then
        return $VALIDATION_FAILURE
    fi
    
    # Validate objective is non-empty string
    local objective
    objective=$(echo "$payload" | jq -r '.objective // ""')
    if ! validate_string_length "$objective" 1 1000 "objective"; then
        return $VALIDATION_FAILURE
    fi
    
    # Optional target_files validation (if present, must be array)
    if echo "$payload" | jq -e '.target_files' >/dev/null 2>&1; then
        local target_files_type
        target_files_type=$(echo "$payload" | jq -r '.target_files | type')
        if [[ "$target_files_type" != "array" ]]; then
            log_error "validation" "failed" "target_files must be an array, got: $target_files_type"
            return $VALIDATION_FAILURE
        fi
    fi
    
    return $VALIDATION_SUCCESS
}

validate_activity_report_payload() {
    local envelope="$1"
    local payload
    payload=$(echo "$envelope" | jq '.payload')
    
    # Required fields for activity report
    local required_fields="activity_type details"
    if ! validate_required_fields "$payload" "$required_fields" "activity_report_payload"; then
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

validate_completion_report_payload() {
    local envelope="$1"
    local payload
    payload=$(echo "$envelope" | jq '.payload')
    
    # Required fields for completion report
    local required_fields="status result"
    if ! validate_required_fields "$payload" "$required_fields" "completion_report_payload"; then
        return $VALIDATION_FAILURE
    fi
    
    # Validate status is valid completion status
    local status
    status=$(echo "$payload" | jq -r '.status')
    if ! validate_enum_value "$status" "success failure partial_success" "completion_status"; then
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

validate_self_improvement_payload() {
    local envelope="$1"
    local payload
    payload=$(echo "$envelope" | jq '.payload')
    
    # Required fields for self improvement
    local required_fields="improvement_type analysis recommendations"
    if ! validate_required_fields "$payload" "$required_fields" "self_improvement_payload"; then
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

# =============================================================================
# TYPE VALIDATION FUNCTIONS
# =============================================================================

# Validates that a value is a valid UUID (v4)
validate_uuid() {
    local value="$1"
    local field_name="${2:-uuid}"
    
    if [[ -z "$value" ]]; then
        log_error "validation" "failed" "UUID field '$field_name' is empty"
        return $VALIDATION_FAILURE
    fi
    
    # UUID v4 pattern: 8-4-4-4-12 hexadecimal digits
    if [[ ! "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; then
        log_error "validation" "failed" "Invalid UUID format for field '$field_name': $value"
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

# Validates ISO8601 timestamp format
validate_iso8601_timestamp() {
    local timestamp="$1"
    local field_name="${2:-timestamp}"
    
    if [[ -z "$timestamp" ]]; then
        log_error "validation" "failed" "Timestamp field '$field_name' is empty"
        return $VALIDATION_FAILURE
    fi
    
    # ISO8601 pattern: YYYY-MM-DDTHH:MM:SSZ or with microseconds
    if [[ ! "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z?$ ]]; then
        log_error "validation" "failed" "Invalid ISO8601 timestamp format for field '$field_name': $timestamp"
        return $VALIDATION_FAILURE
    fi
    
    # Validate date using date command (if available)
    if command -v date >/dev/null 2>&1; then
        if ! date -d "$timestamp" >/dev/null 2>&1; then
            log_error "validation" "failed" "Invalid date value for field '$field_name': $timestamp"
            return $VALIDATION_FAILURE
        fi
    fi
    
    return $VALIDATION_SUCCESS
}

# Validates string length within bounds
validate_string_length() {
    local value="$1"
    local min_length="$2"
    local max_length="$3"
    local field_name="${4:-string}"
    
    local length=${#value}
    
    if [[ $length -lt $min_length ]]; then
        log_error "validation" "failed" "Field '$field_name' too short: $length < $min_length"
        return $VALIDATION_FAILURE
    fi
    
    if [[ $length -gt $max_length ]]; then
        log_error "validation" "failed" "Field '$field_name' too long: $length > $max_length"
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

# Validates numeric value within range
validate_numeric_range() {
    local value="$1"
    local min_value="$2"
    local max_value="$3"
    local field_name="${4:-number}"
    
    if ! [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        log_error "validation" "failed" "Field '$field_name' is not a valid number: $value"
        return $VALIDATION_FAILURE
    fi
    
    if (( $(echo "$value < $min_value" | bc -l) )); then
        log_error "validation" "failed" "Field '$field_name' below minimum: $value < $min_value"
        return $VALIDATION_FAILURE
    fi
    
    if (( $(echo "$value > $max_value" | bc -l) )); then
        log_error "validation" "failed" "Field '$field_name' above maximum: $value > $max_value"
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

# Validates array size within bounds
validate_array_size() {
    local json_array="$1"
    local min_size="$2"
    local max_size="$3"
    local field_name="${4:-array}"
    
    if [[ $(echo "$json_array" | jq -r 'type') != "array" ]]; then
        log_error "validation" "failed" "Field '$field_name' is not an array"
        return $VALIDATION_FAILURE
    fi
    
    local size
    size=$(echo "$json_array" | jq -r 'length')
    
    if [[ $size -lt $min_size ]]; then
        log_error "validation" "failed" "Array '$field_name' too small: $size < $min_size"
        return $VALIDATION_FAILURE
    fi
    
    if [[ $size -gt $max_size ]]; then
        log_error "validation" "failed" "Array '$field_name' too large: $size > $max_size"
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

# Validates enum value against allowed values
validate_enum_value() {
    local value="$1"
    local allowed_values="$2"
    local field_name="${3:-enum}"
    
    for allowed in $allowed_values; do
        if [[ "$value" == "$allowed" ]]; then
            return $VALIDATION_SUCCESS
        fi
    done
    
    log_error "validation" "failed" "Invalid value for field '$field_name': '$value' not in [$allowed_values]"
    return $VALIDATION_FAILURE
}

# =============================================================================
# SECURITY VALIDATION FUNCTIONS
# =============================================================================

# Sanitizes input to prevent SQL injection
sanitize_sql_input() {
    local input="$1"
    
    # Remove or escape dangerous characters
    # Replace single quotes with doubled quotes for SQL escaping
    echo "$input" | sed "s/'/''/g"
}

# Validates and sanitizes file paths to prevent path traversal
validate_file_path() {
    local path="$1"
    local allowed_base="${2:-$CLAUDE_PROJECT_DIR}"
    local field_name="${3:-file_path}"
    
    if [[ -z "$path" ]]; then
        log_error "validation" "failed" "File path field '$field_name' is empty"
        return $VALIDATION_FAILURE
    fi
    
    # Resolve the path to prevent traversal attacks
    local resolved_path
    if ! resolved_path=$(realpath -m "$path" 2>/dev/null); then
        log_error "validation" "failed" "Cannot resolve path for field '$field_name': $path"
        return $VALIDATION_FAILURE
    fi
    
    # Check if resolved path starts with allowed base
    if [[ "$resolved_path" != "$allowed_base"* ]]; then
        log_error "validation" "failed" "Path '$field_name' outside allowed base: $resolved_path"
        return $VALIDATION_FAILURE
    fi
    
    # Check for dangerous patterns
    if [[ "$path" =~ \.\./|/\.\./|\.\.$|^\.\./ ]]; then
        log_error "validation" "failed" "Path '$field_name' contains directory traversal: $path"
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

# Validates command input to prevent command injection
validate_command_input() {
    local command="$1"
    local field_name="${2:-command}"
    
    if [[ -z "$command" ]]; then
        log_error "validation" "failed" "Command field '$field_name' is empty"
        return $VALIDATION_FAILURE
    fi
    
    # Check for dangerous command injection patterns
    local dangerous_patterns=("|" ";" "&" "\$(" "`" ">" "<" "||" "&&")
    
    for pattern in "${dangerous_patterns[@]}"; do
        if [[ "$command" == *"$pattern"* ]]; then
            log_error "validation" "failed" "Command '$field_name' contains dangerous pattern: $pattern"
            return $VALIDATION_FAILURE
        fi
    done
    
    return $VALIDATION_SUCCESS
}

# Validates URL format and safety
validate_url() {
    local url="$1"
    local field_name="${2:-url}"
    local allowed_schemes="${3:-http https}"
    
    if [[ -z "$url" ]]; then
        log_error "validation" "failed" "URL field '$field_name' is empty"
        return $VALIDATION_FAILURE
    fi
    
    # Basic URL format validation
    if [[ ! "$url" =~ ^https?://[a-zA-Z0-9.-]+(/.*)?$ ]]; then
        log_error "validation" "failed" "Invalid URL format for field '$field_name': $url"
        return $VALIDATION_FAILURE
    fi
    
    # Validate scheme
    local scheme
    scheme=$(echo "$url" | sed 's/:.*$//')
    
    local scheme_allowed=false
    for allowed_scheme in $allowed_schemes; do
        if [[ "$scheme" == "$allowed_scheme" ]]; then
            scheme_allowed=true
            break
        fi
    done
    
    if [[ "$scheme_allowed" != true ]]; then
        log_error "validation" "failed" "URL scheme '$scheme' not allowed for field '$field_name'"
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

# Validates email format
validate_email() {
    local email="$1"
    local field_name="${2:-email}"
    
    if [[ -z "$email" ]]; then
        log_error "validation" "failed" "Email field '$field_name' is empty"
        return $VALIDATION_FAILURE
    fi
    
    # Basic email format validation (RFC 5322 compliant pattern)
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "validation" "failed" "Invalid email format for field '$field_name': $email"
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

# =============================================================================
# RESOURCE VALIDATION FUNCTIONS
# =============================================================================

# Validates database connection string format
validate_database_dsn() {
    local dsn="$1"
    local field_name="${2:-database_dsn}"
    
    if [[ -z "$dsn" ]]; then
        log_error "validation" "failed" "Database DSN field '$field_name' is empty"
        return $VALIDATION_FAILURE
    fi
    
    # PostgreSQL DSN pattern
    if [[ ! "$dsn" =~ ^postgresql://[^:]+:[^@]*@[^:/]+:[0-9]+/[^/]+$ ]]; then
        log_error "validation" "failed" "Invalid PostgreSQL DSN format for field '$field_name'"
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

# Validates file exists and is readable
validate_file_exists() {
    local file_path="$1"
    local field_name="${2:-file}"
    
    if ! validate_file_path "$file_path" "$CLAUDE_PROJECT_DIR" "$field_name"; then
        return $VALIDATION_FAILURE
    fi
    
    if [[ ! -f "$file_path" ]]; then
        log_error "validation" "failed" "File does not exist for field '$field_name': $file_path"
        return $VALIDATION_FAILURE
    fi
    
    if [[ ! -r "$file_path" ]]; then
        log_error "validation" "failed" "File is not readable for field '$field_name': $file_path"
        return $VALIDATION_FAILURE
    fi
    
    return $VALIDATION_SUCCESS
}

# =============================================================================
# JSON SCHEMA VALIDATION
# =============================================================================

# Validates JSON against a schema (requires jq with schema support)
validate_json_schema() {
    local json_data="$1"
    local schema="$2"
    local field_name="${3:-json_data}"
    
    if ! validate_json_structure "$json_data" "$field_name"; then
        return $VALIDATION_FAILURE
    fi
    
    if ! validate_json_structure "$schema" "schema"; then
        log_error "validation" "failed" "Invalid JSON schema provided"
        return $VALIDATION_FAILURE
    fi
    
    # Note: Basic schema validation - in production, use a proper JSON schema validator
    log_info "validation" "info" "JSON schema validation requested for field '$field_name' (basic validation applied)"
    
    return $VALIDATION_SUCCESS
}

# =============================================================================
# CUSTOM PROTOCOL VALIDATION
# =============================================================================

# Validates agent protocol-specific rules
validate_agent_protocol() {
    local envelope="$1"
    
    # Validate basic envelope first
    if ! validate_interaction_envelope "$envelope"; then
        return $VALIDATION_FAILURE
    fi
    
    # Validate event-specific payload
    if ! validate_event_payload "$envelope"; then
        return $VALIDATION_FAILURE
    fi
    
    # Additional protocol-specific validations
    local agent_id task_id session_id
    agent_id=$(echo "$envelope" | jq -r '.agent_id')
    task_id=$(echo "$envelope" | jq -r '.task_id')
    session_id=$(echo "$envelope" | jq -r '.session_id')
    
    # Validate agent ID format (should be UUID)
    if ! validate_uuid "$agent_id" "agent_id"; then
        return $VALIDATION_FAILURE
    fi
    
    # Validate task/session relationship if available in state
    if command -v redis-cli >/dev/null 2>&1 && [[ -n "$WORKFLOW_EXECUTION_ID" ]]; then
        # Check if this is consistent with current workflow state
        local current_task_id current_session_id
        current_task_id=$(redis-cli HGET "wfe:$WORKFLOW_EXECUTION_ID" "task_id" 2>/dev/null || true)
        current_session_id=$(redis-cli HGET "wfe:$WORKFLOW_EXECUTION_ID" "session_id" 2>/dev/null || true)
        
        if [[ -n "$current_task_id" ]] && [[ "$current_task_id" != "$task_id" ]]; then
            log_warning "validation" "inconsistent" "Task ID mismatch: current=$current_task_id, envelope=$task_id"
        fi
        
        if [[ -n "$current_session_id" ]] && [[ "$current_session_id" != "$session_id" ]]; then
            log_warning "validation" "inconsistent" "Session ID mismatch: current=$current_session_id, envelope=$session_id"
        fi
    fi
    
    log_info "validation" "success" "Agent protocol validation completed successfully"
    return $VALIDATION_SUCCESS
}

# =============================================================================
# CONVENIENCE FUNCTIONS
# =============================================================================

# Quick validation for common use cases in atomic hooks
validate_hook_input() {
    local hook_name="$1"
    local expected_event_type="$2"
    
    if [[ -z "$WORKFLOW_EXECUTION_ID" ]]; then
        log_critical "validation" "failed" "WORKFLOW_EXECUTION_ID not set for hook: $hook_name"
        return $VALIDATION_CRITICAL
    fi
    
    # Get envelope from state
    local envelope
    if ! envelope=$(redis-cli HGET "wfe:$WORKFLOW_EXECUTION_ID" "initial_envelope" 2>/dev/null); then
        log_critical "validation" "failed" "Cannot retrieve envelope from state for hook: $hook_name"
        return $VALIDATION_CRITICAL
    fi
    
    if [[ -z "$envelope" ]] || [[ "$envelope" == "(nil)" ]]; then
        log_critical "validation" "failed" "Empty envelope in state for hook: $hook_name"
        return $VALIDATION_CRITICAL
    fi
    
    # Validate the envelope
    if ! validate_agent_protocol "$envelope"; then
        log_error "validation" "failed" "Invalid envelope for hook: $hook_name"
        return $VALIDATION_FAILURE
    fi
    
    # Check event type if specified
    if [[ -n "$expected_event_type" ]]; then
        local actual_event_type
        actual_event_type=$(echo "$envelope" | jq -r '.event_type')
        
        if [[ "$actual_event_type" != "$expected_event_type" ]]; then
            log_error "validation" "failed" "Hook '$hook_name' expects event_type '$expected_event_type', got '$actual_event_type'"
            return $VALIDATION_FAILURE
        fi
    fi
    
    log_info "validation" "success" "Hook input validation passed for: $hook_name"
    return $VALIDATION_SUCCESS
}

# Validates environment variables required by the system
validate_environment() {
    local required_vars="CLAUDE_PROJECT_DIR POSTGRES_DSN REDIS_URL HOOKS_DIR LOGS_DIR"
    local missing_vars=""
    
    for var in $required_vars; do
        if [[ -z "${!var}" ]]; then
            missing_vars="$missing_vars $var"
        fi
    done
    
    if [[ -n "$missing_vars" ]]; then
        log_critical "validation" "failed" "Missing required environment variables:$missing_vars"
        return $VALIDATION_CRITICAL
    fi
    
    # Validate directory paths exist
    for dir_var in "CLAUDE_PROJECT_DIR" "HOOKS_DIR" "LOGS_DIR"; do
        local dir_path="${!dir_var}"
        if [[ ! -d "$dir_path" ]]; then
            log_critical "validation" "failed" "Required directory does not exist: $dir_var=$dir_path"
            return $VALIDATION_CRITICAL
        fi
    done
    
    log_info "validation" "success" "Environment validation completed successfully"
    return $VALIDATION_SUCCESS
}

# Export key functions for use by hooks
export -f validate_interaction_envelope
export -f validate_agent_protocol
export -f validate_hook_input
export -f validate_environment
export -f validate_json_structure
export -f validate_required_fields
export -f validate_uuid
export -f validate_iso8601_timestamp
export -f validate_file_path
export -f validate_url
export -f validate_email
export -f sanitize_sql_input