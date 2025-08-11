#!/bin/bash
# tools/task-monitor.sh - Real-time task monitoring dashboard for LevAIthan
# Interactive dashboard for monitoring active tasks, agents, costs, and system health

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

# Dashboard configuration
readonly REFRESH_INTERVAL="${MONITOR_REFRESH_SECONDS:-5}"
readonly MAX_LOG_LINES="${MONITOR_LOG_LINES:-20}"
readonly DASHBOARD_MODE="${1:-interactive}"

# Terminal control sequences
readonly CLEAR_SCREEN='\033[2J'
readonly CURSOR_HOME='\033[H'
readonly SAVE_CURSOR='\033[s'
readonly RESTORE_CURSOR='\033[u'
readonly HIDE_CURSOR='\033[?25l'
readonly SHOW_CURSOR='\033[?25h'

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m' # No Color

# Status indicators
readonly STATUS_ACTIVE="${GREEN}●${NC}"
readonly STATUS_PENDING="${YELLOW}●${NC}"
readonly STATUS_FAILED="${RED}●${NC}"
readonly STATUS_COMPLETED="${BLUE}●${NC}"
readonly STATUS_CANCELLED="${DIM}●${NC}"

# Global state for interactive mode
CURRENT_VIEW="overview"
SORT_COLUMN="created_at"
SORT_ORDER="DESC"
FILTER_STATUS=""
FILTER_AGENT=""
SHOW_HELP=false

# Utility functions
get_terminal_size() {
    local size
    size=$(stty size 2>/dev/null || echo "24 80")
    TERM_ROWS=${size%% *}
    TERM_COLS=${size##* }
}

format_duration() {
    local seconds="$1"
    if [[ -z "$seconds" || "$seconds" == "null" ]]; then
        echo "---"
        return
    fi
    
    local days=$((seconds / 86400))
    local hours=$(((seconds % 86400) / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    
    if [[ $days -gt 0 ]]; then
        echo "${days}d ${hours}h ${minutes}m"
    elif [[ $hours -gt 0 ]]; then
        echo "${hours}h ${minutes}m"
    elif [[ $minutes -gt 0 ]]; then
        echo "${minutes}m ${secs}s"
    else
        echo "${secs}s"
    fi
}

format_cost() {
    local cost="$1"
    if [[ -z "$cost" || "$cost" == "null" || "$cost" == "0" ]]; then
        echo "\$0.00"
    else
        printf "\$%.4f" "$cost"
    fi
}

get_status_indicator() {
    local status="$1"
    case "$status" in
        active) echo -e "$STATUS_ACTIVE" ;;
        pending) echo -e "$STATUS_PENDING" ;;
        failed) echo -e "$STATUS_FAILED" ;;
        completed) echo -e "$STATUS_COMPLETED" ;;
        cancelled) echo -e "$STATUS_CANCELLED" ;;
        *) echo -e "${DIM}?${NC}" ;;
    esac
}

# Data collection functions
get_system_overview() {
    local overview_data=""
    
    # Task counts by status
    local task_counts=$(_psql_query "SELECT status, COUNT(*) FROM tasks GROUP BY status ORDER BY status;")
    local total_tasks=$(_psql_query "SELECT COUNT(*) FROM tasks;")
    
    # Active session count
    local active_sessions=$(_psql_query "SELECT COUNT(*) FROM agent_sessions WHERE status IN ('active', 'pending');")
    
    # Today's costs
    local today=$(date +%Y-%m-%d)
    local today_cost=$(_psql_query "SELECT COALESCE(SUM(total_cost_usd), 0) FROM cost_records WHERE DATE(recorded_at) = '$today';")
    
    # System health checks
    local db_healthy=true
    local redis_healthy=true
    
    if ! _psql_query "SELECT 1;" >/dev/null 2>&1; then db_healthy=false; fi
    if ! redis-cli ping >/dev/null 2>&1; then redis_healthy=false; fi
    
    # Workflow execution count
    local wfe_count=$(redis-cli KEYS "wfe:*" 2>/dev/null | wc -l)
    local dlq_size=$(redis-cli LLEN "dlq:envelopes" 2>/dev/null || echo "0")
    
    # Recent activity count (last hour)
    local recent_activity=$(_psql_query "SELECT COUNT(*) FROM agent_sessions WHERE started_at > NOW() - INTERVAL '1 hour';")
    
    echo "OVERVIEW|$total_tasks|$active_sessions|$today_cost|$db_healthy|$redis_healthy|$wfe_count|$dlq_size|$recent_activity"
    echo "$task_counts"
}

