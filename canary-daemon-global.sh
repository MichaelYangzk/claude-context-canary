#!/bin/bash
#
# Claude Context Canary - 全局监控守护进程 (无 jq 依赖)
#

DAEMON_NAME="claude-context-canary-global"
PID_FILE="/tmp/${DAEMON_NAME}.pid"
LOG_FILE="${HOME}/.claude/canary.log"
CONFIG_FILE="${HOME}/.claude/canary-config.json"
STATE_FILE="${HOME}/.claude/canary-state.json"
CLAUDE_PROJECTS_DIR="${HOME}/.claude/projects"
CHECKED_FILE="/tmp/${DAEMON_NAME}.checked"

# 默认配置
DEFAULT_CANARY_PATTERN="^///"
DEFAULT_FAILURE_THRESHOLD=2
DEFAULT_CHECK_INTERVAL=2

# 简单 JSON 解析（无需 jq）
json_get() {
    local file="$1"
    local key="$2"
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*[^,}]*" "$file" 2>/dev/null | \
        sed 's/.*:[[:space:]]*//; s/"//g; s/[[:space:]]*$//' | head -1
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        CANARY_PATTERN=$(json_get "$CONFIG_FILE" "canary_pattern")
        FAILURE_THRESHOLD=$(json_get "$CONFIG_FILE" "failure_threshold")
        CHECK_INTERVAL=$(json_get "$CONFIG_FILE" "check_interval")
    fi
    CANARY_PATTERN="${CANARY_PATTERN:-$DEFAULT_CANARY_PATTERN}"
    FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-$DEFAULT_FAILURE_THRESHOLD}"
    CHECK_INTERVAL="${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}"
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

send_notification() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"

    # macOS
    if command -v osascript &> /dev/null; then
        osascript -e "display notification \"$message\" with title \"$title\" sound name \"Ping\"" 2>/dev/null
    # Linux
    elif command -v notify-send &> /dev/null; then
        notify-send -u "$urgency" "$title" "$message" 2>/dev/null
    fi

    log "[$urgency] $title: $message"
}

get_active_transcripts() {
    if [ ! -d "$CLAUDE_PROJECTS_DIR" ]; then
        return
    fi
    find "$CLAUDE_PROJECTS_DIR" -name "transcript.jsonl" -mmin -5 2>/dev/null
}

get_response_hash() {
    local transcript="$1"
    tail -1 "$transcript" 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1
}

check_transcript() {
    local transcript="$1"

    if [ ! -f "$transcript" ]; then
        return 0
    fi

    local hash=$(get_response_hash "$transcript")
    if [ -f "$CHECKED_FILE" ] && grep -q "^${hash}$" "$CHECKED_FILE" 2>/dev/null; then
        return 0
    fi

    # 获取最后一条 assistant 消息的文本
    local last_response=""
    while IFS= read -r line; do
        if echo "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"assistant"'; then
            # 提取第一个 text 字段
            local text=$(echo "$line" | sed 's/.*"text"[[:space:]]*:[[:space:]]*"//' | sed 's/".*//' | head -c 500)
            if [ -n "$text" ] && [ "$text" != "$line" ]; then
                last_response="$text"
            fi
        fi
    done < "$transcript"

    if [ -z "$last_response" ]; then
        return 0
    fi

    echo "$hash" >> "$CHECKED_FILE"

    local trimmed=$(echo "$last_response" | sed 's/^[[:space:]]*//')

    if echo "$trimmed" | grep -qE "$CANARY_PATTERN"; then
        echo '{"failure_count": 0}' > "$STATE_FILE"
        return 0
    else
        return 1
    fi
}

update_failure_count() {
    local transcript="$1"

    mkdir -p "$(dirname "$STATE_FILE")"

    local current=0
    if [ -f "$STATE_FILE" ]; then
        current=$(json_get "$STATE_FILE" "failure_count")
        current="${current:-0}"
    fi

    local new_count=$((current + 1))
    local timestamp=$(date '+%Y-%m-%dT%H:%M:%S')
    local project=$(echo "$transcript" | sed "s|$CLAUDE_PROJECTS_DIR/||" | cut -d'/' -f1)

    cat > "$STATE_FILE" << EOF
{"failure_count": $new_count, "last_failure": "$timestamp", "last_project": "$project"}
EOF

    echo "$new_count"
}

