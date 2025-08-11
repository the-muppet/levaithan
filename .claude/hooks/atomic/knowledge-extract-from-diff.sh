#!/bin/bash
# KNOWLEDGE: A realistic implementation to parse a diff and identify patterns.
set -euo pipefail
source "$CLAUDE_PROJECT_DIR/.env"
source "$HOOKS_DIR/lib/logging.sh"
source "$HOOKS_DIR/lib/state.sh"

export HOOK_NAME="atomic/knowledge-extract-from-diff"
envelope=$(state_get "initial_envelope")
status=$(echo "$envelope" | jq -r '.payload.status')
if [[ "$status" != "success" ]]; then exit 0; fi

diff=$(echo "$envelope" | jq -r '.payload.artifacts.diff // ""')
if [[ -z "$diff" ]]; then exit 0; fi

log_info "pattern_extract" "running" "Extracting patterns from provided diff."

# A more robust grep to find new function/class/method definitions
# This looks for lines starting with '+' that are not just whitespace changes.
# It captures common function/class definition keywords.
echo "$diff" | grep -E "^\+\s*(function|class|def|public|private|const .* = \()" | while read -r line; do
    # This is where the call to a more sophisticated signature generation would happen.
    # For now, a hash of the line content is a decent, simple signature.
    signature=$(echo "$line" | sed 's/^\+//' | tr -s ' ' | sha256sum | awk '{print $1}')
    content_snippet=$(echo "$line" | sed 's/^\+//')
    
    # Store results in Redis for the next hook
    state_set "last_pattern_signature" "$signature"
    state_set "last_pattern_content" "$content_snippet"
    
    log_info "pattern_found" "pending_commit" "Identified pattern with signature: $signature"
    
    # Call the database update hook with the extracted data
    "$HOOKS_DIR/atomic/knowledge-update-pattern.sh"
done

exit 0
