#!/bin/bash
#
# Claude Context Canary - 全局安装脚本 (无 jq 依赖)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
PLUGINS_DIR="${CLAUDE_DIR}/plugins"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
DAEMON_SCRIPT="canary-daemon-global.sh"

echo "=========================================="
echo "  Claude Context Canary - 全局安装"
echo "=========================================="
echo ""

# 1. Auto Compact 阈值
echo "[1/4] 配置 Auto Compact 阈值"
echo "  默认 95%，建议设置 50-70%"
read -p "  输入阈值 (1-95，默认 60): " threshold
threshold="${threshold:-60}"

if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [ "$threshold" -lt 1 ] || [ "$threshold" -gt 95 ]; then
    threshold=60
fi

mkdir -p "$CLAUDE_DIR"

# 更新 settings.json（纯 bash 实现）
if [ -f "$SETTINGS_FILE" ]; then
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.backup"

    # 检查是否已有 env 和 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
    if grep -q '"env"' "$SETTINGS_FILE"; then
        if grep -q 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$SETTINGS_FILE"; then
            # 替换现有值
            sed -i.tmp "s/\"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\": \"$threshold\"/" "$SETTINGS_FILE"
            rm -f "${SETTINGS_FILE}.tmp"
        else
            # 在 env 对象中添加
            sed -i.tmp "s/\"env\"[[:space:]]*:[[:space:]]*{/\"env\": { \"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\": \"$threshold\",/" "$SETTINGS_FILE"
            rm -f "${SETTINGS_FILE}.tmp"
        fi
    else
        # 在根对象中添加 env
        sed -i.tmp "s/{/{\"env\": {\"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\": \"$threshold\"}, /" "$SETTINGS_FILE"
        rm -f "${SETTINGS_FILE}.tmp"
    fi
else
    echo "{\"env\": {\"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE\": \"$threshold\"}}" > "$SETTINGS_FILE"
fi
echo "  ✓ Auto Compact 阈值设为 ${threshold}%"

# 2. 金丝雀模式
echo ""
echo "[2/4] 配置金丝雀指令"
echo "  默认检测输出是否以 /// 开头"
read -p "  输入正则表达式 (默认 ^///): " pattern
pattern="${pattern:-^///}"

# 3. 安装守护进程
echo ""
echo "[3/4] 安装全局守护进程"

mkdir -p "$PLUGINS_DIR"
cp "$SCRIPT_DIR/$DAEMON_SCRIPT" "$PLUGINS_DIR/"
chmod +x "$PLUGINS_DIR/$DAEMON_SCRIPT"
echo "  ✓ 已安装 $PLUGINS_DIR/$DAEMON_SCRIPT"

# 创建配置
cat > "${CLAUDE_DIR}/canary-config.json" << EOF
{
  "canary_pattern": "$pattern",
  "failure_threshold": 2,
  "check_interval": 2
}
EOF
echo "  ✓ 已创建 ${CLAUDE_DIR}/canary-config.json"

# 4. 开机自启
echo ""
echo "[4/4] 配置开机自启"

if [[ "$OSTYPE" == "darwin"* ]]; then
    PLIST="${HOME}/Library/LaunchAgents/com.claude.canary.plist"
    mkdir -p "$(dirname "$PLIST")"

    # 先卸载旧的
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
    echo "  ✓ macOS LaunchAgent 已创建并启动"
    echo "  ✓ 开机自动运行"

elif [[ "$OSTYPE" == "linux"* ]]; then
    # Linux - 尝试 systemd，如果失败就跳过
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
        echo "  ✓ systemd user service 已创建"
    else
        echo "  ⚠ systemd 不可用，请手动启动守护进程"
        echo "  运行: $PLUGINS_DIR/$DAEMON_SCRIPT start"
    fi
fi

# 启动守护进程（如果还没启动）
"$PLUGINS_DIR/$DAEMON_SCRIPT" start 2>/dev/null || true

echo ""
echo "=========================================="
echo "  安装完成！"
echo "=========================================="
echo ""
echo "配置摘要:"
echo "  Auto Compact: ${threshold}%"
echo "  金丝雀模式: $pattern"
echo "  守护进程: $PLUGINS_DIR/$DAEMON_SCRIPT"
echo "  日志文件: ${CLAUDE_DIR}/canary.log"
echo ""
echo "管理命令:"
echo "  $PLUGINS_DIR/$DAEMON_SCRIPT status   # 查看状态"
echo "  $PLUGINS_DIR/$DAEMON_SCRIPT restart  # 重启"
echo "  $PLUGINS_DIR/$DAEMON_SCRIPT stop     # 停止"
echo ""
echo "最后一步 - 在全局 CLAUDE.md 添加金丝雀指令:"
echo ""
echo "  文件: ~/.claude/CLAUDE.md"
echo "  内容: 每次回复必须以 /// 开头"
echo ""

# 询问是否自动添加
read -p "是否自动添加到 ~/.claude/CLAUDE.md? (y/n): " add_canary
if [ "$add_canary" = "y" ] || [ "$add_canary" = "Y" ]; then
    GLOBAL_CLAUDE_MD="${HOME}/.claude/CLAUDE.md"
    if [ -f "$GLOBAL_CLAUDE_MD" ]; then
        if ! grep -q "每次回复必须以" "$GLOBAL_CLAUDE_MD"; then
            echo "" >> "$GLOBAL_CLAUDE_MD"
            echo "## 金丝雀指令" >> "$GLOBAL_CLAUDE_MD"
            echo "每次回复必须以 /// 开头" >> "$GLOBAL_CLAUDE_MD"
            echo "✓ 已添加到 $GLOBAL_CLAUDE_MD"
        else
            echo "⚠ 金丝雀指令已存在"
        fi
    else
        echo "## 金丝雀指令" > "$GLOBAL_CLAUDE_MD"
        echo "每次回复必须以 /// 开头" >> "$GLOBAL_CLAUDE_MD"
        echo "✓ 已创建 $GLOBAL_CLAUDE_MD"
    fi
fi

echo ""
echo "✅ 全局安装完成！重启 Claude Code 使设置生效。"
