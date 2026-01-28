#!/bin/bash
#
# Claude Context Canary - Combined Solution Installation Script
#
# Features:
# 1. Configure Auto Compact threshold (trigger compression earlier)
# 2. Install canary detection daemon (as additional warning)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
PLUGINS_DIR="${CLAUDE_DIR}/plugins"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"

echo "=========================================="
echo "  Claude Context Canary - Combined Setup"
echo "=========================================="
echo ""

# Ask for Auto Compact threshold
echo "Auto Compact Trigger Threshold:"
echo "  Default is 95% (compacts only when context is nearly full)"
echo "  Recommended 50-70% (compress earlier, reduce rot risk)"
echo ""
read -p "Enter threshold percentage (1-95, default 60): " threshold
threshold="${threshold:-60}"

# Validate input
if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [ "$threshold" -lt 1 ] || [ "$threshold" -gt 95 ]; then
    echo "Invalid input, using default 60"
    threshold=60
fi

echo ""
echo "[1/3] Configuring Auto Compact threshold to ${threshold}%..."

mkdir -p "$CLAUDE_DIR"

# Update settings.json
if [ -f "$SETTINGS_FILE" ]; then
    # Backup
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.backup"

    # Check if env config exists
    if jq -e '.env' "$SETTINGS_FILE" > /dev/null 2>&1; then
        # Update existing env
        jq --arg val "$threshold" '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = $val' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
        mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    else
        # Add env
        jq --arg val "$threshold" '. + {env: {CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: $val}}' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
        mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    fi
    echo "  ✓ Updated $SETTINGS_FILE"
    echo "  ✓ Backup saved to ${SETTINGS_FILE}.backup"
else
    # Create new file
    cat > "$SETTINGS_FILE" << EOF
{
  "env": {
    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "$threshold"
  }
}
EOF
    echo "  ✓ Created $SETTINGS_FILE"
fi

echo ""
echo "[2/3] Installing canary detection daemon..."

mkdir -p "$PLUGINS_DIR"
cp "$SCRIPT_DIR/canary-daemon.sh" "$PLUGINS_DIR/"
chmod +x "$PLUGINS_DIR/canary-daemon.sh"
echo "  ✓ Installed $PLUGINS_DIR/canary-daemon.sh"

# Config file
if [ ! -f "${CLAUDE_DIR}/canary-config.json" ]; then
    cp "$SCRIPT_DIR/canary-config.example.json" "${CLAUDE_DIR}/canary-config.json"
    echo "  ✓ Created ${CLAUDE_DIR}/canary-config.json"
fi

echo ""
echo "[3/3] Setting up auto-start (optional)..."
echo ""

# Detect system type
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS - Create LaunchAgent
    PLIST_FILE="${HOME}/Library/LaunchAgents/com.claude.canary.plist"
    read -p "Create macOS auto-start? (y/n): " auto_start

    if [ "$auto_start" = "y" ] || [ "$auto_start" = "Y" ]; then
        mkdir -p "$(dirname "$PLIST_FILE")"
        cat > "$PLIST_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.canary</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PLUGINS_DIR}/canary-daemon.sh</string>
        <string>watch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/claude-context-canary.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-context-canary.log</string>
</dict>
</plist>
EOF
        launchctl load "$PLIST_FILE" 2>/dev/null || true
        echo "  ✓ Created LaunchAgent: $PLIST_FILE"
        echo "  ✓ Daemon will auto-start on boot"
    fi

elif [[ "$OSTYPE" == "linux"* ]]; then
    # Linux - Create systemd user service
    SERVICE_DIR="${HOME}/.config/systemd/user"
    SERVICE_FILE="${SERVICE_DIR}/claude-canary.service"
    read -p "Create Linux systemd auto-start? (y/n): " auto_start

    if [ "$auto_start" = "y" ] || [ "$auto_start" = "Y" ]; then
        mkdir -p "$SERVICE_DIR"
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Claude Context Canary Daemon
After=default.target

[Service]
Type=simple
ExecStart=${PLUGINS_DIR}/canary-daemon.sh watch
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable claude-canary.service
        systemctl --user start claude-canary.service
        echo "  ✓ Created systemd service: $SERVICE_FILE"
        echo "  ✓ Daemon will auto-start on login"
    fi
fi

echo ""
echo "=========================================="
echo "  Installation Complete!"
echo "=========================================="
echo ""
echo "Configuration Summary:"
echo "  - Auto Compact Threshold: ${threshold}%"
echo "  - Canary Detection Script: $PLUGINS_DIR/canary-daemon.sh"
echo "  - Config File: ${CLAUDE_DIR}/canary-config.json"
echo ""
echo "Next Steps:"
echo "  1. Add canary instruction to your CLAUDE.md:"
echo ""
echo '     Every response must start with ///'
echo ""
echo "  2. Start the daemon (if auto-start not configured):"
echo "     $PLUGINS_DIR/canary-daemon.sh start"
echo ""
echo "  3. Restart Claude Code for Auto Compact settings to take effect"
echo ""
echo "How It Works:"
echo "  1. Auto Compact will automatically compress when context reaches ${threshold}%"
echo "  2. Canary detection serves as extra protection, notifying if Claude ignores instructions"
echo "  3. Combined, these minimize the impact of context rot"
echo ""
