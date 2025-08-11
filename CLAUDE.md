# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LevAIthan is an AI agent coordination system implementing a "Centaur Polis" model where AI agents operate as citizens under human sovereignty. The system uses a hook-based architecture with multiple databases for different aspects of agent coordination, governance, and knowledge management.

## Key Commands
[REQUESTING AGENTS](

### System Initialization and Setup
```bash
# Initialize environment
cp .env.template .env  # Configure with your settings
docker-compose up -d   # Start infrastructure services
./setup.sh            # Initialize databases and directories

# Run example task
./examples/run_task.sh

# Monitor system activity
tail -f .claude/logs/system.jsonl | jq .
```

### Database Operations
```bash
# Check PostgreSQL
psql $POSTGRES_DSN -c "SELECT * FROM tasks;"
psql $POSTGRES_DSN -c "SELECT * FROM agent_sessions;"

# Monitor Redis workflow state
redis-cli KEYS "wfe:*"

# View cost tracking
psql $POSTGRES_DSN -c "SELECT agent_id, SUM(total_cost_usd) FROM cost_records GROUP BY agent_id;"
```

### Testing Hooks
```bash
# Test individual atomic hooks
echo '{"event_type":"task_declaration",...}' | ./atomic/coord-create-session.sh

# Test workflows through orchestrator
cat test_envelope.json | ./.claude/hooks/orchestrator.sh

# Test with environment variables
CLAUDE_LOG_LEVEL=0 ./orchestrator.sh < test_envelope.json  # Debug mode
```

## Architecture Overview

### Core Components

1. **Orchestrator** (`orchestrator.sh`): Central dispatcher that routes events to appropriate workflows based on event_type

2. **Hook System**: Modular bash scripts organized as:
   - **Libraries** (`lib/`): Shared utilities for logging, data access, state management, and Claude API integration
   - **Atomic Hooks** (`atomic/`): Single-purpose functions (coord-*, governance-*, knowledge-*, cost-*, context-*)
   - **Workflows** (`workflows/`): Multi-step processes that compose atomic hooks

3. **Data Layer**: Polyglot persistence
   - **PostgreSQL**: Primary data store (tasks, sessions, locks, costs, governance)
   - **Redis**: Workflow execution state and Dead Letter Queue
   - **HelixDB**: Relationship graphs
   - **Weaviate**: Semantic search vectors
   - **Elasticsearch**: Activity logs
   - **Prometheus**: System metrics

### Agent Coordination Protocol (ACP)

Agents communicate via InteractionEnvelope JSON messages with required fields:
- protocol_version, agent_id, task_id, session_id
- event_type: "task_declaration", "activity_report", "completion_report"
- timestamp, payload

### Key Workflows

1. **Pre-Tool-Use** (`workflow-pre-tool-use.sh`):
   - Governance checks (ethics, budget, permissions)
   - Session creation and resource locking
   - Context injection
   - Final approval

2. **Post-Tool-Use** (`workflow-post-tool-use.sh`):
   - Cost calculation and logging
   - Knowledge extraction
   - Context effectiveness tracking
   - Resource cleanup

## Development Guidelines

### Adding New Atomic Hooks
1. Create in `.claude/hooks/atomic/` following naming: `category-action.sh`
2. Source required libraries: `logging.sh`, `data-access.sh`, `state.sh`
3. Read input from stdin (InteractionEnvelope JSON)
4. Log all operations with structured logging
5. Exit with appropriate codes (0=success, 1=failure, 101=system locked)

### Creating New Workflows
1. Create in `.claude/hooks/workflows/` as `workflow-name.sh`
2. Compose atomic hooks in logical sequence
3. Handle failures gracefully
4. Add case to orchestrator.sh for new event_type

### Error Handling
- All scripts use `set -e` for fail-fast behavior
- Orchestrator implements cleanup trap for state management
- Failed envelopes go to Redis Dead Letter Queue
- Use structured logging for debugging

### State Management
- Workflow state stored in Redis with `wfe:` prefix
- Use `state.sh` library functions for consistency
- State automatically cleaned up on workflow completion

## Important Environment Variables

Required in `.env`:
- `CLAUDE_PROJECT_DIR`: Base directory path
- `POSTGRES_DSN`: PostgreSQL connection string
- `REDIS_URL`: Redis connection URL
- `CLAUDE_LOG_LEVEL`: 0=DEBUG, 1=INFO, 2=WARNING, 3=ERROR, 4=CRITICAL

Key settings:
- `HUMAN_APPROVAL_REQUIRED`: Enable/disable human oversight
- `ETHICS_STRICT_MODE`: Enforce ethical constraints
- `DEFAULT_DAILY_BUDGET_USD`: Agent spending limit

## Security Considerations

- All database credentials should be in `.env` (never commit)
- Resource locking prevents concurrent file modifications
- Governance hooks enforce security policies
- Human approval gates for sensitive operations
- System lock file (`.system-lock`) for emergency stops

## Debugging Tips

- Enable debug logging: `CLAUDE_LOG_LEVEL=0`
- Check workflow state: `redis-cli HGETALL "wfe:$WORKFLOW_EXECUTION_ID:state"`
- View Dead Letter Queue: `redis-cli LRANGE "dlq:envelopes" 0 -1`
- Trace hook execution in logs: `grep "hook_name" system.jsonl`
- Validate InteractionEnvelope format before sending to orchestrator
