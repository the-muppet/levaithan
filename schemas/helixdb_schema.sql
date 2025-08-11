-- HelixDB Schema for LevAIthan AI Agent Coordination System
-- Graph-Vector Hybrid Database Schema
-- Combines graph relationships with vector embeddings for semantic search
--
-- This schema leverages HelixDB's unique ability to perform both graph operations
-- and vector operations in the same query, enabling:
-- - Graph traversals for task hierarchies and agent relationships
-- - Vector similarity searches for semantic matching
-- - Hybrid queries combining both approaches
-- - Traditional filtering for status/timestamp queries

-- =============================================================================
-- GRAPH NODES WITH VECTOR EMBEDDINGS
-- =============================================================================

-- Tasks - Core execution units with semantic embeddings
CREATE NODE TYPE Task (
    task_id TEXT PRIMARY KEY,
    parent_task_id TEXT,
    objective TEXT NOT NULL,
    description TEXT,
    task_type TEXT DEFAULT 'general',
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'delegated', 'completed', 'failed', 'cancelled')),
    priority INTEGER DEFAULT 5 CHECK (priority BETWEEN 1 AND 10),
    created_by TEXT NOT NULL,
    assigned_to TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    cost_budget_usd DECIMAL(10,2),
    estimated_duration_minutes INTEGER,
    requirements JSONB,
    
    -- Vector embeddings for semantic search
    objective_embedding VECTOR(1536),  -- OpenAI ada-002 embedding for objective
    context_embedding VECTOR(1536),    -- Contextual understanding embedding
    outcome_embedding VECTOR(1536)     -- Success/failure pattern embedding
);

-- Agents - AI agents with capability vectors
CREATE NODE TYPE Agent (
    agent_id TEXT PRIMARY KEY,
    agent_type TEXT DEFAULT 'execution' CHECK (agent_type IN ('coordination', 'execution', 'analysis', 'governance')),
    status TEXT DEFAULT 'available' CHECK (status IN ('available', 'busy', 'offline', 'suspended')),
    capabilities TEXT[] DEFAULT '{}',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_active TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    daily_budget_usd DECIMAL(10,2),
    total_cost_usd DECIMAL(10,2) DEFAULT 0,
    success_rate DECIMAL(3,2) DEFAULT 0.5,
    total_tasks_completed INTEGER DEFAULT 0,
    
    -- Vector embeddings for agent matching
    capability_embedding VECTOR(1536), -- Agent capabilities as vector
    behavior_embedding VECTOR(1536),   -- Behavioral patterns
    expertise_embedding VECTOR(1536)   -- Domain expertise vector
);

-- Sessions - Agent execution sessions with context embeddings
CREATE NODE TYPE Session (
    session_id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'approved_for_execution', 'active', 'completed', 'failed')),
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_heartbeat TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ended_at TIMESTAMP,
    cost_usd DECIMAL(10,8) DEFAULT 0,
    tool_calls INTEGER DEFAULT 0,
    success BOOLEAN,
    error_message TEXT,
    
    -- Vector embeddings for session analysis
    execution_context_embedding VECTOR(1536), -- Session execution context
    performance_embedding VECTOR(1536),       -- Performance characteristics
    outcome_embedding VECTOR(1536)            -- Session outcome patterns
);

-- Patterns - Knowledge patterns with semantic vectors
CREATE NODE TYPE Pattern (
    pattern_id TEXT PRIMARY KEY,
    pattern_signature TEXT UNIQUE NOT NULL,
    pattern_name TEXT,
    pattern_type TEXT NOT NULL CHECK (pattern_type IN ('behavioral', 'decision', 'outcome', 'code', 'workflow')),
    pattern_content TEXT,
    domain TEXT,
    use_case TEXT,
    value_score DECIMAL(3,2) DEFAULT 0.5 CHECK (value_score BETWEEN 0 AND 1),
    confidence_score DECIMAL(3,2) DEFAULT 0.5 CHECK (confidence_score BETWEEN 0 AND 1),
    usage_count INTEGER DEFAULT 1,
    effectiveness_score DECIMAL(3,2) DEFAULT 0.5,
    version INTEGER DEFAULT 1,
    source_pattern_id TEXT,
    agent_id TEXT,
    task_id TEXT,
    reviewed BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    -- Vector embeddings for pattern matching
    semantic_embedding VECTOR(1536),    -- Semantic meaning of pattern
    context_embedding VECTOR(1536),     -- Usage context
    structure_embedding VECTOR(1536)    -- Structural characteristics
);

