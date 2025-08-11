#!/bin/bash
# tools/budget-manager.sh - Financial controls and cost tracking interface for LevAIthan
# Comprehensive budget management, cost analysis, and financial control system

set -e

# Load environment and libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
export CLAUDE_PROJECT_DIR="$PROJECT_ROOT"

# Source environment
if [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a; source "$PROJECT_ROOT/.env"; set +a
else
    echo "ERROR: .env file not found. Please copy .env.template to .env and configure." >&2
    exit 1
fi

# Source libraries
source "$PROJECT_ROOT/.claude/hooks/lib/logging.sh"
source "$PROJECT_ROOT/.claude/hooks/lib/data-access.sh"

# Configuration
readonly PROGRAM_NAME="budget-manager"
readonly VERSION="1.0.0"
readonly DEFAULT_CURRENCY="USD"
readonly COST_ALERT_THRESHOLD="${COST_ALERT_THRESHOLD_USD:-8.00}"
readonly DEFAULT_DAILY_BUDGET="${DEFAULT_DAILY_BUDGET_USD:-10.00}"

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# Alert levels
readonly ALERT_LOW="${GREEN}LOW${NC}"
readonly ALERT_MEDIUM="${YELLOW}MEDIUM${NC}"
readonly ALERT_HIGH="${RED}HIGH${NC}"
readonly ALERT_CRITICAL="${RED}${BOLD}CRITICAL${NC}"

# Helper functions
print_header() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${CYAN}ℹ $1${NC}"; }

format_currency() {
    local amount="$1"
    if [[ -z "$amount" || "$amount" == "null" ]]; then
        echo "\$0.00"
    else
        printf "\$%.2f" "$amount"
    fi
}

format_precise_currency() {
    local amount="$1"
    if [[ -z "$amount" || "$amount" == "null" ]]; then
        echo "\$0.0000"
    else
        printf "\$%.4f" "$amount"
    fi
}

get_alert_level() {
    local spent="$1"
    local budget="$2"
    
    if [[ -z "$spent" || -z "$budget" || "$budget" == "0" ]]; then
        echo "$ALERT_LOW"
        return
    fi
    
    local percentage=$(echo "scale=2; $spent * 100 / $budget" | bc -l 2>/dev/null || echo "0")
    
    if (( $(echo "$percentage >= 100" | bc -l) )); then
        echo "$ALERT_CRITICAL"
    elif (( $(echo "$percentage >= 80" | bc -l) )); then
        echo "$ALERT_HIGH"
    elif (( $(echo "$percentage >= 60" | bc -l) )); then
        echo "$ALERT_MEDIUM"
    else
        echo "$ALERT_LOW"
    fi
}

calculate_burn_rate() {
    local spent="$1"
    local days="$2"
    
    if [[ -z "$spent" || -z "$days" || "$days" == "0" ]]; then
        echo "0.00"
        return
    fi
    
    echo "scale=2; $spent / $days" | bc -l 2>/dev/null || echo "0.00"
}

# Usage information
show_usage() {
    cat << EOF
${PROGRAM_NAME} v${VERSION} - LevAIthan Budget Manager

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    Budget Management:
        budget show [agent_id]              Show budget status
        budget set <agent_id> <amount> [type] [period_start]
        budget delete <agent_id> [type]     Delete budget allocation
        budget list [type]                  List all budget allocations
        budget auto-create                  Create default budgets for all agents

    Cost Analysis:
        cost summary [days]                 Cost summary for period
        cost by-agent [days]               Costs grouped by agent
        cost by-model [days]               Costs grouped by model
        cost by-task [days]                Costs grouped by task
        cost daily [days]                  Daily cost breakdown
        cost hourly [hours]                Hourly cost breakdown
        cost efficiency                    Cost efficiency analysis

    Alerts & Monitoring:
        alert status                       Show current budget alerts
        alert check [agent_id]             Check specific agent's budget
        alert history [days]               Show alert history
        alert configure <agent_id> <threshold_percent>
        
    Financial Controls:
        control status                     Show all financial controls
        control set-limit <agent_id> <limit> [period]
        control freeze <agent_id>          Freeze agent spending
        control unfreeze <agent_id>        Unfreeze agent spending
        control emergency-stop             Emergency stop all spending

    Reporting:
        report monthly [month] [year]      Monthly financial report
        report weekly [week_offset]        Weekly financial report
        report agent <agent_id> [days]     Agent-specific report
        report export [format] [days]      Export financial data
        report forecast [days]             Budget forecast analysis

    Optimization:
        optimize usage [days]              Usage optimization suggestions
        optimize models                    Model cost optimization analysis
        optimize agents                    Agent efficiency analysis
        optimize identify-waste [threshold]

OPTIONS:
    -h, --help                Show this help message
    -f, --format FORMAT       Output format (table/json/csv)
    -q, --quiet               Suppress non-essential output
    -v, --verbose             Enable verbose output
    --currency CURRENCY       Currency code (default: USD)
    --no-color                Disable colored output

EXAMPLES:
    $0 budget show                        # Show all budget status
    $0 budget set agent-1 15.00 daily
    $0 cost by-agent 7                    # Last 7 days by agent
    $0 alert check agent-1                # Check agent-1 budget status
    $0 report monthly                     # Current month report
    $0 optimize usage 30                  # 30-day optimization analysis

EOF
}

# Budget management functions
show_budget_status() {
    local agent_filter="$1"
    local format="${FORMAT:-table}"
    
    print_header "Budget Status Overview"
    
    local where_clause=""
    if [[ -n "$agent_filter" ]]; then
        where_clause="WHERE ba.agent_id = '$agent_filter'"
    fi
    
    case "$format" in
        json)
            local query="
                SELECT json_agg(
                    json_build_object(
                        'agent_id', ba.agent_id,
                        'budget_type', ba.budget_type,
                        'budget_amount', ba.amount_usd,
                        'period_start', ba.period_start,
                        'period_end', ba.period_end,
                        'spent_amount', COALESCE(spending.total_spent, 0),
                        'remaining_amount', ba.amount_usd - COALESCE(spending.total_spent, 0),
                        'utilization_percent', ROUND((COALESCE(spending.total_spent, 0) * 100.0 / ba.amount_usd), 2)
                    )
                ) FROM budget_allocations ba
                LEFT JOIN (
                    SELECT s.agent_id, SUM(cr.total_cost_usd) as total_spent
                    FROM cost_records cr
                    JOIN agent_sessions s ON cr.session_id = s.session_id
                    WHERE cr.recorded_at >= CURRENT_DATE
                    GROUP BY s.agent_id
                ) spending ON ba.agent_id = spending.agent_id
                $where_clause
            "
            _psql_query "$query" | jq .
            ;;
        csv)
            echo "agent_id,budget_type,budget_amount,spent_amount,remaining_amount,utilization_percent,period_start,period_end,alert_level"
            local query="
                SELECT ba.agent_id, ba.budget_type, ba.amount_usd, 
                       COALESCE(spending.total_spent, 0),
                       ba.amount_usd - COALESCE(spending.total_spent, 0),
                       ROUND((COALESCE(spending.total_spent, 0) * 100.0 / ba.amount_usd), 2),
                       ba.period_start, ba.period_end,
                       CASE 
                           WHEN COALESCE(spending.total_spent, 0) >= ba.amount_usd THEN 'CRITICAL'
                           WHEN COALESCE(spending.total_spent, 0) >= ba.amount_usd * 0.8 THEN 'HIGH'
                           WHEN COALESCE(spending.total_spent, 0) >= ba.amount_usd * 0.6 THEN 'MEDIUM'
                           ELSE 'LOW'
                       END
                FROM budget_allocations ba
                LEFT JOIN (
                    SELECT s.agent_id, SUM(cr.total_cost_usd) as total_spent
                    FROM cost_records cr
                    JOIN agent_sessions s ON cr.session_id = s.session_id
                    WHERE cr.recorded_at >= ba.period_start AND cr.recorded_at <= ba.period_end + INTERVAL '1 day'
                    GROUP BY s.agent_id
                ) spending ON ba.agent_id = spending.agent_id
                $where_clause
                ORDER BY ba.agent_id, ba.budget_type
            "
            _psql_query "$query" | sed 's/|/,/g'
            ;;
        *)
            printf "%-15s %-8s %-10s %-10s %-10s %-6s %-8s %-12s %-12s\n" "AGENT_ID" "TYPE" "BUDGET" "SPENT" "REMAINING" "USED%" "ALERT" "PERIOD_START" "PERIOD_END"
            echo "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
            
            local query="
                SELECT ba.agent_id, ba.budget_type, ba.amount_usd, 
                       COALESCE(spending.total_spent, 0) as spent,
                       ba.amount_usd - COALESCE(spending.total_spent, 0) as remaining,
                       ROUND((COALESCE(spending.total_spent, 0) * 100.0 / ba.amount_usd), 1) as utilization,
                       ba.period_start, ba.period_end
                FROM budget_allocations ba
                LEFT JOIN (
                    SELECT s.agent_id, SUM(cr.total_cost_usd) as total_spent
                    FROM cost_records cr
                    JOIN agent_sessions s ON cr.session_id = s.session_id
                    WHERE cr.recorded_at >= ba.period_start AND cr.recorded_at <= ba.period_end + INTERVAL '1 day'
                    GROUP BY s.agent_id
                ) spending ON ba.agent_id = spending.agent_id
                $where_clause
                ORDER BY ba.agent_id, ba.budget_type
            "
            
            _psql_query "$query" | while IFS='|' read -r agent_id budget_type budget_amount spent remaining utilization period_start period_end; do
                if [[ -n "$agent_id" ]]; then
                    local alert_level=$(get_alert_level "$spent" "$budget_amount")
                    local budget_fmt=$(format_currency "$budget_amount")
                    local spent_fmt=$(format_currency "$spent")
                    local remaining_fmt=$(format_currency "$remaining")
                    
                    printf "%-15s %-8s %-10s %-10s %-10s %-5s%% %s %-12s %-12s\n" \
                           "$agent_id" "$budget_type" "$budget_fmt" "$spent_fmt" "$remaining_fmt" \
                           "$utilization" "$alert_level" "$period_start" "$period_end"
                fi
            done
            ;;
    esac
    
    # Show summary statistics
    if [[ "$format" == "table" ]]; then
        echo ""
        local total_budget=$(_psql_query "SELECT COALESCE(SUM(amount_usd), 0) FROM budget_allocations WHERE budget_type = 'daily' AND period_start = CURRENT_DATE;")
        local total_spent=$(_psql_query "SELECT COALESCE(SUM(cr.total_cost_usd), 0) FROM cost_records cr JOIN agent_sessions s ON cr.session_id = s.session_id WHERE DATE(cr.recorded_at) = CURRENT_DATE;")
        local agents_over_budget=$(_psql_query "SELECT COUNT(*) FROM budget_allocations ba LEFT JOIN (SELECT s.agent_id, SUM(cr.total_cost_usd) as spent FROM cost_records cr JOIN agent_sessions s ON cr.session_id = s.session_id WHERE DATE(cr.recorded_at) = CURRENT_DATE GROUP BY s.agent_id) spending ON ba.agent_id = spending.agent_id WHERE ba.budget_type = 'daily' AND ba.period_start = CURRENT_DATE AND COALESCE(spending.spent, 0) > ba.amount_usd;")
        
        echo -e "Summary for today:"
        echo -e "  Total daily budget: $(format_currency "$total_budget")"
        echo -e "  Total spent today: $(format_currency "$total_spent")"
        echo -e "  Budget utilization: $(echo "scale=1; $total_spent * 100 / $total_budget" | bc -l 2>/dev/null || echo "0")%"
        echo -e "  Agents over budget: $agents_over_budget"
    fi
}

