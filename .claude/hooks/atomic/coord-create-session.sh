#!/bin/bash
# atomic/coord-create-session.sh - Create agent session (if missing)
set -e

# Source required libraries
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/logging.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/data-access.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/state.sh"

# Set hook name for logging
export HOOK_NAME="coord-create-session"

# Read InteractionEnvelope from stdin
ENVELOPE=$(cat)
log_info "envelope_received" "processing" "InteractionEnvelope received for session creation"

# Extract required fields from envelope
TASK_ID=$(echo "$ENVELOPE" | jq -r '.task_id')
SESSION_ID=$(echo "$ENVELOPE" | jq -r '.session_id')
AGENT_ID=$(echo "$ENVELOPE" | jq -r '.agent_id')

# Validate required fields
if [[ -z "$TASK_ID" || "$TASK_ID" == "null" ]]; then
    log_error "validation_failed" "failed" "Missing or invalid task_id"
    exit 1
fi

if [[ -z "$SESSION_ID" || "$SESSION_ID" == "null" ]]; then
    log_error "validation_failed" "failed" "Missing or invalid session_id"
    exit 1
fi

if [[ -z "$AGENT_ID" || "$AGENT_ID" == "null" ]]; then
    log_error "validation_failed" "failed" "Missing or invalid agent_id"
    exit 1
fi

log_info "session_creation" "starting" "Processing session creation for '$SESSION_ID'"

# Check if session already exists
EXISTING_SESSION=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT session_id, agent_id, task_id, status 
    FROM agent_sessions 
    WHERE session_id='$SESSION_ID';" 2>/dev/null || echo "")

if [[ -n "$EXISTING_SESSION" ]]; then
    # Session exists - validate consistency
    EXISTING_AGENT=$(echo "$EXISTING_SESSION" | cut -d'|' -f2)
    EXISTING_TASK=$(echo "$EXISTING_SESSION" | cut -d'|' -f3)
    EXISTING_STATUS=$(echo "$EXISTING_SESSION" | cut -d'|' -f4)
    
    if [[ "$EXISTING_AGENT" != "$AGENT_ID" ]]; then
        log_error "session_agent_mismatch" "failed" "Session '$SESSION_ID' belongs to agent '$EXISTING_AGENT', not '$AGENT_ID'"
        exit 1
    fi
    
    if [[ "$EXISTING_TASK" != "$TASK_ID" ]]; then
        log_error "session_task_mismatch" "failed" "Session '$SESSION_ID' is for task '$EXISTING_TASK', not '$TASK_ID'"
        exit 1
    fi
    
    log_info "session_exists" "validated" "Session already exists with status '$EXISTING_STATUS'"
    state_set "session_status" "$EXISTING_STATUS"
    state_set "session_created" "false"
    exit 0
fi

# Verify the task exists before creating session
TASK_STATUS=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT status, assigned_to, created_by 
    FROM tasks 
    WHERE task_id='$TASK_ID';" 2>/dev/null || echo "")

if [[ -z "$TASK_STATUS" ]]; then
    log_error "task_not_found" "failed" "Task '$TASK_ID' not found - cannot create session"
    exit 1
fi

TASK_STATE=$(echo "$TASK_STATUS" | cut -d'|' -f1)
ASSIGNED_TO=$(echo "$TASK_STATUS" | cut -d'|' -f2)
CREATED_BY=$(echo "$TASK_STATUS" | cut -d'|' -f3)

# Validate task status allows session creation
if [[ "$TASK_STATE" == "completed" || "$TASK_STATE" == "failed" || "$TASK_STATE" == "cancelled" ]]; then
    log_error "task_invalid_status" "failed" "Task '$TASK_ID' has status '$TASK_STATE' - cannot create new sessions"
    exit 1
fi

# Validate agent authorization for this task
if [[ -n "$ASSIGNED_TO" && "$ASSIGNED_TO" != "$AGENT_ID" ]]; then
    if [[ "$CREATED_BY" != "$AGENT_ID" ]]; then
        log_error "agent_unauthorized" "failed" "Agent '$AGENT_ID' not authorized for task '$TASK_ID' (assigned to '$ASSIGNED_TO', created by '$CREATED_BY')"
        exit 1
    fi
fi

# Check for existing active sessions by this agent on this task
ACTIVE_SESSION=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT session_id, status 
    FROM agent_sessions 
    WHERE agent_id='$AGENT_ID' 
    AND task_id='$TASK_ID' 
    AND status IN ('active', 'approved_for_execution', 'pending')
    ORDER BY started_at DESC 
    LIMIT 1;" 2>/dev/null || echo "")

