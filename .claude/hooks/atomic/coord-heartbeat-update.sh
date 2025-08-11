#!/bin/bash
# atomic/coord-heartbeat-update.sh - Update heartbeat for long-running tasks
set -e

# Source required libraries
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/logging.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/data-access.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/state.sh"

# Set hook name for logging
export HOOK_NAME="coord-heartbeat-update"

# Read InteractionEnvelope from stdin
ENVELOPE=$(cat)
log_info "envelope_received" "processing" "InteractionEnvelope received for heartbeat update"

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

# Extract heartbeat details from payload
STATUS_UPDATE=$(echo "$ENVELOPE" | jq -r '.payload.status_update // empty')
PROGRESS_PERCENTAGE=$(echo "$ENVELOPE" | jq -r '.payload.progress_percentage // null')
CURRENT_ACTIVITY=$(echo "$ENVELOPE" | jq -r '.payload.current_activity // empty')
ESTIMATED_COMPLETION=$(echo "$ENVELOPE" | jq -r '.payload.estimated_completion // null')

log_info "heartbeat_processing" "updating" "Processing heartbeat for session '$SESSION_ID'"

# Verify session exists and belongs to the agent
SESSION_CHECK=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT agent_id, status, task_id 
    FROM agent_sessions 
    WHERE session_id='$SESSION_ID';" 2>/dev/null || echo "")

if [[ -z "$SESSION_CHECK" ]]; then
    log_error "session_not_found" "failed" "Session '$SESSION_ID' not found"
    exit 1
fi

SESSION_AGENT=$(echo "$SESSION_CHECK" | cut -d'|' -f1)
SESSION_STATUS=$(echo "$SESSION_CHECK" | cut -d'|' -f2)
SESSION_TASK=$(echo "$SESSION_CHECK" | cut -d'|' -f3)

# Verify session ownership
if [[ "$SESSION_AGENT" != "$AGENT_ID" ]]; then
    log_error "session_ownership" "failed" "Session '$SESSION_ID' belongs to agent '$SESSION_AGENT', not '$AGENT_ID'"
    exit 1
fi

# Verify task consistency
if [[ "$SESSION_TASK" != "$TASK_ID" ]]; then
    log_error "task_mismatch" "failed" "Session task '$SESSION_TASK' does not match provided task '$TASK_ID'"
    exit 1
fi

# Check if session is in a state that can receive heartbeats
if [[ "$SESSION_STATUS" != "active" && "$SESSION_STATUS" != "approved_for_execution" ]]; then
    log_warning "inactive_session" "skipped" "Session '$SESSION_ID' has status '$SESSION_STATUS', heartbeat ignored"
    exit 0
fi

# Update session heartbeat timestamp
CURRENT_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
psql "$POSTGRES_DSN" -c "
    UPDATE agent_sessions 
    SET last_heartbeat = CURRENT_TIMESTAMP 
    WHERE session_id='$SESSION_ID';" >/dev/null

log_info "heartbeat_updated" "success" "Heartbeat timestamp updated for session '$SESSION_ID'"

# Store heartbeat data in workflow state
state_set "last_heartbeat" "$CURRENT_TIMESTAMP"
if [[ -n "$STATUS_UPDATE" ]]; then
    state_set "status_update" "$STATUS_UPDATE"
fi
if [[ -n "$PROGRESS_PERCENTAGE" && "$PROGRESS_PERCENTAGE" != "null" ]]; then
    state_set "progress_percentage" "$PROGRESS_PERCENTAGE"
fi
if [[ -n "$CURRENT_ACTIVITY" ]]; then
    state_set "current_activity" "$CURRENT_ACTIVITY"
fi

# Check for stale sessions and log warnings
STALE_THRESHOLD_MINUTES=10
STALE_SESSIONS=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT session_id, agent_id, 
           EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - last_heartbeat))/60 as minutes_since_heartbeat
    FROM agent_sessions 
    WHERE status IN ('active', 'approved_for_execution') 
    AND session_id != '$SESSION_ID'
    AND last_heartbeat < CURRENT_TIMESTAMP - INTERVAL '$STALE_THRESHOLD_MINUTES minutes'
    LIMIT 5;" 2>/dev/null || echo "")

