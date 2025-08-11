#!/bin/bash
# lib/state.sh - Unified interface for managing workflow state in Redis.

if [[ -z "$WORKFLOW_EXECUTION_ID" ]]; then echo "FATAL: WORKFLOW_EXECUTION_ID not set." >&2; exit 1; fi
REDIS_KEY="wfe:$WORKFLOW_EXECUTION_ID"

state_set() { redis-cli HSET "$REDIS_KEY" "$1" "$2" >/dev/null; }
state_get() { redis-cli HGET "$REDIS_KEY" "$1"; }
state_init() { redis-cli HSET "$REDIS_KEY" "start_time" "$(date +%s)" >/dev/null; redis-cli EXPIRE "$REDIS_KEY" 3600; }
state_destroy() { redis-cli DEL "$REDIS_KEY" >/dev/null; }