-- Context - Contextual information with semantic embeddings
CREATE NODE TYPE Context (
    context_id TEXT PRIMARY KEY,
    context_type TEXT NOT NULL CHECK (context_type IN ('dependency', 'constraint', 'information', 'guidance', 'historical')),
    content TEXT,
    metadata JSONB,
    valid_until TIMESTAMP,
    priority INTEGER DEFAULT 5 CHECK (priority BETWEEN 1 AND 10),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    source TEXT,
    effectiveness_score DECIMAL(3,2) CHECK (effectiveness_score BETWEEN 0 AND 1),
    
    -- Vector embeddings for context matching
    semantic_embedding VECTOR(1536),    -- Semantic content
    relevance_embedding VECTOR(1536)    -- Contextual relevance patterns
);

-- Resources - System resources with access patterns
CREATE NODE TYPE Resource (
    resource_id TEXT PRIMARY KEY,
    resource_type TEXT NOT NULL CHECK (resource_type IN ('file', 'database', 'service', 'lock', 'api')),
    path TEXT NOT NULL,
    status TEXT DEFAULT 'available' CHECK (status IN ('available', 'locked', 'modified', 'deleted', 'corrupted')),
    locked_by_session TEXT,
    locked_at TIMESTAMP,
    size_bytes BIGINT,
    checksum TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_accessed TIMESTAMP,
    
    -- Vector embeddings for resource similarity
    content_embedding VECTOR(1536),     -- Resource content characteristics
    usage_pattern_embedding VECTOR(1536) -- Usage pattern vector
);

-- Humans - Human supervisors and decision makers
CREATE NODE TYPE Human (
    human_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    role TEXT DEFAULT 'supervisor' CHECK (role IN ('supervisor', 'administrator', 'stakeholder', 'reviewer')),
    approval_level INTEGER DEFAULT 1 CHECK (approval_level BETWEEN 1 AND 10),
    contact_info JSONB,
    timezone TEXT DEFAULT 'UTC',
    active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_active TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    -- Vector embeddings for decision patterns
    decision_pattern_embedding VECTOR(1536), -- Historical decision patterns
    expertise_embedding VECTOR(1536)         -- Domain expertise
);

-- Decisions - Governance and approval decisions
CREATE NODE TYPE Decision (
    decision_id TEXT PRIMARY KEY,
    decision_type TEXT NOT NULL CHECK (decision_type IN ('approval', 'rejection', 'modification', 'budget_check', 'security_check', 'conflict_check')),
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'implemented')),
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    reasoning TEXT,
    made_by_human TEXT,
    affects_task TEXT,
    risk_level TEXT CHECK (risk_level IN ('low', 'medium', 'high', 'critical')),
    conditions JSONB,
    context_data JSONB,
    
    -- Vector embeddings for decision analysis
    reasoning_embedding VECTOR(1536),   -- Decision reasoning patterns
    context_embedding VECTOR(1536)      -- Decision context
);

