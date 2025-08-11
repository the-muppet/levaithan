# LevAIthan System: Organizational Structure

## 📋 Table of Contents

### 🎯 **Core Concepts** (Start Here)
1. [System Overview](#system-overview)
2. [Foundational Principles](#foundational-principles) 
3. [Key Analogies](#key-analogies)

### 🏗️ **Architecture**
4. [System Architecture](#system-architecture)
5. [Data Layer Design](#data-layer-design)
6. [Agent Coordination Protocol](#agent-coordination-protocol)

### 🔧 **Implementation**
7. [Code Structure](#code-structure)
8. [Hook System](#hook-system)
9. [Workflow Engine](#workflow-engine)

### 🚀 **Operations**
10. [Deployment Guide](#deployment-guide)
11. [System Bootstrap](#system-bootstrap)
12. [Maintenance & Evolution](#maintenance--evolution)

---

## System Overview

### The High-Level Vision
**"A self-governing ecosystem for autonomous AI agents under human sovereignty"**

- **Not** a simple automation framework
- **Is** a stateful, learning environment treating agents as citizens
- Operates under laws enforced by the hook system
- Human as sovereign authority providing strategic direction

### Core Value Proposition
Transform the human role from **tactical prompt engineer** to **strategic ecosystem gardener**:
- Set budgets and boundaries
- Review evolutionary suggestions  
- Provide wisdom for novel problems
- Cultivate system growth over time

---

## Foundational Principles

| Principle | Description | Implementation |
|-----------|-------------|----------------|
| **Human Sovereignty** | Human operator is ultimate authority | Dedicated CLI, approval gates, emergency stop |
| **Explicit Communication** | All agents follow Agent Coordination Protocol | Structured JSON envelopes, mandatory contracts |
| **Polyglot Data Layer** | Right database for the right job | PostgreSQL + HelixDB + Prometheus + Weaviate + Elasticsearch |
| **Evolution Focus** | System improves itself continuously | Performance logging, self-analysis, suggestion generation |
| **Governance First** | All actions gated by governance checks | Cost/Performance/Security checks before execution |

---

## Key Analogies

### The Centaur Model
- **Human provides**: Strategy, intuition, creativity, ethical judgment, high-level direction
- **AI provides**: Tactical calculation, memory, data processing, tireless execution
- **Result**: Combined entity more powerful than either component alone

### The Oracle Concept
Different system components act as "sources of truth" for specific domains:

| Oracle Type | Truth Domain | Example Questions |
|-------------|--------------|-------------------|
| Human Operator | Sovereign/Ethical | "Is this objective wise?" |
| Specialist AI | Architectural/Semantic | "Which design pattern is superior?" |
| Data Layer | Historical/Factual | "What's our budget? What failed last time?" |
| Test Suite | Correctness/Regression | "Did this change break anything?" |

---

## System Architecture

### 🏛️ Four-Layer Hook Architecture

```
┌─────────────────────────────────────┐
│           ORCHESTRATOR              │ ← Top-level workflow dispatch
├─────────────────────────────────────┤
│           WORKFLOWS                 │ ← Composable multi-step processes
├─────────────────────────────────────┤  
│         ATOMIC HOOKS                │ ← Single-purpose, testable functions
├─────────────────────────────────────┤
│           LIBRARIES                 │ ← Shared utilities (logging, data access)
└─────────────────────────────────────┘
```

### 🔄 Core System Capabilities

**Governance**: Cost, Performance, Security checks
**Coordination**: Session management, resource locking, conflict resolution
**Knowledge**: Pattern extraction, context injection, effectiveness tracking
**Evolution**: Performance analysis, suggestion generation, self-improvement

---

## Data Layer Design

### Multi-Database Strategy

| Database | Role | Primary Use Cases |
|----------|------|-------------------|
| **PostgreSQL** | Relational Cortex | Tasks, sessions, budgets, locks (ACID transactions) |
| **HelixDB** | Connective Cortex | Dependencies, relationships, delegation chains |
| **Prometheus** | Brainstem | Real-time metrics, performance monitoring |
| **Weaviate** | Conceptual Cortex | Semantic search, pattern similarity |
| **Elasticsearch** | Hippocampus | Full-text search, behavioral analysis |

### Data Flow Example
1. Task created → PostgreSQL (structured data)
2. Dependencies mapped → HelixDB (relationships)
3. Performance logged → Prometheus (metrics)
4. Patterns stored → Weaviate (semantic vectors)
5. Activity recorded → Elasticsearch (searchable logs)

---

## Agent Coordination Protocol (ACP)

### Required Agent Methods

| Method | Purpose | Triggers |
|--------|---------|----------|
| `declare_task()` | Announce objective before action | Pre-Tool-Use workflow |
| `report_activity()` | Report intermediate actions | Lightweight logging |
| `report_completion()` | Report final results | Post-Tool-Use workflow |
| `accept_context()` | Receive system-injected context | Context injection |
| `execute_heartbeat()` | Signal continued activity | Long-running task monitoring |

### InteractionEnvelope Structure
```json
{
  "protocol_version": "1.0",
  "agent_id": "frontend-v2",
  "task_id": "task_abc123",
  "session_id": "session_xyz789", 
  "event_type": "task_declaration",
  "timestamp": "2023-10-27T10:00:00Z",
  "payload": {
    "objective": "Add password reset button",
    "target_files": ["src/components/LoginForm.jsx"]
  }
}
```

---

## Code Structure

### Directory Layout
```
.claude/
├── hooks/
│   ├── lib/                    # Shared libraries
│   │   ├── logging.sh         # Structured logging
│   │   ├── data-access.sh     # Database abstraction layer
│   │   └── state.sh           # Redis state management
│   ├── atomic/                # Single-purpose hooks
│   │   ├── coord-*.sh         # Coordination functions
│   │   ├── cost-*.sh          # Cost management
│   │   ├── knowledge-*.sh     # Knowledge extraction
│   │   └── governance-*.sh    # Governance checks
│   ├── workflows/             # Multi-step processes
│   │   ├── workflow-pre-tool-use.sh
│   │   ├── workflow-post-tool-use.sh
│   │   └── workflow-self-improvement.sh
│   └── orchestrator.sh        # Main dispatcher
├── context/                   # Configuration & docs
├── db/                       # Database schemas
└── logs/                     # System logs
```

### Key Implementation Files

**Core Libraries** (Start here for implementation):
- `lib/logging.sh` - Structured JSON logging
- `lib/data-access.sh` - Unified database interface  
- `lib/state.sh` - Redis-based workflow state

**Critical Atomic Hooks**:
- `coord-acquire-lock.sh` - Resource conflict prevention
- `coord-create-session.sh` - Task/session initialization
- `cost-calculate-and-log.sh` - Financial tracking
- `knowledge-extract-from-diff.sh` - Pattern learning

**Essential Workflows**:
- `workflow-pre-tool-use.sh` - Governance & setup
- `workflow-post-tool-use.sh` - Cleanup & learning
- `workflow-self-improvement.sh` - Evolution engine

---

## Hook System Details

### Atomic Hook Categories

**Coordination Hooks** (`coord-*`):
- Session lifecycle management
- Resource locking/unlocking
- Conflict detection and resolution

**Governance Hooks** (`governance-*`):
- Budget enforcement
- Security permission checks
- Ethical guideline validation

**Knowledge Hooks** (`knowledge-*`):
- Pattern extraction from diffs
- Context effectiveness tracking
- Similarity-based retrieval

**Cost Hooks** (`cost-*`):
- Token usage calculation
- Budget tracking
- Financial reporting

### Workflow Composition Patterns

**Pre-Tool-Use Pattern**:
1. Governance gates (fail-fast)
2. Coordination setup
3. Context injection
4. Final approval

**Post-Tool-Use Pattern**:
1. Cost calculation
2. Knowledge extraction
3. Effectiveness tracking
4. Resource cleanup

---

## Deployment Guide

### Infrastructure Requirements

**Docker Services**:
```yaml
services:
  postgres:     # Primary data store
  HelixDB:        # Relationship mapping  
  prometheus:   # Metrics collection
  weaviate:     # Semantic search
  elasticsearch: # Activity logging
  redis:        # Workflow state
```

**Environment Setup**:
1. Run `docker-compose up -d` for backend services
2. Execute `setup.sh` for initialization
3. Run `workflow-genesis.sh` to prime knowledge base

### Configuration Files

**Required Context Files**:
- `system-charter.yaml` - Core principles and directives
- `agent-permissions.yaml` - Security policies
- `budget-allocations.yaml` - Financial constraints

---

## Implementation Roadmap

### Phase 1: Foundation (Weeks 1-2)
- [ ] Set up polyglot database stack
- [ ] Implement core libraries (logging, data-access, state)
- [ ] Create basic atomic hooks for coordination
- [ ] Build simple pre/post-tool-use workflows

### Phase 2: Protocol (Weeks 3-4)  
- [ ] Define and test InteractionEnvelope format
- [ ] Implement agent coordination protocol
- [ ] Add governance and security hooks
- [ ] Create orchestrator dispatch logic

### Phase 3: Intelligence (Weeks 5-6)
- [ ] Build knowledge extraction system
- [ ] Implement context injection mechanisms
- [ ] Add cost tracking and budget enforcement
- [ ] Create effectiveness feedback loops

### Phase 4: Evolution (Weeks 7-8)
- [ ] Implement self-improvement workflows
- [ ] Add suggestion generation via Claude integration
- [ ] Build human approval and correction interfaces
- [ ] Create maintenance and optimization cycles

### Phase 5: Advanced Features (Weeks 9-12)
- [ ] Delegation and sub-task management
- [ ] Complex dependency tracking
- [ ] Advanced behavioral analysis
- [ ] Production hardening and monitoring

---

## Next Steps

### Immediate Actions (This Week)
1. **Set up development environment**: Docker, databases, directory structure
2. **Implement core libraries**: Start with `logging.sh` and `data-access.sh`
3. **Create basic atomic hooks**: Focus on coordination functions first
4. **Design and test InteractionEnvelope**: Nail down the protocol format

### Medium-term Goals (Next Month)
1. **Build functional workflows**: Get pre/post-tool-use cycles working
2. **Integrate with real agents**: Test protocol compliance
3. **Add governance layers**: Implement basic safety and cost controls
4. **Start knowledge accumulation**: Begin pattern extraction and learning

### Long-term Vision (3-6 Months)
1. **Achieve system autonomy**: Minimal human intervention for routine tasks
2. **Demonstrate evolution**: System suggests and implements improvements
3. **Scale coordination**: Handle complex multi-agent collaborations
4. **Prove the centaur model**: Human+AI partnership exceeds either alone

---

## Key Success Metrics

- **Coordination Efficiency**: Reduction in agent conflicts and resource contention
- **Learning Velocity**: Rate of pattern extraction and knowledge accumulation  
- **Cost Optimization**: Budget adherence and spend efficiency improvements
- **Human Satisfaction**: Reduced micromanagement, increased strategic focus
- **System Reliability**: Uptime, error rates, recovery capabilities

---

*This document serves as the master organizational framework for the LevAIthan system. Each section should be expanded into detailed implementation guides as development progresses.*