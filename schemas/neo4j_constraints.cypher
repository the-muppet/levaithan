// HelixDB Constraints Schema for LevAIthan Agent Coordination System
// This schema defines the graph database structure for agent coordination,
// task hierarchies, sessions, and knowledge pattern tracking.

// =============================================================================
// NODE CONSTRAINTS AND UNIQUE INDEXES
// =============================================================================

// Task Nodes - Core execution units in the system
CREATE CONSTRAINT task_id_unique IF NOT EXISTS 
FOR (t:Task) REQUIRE t.task_id IS UNIQUE;

CREATE CONSTRAINT task_id_not_null IF NOT EXISTS 
FOR (t:Task) REQUIRE t.task_id IS NOT NULL;

// Agent Nodes - AI agents operating within the system
CREATE CONSTRAINT agent_id_unique IF NOT EXISTS 
FOR (a:Agent) REQUIRE a.agent_id IS UNIQUE;

CREATE CONSTRAINT agent_id_not_null IF NOT EXISTS 
FOR (a:Agent) REQUIRE a.agent_id IS NOT NULL;

// Session Nodes - Agent execution sessions
CREATE CONSTRAINT session_id_unique IF NOT EXISTS 
FOR (s:Session) REQUIRE s.session_id IS UNIQUE;

CREATE CONSTRAINT session_id_not_null IF NOT EXISTS 
FOR (s:Session) REQUIRE s.session_id IS NOT NULL;

// Pattern Nodes - Knowledge patterns extracted from agent activities
CREATE CONSTRAINT pattern_id_unique IF NOT EXISTS 
FOR (p:Pattern) REQUIRE p.pattern_id IS UNIQUE;

CREATE CONSTRAINT pattern_id_not_null IF NOT EXISTS 
FOR (p:Pattern) REQUIRE p.pattern_id IS NOT NULL;

// Context Nodes - Contextual information and dependencies
CREATE CONSTRAINT context_id_unique IF NOT EXISTS 
FOR (c:Context) REQUIRE c.context_id IS UNIQUE;

// Resource Nodes - System resources (files, data, locks)
CREATE CONSTRAINT resource_id_unique IF NOT EXISTS 
FOR (r:Resource) REQUIRE r.resource_id IS UNIQUE;

// Human Nodes - Human supervisors and decision makers
CREATE CONSTRAINT human_id_unique IF NOT EXISTS 
FOR (h:Human) REQUIRE h.human_id IS UNIQUE;

// Decision Nodes - Governance and approval decisions
CREATE CONSTRAINT decision_id_unique IF NOT EXISTS 
FOR (d:Decision) REQUIRE d.decision_id IS UNIQUE;

// =============================================================================
// PERFORMANCE INDEXES
// =============================================================================

// Task indexes for common query patterns
CREATE INDEX task_status_idx IF NOT EXISTS 
FOR (t:Task) ON (t.status);

CREATE INDEX task_created_at_idx IF NOT EXISTS 
FOR (t:Task) ON (t.created_at);

CREATE INDEX task_priority_idx IF NOT EXISTS 
FOR (t:Task) ON (t.priority);

CREATE INDEX task_type_idx IF NOT EXISTS 
FOR (t:Task) ON (t.task_type);

// Agent indexes for coordination queries
CREATE INDEX agent_status_idx IF NOT EXISTS 
FOR (a:Agent) ON (a.status);

CREATE INDEX agent_type_idx IF NOT EXISTS 
FOR (a:Agent) ON (a.agent_type);

CREATE INDEX agent_created_at_idx IF NOT EXISTS 
FOR (a:Agent) ON (a.created_at);

// Session indexes for activity tracking
CREATE INDEX session_status_idx IF NOT EXISTS 
FOR (s:Session) ON (s.status);

CREATE INDEX session_started_at_idx IF NOT EXISTS 
FOR (s:Session) ON (s.started_at);

