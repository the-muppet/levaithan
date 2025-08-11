#!/bin/bash
# GOVERNANCE: Calculates and logs the cost of the last AI interaction.
set -euo pipefail
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/state.sh"
source "$HOOKS_DIR/lib/data-access.sh"

export HOOK_NAME="atomic/cost-calculate-and-log"

INPUT_TOKENS=${CLAUDE_INPUT_TOKENS:-$(state_get "initial_envelope" | jq -r '(.payload.prompt | length) / 4')_}
OUTPUT_TOKENS=${CLAUDE_OUTPUT_TOKENS:-$(state_get "initial_envelope" | jq -r '(.payload.result | length) / 4')_}
MODEL_USED=${CLAUDE_MODEL:-"claude-3-haiku-20240307"}

INPUT_RATE="0.25"
OUTPUT_RATE="1.25"

input_cost=$(echo "scale=8; $INPUT_TOKENS * $INPUT_RATE / 1000000" | bc)
output_cost=$(echo "scale=8; $OUTPUT_TOKENS * $OUTPUT_RATE / 1000000" | bc)
total_cost=$(echo "scale=8; $input_cost + $output_cost" | bc)

log_info "cost_log" "success" "Logged cost of \$$total_cost for interaction."
# DAL function to insert into cost_records table
log_cost_record "$(state_get session_id)" "$MODEL_USED" "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$total_cost"
exit 0
