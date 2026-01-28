#!/bin/bash
#
# Claude Context Canary - Global Monitoring Daemon (no jq dependency)
#

DAEMON_NAME="claude-context-canary-global"
PID_FILE="/tmp/${DAEMON_NAME}.pid"
LOG_FILE="${HOME}/.claude/canary.log"
CONFIG_FILE="${HOME}/.claude/canary-config.json"
STATE_FILE="${HOME}/.claude/canary-state.json"
CLAUDE_PROJECTS_DIR="${HOME}/.claude/projects"
CHECKED_FILE="/tmp/${DAEMON_NAME}.checked"

# Default configuration
DEFAULT_CANARY_PATTERN="^///"
DEFAULT_FAILURE_THRESHOLD=2
DEFAULT_CHECK_INTERVAL=2

# Simple JSON parsing (no jq required)
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
    # Find .jsonl files modified in the last 5 minutes (excluding subagents)
    find "$CLAUDE_PROJECTS_DIR" -maxdepth 3 -name "*.jsonl" -mmin -5 2>/dev/null | grep -v "/subagents/"
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

    # Get the last assistant message text
    local last_response=""
    while IFS= read -r line; do
        if echo "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"assistant"'; then
            # Extract first text field
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

    log "========== Global Daemon Started =========="
    log "Config: pattern=$CANARY_PATTERN, threshold=$FAILURE_THRESHOLD, interval=${CHECK_INTERVAL}s"
    log "Monitoring: $CLAUDE_PROJECTS_DIR"

    while true; do
        while IFS= read -r transcript; do
            if [ -n "$transcript" ]; then
                if ! check_transcript "$transcript"; then
                    local count=$(update_failure_count "$transcript")
                    local project=$(echo "$transcript" | sed "s|$CLAUDE_PROJECTS_DIR/||" | cut -d'/' -f1)

                    if [ "$count" -ge "$FAILURE_THRESHOLD" ]; then
                        send_notification "🚨🚨🚨 Context Canary" \
                            "🔴🔴🔴 [$project] CONTEXT ROT DETECTED! 💀💀💀 ${count} consecutive failures! ⚠️⚠️⚠️ Run /compact NOW! 🆘🆘🆘" \
                            "critical"
                    else
                        send_notification "⚠️ Context Canary" \
                            "🟡 [$project] Instruction not followed (${count}/${FAILURE_THRESHOLD}) 👀" \
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
            echo "Daemon already running (PID: $old_pid)"
            return 1
        fi
    fi

    echo "Starting global daemon..."
    nohup "$0" watch > /dev/null 2>&1 &
    local pid=$!
    echo $pid > "$PID_FILE"
    echo "✓ Daemon started (PID: $pid)"
    echo "✓ Log file: $LOG_FILE"
    echo "✓ Monitoring: $CLAUDE_PROJECTS_DIR"
}

stop_daemon() {
    if [ ! -f "$PID_FILE" ]; then
        echo "Daemon not running"
        return 1
    fi

    local pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        rm -f "$PID_FILE"
        echo "✓ Daemon stopped (PID: $pid)"
    else
        rm -f "$PID_FILE"
        echo "Daemon not found, cleaned up PID file"
    fi
}

show_status() {
    echo "=========================================="
    echo "  Claude Context Canary - Global Status"
    echo "=========================================="
    echo ""

    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Daemon: Running (PID: $pid)"
        else
            echo "Daemon: Not running"
        fi
    else
        echo "Daemon: Not running"
    fi

    load_config
    echo ""
    echo "Configuration:"
    echo "  Canary Pattern: $CANARY_PATTERN"
    echo "  Failure Threshold: $FAILURE_THRESHOLD"
    echo "  Check Interval: ${CHECK_INTERVAL}s"

    if [ -f "$STATE_FILE" ]; then
        echo ""
        echo "Detection State:"
        echo "  Consecutive Failures: $(json_get "$STATE_FILE" "failure_count")"
        echo "  Last Failure: $(json_get "$STATE_FILE" "last_failure")"
        echo "  Last Project: $(json_get "$STATE_FILE" "last_project")"
    fi

    echo ""
    echo "Active Projects (last 5 minutes):"
    local count=0
    while IFS= read -r transcript; do
        if [ -n "$transcript" ]; then
            local project=$(echo "$transcript" | sed "s|$CLAUDE_PROJECTS_DIR/||" | cut -d'/' -f1)
            echo "  - $project"
            count=$((count + 1))
        fi
    done <<< "$(get_active_transcripts)"
    if [ "$count" -eq 0 ]; then
        echo "  (none)"
    fi

    echo ""
    echo "Recent Logs:"
    if [ -f "$LOG_FILE" ]; then
        tail -5 "$LOG_FILE" | sed 's/^/  /'
    else
        echo "  (no logs)"
    fi
}

case "$1" in
    start)  start_daemon ;;
    stop)   stop_daemon ;;
    restart) stop_daemon; sleep 1; start_daemon ;;
    status) show_status ;;
    watch)  watch_loop ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|watch}"
        exit 1
        ;;
esac
