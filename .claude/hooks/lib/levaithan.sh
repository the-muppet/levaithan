#!/bin/bash
# lib/claude.sh - Claude API integration library with retry logic, rate limiting, and cost tracking.
# This library provides comprehensive utilities for interacting with Claude AI models.

set -e

# Source required libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/logging.sh"
source "$SCRIPT_DIR/data-access.sh"

# Claude API Configuration
readonly CLAUDE_API_BASE_URL="${CLAUDE_API_BASE_URL:-https://api.anthropic.com/v1}"
readonly CLAUDE_API_VERSION="${CLAUDE_API_VERSION:-2023-06-01}"
readonly DEFAULT_MODEL="${CLAUDE_MODEL:-claude-3-sonnet-20240229}"
readonly DEFAULT_MAX_TOKENS="${CLAUDE_MAX_TOKENS:-4096}"
readonly DEFAULT_TEMPERATURE="${CLAUDE_TEMPERATURE:-0.7}"

# Rate limiting and retry configuration
readonly MAX_RETRIES="${CLAUDE_MAX_RETRIES:-3}"
readonly INITIAL_RETRY_DELAY="${CLAUDE_INITIAL_RETRY_DELAY:-1}"
readonly MAX_RETRY_DELAY="${CLAUDE_MAX_RETRY_DELAY:-30}"
readonly RATE_LIMIT_DELAY="${CLAUDE_RATE_LIMIT_DELAY:-0.1}"

# Model specifications for token counting and cost calculation
declare -A MODEL_SPECS=(
    ["claude-3-opus-20240229"]="input_cost=0.015,output_cost=0.075,max_tokens=200000"
    ["claude-3-sonnet-20240229"]="input_cost=0.003,output_cost=0.015,max_tokens=200000"
    ["claude-3-haiku-20240307"]="input_cost=0.00025,output_cost=0.00125,max_tokens=200000"
    ["claude-3-5-sonnet-20241022"]="input_cost=0.003,output_cost=0.015,max_tokens=200000"
    ["claude-3-5-haiku-20241022"]="input_cost=0.001,output_cost=0.005,max_tokens=200000"
)

# Error handling
claude_error() {
    local error_msg="$1"
    local error_code="${2:-1}"
    log_error "claude_api_error" "failed" "$error_msg"
    return "$error_code"
}

# Validate required environment variables
claude_validate_config() {
    if [[ -z "$CLAUDE_API_KEY" ]]; then
        claude_error "CLAUDE_API_KEY environment variable is required" 1
        return 1
    fi
    
    log_info "claude_config_validation" "success" "Claude API configuration validated"
    return 0
}

# Parse model specifications
claude_get_model_spec() {
    local model="$1"
    local spec_key="$2"
    
    if [[ -z "${MODEL_SPECS[$model]}" ]]; then
        echo "0"
        return 1
    fi
    
    local spec="${MODEL_SPECS[$model]}"
    local value
    value=$(echo "$spec" | grep -o "${spec_key}=[0-9.]*" | cut -d= -f2)
    echo "${value:-0}"
}

