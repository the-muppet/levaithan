-- PostgreSQL Schema for LevAIthan System
-- Core tables for task management, coordination, and evolution

-- Tasks table - Core task tracking
CREATE TABLE IF NOT EXISTS tasks (
    task_id TEXT PRIMARY KEY,
    parent_task_id TEXT REFERENCES tasks(task_id),
    objective TEXT NOT NULL,
    created_by TEXT NOT NULL,
    assigned_to TEXT,
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'delegated', 'completed', 'failed', 'cancelled')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Agent Sessions table - Active work sessions
CREATE TABLE IF NOT EXISTS agent_sessions (
    session_id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL REFERENCES tasks(task_id),
    agent_id TEXT NOT NULL,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'approved_for_execution', 'active', 'completed', 'failed')),
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_heartbeat TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ended_at TIMESTAMP
);

-- Resource Locks table - File/resource conflict prevention
CREATE TABLE IF NOT EXISTS resource_locks (
    lock_id SERIAL PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES agent_sessions(session_id) ON DELETE CASCADE,
    resource_path TEXT NOT NULL,
    locked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(resource_path)
);

-- Cost Records table - Financial tracking
CREATE TABLE IF NOT EXISTS cost_records (
    record_id SERIAL PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES agent_sessions(session_id),
    model_used TEXT NOT NULL,
    input_tokens INTEGER,
    output_tokens INTEGER,
    total_cost_usd DECIMAL(10,8),
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Budget Allocations table - Agent spending limits
CREATE TABLE IF NOT EXISTS budget_allocations (
    allocation_id SERIAL PRIMARY KEY,
    agent_id TEXT NOT NULL,
    budget_type TEXT NOT NULL CHECK (budget_type IN ('daily', 'weekly', 'monthly')),
    amount_usd DECIMAL(10,2),
    period_start DATE,
    period_end DATE,
    UNIQUE(agent_id, budget_type, period_start)
);

-- Context Injections table - AI context effectiveness tracking
CREATE TABLE IF NOT EXISTS context_injections (
    injection_id SERIAL PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES agent_sessions(session_id),
    context_source TEXT NOT NULL,
    context_data TEXT,
    effectiveness_score DECIMAL(3,2) CHECK (effectiveness_score BETWEEN 0 AND 1),
    injected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Improvement Suggestions table - System evolution proposals
CREATE TABLE IF NOT EXISTS improvement_suggestions (
    suggestion_id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    suggestion_type TEXT NOT NULL CHECK (suggestion_type IN ('create_custom_hook', 'modify_config', 'optimize_query')),
    justification TEXT,
    implementation_details JSONB,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'implemented')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    reviewed_at TIMESTAMP,
    reviewed_by TEXT
);

-- Human Feedback table - Operator corrections and guidance
CREATE TABLE IF NOT EXISTS human_feedback (
    feedback_id SERIAL PRIMARY KEY,
    task_id TEXT REFERENCES tasks(task_id),
    session_id TEXT REFERENCES agent_sessions(session_id),
    feedback_type TEXT NOT NULL CHECK (feedback_type IN ('correction', 'guidance', 'approval', 'rejection')),
    correction_details JSONB,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'addressed', 'dismissed')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    addressed_at TIMESTAMP
);

-- Chronicle Events table - High-level system event log
CREATE TABLE IF NOT EXISTS chronicle_events (
    event_id SERIAL PRIMARY KEY,
    event_type TEXT NOT NULL,
    event_title TEXT,
    event_description TEXT,
    metadata JSONB,
    significance_level INTEGER DEFAULT 5 CHECK (significance_level BETWEEN 1 AND 10),
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_assigned_to ON tasks(assigned_to);
CREATE INDEX IF NOT EXISTS idx_sessions_agent_status ON agent_sessions(agent_id, status);
CREATE INDEX IF NOT EXISTS idx_cost_records_session ON cost_records(session_id);
CREATE INDEX IF NOT EXISTS idx_cost_records_date ON cost_records(recorded_at);
CREATE INDEX IF NOT EXISTS idx_resource_locks_path ON resource_locks(resource_path);
CREATE INDEX IF NOT EXISTS idx_context_effectiveness ON context_injections(effectiveness_score);
CREATE INDEX IF NOT EXISTS idx_suggestions_status ON improvement_suggestions(status);
CREATE INDEX IF NOT EXISTS idx_feedback_status ON human_feedback(status);
CREATE INDEX IF NOT EXISTS idx_chronicle_date ON chronicle_events(recorded_at);

-- Chronicle Events table - High-level system event log
CREATE TABLE IF NOT EXISTS chronicle_events (
    event_id SERIAL PRIMARY KEY,
    event_type TEXT NOT NULL,
    event_title TEXT,
    event_description TEXT,
    metadata JSONB,
    significance_level INTEGER DEFAULT 5 CHECK (significance_level BETWEEN 1 AND 10),
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Patterns table - Learned code patterns and knowledge
CREATE TABLE IF NOT EXISTS patterns (
    pattern_id SERIAL PRIMARY KEY,
    pattern_signature TEXT UNIQUE NOT NULL,
    pattern_name TEXT,
    pattern_type TEXT NOT NULL,
    pattern_content TEXT,
    use_case TEXT,
    value_score DECIMAL(3,2) DEFAULT 0.5 CHECK (value_score BETWEEN 0 AND 1),
    usage_count INTEGER DEFAULT 1,
    agent_id TEXT,
    task_id TEXT,
    reviewed BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Governance Decisions table - Track all governance decisions for learning
CREATE TABLE IF NOT EXISTS governance_decisions (
    decision_id SERIAL PRIMARY KEY,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    agent_id TEXT NOT NULL,
    decision_type TEXT NOT NULL, -- 'budget_check', 'security_check', 'conflict_check'
    decision BOOLEAN NOT NULL,   -- true = approved, false = blocked
    reasoning TEXT,
    risk_level TEXT,
    context_data JSONB
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_chronicle_type_date ON chronicle_events(event_type, recorded_at);
CREATE INDEX IF NOT EXISTS idx_patterns_type_score ON patterns(pattern_type, value_score);
CREATE INDEX IF NOT EXISTS idx_patterns_agent ON patterns(agent_id);
CREATE INDEX IF NOT EXISTS idx_governance_agent_type ON governance_decisions(agent_id, decision_type);
CREATE INDEX IF NOT EXISTS idx_governance_timestamp ON governance_decisions(timestamp);

-- Insert initial system charter event
INSERT INTO chronicle_events (event_type, event_title, event_description, significance_level)
VALUES ('system_initialization', 'LevAIthan Genesis', 'System database initialized and ready for operation', 10)
ON CONFLICT DO NOTHING;