set_budget() {
    local agent_id="$1"
    local amount="$2"
    local budget_type="${3:-daily}"
    local period_start="$4"
    
    if [[ -z "$agent_id" || -z "$amount" ]]; then
        print_error "Agent ID and amount are required"
        return 1
    fi
    
    # Validate budget type
    if [[ ! "$budget_type" =~ ^(daily|weekly|monthly)$ ]]; then
        print_error "Budget type must be daily, weekly, or monthly"
        return 1
    fi
    
    # Validate amount
    if ! [[ "$amount" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        print_error "Amount must be a valid number"
        return 1
    fi
    
    # Calculate period dates if not provided
    local period_end
    if [[ -z "$period_start" ]]; then
        case "$budget_type" in
            daily)
                period_start=$(date +%Y-%m-%d)
                period_end=$(date +%Y-%m-%d)
                ;;
            weekly)
                period_start=$(date -d 'last monday' +%Y-%m-%d)
                period_end=$(date -d 'next sunday' +%Y-%m-%d)
                ;;
            monthly)
                period_start=$(date +%Y-%m-01)
                period_end=$(date -d "$(date +%Y-%m-01) + 1 month - 1 day" +%Y-%m-%d)
                ;;
        esac
    else
        case "$budget_type" in
            daily)
                period_end="$period_start"
                ;;
            weekly)
                period_end=$(date -d "$period_start + 6 days" +%Y-%m-%d)
                ;;
            monthly)
                period_end=$(date -d "$period_start + 1 month - 1 day" +%Y-%m-%d)
                ;;
        esac
    fi
    
    print_info "Setting $budget_type budget for $agent_id: $(format_currency "$amount") ($period_start to $period_end)"
    
    local query="INSERT INTO budget_allocations (agent_id, budget_type, amount_usd, period_start, period_end) 
                 VALUES ('$agent_id', '$budget_type', $amount, '$period_start', '$period_end') 
                 ON CONFLICT (agent_id, budget_type, period_start) 
                 DO UPDATE SET amount_usd = $amount, period_end = '$period_end';"
    
    if _psql_query "$query" >/dev/null; then
        print_success "Budget updated successfully"
        
        # Log the budget change
        log_info "budget_set" "success" "Set $budget_type budget for $agent_id: $(format_currency "$amount")"
    else
        print_error "Failed to update budget"
        return 1
    fi
}

