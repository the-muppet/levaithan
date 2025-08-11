#!/bin/bash
# atomic/knowledge-update-pattern.sh - Claude-powered pattern learning and storage

set -euo pipefail
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/state.sh"  
source "$HOOKS_DIR/lib/data-access.sh"
source "$HOOKS_DIR/lib/claude.sh"

export HOOK_NAME="atomic/knowledge-update-pattern"

# Get completion data from state
session_id=$(state_get "session_id")
task_id=$(state_get "task_id")
agent_name=$(state_get "agent_name")
objective=$(state_get "objective")
envelope=$(state_get "initial_envelope")

log_info "pattern_learning" "running" "Extracting patterns from task completion"

# Extract task status and artifacts
task_status=$(echo "$envelope" | jq -r '.payload.status // "unknown"')
diff_content=$(echo "$envelope" | jq -r '.payload.artifacts.diff // ""')
result_summary=$(echo "$envelope" | jq -r '.payload.result_summary // ""')

# Only learn from successful tasks
if [[ "$task_status" != "success" ]]; then
    log_info "skip_failed" "skipped" "Skipping pattern learning from non-successful task"
    exit 0
fi

# Only proceed if we have meaningful changes
if [[ -z "$diff_content" ]] || [[ "$diff_content" == "null" ]]; then
    log_info "no_diff" "skipped" "No code diff available for pattern extraction"
    exit 0
fi

log_info "analyzing_diff" "running" "Analyzing diff content ($(echo "$diff_content" | wc -c) chars)"

# Use Claude to extract meaningful patterns from the diff
pattern_analysis=$(claude_extract_patterns "$objective" "$diff_content")

if [[ $? -ne 0 ]] || [[ -z "$pattern_analysis" ]]; then
    # Fallback to simple pattern extraction if Claude fails
    log_warning "claude_fallback" "degraded" "Claude extraction failed, using regex-based pattern detection"
    
    # Simple regex-based pattern detection (from elmoai pattern)
    new_functions=$(echo "$diff_content" | grep "^+.*function\|^+.*def \|^+.*const.*=" | head -10)
    new_classes=$(echo "$diff_content" | grep "^+.*class \|^+.*interface \|^+.*type " | head -5)
    
    if [[ -n "$new_functions" ]] || [[ -n "$new_classes" ]]; then
        # Create simple pattern entries
        echo "$new_functions" | while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                signature=$(echo "$line" | sed 's/^\+//' | tr -s ' ' | sha256sum | awk '{print $1}')
                content=$(echo "$line" | sed 's/^\+//' | head -c 200)
                
                # Store basic pattern in database
                _psql_query "INSERT INTO patterns (pattern_signature, pattern_type, pattern_content, agent_id, task_id, created_at) VALUES ('$signature', 'function', '$content', '$agent_name', '$task_id', NOW()) ON CONFLICT (pattern_signature) DO UPDATE SET usage_count = patterns.usage_count + 1, last_seen = NOW()"
                
                log_info "pattern_stored" "success" "Basic pattern stored: $signature"
            fi
        done
    else
        log_info "no_patterns" "skipped" "No recognizable patterns found in diff"
        exit 0
    fi
    
    exit 0
fi

# Process Claude's pattern analysis
patterns_count=$(echo "$pattern_analysis" | jq '.patterns | length')
log_info "claude_patterns" "extracted" "Claude identified $patterns_count patterns"