get_active_tasks() {
    local where_clause="WHERE t.status IN ('active', 'delegated')"
    if [[ -n "$FILTER_AGENT" ]]; then
        where_clause="$where_clause AND t.assigned_to = '$FILTER_AGENT'"
    fi
    
    _psql_query "
        SELECT 
            t.task_id,
            LEFT(t.objective, 40) || CASE WHEN LENGTH(t.objective) > 40 THEN '...' ELSE '' END as objective_short,
            t.assigned_to,
            t.status,
            EXTRACT(EPOCH FROM (NOW() - t.created_at))::int as age_seconds,
            COALESCE(COUNT(s.session_id), 0) as session_count,
            COALESCE(SUM(cr.total_cost_usd), 0) as total_cost
        FROM tasks t
        LEFT JOIN agent_sessions s ON t.task_id = s.task_id
        LEFT JOIN cost_records cr ON s.session_id = cr.session_id
        $where_clause
        GROUP BY t.task_id, t.objective, t.assigned_to, t.status, t.created_at
        ORDER BY $SORT_COLUMN $SORT_ORDER
        LIMIT 20;
    "
}

get_active_sessions() {
    local where_clause="WHERE s.status IN ('active', 'pending', 'approved_for_execution')"
    if [[ -n "$FILTER_AGENT" ]]; then
        where_clause="$where_clause AND s.agent_id = '$FILTER_AGENT'"
    fi
    
    _psql_query "
        SELECT 
            s.session_id,
            s.agent_id,
            LEFT(t.objective, 35) || CASE WHEN LENGTH(t.objective) > 35 THEN '...' ELSE '' END as objective_short,
            s.status,
            EXTRACT(EPOCH FROM (NOW() - s.started_at))::int as duration_seconds,
            COALESCE(SUM(cr.total_cost_usd), 0) as session_cost,
            COUNT(rl.lock_id) as lock_count
        FROM agent_sessions s
        JOIN tasks t ON s.task_id = t.task_id
        LEFT JOIN cost_records cr ON s.session_id = cr.session_id
        LEFT JOIN resource_locks rl ON s.session_id = rl.session_id
        $where_clause
        GROUP BY s.session_id, s.agent_id, t.objective, s.status, s.started_at
        ORDER BY s.started_at DESC
        LIMIT 15;
    "
}

get_recent_costs() {
    _psql_query "
        SELECT 
            cr.session_id,
            s.agent_id,
            cr.model_used,
            cr.input_tokens,
            cr.output_tokens,
            cr.total_cost_usd,
            cr.recorded_at
        FROM cost_records cr
        JOIN agent_sessions s ON cr.session_id = s.session_id
        WHERE cr.recorded_at > NOW() - INTERVAL '2 hours'
        ORDER BY cr.recorded_at DESC
        LIMIT 10;
    "
}

get_governance_activity() {
    _psql_query "
        SELECT 
            gd.agent_id,
            gd.decision_type,
            gd.decision,
            gd.risk_level,
            LEFT(gd.reasoning, 50) || CASE WHEN LENGTH(gd.reasoning) > 50 THEN '...' ELSE '' END as reasoning_short,
            gd.timestamp
        FROM governance_decisions gd
        WHERE gd.timestamp > NOW() - INTERVAL '1 hour'
        ORDER BY gd.timestamp DESC
        LIMIT 10;
    "
}

