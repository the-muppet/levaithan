#!/bin/bash
# atomic/coord-create-subtask.sh - Create subtasks for delegation
set -e

# Source required libraries
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/logging.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/data-access.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/state.sh"

# Set hook name for logging
export HOOK_NAME="coord-create-subtask"

# Read InteractionEnvelope from stdin
ENVELOPE=$(cat)
log_info "envelope_received" "processing" "InteractionEnvelope received for subtask creation"

# Extract required fields from envelope
TASK_ID=$(echo "$ENVELOPE" | jq -r '.task_id')
AGENT_ID=$(echo "$ENVELOPE" | jq -r '.agent_id')
SESSION_ID=$(echo "$ENVELOPE" | jq -r '.session_id')

# Validate required fields
if [[ -z "$TASK_ID" || "$TASK_ID" == "null" ]]; then
    log_error "validation_failed" "failed" "Missing or invalid task_id"
    exit 1
fi

if [[ -z "$AGENT_ID" || "$AGENT_ID" == "null" ]]; then
    log_error "validation_failed" "failed" "Missing or invalid agent_id"
    exit 1
fi

if [[ -z "$SESSION_ID" || "$SESSION_ID" == "null" ]]; then
    log_error "validation_failed" "failed" "Missing or invalid session_id"
    exit 1
fi

# Extract subtask details from payload
SUBTASK_OBJECTIVE=$(echo "$ENVELOPE" | jq -r '.payload.subtask_objective // empty')
DELEGATE_TO=$(echo "$ENVELOPE" | jq -r '.payload.delegate_to // empty')
SUBTASK_PRIORITY=$(echo "$ENVELOPE" | jq -r '.payload.priority // "normal"')

# Validate subtask creation request
if [[ -z "$SUBTASK_OBJECTIVE" ]]; then
    log_error "validation_failed" "failed" "Missing subtask_objective in payload"
    exit 1
fi

# Generate unique subtask ID
SUBTASK_ID="subtask_$(uuidgen 2>/dev/null || echo "$(date +%s)_$$")"

log_info "subtask_creation" "starting" "Creating subtask '$SUBTASK_ID' for objective: $SUBTASK_OBJECTIVE"

# Verify parent task exists and is active
PARENT_STATUS=$(psql "$POSTGRES_DSN" -t -A -c "SELECT status FROM tasks WHERE task_id='$TASK_ID';" 2>/dev/null || echo "")

if [[ -z "$PARENT_STATUS" ]]; then
    log_error "parent_not_found" "failed" "Parent task '$TASK_ID' not found"
    exit 1
fi

if [[ "$PARENT_STATUS" != "active" && "$PARENT_STATUS" != "delegated" ]]; then
    log_error "parent_invalid_status" "failed" "Parent task '$TASK_ID' has status '$PARENT_STATUS', cannot create subtasks"
    exit 1
fi

# Determine delegation target
if [[ -z "$DELEGATE_TO" ]]; then
    DELEGATE_TO="$AGENT_ID"  # Self-delegation if no specific agent specified
    log_info "self_delegation" "assigned" "No delegate specified, assigning subtask to self"
else
    log_info "delegation_target" "assigned" "Delegating subtask to agent '$DELEGATE_TO'"
fi

# Create the subtask record
if create_task_record "$SUBTASK_ID" "$TASK_ID" "$SUBTASK_OBJECTIVE" "$AGENT_ID"; then
    log_info "subtask_created" "success" "Subtask record created successfully"
else
    log_error "creation_failed" "failed" "Failed to create subtask record in database"
    exit 1
fi

# Update parent task status to 'delegated' if it's not already
if [[ "$PARENT_STATUS" == "active" ]]; then
    psql "$POSTGRES_DSN" -c "UPDATE tasks SET status='delegated', updated_at=CURRENT_TIMESTAMP WHERE task_id='$TASK_ID';" >/dev/null 2>&1
    log_info "parent_status_updated" "updated" "Parent task status changed to 'delegated'"
fi

# Assign the subtask to the delegate
psql "$POSTGRES_DSN" -c "UPDATE tasks SET assigned_to='$DELEGATE_TO', updated_at=CURRENT_TIMESTAMP WHERE task_id='$SUBTASK_ID';" >/dev/null 2>&1

# Store subtask creation in state for workflow tracking
state_set "subtask_created" "$SUBTASK_ID"
state_set "subtask_objective" "$SUBTASK_OBJECTIVE"
state_set "subtask_delegate" "$DELEGATE_TO"
state_set "subtask_priority" "$SUBTASK_PRIORITY"

# Log to activity stream for monitoring
if command -v curl >/dev/null 2>&1 && [[ -n "$ELASTIC_URL" ]]; then
    SUBTASK_DETAILS=$(jq -n \
        --arg subtask_id "$SUBTASK_ID" \
        --arg parent_id "$TASK_ID" \
        --arg objective "$SUBTASK_OBJECTIVE" \
        --arg delegate "$DELEGATE_TO" \
        --arg priority "$SUBTASK_PRIORITY" \
        '{subtask_id: $subtask_id, parent_task_id: $parent_id, objective: $objective, delegate: $delegate, priority: $priority}')
    
    log_to_activity_stream "$TASK_ID" "subtask_created" "$SUBTASK_DETAILS"
    log_info "activity_logged" "logged" "Subtask creation logged to activity stream"
fi

# Chronicle the delegation event for system learning
psql "$POSTGRES_DSN" -c "
    INSERT INTO chronicle_events (event_type, event_title, event_description, metadata, significance_level) 
    VALUES ('task_delegation', 'Subtask Created', 
            'Agent $AGENT_ID created subtask and delegated to $DELEGATE_TO', 
            '{\"parent_task\":\"$TASK_ID\",\"subtask\":\"$SUBTASK_ID\",\"session_id\":\"$SESSION_ID\",\"delegate\":\"$DELEGATE_TO\",\"priority\":\"$SUBTASK_PRIORITY\"}', 
            5);" >/dev/null 2>&1

# If delegating to a different agent, create a basic session for them
if [[ "$DELEGATE_TO" != "$AGENT_ID" ]]; then
    DELEGATE_SESSION_ID="session_$(uuidgen 2>/dev/null || echo "$(date +%s)_${DELEGATE_TO}")"
    
    psql "$POSTGRES_DSN" -c "
        INSERT INTO agent_sessions (session_id, task_id, agent_id, status) 
        VALUES ('$DELEGATE_SESSION_ID', '$SUBTASK_ID', '$DELEGATE_TO', 'pending');" >/dev/null 2>&1
    
    state_set "delegate_session_created" "$DELEGATE_SESSION_ID"
    log_info "delegate_session_created" "created" "Created session '$DELEGATE_SESSION_ID' for delegate '$DELEGATE_TO'"
fi

# Output subtask information for the calling workflow
cat <<EOF
{
  "subtask_id": "$SUBTASK_ID",
  "parent_task_id": "$TASK_ID",
  "objective": "$SUBTASK_OBJECTIVE",
  "assigned_to": "$DELEGATE_TO",
  "priority": "$SUBTASK_PRIORITY",
  "status": "active",
  "created_by": "$AGENT_ID"
}
EOF

log_info "subtask_creation_complete" "success" "Subtask '$SUBTASK_ID' created and assigned to '$DELEGATE_TO'"
exit 0