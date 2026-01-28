# Claude Context Canary

上下文腐烂检测插件 - 通过"金丝雀指令"自动检测 Claude Code 的上下文是否正常工作。

## 原理

在 `claude.md` 中设置一个简单的强制指令（如"每次回复以 `///` 开头"），当 Claude 不再遵循这个指令时，说明上下文可能已经腐烂，需要执行 `/compact` 或 `/clear`。

## 安装

```bash
cd claude-context-canary
chmod +x install.sh
./install.sh
```

安装程序会让你选择：
1. **Hook 方案** - 在你发送消息时检查上一条响应
2. **守护进程方案（推荐）** - 独立后台进程实时监控
3. **两者都安装**

## 配置

### 1. 金丝雀指令

在你的 `claude.md` 或 `CLAUDE.md` 文件中添加：

```markdown
## 金丝雀指令
每次回复必须以 /// 开头
```

### 2. 配置文件

编辑 `~/.claude/canary-config.json`：

```json
{
  "canary_pattern": "^///",
  "failure_threshold": 2,
  "auto_action": "warn",
  "check_interval": 2
}
```

| 参数 | 说明 | 默认值 |
|-----|------|-------|
| `canary_pattern` | 正则表达式，检测输出是否符合要求 | `^///` |
| `failure_threshold` | 连续失败多少次后发出严重警告 | `2` |
| `auto_action` | `warn` = 仅警告，`block` = 阻止继续对话 | `warn` |
| `check_interval` | 守护进程检查间隔（秒） | `2` |

## 使用方法

### 守护进程方案

```bash
# 启动监控
~/.claude/plugins/canary-daemon.sh start

# 查看状态
~/.claude/plugins/canary-daemon.sh status

# 停止监控
~/.claude/plugins/canary-daemon.sh stop

# 前台运行（调试）
~/.claude/plugins/canary-daemon.sh watch
```

当检测到 Claude 未遵循金丝雀指令时，会：
- 发送系统通知（macOS/Linux）
- 记录到日志 `/tmp/claude-context-canary.log`

### Hook 方案

安装后自动生效。当你发送下一条消息时，会检查 Claude 上一条响应是否符合要求。

如果不符合，会：
- 向 Claude 注入警告上下文
- 当达到失败阈值且 `auto_action=block` 时，阻止发送消息

## 日志

- 守护进程日志：`/tmp/claude-context-canary.log`
- 状态文件：`~/.claude/canary-state.json`

## 限制

⚠️ **重要**：由于 Claude Code 的 API 限制，此插件**无法**自动执行 `/compact` 或 `/clear` 命令。它只能：
1. 发出警告通知
2. 阻止你继续对话（如果配置了 `auto_action=block`）

你需要手动执行清理操作。

## 故障排查

### Hook 不触发？
- 确认 `~/.claude/settings.json` 中的 hooks 配置正确
- 尝试使用守护进程方案

### 通知不显示？
- macOS：需要允许终端发送通知
- Linux：需要安装 `notify-send`

### 检测不准确？
- 调整 `canary_pattern` 正则表达式
- 确保 claude.md 中的指令清晰明确

## 卸载

```bash
rm -f ~/.claude/plugins/canary-*.sh
rm -f ~/.claude/canary-config.json
rm -f ~/.claude/canary-state.json
# 手动编辑 ~/.claude/settings.json 移除相关 hooks
```

## 许可

MIT License
