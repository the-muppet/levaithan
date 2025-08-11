#!/bin/bash
# tools/system-cli.sh - Main human operator interface for LevAIthan system
# Comprehensive CLI for task management, agent coordination, and system administration

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

# CLI Configuration
readonly PROGRAM_NAME="prometheus-cli"
readonly VERSION="1.0.0"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Helper functions for formatted output
print_header() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${CYAN}ℹ $1${NC}"; }

# Generate unique IDs
generate_id() {
    echo "$(date +%Y%m%d_%H%M%S)_$(openssl rand -hex 4)"
}

# Usage information
show_usage() {
    cat << EOF
${PROGRAM_NAME} v${VERSION} - LevAIthan System CLI

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    System Management:
        status                  Show system health and overview
        init                    Initialize system (run setup.sh)
        reset                   Reset system state (careful!)
        logs [lines]            Show recent system logs
        config                  Show current configuration

    Task Management:
        task create <objective> [agent_id]     Create new task
        task list [status]                     List tasks (all/active/completed)
        task show <task_id>                    Show task details
        task assign <task_id> <agent_id>       Assign task to agent
        task cancel <task_id>                  Cancel task
        task tree [task_id]                    Show task hierarchy

    Agent & Session Management:
        agent list                             List all agents
        agent status <agent_id>                Show agent status
        session list [agent_id]               List sessions
        session show <session_id>              Show session details
        session kill <session_id>              Terminate session
        session locks [session_id]            Show resource locks

    Budget & Cost Management:
        budget show [agent_id]                 Show budget status
        budget set <agent_id> <amount> [type]  Set budget (daily/weekly/monthly)
        cost summary [days]                    Show cost summary
        cost by-agent [days]                   Show costs by agent
        cost by-model [days]                   Show costs by model

    Monitoring & Analytics:
        monitor dashboard                      Launch monitoring dashboard
        monitor tasks                          Monitor active tasks
        monitor performance                    Show performance metrics
        analytics patterns                     Show learned patterns
        analytics effectiveness                Show context effectiveness

    Governance & Safety:
        governance decisions [days]            Show recent governance decisions
        governance suggestions                 Show pending suggestions
        feedback list [status]                Show human feedback
        feedback add <task_id> <type> <text>   Add human feedback
        
    Database & Maintenance:
        db status                              Check database connectivity
        db backup                              Create database backup
        db cleanup [days]                      Clean old records
        queue status                           Show Redis queue status
        queue clear-dlq                       Clear dead letter queue

OPTIONS:
    -h, --help                Show this help message
    -v, --verbose             Enable verbose output
    -q, --quiet               Suppress non-essential output
    -f, --format FORMAT       Output format (table/json/csv)
    --no-color                Disable colored output

EXAMPLES:
    $0 status                                 # System overview
    $0 task create "Optimize database queries" data-analyst
    $0 session list --format json
    $0 budget set agent-1 15.00 daily
    $0 monitor dashboard
    $0 analytics patterns --format table

EOF
}