# Estimate token count (rough approximation: 1 token ≈ 4 characters)
claude_estimate_tokens() {
    local text="$1"
    local char_count=${#text}
    local estimated_tokens=$((char_count / 4))
    echo "$estimated_tokens"
}

# Calculate cost based on model and token usage
claude_calculate_cost() {
    local model="$1"
    local input_tokens="$2"
    local output_tokens="$3"
    
    local input_cost_per_1k
    local output_cost_per_1k
    input_cost_per_1k=$(claude_get_model_spec "$model" "input_cost")
    output_cost_per_1k=$(claude_get_model_spec "$model" "output_cost")
    
    # Calculate costs (prices are per 1K tokens)
    local input_cost
    local output_cost
    local total_cost
    input_cost=$(echo "scale=6; $input_tokens * $input_cost_per_1k / 1000" | bc -l)
    output_cost=$(echo "scale=6; $output_tokens * $output_cost_per_1k / 1000" | bc -l)
    total_cost=$(echo "scale=6; $input_cost + $output_cost" | bc -l)
    
    echo "$total_cost"
}

# Get context window size for model
claude_get_context_window() {
    local model="$1"
    claude_get_model_spec "$model" "max_tokens"
}

# Check if content fits in context window
claude_check_context_window() {
    local model="$1"
    local content="$2"
    local max_tokens
    local content_tokens
    
    max_tokens=$(claude_get_context_window "$model")
    content_tokens=$(claude_estimate_tokens "$content")
    
    if [[ "$content_tokens" -gt "$max_tokens" ]]; then
        log_warning "claude_context_check" "exceeded" "Content ($content_tokens tokens) exceeds context window ($max_tokens tokens) for model $model"
        return 1
    fi
    
    log_info "claude_context_check" "success" "Content fits in context window ($content_tokens/$max_tokens tokens)"
    return 0
}

# Exponential backoff delay calculation
claude_calculate_backoff_delay() {
    local attempt="$1"
    local base_delay="$2"
    local max_delay="$3"
    
    local delay
    delay=$(echo "scale=2; $base_delay * (2 ^ ($attempt - 1))" | bc -l)
    
    # Cap at max delay
    if (( $(echo "$delay > $max_delay" | bc -l) )); then
        delay="$max_delay"
    fi
    
    echo "$delay"
}

# Make HTTP request to Claude API with retry logic
claude_api_request() {
    local endpoint="$1"
    local method="${2:-POST}"
    local data="$3"
    local attempt=1
    local response
    local http_code
    local temp_file
    
    temp_file=$(mktemp)
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_info "claude_api_request" "attempting" "Making API request to $endpoint (attempt $attempt/$MAX_RETRIES)"
        
        # Make the API call
        http_code=$(curl -s -w "%{http_code}" \
            -X "$method" \
            -H "Content-Type: application/json" \
            -H "x-api-key: $CLAUDE_API_KEY" \
            -H "anthropic-version: $CLAUDE_API_VERSION" \
            -d "$data" \
            "$CLAUDE_API_BASE_URL/$endpoint" \
            -o "$temp_file")
        
        response=$(cat "$temp_file")
        
        case "$http_code" in
            200)
                log_info "claude_api_request" "success" "API request successful"
                echo "$response"
                rm -f "$temp_file"
                return 0
                ;;
            429)
                local retry_after
                retry_after=$(echo "$response" | jq -r '.error.retry_after // 60')
                log_warning "claude_api_request" "rate_limited" "Rate limited, waiting ${retry_after}s before retry"
                sleep "$retry_after"
                ;;
            5*)
                log_warning "claude_api_request" "server_error" "Server error (HTTP $http_code), retrying"
                ;;
            4*)
                log_error "claude_api_request" "client_error" "Client error (HTTP $http_code): $response"
                rm -f "$temp_file"
                return 1
                ;;
            *)
                log_warning "claude_api_request" "unknown_error" "Unknown error (HTTP $http_code): $response"
                ;;
        esac
        
        if [[ $attempt -lt $MAX_RETRIES ]]; then
            local delay
            delay=$(claude_calculate_backoff_delay "$attempt" "$INITIAL_RETRY_DELAY" "$MAX_RETRY_DELAY")
            log_info "claude_api_request" "retrying" "Waiting ${delay}s before retry"
            sleep "$delay"
        fi
        
        ((attempt++))
    done
    
    log_error "claude_api_request" "failed" "API request failed after $MAX_RETRIES attempts"
    rm -f "$temp_file"
    return 1
}

# Create a message request payload
claude_create_message_payload() {
    local model="$1"
    local messages="$2"  # JSON array of message objects
    local max_tokens="${3:-$DEFAULT_MAX_TOKENS}"
    local temperature="${4:-$DEFAULT_TEMPERATURE}"
    local system_prompt="$5"
    local stream="${6:-false}"
    
    local payload
    payload=$(jq -n \
        --arg model "$model" \
        --argjson messages "$messages" \
        --arg max_tokens "$max_tokens" \
        --arg temperature "$temperature" \
        --arg stream "$stream" \
        --arg system "$system_prompt" \
        '{
            model: $model,
            messages: $messages,
            max_tokens: ($max_tokens | tonumber),
            temperature: ($temperature | tonumber),
            stream: ($stream | test("true"))
        } + (if $system != "" then {system: $system} else {} end)')
    
    echo "$payload"
}