# Cost analysis functions
show_cost_summary() {
    local days="${1:-7}"
    local format="${FORMAT:-table}"
    
    print_header "Cost Summary (Last $days days)"
    
    local start_date=$(date -d "$days days ago" +%Y-%m-%d)
    
    case "$format" in
        json)
            local query="
                SELECT json_build_object(
                    'period', '$days days',
                    'start_date', '$start_date',
                    'end_date', CURRENT_DATE,
                    'total_cost', COALESCE(SUM(total_cost_usd), 0),
                    'total_sessions', COUNT(DISTINCT session_id),
                    'total_agents', COUNT(DISTINCT s.agent_id),
                    'total_tasks', COUNT(DISTINCT s.task_id),
                    'total_tokens_in', COALESCE(SUM(input_tokens), 0),
                    'total_tokens_out', COALESCE(SUM(output_tokens), 0),
                    'avg_cost_per_session', COALESCE(AVG(total_cost_usd), 0),
                    'models_used', COUNT(DISTINCT model_used)
                ) FROM cost_records cr
                JOIN agent_sessions s ON cr.session_id = s.session_id
                WHERE cr.recorded_at >= '$start_date'
            "
            _psql_query "$query" | jq .
            ;;
        csv)
            echo "date,total_cost,sessions,unique_agents,total_tokens_in,total_tokens_out,avg_cost_per_session"
            local query="
                SELECT DATE(cr.recorded_at),
                       SUM(cr.total_cost_usd),
                       COUNT(DISTINCT cr.session_id),
                       COUNT(DISTINCT s.agent_id),
                       SUM(cr.input_tokens),
                       SUM(cr.output_tokens),
                       AVG(cr.total_cost_usd)
                FROM cost_records cr
                JOIN agent_sessions s ON cr.session_id = s.session_id
                WHERE cr.recorded_at >= '$start_date'
                GROUP BY DATE(cr.recorded_at)
                ORDER BY DATE(cr.recorded_at) DESC
            "
            _psql_query "$query" | sed 's/|/,/g'
            ;;
        *)
            # Overall summary
            local summary_query="
                SELECT COALESCE(SUM(cr.total_cost_usd), 0) as total_cost,
                       COUNT(DISTINCT cr.session_id) as sessions,
                       COUNT(DISTINCT s.agent_id) as agents,
                       COUNT(DISTINCT s.task_id) as tasks,
                       COALESCE(SUM(cr.input_tokens), 0) as tokens_in,
                       COALESCE(SUM(cr.output_tokens), 0) as tokens_out,
                       COALESCE(AVG(cr.total_cost_usd), 0) as avg_session_cost,
                       COUNT(DISTINCT cr.model_used) as models
                FROM cost_records cr
                JOIN agent_sessions s ON cr.session_id = s.session_id
                WHERE cr.recorded_at >= '$start_date'
            "
            
            local summary_data=$(_psql_query "$summary_query")
            IFS='|' read -r total_cost sessions agents tasks tokens_in tokens_out avg_cost models <<< "$summary_data"
            
            echo -e "Period: $start_date to $(date +%Y-%m-%d) ($days days)"
            echo -e "Total Cost: $(format_currency "$total_cost")"
            echo -e "Sessions: $sessions | Agents: $agents | Tasks: $tasks | Models: $models"
            echo -e "Tokens: $(printf "%'d" "$tokens_in") in, $(printf "%'d" "$tokens_out") out"
            echo -e "Average cost per session: $(format_precise_currency "$avg_cost")"
            
            local burn_rate=$(calculate_burn_rate "$total_cost" "$days")
            echo -e "Daily burn rate: $(format_currency "$burn_rate")"
            
            # Daily breakdown
            echo -e "\nDaily Breakdown:"
            printf "%-12s %-10s %-8s %-8s %-12s %-12s %-12s\n" "DATE" "COST" "SESSIONS" "AGENTS" "TOKENS_IN" "TOKENS_OUT" "AVG_COST"
            echo "──────────────────────────────────────────────────────────────────────────────────────────"
            
            local daily_query="
                SELECT DATE(cr.recorded_at),
                       SUM(cr.total_cost_usd),
                       COUNT(DISTINCT cr.session_id),
                       COUNT(DISTINCT s.agent_id),
                       SUM(cr.input_tokens),
                       SUM(cr.output_tokens),
                       AVG(cr.total_cost_usd)
                FROM cost_records cr
                JOIN agent_sessions s ON cr.session_id = s.session_id
                WHERE cr.recorded_at >= '$start_date'
                GROUP BY DATE(cr.recorded_at)
                ORDER BY DATE(cr.recorded_at) DESC
            "
            
            _psql_query "$daily_query" | while IFS='|' read -r date cost sessions agents tokens_in tokens_out avg_cost; do
                if [[ -n "$date" ]]; then
                    printf "%-12s %-10s %-8s %-8s %-12s %-12s %-12s\n" \
                           "$date" "$(format_currency "$cost")" "$sessions" "$agents" \
                           "$(printf "%'d" "$tokens_in")" "$(printf "%'d" "$tokens_out")" "$(format_precise_currency "$avg_cost")"
                fi
            done
            ;;
    esac
}

