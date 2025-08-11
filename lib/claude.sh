#!/bin/bash
# Claude API Integration Library
# Purpose: Provides functions for interacting with Claude via the CLI
# Dependencies: claude CLI tool, jq, lib/logging.sh, lib/error-handling.sh

set -e

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/logging.sh" || { echo "ERROR: Failed to source logging.sh"; exit 1; }
source "${SCRIPT_DIR}/error-handling.sh" || { echo "ERROR: Failed to source error-handling.sh"; exit 1; }

# Configuration
CLAUDE_MAX_RETRIES="${CLAUDE_MAX_RETRIES:-3}"
CLAUDE_RETRY_DELAY="${CLAUDE_RETRY_DELAY:-2}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-300}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-3-sonnet-20240229}"

# Initialize Claude session
claude_init() {
    local session_id=$1
    
    log_info "Initializing Claude session" "{\"session_id\":\"$session_id\"}"
    
    # Verify claude CLI is available
    if ! command -v claude &> /dev/null; then
        handle_error "ERR_CLAUDE_NOT_FOUND" "Claude CLI not found in PATH"
        return 1
    fi
    
    # Test claude connectivity
    if ! timeout 10 claude --version &> /dev/null; then
        handle_error "ERR_CLAUDE_UNREACHABLE" "Claude CLI not responding"
        return 1
    fi
    
    log_info "Claude session initialized successfully" "{\"session_id\":\"$session_id\"}"
    return 0
}

# Send a message to Claude with retry logic
claude_send_message() {
    local message=$1
    local context=$2
    local session_id=$3
    local attempt=1
    local response=""
    
    # Validate inputs
    if [[ -z "$message" ]]; then
        handle_error "ERR_INVALID_INPUT" "Message cannot be empty"
        return 1
    fi
    
    # Prepare the full prompt with context
    local full_prompt=""
    if [[ -n "$context" ]]; then
        full_prompt="Context:\n${context}\n\nRequest:\n${message}"
    else
        full_prompt="$message"
    fi
    
    # Retry loop
    while [[ $attempt -le $CLAUDE_MAX_RETRIES ]]; do
        log_debug "Sending message to Claude" "{\"session_id\":\"$session_id\",\"attempt\":$attempt}"
        
        # Execute claude command with timeout
        if response=$(echo -e "$full_prompt" | timeout "$CLAUDE_TIMEOUT" claude --model "$CLAUDE_MODEL" 2>&1); then
            # Success
            log_info "Claude response received" "{\"session_id\":\"$session_id\",\"response_length\":${#response}}"
            echo "$response"
            return 0
        else
            local exit_code=$?
            log_warn "Claude request failed" "{\"session_id\":\"$session_id\",\"attempt\":$attempt,\"exit_code\":$exit_code}"
            
            # Check if it's a timeout
            if [[ $exit_code -eq 124 ]]; then
                handle_error "ERR_CLAUDE_TIMEOUT" "Claude request timed out after ${CLAUDE_TIMEOUT}s"
            fi
            
            # Retry with exponential backoff
            if [[ $attempt -lt $CLAUDE_MAX_RETRIES ]]; then
                local delay=$((CLAUDE_RETRY_DELAY * attempt))
                log_info "Retrying Claude request" "{\"session_id\":\"$session_id\",\"delay\":$delay}"
                sleep $delay
            fi
        fi
        
        ((attempt++))
    done
    
    handle_error "ERR_CLAUDE_MAX_RETRIES" "Failed after $CLAUDE_MAX_RETRIES attempts"
    return 1
}

# Parse Claude response for structured data
claude_parse_response() {
    local response=$1
    local extract_type=$2  # json, code, text
    
    case "$extract_type" in
        json)
            # Extract JSON blocks from response
            echo "$response" | sed -n '/```json/,/```/p' | sed '1d;$d'
            ;;
        code)
            # Extract code blocks from response
            echo "$response" | sed -n '/```/,/```/p' | sed '1d;$d'
            ;;
        text)
            # Return raw text
            echo "$response"
            ;;
        *)
            handle_error "ERR_INVALID_EXTRACT_TYPE" "Unknown extract type: $extract_type"
            return 1
            ;;
    esac
}

# Estimate token usage for a message
claude_estimate_tokens() {
    local text=$1
    # Rough estimation: ~4 characters per token
    local char_count=${#text}
    local estimated_tokens=$((char_count / 4))
    echo $estimated_tokens
}

# Calculate estimated cost for a Claude request
claude_calculate_cost() {
    local input_tokens=$1
    local output_tokens=$2
    local model=${3:-$CLAUDE_MODEL}
    
    # Cost per 1K tokens (example rates, adjust based on actual pricing)
    local input_cost_per_1k=0.003
    local output_cost_per_1k=0.015
    
    # Calculate costs
    local input_cost=$(echo "scale=6; $input_tokens * $input_cost_per_1k / 1000" | bc)
    local output_cost=$(echo "scale=6; $output_tokens * $output_cost_per_1k / 1000" | bc)
    local total_cost=$(echo "scale=6; $input_cost + $output_cost" | bc)
    
    # Return as JSON
    echo "{\"input_cost\":$input_cost,\"output_cost\":$output_cost,\"total_cost\":$total_cost,\"model\":\"$model\"}"
}

# Stream response from Claude (for long-running tasks)
claude_stream_response() {
    local message=$1
    local session_id=$2
    local callback_func=$3  # Function to call with each chunk
    
    # Note: This is a placeholder for streaming functionality
    # Actual implementation would depend on Claude CLI capabilities
    log_warn "Streaming not yet implemented, falling back to standard request" "{\"session_id\":\"$session_id\"}"
    
    local response
    if response=$(claude_send_message "$message" "" "$session_id"); then
        # Call callback with full response
        if [[ -n "$callback_func" ]] && declare -f "$callback_func" > /dev/null; then
            $callback_func "$response"
        fi
        echo "$response"
        return 0
    fi
    
    return 1
}

# Validate Claude response format
claude_validate_response() {
    local response=$1
    local expected_format=$2  # json, code, ack
    
    case "$expected_format" in
        json)
            # Check if response contains valid JSON
            if echo "$response" | grep -q '```json' && echo "$response" | grep -q '```'; then
                local json_content
                json_content=$(claude_parse_response "$response" "json")
                if echo "$json_content" | jq . > /dev/null 2>&1; then
                    return 0
                fi
            fi
            ;;
        code)
            # Check if response contains code blocks
            if echo "$response" | grep -q '```'; then
                return 0
            fi
            ;;
        ack)
            # Check if response acknowledges the request
            if [[ -n "$response" ]] && [[ ${#response} -gt 10 ]]; then
                return 0
            fi
            ;;
        *)
            return 0  # No specific validation
            ;;
    esac
    
    log_warn "Response validation failed" "{\"expected_format\":\"$expected_format\"}"
    return 1
}

# Helper function to format system prompts
claude_format_system_prompt() {
    local role=$1
    local constraints=$2
    local context=$3
    
    cat <<EOF
You are acting as a $role within the LevAIthan system.

System Constraints:
$constraints

Current Context:
$context

Please respond in a structured format appropriate for automated processing.
EOF
}

# Export functions
export -f claude_init
export -f claude_send_message
export -f claude_parse_response
export -f claude_estimate_tokens
export -f claude_calculate_cost
export -f claude_stream_response
export -f claude_validate_response
export -f claude_format_system_prompt