# Store each pattern identified by Claude
echo "$pattern_analysis" | jq -c '.patterns[]?' | while IFS= read -r pattern; do
    if [[ -z "$pattern" ]]; then continue; fi
    
    pattern_name=$(echo "$pattern" | jq -r '.name // "unnamed"')
    pattern_type=$(echo "$pattern" | jq -r '.type // "unknown"')
    code_snippet=$(echo "$pattern" | jq -r '.code_snippet // ""')
    use_case=$(echo "$pattern" | jq -r '.use_case // ""')
    value_score=$(echo "$pattern" | jq -r '.value_score // 0.5')
    reusability=$(echo "$pattern" | jq -r '.reusability // "medium"')
    
    # Generate signature for deduplication
    pattern_signature=$(echo "$pattern_name$code_snippet" | sha256sum | awk '{print $1}')
    
    log_info "storing_pattern" "running" "Storing pattern: $pattern_name ($pattern_type)"
    
    # Store in PostgreSQL patterns table
    insert_result=$(_psql_query "
        INSERT INTO patterns (pattern_signature, pattern_type, pattern_content, pattern_name, use_case, value_score, agent_id, task_id, created_at) 
        VALUES ('$pattern_signature', '$pattern_type', '$code_snippet', '$pattern_name', '$use_case', $value_score, '$agent_name', '$task_id', NOW()) 
        ON CONFLICT (pattern_signature) DO UPDATE SET 
            usage_count = patterns.usage_count + 1,
            last_seen = NOW(),
            value_score = (patterns.value_score + $value_score) / 2
    ")
    
    if [[ $? -eq 0 ]]; then
        log_info "pattern_stored" "success" "Pattern stored in database: $pattern_name"
    else
        log_error "pattern_storage_failed" "error" "Failed to store pattern: $pattern_name"
        continue
    fi
    
    # Store in Weaviate for semantic search (if available)
    if command -v curl >/dev/null 2>&1 && [[ -n "$WEAVIATE_URL" ]]; then
        # Generate text for embedding
        pattern_text="$pattern_name $use_case $code_snippet"
        
        weaviate_object=$(cat << EOF
{
  "class": "CodePattern",
  "properties": {
    "signature": "$pattern_signature",
    "content_snippet": "$code_snippet",
    "use_case": "$use_case",
    "value_score": $value_score,
    "created_at": "$(date -Iseconds)",
    "agent_id": "$agent_name",
    "pattern_name": "$pattern_name",
    "reusability": "$reusability"
  }
}
EOF
        )
        
        weaviate_result=$(curl -s -H "Content-Type: application/json" -X POST -d "$weaviate_object" "$WEAVIATE_URL/v1/objects" 2>/dev/null)
        
        if [[ $? -eq 0 ]] && echo "$weaviate_result" | jq -e '.id' >/dev/null; then
            log_info "weaviate_stored" "success" "Pattern stored in Weaviate for semantic search"
        else
            log_warning "weaviate_failed" "degraded" "Failed to store pattern in Weaviate"
        fi
    fi
    
    # Create relationship in HelixDB (if available)
    if command -v curl >/dev/null 2>&1 && [[ -n "$HelixDB_HTTP_URL" ]]; then
        HelixDB_query="{\"query\": \"MERGE (p:Pattern {signature:'$pattern_signature', name:'$pattern_name', type:'$pattern_type'}) MERGE (a:Agent {id:'$agent_name'}) MERGE (t:Task {id:'$task_id'}) MERGE (a)-[:DISCOVERED]->(p) MERGE (p)-[:EXTRACTED_FROM]->(t) RETURN p\"}"
        
        HelixDB_result=$(curl -s -u "$HelixDB_AUTH" -H "Content-Type: application/json" -X POST -d "$HelixDB_query" "$HelixDB_HTTP_URL/db/data/transaction/commit" 2>/dev/null)
        
        if [[ $? -eq 0 ]]; then
            log_info "HelixDB_stored" "success" "Pattern relationships stored in HelixDB"
        else
            log_warning "HelixDB_failed" "degraded" "Failed to store pattern relationships in HelixDB"
        fi
    fi
done

# Update agent learning statistics
agent_patterns_count=$(_psql_query "SELECT COUNT(*) FROM patterns WHERE agent_id = '$agent_name'")
log_info "agent_learning" "updated" "Agent '$agent_name' has discovered $agent_patterns_count total patterns"

# Store pattern learning event
_psql_query "INSERT INTO chronicle_events (event_type, event_title, event_description, metadata, significance_level) VALUES ('pattern_learning', 'Patterns Extracted', 'Agent $agent_name extracted $patterns_count patterns from task completion', '{\"agent_id\": \"$agent_name\", \"task_id\": \"$task_id\", \"patterns_count\": $patterns_count}', 7)"

# Identify emerging high-value patterns
high_value_patterns=$(_psql_query "
    SELECT pattern_name, pattern_type, AVG(value_score) as avg_score, COUNT(*) as occurrences
    FROM patterns 
    WHERE value_score > 0.7 
    AND created_at > NOW() - INTERVAL '7 days'
    GROUP BY pattern_name, pattern_type
    HAVING COUNT(*) >= 2
    ORDER BY avg_score DESC, occurrences DESC
    LIMIT 5
")

if [[ -n "$high_value_patterns" ]]; then
    log_info "high_value_patterns" "identified" "Found $(echo "$high_value_patterns" | wc -l) high-value emerging patterns"
    
    # Store for evolution analysis
    echo "# High-Value Patterns Report" > "$CLAUDE_PROJECT_DIR/.claude/context/high-value-patterns.md"
    echo "Generated: $(date -Iseconds)" >> "$CLAUDE_PROJECT_DIR/.claude/context/high-value-patterns.md"
    echo "" >> "$CLAUDE_PROJECT_DIR/.claude/context/high-value-patterns.md"
    echo "$high_value_patterns" >> "$CLAUDE_PROJECT_DIR/.claude/context/high-value-patterns.md"
fi

# Check if we should trigger pattern review
total_patterns=$(_psql_query "SELECT COUNT(*) FROM patterns")
unreviewed_patterns=$(_psql_query "SELECT COUNT(*) FROM patterns WHERE reviewed = FALSE OR reviewed IS NULL")

if [[ $unreviewed_patterns -gt 20 ]] && [[ $((unreviewed_patterns * 100 / total_patterns)) -gt 30 ]]; then
    log_warning "pattern_review_needed" "optimization" "Many unreviewed patterns detected: $unreviewed_patterns/$total_patterns"
    echo "PATTERN_REVIEW_NEEDED|$unreviewed_patterns|$total_patterns" >> "$CLAUDE_PROJECT_DIR/.claude/logs/optimization-triggers.log"
fi

log_info "pattern_learning" "success" "Pattern learning completed: $patterns_count patterns processed"
exit 0