show_costs_by_agent() {
    local days="${1:-7}"
    local format="${FORMAT:-table}"
    
    print_header "Cost Analysis by Agent (Last $days days)"
    
    local start_date=$(date -d "$days days ago" +%Y-%m-%d)
    
    case "$format" in
        json)
            local query="
                SELECT json_agg(
                    json_build_object(
                        'agent_id', s.agent_id,
                        'total_cost', agent_costs.total_cost,
                        'session_count', agent_costs.session_count,
                        'avg_cost_per_session', agent_costs.avg_cost,
                        'total_tokens_in', agent_costs.tokens_in,
                        'total_tokens_out', agent_costs.tokens_out,
                        'cost_per_token', CASE WHEN (agent_costs.tokens_in + agent_costs.tokens_out) > 0 
                                              THEN agent_costs.total_cost / (agent_costs.tokens_in + agent_costs.tokens_out)
                                              ELSE 0 END,
                        'primary_model', agent_costs.primary_model,
                        'daily_average', agent_costs.total_cost / $days
                    )
                ) FROM (
                    SELECT s.agent_id,
                           SUM(cr.total_cost_usd) as total_cost,
                           COUNT(DISTINCT cr.session_id) as session_count,
                           AVG(cr.total_cost_usd) as avg_cost,
                           SUM(cr.input_tokens) as tokens_in,
                           SUM(cr.output_tokens) as tokens_out,
                           MODE() WITHIN GROUP (ORDER BY cr.model_used) as primary_model
                    FROM cost_records cr
                    JOIN agent_sessions s ON cr.session_id = s.session_id
                    WHERE cr.recorded_at >= '$start_date'
                    GROUP BY s.agent_id
                ) agent_costs
                JOIN agent_sessions s ON s.agent_id = agent_costs.agent_id
            "
            _psql_query "$query" | jq .
            ;;
        *)
            printf "%-15s %-10s %-8s %-10s %-12s %-12s %-8s %-20s %-10s\n" "AGENT_ID" "TOTAL_COST" "SESSIONS" "AVG_COST" "TOKENS_IN" "TOKENS_OUT" "COST/TOKEN" "PRIMARY_MODEL" "DAILY_AVG"
            echo "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
            
            local query="
                SELECT s.agent_id,
                       SUM(cr.total_cost_usd) as total_cost,
                       COUNT(DISTINCT cr.session_id) as session_count,
                       AVG(cr.total_cost_usd) as avg_cost,
                       SUM(cr.input_tokens) as tokens_in,
                       SUM(cr.output_tokens) as tokens_out,
                       MODE() WITHIN GROUP (ORDER BY cr.model_used) as primary_model
                FROM cost_records cr
                JOIN agent_sessions s ON cr.session_id = s.session_id
                WHERE cr.recorded_at >= '$start_date'
                GROUP BY s.agent_id
                ORDER BY SUM(cr.total_cost_usd) DESC
            "
            
            _psql_query "$query" | while IFS='|' read -r agent_id total_cost session_count avg_cost tokens_in tokens_out primary_model; do
                if [[ -n "$agent_id" ]]; then
                    local total_tokens=$((tokens_in + tokens_out))
                    local cost_per_token="0.0000"
                    if [[ $total_tokens -gt 0 ]]; then
                        cost_per_token=$(echo "scale=6; $total_cost / $total_tokens" | bc -l 2>/dev/null || echo "0.0000")
                    fi
                    local daily_avg=$(echo "scale=2; $total_cost / $days" | bc -l 2>/dev/null || echo "0.00")
                    
                    printf "%-15s %-10s %-8s %-10s %-12s %-12s \$%-7s %-20s %-10s\n" \
                           "$agent_id" "$(format_currency "$total_cost")" "$session_count" "$(format_precise_currency "$avg_cost")" \
                           "$(printf "%'d" "$tokens_in")" "$(printf "%'d" "$tokens_out")" "$cost_per_token" \
                           "${primary_model:0:20}" "$(format_currency "$daily_avg")"
                fi
            done
            
            # Show efficiency ranking
            echo -e "\nEfficiency Ranking (Cost per token, lower is better):"
            local efficiency_query="
                SELECT s.agent_id,
                       SUM(cr.total_cost_usd) / NULLIF((SUM(cr.input_tokens) + SUM(cr.output_tokens)), 0) as cost_per_token
                FROM cost_records cr
                JOIN agent_sessions s ON cr.session_id = s.session_id
                WHERE cr.recorded_at >= '$start_date'
                GROUP BY s.agent_id
                HAVING (SUM(cr.input_tokens) + SUM(cr.output_tokens)) > 0
                ORDER BY cost_per_token ASC
            "
            
            local rank=1
            _psql_query "$efficiency_query" | while IFS='|' read -r agent_id cost_per_token; do
                if [[ -n "$agent_id" ]]; then
                    local efficiency_color=""
                    case $rank in
                        1) efficiency_color="$GREEN" ;;
                        2|3) efficiency_color="$YELLOW" ;;
                        *) efficiency_color="$NC" ;;
                    esac
                    echo -e "  ${efficiency_color}#${rank} $agent_id: $(format_precise_currency "$cost_per_token")/token${NC}"
                    ((rank++))
                fi
            done
            ;;
    esac
}