# System status check
check_system_status() {
    print_header "LevAIthan System Status"
    
    local all_healthy=true
    
    # Check PostgreSQL
    print_info "Checking PostgreSQL connection..."
    if _psql_query "SELECT 1;" >/dev/null 2>&1; then
        print_success "PostgreSQL: Connected"
        local task_count=$(psql "$POSTGRES_DSN" -t -A -c "SELECT COUNT(*) FROM tasks;")
        local session_count=$(psql "$POSTGRES_DSN" -t -A -c "SELECT COUNT(*) FROM agent_sessions WHERE status IN ('active', 'pending');")
        echo -e "  Tasks: $task_count total, Active sessions: $session_count"
    else
        print_error "PostgreSQL: Connection failed"
        all_healthy=false
    fi
    
    # Check Redis
    print_info "Checking Redis connection..."
    if redis-cli ping >/dev/null 2>&1; then
        print_success "Redis: Connected"
        local wfe_keys=$(redis-cli KEYS "wfe:*" | wc -l)
        local dlq_size=$(redis-cli LLEN "dlq:envelopes" 2>/dev/null || echo "0")
        echo -e "  Workflow executions: $wfe_keys, DLQ size: $dlq_size"
    else
        print_error "Redis: Connection failed"
        all_healthy=false
    fi
    
    # Check system lock
    if [[ -f "$PROJECT_ROOT/.system-lock" ]]; then
        print_warning "System is LOCKED for maintenance"
        all_healthy=false
    else
        print_success "System: Unlocked and operational"
    fi
    
    # Show resource usage
    local disk_usage=$(df -h "$PROJECT_ROOT" | tail -1 | awk '{print $5}')
    local memory_usage=$(free -h | grep '^Mem:' | awk '{print $3 "/" $2}')
    echo -e "\nResource Usage:"
    echo -e "  Disk: $disk_usage used"
    echo -e "  Memory: $memory_usage"
    
    if $all_healthy; then
        print_success "All systems operational"
        return 0
    else
        print_error "Some systems have issues"
        return 1
    fi
}

# Task management functions
create_task() {
    local objective="$1"
    local agent_id="${2:-human-operator}"
    local task_id="task_$(generate_id)"
    
    if [[ -z "$objective" ]]; then
        print_error "Objective is required"
        return 1
    fi
    
    print_info "Creating task: $objective"
    if create_task_record "$task_id" "" "$objective" "$agent_id"; then
        print_success "Task created: $task_id"
        echo "Objective: $objective"
        echo "Created by: $agent_id"
    else
        print_error "Failed to create task"
        return 1
    fi
}

list_tasks() {
    local status_filter="${1:-all}"
    local format="${FORMAT:-table}"
    
    print_header "Task List"
    
    local where_clause=""
    if [[ "$status_filter" != "all" ]]; then
        where_clause="WHERE status = '$status_filter'"
    fi
    
    case "$format" in
        json)
            _psql_query "SELECT json_agg(row_to_json(t)) FROM (SELECT task_id, objective, created_by, assigned_to, status, created_at FROM tasks $where_clause ORDER BY created_at DESC) t;" | jq .
            ;;
        csv)
            echo "task_id,objective,created_by,assigned_to,status,created_at"
            _psql_query "COPY (SELECT task_id, objective, created_by, assigned_to, status, created_at FROM tasks $where_clause ORDER BY created_at DESC) TO STDOUT WITH CSV;"
            ;;
        *)
            printf "%-20s %-50s %-15s %-15s %-10s %-20s\n" "TASK_ID" "OBJECTIVE" "CREATED_BY" "ASSIGNED_TO" "STATUS" "CREATED_AT"
            echo "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
            _psql_query "SELECT task_id, LEFT(objective, 47) || CASE WHEN LENGTH(objective) > 47 THEN '...' ELSE '' END, created_by, COALESCE(assigned_to, '-'), status, created_at FROM tasks $where_clause ORDER BY created_at DESC;" | while IFS='|' read -r task_id objective created_by assigned_to status created_at; do
                printf "%-20s %-50s %-15s %-15s %-10s %-20s\n" "$task_id" "$objective" "$created_by" "$assigned_to" "$status" "$created_at"
            done
            ;;
    esac
}

