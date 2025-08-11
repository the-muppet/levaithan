#!/bin/bash
# Simulates an agent sending an ACP envelope to the system.

# 1. Construct the InteractionEnvelope
cat > /tmp/task_envelope.json <<EOF
{
  "protocol_version": "1.0",
  "agent_id": "frontend-v2",
  "task_id": "task_$(uuidgen)",
  "session_id": "session_$(uuidgen)",
  "event_type": "task_declaration",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "payload": {
    "objective": "Refactor Login component to use new SSO API",
    "target_files": ["src/components/Login.jsx"]
  }
}
EOF

# 2. Pipe the envelope into the orchestrator
echo "--- INITIATING TASK VIA ACP ---"
cat /tmp/task_envelope.json | ./.claude/hooks/orchestrator.sh

# 3. Check the exit code
if [ $? -eq 0 ]; then
  echo "--- PRE-TOOL-USE WORKFLOW SUCCEEDED. AGENT CAN PROCEED. ---"
else
  echo "--- PRE-TOOL-USE WORKFLOW FAILED. AGENT ACTION BLOCKED. ---"
fi