# Alert and monitoring functions
check_budget_alerts() {
    local agent_filter="$1"
    
    print_header "Budget Alert Status"
    
    local where_clause=""
    if [[ -n "$agent_filter" ]]; then
        where_clause="AND ba.agent_id = '$agent_filter'"
    fi
    
    local alert_query="
        SELECT ba.agent_id, ba.budget_type, ba.amount_usd, ba.period_start, ba.period_end,
               COALESCE(spending.total_spent, 0) as spent,
               ROUND((COALESCE(spending.total_spent, 0) * 100.0 / ba.amount_usd), 1) as utilization,
               CASE 
                   WHEN COALESCE(spending.total_spent, 0) >= ba.amount_usd THEN 'CRITICAL'
                   WHEN COALESCE(spending.total_spent, 0) >= ba.amount_usd * 0.8 THEN 'HIGH'
                   WHEN COALESCE(spending.total_spent, 0) >= ba.amount_usd * 0.6 THEN 'MEDIUM'
                   ELSE 'LOW'
               END as alert_level
        FROM budget_allocations ba
        LEFT JOIN (
            SELECT s.agent_id, SUM(cr.total_cost_usd) as total_spent
            FROM cost_records cr
            JOIN agent_sessions s ON cr.session_id = s.session_id
            WHERE cr.recorded_at >= ba.period_start AND cr.recorded_at <= ba.period_end + INTERVAL '1 day'
            GROUP BY s.agent_id
        ) spending ON ba.agent_id = spending.agent_id
        WHERE CURRENT_DATE BETWEEN ba.period_start AND ba.period_end
        $where_clause
        ORDER BY utilization DESC, ba.agent_id
    "
    
    local has_alerts=false
    
    # Critical alerts
    echo -e "${BOLD}${RED}CRITICAL ALERTS:${NC}"
    _psql_query "$alert_query" | while IFS='|' read -r agent_id budget_type amount spent utilization alert_level; do
        if [[ "$alert_level" == "CRITICAL" ]]; then
            has_alerts=true
            echo -e "  ${RED}● $agent_id ($budget_type): $(format_currency "$spent")/$(format_currency "$amount") (${utilization}%)${NC}"
            
            # Calculate overage
            local overage=$(echo "scale=2; $spent - $amount" | bc -l)
            echo -e "    ${RED}OVER BUDGET by $(format_currency "$overage")${NC}"
        fi
    done
    
    # High alerts  
    echo -e "\n${BOLD}${YELLOW}HIGH ALERTS:${NC}"
    _psql_query "$alert_query" | while IFS='|' read -r agent_id budget_type amount spent utilization alert_level; do
        if [[ "$alert_level" == "HIGH" ]]; then
            has_alerts=true
            echo -e "  ${YELLOW}● $agent_id ($budget_type): $(format_currency "$spent")/$(format_currency "$amount") (${utilization}%)${NC}"
            
            # Calculate remaining
            local remaining=$(echo "scale=2; $amount - $spent" | bc -l)
            echo -e "    ${YELLOW}$(format_currency "$remaining") remaining${NC}"
        fi
    done
    
    # Medium alerts
    echo -e "\n${BOLD}MEDIUM ALERTS:${NC}"
    _psql_query "$alert_query" | while IFS='|' read -r agent_id budget_type amount spent utilization alert_level; do
        if [[ "$alert_level" == "MEDIUM" ]]; then
            has_alerts=true
            echo -e "  ${CYAN}● $agent_id ($budget_type): $(format_currency "$spent")/$(format_currency "$amount") (${utilization}%)${NC}"
        fi
    done
    
    if [[ "$has_alerts" != "true" ]]; then
        print_success "No budget alerts - all agents within limits"
    fi
    
    # Show recent high-cost activities
    echo -e "\n${BOLD}Recent High-Cost Activities (Last 2 hours):${NC}"
    local high_cost_query="
        SELECT cr.session_id, s.agent_id, cr.model_used, cr.total_cost_usd, cr.recorded_at
        FROM cost_records cr
        JOIN agent_sessions s ON cr.session_id = s.session_id
        WHERE cr.recorded_at > NOW() - INTERVAL '2 hours'
          AND cr.total_cost_usd > 0.01
        ORDER BY cr.total_cost_usd DESC
        LIMIT 10
    "
    
    _psql_query "$high_cost_query" | while IFS='|' read -r session_id agent_id model_used cost recorded_at; do
        if [[ -n "$session_id" ]]; then
            local cost_color=""
            if (( $(echo "$cost > 0.10" | bc -l) )); then
                cost_color="$RED"
            elif (( $(echo "$cost > 0.05" | bc -l) )); then
                cost_color="$YELLOW"
            fi
            
            echo -e "  ${cost_color}$(format_precise_currency "$cost")${NC} - $agent_id using $model_used ($(date -d "$recorded_at" '+%H:%M'))"
        fi
    done
}