# Send a message to Claude
claude_send_message() {
    local model="$1"
    local messages="$2"
    local max_tokens="${3:-$DEFAULT_MAX_TOKENS}"
    local temperature="${4:-$DEFAULT_TEMPERATURE}"
    local system_prompt="$5"
    
    # Validate configuration
    if ! claude_validate_config; then
        return 1
    fi
    
    # Create request payload
    local payload
    payload=$(claude_create_message_payload "$model" "$messages" "$max_tokens" "$temperature" "$system_prompt")
    
    # Log the request
    log_info "claude_send_message" "sending" "Sending message to model $model"
    
    # Make the API request
    local response
    if response=$(claude_api_request "messages" "POST" "$payload"); then
        log_info "claude_send_message" "success" "Message sent successfully"
        echo "$response"
        return 0
    else
        log_error "claude_send_message" "failed" "Failed to send message"
        return 1
    fi
}

# Send a streaming message to Claude
claude_send_message_stream() {
    local model="$1"
    local messages="$2"
    local max_tokens="${3:-$DEFAULT_MAX_TOKENS}"
    local temperature="${4:-$DEFAULT_TEMPERATURE}"
    local system_prompt="$5"
    local output_file="$6"  # Optional file to write stream to
    
    # Validate configuration
    if ! claude_validate_config; then
        return 1
    fi
    
    # Create request payload with streaming enabled
    local payload
    payload=$(claude_create_message_payload "$model" "$messages" "$max_tokens" "$temperature" "$system_prompt" "true")
    
    log_info "claude_send_message_stream" "starting" "Starting streaming message to model $model"
    
    # Make streaming request
    local temp_file
    temp_file=$(mktemp)
    
    if curl -s -N \
        -H "Content-Type: application/json" \
        -H "x-api-key: $CLAUDE_API_KEY" \
        -H "anthropic-version: $CLAUDE_API_VERSION" \
        -d "$payload" \
        "$CLAUDE_API_BASE_URL/messages" \
        -o "$temp_file"; then
        
        # Process streaming response
        if [[ -n "$output_file" ]]; then
            cp "$temp_file" "$output_file"
        fi
        
        cat "$temp_file"
        rm -f "$temp_file"
        log_info "claude_send_message_stream" "success" "Streaming message completed"
        return 0
    else
        rm -f "$temp_file"
        log_error "claude_send_message_stream" "failed" "Failed to stream message"
        return 1
    fi
}

# Parse Claude response and extract relevant information
claude_parse_response() {
    local response="$1"
    local extract_field="${2:-content}"  # content, usage, model, etc.
    
    case "$extract_field" in
        "content")
            echo "$response" | jq -r '.content[0].text // ""'
            ;;
        "input_tokens")
            echo "$response" | jq -r '.usage.input_tokens // 0'
            ;;
        "output_tokens")
            echo "$response" | jq -r '.usage.output_tokens // 0'
            ;;
        "total_tokens")
            local input_tokens output_tokens
            input_tokens=$(echo "$response" | jq -r '.usage.input_tokens // 0')
            output_tokens=$(echo "$response" | jq -r '.usage.output_tokens // 0')
            echo $((input_tokens + output_tokens))
            ;;
        "model")
            echo "$response" | jq -r '.model // ""'
            ;;
        "stop_reason")
            echo "$response" | jq -r '.stop_reason // ""'
            ;;
        "usage")
            echo "$response" | jq -c '.usage // {}'
            ;;
        *)
            echo "$response" | jq -r ".$extract_field // \"\""
            ;;
    esac
}

# Log cost information to database
claude_log_cost() {
    local agent_id="$1"
    local task_id="$2"
    local session_id="$3"
    local model="$4"
    local input_tokens="$5"
    local output_tokens="$6"
    local total_cost="$7"
    
    # Store cost record in PostgreSQL
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    _psql_query "INSERT INTO cost_records (agent_id, task_id, session_id, model_name, input_tokens, output_tokens, total_cost_usd, created_at) VALUES ('$agent_id', '$task_id', '$session_id', '$model', $input_tokens, $output_tokens, $total_cost, '$timestamp');" >/dev/null
    
    log_info "claude_cost_logging" "success" "Cost logged: $total_cost USD for $input_tokens input + $output_tokens output tokens"
}

