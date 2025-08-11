#!/bin/bash
# atomic/coord-check-conflict.sh - Claude-powered conflict prediction and resolution

set -euo pipefail
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/state.sh"  
source "$HOOKS_DIR/lib/data-access.sh"
source "$HOOKS_DIR/lib/claude.sh"

export HOOK_NAME="atomic/coord-check-conflict"

# Get task info from state
agent_name=$(state_get "agent_name")
session_id=$(state_get "session_id")
objective=$(state_get "objective")
target_files_json=$(state_get "target_files_json")

log_info "conflict_check" "running" "Analyzing conflicts for agent '$agent_name'"

# Extract target files
target_files=""
if [[ -n "$target_files_json" ]] && [[ "$target_files_json" != "null" ]]; then
    target_files=$(echo "$target_files_json" | jq -r '.[]?' | tr '\n' ' ' | sed 's/ $//')
fi

# If no files involved, no conflicts possible
if [[ -z "$target_files" ]]; then
    log_info "no_files" "skipped" "No target files specified, no conflicts possible"
    exit 0
fi

log_info "files_check" "running" "Checking conflicts for files: $target_files"

# Check for active resource locks (immediate conflicts)
immediate_conflicts=""
for file in $target_files; do
    conflicting_session=$(_psql_query "SELECT session_id FROM resource_locks WHERE resource_path='$file' AND session_id != '$session_id'")
    if [[ -n "$conflicting_session" ]]; then
        conflicting_agent=$(_psql_query "SELECT agent_id FROM agent_sessions WHERE session_id='$conflicting_session'")
        immediate_conflicts="$immediate_conflicts $file:$conflicting_agent"
    fi
done

# Block if immediate conflicts exist
if [[ -n "$immediate_conflicts" ]]; then
    log_error "immediate_conflict" "blocked" "Resource locks prevent access: $immediate_conflicts"
    echo "CONFLICT: Files currently locked by other agents: $immediate_conflicts" >&2
    exit 1
fi

# Gather data for Claude's conflict analysis
active_sessions=$(_psql_query "SELECT agent_id, task_id, objective, created_at FROM agent_sessions WHERE status IN ('pending', 'approved_for_execution', 'active') AND session_id != '$session_id'")

# Get recent file modifications to understand system state
recent_changes=""
for file in $target_files; do
    recent_change=$(_psql_query "SELECT agent_id, created_at FROM agent_sessions WHERE task_id IN (SELECT task_id FROM agent_sessions) AND created_at > NOW() - INTERVAL '1 hour' LIMIT 5" || echo "")
    if [[ -n "$recent_change" ]]; then
        recent_changes="$recent_changes $file:$recent_change"
    fi
done

# Get dependency information from HelixDB if available
dependencies=""
if command -v curl >/dev/null 2>&1; then
    for file in $target_files; do
        # Query HelixDB for file dependencies
        dep_query="{\"query\": \"MATCH (f:File {path:'$file'})-[:DEPENDS_ON]->(d:File) RETURN d.path LIMIT 5\"}"
        file_deps=$(curl -s -u "$HelixDB_AUTH" -H "Content-Type: application/json" -X POST -d "$dep_query" "$HelixDB_HTTP_URL/db/data/transaction/commit" 2>/dev/null | jq -r '.results[0].data[0].row[0] // empty' | tr '\n' ',' | sed 's/,$//' || echo "")
        if [[ -n "$file_deps" ]]; then
            dependencies="$dependencies $file:[$file_deps]"
        fi
    done
fi

log_info "conflict_data" "collected" "Active sessions: $(echo "$active_sessions" | wc -l), Dependencies: $(echo "$dependencies" | wc -w)"

# Use Claude to predict potential conflicts intelligently  
conflict_analysis=$(claude_analyze_conflicts "$objective" "$target_files" "$active_sessions" "$recent_changes $dependencies")

