#!/bin/bash
# This workflow applies a direct correction from the Human Operator.
set -e
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/state.sh"
source "$HOOKS_DIR/lib/data-access.sh"

export HOOK_NAME="workflow/apply-correction"
log_warning "workflow_start" "running" "--- HUMAN CORRECTION WORKFLOW INITIATED ---"

# --- Get Feedback Details ---
# The scheduler passes the feedback_id to the workflow state
feedback_id=$(state_get "feedback_id")
feedback_json=$(get_human_feedback_details "$feedback_id") # New DAL function
if [[ -z "$feedback_json" ]]; then
    log_error "correction_fail" "critical" "Could not retrieve human feedback for ID: $feedback_id"
    exit 1
fi
state_set "feedback_json" "$feedback_json"

log_info "correction_ingest" "running" "Applying correction: $(echo $feedback_json | jq -r .correction_details.reason)"

# --- Generate and Implement Suggestion ---
# This chain bypasses the normal analysis and goes straight to generating a fix.
# It uses a specialized atomic hook that takes human feedback as its primary input.
"$HOOKS_DIR/atomic/reflect-generate-from-human-feedback.sh"
# The output of the above hook is a suggestion JSON, which we store in the state
state_set "suggestion_json" "$(cat)"

# This hook takes the suggestion and generates the code or config change.
"$HOOKS_DIR/atomic/reflect-implement-suggestion.sh"

# --- Finalize ---
log_info "correction_finalize" "running" "Marking human feedback as addressed."
update_human_feedback_status "$feedback_id" "addressed" # New DAL function

log_warning "workflow_end" "success" "Human correction has been successfully implemented."
exit 0
