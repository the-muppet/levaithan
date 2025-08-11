#!/bin/bash
# atomic/context-find-similar.sh - Claude-powered context curation

set -euo pipefail

# Set base directory and environment variables
export CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd ../../.. && pwd)}"
export POSTGRES_DSN="${POSTGRES_DSN:-postgresql://user:pass@localhost:5432/claude_db}"
export REDIS_URL="${REDIS_URL:-redis://localhost:6379}"
export HelixDB_HTTP_URL="${HelixDB_HTTP_URL:-http://localhost:7474}"
export HelixDB_AUTH="${HelixDB_AUTH:-HelixDB:password}"
export WEAVIATE_URL="${WEAVIATE_URL:-http://localhost:8080}"
export ELASTICSEARCH_URL="${ELASTICSEARCH_URL:-http://localhost:9200}"
export CLAUDE_LOG_LEVEL="${CLAUDE_LOG_LEVEL:-1}"
export WORKFLOW_EXECUTION_ID="${WORKFLOW_EXECUTION_ID:-$(date +%s)-$$}"

# Source required libraries
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/logging.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/state.sh"  
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/data-access.sh"
source "${CLAUDE_PROJECT_DIR}/.claude/hooks/lib/claude.sh"

export HOOK_NAME="atomic/context-find-similar"

# Get task info from state
agent_name=$(state_get "agent_name")
objective=$(state_get "objective")
target_files_json=$(state_get "target_files_json")

log_info "context_search" "running" "Finding relevant context for agent '$agent_name'"

# Extract keywords and context hints from objective
keywords=$(echo "$objective" | grep -oiE '\b(component|function|method|endpoint|class|service|pattern|authentication|database|api|frontend|backend)\b' | tr '[:upper:]' '[:lower:]' | sort -u | head -10 | tr '\n' ' ')

log_info "keywords_extracted" "success" "Keywords: $keywords"

# 1. Get similar patterns from Weaviate (if available)
similar_patterns=""
if command -v curl >/dev/null 2>&1 && [[ -n "$WEAVIATE_URL" ]]; then
    log_info "weaviate_search" "running" "Searching for similar patterns"
    
    # Query Weaviate for semantically similar patterns
    pattern_query="{\"query\": \"query GetPatterns(\$concepts: [String]) { Get { CodePatterns(nearText: {concepts: \$concepts}, limit: 5) { signature content_snippet use_case value_score } } }\", \"variables\": {\"concepts\": [\"$objective\"]}}"
    
    similar_patterns=$(curl -s -H "Content-Type: application/json" -X POST -d "$pattern_query" "$WEAVIATE_URL/v1/graphql" 2>/dev/null | jq -c '.data.Get.CodePatterns[]?' | head -5 || echo "")
    
    if [[ -n "$similar_patterns" ]]; then
        log_info "weaviate_found" "success" "Found $(echo "$similar_patterns" | wc -l) similar patterns"
    else
        log_warning "weaviate_empty" "degraded" "No similar patterns found in Weaviate"
    fi
else
    log_warning "weaviate_unavailable" "degraded" "Weaviate not available, skipping semantic search"
fi

# 2. Get recent successful solutions from PostgreSQL
recent_solutions=""
similar_objectives=$(_psql_query "SELECT objective, task_id, created_by FROM tasks WHERE status='completed' AND objective ILIKE '%$(echo "$objective" | cut -d' ' -f1)%' ORDER BY updated_at DESC LIMIT 5")

if [[ -n "$similar_objectives" ]]; then
    recent_solutions="Recent successful tasks: $similar_objectives"
    log_info "recent_solutions" "success" "Found $(echo "$similar_objectives" | wc -l) recent similar tasks"
else
    log_info "recent_solutions" "empty" "No recent similar tasks found"
fi

# 3. Get file dependencies from HelixDB (if available)
dependencies=""
target_files=""
if [[ -n "$target_files_json" ]] && [[ "$target_files_json" != "null" ]]; then
    target_files=$(echo "$target_files_json" | jq -r '.[]?' | tr '\n' ' ')
    
    if command -v curl >/dev/null 2>&1 && [[ -n "$HelixDB_HTTP_URL" ]] && [[ -n "$target_files" ]]; then
        log_info "dependency_search" "running" "Finding dependencies for target files"
        
        for file in $target_files; do
            dep_query="{\"query\": \"MATCH (f:File {path:'$file'})-[:DEPENDS_ON]->(d:File) RETURN d.path, d.type LIMIT 10\"}"
            file_deps=$(curl -s -u "$HelixDB_AUTH" -H "Content-Type: application/json" -X POST -d "$dep_query" "$HelixDB_HTTP_URL/db/data/transaction/commit" 2>/dev/null | jq -r '.results[0].data[]?.row | join(":") // empty' | head -5 || echo "")
            
            if [[ -n "$file_deps" ]]; then
                dependencies="$dependencies $file -> [$file_deps]"
            fi
        done
        
        if [[ -n "$dependencies" ]]; then
            log_info "dependencies_found" "success" "Found dependencies for $(echo "$dependencies" | wc -w) files"
        fi
    fi
