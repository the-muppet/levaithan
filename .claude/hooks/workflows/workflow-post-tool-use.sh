#!/bin/bash
# The definitive Post-Tool-Use workflow.
set -e
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/state.sh"

export HOOK_NAME="workflow/post-tool-use"
ATOMIC_HOOKS_DIR="$HOOKS_DIR/atomic"
log_info "workflow_start" "running" "Initiating Post-Tool-Use Knowledge & Cleanup sequence."

# --- PRIMARY CAPABILITIES ---
# This workflow is about learning and cleaning up.
"$ATOMIC_HOOKS_DIR/cost-calculate-and-log.sh"
"$ATOMIC_HOOKS_DIR/knowledge-extract-from-diff.sh"
"$ATOMIC_HOOKS_DIR/context-update-effectiveness.sh"

# --- FINAL CLEANUP ---
# If all previous steps succeeded, this final set of hooks closes the session.
"$ATOMIC_HOOKS_DIR/coord-release-lock.sh"
"$ATOMIC_HOOKS_DIR/coord-close-session.sh"

log_info "workflow_end" "success" "Post-Tool-Use workflow completed successfully."
exit 0
