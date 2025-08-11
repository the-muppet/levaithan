#!/bin/bash
# GOVERNANCE: Validate security permissions for the requested action
# Checks agent permissions, resource access controls, and security policies
# to ensure the requested action is authorized and safe to execute.

set -euo pipefail

# Source required environment and libraries
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/data-access.sh"
source "$HOOKS_DIR/lib/validation.sh"
source "$HOOKS_DIR/lib/error-handling.sh"

export HOOK_NAME="atomic/governance-check-permissions"

# Enable error trapping for proper cleanup
enable_error_trap

log_info "permissions_check" "running" "Executing Security Permissions Check"

# Read and validate InteractionEnvelope from stdin
INTERACTION_ENVELOPE=""
if ! read -r INTERACTION_ENVELOPE; then
    log_error "permissions_check" "failed" "No input received from stdin"
    exit 1
fi

# Validate the interaction envelope structure
if ! validate_interaction_envelope "$INTERACTION_ENVELOPE"; then
    log_error "permissions_check" "failed" "Invalid InteractionEnvelope format"
    exit 1
fi

# Extract key information from envelope
agent_id=$(echo "$INTERACTION_ENVELOPE" | jq -r '.agent_id')
event_type=$(echo "$INTERACTION_ENVELOPE" | jq -r '.event_type')
payload=$(echo "$INTERACTION_ENVELOPE" | jq '.payload')

log_info "permissions_check" "agent_context" "Checking permissions for agent: $agent_id, event: $event_type"

# Extract security-relevant information from payload
objective=$(echo "$payload" | jq -r '.objective // ""')
target_files=$(echo "$payload" | jq -r '.target_files[]? // empty' 2>/dev/null | tr '\n' ' ')
requested_operations=$(echo "$payload" | jq -r '.operations[]? // empty' 2>/dev/null | tr '\n' ' ')

# Infer operations from objective text if not explicitly specified
if [[ -z "$requested_operations" ]]; then
    requested_operations=$(echo "$objective" | grep -oiE '\b(create|delete|modify|refactor|write|edit|remove|update|execute|admin|sudo|chmod|chown|install|deploy|configure)\b' | tr '[:upper:]' '[:lower:]' | sort -u | tr '\n' ' ')
fi

log_info "permissions_check" "context_extracted" "Target files: ${target_files:-none}, Operations: ${requested_operations:-inferred from objective}"

# 1. CHECK AGENT PERMISSIONS
log_info "permissions_check" "agent_perms" "Validating agent permissions"

# Query agent-specific permissions
agent_perms_query="SELECT allowed_operations, forbidden_operations, max_files_per_operation, resource_access_level
                   FROM agent_permissions 
                   WHERE agent_id = '$agent_id' 
                   AND is_active = true 
                   ORDER BY created_at DESC LIMIT 1;"

agent_permissions=$(psql "$POSTGRES_DSN" -t -A -c "$agent_perms_query" 2>/dev/null || echo "")

# Set defaults if no specific permissions found
if [[ -z "$agent_permissions" ]]; then
    allowed_operations="read,create,modify"
    forbidden_operations="delete,execute,admin,sudo"
    max_files_per_operation="10"
    resource_access_level="restricted"
    
    log_warning "permissions_check" "default_perms" "No specific permissions found for agent $agent_id, using defaults"
else
    IFS='|' read -r allowed_operations forbidden_operations max_files_per_operation resource_access_level <<< "$agent_permissions"
fi

log_info "permissions_check" "agent_perms_loaded" "Agent permissions: allowed=[$allowed_operations], forbidden=[$forbidden_operations]"

# 2. VALIDATE REQUESTED OPERATIONS
log_info "permissions_check" "operation_validation" "Validating requested operations"

for operation in $requested_operations; do
    # Check if operation is explicitly forbidden
    if echo "$forbidden_operations" | grep -q "$operation"; then
        log_error "permissions_check" "forbidden_operation" "Operation '$operation' is forbidden for agent $agent_id"
        exit 1
    fi
    
    # Check if operation is allowed (if allow list is restrictive)
    if [[ "$allowed_operations" != "*" ]] && ! echo "$allowed_operations" | grep -q "$operation"; then
        log_error "permissions_check" "unauthorized_operation" "Operation '$operation' is not authorized for agent $agent_id"
        exit 1
    fi
done

# 3. CHECK FILE ACCESS PERMISSIONS
if [[ -n "$target_files" ]]; then
    log_info "permissions_check" "file_access" "Validating file access permissions"
    
    file_count=$(echo "$target_files" | wc -w)
    
    # Check file count limit
    if [[ $file_count -gt $max_files_per_operation ]]; then
        log_error "permissions_check" "too_many_files" "File count $file_count exceeds limit $max_files_per_operation for agent $agent_id"
        exit 1
    fi
    
    # Validate each file path
    for file_path in $target_files; do
        # Basic path validation to prevent directory traversal
        if ! validate_file_path "$file_path" "$CLAUDE_PROJECT_DIR" "target_file"; then
            log_error "permissions_check" "invalid_path" "Invalid or unsafe file path: $file_path"
            exit 1
        fi
        
        # Check for sensitive file patterns
        if echo "$file_path" | grep -qE '\.(env|key|pem|secret|credentials|config|private)$'; then
            log_error "permissions_check" "sensitive_file" "Access denied to sensitive file: $file_path"
            exit 1
        fi
        
        # Check for system directories (if not admin level access)
        if [[ "$resource_access_level" != "admin" ]] && echo "$file_path" | grep -qE '^/?(etc|root|home|var/log|sys|proc)/'; then
            log_error "permissions_check" "system_directory" "Access denied to system directory: $file_path"
            exit 1
        fi
        
        # Check resource-specific permissions
        resource_check_query="SELECT COUNT(*) FROM resource_permissions 
                              WHERE (agent_id = '$agent_id' OR agent_id = 'all')
                              AND resource_pattern LIKE '%$(basename "$file_path")%'
                              AND permission_type = 'deny'
                              AND is_active = true;"
        
        denied_count=$(psql "$POSTGRES_DSN" -t -A -c "$resource_check_query" 2>/dev/null || echo "0")
        
        if [[ "$denied_count" -gt 0 ]]; then
            log_error "permissions_check" "resource_denied" "Access denied to resource by policy: $file_path"
            exit 1
        fi
    done
