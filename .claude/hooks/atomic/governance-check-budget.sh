#!/bin/bash
# GOVERNANCE: Check if an action would exceed budget limits
# Validates that the requested action is within the agent's daily spending limits
# and checks for any budget constraints based on action type and estimated cost.

set -euo pipefail

# Source required environment and libraries
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/data-access.sh"
source "$HOOKS_DIR/lib/validation.sh"
source "$HOOKS_DIR/lib/error-handling.sh"

export HOOK_NAME="atomic/governance-check-budget"

# Enable error trapping for proper cleanup
enable_error_trap

log_info "budget_check" "running" "Executing Budget Governance Check"

# Read and validate InteractionEnvelope from stdin
INTERACTION_ENVELOPE=""
if ! read -r INTERACTION_ENVELOPE; then
    log_error "budget_check" "failed" "No input received from stdin"
    exit 1
fi

# Validate the interaction envelope structure
if ! validate_interaction_envelope "$INTERACTION_ENVELOPE"; then
    log_error "budget_check" "failed" "Invalid InteractionEnvelope format"
    exit 1
fi

# Extract key information from envelope
agent_id=$(echo "$INTERACTION_ENVELOPE" | jq -r '.agent_id')
event_type=$(echo "$INTERACTION_ENVELOPE" | jq -r '.event_type')
payload=$(echo "$INTERACTION_ENVELOPE" | jq '.payload')

# Extract budget-relevant information from payload
estimated_cost_usd=0
action_type="general"

case "$event_type" in
    "task_declaration")
        # For task declarations, estimate cost based on objective complexity
        objective=$(echo "$payload" | jq -r '.objective // ""')
        target_files=$(echo "$payload" | jq -r '.target_files // [] | length')
        
        # Simple cost estimation (in real implementation, this would use ML model)
        objective_length=${#objective}
        base_cost=$(echo "scale=4; $objective_length * 0.001 + $target_files * 0.01" | bc -l)
        estimated_cost_usd=${base_cost:-0.01}
        action_type="task_execution"
        ;;
    "activity_report")
        # Activity reports typically have minimal cost
        estimated_cost_usd=0.001
        action_type="reporting"
        ;;
    "completion_report")
        # Completion reports may trigger analysis/learning
        estimated_cost_usd=0.005
        action_type="completion_analysis"
        ;;
    *)
        # Default minimal cost for unknown event types
        estimated_cost_usd=0.002
        action_type="unknown"
        ;;
esac

log_info "budget_check" "cost_estimate" "Estimated cost: \$${estimated_cost_usd} for action_type: ${action_type}"

# Get current date for daily budget tracking
current_date=$(date +%Y-%m-%d)

# Query current daily spending for this agent
daily_spent_query="SELECT COALESCE(SUM(total_cost_usd), 0) FROM cost_records 
                   WHERE agent_id = '$agent_id' 
                   AND DATE(created_at) = '$current_date';"

current_daily_spent=$(psql "$POSTGRES_DSN" -t -A -c "$daily_spent_query" 2>/dev/null || echo "0")

# Get agent-specific daily budget limit (fallback to default)
agent_budget_query="SELECT daily_budget_usd FROM agent_budgets 
                    WHERE agent_id = '$agent_id' 
                    AND is_active = true 
                    ORDER BY created_at DESC LIMIT 1;"

agent_daily_budget=$(psql "$POSTGRES_DSN" -t -A -c "$agent_budget_query" 2>/dev/null || echo "")

# Use default budget if no agent-specific budget found
if [[ -z "$agent_daily_budget" ]] || [[ "$agent_daily_budget" == "" ]]; then
    agent_daily_budget="${DEFAULT_DAILY_BUDGET_USD:-10.00}"
fi

log_info "budget_check" "budget_status" "Agent $agent_id daily budget: \$${agent_daily_budget}, spent: \$${current_daily_spent}"

# Calculate projected total after this action
projected_total=$(echo "scale=6; $current_daily_spent + $estimated_cost_usd" | bc -l)

# Check if projected total would exceed budget
if (( $(echo "$projected_total > $agent_daily_budget" | bc -l) )); then
    log_error "budget_check" "budget_exceeded" "Budget check failed: projected spend \$${projected_total} exceeds daily limit \$${agent_daily_budget}"
    
    # Record the budget violation for monitoring
    violation_record="INSERT INTO budget_violations 
                     (agent_id, violation_date, requested_amount, daily_limit, current_spent, event_type, action_type)
                     VALUES ('$agent_id', '$current_date', $estimated_cost_usd, $agent_daily_budget, $current_daily_spent, '$event_type', '$action_type');"
    
    _psql_query "$violation_record" || log_warning "budget_check" "violation_record_failed" "Failed to record budget violation"
    
    exit 1
fi

# Check for cost alert threshold
cost_alert_threshold="${COST_ALERT_THRESHOLD_USD:-8.00}"
if (( $(echo "$projected_total > $cost_alert_threshold" | bc -l) )); then
    log_warning "budget_check" "cost_alert" "Projected spend \$${projected_total} exceeds alert threshold \$${cost_alert_threshold}"
    
    # Record cost alert (but don't block the action)
    alert_record="INSERT INTO cost_alerts 
                  (agent_id, alert_date, projected_amount, alert_threshold, event_type, action_type, status)
                  VALUES ('$agent_id', NOW(), $projected_total, $cost_alert_threshold, '$event_type', '$action_type', 'triggered');"
    
    _psql_query "$alert_record" || log_warning "budget_check" "alert_record_failed" "Failed to record cost alert"
fi

# Check for action-specific budget limits (if configured)
action_budget_query="SELECT daily_limit_usd FROM action_budget_limits 
                     WHERE action_type = '$action_type' 
                     AND is_active = true;"

action_daily_limit=$(psql "$POSTGRES_DSN" -t -A -c "$action_budget_query" 2>/dev/null || echo "")

if [[ -n "$action_daily_limit" ]] && [[ "$action_daily_limit" != "" ]]; then
    # Query current daily spending for this action type
    action_spent_query="SELECT COALESCE(SUM(total_cost_usd), 0) FROM cost_records 
                        WHERE agent_id = '$agent_id' 
                        AND action_type = '$action_type'
                        AND DATE(created_at) = '$current_date';"
    
    current_action_spent=$(psql "$POSTGRES_DSN" -t -A -c "$action_spent_query" 2>/dev/null || echo "0")
    projected_action_total=$(echo "scale=6; $current_action_spent + $estimated_cost_usd" | bc -l)
    
    if (( $(echo "$projected_action_total > $action_daily_limit" | bc -l) )); then
        log_error "budget_check" "action_budget_exceeded" "Action-specific budget exceeded: $action_type projected \$${projected_action_total} > limit \$${action_daily_limit}"
        exit 1
    fi
fi

# Store estimated cost in workflow state for downstream hooks
if command -v state_set >/dev/null 2>&1 && [[ -n "${WORKFLOW_EXECUTION_ID:-}" ]]; then
    state_set "estimated_cost_usd" "$estimated_cost_usd"
    state_set "action_type" "$action_type"
fi

# All budget checks passed
log_info "budget_check" "success" "Budget check passed: projected spend \$${projected_total} within limit \$${agent_daily_budget}"
exit 0