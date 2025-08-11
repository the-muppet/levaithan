#!/bin/bash
# orchestrator.sh - The definitive, stateful, production-grade hook orchestrator.
set -euo pipefail
source "$CLAUDE_PROJECT_DIR/.env"

if [ -f "$CLAUDE_PROJECT_DIR/.system-lock" ]; then exit 101; fi

source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/state.sh"

export WORKFLOW_EXECUTION_ID="wfe_$(uuidgen)"

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && $exit_code -ne 101 ]]; then
        local failed_envelope; failed_envelope=$(state_get "initial_envelope")
        if [[ -n "$failed_envelope" ]]; then
            log_critical "workflow_failure" "dlq" "Moving envelope to Dead-Letter Queue."
            redis-cli LPUSH "dlq:envelopes" "$failed_envelope" >/dev/null
        fi
    fi
    log_info "workflow_shutdown" "exit_code_$exit_code" "WFE ID $WORKFLOW_EXECUTION_ID terminating."
    state_destroy
    exit $exit_code
}
trap cleanup EXIT ERR INT TERM

state_init
state_set "initial_envelope" "$(cat)"

PHASE=$(state_get "initial_envelope" | jq -r '.event_type // "unknown"')
log_info "phase_dispatch" "running" "Dispatching to workflow for event: $PHASE"

case "$PHASE" in
    "task_declaration")
        "$HOOKS_DIR/workflows/workflow-pre-tool-use.sh" ;;
    "completion_report")
        "$HOOKS_DIR/workflows/workflow-post-tool-use.sh" ;;
    "self_improvement_cycle")
        "$HOOKS_DIR/workflows/workflow-self-improvement.sh" ;;
    *)
        log_error "unknown_phase" "failed" "No workflow for event: $PHASE"
        exit 1 ;;
esac
