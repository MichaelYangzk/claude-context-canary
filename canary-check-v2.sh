#!/bin/bash
#
# Claude Context Canary v2 - Context Rot Detection Script
#
# Uses UserPromptSubmit hook - checks previous Claude response before user sends message
#

# Config file paths
CONFIG_FILE="${HOME}/.claude/canary-config.json"
STATE_FILE="${HOME}/.claude/canary-state.json"

# Default configuration
DEFAULT_CANARY_PATTERN="^///"
DEFAULT_FAILURE_THRESHOLD=2
DEFAULT_AUTO_ACTION="warn"  # warn | block

# Read stdin to get hook input
HOOK_INPUT=$(cat)

# Parse hook input
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty')
HOOK_EVENT=$(echo "$HOOK_INPUT" | jq -r '.hook_event_name // empty')

# Debug log (optional)
# echo "$(date): Hook triggered - $HOOK_EVENT" >> /tmp/canary-debug.log

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

CANARY_PATTERN="${CANARY_PATTERN:-$DEFAULT_CANARY_PATTERN}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-$DEFAULT_FAILURE_THRESHOLD}"
AUTO_ACTION="${AUTO_ACTION:-$DEFAULT_AUTO_ACTION}"

# Get Claude's last response
# Search for the last assistant type message from transcript.jsonl
LAST_RESPONSE=""
while IFS= read -r line; do
    MSG_TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
    if [ "$MSG_TYPE" = "assistant" ]; then
        # Extract text content (may have multiple content blocks)
        TEXT_CONTENT=$(echo "$line" | jq -r '
            .message.content[] |
            select(.type == "text") |
            .text
        ' 2>/dev/null | head -1)
        if [ -n "$TEXT_CONTENT" ]; then
            LAST_RESPONSE="$TEXT_CONTENT"
        fi
    fi
done < "$TRANSCRIPT_PATH"

# If no Claude response found (possibly new session), allow through
if [ -z "$LAST_RESPONSE" ]; then
    exit 0
fi

# Check if it matches canary instruction
# Remove leading whitespace before checking
TRIMMED_RESPONSE=$(echo "$LAST_RESPONSE" | sed 's/^[[:space:]]*//')
if echo "$TRIMMED_RESPONSE" | grep -qE "$CANARY_PATTERN"; then
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

CURRENT_COUNT=$(jq -r '.failure_count // 0' "$STATE_FILE")
NEW_COUNT=$((CURRENT_COUNT + 1))
TIMESTAMP=$(date -Iseconds)

jq --argjson count "$NEW_COUNT" --arg ts "$TIMESTAMP" \
   '.failure_count = $count | .last_failure = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" \
   && mv "${STATE_FILE}.tmp" "$STATE_FILE"

# Generate output
if [ "$NEW_COUNT" -ge "$FAILURE_THRESHOLD" ]; then
    # Critical warning
    REASON="🚨 [Context Canary] Context rot detected! ${NEW_COUNT} consecutive failures to follow canary instruction. Run /compact or /clear"

    if [ "$AUTO_ACTION" = "block" ]; then
        # Block user from sending more messages
        cat << EOF
{
  "decision": "block",
  "reason": "$REASON"
}
EOF
        exit 0
    fi
fi

# Return warning context (will be shown to Claude)
cat << EOF
{
  "decision": "allow",
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "⚠️ [Context Canary] Warning: Your previous response did not follow the canary instruction (should start with $CANARY_PATTERN). Consecutive failures: ${NEW_COUNT}/${FAILURE_THRESHOLD}. Please follow the instructions in CLAUDE.md."
  }
}
EOF
exit 0
