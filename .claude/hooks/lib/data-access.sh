#!/bin/bash
# lib/data-access.sh - The definitive, functional data access layer.
# All database/API interactions go through this library.

# --- PostgreSQL Functions ---
# Executes a query and returns the raw result.
_psql_query() { psql "$POSTGRES_DSN" -t -A -c "$1"; }

# Creates a task record.
create_task_record() { # task_id, parent_task_id, objective, agent_name
    _psql_query "INSERT INTO tasks (task_id, parent_task_id, objective, created_by, assigned_to, status) VALUES ('$1', NULLIF('$2',''), '$3', '$4', '$4', 'active');" >/dev/null
}

# Updates a session's status.
update_session_status() { # session_id, status
    _psql_query "UPDATE agent_sessions SET status='$2' WHERE session_id='$1';" >/dev/null
}

# Acquires a resource lock atomically. Fails if the lock exists.
create_resource_lock() { # session_id, resource_path
    _psql_query "INSERT INTO resource_locks (session_id, resource_path) VALUES ('$1', '$2');" &>/dev/null
}

# Releases all locks for a given session.
release_all_locks_for_session() { # session_id
    _psql_query "DELETE FROM resource_locks WHERE session_id='$1';" >/dev/null
}

# Stores a generated suggestion.
store_pending_suggestion() { # title, type, justification, details_json
    _psql_query "INSERT INTO improvement_suggestions (title, suggestion_type, justification, implementation_details, status) VALUES ('$1', '$2', '$3', '$4', 'pending');" >/dev/null
}

# --- HelixDB Functions ---
execute_cypher_query() { # cypher_query
    local payload; payload=$(jq -n --arg q "$1" '{"query": $q}')
    curl -s -u "$HelixDB_AUTH" -H "Content-Type: application/json" \
         -X POST -d "$payload" "$HelixDB_HTTP_URL/db/data/transaction/commit"
}

# --- Weaviate Functions ---
get_text_embedding() { # text_string
    curl -s -H "Content-Type: application/json" -X POST -d "{\"text\": \"$1\"}" "$EMBEDDING_MODEL_URL" | jq -c .vector
}

find_similar_patterns_by_objective() { # objective_string
    local vector; vector=$(get_text_embedding "$1")
    local query; query=$(jq -n --argjson v "$vector" \
        '{ "query": "query GetPatterns($vector: [Float]!) { Get { CodePatterns(nearVector: {vector: $vector}, limit: 5) { signature content_snippet } } }", "variables": { "vector": $v } }')
    curl -s -H "Content-Type: application/json" -X POST -d "$query" "$WEAVIATE_URL/v1/graphql" | jq -c '.data.Get.CodePatterns'
}

# --- Elasticsearch Functions ---
log_to_elasticsearch() { # log_json
    # Send structured log to Elasticsearch if available, otherwise write to local log file
    if command -v curl >/dev/null 2>&1 && [[ -n "${ELASTICSEARCH_URL:-}" ]]; then
        curl -s -H "Content-Type: application/json" -X POST "$ELASTICSEARCH_URL/claude_logs/_doc" -d "$1" >/dev/null 2>&1 || true
    else
        # Fallback to local logging
        local logs_dir="$CLAUDE_PROJECT_DIR/.claude/logs"
        mkdir -p "$logs_dir"
        echo "$1" >> "$logs_dir/system.jsonl"
    fi
}

log_to_activity_stream() { # task_id, event_type, details_json
    local doc; doc=$(jq -n --arg task_id "$1" --arg event_type "$2" --argjson details "$3" \
        '{ "task_id": $task_id, "event_type": $event_type, "details": $details, "timestamp": "'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'" }')
    curl -s -H "Content-Type: application/json" -X POST "$ELASTICSEARCH_URL/activity_log/_doc" -d "$doc" >/dev/null
}
