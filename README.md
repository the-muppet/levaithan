# LevAIthan: AI Coordination Sovereign 🔱

## Overview
How to prevent AI chaos by creating a digital commonwealth where AI agents operate as citizens under human sovereignty through constitutional governance and Oracle authority.
This project seeks to answer "at what point does a complex enough automation system become indistinguishable from intelligence?"

## Quick Start

### 1. Environment Setup
```bash
# Copy environment template
cp .env.template .env
# Edit .env with your configuration

# Start infrastructure services
docker-compose up -d

# Initialize system
./setup.sh
```

### 2. Test the System
```bash
# Run example task
./examples/run_task.sh

# Monitor system
tail -f .claude/logs/system.jsonl
```

## Architecture

📊 **Visual Documentation**: 
- [📋 Quick Reference](docs/quick-reference.md) - Key concepts at a glance
- [🏗️ Architecture Diagrams](docs/architecture-diagrams.md) - Detailed system design
- [🔄 Data Flow Diagrams](docs/data-flow-diagrams.md) - How information moves through the system

### Core Components

- **Orchestrator**: Central workflow dispatcher (`orchestrator.sh`)
- **Hook System**: Modular, composable functions
  - **Libraries**: Shared utilities (`lib/`)
  - **Atomic Hooks**: Single-purpose functions (`atomic/`)
  - **Workflows**: Multi-step processes (`workflows/`)
- **Data Layer**: Polyglot persistence (PostgreSQL + HelixDB + Weaviate + Elasticsearch + Prometheus + Redis)
- **Agent Protocol**: Formal communication standard (ACP)

### Key Features

- **Resource Locking**: Prevents agent conflicts
- **Cost Tracking**: Monitors AI API usage and costs
- **Context Injection**: Provides relevant knowledge to agents
- **Self-Improvement**: System analyzes and evolves itself
- **Human Oversight**: Sovereign control with approval workflows

## Directory Structure

```
LevAIthan/
├── docker-compose.yml              # Infrastructure services
├── setup.sh                       # System initialization
├── .env.template                   # Configuration template
├── .claude/
│   ├── hooks/
│   │   ├── lib/                   # Core libraries
│   │   │   ├── logging.sh
│   │   │   ├── data-access.sh
│   │   │   └── state.sh
│   │   ├── atomic/                # Single-purpose hooks
│   │   │   ├── coord-*.sh        # Coordination functions
│   │   │   ├── cost-*.sh         # Cost management
│   │   │   ├── governance-*.sh   # Policy enforcement
│   │   │   └── knowledge-*.sh    # Learning functions
│   │   ├── workflows/            # Multi-step processes
│   │   │   ├── workflow-pre-tool-use.sh
│   │   │   ├── workflow-post-tool-use.sh
│   │   │   └── workflow-*.sh
│   │   └── orchestrator.sh       # Main dispatcher
│   └── context/
│       └── system-charter.yaml   # Governance rules
├── schemas/
│   └── postgres_schema.sql       # Database schema
└── examples/
    └── run_task.sh               # Test agent interaction
```

## Agent Coordination Protocol (ACP)

Agents must implement these methods and use structured messages:

### Required Agent Methods
- `declare_task()` - Announce objectives
- `report_activity()` - Report intermediate actions  
- `report_completion()` - Report final results
- `accept_context()` - Receive system context
- `execute_heartbeat()` - Signal continued activity

### Message Format (InteractionEnvelope)
```json
{
  "protocol_version": "1.0",
  "agent_id": "agent-name",
  "task_id": "task_123",
  "session_id": "session_456", 
  "event_type": "task_declaration",
  "timestamp": "2023-10-27T10:00:00Z",
  "payload": {
    "objective": "Task description",
    "target_files": ["file1.js", "file2.py"]
  }
}
```

## Workflow Lifecycle

### 1. Task Declaration
Agent sends `task_declaration` → Pre-Tool-Use workflow runs:
- Ethics/budget/security checks
- Session creation and resource locking
- Context injection
- Final approval