get_system_metrics() {
    local cpu_usage
    local memory_usage
    local disk_usage
    
    # System resource usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 | cut -d',' -f1 || echo "0.0")
    memory_usage=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}')
    disk_usage=$(df "$PROJECT_ROOT" | tail -1 | awk '{print $5}' | cut -d'%' -f1)
    
    # Database metrics
    local db_connections=$(_psql_query "SELECT COUNT(*) FROM pg_stat_activity;" 2>/dev/null || echo "0")
    local db_size=$(_psql_query "SELECT pg_size_pretty(pg_database_size(current_database()));" 2>/dev/null || echo "Unknown")
    
    echo "METRICS|$cpu_usage|$memory_usage|$disk_usage|$db_connections|$db_size"
}

# Display functions
display_header() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BOLD}${BLUE}┌─ LevAIthan Dashboard ─────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${BLUE}│${NC} ${timestamp} | View: ${CURRENT_VIEW} | Refresh: ${REFRESH_INTERVAL}s | Press 'h' for help${BOLD}${BLUE} │${NC}"
    echo -e "${BOLD}${BLUE}└─────────────────────────────────────────────────────────────────────────┘${NC}"
}

display_system_overview() {
    local overview_line task_counts
    
    # Read overview data
    local overview_data=$(get_system_overview)
    overview_line=$(echo "$overview_data" | head -1)
    task_counts=$(echo "$overview_data" | tail -n +2)
    
    IFS='|' read -r _ total_tasks active_sessions today_cost db_healthy redis_healthy wfe_count dlq_size recent_activity <<< "$overview_line"
    
    echo -e "\n${BOLD}System Overview:${NC}"
    echo -e "┌─────────────────────────────────────────────────────────────────────────┐"
    
    # Health status
    local db_status redis_status
    [[ "$db_healthy" == "true" ]] && db_status="${GREEN}●${NC}" || db_status="${RED}●${NC}"
    [[ "$redis_healthy" == "true" ]] && redis_status="${GREEN}●${NC}" || redis_status="${RED}●${NC}"
    
    printf "│ Health: PostgreSQL %s Redis %s │ Cost Today: %-10s │\n" "$db_status" "$redis_status" "$(format_cost "$today_cost")"
    printf "│ Tasks: %-3s │ Sessions: %-3s │ Workflows: %-3s │ DLQ: %-3s │ Recent: %-3s │\n" \
           "$total_tasks" "$active_sessions" "$wfe_count" "$dlq_size" "$recent_activity"
    
    # Task status breakdown
    local status_line=""
    while IFS='|' read -r status count; do
        if [[ -n "$status" ]]; then
            local indicator=$(get_status_indicator "$status")
            status_line="$status_line $indicator $status: $count"
        fi
    done <<< "$task_counts"
    
    printf "│ %s │\n" "$status_line"
    echo -e "└─────────────────────────────────────────────────────────────────────────┘"
}

display_active_tasks() {
    echo -e "\n${BOLD}Active Tasks:${NC}"
    echo -e "┌──────────────────────┬────────────────────────────────────────┬─────────────┬────────┬─────────┬──────────┐"
    printf "│ %-20s │ %-38s │ %-11s │ %-6s │ %-7s │ %-8s │\n" "TASK_ID" "OBJECTIVE" "ASSIGNED_TO" "STATUS" "AGE" "COST"
    echo -e "├──────────────────────┼────────────────────────────────────────┼─────────────┼────────┼─────────┼──────────┤"
    
    get_active_tasks | while IFS='|' read -r task_id objective assigned_to status age_seconds session_count total_cost; do
        if [[ -n "$task_id" ]]; then
            local status_indicator=$(get_status_indicator "$status")
            local age_formatted=$(format_duration "$age_seconds")
            local cost_formatted=$(format_cost "$total_cost")
            
            printf "│ %-20s │ %-38s │ %-11s │ %s %-4s │ %-7s │ %-8s │\n" \
                   "${task_id:0:20}" "${objective:0:38}" "${assigned_to:0:11}" \
                   "$status_indicator" "$status" "$age_formatted" "$cost_formatted"
        fi
    done
    echo -e "└──────────────────────┴────────────────────────────────────────┴─────────────┴────────┴─────────┴──────────┘"
}

