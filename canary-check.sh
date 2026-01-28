#!/bin/bash
#
# Claude Context Canary - Context Rot Detection Script
#
# Function: Detect if Claude's output follows the "canary instruction" in CLAUDE.md
#           If not followed, context may have degraded and needs compact or clear
#

# Config file paths
CONFIG_FILE="${HOME}/.claude/canary-config.json"
STATE_FILE="${HOME}/.claude/canary-state.json"

# Default configuration
DEFAULT_CANARY_PATTERN="^///"  # Default: check if output starts with ///
DEFAULT_FAILURE_THRESHOLD=2    # Consecutive failures before strong warning
DEFAULT_AUTO_ACTION="warn"     # warn | block

# Read stdin to get hook input
HOOK_INPUT=$(cat)

# Parse hook input
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty')

# If no transcript_path, exit directly
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    exit 0
fi

# Read configuration
if [ -f "$CONFIG_FILE" ]; then
    CANARY_PATTERN=$(jq -r '.canary_pattern // empty' "$CONFIG_FILE")
    FAILURE_THRESHOLD=$(jq -r '.failure_threshold // empty' "$CONFIG_FILE")
    AUTO_ACTION=$(jq -r '.auto_action // empty' "$CONFIG_FILE")
fi

# Use default values
CANARY_PATTERN="${CANARY_PATTERN:-$DEFAULT_CANARY_PATTERN}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-$DEFAULT_FAILURE_THRESHOLD}"
AUTO_ACTION="${AUTO_ACTION:-$DEFAULT_AUTO_ACTION}"

# Get Claude's last response
# transcript.jsonl format: each line is a JSON object
# We need to find the last message with type "assistant"
LAST_RESPONSE=$(tac "$TRANSCRIPT_PATH" 2>/dev/null | while read -r line; do
    MSG_TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
    if [ "$MSG_TYPE" = "assistant" ]; then
        # Extract text content
        echo "$line" | jq -r '.message.content[] | select(.type == "text") | .text' 2>/dev/null | head -1
        break
    fi
done)

# If no response found, exit directly
if [ -z "$LAST_RESPONSE" ]; then
    exit 0
fi

# Check if it matches canary instruction
if echo "$LAST_RESPONSE" | grep -qE "$CANARY_PATTERN"; then
    # Matches instruction, reset failure count
    if [ -f "$STATE_FILE" ]; then
        jq '.failure_count = 0' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    exit 0
fi

# Does not match instruction, record failure
mkdir -p "$(dirname "$STATE_FILE")"

if [ ! -f "$STATE_FILE" ]; then
    echo '{"failure_count": 0, "last_failure": ""}' > "$STATE_FILE"
fi

# Increment failure count
CURRENT_COUNT=$(jq -r '.failure_count // 0' "$STATE_FILE")
NEW_COUNT=$((CURRENT_COUNT + 1))
TIMESTAMP=$(date -Iseconds)

jq --argjson count "$NEW_COUNT" --arg ts "$TIMESTAMP" \
   '.failure_count = $count | .last_failure = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" \
   && mv "${STATE_FILE}.tmp" "$STATE_FILE"

# Generate warning message
WARNING_MSG="⚠️ [Context Canary] Context rot detected! Claude did not follow canary instruction."
WARNING_MSG+="\nConsecutive failures: $NEW_COUNT / $FAILURE_THRESHOLD"
WARNING_MSG+="\nRecommended: /compact or /clear"

# Decide behavior based on failure count
if [ "$NEW_COUNT" -ge "$FAILURE_THRESHOLD" ]; then
    CRITICAL_MSG="🚨 [Context Canary] Critical warning! $NEW_COUNT consecutive failures to follow canary instruction!"
    CRITICAL_MSG+="\nContext severely degraded, strongly recommend running /compact or /clear immediately!"

    if [ "$AUTO_ACTION" = "block" ]; then
        # Return block decision
        echo "{\"decision\": \"block\", \"reason\": \"$CRITICAL_MSG\"}"
        exit 0
    else
        # Just warn, output to stderr (shown in verbose mode)
        echo -e "$CRITICAL_MSG" >&2
        exit 0
    fi
else
    # Normal warning
    echo -e "$WARNING_MSG" >&2
    exit 0
fi
