#!/bin/bash
#
# Claude Context Canary - Global Installation Script (no jq dependency)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
PLUGINS_DIR="${CLAUDE_DIR}/plugins"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
DAEMON_SCRIPT="canary-daemon-global.sh"

echo "=========================================="
echo "  Claude Context Canary - Global Install"
echo "=========================================="
echo ""

# 1. Auto Compact threshold
echo "[1/4] Configure Auto Compact Threshold"
echo "  Default is 95%, recommended 50-70%"
read -p "  Enter threshold (1-95, default 60): " threshold
threshold="${threshold:-60}"

if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [ "$threshold" -lt 1 ] || [ "$threshold" -gt 95 ]; then
    threshold=60
fi

mkdir -p "$CLAUDE_DIR"

# Update settings.json (pure bash implementation)
if [ -f "$SETTINGS_FILE" ]; then
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.backup"

    # Check if env and CLAUDE_AUTOCOMPACT_PCT_OVERRIDE exist
    if grep -q '"env"' "$SETTINGS_FILE"; then
        if grep -q 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$SETTINGS_FILE"; then
            # Replace existing value
            sed -i.tmp "s/\"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\": \"$threshold\"/" "$SETTINGS_FILE"
            rm -f "${SETTINGS_FILE}.tmp"
        else
            # Add to existing env object
            sed -i.tmp "s/\"env\"[[:space:]]*:[[:space:]]*{/\"env\": { \"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\": \"$threshold\",/" "$SETTINGS_FILE"
            rm -f "${SETTINGS_FILE}.tmp"
        fi
    else
        # Add env to root object
        sed -i.tmp "s/{/{\"env\": {\"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\": \"$threshold\"}, /" "$SETTINGS_FILE"
        rm -f "${SETTINGS_FILE}.tmp"
    fi
else
    echo "{\"env\": {\"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\": \"$threshold\"}}" > "$SETTINGS_FILE"
fi
echo "  ✓ Auto Compact threshold set to ${threshold}%"

# 2. Canary pattern
echo ""
echo "[2/4] Configure Canary Pattern"
echo "  Default: check if output starts with ///"
read -p "  Enter regex pattern (default ^///): " pattern
pattern="${pattern:-^///}"

# 3. Install daemon
echo ""
echo "[3/4] Install Global Daemon"

mkdir -p "$PLUGINS_DIR"
cp "$SCRIPT_DIR/$DAEMON_SCRIPT" "$PLUGINS_DIR/"
chmod +x "$PLUGINS_DIR/$DAEMON_SCRIPT"
echo "  ✓ Installed $PLUGINS_DIR/$DAEMON_SCRIPT"

# Create config
cat > "${CLAUDE_DIR}/canary-config.json" << EOF
{
  "canary_pattern": "$pattern",
  "failure_threshold": 2,
  "check_interval": 2
}
EOF
echo "  ✓ Created ${CLAUDE_DIR}/canary-config.json"

# 4. Auto-start on boot
echo ""
echo "[4/4] Configure Auto-Start"

if [[ "$OSTYPE" == "darwin"* ]]; then
    PLIST="${HOME}/Library/LaunchAgents/com.claude.canary.plist"
    mkdir -p "$(dirname "$PLIST")"

    # Unload old one first
    launchctl unload "$PLIST" 2>/dev/null || true

    cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.canary</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PLUGINS_DIR}/${DAEMON_SCRIPT}</string>
        <string>watch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${CLAUDE_DIR}/canary.log</string>
    <key>StandardErrorPath</key>
    <string>${CLAUDE_DIR}/canary.log</string>
</dict>
</plist>
EOF

    launchctl load "$PLIST"
    echo "  ✓ macOS LaunchAgent created and started"
    echo "  ✓ Will auto-run on boot"

elif [[ "$OSTYPE" == "linux"* ]]; then
    # Linux - try systemd, skip if unavailable
    if command -v systemctl &> /dev/null; then
        SERVICE_DIR="${HOME}/.config/systemd/user"
        SERVICE="${SERVICE_DIR}/claude-canary.service"
        mkdir -p "$SERVICE_DIR"

        cat > "$SERVICE" << EOF
[Unit]
Description=Claude Context Canary Global Daemon
After=default.target

[Service]
Type=simple
ExecStart=${PLUGINS_DIR}/${DAEMON_SCRIPT} watch
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable claude-canary.service 2>/dev/null || true
        systemctl --user start claude-canary.service 2>/dev/null || true
        echo "  ✓ systemd user service created"
    else
        echo "  ⚠ systemd not available, please start daemon manually"
        echo "  Run: $PLUGINS_DIR/$DAEMON_SCRIPT start"
    fi
fi

# Start daemon (if not already running)
"$PLUGINS_DIR/$DAEMON_SCRIPT" start 2>/dev/null || true

echo ""
echo "=========================================="
echo "  Installation Complete!"
echo "=========================================="
echo ""
echo "Configuration Summary:"
echo "  Auto Compact: ${threshold}%"
echo "  Canary Pattern: $pattern"
echo "  Daemon: $PLUGINS_DIR/$DAEMON_SCRIPT"
echo "  Log File: ${CLAUDE_DIR}/canary.log"
echo ""
echo "Management Commands:"
echo "  $PLUGINS_DIR/$DAEMON_SCRIPT status   # Check status"
echo "  $PLUGINS_DIR/$DAEMON_SCRIPT restart  # Restart"
echo "  $PLUGINS_DIR/$DAEMON_SCRIPT stop     # Stop"
echo ""
echo "Final Step - Add canary instruction to global CLAUDE.md:"
echo ""
echo "  File: ~/.claude/CLAUDE.md"
echo "  Content: Every response must start with ///"
echo ""

# Ask if user wants to auto-add
read -p "Auto-add to ~/.claude/CLAUDE.md? (y/n): " add_canary
if [ "$add_canary" = "y" ] || [ "$add_canary" = "Y" ]; then
    GLOBAL_CLAUDE_MD="${HOME}/.claude/CLAUDE.md"
    if [ -f "$GLOBAL_CLAUDE_MD" ]; then
        if ! grep -q "Every response must start with" "$GLOBAL_CLAUDE_MD"; then
            echo "" >> "$GLOBAL_CLAUDE_MD"
            echo "## Canary Instruction" >> "$GLOBAL_CLAUDE_MD"
            echo "Every response must start with ///" >> "$GLOBAL_CLAUDE_MD"
            echo "✓ Added to $GLOBAL_CLAUDE_MD"
        else
            echo "⚠ Canary instruction already exists"
        fi
    else
        echo "## Canary Instruction" > "$GLOBAL_CLAUDE_MD"
        echo "Every response must start with ///" >> "$GLOBAL_CLAUDE_MD"
        echo "✓ Created $GLOBAL_CLAUDE_MD"
    fi
fi

echo ""
echo "✅ Global installation complete! Restart Claude Code for settings to take effect."