# Complete Claude interaction with cost tracking
claude_complete_interaction() {
    local agent_id="$1"
    local task_id="$2"
    local session_id="$3"
    local model="$4"
    local messages="$5"
    local max_tokens="${6:-$DEFAULT_MAX_TOKENS}"
    local temperature="${7:-$DEFAULT_TEMPERATURE}"
    local system_prompt="$8"
    
    log_info "claude_complete_interaction" "starting" "Starting Claude interaction for agent $agent_id"
    
    # Send message to Claude
    local response
    if ! response=$(claude_send_message "$model" "$messages" "$max_tokens" "$temperature" "$system_prompt"); then
        return 1
    fi
    
    # Extract usage information
    local input_tokens output_tokens total_cost
    input_tokens=$(claude_parse_response "$response" "input_tokens")
    output_tokens=$(claude_parse_response "$response" "output_tokens")
    total_cost=$(claude_calculate_cost "$model" "$input_tokens" "$output_tokens")
    
    # Log cost information
    claude_log_cost "$agent_id" "$task_id" "$session_id" "$model" "$input_tokens" "$output_tokens" "$total_cost"
    
    # Return the response
    echo "$response"
    
    log_info "claude_complete_interaction" "success" "Claude interaction completed successfully"
    return 0
}

# Create a simple message array from text
claude_create_user_message() {
    local user_text="$1"
    jq -n --arg text "$user_text" '[{role: "user", content: $text}]'
}

# Create a conversation message array
claude_create_conversation() {
    local conversation_json="$1"  # Array of {role, content} objects
    echo "$conversation_json"
}

# Truncate content to fit context window
claude_truncate_content() {
    local model="$1"
    local content="$2"
    local max_tokens
    local content_tokens
    local truncated_content
    
    max_tokens=$(claude_get_context_window "$model")
    content_tokens=$(claude_estimate_tokens "$content")
    
    if [[ "$content_tokens" -le "$max_tokens" ]]; then
        echo "$content"
        return 0
    fi
    
    # Truncate to 90% of max tokens to leave room for response
    local target_tokens
    target_tokens=$((max_tokens * 9 / 10))
    local target_chars
    target_chars=$((target_tokens * 4))
    
    truncated_content="${content:0:$target_chars}"
    
    log_warning "claude_truncate_content" "truncated" "Content truncated from $content_tokens to ~$target_tokens tokens"
    echo "$truncated_content"
}

# Health check function
claude_health_check() {
    log_info "claude_health_check" "starting" "Performing Claude API health check"
    
    if ! claude_validate_config; then
        return 1
    fi
    
    # Send a simple test message
    local test_messages
    test_messages=$(claude_create_user_message "Hello, please respond with 'OK' if you are working properly.")
    
    local response
    if response=$(claude_send_message "$DEFAULT_MODEL" "$test_messages" "10" "0.1"); then
        local content
        content=$(claude_parse_response "$response" "content")
        
        if [[ "$content" =~ "OK" ]]; then
            log_info "claude_health_check" "success" "Claude API is healthy"
            return 0
        else
            log_warning "claude_health_check" "unexpected_response" "Unexpected response: $content"
            return 1
        fi
    else
        log_error "claude_health_check" "failed" "Health check failed"
        return 1
    fi
}

# Rate limiting helper
claude_apply_rate_limit() {
    sleep "$RATE_LIMIT_DELAY"
}

# Initialize library (validate dependencies)
claude_init() {
    # Check for required commands
    local required_commands=("curl" "jq" "bc")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            claude_error "Required command '$cmd' not found" 1
            return 1
        fi
    done
    
    log_info "claude_init" "success" "Claude library initialized successfully"
    return 0
}

