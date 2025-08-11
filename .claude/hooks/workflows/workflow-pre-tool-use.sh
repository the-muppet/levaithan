#!/bin/bash
# The definitive Pre-Tool-Use workflow.
set -e # Exit immediately if a command exits with a non-zero status.
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"

export HOOK_NAME="workflow/pre-tool-use"
ATOMIC_HOOKS_DIR="$HOOKS_DIR/atomic"
log_info "workflow_start" "running" "Initiating Pre-Tool-Use Coordination sequence."

# --- GOVERNANCE GATES ---
"$ATOMIC_HOOKS_DIR/governance-check-ethics.sh"
"$ATOMIC_HOOKS_DIR/governance-check-budget.sh" # A mock of a cost check
"$ATOMIC_HOOKS_DIR/governance-check-permissions.sh" # A mock of security check

# --- PRIMARY CAPABILITIES ---
"$ATOMIC_HOOKS_DIR/coord-create-session.sh"
"$ATOMIC_HOOKS_DIR/coord-check-conflict.sh"
"$ATOMIC_HOOKS_DIR/coord-acquire-lock.sh"

# --- CONTEXT INJECTION ---
"$ATOMIC_HOOKS_DIR/context-find-similar.sh"
"$ATOMIC_HOOKS_DIR/context-inject-final.sh"

# --- FINAL APPROVAL ---
# If all previous steps succeeded, this final hook "unlocks" the agent.
"$ATOMIC_HOOKS_DIR/coord-approve-session.sh"

log_info "workflow_end" "success" "Pre-Tool-Use workflow completed successfully."
exit 0
