#!/bin/bash
# atomic/context-update-effectiveness.sh - Track context quality and effectiveness
set -e

# Source required libraries
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/logging.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/data-access.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/state.sh"

# Set hook name for logging
export HOOK_NAME="context-update-effectiveness"

# Read InteractionEnvelope from stdin
ENVELOPE=$(cat)
log_info "envelope_received" "processing" "InteractionEnvelope received for context effectiveness update"

# Extract required fields from envelope
TASK_ID=$(echo "$ENVELOPE" | jq -r '.task_id')
SESSION_ID=$(echo "$ENVELOPE" | jq -r '.session_id')
AGENT_ID=$(echo "$ENVELOPE" | jq -r '.agent_id')
EVENT_TYPE=$(echo "$ENVELOPE" | jq -r '.event_type')

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

log_info "effectiveness_update" "starting" "Updating context effectiveness for session '$SESSION_ID'"

# Extract task completion details from payload
TASK_STATUS=$(echo "$ENVELOPE" | jq -r '.payload.status // "unknown"')
ERROR_MESSAGE=$(echo "$ENVELOPE" | jq -r '.payload.error_message // empty')
ARTIFACTS=$(echo "$ENVELOPE" | jq -r '.payload.artifacts // empty')

log_info "completion_details" "processing" "Task status: $TASK_STATUS"

# Calculate effectiveness score based on task outcome
EFFECTIVENESS_SCORE="0.5"  # Default neutral score

case "$TASK_STATUS" in
    "success"|"completed")
        EFFECTIVENESS_SCORE="0.9"
        ;;
    "partial_success")
        EFFECTIVENESS_SCORE="0.6"
        ;;
    "failed"|"error")
        EFFECTIVENESS_SCORE="0.2"
        ;;
    "cancelled"|"timeout")
        EFFECTIVENESS_SCORE="0.3"
        ;;
    *)
        EFFECTIVENESS_SCORE="0.5"  # Unknown status
        ;;
esac

# Adjust score based on additional indicators from the completion envelope
if [[ -n "$ARTIFACTS" && "$ARTIFACTS" != "null" ]]; then
    # Task produced artifacts - positive indicator
    ARTIFACTS_COUNT=$(echo "$ARTIFACTS" | jq 'length // 0')
    if [[ "$ARTIFACTS_COUNT" -gt 0 ]]; then
        EFFECTIVENESS_SCORE=$(echo "scale=2; $EFFECTIVENESS_SCORE + 0.1" | bc -l)
        log_info "artifacts_bonus" "processing" "Added bonus for $ARTIFACTS_COUNT artifacts"
    fi
fi

if [[ -n "$ERROR_MESSAGE" && "$ERROR_MESSAGE" != "null" ]]; then
    # Task had errors - negative indicator
    EFFECTIVENESS_SCORE=$(echo "scale=2; $EFFECTIVENESS_SCORE - 0.2" | bc -l)
    log_info "error_penalty" "processing" "Applied penalty for error message"
fi

# Get execution duration from workflow state
START_TIME=$(state_get "workflow_start_time" 2>/dev/null || echo "")
if [[ -n "$START_TIME" ]]; then
    END_TIME=$(date +%s)
    DURATION_SECONDS=$((END_TIME - START_TIME))
    
    # Reward reasonable execution times (1-30 minutes)
    if [[ $DURATION_SECONDS -gt 60 ]] && [[ $DURATION_SECONDS -lt 1800 ]]; then
        EFFECTIVENESS_SCORE=$(echo "scale=2; $EFFECTIVENESS_SCORE + 0.05" | bc -l)
        log_info "duration_bonus" "processing" "Added bonus for reasonable duration: ${DURATION_SECONDS}s"
    elif [[ $DURATION_SECONDS -gt 1800 ]]; then
        # Penalize very long execution times (might indicate poor context)
        EFFECTIVENESS_SCORE=$(echo "scale=2; $EFFECTIVENESS_SCORE - 0.1" | bc -l)
        log_info "duration_penalty" "processing" "Applied penalty for long duration: ${DURATION_SECONDS}s"
    fi
else
    DURATION_SECONDS=0
fi

# Ensure score stays within bounds [0.0, 1.0]
if (( $(echo "$EFFECTIVENESS_SCORE > 1.0" | bc -l) )); then
    EFFECTIVENESS_SCORE="1.0"
elif (( $(echo "$EFFECTIVENESS_SCORE < 0.0" | bc -l) )); then
    EFFECTIVENESS_SCORE="0.0"
fi

log_info "score_calculated" "success" "Final effectiveness score: $EFFECTIVENESS_SCORE (status: $TASK_STATUS, duration: ${DURATION_SECONDS}s)"

