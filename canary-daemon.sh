#!/bin/bash
#
# Claude Context Canary - 独立监控守护进程
#
# 功能：实时监控 Claude 的 transcript 文件，检测输出是否符合金丝雀指令
# 优点：不依赖 hooks，可以检测所有输出（包括纯文本响应）
#
# 使用方法：
#   ./canary-daemon.sh start   # 启动守护进程
#   ./canary-daemon.sh stop    # 停止守护进程
#   ./canary-daemon.sh status  # 查看状态
#   ./canary-daemon.sh watch   # 前台运行（调试用）
#

DAEMON_NAME="claude-context-canary"
PID_FILE="/tmp/${DAEMON_NAME}.pid"
LOG_FILE="/tmp/${DAEMON_NAME}.log"
CONFIG_FILE="${HOME}/.claude/canary-config.json"
STATE_FILE="${HOME}/.claude/canary-state.json"

# 默认配置
DEFAULT_CANARY_PATTERN="^///"
DEFAULT_FAILURE_THRESHOLD=2
DEFAULT_CHECK_INTERVAL=2  # 检查间隔（秒）

# 加载配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        CANARY_PATTERN=$(jq -r '.canary_pattern // empty' "$CONFIG_FILE")
        FAILURE_THRESHOLD=$(jq -r '.failure_threshold // empty' "$CONFIG_FILE")
        CHECK_INTERVAL=$(jq -r '.check_interval // empty' "$CONFIG_FILE")
    fi
    CANARY_PATTERN="${CANARY_PATTERN:-$DEFAULT_CANARY_PATTERN}"
    FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-$DEFAULT_FAILURE_THRESHOLD}"
    CHECK_INTERVAL="${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}"
}

# 发送系统通知
send_notification() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"  # low, normal, critical

    # macOS
    if command -v osascript &> /dev/null; then
        osascript -e "display notification \"$message\" with title \"$title\" sound name \"Ping\""
    # Linux (需要 notify-send)
    elif command -v notify-send &> /dev/null; then
        notify-send -u "$urgency" "$title" "$message"
    fi

    # 同时写入日志
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$urgency] $title: $message" >> "$LOG_FILE"
}

# 获取当前活跃的 transcript 文件
get_active_transcript() {
    # Claude Code 的 transcript 文件通常在 ~/.claude/projects/*/session_*/transcript.jsonl
    local latest=""
    local latest_time=0

    for file in ~/.claude/projects/*/session_*/transcript.jsonl; do
        if [ -f "$file" ]; then
            local mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)
            if [ "$mtime" -gt "$latest_time" ]; then
                latest_time=$mtime
                latest=$file
            fi
        fi
    done

    echo "$latest"
}

# 检查最后一条 Claude 响应
check_last_response() {
    local transcript="$1"

    if [ ! -f "$transcript" ]; then
        return 0
    fi

    # 获取最后一条 assistant 消息
    local last_response=""
    while IFS= read -r line; do
        local msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        if [ "$msg_type" = "assistant" ]; then
            local text=$(echo "$line" | jq -r '
                .message.content[] |
                select(.type == "text") |
                .text
            ' 2>/dev/null | head -1)
            if [ -n "$text" ]; then
                last_response="$text"
            fi
        fi
    done < "$transcript"

    if [ -z "$last_response" ]; then
        return 0
    fi

    # 去除开头空白后检查
    local trimmed=$(echo "$last_response" | sed 's/^[[:space:]]*//')

    if echo "$trimmed" | grep -qE "$CANARY_PATTERN"; then
        # 符合要求，重置计数
        if [ -f "$STATE_FILE" ]; then
            jq '.failure_count = 0' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
        fi
        return 0
    else
        # 不符合要求
        return 1
    fi
}

# 更新失败计数
update_failure_count() {
    mkdir -p "$(dirname "$STATE_FILE")"

    if [ ! -f "$STATE_FILE" ]; then
        echo '{"failure_count": 0, "last_failure": "", "last_checked_response": ""}' > "$STATE_FILE"
    fi

    local current=$(jq -r '.failure_count // 0' "$STATE_FILE")
    local new_count=$((current + 1))
    local timestamp=$(date -Iseconds)

    jq --argjson count "$new_count" --arg ts "$timestamp" \
       '.failure_count = $count | .last_failure = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" \
       && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    echo "$new_count"
}

# 监控循环
watch_loop() {
    load_config
    echo "$(date): 守护进程启动" >> "$LOG_FILE"
    echo "配置: pattern=$CANARY_PATTERN, threshold=$FAILURE_THRESHOLD, interval=${CHECK_INTERVAL}s" >> "$LOG_FILE"

    local last_check_time=0
    local last_transcript_size=0

    while true; do
        local transcript=$(get_active_transcript)

        if [ -n "$transcript" ]; then
            local current_size=$(stat -c %s "$transcript" 2>/dev/null || stat -f %z "$transcript" 2>/dev/null)

            # 只有当文件变化时才检查
            if [ "$current_size" != "$last_transcript_size" ]; then
                last_transcript_size=$current_size

                if ! check_last_response "$transcript"; then
                    local count=$(update_failure_count)

                    if [ "$count" -ge "$FAILURE_THRESHOLD" ]; then
                        send_notification "🚨 Context Canary" \
                            "上下文已腐烂！连续 ${count} 次未遵循指令。请执行 /compact" \
                            "critical"
                    else
                        send_notification "⚠️ Context Canary" \
                            "警告：Claude 未遵循金丝雀指令 (${count}/${FAILURE_THRESHOLD})" \
                            "normal"
                    fi
                fi
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# 启动守护进程
start_daemon() {
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "守护进程已在运行 (PID: $old_pid)"
            return 1
        fi
    fi

    echo "启动守护进程..."
    nohup "$0" watch > /dev/null 2>&1 &
    local pid=$!
    echo $pid > "$PID_FILE"
    echo "守护进程已启动 (PID: $pid)"
    echo "日志文件: $LOG_FILE"
}

# 停止守护进程
stop_daemon() {
    if [ ! -f "$PID_FILE" ]; then
        echo "守护进程未运行"
        return 1
    fi

    local pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        rm -f "$PID_FILE"
        echo "守护进程已停止 (PID: $pid)"
    else
        rm -f "$PID_FILE"
        echo "守护进程不存在，已清理 PID 文件"
    fi
}

# 查看状态
show_status() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "状态: 运行中 (PID: $pid)"

            if [ -f "$STATE_FILE" ]; then
                local count=$(jq -r '.failure_count // 0' "$STATE_FILE")
                local last=$(jq -r '.last_failure // "无"' "$STATE_FILE")
                echo "连续失败次数: $count"
                echo "最后失败时间: $last"
            fi

            echo ""
            echo "最近日志:"
            tail -5 "$LOG_FILE" 2>/dev/null || echo "(无日志)"
            return 0
        fi
    fi

    echo "状态: 未运行"
    return 1
}

# 主入口
case "$1" in
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        stop_daemon
        sleep 1
        start_daemon
        ;;
    status)
        show_status
        ;;
    watch)
        watch_loop
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status|watch}"
        echo ""
        echo "  start   - 启动后台守护进程"
        echo "  stop    - 停止守护进程"
        echo "  restart - 重启守护进程"
        echo "  status  - 查看运行状态"
        echo "  watch   - 前台运行（调试用）"
        exit 1
        ;;
esac
