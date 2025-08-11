#!/bin/bash
# EVOLUTION: Generates a concrete improvement suggestion from analysis data.
set -euo pipefail
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/state.sh"
source "$HOOKS_DIR/lib/claude.sh"
source "$HOOKS_DIR/lib/data-access.sh"

export HOOK_NAME="atomic/reflect-generate-suggestion"
analysis_input=$(state_get "performance_analysis_json")
charter=$(cat "$CONTEXT_DIR/system-charter.yaml")

log_info "suggestion_start" "running" "Generating improvement from analysis."

claude_prompt="
SYSTEM CHARTER:
$charter

PERFORMANCE ANALYSIS:
$analysis_input

Adhering to the System Charter, analyze the performance data and formulate ONE high-impact, actionable improvement suggestion.
Respond ONLY with a JSON object of the following structure:
{
  \"suggestion_title\": \"<A brief title>\",
  \"suggestion_type\": \"<create_custom_hook | modify_config | optimize_query>\",
  \"justification\": \"<Why this change is important, citing the charter or data.>\",
  \"implementation_details\": {
    \"description\": \"<A description of the code to be written or change to be made>\"
  }
}"

suggestion_json=$(claude_get_response "$claude_prompt")
if [[ -z "$suggestion_json" ]]; then
    log_error "claude_suggestion_failed" "error" "Claude returned no suggestion."
    exit 1
fi

# Store the suggestion in the database with status 'pending'
store_pending_suggestion "$suggestion_json" # New DAL function
log_info "suggestion_generated" "pending_approval" "New suggestion created and is awaiting human review."

exit 0