-- Knowledge Artifacts - Extracted knowledge with semantic vectors
CREATE NODE TYPE KnowledgeArtifact (
    artifact_id TEXT PRIMARY KEY,
    artifact_type TEXT NOT NULL CHECK (artifact_type IN ('insight', 'solution', 'best_practice', 'anti_pattern', 'procedure')),
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    summary TEXT,
    domain TEXT,
    confidence_score DECIMAL(3,2) DEFAULT 0.5 CHECK (confidence_score BETWEEN 0 AND 1),
    usage_count INTEGER DEFAULT 0,
    created_by_agent TEXT,
    extracted_from_session TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    -- Vector embeddings for knowledge retrieval
    content_embedding VECTOR(1536),     -- Full content semantic embedding
    summary_embedding VECTOR(1536),     -- Summary embedding for quick matching
    domain_embedding VECTOR(1536)       -- Domain-specific embedding
);

-- =============================================================================
-- GRAPH RELATIONSHIPS
-- =============================================================================

-- Task Hierarchy and Dependencies
CREATE EDGE TYPE SUBTASK_OF (
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    dependency_type TEXT DEFAULT 'hierarchical' CHECK (dependency_type IN ('hierarchical', 'sequential', 'parallel'))
);

CREATE EDGE TYPE DEPENDS_ON (
    dependency_type TEXT NOT NULL CHECK (dependency_type IN ('data', 'completion', 'approval', 'resource')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resolved_at TIMESTAMP
);

-- Agent-Task-Session Relationships
CREATE EDGE TYPE EXECUTES (
    assigned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    priority INTEGER DEFAULT 5,
    expected_completion TIMESTAMP
);

CREATE EDGE TYPE CREATES_SESSION (
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_purpose TEXT
);

CREATE EDGE TYPE BELONGS_TO_TASK (
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_role TEXT DEFAULT 'primary' CHECK (session_role IN ('primary', 'support', 'monitoring'))
);

-- Knowledge and Pattern Relationships
CREATE EDGE TYPE DERIVES_FROM (
    extraction_confidence DECIMAL(3,2) DEFAULT 0.5,
    extracted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE EDGE TYPE EVOLVES_FROM (
    evolution_type TEXT NOT NULL CHECK (evolution_type IN ('refinement', 'generalization', 'specialization', 'adaptation')),
    similarity_score DECIMAL(3,2),
    evolved_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE EDGE TYPE APPLIES_TO (
    applicability_score DECIMAL(3,2) DEFAULT 0.5,
    applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    effectiveness_score DECIMAL(3,2)
);

CREATE EDGE TYPE SIMILAR_TO (
    similarity_score DECIMAL(3,2) NOT NULL CHECK (similarity_score BETWEEN 0 AND 1),
    similarity_type TEXT DEFAULT 'semantic' CHECK (similarity_type IN ('semantic', 'structural', 'behavioral', 'contextual')),
    computed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Context and Resource Relationships
CREATE EDGE TYPE RELEVANT_TO (
    relevance_score DECIMAL(3,2) DEFAULT 0.5,
    context_type TEXT,
    valid_until TIMESTAMP
);

CREATE EDGE TYPE REQUIRES_RESOURCE (
    access_type TEXT NOT NULL CHECK (access_type IN ('read', 'write', 'execute', 'lock')),
    required_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE EDGE TYPE LOCKS_RESOURCE (
    locked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    lock_type TEXT DEFAULT 'exclusive' CHECK (lock_type IN ('shared', 'exclusive', 'intent'))
);

-- Governance Relationships
CREATE EDGE TYPE SUPERVISES (
    supervision_level INTEGER DEFAULT 1 CHECK (supervision_level BETWEEN 1 AND 5),
    assigned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    active BOOLEAN DEFAULT TRUE
);

CREATE EDGE TYPE APPROVES (
    approval_type TEXT NOT NULL CHECK (approval_type IN ('task', 'resource', 'budget', 'execution')),
    approved_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    conditions JSONB
);

CREATE EDGE TYPE REQUESTS_APPROVAL (
    request_type TEXT NOT NULL,
    requested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    urgency_level INTEGER DEFAULT 3 CHECK (urgency_level BETWEEN 1 AND 5)
);

-- Temporal and Causal Relationships
CREATE EDGE TYPE PRECEDED_BY (
    temporal_gap_minutes INTEGER,
    causality_strength DECIMAL(3,2) DEFAULT 0.5
);

CREATE EDGE TYPE TRIGGERED_BY (
    trigger_type TEXT NOT NULL CHECK (trigger_type IN ('completion', 'failure', 'approval', 'schedule', 'condition')),
    triggered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =============================================================================
-- VECTOR INDEXES FOR SEMANTIC SEARCH
-- =============================================================================

-- Task semantic indexes
CREATE VECTOR INDEX task_objective_idx ON Task(objective_embedding) 
WITH (distance_metric = 'cosine');

CREATE VECTOR INDEX task_context_idx ON Task(context_embedding) 
WITH (distance_metric = 'cosine');

CREATE VECTOR INDEX task_outcome_idx ON Task(outcome_embedding) 
WITH (distance_metric = 'cosine');

-- Agent capability indexes
CREATE VECTOR INDEX agent_capability_idx ON Agent(capability_embedding) 
WITH (distance_metric = 'cosine');

CREATE VECTOR INDEX agent_behavior_idx ON Agent(behavior_embedding) 
WITH (distance_metric = 'cosine');

CREATE VECTOR INDEX agent_expertise_idx ON Agent(expertise_embedding) 
WITH (distance_metric = 'cosine');

-- Pattern semantic indexes
CREATE VECTOR INDEX pattern_semantic_idx ON Pattern(semantic_embedding) 
WITH (distance_metric = 'cosine');

CREATE VECTOR INDEX pattern_context_idx ON Pattern(context_embedding) 
WITH (distance_metric = 'cosine');

CREATE VECTOR INDEX pattern_structure_idx ON Pattern(structure_embedding) 
WITH (distance_metric = 'cosine');

-- Context relevance indexes
CREATE VECTOR INDEX context_semantic_idx ON Context(semantic_embedding) 
WITH (distance_metric = 'cosine');

CREATE VECTOR INDEX context_relevance_idx ON Context(relevance_embedding) 
WITH (distance_metric = 'cosine');

-- Knowledge artifact indexes
CREATE VECTOR INDEX knowledge_content_idx ON KnowledgeArtifact(content_embedding) 
WITH (distance_metric = 'cosine');

CREATE VECTOR INDEX knowledge_summary_idx ON KnowledgeArtifact(summary_embedding) 
WITH (distance_metric = 'cosine');

-- =============================================================================
-- TRADITIONAL INDEXES FOR FILTERING
-- =============================================================================

-- Task indexes
CREATE INDEX task_status_idx ON Task(status);
CREATE INDEX task_priority_idx ON Task(priority);
CREATE INDEX task_assigned_to_idx ON Task(assigned_to);
CREATE INDEX task_created_at_idx ON Task(created_at);
CREATE INDEX task_type_idx ON Task(task_type);
CREATE INDEX task_parent_composite_idx ON Task(parent_task_id, status);

-- Agent indexes
CREATE INDEX agent_status_idx ON Agent(status);
CREATE INDEX agent_type_idx ON Agent(agent_type);
CREATE INDEX agent_success_rate_idx ON Agent(success_rate);
CREATE INDEX agent_last_active_idx ON Agent(last_active);

-- Session indexes
CREATE INDEX session_status_idx ON Session(status);
CREATE INDEX session_agent_task_idx ON Session(agent_id, task_id);
CREATE INDEX session_started_at_idx ON Session(started_at);
CREATE INDEX session_cost_idx ON Session(cost_usd);

-- Pattern indexes
CREATE INDEX pattern_type_score_idx ON Pattern(pattern_type, value_score);
CREATE INDEX pattern_confidence_idx ON Pattern(confidence_score);
CREATE INDEX pattern_usage_idx ON Pattern(usage_count);
CREATE INDEX pattern_domain_idx ON Pattern(domain);

-- Resource indexes
CREATE INDEX resource_type_status_idx ON Resource(resource_type, status);
CREATE INDEX resource_path_idx ON Resource(path);
CREATE INDEX resource_locked_by_idx ON Resource(locked_by_session);

-- Decision indexes
CREATE INDEX decision_type_status_idx ON Decision(decision_type, status);
CREATE INDEX decision_timestamp_idx ON Decision(timestamp);
CREATE INDEX decision_risk_level_idx ON Decision(risk_level);

-- =============================================================================
-- HYBRID QUERY EXAMPLES AND USE CASES
-- =============================================================================

-- Example 1: Find similar tasks for context injection
-- Combines semantic similarity with graph traversal and filtering
/*
MATCH (current_task:Task {task_id: $current_task_id})
CALL vector.similarity.search(
    'task_objective_idx', 
    current_task.objective_embedding, 
    10
) YIELD node AS similar_task, score
WHERE similar_task.status IN ['completed', 'failed']
  AND similar_task.created_at > current_task.created_at - INTERVAL '90 days'
OPTIONAL MATCH (similar_task)<-[:BELONGS_TO_TASK]-(session:Session)-[:DERIVES_FROM]->(pattern:Pattern)
RETURN similar_task, score, collect(pattern) AS patterns
ORDER BY score DESC
LIMIT 5;
*/

-- Example 2: Agent matching for task assignment
-- Finds agents with similar capabilities and good performance
/*
MATCH (task:Task {task_id: $task_id})
CALL vector.similarity.search(
    'agent_capability_idx', 
    task.context_embedding, 
    20
) YIELD node AS agent, score
WHERE agent.status = 'available'
  AND agent.success_rate > 0.7
  AND agent.daily_budget_usd > task.cost_budget_usd
OPTIONAL MATCH (agent)-[:EXECUTES]->(prev_task:Task)-[:SIMILAR_TO {similarity_type: 'semantic'}]-(task)
RETURN agent, score, count(prev_task) AS similar_experience
ORDER BY score * (1 + similar_experience * 0.1) DESC
LIMIT 3;
*/

-- Example 3: Pattern evolution tracking
-- Tracks how patterns evolve and their effectiveness
/*
MATCH path = (original:Pattern)-[:EVOLVES_FROM*1..5]->(evolved:Pattern)
WHERE original.created_at > $start_date
WITH nodes(path) AS pattern_chain, length(path) AS evolution_depth
UNWIND pattern_chain AS p
WITH pattern_chain, evolution_depth, 
     avg(p.effectiveness_score) AS avg_effectiveness,
     sum(p.usage_count) AS total_usage
RETURN pattern_chain[0].pattern_name AS original_pattern,
       pattern_chain[-1].pattern_name AS current_pattern,
       evolution_depth,
       avg_effectiveness,
       total_usage
ORDER BY avg_effectiveness DESC, total_usage DESC
LIMIT 10;
*/

-- Example 4: Resource conflict detection with semantic analysis
-- Identifies potential resource conflicts using both graph relationships and semantic similarity
/*
MATCH (session:Session {status: 'active'})-[:LOCKS_RESOURCE]->(resource:Resource)
MATCH (pending_task:Task {status: 'active'})-[:REQUIRES_RESOURCE {access_type: 'write'}]->(conflict_resource:Resource)
WHERE resource.path = conflict_resource.path
   OR resource.resource_type = conflict_resource.resource_type
CALL vector.similarity.search(
    'resource_usage_pattern_idx', 
    resource.usage_pattern_embedding, 
    5
) YIELD node AS similar_resource, score
WHERE score > 0.8
  AND similar_resource <> resource
MATCH (similar_resource)<-[:REQUIRES_RESOURCE]-(potential_conflict:Task)
WHERE potential_conflict.status = 'active'
RETURN resource, conflict_resource, similar_resource, score, potential_conflict
ORDER BY score DESC;
*/

-- Example 5: Context effectiveness analysis
-- Analyzes which contexts are most effective for different task types
/*
MATCH (task:Task)-[:RELEVANT_TO]-(context:Context)
MATCH (task)<-[:BELONGS_TO_TASK]-(session:Session)
WHERE session.success = true
  AND context.effectiveness_score IS NOT NULL
CALL vector.similarity.search(
    'context_semantic_idx', 
    context.semantic_embedding, 
    100
) YIELD node AS similar_context, score
MATCH (similar_context)-[:RELEVANT_TO]->(other_task:Task)
MATCH (other_task)<-[:BELONGS_TO_TASK]-(other_session:Session)
WHERE other_session.success IS NOT NULL
WITH context, task.task_type AS task_type,
     avg(session.success::int) AS success_rate,
     avg(similar_context.effectiveness_score) AS avg_effectiveness,
     count(other_session) AS usage_count
RETURN task_type, 
       avg(success_rate) AS type_success_rate,
       avg(avg_effectiveness) AS effectiveness,
       sum(usage_count) AS total_usage
ORDER BY type_success_rate DESC, effectiveness DESC
LIMIT 20;
*/

-- =============================================================================
-- STORED PROCEDURES FOR COMMON OPERATIONS
-- =============================================================================

-- Procedure: Update task embedding when objective changes
CREATE OR REPLACE PROCEDURE update_task_embeddings(
    task_id_param TEXT,
    objective_emb VECTOR(1536),
    context_emb VECTOR(1536) DEFAULT NULL,
    outcome_emb VECTOR(1536) DEFAULT NULL
)
LANGUAGE SQL
AS $$
    UPDATE Task 
    SET objective_embedding = objective_emb,
        context_embedding = COALESCE(context_emb, context_embedding),
        outcome_embedding = COALESCE(outcome_emb, outcome_embedding),
        updated_at = CURRENT_TIMESTAMP
    WHERE task_id = task_id_param;
$$;

-- Procedure: Find and link similar patterns
CREATE OR REPLACE PROCEDURE link_similar_patterns(
    pattern_id_param TEXT,
    similarity_threshold DECIMAL(3,2) DEFAULT 0.75
)
LANGUAGE SQL
AS $$
    MATCH (source:Pattern {pattern_id: pattern_id_param})
    CALL vector.similarity.search(
        'pattern_semantic_idx', 
        source.semantic_embedding, 
        50
    ) YIELD node AS similar_pattern, score
    WHERE score >= similarity_threshold
      AND similar_pattern.pattern_id != pattern_id_param
    MERGE (source)-[sim:SIMILAR_TO]->(similar_pattern)
    SET sim.similarity_score = score,
        sim.computed_at = CURRENT_TIMESTAMP;
$$;

-- Procedure: Calculate and update pattern effectiveness
CREATE OR REPLACE PROCEDURE update_pattern_effectiveness()
LANGUAGE SQL
AS $$
    MATCH (pattern:Pattern)-[:APPLIES_TO]->(task:Task)
    MATCH (task)<-[:BELONGS_TO_TASK]-(session:Session)
    WHERE session.success IS NOT NULL
    WITH pattern, 
         avg(session.success::int) AS success_rate,
         count(session) AS total_applications
    SET pattern.effectiveness_score = success_rate,
        pattern.usage_count = total_applications,
        pattern.last_seen = CURRENT_TIMESTAMP;
$$;

-- =============================================================================
-- SCHEMA VALIDATION AND MAINTENANCE
-- =============================================================================

-- View: Schema health check
CREATE VIEW schema_health AS
SELECT 
    'Tasks' AS entity_type,
    count(*) AS total_count,
    count(objective_embedding) AS embedded_count,
    count(objective_embedding)::float / count(*) AS embedding_coverage
FROM Task
UNION ALL
SELECT 
    'Agents' AS entity_type,
    count(*) AS total_count,
    count(capability_embedding) AS embedded_count,
    count(capability_embedding)::float / count(*) AS embedding_coverage
FROM Agent
UNION ALL
SELECT 
    'Patterns' AS entity_type,
    count(*) AS total_count,
    count(semantic_embedding) AS embedded_count,
    count(semantic_embedding)::float / count(*) AS embedding_coverage
FROM Pattern;

-- View: Vector index utilization
CREATE VIEW vector_index_stats AS
SELECT 
    'task_objectives' AS index_name,
    count(*) AS vector_count,
    avg(array_length(objective_embedding::float[], 1)) AS avg_dimensions
FROM Task 
WHERE objective_embedding IS NOT NULL
UNION ALL
SELECT 
    'agent_capabilities' AS index_name,
    count(*) AS vector_count,
    avg(array_length(capability_embedding::float[], 1)) AS avg_dimensions
FROM Agent 
WHERE capability_embedding IS NOT NULL
UNION ALL
SELECT 
    'pattern_semantics' AS index_name,
    count(*) AS vector_count,
    avg(array_length(semantic_embedding::float[], 1)) AS avg_dimensions
FROM Pattern 
WHERE semantic_embedding IS NOT NULL;

-- =============================================================================
-- INITIALIZATION DATA
-- =============================================================================

-- Insert system genesis event
INSERT INTO KnowledgeArtifact (
    artifact_id,
    artifact_type,
    title,
    content,
    summary,
    domain,
    confidence_score,
    created_by_agent
) VALUES (
    'genesis_artifact',
    'procedure',
    'LevAIthan System Genesis',
    'Initial system setup and configuration procedures for AI agent coordination.',
    'System initialization knowledge base',
    'system_administration',
    1.0,
    'system'
);

-- =============================================================================
-- MAINTENANCE PROCEDURES
-- =============================================================================

-- Cleanup old similarity relationships
CREATE OR REPLACE PROCEDURE cleanup_stale_similarities()
LANGUAGE SQL
AS $$
    MATCH ()-[sim:SIMILAR_TO]->()
    WHERE sim.computed_at < CURRENT_TIMESTAMP - INTERVAL '30 days'
    DELETE sim;
$$;

-- Recompute pattern effectiveness scores
CREATE OR REPLACE PROCEDURE recompute_effectiveness_scores()
LANGUAGE SQL
AS $$
    CALL update_pattern_effectiveness();
    
    -- Update context effectiveness
    MATCH (context:Context)-[:RELEVANT_TO]->(task:Task)
    MATCH (task)<-[:BELONGS_TO_TASK]-(session:Session)
    WHERE session.success IS NOT NULL
    WITH context, avg(session.success::int) AS effectiveness
    SET context.effectiveness_score = effectiveness;
$$;

-- =============================================================================
-- PERFORMANCE MONITORING
-- =============================================================================

-- View: Query performance metrics
CREATE VIEW query_performance AS
SELECT 
    'hybrid_similarity_search' AS query_type,
    count(*) AS execution_count,
    avg(execution_time_ms) AS avg_execution_time,
    max(execution_time_ms) AS max_execution_time
FROM query_log 
WHERE query_text LIKE '%vector.similarity.search%'
  AND created_at > CURRENT_TIMESTAMP - INTERVAL '24 hours'
GROUP BY query_type;

-- Index maintenance reminder
CREATE OR REPLACE PROCEDURE maintenance_reminder()
LANGUAGE SQL
AS $$
    SELECT 
        'HelixDB maintenance required' AS message,
        count(*) AS total_vectors,
        min(last_updated) AS oldest_embedding
    FROM (
        SELECT updated_at AS last_updated FROM Task WHERE objective_embedding IS NOT NULL
        UNION ALL
        SELECT last_updated FROM Agent WHERE capability_embedding IS NOT NULL
        UNION ALL
        SELECT last_updated FROM Pattern WHERE semantic_embedding IS NOT NULL
    ) AS embeddings
    WHERE last_updated < CURRENT_TIMESTAMP - INTERVAL '7 days';
$$;