# Legacy compatibility functions for existing hooks
claude_analyze() {
    local prompt="$1"
    local data="$2"
    
    if [[ -z "$data" ]]; then
        data=$(cat) # Read from stdin
    fi
    
    # Create messages array
    local full_prompt="$prompt\n\n$data"
    local messages
    messages=$(claude_create_user_message "$full_prompt")
    
    # Send to Claude and extract content
    local response
    if response=$(claude_send_message "$DEFAULT_MODEL" "$messages"); then
        claude_parse_response "$response" "content"
    else
        echo "Error: Claude analysis failed" >&2
        return 1
    fi
}

claude_get_json() {
    local prompt="$1"
    local data="$2"
    
    local full_prompt="RESPOND ONLY WITH VALID JSON. DO NOT include markdown code blocks or explanations. $prompt"
    
    local response
    response=$(claude_analyze "$full_prompt" "$data") || return 1
    
    # Strip any markdown formatting that might slip through
    response=$(echo "$response" | sed 's/```json//g' | sed 's/```//g' | sed 's/^[[:space:]]*//g')
    
    # Validate JSON
    if echo "$response" | jq . >/dev/null 2>&1; then
        echo "$response"
    else
        echo "Error: Invalid JSON response from Claude" >&2
        echo "Response was: $response" >&2
        return 1
    fi
}

# Specialized analysis functions for common hook patterns
claude_analyze_budget() {
    local agent_name="$1"
    local current_spend="$2" 
    local budget="$3"
    local recent_tasks="$4"
    
    claude_get_json "You are a financial advisor for an AI agent coordination system.
    
AGENT: $agent_name
CURRENT SPEND: \$${current_spend}
DAILY BUDGET: \$${budget} 
RECENT TASK COSTS: $recent_tasks

Analyze this spending situation and provide decision:
{
  \"allow_task\": true/false,
  \"reason\": \"brief explanation\",
  \"predicted_daily_spend\": estimated_number,
  \"risk_level\": \"low/medium/high\",
  \"recommendations\": [\"optimization suggestions\"]
}

Consider spending velocity, task patterns, cost efficiency." ""
}

claude_analyze_conflicts() {
    local objective="$1"
    local target_files="$2"
    local active_sessions="$3"
    local recent_changes="$4"
    
    claude_get_json "You are a coordination specialist preventing agent conflicts.

OBJECTIVE: $objective
TARGET FILES: $target_files
ACTIVE SESSIONS: $active_sessions  
RECENT CHANGES: $recent_changes

Analyze potential conflicts and risks:
{
  \"conflicts_detected\": true/false,
  \"risk_level\": \"low/medium/high\", 
  \"specific_risks\": [\"list of specific risks\"],
  \"recommendations\": [\"mitigation strategies\"],
  \"safe_to_proceed\": true/false,
  \"reasoning\": \"why safe or unsafe\"
}

Focus on resource conflicts, timing issues, and coordination problems." ""
}

claude_curate_context() {
    local objective="$1"
    local available_patterns="$2"
    local recent_solutions="$3"
    local dependencies="$4"
    
    claude_analyze "You are a context curator for AI agents. Select the most relevant context.

OBJECTIVE: $objective

AVAILABLE CONTEXT:
- Similar Patterns: $available_patterns
- Recent Solutions: $recent_solutions  
- Dependencies: $dependencies

Select and rank the top 3 most relevant context items for this objective.
Focus on: practical examples, gotchas, dependencies, best practices.
Explain why each item is relevant and how it should guide the agent." ""
}

claude_extract_patterns() {
    local objective="$1" 
    local diff_content="$2"
    
    claude_get_json "You are a software pattern recognition expert.

TASK OBJECTIVE: $objective

CODE CHANGES:
$diff_content

Extract meaningful, reusable code patterns from these changes:
{
  \"patterns\": [
    {
      \"name\": \"descriptive_name\", 
      \"type\": \"function/class/pattern/technique\",
      \"code_snippet\": \"key_code_example\",
      \"use_case\": \"when_to_use_this\",
      \"value_score\": 0.8,
      \"reusability\": \"high/medium/low\"
    }
  ]
}

Focus on genuinely reusable patterns, not one-off code." ""
}

