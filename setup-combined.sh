#!/bin/bash
#
# Claude Context Canary - 综合方案安装脚本
#
# 功能：
# 1. 配置 Auto Compact 阈值（更早触发自动压缩）
# 2. 安装金丝雀检测守护进程（作为额外警告）
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
PLUGINS_DIR="${CLAUDE_DIR}/plugins"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"

echo "=========================================="
echo "  Claude Context Canary - 综合方案"
echo "=========================================="
echo ""

# 询问 Auto Compact 阈值
echo "Auto Compact 触发阈值设置："
echo "  默认值是 95%（上下文快满时才压缩）"
echo "  建议设置 50-70%（更早压缩，减少腐烂风险）"
echo ""
read -p "请输入阈值百分比 (1-95，默认 60): " threshold
threshold="${threshold:-60}"

# 验证输入
if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [ "$threshold" -lt 1 ] || [ "$threshold" -gt 95 ]; then
    echo "无效输入，使用默认值 60"
    threshold=60
fi

echo ""
echo "[1/3] 配置 Auto Compact 阈值为 ${threshold}%..."

mkdir -p "$CLAUDE_DIR"

# 更新 settings.json
if [ -f "$SETTINGS_FILE" ]; then
    # 备份
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.backup"

    # 检查是否已有 env 配置
    if jq -e '.env' "$SETTINGS_FILE" > /dev/null 2>&1; then
        # 更新现有 env
        jq --arg val "$threshold" '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = $val' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
        mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    else
        # 添加 env
        jq --arg val "$threshold" '. + {env: {CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: $val}}' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
        mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    fi
    echo "  ✓ 已更新 $SETTINGS_FILE"
    echo "  ✓ 备份保存至 ${SETTINGS_FILE}.backup"
else
    # 创建新文件
    cat > "$SETTINGS_FILE" << EOF
{
  "env": {
    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "$threshold"
  }
}
EOF
    echo "  ✓ 已创建 $SETTINGS_FILE"
fi

echo ""
echo "[2/3] 安装金丝雀检测守护进程..."

mkdir -p "$PLUGINS_DIR"
cp "$SCRIPT_DIR/canary-daemon.sh" "$PLUGINS_DIR/"
chmod +x "$PLUGINS_DIR/canary-daemon.sh"
echo "  ✓ 已安装 $PLUGINS_DIR/canary-daemon.sh"

# 配置文件
if [ ! -f "${CLAUDE_DIR}/canary-config.json" ]; then
    cp "$SCRIPT_DIR/canary-config.example.json" "${CLAUDE_DIR}/canary-config.json"
    echo "  ✓ 已创建 ${CLAUDE_DIR}/canary-config.json"
fi

echo ""
echo "[3/3] 设置开机自启（可选）..."
echo ""

# 检测系统类型
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS - 创建 LaunchAgent
    PLIST_FILE="${HOME}/Library/LaunchAgents/com.claude.canary.plist"
    read -p "是否创建 macOS 开机自启？(y/n): " auto_start

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
        echo "  ✓ 已创建 LaunchAgent: $PLIST_FILE"
        echo "  ✓ 守护进程将在开机时自动启动"
    fi

elif [[ "$OSTYPE" == "linux"* ]]; then
    # Linux - 创建 systemd user service
    SERVICE_DIR="${HOME}/.config/systemd/user"
    SERVICE_FILE="${SERVICE_DIR}/claude-canary.service"
    read -p "是否创建 Linux systemd 开机自启？(y/n): " auto_start

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
        echo "  ✓ 已创建 systemd service: $SERVICE_FILE"
        echo "  ✓ 守护进程将在登录时自动启动"
    fi
fi

echo ""
echo "=========================================="
echo "  安装完成！"
echo "=========================================="
echo ""
echo "配置摘要："
echo "  - Auto Compact 阈值: ${threshold}%"
echo "  - 金丝雀检测脚本: $PLUGINS_DIR/canary-daemon.sh"
echo "  - 配置文件: ${CLAUDE_DIR}/canary-config.json"
echo ""
echo "下一步："
echo "  1. 在 claude.md 添加金丝雀指令："
echo ""
echo '     每次回复必须以 /// 开头'
echo ""
echo "  2. 启动守护进程（如果未设置自启）："
echo "     $PLUGINS_DIR/canary-daemon.sh start"
echo ""
echo "  3. 重启 Claude Code 使 Auto Compact 设置生效"
echo ""
echo "工作原理："
echo "  1. Auto Compact 会在上下文达到 ${threshold}% 时自动压缩"
echo "  2. 金丝雀检测作为额外保护，如果 Claude 不遵循指令会发通知"
echo "  3. 两者结合可以最大限度减少上下文腐烂的影响"
echo ""
