#!/bin/bash
# COORDINATION: Releases all resource locks for the current session.
set -euo pipefail
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/state.sh"
source "$HOOKS_DIR/lib/data-access.sh"

export HOOK_NAME="atomic/coord-release-lock"
session_id=$(state_get "session_id")
if [[ -z "$session_id" ]]; then exit 1; fi

log_info "lock_release" "running" "Releasing all locks for session '$session_id'."
release_all_locks_for_session "$session_id"
log_info "lock_release" "success" "Locks released."
exit 0