if [[ -n "$STALE_SESSIONS" ]]; then
    while IFS='|' read -r stale_session stale_agent minutes_stale; do
        if [[ -n "$stale_session" ]]; then
            log_warning "stale_session_detected" "monitoring" "Session '$stale_session' (agent: $stale_agent) has no heartbeat for ${minutes_stale%.??} minutes"
        fi
    done <<< "$STALE_SESSIONS"
fi

# Log activity report if detailed status provided
if [[ -n "$STATUS_UPDATE" || -n "$CURRENT_ACTIVITY" ]]; then
    ACTIVITY_DETAILS=$(jq -n \
        --arg status "$STATUS_UPDATE" \
        --arg activity "$CURRENT_ACTIVITY" \
        --arg progress "$PROGRESS_PERCENTAGE" \
        --arg estimated "$ESTIMATED_COMPLETION" \
        '{status_update: $status, current_activity: $activity, progress_percentage: ($progress | if . == "null" then null else tonumber end), estimated_completion: $estimated}')
    
    # Log to activity stream if available
    if command -v curl >/dev/null 2>&1 && [[ -n "$ELASTIC_URL" ]]; then
        log_to_activity_stream "$TASK_ID" "heartbeat_update" "$ACTIVITY_DETAILS"
        log_info "activity_logged" "logged" "Heartbeat activity logged to stream"
    fi
    
    # Store in Redis for real-time monitoring
    redis-cli HSET "session:$SESSION_ID:status" \
        "last_update" "$CURRENT_TIMESTAMP" \
        "status" "$STATUS_UPDATE" \
        "activity" "$CURRENT_ACTIVITY" \
        "progress" "$PROGRESS_PERCENTAGE" >/dev/null 2>&1 || true
    redis-cli EXPIRE "session:$SESSION_ID:status" 3600 >/dev/null 2>&1 || true
fi

# Check for completion indicators
if [[ "$PROGRESS_PERCENTAGE" == "100" ]] || [[ "$STATUS_UPDATE" =~ ^(completed|finished|done)$ ]]; then
    log_info "completion_indicated" "completion_detected" "Task appears to be completing based on heartbeat data"
    state_set "completion_indicated" "true"
    
    # Chronicle significant progress milestone
    psql "$POSTGRES_DSN" -c "
        INSERT INTO chronicle_events (event_type, event_title, event_description, metadata, significance_level) 
        VALUES ('task_completion_indicated', 'Task Nearing Completion', 
                'Agent $AGENT_ID indicated task completion via heartbeat', 
                '{\"session_id\":\"$SESSION_ID\",\"task_id\":\"$TASK_ID\",\"progress\":\"$PROGRESS_PERCENTAGE\",\"status\":\"$STATUS_UPDATE\"}', 
                6);" >/dev/null 2>&1
fi

# Handle estimated completion time
if [[ -n "$ESTIMATED_COMPLETION" && "$ESTIMATED_COMPLETION" != "null" ]]; then
    # Validate and store estimated completion
    if date -d "$ESTIMATED_COMPLETION" >/dev/null 2>&1; then
        state_set "estimated_completion" "$ESTIMATED_COMPLETION"
        log_info "completion_estimate" "updated" "Task completion estimated for: $ESTIMATED_COMPLETION"
    else
        log_warning "invalid_completion_time" "ignored" "Invalid estimated completion time format: $ESTIMATED_COMPLETION"
    fi
fi

# Update resource lock timestamps to prevent premature cleanup
TARGET_FILES=$(echo "$ENVELOPE" | jq -r '.payload.target_files[]?' 2>/dev/null || echo "")
if [[ -n "$TARGET_FILES" ]]; then
    while IFS= read -r file_path; do
        if [[ -n "$file_path" ]]; then
            psql "$POSTGRES_DSN" -c "
                UPDATE resource_locks 
                SET locked_at = CURRENT_TIMESTAMP 
                WHERE session_id='$SESSION_ID' AND resource_path='$file_path';" >/dev/null 2>&1
        fi
    done <<< "$TARGET_FILES"
    log_info "locks_refreshed" "updated" "Resource lock timestamps refreshed"
fi

log_info "heartbeat_complete" "success" "Heartbeat processing completed for session '$SESSION_ID'"
exit 0