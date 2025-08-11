#!/bin/bash
# This workflow processes a delegation request from an agent.
set -e
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/state.sh"
source "$HOOKS_DIR/lib/data-access.sh" # Assumes DAL is populated with all needed functions

export HOOK_NAME="workflow/process-delegation"
log_info "workflow_start" "running" "Initiating Task Delegation sequence."

# --- Get original task details from Redis state ---
envelope=$(state_get "initial_envelope")
parent_task_id=$(echo "$envelope" | jq -r '.task_id')
parent_session_id=$(echo "$envelope" | jq -r '.session_id')
delegating_agent=$(echo "$envelope" | jq -r '.agent_id')

# --- Log the delegation event ---
log_to_activity_stream "$parent_task_id" "delegation_request" "$(echo "$envelope" | jq -c .payload)"

# --- Iterate through each sub-task in the payload ---
echo "$envelope" | jq -c '.payload.sub_tasks[]' | while read -r sub_task_json; do
    # Store sub-task details in Redis state for the atomic hooks
    state_set "sub_task_json" "$sub_task_json"
    state_set "parent_task_id" "$parent_task_id"
    state_set "delegating_agent" "$delegating_agent"
    
    log_info "sub_task_processing" "running" "Processing sub-task: $(echo $sub_task_json | jq -r .objective)"
    
    # --- Execute Atomic Hooks for each sub-task ---
    "$HOOKS_DIR/atomic/coord-create-subtask.sh"
    # This hook could be extended to run a mini-governance check on the sub-task
done

# --- Finalize Parent Task Status ---
log_info "parent_task_update" "running" "Updating parent task $parent_task_id to 'delegated'."
update_task_status "$parent_task_id" "delegated"
# We also close the original agent's session, as its work is now complete.
update_session_status "$parent_session_id" "completed"
release_all_locks_for_session "$parent_session_id"

log_info "workflow_end" "success" "Delegation workflow completed successfully."
exit 0
