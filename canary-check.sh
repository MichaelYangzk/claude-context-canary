#!/bin/bash
#
# Claude Context Canary - 上下文腐烂检测脚本
#
# 功能：检测 Claude 的输出是否遵循 claude.md 中的"金丝雀指令"
# 如果未遵循，说明上下文可能已腐烂，需要执行 compact 或 clear
#

# 配置文件路径
CONFIG_FILE="${HOME}/.claude/canary-config.json"
STATE_FILE="${HOME}/.claude/canary-state.json"

# 默认配置
DEFAULT_CANARY_PATTERN="^///"  # 默认检测输出是否以 /// 开头
DEFAULT_FAILURE_THRESHOLD=2    # 连续失败多少次后发出强烈警告
DEFAULT_AUTO_ACTION="warn"     # warn | block

# 读取 stdin 获取 hook 输入
HOOK_INPUT=$(cat)

# 解析 hook 输入
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty')

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

# 使用默认值
CANARY_PATTERN="${CANARY_PATTERN:-$DEFAULT_CANARY_PATTERN}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-$DEFAULT_FAILURE_THRESHOLD}"
AUTO_ACTION="${AUTO_ACTION:-$DEFAULT_AUTO_ACTION}"

# 获取 Claude 最后一条响应
# transcript.jsonl 格式：每行是一个 JSON 对象
# 我们需要找最后一条 type 为 "assistant" 的消息
LAST_RESPONSE=$(tac "$TRANSCRIPT_PATH" 2>/dev/null | while read -r line; do
    MSG_TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
    if [ "$MSG_TYPE" = "assistant" ]; then
        # 提取文本内容
        echo "$line" | jq -r '.message.content[] | select(.type == "text") | .text' 2>/dev/null | head -1
        break
    fi
done)

# 如果没有找到响应，直接退出
if [ -z "$LAST_RESPONSE" ]; then
    exit 0
fi

# 检查是否符合金丝雀指令
if echo "$LAST_RESPONSE" | grep -qE "$CANARY_PATTERN"; then
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

# 增加失败计数
CURRENT_COUNT=$(jq -r '.failure_count // 0' "$STATE_FILE")
NEW_COUNT=$((CURRENT_COUNT + 1))
TIMESTAMP=$(date -Iseconds)

jq --argjson count "$NEW_COUNT" --arg ts "$TIMESTAMP" \
   '.failure_count = $count | .last_failure = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" \
   && mv "${STATE_FILE}.tmp" "$STATE_FILE"

# 生成警告信息
WARNING_MSG="⚠️ [Context Canary] 检测到上下文可能已腐烂！Claude 未遵循金丝雀指令。"
WARNING_MSG+="\n连续失败次数: $NEW_COUNT / $FAILURE_THRESHOLD"
WARNING_MSG+="\n建议执行: /compact 或 /clear"

# 根据失败次数决定行为
if [ "$NEW_COUNT" -ge "$FAILURE_THRESHOLD" ]; then
    CRITICAL_MSG="🚨 [Context Canary] 严重警告！连续 $NEW_COUNT 次未遵循金丝雀指令！"
    CRITICAL_MSG+="\n上下文已严重腐烂，强烈建议立即执行 /compact 或 /clear！"

    if [ "$AUTO_ACTION" = "block" ]; then
        # 返回 block 决策，阻止继续
        echo "{\"decision\": \"block\", \"reason\": \"$CRITICAL_MSG\"}"
        exit 0
    else
        # 只是警告，输出到 stderr（会在 verbose 模式下显示）
        echo -e "$CRITICAL_MSG" >&2
        exit 0
    fi
else
    # 普通警告
    echo -e "$WARNING_MSG" >&2
    exit 0
fi