watch_loop() {
    load_config

    mkdir -p "$(dirname "$LOG_FILE")"
    : > "$CHECKED_FILE"

    log "========== 全局守护进程启动 =========="
    log "配置: pattern=$CANARY_PATTERN, threshold=$FAILURE_THRESHOLD, interval=${CHECK_INTERVAL}s"
    log "监控目录: $CLAUDE_PROJECTS_DIR"

    while true; do
        while IFS= read -r transcript; do
            if [ -n "$transcript" ]; then
                if ! check_transcript "$transcript"; then
                    local count=$(update_failure_count "$transcript")
                    local project=$(echo "$transcript" | sed "s|$CLAUDE_PROJECTS_DIR/||" | cut -d'/' -f1)

                    if [ "$count" -ge "$FAILURE_THRESHOLD" ]; then
                        send_notification "Context Canary" \
                            "[$project] 上下文腐烂! 连续${count}次失败. 执行 /compact" \
                            "critical"
                    else
                        send_notification "Context Canary" \
                            "[$project] 未遵循指令 (${count}/${FAILURE_THRESHOLD})" \
                            "normal"
                    fi
                fi
            fi
        done <<< "$(get_active_transcripts)"

        sleep "$CHECK_INTERVAL"
    done
}

start_daemon() {
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "守护进程已在运行 (PID: $old_pid)"
            return 1
        fi
    fi

    echo "启动全局守护进程..."
    nohup "$0" watch > /dev/null 2>&1 &
    local pid=$!
    echo $pid > "$PID_FILE"
    echo "✓ 守护进程已启动 (PID: $pid)"
    echo "✓ 日志: $LOG_FILE"
    echo "✓ 监控: $CLAUDE_PROJECTS_DIR"
}

stop_daemon() {
    if [ ! -f "$PID_FILE" ]; then
        echo "守护进程未运行"
        return 1
    fi

    local pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        rm -f "$PID_FILE"
        echo "✓ 守护进程已停止 (PID: $pid)"
    else
        rm -f "$PID_FILE"
        echo "守护进程不存在，已清理"
    fi
}

show_status() {
    echo "=========================================="
    echo "  Claude Context Canary - 全局监控状态"
    echo "=========================================="
    echo ""

    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "守护进程: 运行中 (PID: $pid)"
        else
            echo "守护进程: 未运行"
        fi
    else
        echo "守护进程: 未运行"
    fi

    load_config
    echo ""
    echo "配置:"
    echo "  金丝雀模式: $CANARY_PATTERN"
    echo "  失败阈值: $FAILURE_THRESHOLD"
    echo "  检查间隔: ${CHECK_INTERVAL}s"

    if [ -f "$STATE_FILE" ]; then
        echo ""
        echo "检测状态:"
        echo "  连续失败: $(json_get "$STATE_FILE" "failure_count")"
        echo "  最后失败: $(json_get "$STATE_FILE" "last_failure")"
        echo "  最后项目: $(json_get "$STATE_FILE" "last_project")"
    fi

    echo ""
    echo "活跃项目 (最近 5 分钟):"
    local count=0
    while IFS= read -r transcript; do
        if [ -n "$transcript" ]; then
            local project=$(echo "$transcript" | sed "s|$CLAUDE_PROJECTS_DIR/||" | cut -d'/' -f1)
            echo "  - $project"
            count=$((count + 1))
        fi
    done <<< "$(get_active_transcripts)"
    if [ "$count" -eq 0 ]; then
        echo "  (无)"
    fi

    echo ""
    echo "最近日志:"
    if [ -f "$LOG_FILE" ]; then
        tail -5 "$LOG_FILE" | sed 's/^/  /'
    else
        echo "  (无日志)"
    fi
}

case "$1" in
    start)  start_daemon ;;
    stop)   stop_daemon ;;
    restart) stop_daemon; sleep 1; start_daemon ;;
    status) show_status ;;
    watch)  watch_loop ;;
    *)
        echo "用法: $0 {start|stop|restart|status|watch}"
        exit 1
        ;;
esac