display_active_sessions() {
    echo -e "\n${BOLD}Active Sessions:${NC}"
    echo -e "┌─────────────────────┬─────────────┬───────────────────────────────────┬────────┬─────────┬──────────┬──────┐"
    printf "│ %-19s │ %-11s │ %-33s │ %-6s │ %-7s │ %-8s │ %-4s │\n" "SESSION_ID" "AGENT_ID" "OBJECTIVE" "STATUS" "DURATION" "COST" "LOCKS"
    echo -e "├─────────────────────┼─────────────┼───────────────────────────────────┼────────┼─────────┼──────────┼──────┤"
    
    get_active_sessions | while IFS='|' read -r session_id agent_id objective status duration_seconds session_cost lock_count; do
        if [[ -n "$session_id" ]]; then
            local status_indicator=$(get_status_indicator "$status")
            local duration_formatted=$(format_duration "$duration_seconds")
            local cost_formatted=$(format_cost "$session_cost")
            
            printf "│ %-19s │ %-11s │ %-33s │ %s %-4s │ %-7s │ %-8s │ %-4s │\n" \
                   "${session_id:0:19}" "${agent_id:0:11}" "${objective:0:33}" \
                   "$status_indicator" "$status" "$duration_formatted" "$cost_formatted" "$lock_count"
        fi
    done
    echo -e "└─────────────────────┴─────────────┴───────────────────────────────────┴────────┴─────────┴──────────┴──────┘"
}

display_recent_costs() {
    echo -e "\n${BOLD}Recent Costs (Last 2 hours):${NC}"
    echo -e "┌─────────────────────┬─────────────┬─────────────────────┬──────────┬───────────┬──────────┐"
    printf "│ %-19s │ %-11s │ %-19s │ %-8s │ %-9s │ %-8s │\n" "SESSION_ID" "AGENT_ID" "MODEL" "IN_TOKENS" "OUT_TOKENS" "COST"
    echo -e "├─────────────────────┼─────────────┼─────────────────────┼──────────┼───────────┼──────────┤"
    
    get_recent_costs | while IFS='|' read -r session_id agent_id model input_tokens output_tokens cost recorded_at; do
        if [[ -n "$session_id" ]]; then
            local cost_formatted=$(format_cost "$cost")
            printf "│ %-19s │ %-11s │ %-19s │ %-8s │ %-9s │ %-8s │\n" \
                   "${session_id:0:19}" "${agent_id:0:11}" "${model:0:19}" \
                   "$input_tokens" "$output_tokens" "$cost_formatted"
        fi
    done
    echo -e "└─────────────────────┴─────────────┴─────────────────────┴──────────┴───────────┴──────────┘"
}

display_governance_activity() {
    echo -e "\n${BOLD}Governance Activity (Last hour):${NC}"
    echo -e "┌─────────────┬─────────────────┬────────┬──────────────┬──────────────────────────────────────────────────┐"
    printf "│ %-11s │ %-15s │ %-6s │ %-12s │ %-48s │\n" "AGENT_ID" "DECISION_TYPE" "RESULT" "RISK_LEVEL" "REASONING"
    echo -e "├─────────────┼─────────────────┼────────┼──────────────┼──────────────────────────────────────────────────┤"
    
    get_governance_activity | while IFS='|' read -r agent_id decision_type decision risk_level reasoning timestamp; do
        if [[ -n "$agent_id" ]]; then
            local result_indicator
            [[ "$decision" == "true" ]] && result_indicator="${GREEN}ALLOW${NC}" || result_indicator="${RED}BLOCK${NC}"
            
            printf "│ %-11s │ %-15s │ %s │ %-12s │ %-48s │\n" \
                   "${agent_id:0:11}" "${decision_type:0:15}" "$result_indicator" \
                   "${risk_level:0:12}" "${reasoning:0:48}"
        fi
    done
    echo -e "└─────────────┴─────────────────┴────────┴──────────────┴──────────────────────────────────────────────────┘"
}