if [[ -n "$ACTIVE_SESSION" ]]; then
    EXISTING_SESSION_ID=$(echo "$ACTIVE_SESSION" | cut -d'|' -f1)
    EXISTING_SESSION_STATUS=$(echo "$ACTIVE_SESSION" | cut -d'|' -f2)
    
    log_warning "existing_active_session" "conflict" "Agent '$AGENT_ID' already has active session '$EXISTING_SESSION_ID' for task '$TASK_ID'"
    
    # Allow creation but log the potential conflict
    psql "$POSTGRES_DSN" -c "
        INSERT INTO chronicle_events (event_type, event_title, event_description, metadata, significance_level) 
        VALUES ('multiple_sessions_detected', 'Multiple Active Sessions', 
                'Agent $AGENT_ID has multiple sessions for same task', 
                '{\"existing_session\":\"$EXISTING_SESSION_ID\",\"new_session\":\"$SESSION_ID\",\"task_id\":\"$TASK_ID\"}', 
                6);" >/dev/null 2>&1
fi

# Create the session record
CREATE_RESULT=$(psql "$POSTGRES_DSN" -c "
    INSERT INTO agent_sessions (session_id, task_id, agent_id, status) 
    VALUES ('$SESSION_ID', '$TASK_ID', '$AGENT_ID', 'pending');" 2>&1)

if [[ $? -eq 0 ]]; then
    log_info "session_created" "success" "Session '$SESSION_ID' created successfully"
else
    log_error "creation_failed" "failed" "Failed to create session: $CREATE_RESULT"
    exit 1
fi

# Store session creation in state
state_set "session_created" "true"
state_set "session_status" "pending"
state_set "session_agent" "$AGENT_ID"
state_set "session_task" "$TASK_ID"

# Initialize session monitoring in Redis
redis-cli HSET "session:$SESSION_ID:info" \
    "agent_id" "$AGENT_ID" \
    "task_id" "$TASK_ID" \
    "created_at" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "status" "pending" >/dev/null 2>&1 || true
redis-cli EXPIRE "session:$SESSION_ID:info" 86400 >/dev/null 2>&1 || true

# Log to activity stream
if command -v curl >/dev/null 2>&1 && [[ -n "$ELASTIC_URL" ]]; then
    SESSION_DETAILS=$(jq -n \
        --arg session_id "$SESSION_ID" \
        --arg agent_id "$AGENT_ID" \
        --arg task_id "$TASK_ID" \
        --arg status "pending" \
        '{session_id: $session_id, agent_id: $agent_id, task_id: $task_id, status: $status}')
    
    log_to_activity_stream "$TASK_ID" "session_created" "$SESSION_DETAILS"
    log_info "activity_logged" "logged" "Session creation logged to activity stream"
fi

# Chronicle the session creation
psql "$POSTGRES_DSN" -c "
    INSERT INTO chronicle_events (event_type, event_title, event_description, metadata, significance_level) 
    VALUES ('session_created', 'Agent Session Created', 
            'New session created for agent $AGENT_ID on task $TASK_ID', 
            '{\"session_id\":\"$SESSION_ID\",\"agent_id\":\"$AGENT_ID\",\"task_id\":\"$TASK_ID\"}', 
            4);" >/dev/null 2>&1

# Check and initialize agent budget tracking if not exists
BUDGET_EXISTS=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT allocation_id 
    FROM budget_allocations 
    WHERE agent_id='$AGENT_ID' 
    AND budget_type='daily' 
    AND period_start = CURRENT_DATE;" 2>/dev/null || echo "")

if [[ -z "$BUDGET_EXISTS" ]]; then
    DEFAULT_BUDGET="${DEFAULT_DAILY_BUDGET_USD:-10.00}"
    psql "$POSTGRES_DSN" -c "
        INSERT INTO budget_allocations (agent_id, budget_type, amount_usd, period_start, period_end) 
        VALUES ('$AGENT_ID', 'daily', $DEFAULT_BUDGET, CURRENT_DATE, CURRENT_DATE + INTERVAL '1 day')
        ON CONFLICT (agent_id, budget_type, period_start) DO NOTHING;" >/dev/null 2>&1
    
    log_info "budget_initialized" "created" "Daily budget of \$$DEFAULT_BUDGET initialized for agent '$AGENT_ID'"
fi

# Output session information for the calling workflow
cat <<EOF
{
  "session_id": "$SESSION_ID",
  "task_id": "$TASK_ID",
  "agent_id": "$AGENT_ID",
  "status": "pending",
  "created": true,
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

log_info "session_creation_complete" "success" "Session '$SESSION_ID' ready for agent '$AGENT_ID'"
exit 0