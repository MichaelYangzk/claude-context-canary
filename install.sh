#!/bin/bash
#
# Claude Context Canary - 安装脚本
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
PLUGINS_DIR="${CLAUDE_DIR}/plugins"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"

echo "=========================================="
echo "  Claude Context Canary - 安装程序"
echo "=========================================="
echo ""
echo "选择安装方案:"
echo ""
echo "  1) Hook 方案 (UserPromptSubmit)"
echo "     - 在你发送下一条消息时检查上一条响应"
echo "     - 需要配置 Claude Code hooks"
echo "     - 轻量级，无需后台进程"
echo ""
echo "  2) 守护进程方案 (推荐)"
echo "     - 独立后台进程实时监控"
echo "     - 不依赖 hooks，检测所有输出"
echo "     - 支持系统通知"
echo ""
echo "  3) 两者都安装"
echo ""
read -p "请选择 (1/2/3): " choice

mkdir -p "$PLUGINS_DIR"

install_hook() {
    echo ""
    echo "[Hook 方案] 安装中..."

    # 复制脚本
    cp "$SCRIPT_DIR/canary-check-v2.sh" "$PLUGINS_DIR/"
    chmod +x "$PLUGINS_DIR/canary-check-v2.sh"
    echo "  ✓ 已安装 $PLUGINS_DIR/canary-check-v2.sh"

    # 配置 hooks
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
        echo "  ✓ 已创建 $SETTINGS_FILE"
    else
        if grep -q "canary-check" "$SETTINGS_FILE" 2>/dev/null; then
            echo "  ⚠ hooks 已配置"
        else
            echo "  ⚠ 请手动添加以下 hook 到 $SETTINGS_FILE:"
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
    echo "[守护进程方案] 安装中..."

    # 复制脚本
    cp "$SCRIPT_DIR/canary-daemon.sh" "$PLUGINS_DIR/"
    chmod +x "$PLUGINS_DIR/canary-daemon.sh"
    echo "  ✓ 已安装 $PLUGINS_DIR/canary-daemon.sh"

    echo ""
    echo "  使用方法:"
    echo "    $PLUGINS_DIR/canary-daemon.sh start   # 启动"
    echo "    $PLUGINS_DIR/canary-daemon.sh stop    # 停止"
    echo "    $PLUGINS_DIR/canary-daemon.sh status  # 状态"
}

install_config() {
    if [ ! -f "${CLAUDE_DIR}/canary-config.json" ]; then
        cp "$SCRIPT_DIR/canary-config.example.json" "${CLAUDE_DIR}/canary-config.json"
        echo ""
        echo "[配置文件] ✓ 已创建 ${CLAUDE_DIR}/canary-config.json"
    else
        echo ""
        echo "[配置文件] ⚠ 已存在，跳过"
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
        echo "无效选择"
        exit 1
        ;;
esac

echo ""
echo "=========================================="
echo "  安装完成！"
echo "=========================================="
echo ""
echo "下一步："
echo "  1. 编辑 ${CLAUDE_DIR}/canary-config.json 自定义配置"
echo "  2. 在 claude.md 添加金丝雀指令，例如："
echo ""
echo '     ```'
echo '     每次回复必须以 /// 开头'
echo '     ```'
echo ""
if [ "$choice" = "2" ] || [ "$choice" = "3" ]; then
    echo "  3. 启动守护进程:"
    echo "     $PLUGINS_DIR/canary-daemon.sh start"
    echo ""
fi
