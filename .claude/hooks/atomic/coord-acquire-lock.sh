#!/bin/bash
# COORDINATION: Acquires exclusive resource locks.
set -euo pipefail
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/state.sh"
source "$HOOKS_DIR/lib/data-access.sh"

export HOOK_NAME="atomic/coord-acquire-lock"

session_id=$(state_get "session_id")
target_files=$(state_get "target_files_json" | jq -r '.[]')
if [[ -z "$target_files" ]]; then exit 0; fi

log_info "lock_acquire" "running" "Attempting to acquire locks for session '$session_id'."

for file in $target_files; do
    if ! create_resource_lock "$session_id" "$file"; then
        log_error "lock_conflict" "blocked" "File '$file' is already locked."
        release_all_locks_for_session "$session_id" # Rollback
        exit 1
    fi
done

log_info "lock_acquire" "success" "All required locks acquired."
exit 0