fi

# 4. Get relevant documentation from context directory
documentation=""
context_dir="$CLAUDE_PROJECT_DIR/.claude/context"
if [[ -d "$context_dir" ]]; then
    # Look for relevant documentation based on keywords
    for keyword in $keywords; do
        relevant_docs=$(find "$context_dir" -name "*${keyword}*" -type f | head -3)
        if [[ -n "$relevant_docs" ]]; then
            for doc in $relevant_docs; do
                doc_content=$(head -10 "$doc" 2>/dev/null | tr '\n' ' ')
                documentation="$documentation $(basename "$doc"): $doc_content"
            done
        fi
    done
    
    # Always include general guidelines if available
    if [[ -f "$context_dir/guidelines.md" ]]; then
        guidelines=$(head -5 "$context_dir/guidelines.md" 2>/dev/null | tr '\n' ' ')
        documentation="$documentation Guidelines: $guidelines"
    fi
fi

# 5. Get effectiveness scores for context types
context_effectiveness=""
effective_contexts=$(_psql_query "SELECT context_source, AVG(effectiveness_score) as avg_score, COUNT(*) as usage_count FROM context_injections WHERE agent_id='$agent_name' AND effectiveness_score IS NOT NULL GROUP BY context_source ORDER BY avg_score DESC LIMIT 5")

if [[ -n "$effective_contexts" ]]; then
    context_effectiveness="Context effectiveness for $agent_name: $effective_contexts"
    log_info "effectiveness_data" "success" "Found effectiveness data for $(echo "$effective_contexts" | wc -l) context types"
fi

log_info "context_data" "collected" "Patterns: $(echo "$similar_patterns" | wc -l), Solutions: $(echo "$similar_objectives" | wc -l), Deps: $(echo "$dependencies" | wc -w)"

# 6. Use Claude to intelligently curate the best context
curated_context=$(claude_curate_context "$objective" "$similar_patterns" "$recent_solutions" "$dependencies $documentation $context_effectiveness")

if [[ $? -ne 0 ]] || [[ -z "$curated_context" ]]; then
    # Fallback to rule-based context selection
    log_warning "claude_fallback" "degraded" "Claude curation failed, using rule-based context selection"
    
    fallback_context=""
    
    # Include recent successful solutions if available
    if [[ -n "$similar_objectives" ]]; then
        fallback_context="$fallback_context\n\nRecent successful similar tasks:\n$similar_objectives"
    fi
    
    # Include top patterns if available
    if [[ -n "$similar_patterns" ]]; then
        top_pattern=$(echo "$similar_patterns" | head -1)
        fallback_context="$fallback_context\n\nRelevant pattern: $top_pattern"
    fi
    
    # Include key dependencies
    if [[ -n "$dependencies" ]]; then
        fallback_context="$fallback_context\n\nFile dependencies: $dependencies"
    fi
    
    # Include relevant keywords context
    if [[ -n "$keywords" ]]; then
        fallback_context="$fallback_context\n\nRelevant concepts: $keywords"
    fi
    
    curated_context="$fallback_context"
    
    if [[ -z "$curated_context" ]]; then
        curated_context="No specific context found for this task. Proceed with standard best practices."
    fi
fi

# Store curated context for injection
state_set "curated_context" "$curated_context"

# Store context sources for effectiveness tracking
context_sources="patterns,solutions,dependencies,documentation"
state_set "context_sources" "$context_sources"

# Log context curation details
context_length=${#curated_context}
log_info "context_curated" "success" "Context curated ($context_length chars) with sources: $context_sources"

# Store context injection record for effectiveness tracking
session_id=$(state_get "session_id")
_psql_query "INSERT INTO context_injections (session_id, context_source, context_data, injected_at) VALUES ('$session_id', 'claude_curated', '$curated_context', NOW())"

log_info "context_find" "success" "Context curation completed for agent '$agent_name'"
exit 0
