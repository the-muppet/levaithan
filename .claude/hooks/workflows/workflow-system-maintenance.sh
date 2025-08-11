#!/bin/bash
# This workflow performs routine system maintenance and data optimization.
set -e
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"

export HOOK_NAME="workflow/system-maintenance"
ATOMIC_HOOKS_DIR="$HOOKS_DIR/atomic"
log_info "workflow_start" "running" "--- System Maintenance Cycle Initiated ---"

# --- Execute Maintenance Hooks in Sequence ---
"$ATOMIC_HOOKS_DIR/maint-archive-old-tasks.sh"
"$ATOMIC_HOOKS_DIR/maint-prune-stale-locks.sh"
"$ATOMIC_HOOKS_DIR/maint-reindex-databases.sh"
"$ATOMIC_HOOKS_DIR/maint-summarize-chronicle.sh"

log_info "workflow_end" "success" "System Maintenance Cycle Completed."
exit 0