# Reporting functions
generate_monthly_report() {
    local month="${1:-$(date +%m)}"
    local year="${2:-$(date +%Y)}"
    
    print_header "Monthly Financial Report - $month/$year"
    
    local month_start="$year-$(printf '%02d' "$month")-01"
    local month_end=$(date -d "$month_start + 1 month - 1 day" +%Y-%m-%d)
    
    echo -e "Report Period: $month_start to $month_end"
    echo -e "Generated: $(date '+%Y-%m-%d %H:%M:%S')\n"
    
    # Monthly summary
    local monthly_summary="
        SELECT COALESCE(SUM(cr.total_cost_usd), 0) as total_cost,
               COUNT(DISTINCT cr.session_id) as total_sessions,
               COUNT(DISTINCT s.agent_id) as active_agents,
               COUNT(DISTINCT s.task_id) as total_tasks,
               COALESCE(SUM(cr.input_tokens), 0) as total_input_tokens,
               COALESCE(SUM(cr.output_tokens), 0) as total_output_tokens
        FROM cost_records cr
        JOIN agent_sessions s ON cr.session_id = s.session_id
        WHERE cr.recorded_at >= '$month_start' AND cr.recorded_at <= '$month_end 23:59:59'
    "
    
    local summary_data=$(_psql_query "$monthly_summary")
    IFS='|' read -r total_cost total_sessions active_agents total_tasks input_tokens output_tokens <<< "$summary_data"
    
    echo -e "${BOLD}EXECUTIVE SUMMARY:${NC}"
    echo -e "  Total Cost: $(format_currency "$total_cost")"
    echo -e "  Sessions: $total_sessions"
    echo -e "  Active Agents: $active_agents"  
    echo -e "  Tasks Processed: $total_tasks"
    echo -e "  Total Tokens: $(printf "%'d" $((input_tokens + output_tokens)))"
    
    local days_in_month=$(date -d "$month_end" +%d)
    local avg_daily_cost=$(echo "scale=2; $total_cost / $days_in_month" | bc -l)
    echo -e "  Average Daily Cost: $(format_currency "$avg_daily_cost")"
    
    # Top spending agents
    echo -e "\n${BOLD}TOP SPENDING AGENTS:${NC}"
    local top_agents="
        SELECT s.agent_id, SUM(cr.total_cost_usd) as agent_cost,
               COUNT(DISTINCT cr.session_id) as sessions,
               ROUND(SUM(cr.total_cost_usd) * 100.0 / $total_cost, 1) as percentage
        FROM cost_records cr
        JOIN agent_sessions s ON cr.session_id = s.session_id
        WHERE cr.recorded_at >= '$month_start' AND cr.recorded_at <= '$month_end 23:59:59'
        GROUP BY s.agent_id
        ORDER BY agent_cost DESC
        LIMIT 5
    "
    
    _psql_query "$top_agents" | while IFS='|' read -r agent_id agent_cost sessions percentage; do
        if [[ -n "$agent_id" ]]; then
            echo -e "  $agent_id: $(format_currency "$agent_cost") (${percentage}%) - $sessions sessions"
        fi
    done
    
    # Model usage analysis
    echo -e "\n${BOLD}MODEL USAGE ANALYSIS:${NC}"
    local model_usage="
        SELECT cr.model_used, SUM(cr.total_cost_usd) as model_cost,
               COUNT(*) as usage_count,
               AVG(cr.total_cost_usd) as avg_cost_per_use,
               SUM(cr.input_tokens + cr.output_tokens) as total_tokens
        FROM cost_records cr
        WHERE cr.recorded_at >= '$month_start' AND cr.recorded_at <= '$month_end 23:59:59'
        GROUP BY cr.model_used
        ORDER BY model_cost DESC
    "
    
    _psql_query "$model_usage" | while IFS='|' read -r model_used model_cost usage_count avg_cost total_tokens; do
        if [[ -n "$model_used" ]]; then
            local percentage=$(echo "scale=1; $model_cost * 100 / $total_cost" | bc -l)
            echo -e "  $model_used: $(format_currency "$model_cost") (${percentage}%) - $usage_count uses, $(printf "%'d" "$total_tokens") tokens"
        fi
    done
    
    # Daily trend analysis
    echo -e "\n${BOLD}DAILY COST TREND:${NC}"
    local daily_trend="
        SELECT DATE(cr.recorded_at) as cost_date, SUM(cr.total_cost_usd) as daily_cost
        FROM cost_records cr
        WHERE cr.recorded_at >= '$month_start' AND cr.recorded_at <= '$month_end 23:59:59'
        GROUP BY DATE(cr.recorded_at)
        ORDER BY cost_date DESC
        LIMIT 10
    "
    
    _psql_query "$daily_trend" | while IFS='|' read -r cost_date daily_cost; do
        if [[ -n "$cost_date" ]]; then
            # Simple text-based bar chart
            local bar_length=$(echo "scale=0; $daily_cost * 50 / $avg_daily_cost" | bc -l 2>/dev/null || echo "0")
            local bar=""
            for ((i=0; i<bar_length && i<50; i++)); do bar+="█"; done
            echo -e "  $cost_date: $(format_currency "$daily_cost") $bar"
        fi
    done
    
    # Budget compliance
    echo -e "\n${BOLD}BUDGET COMPLIANCE:${NC}"
    local budget_compliance="
        SELECT ba.agent_id, ba.amount_usd as monthly_budget,
               COALESCE(SUM(cr.total_cost_usd), 0) as actual_spend,
               ROUND(COALESCE(SUM(cr.total_cost_usd), 0) * 100.0 / ba.amount_usd, 1) as compliance_percentage
        FROM budget_allocations ba
        LEFT JOIN agent_sessions s ON ba.agent_id = s.agent_id
        LEFT JOIN cost_records cr ON s.session_id = cr.session_id 
            AND cr.recorded_at >= '$month_start' AND cr.recorded_at <= '$month_end 23:59:59'
        WHERE ba.budget_type = 'monthly' 
          AND ba.period_start <= '$month_start' 
          AND ba.period_end >= '$month_end'
        GROUP BY ba.agent_id, ba.amount_usd
        ORDER BY compliance_percentage DESC
    "
    
    _psql_query "$budget_compliance" | while IFS='|' read -r agent_id monthly_budget actual_spend compliance_percentage; do
        if [[ -n "$agent_id" ]]; then
            local status_indicator=""
            if (( $(echo "$compliance_percentage > 100" | bc -l) )); then
                status_indicator="${RED}OVER${NC}"
            elif (( $(echo "$compliance_percentage > 80" | bc -l) )); then
                status_indicator="${YELLOW}HIGH${NC}"
            else
                status_indicator="${GREEN}OK${NC}"
            fi
            echo -e "  $agent_id: $(format_currency "$actual_spend")/$(format_currency "$monthly_budget") (${compliance_percentage}%) $status_indicator"
        fi
    done
}

