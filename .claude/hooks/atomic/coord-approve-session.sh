#!/bin/bash
# COORDINATION: The final hook in a successful pre-tool-use workflow.
set -euo pipefail
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/state.sh"
source "$HOOKS_DIR/lib/data-access.sh"

export HOOK_NAME="atomic/coord-approve-session"
session_id=$(state_get "session_id")
log_info "session_approve" "running" "Approving session $session_id for execution."

if ! update_session_status "$session_id" "approved_for_execution"; then
    log_error "session_approve_fail" "critical" "Failed to update session status in DB."
    exit 1
fi
log_info "session_approve" "success" "Session $session_id unlocked."
exit 0