CREATE INDEX session_agent_task_idx IF NOT EXISTS 
FOR (s:Session) ON (s.agent_id, s.task_id);

// Pattern indexes for knowledge retrieval
CREATE INDEX pattern_type_idx IF NOT EXISTS 
FOR (p:Pattern) ON (p.pattern_type);

CREATE INDEX pattern_confidence_idx IF NOT EXISTS 
FOR (p:Pattern) ON (p.confidence_score);

CREATE INDEX pattern_created_at_idx IF NOT EXISTS 
FOR (p:Pattern) ON (p.created_at);

CREATE INDEX pattern_domain_idx IF NOT EXISTS 
FOR (p:Pattern) ON (p.domain);

// Context indexes for dependency resolution
CREATE INDEX context_type_idx IF NOT EXISTS 
FOR (c:Context) ON (c.context_type);

CREATE INDEX context_validity_idx IF NOT EXISTS 
FOR (c:Context) ON (c.valid_until);

// Resource indexes for lock management
CREATE INDEX resource_type_idx IF NOT EXISTS 
FOR (r:Resource) ON (r.resource_type);

CREATE INDEX resource_status_idx IF NOT EXISTS 
FOR (r:Resource) ON (r.status);

// Decision indexes for governance tracking
CREATE INDEX decision_type_idx IF NOT EXISTS 
FOR (d:Decision) ON (d.decision_type);

CREATE INDEX decision_status_idx IF NOT EXISTS 
FOR (d:Decision) ON (d.status);

CREATE INDEX decision_timestamp_idx IF NOT EXISTS 
FOR (d:Decision) ON (d.timestamp);

// =============================================================================
// COMPOSITE INDEXES FOR COMPLEX QUERIES
// =============================================================================

// Agent-Task-Session composite for coordination queries
CREATE INDEX agent_task_session_composite_idx IF NOT EXISTS 
FOR (s:Session) ON (s.agent_id, s.task_id, s.status);

// Task hierarchy navigation
CREATE INDEX task_parent_status_idx IF NOT EXISTS 
FOR (t:Task) ON (t.parent_task_id, t.status);

// Pattern evolution tracking
CREATE INDEX pattern_source_version_idx IF NOT EXISTS 
FOR (p:Pattern) ON (p.source_pattern_id, p.version);

// =============================================================================
// RELATIONSHIP TYPE DEFINITIONS
// Note: HelixDB doesn't require explicit relationship type creation,
// but documenting the expected relationship types for reference
// =============================================================================

/*
CORE COORDINATION RELATIONSHIPS:
- (Agent)-[:EXECUTES]->(Task) - Agent is assigned to execute a task
- (Agent)-[:CREATES]->(Session) - Agent creates an execution session
- (Session)-[:BELONGS_TO]->(Task) - Session is associated with a task
- (Task)-[:SUBTASK_OF]->(Task) - Task hierarchy relationships
- (Task)-[:DEPENDS_ON]->(Task) - Task dependencies
- (Task)-[:REQUIRES]->(Resource) - Task resource requirements

KNOWLEDGE RELATIONSHIPS:
- (Pattern)-[:DERIVED_FROM]->(Session) - Pattern extracted from session
- (Pattern)-[:EVOLVED_FROM]->(Pattern) - Pattern evolution chain
- (Pattern)-[:APPLIES_TO]->(Task) - Pattern applicable to task type
- (Context)-[:RELEVANT_TO]->(Task) - Context provides information for task
- (Context)-[:GENERATED_BY]->(Session) - Context created during session

GOVERNANCE RELATIONSHIPS:
- (Human)-[:SUPERVISES]->(Agent) - Human oversight of agent
- (Human)-[:APPROVES]->(Task) - Human approval of task execution
- (Decision)-[:AUTHORIZES]->(Task) - Decision permits task execution
- (Decision)-[:MADE_BY]->(Human) - Decision maker attribution
- (Agent)-[:REQUESTS_APPROVAL]->(Human) - Agent seeks human approval

RESOURCE RELATIONSHIPS:
- (Session)-[:LOCKS]->(Resource) - Session has exclusive access to resource
- (Task)-[:MODIFIES]->(Resource) - Task will modify resource
- (Agent)-[:ACCESSES]->(Resource) - Agent has permission to access resource

TEMPORAL RELATIONSHIPS:
- (Session)-[:PRECEDED_BY]->(Session) - Session ordering
- (Task)-[:TRIGGERED_BY]->(Task) - Task causation
- (Pattern)-[:SUPERSEDES]->(Pattern) - Pattern replacement
*/

