#!/bin/bash
#
# Claude Context Canary - Standalone Monitoring Daemon
#
# Function: Real-time monitoring of Claude's transcript files to detect
#           if outputs follow the canary instruction
#
# Advantages: No hooks dependency, can detect all outputs (including plain text)
#
# Usage:
#   ./canary-daemon.sh start   # Start daemon
#   ./canary-daemon.sh stop    # Stop daemon
#   ./canary-daemon.sh status  # Check status
#   ./canary-daemon.sh watch   # Run in foreground (for debugging)
#

DAEMON_NAME="claude-context-canary"
PID_FILE="/tmp/${DAEMON_NAME}.pid"
LOG_FILE="/tmp/${DAEMON_NAME}.log"
CONFIG_FILE="${HOME}/.claude/canary-config.json"
STATE_FILE="${HOME}/.claude/canary-state.json"

# Default configuration
DEFAULT_CANARY_PATTERN="^///"
DEFAULT_FAILURE_THRESHOLD=2
DEFAULT_CHECK_INTERVAL=2  # Check interval (seconds)

# Load configuration
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

# Send system notification
send_notification() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"  # low, normal, critical

    # macOS
    if command -v osascript &> /dev/null; then
        osascript -e "display notification \"$message\" with title \"$title\" sound name \"Ping\""
    # Linux (requires notify-send)
    elif command -v notify-send &> /dev/null; then
        notify-send -u "$urgency" "$title" "$message"
    fi

    # Also write to log
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$urgency] $title: $message" >> "$LOG_FILE"
}

# Get currently active transcript file
get_active_transcript() {
    # Claude Code transcript files are typically at ~/.claude/projects/*/session_*/transcript.jsonl
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

# Check the last Claude response
check_last_response() {
    local transcript="$1"

    if [ ! -f "$transcript" ]; then
        return 0
    fi

    # Get the last assistant message
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

    # Remove leading whitespace and check
    local trimmed=$(echo "$last_response" | sed 's/^[[:space:]]*//')

    if echo "$trimmed" | grep -qE "$CANARY_PATTERN"; then
        # Matches requirement, reset counter
        if [ -f "$STATE_FILE" ]; then
            jq '.failure_count = 0' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
        fi
        return 0
    else
        # Does not match
        return 1
    fi
}

# Update failure count
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

# Monitoring loop
watch_loop() {
    load_config
    echo "$(date): Daemon started" >> "$LOG_FILE"
    echo "Config: pattern=$CANARY_PATTERN, threshold=$FAILURE_THRESHOLD, interval=${CHECK_INTERVAL}s" >> "$LOG_FILE"

    local last_check_time=0
    local last_transcript_size=0

    while true; do
        local transcript=$(get_active_transcript)

        if [ -n "$transcript" ]; then
            local current_size=$(stat -c %s "$transcript" 2>/dev/null || stat -f %z "$transcript" 2>/dev/null)

            # Only check when file has changed
            if [ "$current_size" != "$last_transcript_size" ]; then
                last_transcript_size=$current_size

                if ! check_last_response "$transcript"; then
                    local count=$(update_failure_count)

                    if [ "$count" -ge "$FAILURE_THRESHOLD" ]; then
                        send_notification "🚨 Context Canary" \
                            "Context rot detected! ${count} consecutive failures. Run /compact" \
                            "critical"
                    else
                        send_notification "⚠️ Context Canary" \
                            "Warning: Claude did not follow canary instruction (${count}/${FAILURE_THRESHOLD})" \
                            "normal"
                    fi
                fi
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# Start daemon
start_daemon() {
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "Daemon already running (PID: $old_pid)"
            return 1
        fi
    fi

    echo "Starting daemon..."
    nohup "$0" watch > /dev/null 2>&1 &
    local pid=$!
    echo $pid > "$PID_FILE"
    echo "Daemon started (PID: $pid)"
    echo "Log file: $LOG_FILE"
}

# Stop daemon
stop_daemon() {
    if [ ! -f "$PID_FILE" ]; then
        echo "Daemon not running"
        return 1
    fi

    local pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        rm -f "$PID_FILE"
        echo "Daemon stopped (PID: $pid)"
    else
        rm -f "$PID_FILE"
        echo "Daemon not found, cleaned up PID file"
    fi
}

# Show status
show_status() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Status: Running (PID: $pid)"

            if [ -f "$STATE_FILE" ]; then
                local count=$(jq -r '.failure_count // 0' "$STATE_FILE")
                local last=$(jq -r '.last_failure // "none"' "$STATE_FILE")
                echo "Consecutive failures: $count"
                echo "Last failure: $last"
            fi

            echo ""
            echo "Recent logs:"
            tail -5 "$LOG_FILE" 2>/dev/null || echo "(no logs)"
            return 0
        fi
    fi

    echo "Status: Not running"
    return 1
}

# Main entry
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
        echo "Usage: $0 {start|stop|restart|status|watch}"
        echo ""
        echo "  start   - Start background daemon"
        echo "  stop    - Stop daemon"
        echo "  restart - Restart daemon"
        echo "  status  - Check running status"
        echo "  watch   - Run in foreground (for debugging)"
        exit 1
        ;;
esac
