#!/bin/bash
# atomic/context-find-dependencies.sh - Analyze task dependencies using graph traversal
set -e

# Source required libraries
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/logging.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/data-access.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/state.sh"

# Set hook name for logging
export HOOK_NAME="context-find-dependencies"

# Read InteractionEnvelope from stdin
ENVELOPE=$(cat)
log_info "envelope_received" "processing" "InteractionEnvelope received for dependency analysis"

# Extract required fields from envelope
TASK_ID=$(echo "$ENVELOPE" | jq -r '.task_id')
SESSION_ID=$(echo "$ENVELOPE" | jq -r '.session_id')
AGENT_ID=$(echo "$ENVELOPE" | jq -r '.agent_id')
OBJECTIVE=$(echo "$ENVELOPE" | jq -r '.payload.objective // empty')
TARGET_FILES=$(echo "$ENVELOPE" | jq -r '.payload.target_files // empty')

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

# Get objective from task if not in payload
if [[ -z "$OBJECTIVE" ]]; then
    OBJECTIVE=$(psql "$POSTGRES_DSN" -t -A -c "
        SELECT objective 
        FROM tasks 
        WHERE task_id='$TASK_ID';" 2>/dev/null)
    
    if [[ -z "$OBJECTIVE" ]]; then
        log_error "objective_missing" "failed" "Cannot retrieve task objective for dependency analysis"
        exit 1
    fi
fi

log_info "dependency_analysis" "starting" "Analyzing dependencies for task: ${OBJECTIVE:0:100}..."

# Initialize dependency structure
DEPENDENCIES_JSON='{"dependencies": [], "blockers": [], "file_dependencies": [], "task_relationships": []}'

# 1. Analyze task-level dependencies from PostgreSQL
TASK_DEPENDENCIES=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT DISTINCT 
        t.task_id, 
        t.objective, 
        t.status, 
        t.created_by,
        t.updated_at
    FROM tasks t
    WHERE t.parent_task_id = '$TASK_ID' 
       OR t.task_id IN (
           SELECT parent_task_id 
           FROM tasks 
           WHERE task_id = '$TASK_ID' 
           AND parent_task_id IS NOT NULL
       )
    ORDER BY t.updated_at DESC
    LIMIT 10;" 2>/dev/null)

TASK_DEPS_JSON="[]"
if [[ -n "$TASK_DEPENDENCIES" ]]; then
    TASK_DEPS_JSON="["
    FIRST_ITEM=true
    while IFS='|' read -r tid obj status creator updated; do
        if [[ -n "$tid" ]]; then
            if [[ "$FIRST_ITEM" == true ]]; then
                FIRST_ITEM=false
            else
                TASK_DEPS_JSON="$TASK_DEPS_JSON,"
            fi
            TASK_DEPS_JSON="$TASK_DEPS_JSON$(jq -n \
                --arg task_id "$tid" \
                --arg objective "$obj" \
                --arg status "$status" \
                --arg created_by "$creator" \
                --arg updated_at "$updated" \
                '{task_id: $task_id, objective: $objective, status: $status, created_by: $created_by, updated_at: $updated_at}')"
        fi
    done <<< "$TASK_DEPENDENCIES"
    TASK_DEPS_JSON="$TASK_DEPS_JSON]"
    
    TASK_COUNT=$(echo "$TASK_DEPS_JSON" | jq 'length')
    log_info "task_dependencies" "success" "Found $TASK_COUNT related tasks"
fi

# 2. Identify potential blockers (active tasks by same agent or on same resources)
POTENTIAL_BLOCKERS=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT DISTINCT 
        t.task_id, 
        t.objective, 
        t.assigned_to,
        s.session_id,
        s.status as session_status,
        rl.resource_path
    FROM tasks t
    LEFT JOIN agent_sessions s ON t.task_id = s.task_id
    LEFT JOIN resource_locks rl ON s.session_id = rl.session_id
    WHERE (t.assigned_to = '$AGENT_ID' OR t.created_by = '$AGENT_ID')
      AND t.task_id != '$TASK_ID'
      AND t.status IN ('active', 'delegated')
      AND (s.status IN ('active', 'approved_for_execution') OR rl.resource_path IS NOT NULL)
    ORDER BY t.updated_at DESC
    LIMIT 5;" 2>/dev/null)

BLOCKERS_JSON="[]"
if [[ -n "$POTENTIAL_BLOCKERS" ]]; then
    BLOCKERS_JSON="["
    FIRST_ITEM=true
    while IFS='|' read -r tid obj assigned sid sstatus resource; do
        if [[ -n "$tid" ]]; then
            if [[ "$FIRST_ITEM" == true ]]; then
                FIRST_ITEM=false
            else
                BLOCKERS_JSON="$BLOCKERS_JSON,"
            fi
            BLOCKERS_JSON="$BLOCKERS_JSON$(jq -n \
                --arg task_id "$tid" \
                --arg objective "$obj" \
                --arg assigned_to "$assigned" \
                --arg session_id "$sid" \
                --arg session_status "$sstatus" \
                --arg resource_path "$resource" \
                '{task_id: $task_id, objective: $objective, assigned_to: $assigned_to, session_id: $session_id, session_status: $session_status, resource_path: $resource_path}')"
        fi
    done <<< "$POTENTIAL_BLOCKERS"
    BLOCKERS_JSON="$BLOCKERS_JSON]"
    
    BLOCKERS_COUNT=$(echo "$BLOCKERS_JSON" | jq 'length')
    log_info "potential_blockers" "warning" "Found $BLOCKERS_COUNT potential blocking tasks"
fi

# 3. Analyze file dependencies using HelixDB graph traversal (if available and target files provided)
FILE_DEPS_JSON="[]"
if [[ -n "$TARGET_FILES" && "$TARGET_FILES" != "null" && command -v curl >/dev/null 2>&1 && -n "$HelixDB_HTTP_URL" ]]; then
    log_info "HelixDB_traversal" "processing" "Analyzing file dependencies via HelixDB"
    
    # Convert target files to array for processing
    TARGET_FILES_ARRAY=$(echo "$TARGET_FILES" | jq -r '.[]?' 2>/dev/null || echo "$TARGET_FILES" | tr ',' '\n')
    
    FILE_DEPS_JSON="["
    FIRST_FILE=true
    
    while read -r target_file; do
        if [[ -n "$target_file" && "$target_file" != "null" ]]; then
            # Query HelixDB for file dependencies using Cypher
            CYPHER_QUERY=$(jq -n \
                --arg file "$target_file" \
                '{"query": "MATCH (f:File {path: $file})-[:DEPENDS_ON*1..3]->(dep:File) RETURN dep.path, dep.type, dep.last_modified ORDER BY dep.last_modified DESC LIMIT 10", "parameters": {"file": $file}}')
            
            FILE_DEPS=$(curl -s -u "$HelixDB_AUTH" -H "Content-Type: application/json" \
                -X POST -d "$CYPHER_QUERY" "$HelixDB_HTTP_URL/db/data/transaction/commit" 2>/dev/null | \
                jq -r '.results[0].data[]?.row | @json' 2>/dev/null || echo "")
            
            if [[ -n "$FILE_DEPS" ]]; then
                while read -r dep_data; do
                    if [[ -n "$dep_data" ]]; then
                        DEP_PATH=$(echo "$dep_data" | jq -r '.[0]')
                        DEP_TYPE=$(echo "$dep_data" | jq -r '.[1]')
                        DEP_MODIFIED=$(echo "$dep_data" | jq -r '.[2]')
                        
                        if [[ "$FIRST_FILE" == true ]]; then
                            FIRST_FILE=false
                        else
                            FILE_DEPS_JSON="$FILE_DEPS_JSON,"
                        fi
                        
                        FILE_DEPS_JSON="$FILE_DEPS_JSON$(jq -n \
                            --arg source "$target_file" \
                            --arg dependency "$DEP_PATH" \
                            --arg type "$DEP_TYPE" \
                            --arg last_modified "$DEP_MODIFIED" \
                            '{source_file: $source, dependency: $dependency, type: $type, last_modified: $last_modified}')"
                    fi
                done <<< "$FILE_DEPS"
            fi
        fi
    done <<< "$TARGET_FILES_ARRAY"
    
    FILE_DEPS_JSON="$FILE_DEPS_JSON]"
    
    FILE_DEPS_COUNT=$(echo "$FILE_DEPS_JSON" | jq 'length')
    log_info "file_dependencies" "success" "Found $FILE_DEPS_COUNT file dependencies via graph traversal"
else
    log_info "file_dependencies" "skipped" "HelixDB not available or no target files specified"
fi

# 4. Analyze patterns of similar task dependencies
PATTERN_DEPENDENCIES=$(psql "$POSTGRES_DSN" -t -A -c "
    SELECT 
        p.pattern_signature,
        p.pattern_name,
        p.use_case,
        p.value_score
    FROM patterns p
    WHERE p.pattern_content ILIKE '%$(echo "$OBJECTIVE" | cut -d' ' -f1 | head -c 20)%'
       OR p.use_case ILIKE '%dependency%'
       OR p.pattern_type = 'dependency_pattern'
    ORDER BY p.value_score DESC, p.usage_count DESC
    LIMIT 5;" 2>/dev/null)

PATTERN_DEPS_JSON="[]"
if [[ -n "$PATTERN_DEPENDENCIES" ]]; then
    PATTERN_DEPS_JSON="["
    FIRST_ITEM=true
    while IFS='|' read -r signature name use_case score; do
        if [[ -n "$signature" ]]; then
            if [[ "$FIRST_ITEM" == true ]]; then
                FIRST_ITEM=false
            else
                PATTERN_DEPS_JSON="$PATTERN_DEPS_JSON,"
            fi
            PATTERN_DEPS_JSON="$PATTERN_DEPS_JSON$(jq -n \
                --arg signature "$signature" \
                --arg name "$name" \
                --arg use_case "$use_case" \
                --arg value_score "$score" \
                '{pattern_signature: $signature, pattern_name: $name, use_case: $use_case, value_score: ($value_score | tonumber)}')"
        fi
    done <<< "$PATTERN_DEPENDENCIES"
    PATTERN_DEPS_JSON="$PATTERN_DEPS_JSON]"
    
    PATTERN_COUNT=$(echo "$PATTERN_DEPS_JSON" | jq 'length')
    log_info "pattern_dependencies" "success" "Found $PATTERN_COUNT relevant dependency patterns"
fi

# 5. Combine all dependency information
COMBINED_DEPENDENCIES=$(jq -n \
    --argjson task_deps "$TASK_DEPS_JSON" \
    --argjson blockers "$BLOCKERS_JSON" \
    --argjson file_deps "$FILE_DEPS_JSON" \
    --argjson pattern_deps "$PATTERN_DEPS_JSON" \
    '{
        task_dependencies: $task_deps,
        potential_blockers: $blockers,
        file_dependencies: $file_deps,
        dependency_patterns: $pattern_deps,
        analysis_timestamp: now
    }')

# Calculate dependency metrics
TOTAL_DEPENDENCIES=$(echo "$COMBINED_DEPENDENCIES" | jq '.task_dependencies | length + .potential_blockers | length + .file_dependencies | length')
HIGH_RISK_BLOCKERS=$(echo "$COMBINED_DEPENDENCIES" | jq '[.potential_blockers[] | select(.session_status == "active")] | length')

# Store results in workflow state
state_set "task_dependencies" "$COMBINED_DEPENDENCIES"
state_set "dependency_analysis_complete" "true"
state_set "total_dependencies" "$TOTAL_DEPENDENCIES"
state_set "high_risk_blockers" "$HIGH_RISK_BLOCKERS"

# Log dependency analysis to database
INSERT_RESULT=$(psql "$POSTGRES_DSN" -c "
    INSERT INTO context_injections (session_id, context_source, context_data) 
    VALUES ('$SESSION_ID', 'dependency_analysis', 'Found $TOTAL_DEPENDENCIES dependencies: tasks, blockers, files, patterns');" 2>&1)

if [[ $? -eq 0 ]]; then
    log_info "analysis_logged" "success" "Dependency analysis logged to database"
else
    log_warning "analysis_log_failed" "warning" "Failed to log dependency analysis: $INSERT_RESULT"
fi

# Generate dependency risk assessment
RISK_LEVEL="low"
if [[ "$HIGH_RISK_BLOCKERS" -gt 0 ]]; then
    RISK_LEVEL="high"
    log_warning "high_risk_dependencies" "warning" "$HIGH_RISK_BLOCKERS active blocking tasks detected"
elif [[ "$TOTAL_DEPENDENCIES" -gt 5 ]]; then
    RISK_LEVEL="medium"
    log_info "medium_risk_dependencies" "info" "Multiple dependencies detected, may require coordination"
fi

# Log to activity stream
if command -v curl >/dev/null 2>&1 && [[ -n "$ELASTIC_URL" ]]; then
    DEPENDENCY_DETAILS=$(jq -n \
        --arg session_id "$SESSION_ID" \
        --arg total_dependencies "$TOTAL_DEPENDENCIES" \
        --arg high_risk_blockers "$HIGH_RISK_BLOCKERS" \
        --arg risk_level "$RISK_LEVEL" \
        '{session_id: $session_id, total_dependencies: ($total_dependencies | tonumber), high_risk_blockers: ($high_risk_blockers | tonumber), risk_level: $risk_level}')
    
    log_to_activity_stream "$TASK_ID" "dependency_analysis_completed" "$DEPENDENCY_DETAILS" || true
    log_info "activity_logged" "logged" "Dependency analysis logged to activity stream"
fi

# Chronicle the dependency analysis
psql "$POSTGRES_DSN" -c "
    INSERT INTO chronicle_events (event_type, event_title, event_description, metadata, significance_level) 
    VALUES ('dependency_analysis', 'Task Dependencies Analyzed', 
            'Found $TOTAL_DEPENDENCIES dependencies for task $TASK_ID with risk level: $RISK_LEVEL', 
            '{\"session_id\":\"$SESSION_ID\",\"task_id\":\"$TASK_ID\",\"total_dependencies\":$TOTAL_DEPENDENCIES,\"risk_level\":\"$RISK_LEVEL\"}', 
            3);" >/dev/null 2>&1

# Store detailed dependency report for debugging/audit
DEPENDENCY_REPORT="$CLAUDE_PROJECT_DIR/.claude/context/dependency-analysis-$SESSION_ID.json"
echo "$COMBINED_DEPENDENCIES" | jq '.' > "$DEPENDENCY_REPORT"
log_info "dependency_report" "created" "Detailed report saved: $DEPENDENCY_REPORT"

# Output structured result for workflow integration
cat <<EOF
{
  "session_id": "$SESSION_ID",
  "task_id": "$TASK_ID",
  "agent_id": "$AGENT_ID",
  "analysis_completed": true,
  "total_dependencies": $TOTAL_DEPENDENCIES,
  "high_risk_blockers": $HIGH_RISK_BLOCKERS,
  "risk_level": "$RISK_LEVEL",
  "dependency_report": "$DEPENDENCY_REPORT",
  "dependencies": $COMBINED_DEPENDENCIES
}
EOF

log_info "dependency_analysis_complete" "success" "Found $TOTAL_DEPENDENCIES dependencies with $RISK_LEVEL risk level for session '$SESSION_ID'"
exit 0