// =============================================================================
// EXAMPLE NODE PROPERTY SCHEMAS
// =============================================================================

/*
Task Properties:
- task_id: string (unique identifier)
- task_type: string (task classification)
- status: string (pending, active, completed, failed)
- priority: integer (1-10, higher is more urgent)
- created_at: datetime
- started_at: datetime
- completed_at: datetime
- parent_task_id: string (for hierarchical tasks)
- description: string
- requirements: map (task-specific requirements)
- cost_budget_usd: float
- estimated_duration_minutes: integer

Agent Properties:
- agent_id: string (unique identifier)
- agent_type: string (coordination, execution, analysis)
- status: string (available, busy, offline, suspended)
- capabilities: list (what the agent can do)
- created_at: datetime
- last_active: datetime
- daily_budget_usd: float
- total_cost_usd: float
- success_rate: float

Session Properties:
- session_id: string (unique identifier)
- agent_id: string (foreign key to Agent)
- task_id: string (foreign key to Task)
- status: string (active, completed, failed, aborted)
- started_at: datetime
- ended_at: datetime
- cost_usd: float
- tool_calls: integer
- success: boolean
- error_message: string

Pattern Properties:
- pattern_id: string (unique identifier)
- pattern_type: string (behavioral, decision, outcome)
- domain: string (task domain the pattern applies to)
- description: string
- confidence_score: float (0.0-1.0)
- version: integer
- created_at: datetime
- source_pattern_id: string (for evolved patterns)
- usage_count: integer
- effectiveness_score: float

Context Properties:
- context_id: string (unique identifier)
- context_type: string (dependency, constraint, information)
- content: string or map
- valid_until: datetime
- priority: integer
- created_at: datetime
- source: string (where context came from)

Resource Properties:
- resource_id: string (unique identifier)
- resource_type: string (file, database, service, lock)
- path: string (file path or resource locator)
- status: string (available, locked, modified, deleted)
- locked_by_session: string (session holding lock)
- locked_at: datetime
- size_bytes: integer
- checksum: string

Human Properties:
- human_id: string (unique identifier)
- name: string
- role: string (supervisor, administrator, stakeholder)
- approval_level: integer (what they can approve)
- contact_info: map
- timezone: string
- active: boolean

Decision Properties:
- decision_id: string (unique identifier)
- decision_type: string (approval, rejection, modification)
- status: string (pending, approved, rejected)
- timestamp: datetime
- reasoning: string
- made_by_human: string (human_id)
- affects_task: string (task_id)
- conditions: map (any conditions attached to decision)
*/

// =============================================================================
// SCHEMA VALIDATION QUERIES
// =============================================================================

// Use these queries to validate the schema is properly applied:
// SHOW CONSTRAINTS;
// SHOW INDEXES;
// CALL db.schema.visualization();

// =============================================================================
// CLEANUP QUERIES (for development/testing)
// =============================================================================

// Uncomment and run these if you need to reset the schema during development:
// DROP CONSTRAINT task_id_unique IF EXISTS;
// DROP CONSTRAINT agent_id_unique IF EXISTS;
// DROP CONSTRAINT session_id_unique IF EXISTS;
// DROP CONSTRAINT pattern_id_unique IF EXISTS;
// DROP INDEX task_status_idx IF EXISTS;
// -- (add other DROP statements as needed)