claude_analyze_performance() {
    local metrics_data="$1"
    
    claude_analyze "You are a performance engineer analyzing an AI coordination system.

PERFORMANCE DATA:
$metrics_data

Analyze this data and provide:
1. **Performance Assessment**: What's working well? What's degrading?
2. **Bottleneck Identification**: Where are the main constraints?
3. **Optimization Opportunities**: Specific improvements to implement
4. **Risk Assessment**: What could break soon?
5. **Resource Planning**: Capacity and scaling recommendations

Provide 3 concrete, actionable optimization recommendations ranked by impact." ""
}

claude_validate_security() {
    local agent_input="$1"
    local operation_context="$2"
    
    claude_get_json "You are a cybersecurity expert analyzing AI agent requests.

INPUT TO VALIDATE: $agent_input
OPERATION CONTEXT: $operation_context

Analyze for security threats:
{
  \"safe\": true/false,
  \"risk_level\": \"low/medium/high\",
  \"threats_detected\": [
    {\"type\": \"injection/traversal/etc\", \"description\": \"what was found\"}
  ],
  \"sanitized_input\": \"cleaned_version_if_fixable\",
  \"recommendations\": [\"security_improvements\"]
}

Check for: SQL injection, path traversal, code injection, privilege escalation." ""
}

# Performance-optimized Claude calls with caching
claude_cached_analysis() {
    local cache_key="$1"
    local prompt="$2" 
    local data="$3"
    local cache_dir="$CLAUDE_PROJECT_DIR/.claude/cache"
    local cache_file="$cache_dir/${cache_key}.cache"
    
    mkdir -p "$cache_dir"
    
    # Check cache (valid for 1 hour)
    if [[ -f "$cache_file" ]] && [[ $(($(date +%s) - $(stat -c%Y "$cache_file" 2>/dev/null || stat -f%m "$cache_file" 2>/dev/null || echo 0))) -lt 3600 ]]; then
        cat "$cache_file"
        return 0
    fi
    
    # Generate new analysis and cache it
    local result
    if result=$(claude_analyze "$prompt" "$data"); then
        echo "$result" | tee "$cache_file"
        return 0
    else
        return 1
    fi
}

# System evolution analysis
claude_system_evolution() {
    local performance_data="$1"
    local error_patterns="$2"  
    local cost_trends="$3"
    local effectiveness_scores="$4"
    
    claude_analyze "You are the architect of the LevAIthan AI coordination system analyzing yourself for improvements.

SYSTEM PERFORMANCE DATA:
Performance Metrics: $performance_data
Error Patterns: $error_patterns  
Cost Trends: $cost_trends
Agent Effectiveness: $effectiveness_scores

As your own system architect, analyze and provide:

1. **System Health Assessment**: Overall performance evaluation
2. **Critical Issues**: What needs immediate attention?
3. **Optimization Opportunities**: Where can efficiency improve?
4. **Architecture Evolution**: What structural improvements would help?
5. **Learning Enhancement**: How can the system learn better?

Provide 3 specific, implementable improvements with:
- Description of the change
- Expected benefits  
- Implementation approach
- Risk assessment

Focus on changes that compound system intelligence over time." ""
}

# Error handling and fallback
claude_with_fallback() {
    local prompt="$1"
    local data="$2" 
    local fallback_value="$3"
    
    claude_analyze "$prompt" "$data" 2>/dev/null || {
        echo "Warning: Claude analysis failed, using fallback" >&2
        echo "$fallback_value"
    }
}

# Auto-initialize when sourced
if ! claude_init; then
    claude_error "Failed to initialize Claude library" 1
fi

# Export functions for use in other hooks
export -f claude_analyze claude_get_json claude_analyze_budget claude_analyze_conflicts
export -f claude_curate_context claude_extract_patterns claude_analyze_performance  
export -f claude_validate_security claude_cached_analysis claude_system_evolution claude_with_fallback
export -f claude_send_message claude_send_message_stream claude_parse_response claude_complete_interaction
export -f claude_create_user_message claude_create_conversation claude_truncate_content
export -f claude_calculate_cost claude_estimate_tokens claude_check_context_window claude_health_check