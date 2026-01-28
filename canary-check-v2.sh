#!/bin/bash
#
# Claude Context Canary v2 - 上下文腐烂检测脚本
#
# 使用 UserPromptSubmit hook - 在用户发送消息前检查上一条 Claude 响应
#

# 配置文件路径
CONFIG_FILE="${HOME}/.claude/canary-config.json"
STATE_FILE="${HOME}/.claude/canary-state.json"

# 默认配置
DEFAULT_CANARY_PATTERN="^///"
DEFAULT_FAILURE_THRESHOLD=2
DEFAULT_AUTO_ACTION="warn"  # warn | block

# 读取 stdin 获取 hook 输入
HOOK_INPUT=$(cat)

# 解析 hook 输入
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty')
HOOK_EVENT=$(echo "$HOOK_INPUT" | jq -r '.hook_event_name // empty')

# 调试日志（可选）
# echo "$(date): Hook triggered - $HOOK_EVENT" >> /tmp/canary-debug.log

# 如果没有 transcript_path，直接退出
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    exit 0
fi

# 读取配置
if [ -f "$CONFIG_FILE" ]; then
    CANARY_PATTERN=$(jq -r '.canary_pattern // empty' "$CONFIG_FILE")
    FAILURE_THRESHOLD=$(jq -r '.failure_threshold // empty' "$CONFIG_FILE")
    AUTO_ACTION=$(jq -r '.auto_action // empty' "$CONFIG_FILE")
fi

CANARY_PATTERN="${CANARY_PATTERN:-$DEFAULT_CANARY_PATTERN}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-$DEFAULT_FAILURE_THRESHOLD}"
AUTO_ACTION="${AUTO_ACTION:-$DEFAULT_AUTO_ACTION}"

# 获取 Claude 最后一条响应
# 从 transcript.jsonl 中查找最后一条 assistant 类型的消息
LAST_RESPONSE=""
while IFS= read -r line; do
    MSG_TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
    if [ "$MSG_TYPE" = "assistant" ]; then
        # 提取文本内容（可能有多个 content 块）
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

# 如果没有找到 Claude 响应（可能是新会话），直接放行
if [ -z "$LAST_RESPONSE" ]; then
    exit 0
fi

# 检查是否符合金丝雀指令
# 去除开头的空白字符后检查
TRIMMED_RESPONSE=$(echo "$LAST_RESPONSE" | sed 's/^[[:space:]]*//')
if echo "$TRIMMED_RESPONSE" | grep -qE "$CANARY_PATTERN"; then
    # 符合指令，重置失败计数
    if [ -f "$STATE_FILE" ]; then
        jq '.failure_count = 0' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    exit 0
fi

# 不符合指令，记录失败
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

# 生成输出
if [ "$NEW_COUNT" -ge "$FAILURE_THRESHOLD" ]; then
    # 严重警告
    REASON="🚨 [Context Canary] 上下文已腐烂！连续 ${NEW_COUNT} 次未遵循金丝雀指令。请执行 /compact 或 /clear"

    if [ "$AUTO_ACTION" = "block" ]; then
        # 阻止用户继续发送消息
        cat << EOF
{
  "decision": "block",
  "reason": "$REASON"
}
EOF
        exit 0
    fi
fi

# 返回警告上下文（会显示给 Claude）
cat << EOF
{
  "decision": "allow",
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "⚠️ [Context Canary] 警告：你上一条回复未遵循金丝雀指令（应以 $CANARY_PATTERN 开头）。连续失败: ${NEW_COUNT}/${FAILURE_THRESHOLD}。请确保遵循 CLAUDE.md 中的指令。"
  }
}
EOF
exit 0