fi

# 4. CHECK SECURITY POLICIES AND PATTERNS
log_info "permissions_check" "security_patterns" "Checking for security policy violations"

# Check for forbidden patterns in objective
forbidden_patterns="rm -rf|sudo|eval\(|DROP TABLE|DELETE FROM|../|chmod 777|/etc/passwd|process\.env\.|__import__|exec\("

pattern_violations=""
while IFS='|' read -r pattern; do
    if [[ -n "$pattern" ]] && echo "$objective" | grep -qE "$pattern"; then
        pattern_violations="$pattern_violations $pattern"
    fi
done <<< "${forbidden_patterns//|/$'\n'}"

if [[ -n "$pattern_violations" ]]; then
    log_error "permissions_check" "forbidden_pattern" "Detected forbidden security patterns: $pattern_violations"
    
    # Record security violation
    violation_record="INSERT INTO security_violations 
                     (agent_id, violation_date, violation_type, violation_details, objective_snippet, blocked)
                     VALUES ('$agent_id', NOW(), 'forbidden_pattern', '$pattern_violations', 
                     '$(echo "$objective" | head -c 200)', true);"
    
    _psql_query "$violation_record" || log_warning "permissions_check" "violation_record_failed" "Failed to record security violation"
    
    exit 1
fi

# 5. CHECK TIME-BASED AND CONTEXT RESTRICTIONS
log_info "permissions_check" "context_restrictions" "Checking context-based restrictions"

# Check if agent is in maintenance mode or suspended
agent_status_query="SELECT status, last_violation_date FROM agent_status 
                    WHERE agent_id = '$agent_id' 
                    ORDER BY updated_at DESC LIMIT 1;"

agent_status_info=$(psql "$POSTGRES_DSN" -t -A -c "$agent_status_query" 2>/dev/null || echo "active|")
IFS='|' read -r agent_status last_violation_date <<< "$agent_status_info"

case "$agent_status" in
    "suspended")
        log_error "permissions_check" "agent_suspended" "Agent $agent_id is suspended"
        exit 1
        ;;
    "maintenance")
        log_error "permissions_check" "agent_maintenance" "Agent $agent_id is in maintenance mode"
        exit 1
        ;;
    "probation")
        log_warning "permissions_check" "agent_probation" "Agent $agent_id is on probation - elevated monitoring"
        ;;
esac

# Check rate limiting based on recent activity
recent_activity_query="SELECT COUNT(*) FROM agent_sessions 
                       WHERE agent_id = '$agent_id' 
                       AND created_at > NOW() - INTERVAL '1 hour';"

recent_activity_count=$(psql "$POSTGRES_DSN" -t -A -c "$recent_activity_query" 2>/dev/null || echo "0")
max_hourly_sessions="${MAX_HOURLY_SESSIONS:-20}"

if [[ $recent_activity_count -gt $max_hourly_sessions ]]; then
    log_error "permissions_check" "rate_limited" "Agent $agent_id exceeded hourly session limit: $recent_activity_count > $max_hourly_sessions"
    exit 1
fi

# 6. RECORD PERMISSION CHECK AND SET STATE
log_info "permissions_check" "recording_decision" "Recording permission check results"

# Store permission check details
permission_record="INSERT INTO permission_checks 
                   (agent_id, check_timestamp, event_type, requested_operations, target_files, 
                    decision, risk_level, context_data)
                   VALUES ('$agent_id', NOW(), '$event_type', '$requested_operations', '$target_files',
                   'approved', 'low', '$INTERACTION_ENVELOPE');"

_psql_query "$permission_record" || log_warning "permissions_check" "record_failed" "Failed to record permission check"

# Store permission context in workflow state for downstream hooks
if command -v state_set >/dev/null 2>&1 && [[ -n "${WORKFLOW_EXECUTION_ID:-}" ]]; then
    state_set "agent_permissions" "$allowed_operations"
    state_set "resource_access_level" "$resource_access_level"
    state_set "security_risk_level" "low"
    state_set "file_count" "${file_count:-0}"
fi

# All permission checks passed
log_info "permissions_check" "success" "All permission checks passed for agent $agent_id (risk: low)"

# Log successful authorization to security audit trail
echo "$(date -Iseconds)|permission_check_passed|$agent_id|operations:${requested_operations:-none}|files:${file_count:-0}|authorized" >> "$LOGS_DIR/security_audit.log"

exit 0