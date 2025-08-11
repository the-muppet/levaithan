#!/bin/bash
# COORDINATION: Closes the agent session and task in the database.
set -euo pipefail
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/state.sh"
source "$HOOKS_DIR/lib/data-access.sh"

export HOOK_NAME="atomic/coord-close-session"
session_id=$(state_get "session_id")
task_id=$(state_get "task_id")
final_status=$(state_get "initial_envelope" | jq -r '.payload.status')

log_info "session_close" "running" "Closing session '$session_id' with status '$final_status'."
update_session_status "$session_id" "$final_status"
update_task_status "$task_id" "$final_status" # New DAL function
log_info "session_close" "success" "Session and task closed."
exit 0