display_system_metrics() {
    local metrics_data=$(get_system_metrics)
    IFS='|' read -r _ cpu_usage memory_usage disk_usage db_connections db_size <<< "$metrics_data"
    
    echo -e "\n${BOLD}System Metrics:${NC}"
    echo -e "┌─────────────────────────────────────────────────────────────────────────┐"
    printf "│ CPU: %3s%% │ Memory: %4s%% │ Disk: %3s%% │ DB Conn: %3s │ DB Size: %8s │\n" \
           "$cpu_usage" "$memory_usage" "$disk_usage" "$db_connections" "$db_size"
    echo -e "└─────────────────────────────────────────────────────────────────────────┘"
}

display_recent_logs() {
    echo -e "\n${BOLD}Recent System Activity:${NC}"
    echo -e "┌─────────────────────┬─────────┬────────────────┬─────────────────┬──────────────────────────────────────┐"
    printf "│ %-19s │ %-7s │ %-14s │ %-15s │ %-36s │\n" "TIMESTAMP" "LEVEL" "HOOK" "EVENT" "MESSAGE"
    echo -e "├─────────────────────┼─────────┼────────────────┼─────────────────┼──────────────────────────────────────┤"
    
    if [[ -f "$LOGS_DIR/system.jsonl" ]]; then
        tail -n "$MAX_LOG_LINES" "$LOGS_DIR/system.jsonl" | while read -r log_line; do
            if [[ -n "$log_line" ]]; then
                local timestamp level hook event message
                timestamp=$(echo "$log_line" | jq -r '.timestamp // "unknown"' | cut -c12-19)
                level=$(echo "$log_line" | jq -r '.level // "INFO"')
                hook=$(echo "$log_line" | jq -r '.hook // "unknown"')
                event=$(echo "$log_line" | jq -r '.event // "unknown"')
                message=$(echo "$log_line" | jq -r '.message // ""')
                
                # Color code by level
                local level_colored
                case "$level" in
                    ERROR|CRITICAL) level_colored="${RED}$level${NC}" ;;
                    WARNING) level_colored="${YELLOW}$level${NC}" ;;
                    INFO) level_colored="${GREEN}$level${NC}" ;;
                    *) level_colored="$level" ;;
                esac
                
                printf "│ %-19s │ %s │ %-14s │ %-15s │ %-36s │\n" \
                       "$timestamp" "$level_colored" "${hook:0:14}" "${event:0:15}" "${message:0:36}"
            fi
        done
    else
        printf "│ %-19s │ %-7s │ %-14s │ %-15s │ %-36s │\n" \
               "No log file found" "" "" "" ""
    fi
    echo -e "└─────────────────────┴─────────┴────────────────┴─────────────────┴──────────────────────────────────────┘"
}

display_help() {
    echo -e "\n${BOLD}${CYAN}Dashboard Help:${NC}"
    echo -e "┌─────────────────────────────────────────────────────────────────────────┐"
    echo -e "│ ${BOLD}Navigation:${NC}                                                           │"
    echo -e "│   o - Overview         t - Tasks           s - Sessions                 │"
    echo -e "│   c - Costs           g - Governance       m - Metrics                 │"
    echo -e "│   l - Logs            h - Help             q - Quit                    │"
    echo -e "│                                                                         │"
    echo -e "│ ${BOLD}Filtering:${NC}                                                           │"
    echo -e "│   f - Filter by agent  r - Reset filters                               │"
    echo -e "│                                                                         │"
    echo -e "│ ${BOLD}Controls:${NC}                                                            │"
    echo -e "│   + - Increase refresh rate    - - Decrease refresh rate               │"
    echo -e "│   SPACE - Manual refresh       ENTER - Dismiss help                    │"
    echo -e "└─────────────────────────────────────────────────────────────────────────┘"
}