# Main command processor
main() {
    # Parse global options
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -f|--format)
                export FORMAT="$2"
                shift 2
                ;;
            -q|--quiet)
                export QUIET=1
                shift
                ;;
            -v|--verbose)
                export CLAUDE_LOG_LEVEL=0
                shift
                ;;
            --currency)
                export CURRENCY="$2"
                shift 2
                ;;
            --no-color)
                unset RED GREEN YELLOW BLUE PURPLE CYAN BOLD DIM
                readonly RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' CYAN='' BOLD='' DIM='' NC=''
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                print_error "Unknown option: $1"
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done
    
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi
    
    local command="$1"
    shift
    
    case "$command" in
        budget)
            case "${1:-show}" in
                show) shift; show_budget_status "$@" ;;
                set) shift; set_budget "$@" ;;
                delete) shift; delete_budget "$@" ;;
                list) shift; list_budgets "$@" ;;
                auto-create) shift; auto_create_budgets "$@" ;;
                *) print_error "Unknown budget command: $1"; exit 1 ;;
            esac
            ;;
        cost)
            case "${1:-summary}" in
                summary) shift; show_cost_summary "$@" ;;
                by-agent) shift; show_costs_by_agent "$@" ;;
                by-model) shift; show_costs_by_model "$@" ;;
                by-task) shift; show_costs_by_task "$@" ;;
                daily) shift; show_daily_costs "$@" ;;
                hourly) shift; show_hourly_costs "$@" ;;
                efficiency) shift; show_cost_efficiency "$@" ;;
                *) print_error "Unknown cost command: $1"; exit 1 ;;
            esac
            ;;
        alert)
            case "${1:-status}" in
                status) shift; check_budget_alerts "$@" ;;
                check) shift; check_budget_alerts "$@" ;;
                history) shift; show_alert_history "$@" ;;
                configure) shift; configure_alert "$@" ;;
                *) print_error "Unknown alert command: $1"; exit 1 ;;
            esac
            ;;
        report)
            case "${1:-monthly}" in
                monthly) shift; generate_monthly_report "$@" ;;
                weekly) shift; generate_weekly_report "$@" ;;
                agent) shift; generate_agent_report "$@" ;;
                export) shift; export_financial_data "$@" ;;
                forecast) shift; generate_forecast "$@" ;;
                *) print_error "Unknown report command: $1"; exit 1 ;;
            esac
            ;;
        *)
            print_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Check dependencies
for cmd in psql redis-cli jq bc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_error "Required command '$cmd' not found"
        exit 1
    fi
done

# Run main function
main "$@"