# Update all context injection records for this session with effectiveness score
UPDATE_RESULT=$(psql "$POSTGRES_DSN" -c "
    UPDATE context_injections 
    SET effectiveness_score = $EFFECTIVENESS_SCORE 
    WHERE session_id = '$SESSION_ID';" 2>&1)

if [[ $? -eq 0 ]]; then
    UPDATED_COUNT=$(echo "$UPDATE_RESULT" | grep -o 'UPDATE [0-9]*' | grep -o '[0-9]*' || echo "0")
    log_info "effectiveness_updated" "success" "Updated $UPDATED_COUNT context injection records"
else
    log_warning "update_failed" "warning" "Failed to update context effectiveness: $UPDATE_RESULT"
fi

# Analyze context source performance for this agent
CONTEXT_ANALYSIS=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT 
        context_source,
        ROUND(AVG(effectiveness_score), 3) as avg_effectiveness,
        COUNT(*) as usage_count,
        ROUND(MIN(effectiveness_score), 3) as min_score,
        ROUND(MAX(effectiveness_score), 3) as max_score
    FROM context_injections 
    WHERE session_id IN (
        SELECT session_id FROM agent_sessions WHERE agent_id = '$AGENT_ID'
    )
    AND effectiveness_score IS NOT NULL 
    GROUP BY context_source 
    ORDER BY avg_effectiveness DESC;" 2>/dev/null)

if [[ -n "$CONTEXT_ANALYSIS" ]]; then
    ANALYSIS_COUNT=$(echo "$CONTEXT_ANALYSIS" | wc -l)
    log_info "context_analysis" "completed" "Performance analysis: $ANALYSIS_COUNT context sources analyzed"
    
    # Store analysis for learning
    ANALYSIS_FILE="$CLAUDE_PROJECT_DIR/.claude/context/effectiveness-analysis-$AGENT_ID.md"
    mkdir -p "$(dirname "$ANALYSIS_FILE")"
    
    cat > "$ANALYSIS_FILE" << EOF
# Context Effectiveness Analysis for $AGENT_ID
Generated: $(date -Iseconds)
Session: $SESSION_ID
Task: $TASK_ID

## Context Source Performance
| Source | Avg Score | Usage Count | Min Score | Max Score |
|--------|-----------|-------------|-----------|-----------|
EOF
    
    while IFS='|' read -r source avg count min_score max_score; do
        if [[ -n "$source" ]]; then
            echo "| $source | $avg | $count | $min_score | $max_score |" >> "$ANALYSIS_FILE"
        fi
    done <<< "$CONTEXT_ANALYSIS"
    
    log_info "analysis_stored" "success" "Analysis stored: $ANALYSIS_FILE"
fi

# Identify high and low performing context sources
HIGH_PERFORMING=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT context_source, ROUND(AVG(effectiveness_score), 3) as avg_score, COUNT(*) as count
    FROM context_injections 
    WHERE session_id IN (
        SELECT session_id FROM agent_sessions WHERE agent_id = '$AGENT_ID'
    )
    AND effectiveness_score IS NOT NULL 
    GROUP BY context_source 
    HAVING AVG(effectiveness_score) > 0.8 AND COUNT(*) >= 2
    ORDER BY avg_score DESC;" 2>/dev/null)

LOW_PERFORMING=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT context_source, ROUND(AVG(effectiveness_score), 3) as avg_score, COUNT(*) as count
    FROM context_injections 
    WHERE session_id IN (
        SELECT session_id FROM agent_sessions WHERE agent_id = '$AGENT_ID'
    )
    AND effectiveness_score IS NOT NULL 
    GROUP BY context_source 
    HAVING AVG(effectiveness_score) < 0.4 AND COUNT(*) >= 3
    ORDER BY avg_score ASC;" 2>/dev/null)

if [[ -n "$HIGH_PERFORMING" ]]; then
    log_info "high_performing_context" "learning" "High-performing context sources identified"
    echo "$HIGH_PERFORMING" > "$CLAUDE_PROJECT_DIR/.claude/context/high-performing-contexts-$AGENT_ID.txt"
fi

if [[ -n "$LOW_PERFORMING" ]]; then
    log_warning "low_performing_context" "learning" "Low-performing context sources identified"
    echo "$LOW_PERFORMING" > "$CLAUDE_PROJECT_DIR/.claude/context/low-performing-contexts-$AGENT_ID.txt"
fi

# Store session-level effectiveness metrics
SESSION_METRICS=$(jq -n \
    --arg session_id "$SESSION_ID" \
    --arg agent_id "$AGENT_ID" \
    --arg task_id "$TASK_ID" \
    --arg task_status "$TASK_STATUS" \
    --arg effectiveness_score "$EFFECTIVENESS_SCORE" \
    --arg duration_seconds "$DURATION_SECONDS" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{
        session_id: $session_id,
        agent_id: $agent_id,
        task_id: $task_id,
        task_status: $task_status,
        effectiveness_score: ($effectiveness_score | tonumber),
        execution_duration_seconds: ($duration_seconds | tonumber),
        timestamp: $timestamp
    }')

echo "$SESSION_METRICS" >> "$CLAUDE_PROJECT_DIR/.claude/logs/context-effectiveness.jsonl"

# Update agent learning profile
AGENT_PROFILE="$CLAUDE_PROJECT_DIR/.claude/context/agents/$AGENT_ID.json"
mkdir -p "$(dirname "$AGENT_PROFILE")"

if [[ -f "$AGENT_PROFILE" ]]; then
    # Update existing profile
    jq --argjson score "$EFFECTIVENESS_SCORE" --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '
        .last_effectiveness_score = $score |
        .last_updated = $timestamp |
        .total_tasks = (.total_tasks // 0) + 1 |
        .average_effectiveness = ((.average_effectiveness // 0.5) * (.total_tasks - 1) + $score) / .total_tasks
    ' "$AGENT_PROFILE" > "$AGENT_PROFILE.tmp" && mv "$AGENT_PROFILE.tmp" "$AGENT_PROFILE"
else
    # Create new profile
    jq -n \
        --arg agent_id "$AGENT_ID" \
        --argjson score "$EFFECTIVENESS_SCORE" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            agent_id: $agent_id,
            total_tasks: 1,
            last_effectiveness_score: $score,
            average_effectiveness: $score,
            last_updated: $timestamp,
            learning_enabled: true
        }' > "$AGENT_PROFILE"
fi

log_info "agent_profile_updated" "success" "Agent learning profile updated: $AGENT_PROFILE"

# Store in workflow state
state_set "effectiveness_score" "$EFFECTIVENESS_SCORE"
state_set "effectiveness_updated" "true"

# Log to activity stream
if command -v curl >/dev/null 2>&1 && [[ -n "$ELASTIC_URL" ]]; then
    EFFECTIVENESS_DETAILS=$(jq -n \
        --arg session_id "$SESSION_ID" \
        --arg effectiveness_score "$EFFECTIVENESS_SCORE" \
        --arg task_status "$TASK_STATUS" \
        --arg duration_seconds "$DURATION_SECONDS" \
        '{session_id: $session_id, effectiveness_score: ($effectiveness_score | tonumber), task_status: $task_status, duration_seconds: ($duration_seconds | tonumber)}')
    
    log_to_activity_stream "$TASK_ID" "context_effectiveness_updated" "$EFFECTIVENESS_DETAILS" || true
    log_info "activity_logged" "logged" "Context effectiveness logged to activity stream"
fi

# Chronicle the effectiveness update
psql "$POSTGRES_DSN" -c "
    INSERT INTO chronicle_events (event_type, event_title, event_description, metadata, significance_level) 
    VALUES ('context_effectiveness_updated', 'Context Effectiveness Updated', 
            'Context effectiveness score of $EFFECTIVENESS_SCORE recorded for agent $AGENT_ID', 
            '{\"session_id\":\"$SESSION_ID\",\"task_id\":\"$TASK_ID\",\"effectiveness_score\":$EFFECTIVENESS_SCORE}', 
            2);" >/dev/null 2>&1

# Trigger context optimization if effectiveness is consistently low
if (( $(echo "$EFFECTIVENESS_SCORE < 0.3" | bc -l) )); then
    log_warning "low_effectiveness" "optimization" "Low effectiveness score may trigger context optimization"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ")|LOW_EFFECTIVENESS|$AGENT_ID|$SESSION_ID|$EFFECTIVENESS_SCORE" >> "$CLAUDE_PROJECT_DIR/.claude/logs/optimization-triggers.log"
fi

# Output structured result for workflow integration
cat <<EOF
{
  "session_id": "$SESSION_ID",
  "task_id": "$TASK_ID",
  "agent_id": "$AGENT_ID",
  "effectiveness_updated": true,
  "effectiveness_score": $EFFECTIVENESS_SCORE,
  "task_status": "$TASK_STATUS",
  "execution_duration_seconds": $DURATION_SECONDS,
  "high_performing_sources": $(echo "$HIGH_PERFORMING" | wc -l),
  "low_performing_sources": $(echo "$LOW_PERFORMING" | wc -l)
}
EOF

log_info "effectiveness_update_complete" "success" "Context effectiveness tracking completed (score: $EFFECTIVENESS_SCORE)"
exit 0