show_task_details() {
    local task_id="$1"
    if [[ -z "$task_id" ]]; then
        print_error "Task ID is required"
        return 1
    fi
    
    print_header "Task Details: $task_id"
    
    # Get task info
    local task_info=$(_psql_query "SELECT objective, created_by, assigned_to, status, created_at, updated_at FROM tasks WHERE task_id='$task_id';")
    if [[ -z "$task_info" ]]; then
        print_error "Task not found: $task_id"
        return 1
    fi
    
    echo "$task_info" | IFS='|' read -r objective created_by assigned_to status created_at updated_at
    
    echo -e "Objective: $objective"
    echo -e "Created by: $created_by"
    echo -e "Assigned to: ${assigned_to:-unassigned}"
    echo -e "Status: $status"
    echo -e "Created: $created_at"
    echo -e "Updated: $updated_at"
    
    # Show related sessions
    echo -e "\nRelated Sessions:"
    _psql_query "SELECT session_id, agent_id, status, started_at FROM agent_sessions WHERE task_id='$task_id' ORDER BY started_at DESC;" | while IFS='|' read -r session_id agent_id session_status started_at; do
        echo -e "  $session_id ($agent_id) - $session_status - $started_at"
    done
    
    # Show cost summary
    local total_cost=$(_psql_query "SELECT COALESCE(SUM(cr.total_cost_usd), 0) FROM cost_records cr JOIN agent_sessions s ON cr.session_id = s.session_id WHERE s.task_id='$task_id';")
    echo -e "\nTotal Cost: \$${total_cost}"
}

# Budget management functions
show_budget_status() {
    local agent_id="$1"
    print_header "Budget Status"
    
    if [[ -n "$agent_id" ]]; then
        # Show budget for specific agent
        echo -e "Agent: $agent_id\n"
        _psql_query "SELECT budget_type, amount_usd, period_start, period_end FROM budget_allocations WHERE agent_id='$agent_id' ORDER BY budget_type;" | while IFS='|' read -r budget_type amount period_start period_end; do
            echo -e "$budget_type: \$${amount} ($period_start to $period_end)"
        done
        
        # Show current spending
        local today=$(date +%Y-%m-%d)
        local daily_spent=$(_psql_query "SELECT COALESCE(SUM(cr.total_cost_usd), 0) FROM cost_records cr JOIN agent_sessions s ON cr.session_id = s.session_id WHERE s.agent_id='$agent_id' AND DATE(cr.recorded_at) = '$today';")
        echo -e "\nToday's spending: \$${daily_spent}"
    else
        # Show all agents' budgets
        printf "%-15s %-10s %-12s %-12s %-12s\n" "AGENT_ID" "TYPE" "BUDGET" "PERIOD_START" "PERIOD_END"
        echo "────────────────────────────────────────────────────────────────────────────"
        _psql_query "SELECT agent_id, budget_type, amount_usd, period_start, period_end FROM budget_allocations ORDER BY agent_id, budget_type;" | while IFS='|' read -r agent budget_type amount period_start period_end; do
            printf "%-15s %-10s \$%-11s %-12s %-12s\n" "$agent" "$budget_type" "$amount" "$period_start" "$period_end"
        done
    fi
}

set_budget() {
    local agent_id="$1"
    local amount="$2"
    local budget_type="${3:-daily}"
    
    if [[ -z "$agent_id" || -z "$amount" ]]; then
        print_error "Agent ID and amount are required"
        return 1
    fi
    
    # Validate budget type
    if [[ ! "$budget_type" =~ ^(daily|weekly|monthly)$ ]]; then
        print_error "Budget type must be daily, weekly, or monthly"
        return 1
    fi
    
    # Calculate period dates
    local period_start period_end
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
    
    print_info "Setting $budget_type budget for $agent_id: \$${amount}"
    
    if _psql_query "INSERT INTO budget_allocations (agent_id, budget_type, amount_usd, period_start, period_end) VALUES ('$agent_id', '$budget_type', $amount, '$period_start', '$period_end') ON CONFLICT (agent_id, budget_type, period_start) DO UPDATE SET amount_usd = $amount;"; then
        print_success "Budget updated successfully"
    else
        print_error "Failed to update budget"
        return 1
    fi
}