### 2. Agent Execution
Agent performs work, periodically sending `activity_report` events

### 3. Task Completion
Agent sends `completion_report` → Post-Tool-Use workflow runs:
- Cost calculation and logging
- Knowledge extraction from results
- Context effectiveness tracking
- Resource cleanup

## Key Atomic Hooks

### Coordination
- `coord-create-session.sh` - Initialize task/session
- `coord-acquire-lock.sh` - Prevent resource conflicts
- `coord-release-lock.sh` - Clean up resources
- `coord-close-session.sh` - Finalize session

### Governance
- `governance-check-ethics.sh` - Ethical compliance
- `governance-check-budget.sh` - Cost limits
- `governance-check-permissions.sh` - Security policies

### Knowledge Management
- `knowledge-extract-from-diff.sh` - Learn from code changes
- `context-update-effectiveness.sh` - Track context quality

### Cost Management
- `cost-calculate-and-log.sh` - Track AI usage costs

## Data Layer

### PostgreSQL (Primary Store)
- Tasks, sessions, resource locks
- Cost records, budgets
- Context injections, suggestions
- Human feedback, chronicle events

### HelixDB (Relationships)
- Agent-task-file dependencies
- Delegation hierarchies
- Pattern relationships

### Weaviate (Semantic Search)
- Code pattern vectors
- Objective similarity matching

### Elasticsearch (Activity Logs)  
- Full-text searchable agent activity
- Behavioral analysis and debugging

### Prometheus (Metrics)
- Real-time performance monitoring
- Hook execution times, error rates

### Redis (Workflow State)
- Temporary workflow coordination state
- Session management

## Development

### Adding New Hooks
1. Create atomic hook in `atomic/`
2. Follow naming convention: `category-action.sh`
3. Use standard libraries (`logging.sh`, `data-access.sh`)
4. Include proper error handling and logging

### Creating Workflows
1. Compose atomic hooks in logical sequence
2. Handle failures gracefully
3. Use state management for hook coordination
4. Add to orchestrator dispatch logic

### Testing
```bash
# Test individual hooks
./atomic/coord-create-session.sh < test_envelope.json

# Test workflows
echo '{"event_type":"task_declaration",...}' | ./orchestrator.sh

# Validate database state
psql $POSTGRES_DSN -c "SELECT * FROM tasks;"
```

## Production Deployment

### Prerequisites
- Docker & Docker Compose
- PostgreSQL 15+
- 8GB+ RAM recommended
- Claude API access

### Security Checklist
- [ ] Change default passwords
- [ ] Configure network security
- [ ] Set up backup procedures
- [ ] Review ethical directives
- [ ] Test emergency stop procedures

### Monitoring
- Grafana dashboards for system metrics
- Log aggregation via Elasticsearch
- Cost monitoring and alerting
- Performance anomaly detection

## Troubleshooting

### Common Issues

**Workflow Failures**
- Check `system.jsonl` logs
- Verify database connectivity
- Confirm environment variables

**Agent Integration**
- Validate InteractionEnvelope format
- Check ACP method implementations
- Review protocol compliance

**Performance Issues**
- Monitor database query performance
- Check Redis memory usage
- Review hook execution times

### Debug Commands
```bash
# View recent system activity
tail -f .claude/logs/system.jsonl | jq .

# Check database status
docker-compose ps

# Monitor Redis state
redis-cli KEYS "wfe:*"

# Review cost records
psql $POSTGRES_DSN -c "SELECT agent_id, SUM(total_cost_usd) FROM cost_records GROUP BY agent_id;"
```

## Contributing

1. Follow bash scripting best practices
2. Include comprehensive error handling
3. Add structured logging to all hooks
4. Write tests for new functionality
5. Update documentation

## License

[Your chosen license]

## Support

For issues and questions:
- Review troubleshooting section
- Check system logs in `.claude/logs/`
- Examine database state via PostgreSQL
- Test individual components in isolation

---
