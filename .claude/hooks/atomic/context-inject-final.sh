#!/bin/bash
# atomic/context-inject-final.sh - Final context injection to agents before execution
set -e

# Source required libraries
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/logging.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/data-access.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/state.sh"

# Set hook name for logging
export HOOK_NAME="context-inject-final"

# Read InteractionEnvelope from stdin
ENVELOPE=$(cat)
log_info "envelope_received" "processing" "InteractionEnvelope received for final context injection"

# Extract required fields from envelope
TASK_ID=$(echo "$ENVELOPE" | jq -r '.task_id')
SESSION_ID=$(echo "$ENVELOPE" | jq -r '.session_id')
AGENT_ID=$(echo "$ENVELOPE" | jq -r '.agent_id')
OBJECTIVE=$(echo "$ENVELOPE" | jq -r '.payload.objective // empty')

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

log_info "context_injection" "starting" "Performing final context injection for session '$SESSION_ID'"

# Get objective from task if not in payload
if [[ -z "$OBJECTIVE" ]]; then
    OBJECTIVE=$(psql "$POSTGRES_DSN" -t -A -c "
        SELECT objective 
        FROM tasks 
        WHERE task_id='$TASK_ID';" 2>/dev/null)
    
    if [[ -z "$OBJECTIVE" ]]; then
        log_error "objective_missing" "failed" "Cannot retrieve task objective for context injection"
        exit 1
    fi
fi

log_info "objective_retrieved" "processing" "Task objective: ${OBJECTIVE:0:100}..."

# Initialize context aggregation
CONTEXT_SOURCES=""
FINAL_CONTEXT=""

# 1. Retrieve similar task patterns from previous workflow state
SIMILAR_TASKS=$(state_get "similar_tasks" 2>/dev/null || echo "{}")
if [[ "$SIMILAR_TASKS" != "{}" && "$SIMILAR_TASKS" != "null" && -n "$SIMILAR_TASKS" ]]; then
    PATTERN_CONTEXT=$(echo "$SIMILAR_TASKS" | jq -r '.[] | "Task Pattern: " + .signature + " - " + .content_snippet' 2>/dev/null | head -3)
    if [[ -n "$PATTERN_CONTEXT" ]]; then
        FINAL_CONTEXT="${FINAL_CONTEXT}

## Similar Task Patterns:
$PATTERN_CONTEXT"
        CONTEXT_SOURCES="${CONTEXT_SOURCES}similar_patterns,"
        log_info "pattern_context_added" "success" "Added similar task patterns to context"
    fi
fi

# 2. Retrieve task dependencies from previous workflow state
TASK_DEPENDENCIES=$(state_get "task_dependencies" 2>/dev/null || echo "{}")
if [[ "$TASK_DEPENDENCIES" != "{}" && "$TASK_DEPENDENCIES" != "null" && -n "$TASK_DEPENDENCIES" ]]; then
    DEPS_CONTEXT=$(echo "$TASK_DEPENDENCIES" | jq -r '
        if .dependencies and (.dependencies | length > 0) then 
            "Dependencies: " + (.dependencies | join(", ")) 
        else 
            empty 
        end' 2>/dev/null)
    
    if [[ -n "$DEPS_CONTEXT" ]]; then
        FINAL_CONTEXT="${FINAL_CONTEXT}

## Task Dependencies:
$DEPS_CONTEXT"
        CONTEXT_SOURCES="${CONTEXT_SOURCES}dependencies,"
        log_info "dependency_context_added" "success" "Added task dependencies to context"
    fi
fi

# 3. Retrieve high-value patterns from database
HIGH_VALUE_PATTERNS=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT pattern_name, pattern_content, use_case 
    FROM patterns 
    WHERE value_score >= 0.8 
    AND pattern_type IN ('code_template', 'best_practice', 'solution_approach')
    ORDER BY value_score DESC, usage_count DESC 
    LIMIT 3;" 2>/dev/null)

if [[ -n "$HIGH_VALUE_PATTERNS" ]]; then
    PATTERN_LIST=""
    while IFS='|' read -r name content use_case; do
        if [[ -n "$name" ]]; then
            PATTERN_LIST="${PATTERN_LIST}
- ${name}: ${use_case} - ${content:0:150}..."
        fi
    done <<< "$HIGH_VALUE_PATTERNS"
    
    if [[ -n "$PATTERN_LIST" ]]; then
        FINAL_CONTEXT="${FINAL_CONTEXT}

## High-Value Patterns:$PATTERN_LIST"
        CONTEXT_SOURCES="${CONTEXT_SOURCES}high_value_patterns,"
        log_info "pattern_db_context_added" "success" "Added high-value patterns from database"
    fi
fi

# 4. Add governance and safety reminders
FINAL_CONTEXT="${FINAL_CONTEXT}

## Governance Reminders:
- Always validate inputs and handle edge cases
- Log significant actions for audit trail
- Respect resource locks and concurrent access patterns
- Follow the principle of least privilege
- Escalate to human oversight when uncertain"

CONTEXT_SOURCES="${CONTEXT_SOURCES}governance_reminders"

# 5. Add session-specific context
SESSION_INFO=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT status, started_at 
    FROM agent_sessions 
    WHERE session_id='$SESSION_ID';" 2>/dev/null)

if [[ -n "$SESSION_INFO" ]]; then
    SESSION_STATUS=$(echo "$SESSION_INFO" | cut -d'|' -f1)
    SESSION_START=$(echo "$SESSION_INFO" | cut -d'|' -f2)
    
    FINAL_CONTEXT="${FINAL_CONTEXT}

## Session Context:
- Session ID: $SESSION_ID
- Current Status: $SESSION_STATUS
- Started: $SESSION_START
- Agent: $AGENT_ID"
    
    CONTEXT_SOURCES="${CONTEXT_SOURCES},session_info"
    log_info "session_context_added" "success" "Added session-specific context"
fi

# Calculate context quality metrics
CONTEXT_LENGTH=${#FINAL_CONTEXT}
SOURCE_COUNT=$(echo "$CONTEXT_SOURCES" | tr ',' '\n' | grep -v '^$' | wc -l)

# Create context injection file for the agent
CONTEXT_FILE="$CLAUDE_PROJECT_DIR/.claude/context/agent-context-$SESSION_ID.md"
mkdir -p "$(dirname "$CONTEXT_FILE")"

cat > "$CONTEXT_FILE" << EOF
# Agent Context Injection
**Session**: $SESSION_ID  
**Agent**: $AGENT_ID  
**Task**: $TASK_ID  
**Injected**: $(date -Iseconds)

## Task Objective
$OBJECTIVE

$FINAL_CONTEXT

---
*This context was curated by the LevAIthan system based on similar patterns, dependencies, and system knowledge.*
EOF

# Log context injection to database
INSERT_RESULT=$(psql "$POSTGRES_DSN" -c "
    INSERT INTO context_injections (session_id, context_source, context_data) 
    VALUES ('$SESSION_ID', '$CONTEXT_SOURCES', \$\$Final Context Injection: $CONTEXT_LENGTH chars, $SOURCE_COUNT sources\$\$);" 2>&1)

if [[ $? -eq 0 ]]; then
    log_info "context_logged" "success" "Context injection logged to database"
else
    log_warning "context_log_failed" "warning" "Failed to log context injection: $INSERT_RESULT"
fi

# Store in workflow state for effectiveness tracking
state_set "final_context_injected" "true"
state_set "context_length" "$CONTEXT_LENGTH"
state_set "context_sources" "$CONTEXT_SOURCES"
state_set "context_source_count" "$SOURCE_COUNT"
state_set "context_file" "$CONTEXT_FILE"
state_set "context_injected_at" "$(date -Iseconds)"

# Set environment variables for immediate access
export AGENT_CONTEXT="$FINAL_CONTEXT"
export AGENT_CONTEXT_FILE="$CONTEXT_FILE"

# Log to activity stream
if command -v curl >/dev/null 2>&1 && [[ -n "$ELASTIC_URL" ]]; then
    CONTEXT_DETAILS=$(jq -n \
        --arg session_id "$SESSION_ID" \
        --arg context_length "$CONTEXT_LENGTH" \
        --arg source_count "$SOURCE_COUNT" \
        --arg sources "$CONTEXT_SOURCES" \
        '{session_id: $session_id, context_length: ($context_length | tonumber), source_count: ($source_count | tonumber), sources: $sources}')
    
    log_to_activity_stream "$TASK_ID" "final_context_injected" "$CONTEXT_DETAILS" || true
    log_info "activity_logged" "logged" "Context injection logged to activity stream"
fi

# Chronicle the context injection
psql "$POSTGRES_DSN" -c "
    INSERT INTO chronicle_events (event_type, event_title, event_description, metadata, significance_level) 
    VALUES ('final_context_injection', 'Final Context Injected', 
            'Agent $AGENT_ID received final context for task execution', 
            '{\"session_id\":\"$SESSION_ID\",\"task_id\":\"$TASK_ID\",\"context_length\":$CONTEXT_LENGTH,\"source_count\":$SOURCE_COUNT}', 
            3);" >/dev/null 2>&1

# Output structured result for workflow integration
cat <<EOF
{
  "session_id": "$SESSION_ID",
  "task_id": "$TASK_ID",
  "agent_id": "$AGENT_ID",
  "context_injected": true,
  "context_length": $CONTEXT_LENGTH,
  "source_count": $SOURCE_COUNT,
  "sources": "$CONTEXT_SOURCES",
  "context_file": "$CONTEXT_FILE",
  "final_context": $(echo "$FINAL_CONTEXT" | jq -R -s .)
}
EOF

log_info "context_injection_complete" "success" "Final context injection completed for session '$SESSION_ID'"
exit 0