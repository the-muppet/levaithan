#!/bin/bash
# Initializes the entire AI system environment.
echo "--- Initializing LevAIthan System ---"
set -e

# 1. Create directory structure
mkdir -p .claude/{hooks/{lib,atomic,workflows,customizations},context,db,logs}

# 2. Copy hooks into place (assuming they are in a git repo)
# cp -r ./hooks/* .claude/hooks/

# 3. Create initial configuration files
touch .claude/context/project-scope.yaml
cat > .claude/context/system-charter.yaml << EOF
# System Charter, Version 1.0
prime_directive: "To accelerate human-AI collaborative problem-solving..."
core_principles:
  - "HumanSovereignty"
  # ...
EOF

# 4. Initialize Databases
echo "Initializing PostgreSQL Schemas..."
psql "$POSTGRES_DSN" -f ./schemas/postgres_schema.sql

# In a real setup, you would also initialize HelixDB constraints and Elasticsearch mappings
echo "Initializing HelixDB Constraints..."
# execute_cypher_query "CREATE CONSTRAINT FOR (t:Task) REQUIRE t.id IS UNIQUE;"

echo "--- System Initialization Complete ---"
echo "Run 'docker-compose up -d' to start backend services."
echo "Run 'workflow-genesis.sh' to prime the knowledge base."
