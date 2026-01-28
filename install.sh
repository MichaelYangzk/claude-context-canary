#!/bin/bash
#
# Claude Context Canary - Installation Script
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
PLUGINS_DIR="${CLAUDE_DIR}/plugins"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"

echo "=========================================="
echo "  Claude Context Canary - Installer"
echo "=========================================="
echo ""
echo "Select installation method:"
echo ""
echo "  1) Hook Method (UserPromptSubmit)"
echo "     - Checks previous response when you send a message"
echo "     - Requires Claude Code hooks configuration"
echo "     - Lightweight, no background process"
echo ""
echo "  2) Daemon Method (Recommended)"
echo "     - Independent background process for real-time monitoring"
echo "     - No hooks dependency, monitors all outputs"
echo "     - Supports system notifications"
echo ""
echo "  3) Install both"
echo ""
read -p "Choose (1/2/3): " choice

mkdir -p "$PLUGINS_DIR"

install_hook() {
    echo ""
    echo "[Hook Method] Installing..."

    # Copy script
    cp "$SCRIPT_DIR/canary-check-v2.sh" "$PLUGINS_DIR/"
    chmod +x "$PLUGINS_DIR/canary-check-v2.sh"
    echo "  ✓ Installed $PLUGINS_DIR/canary-check-v2.sh"

    # Configure hooks
    if [ ! -f "$SETTINGS_FILE" ]; then
        cat > "$SETTINGS_FILE" << 'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/plugins/canary-check-v2.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
EOF
        echo "  ✓ Created $SETTINGS_FILE"
    else
        if grep -q "canary-check" "$SETTINGS_FILE" 2>/dev/null; then
            echo "  ⚠ Hooks already configured"
        else
            echo "  ⚠ Please manually add the following hook to $SETTINGS_FILE:"
            echo ""
            echo '    "UserPromptSubmit": ['
            echo '      {'
            echo '        "hooks": ['
            echo '          {'
            echo '            "type": "command",'
            echo '            "command": "~/.claude/plugins/canary-check-v2.sh",'
            echo '            "timeout": 5'
            echo '          }'
            echo '        ]'
            echo '      }'
            echo '    ]'
        fi
    fi
}

install_daemon() {
    echo ""
    echo "[Daemon Method] Installing..."

    # Copy script
    cp "$SCRIPT_DIR/canary-daemon.sh" "$PLUGINS_DIR/"
    chmod +x "$PLUGINS_DIR/canary-daemon.sh"
    echo "  ✓ Installed $PLUGINS_DIR/canary-daemon.sh"

    echo ""
    echo "  Usage:"
    echo "    $PLUGINS_DIR/canary-daemon.sh start   # Start"
    echo "    $PLUGINS_DIR/canary-daemon.sh stop    # Stop"
    echo "    $PLUGINS_DIR/canary-daemon.sh status  # Status"
}

install_config() {
    if [ ! -f "${CLAUDE_DIR}/canary-config.json" ]; then
        cp "$SCRIPT_DIR/canary-config.example.json" "${CLAUDE_DIR}/canary-config.json"
        echo ""
        echo "[Config] ✓ Created ${CLAUDE_DIR}/canary-config.json"
    else
        echo ""
        echo "[Config] ⚠ Already exists, skipped"
    fi
}

case "$choice" in
    1)
        install_hook
        install_config
        ;;
    2)
        install_daemon
        install_config
        ;;
    3)
        install_hook
        install_daemon
        install_config
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "=========================================="
echo "  Installation Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Edit ${CLAUDE_DIR}/canary-config.json to customize settings"
echo "  2. Add canary instruction to your CLAUDE.md, for example:"
echo ""
echo '     ```'
echo '     Every response must start with ///'
echo '     ```'
echo ""
if [ "$choice" = "2" ] || [ "$choice" = "3" ]; then
    echo "  3. Start the daemon:"
    echo "     $PLUGINS_DIR/canary-daemon.sh start"
    echo ""
fi