# Interactive dashboard
run_interactive_dashboard() {
    trap cleanup_dashboard EXIT INT TERM
    
    # Hide cursor and clear screen
    printf '%s%s' "$HIDE_CURSOR" "$CLEAR_SCREEN"
    
    while true; do
        get_terminal_size
        
        # Clear screen and move cursor to top
        printf '%s%s' "$CLEAR_SCREEN" "$CURSOR_HOME"
        
        # Display header
        display_header
        
        if [[ "$SHOW_HELP" == "true" ]]; then
            display_help
        else
            # Display current view
            case "$CURRENT_VIEW" in
                overview)
                    display_system_overview
                    display_active_tasks
                    display_recent_logs
                    ;;
                tasks)
                    display_system_overview
                    display_active_tasks
                    ;;
                sessions)
                    display_system_overview
                    display_active_sessions
                    ;;
                costs)
                    display_system_overview
                    display_recent_costs
                    ;;
                governance)
                    display_system_overview
                    display_governance_activity
                    ;;
                metrics)
                    display_system_metrics
                    display_recent_logs
                    ;;
                logs)
                    display_recent_logs
                    ;;
            esac
        fi
        
        # Status bar
        echo -e "\n${DIM}View: $CURRENT_VIEW | Filter: ${FILTER_AGENT:-none} | Press 'h' for help, 'q' to quit${NC}"
        
        # Wait for input with timeout
        if read -t "$REFRESH_INTERVAL" -n 1 key; then
            case "$key" in
                q|Q) break ;;
                h|H) SHOW_HELP=$([[ "$SHOW_HELP" == "true" ]] && echo "false" || echo "true") ;;
                o|O) CURRENT_VIEW="overview"; SHOW_HELP="false" ;;
                t|T) CURRENT_VIEW="tasks"; SHOW_HELP="false" ;;
                s|S) CURRENT_VIEW="sessions"; SHOW_HELP="false" ;;
                c|C) CURRENT_VIEW="costs"; SHOW_HELP="false" ;;
                g|G) CURRENT_VIEW="governance"; SHOW_HELP="false" ;;
                m|M) CURRENT_VIEW="metrics"; SHOW_HELP="false" ;;
                l|L) CURRENT_VIEW="logs"; SHOW_HELP="false" ;;
                f|F) 
                    printf '%s%s' "$SHOW_CURSOR" "$SAVE_CURSOR"
                    echo -e "\nEnter agent ID to filter (or press ENTER for none): "
                    read -r filter_input
                    FILTER_AGENT="$filter_input"
                    printf '%s' "$HIDE_CURSOR"
                    ;;
                r|R) FILTER_AGENT=""; SHOW_HELP="false" ;;
                +) REFRESH_INTERVAL=$((REFRESH_INTERVAL > 1 ? REFRESH_INTERVAL - 1 : 1)) ;;
                -) REFRESH_INTERVAL=$((REFRESH_INTERVAL + 1)) ;;
                ' ') ;; # Manual refresh - just continue loop
                $'\n') SHOW_HELP="false" ;; # Enter key - dismiss help
            esac
        fi
    done
}

cleanup_dashboard() {
    printf '%s%s' "$SHOW_CURSOR" "$CLEAR_SCREEN"
    exit 0
}

# Non-interactive mode for scripting
run_snapshot_mode() {
    local mode="$1"
    
    case "$mode" in
        overview|"")
            display_system_overview
            display_active_tasks
            ;;
        tasks)
            display_active_tasks
            ;;
        sessions)
            display_active_sessions
            ;;
        costs)
            display_recent_costs
            ;;
        governance)
            display_governance_activity
            ;;
        metrics)
            display_system_metrics
            ;;
        logs)
            display_recent_logs
            ;;
        *)
            echo "ERROR: Unknown snapshot mode: $mode" >&2
            echo "Available modes: overview, tasks, sessions, costs, governance, metrics, logs" >&2
            exit 1
            ;;
    esac
}

# Main function
main() {
    case "$DASHBOARD_MODE" in
        interactive|"")
            run_interactive_dashboard
            ;;
        snapshot)
            run_snapshot_mode "$2"
            ;;
        *)
            run_snapshot_mode "$DASHBOARD_MODE"
            ;;
    esac
}

# Check if we have required commands
for cmd in psql redis-cli jq stty; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found" >&2
        exit 1
    fi
done

# Run the dashboard
main "$@"