if [[ $? -ne 0 ]] || [[ -z "$conflict_analysis" ]]; then
    # Fallback to simple agent state conflict detection if Claude fails
    log_warning "claude_fallback" "degraded" "Claude analysis failed, using basic conflict detection"
    
    # Check agent state files for potential conflicts (from elmoai pattern)
    agent_conflicts=""
    state_dir="$CLAUDE_PROJECT_DIR/.claude/state/agents"
    mkdir -p "$state_dir"
    
    for agent_state in "$state_dir"/*.json; do
        if [[ ! -f "$agent_state" ]]; then continue; fi
        
        other_agent=$(basename "$agent_state" .json)
        if [[ "$other_agent" == "$agent_name" ]]; then continue; fi
        
        # Check if other agent is active (within 5 minutes)
        last_update=$(jq -r '.last_update // 0' "$agent_state" 2>/dev/null || echo "0")
        current_time=$(date +%s)
        if (( current_time - last_update > 300 )); then continue; fi
        
        # Check file conflicts
        other_files=$(jq -r '.current_files[]? // empty' "$agent_state" 2>/dev/null || echo "")
        for file in $target_files; do
            if echo "$other_files" | grep -q "$(basename "$file")"; then
                agent_conflicts="$agent_conflicts $other_agent:$file"
            fi
        done
    done
    
    if [[ -n "$agent_conflicts" ]]; then
        log_error "agent_conflict" "blocked" "Agent file conflicts detected: $agent_conflicts"
        exit 1
    else
        log_info "conflict_check" "success" "No conflicts detected (fallback check)"
        exit 0
    fi
fi

# Extract Claude's conflict analysis
conflicts_detected=$(echo "$conflict_analysis" | jq -r '.conflicts_detected // false')
risk_level=$(echo "$conflict_analysis" | jq -r '.risk_level // "low"')
specific_risks=$(echo "$conflict_analysis" | jq -r '.specific_risks[]? // empty' | head -5 | tr '\n' ',' | sed 's/,$//')
safe_to_proceed=$(echo "$conflict_analysis" | jq -r '.safe_to_proceed // true')
reasoning=$(echo "$conflict_analysis" | jq -r '.reasoning // "No reasoning provided"')
recommendations=$(echo "$conflict_analysis" | jq -r '.recommendations[]? // empty' | head -3)

# Log Claude's analysis
log_info "claude_analysis" "completed" "Conflicts: $conflicts_detected, Risk: $risk_level, Safe: $safe_to_proceed"

# Store the conflict analysis for learning
_psql_query "INSERT INTO governance_decisions (timestamp, agent_id, decision_type, decision, reasoning, risk_level, context_data) VALUES (NOW(), '$agent_name', 'conflict_check', '$safe_to_proceed', '$reasoning', '$risk_level', '$conflict_analysis')"

# Apply Claude's decision
if [[ "$safe_to_proceed" == "false" ]]; then
    log_error "claude_conflict_block" "blocked" "Claude blocked due to conflicts: $reasoning"
    echo "CONFLICT DETECTED: $reasoning" >&2
    echo "Risk Level: $risk_level" >&2
    if [[ -n "$specific_risks" ]]; then
        echo "Specific Risks: $specific_risks" >&2
    fi
    if [[ -n "$recommendations" ]]; then
        echo "Recommendations:" >&2
        echo "$recommendations" | sed 's/^/  - /' >&2
    fi
    exit 1
fi

# Conflicts analyzed - store mitigation recommendations
if [[ -n "$recommendations" ]]; then
    echo "$recommendations" > "$CLAUDE_PROJECT_DIR/.claude/context/conflict-mitigation-suggestions.txt"
    log_info "mitigation_stored" "pending" "Conflict mitigation suggestions saved"
fi

# Set conflict context for coordination
state_set "conflict_risk_level" "$risk_level"
state_set "conflict_analysis" "$conflict_analysis"

# Special handling for medium/high risk scenarios
if [[ "$risk_level" == "medium" ]] || [[ "$risk_level" == "high" ]]; then
    log_warning "elevated_risk" "$risk_level" "Proceeding with $risk_level conflict risk: $reasoning"
    # Could add additional monitoring or shortened timeouts here
fi

log_info "conflict_check" "success" "No blocking conflicts detected (Risk: $risk_level)"
exit 0