# Cost analysis functions
show_cost_summary() {
    local days="${1:-7}"
    print_header "Cost Summary (Last $days days)"
    
    local start_date=$(date -d "$days days ago" +%Y-%m-%d)
    
    # Total costs
    local total_cost=$(_psql_query "SELECT COALESCE(SUM(total_cost_usd), 0) FROM cost_records WHERE recorded_at >= '$start_date';")
    echo -e "Total Cost: \$${total_cost}"
    
    # Daily breakdown
    echo -e "\nDaily Breakdown:"
    printf "%-12s %-10s %-15s %-15s\n" "DATE" "COST" "SESSIONS" "MODELS_USED"
    echo "──────────────────────────────────────────────────────────────"
    _psql_query "SELECT DATE(recorded_at), SUM(total_cost_usd), COUNT(DISTINCT session_id), COUNT(DISTINCT model_used) FROM cost_records WHERE recorded_at >= '$start_date' GROUP BY DATE(recorded_at) ORDER BY DATE(recorded_at) DESC;" | while IFS='|' read -r date cost sessions models; do
        printf "%-12s \$%-9s %-15s %-15s\n" "$date" "$cost" "$sessions" "$models"
    done
}

# Database operations
check_database_status() {
    print_header "Database Status"
    
    # PostgreSQL tables
    print_info "PostgreSQL Tables:"
    _psql_query "SELECT schemaname, tablename, n_tup_ins as inserts, n_tup_upd as updates, n_tup_del as deletes FROM pg_stat_user_tables ORDER BY tablename;" | while IFS='|' read -r schema table inserts updates deletes; do
        echo -e "  $table: $inserts inserts, $updates updates, $deletes deletes"
    done
    
    # Redis keys
    print_info "Redis Key Statistics:"
    local total_keys=$(redis-cli DBSIZE)
    local wfe_keys=$(redis-cli KEYS "wfe:*" | wc -l)
    local dlq_size=$(redis-cli LLEN "dlq:envelopes" 2>/dev/null || echo "0")
    echo -e "  Total keys: $total_keys"
    echo -e "  Workflow executions: $wfe_keys"
    echo -e "  Dead letter queue: $dlq_size items"
}

# Main command parser
main() {
    # Parse global options
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                export CLAUDE_LOG_LEVEL=0
                export VERBOSE=1
                shift
                ;;
            -q|--quiet)
                export QUIET=1
                shift
                ;;
            -f|--format)
                export FORMAT="$2"
                shift 2
                ;;
            --no-color)
                unset RED GREEN YELLOW BLUE PURPLE CYAN
                readonly RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' CYAN='' NC=''
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
        status)
            check_system_status
            ;;
        init)
            print_info "Initializing system..."
            "$PROJECT_ROOT/setup.sh"
            ;;
        logs)
            local lines="${1:-50}"
            print_header "System Logs (Last $lines lines)"
            tail -n "$lines" "$LOGS_DIR/system.jsonl" | jq -r '[.timestamp, .level, .hook, .event, .message] | @tsv' | column -t
            ;;
        task)
            case "${1:-list}" in
                create) shift; create_task "$@" ;;
                list) shift; list_tasks "$@" ;;
                show) shift; show_task_details "$@" ;;
                assign) shift; assign_task "$@" ;;
                cancel) shift; cancel_task "$@" ;;
                tree) shift; show_task_tree "$@" ;;
                *) print_error "Unknown task command: $1"; exit 1 ;;
            esac
            ;;
        budget)
            case "${1:-show}" in
                show) shift; show_budget_status "$@" ;;
                set) shift; set_budget "$@" ;;
                *) print_error "Unknown budget command: $1"; exit 1 ;;
            esac
            ;;
        cost)
            case "${1:-summary}" in
                summary) shift; show_cost_summary "$@" ;;
                by-agent) shift; show_costs_by_agent "$@" ;;
                by-model) shift; show_costs_by_model "$@" ;;
                *) print_error "Unknown cost command: $1"; exit 1 ;;
            esac
            ;;
        monitor)
            case "${1:-dashboard}" in
                dashboard) shift; exec "$SCRIPT_DIR/task-monitor.sh" "$@" ;;
                *) print_error "Unknown monitor command: $1"; exit 1 ;;
            esac
            ;;
        db)
            case "${1:-status}" in
                status) shift; check_database_status ;;
                *) print_error "Unknown db command: $1"; exit 1 ;;
            esac
            ;;
        *)
            print_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"