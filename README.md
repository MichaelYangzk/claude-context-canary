# Claude Context Canary 🐤

**Detect context rot in Claude Code before it causes problems.**

A context corruption / context rot detection plugin for Claude Code CLI - automatically detect when Claude's context window has degraded using a simple "canary" instruction technique.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Why "Canary"?

> *In the early days of coal mining, miners would bring canaries into the mines with them. These small birds are extremely sensitive to toxic gases like carbon monoxide and methane. If dangerous gases were present, the canary would show signs of distress or die before the gas levels became lethal to the miners, giving them time to evacuate.*

This plugin applies the same principle to AI context management. Instead of a bird, we use a simple instruction that Claude must follow (like "start every response with `///`"). When Claude stops following this trivial instruction, it's our "canary" warning us that the context has become corrupted - time to run `/compact` or `/clear`!

## The Problem: Context Rot

When using Claude Code for extended sessions, the context window can become "corrupted" or "rotted" - Claude starts forgetting instructions, ignoring rules in CLAUDE.md, or producing inconsistent outputs. This is especially problematic when:

- Working on long coding sessions
- Having many back-and-forth exchanges
- Context window approaching capacity

## The Solution: Canary Instructions

This plugin uses a "canary in the coal mine" approach:

1. Add a simple, easy-to-verify instruction to your CLAUDE.md (e.g., "Every response must start with `///`")
2. The plugin monitors Claude's responses
3. When Claude stops following this trivial instruction, it's a reliable indicator that context has degraded
4. You get notified to run `/compact` or `/clear`

## Features

- 🔍 **Real-time monitoring** - Daemon watches all Claude Code sessions
- 🔔 **System notifications** - Desktop alerts on macOS and Linux
- ⚙️ **Auto Compact threshold** - Configure when auto-compaction triggers
- 🚫 **No jq dependency** - Pure bash implementation
- 🖥️ **Cross-platform** - Works on macOS and Linux
- 🚀 **Auto-start** - Runs on system boot (LaunchAgent/systemd)

## Quick Start

```bash
git clone https://github.com/MichaelYangzk/claude-context-canary.git
cd claude-context-canary
./install-global.sh
```

The installer will:
1. Configure Auto Compact threshold (recommended: 50-70%)
2. Set up the canary pattern (default: `^///`)
3. Install the monitoring daemon
4. Configure auto-start on boot
5. Optionally add the canary instruction to your `~/.claude/CLAUDE.md`

## Installation Options

### Global Install (Recommended)

```bash
./install-global.sh
```

Monitors all Claude Code projects system-wide.

### Project-specific Install

```bash
./install.sh
```

Choose between:
1. **Hook Method** - Checks previous response when you send a message
2. **Daemon Method** - Independent background process for real-time monitoring
3. **Both**

## Configuration

### Canary Instruction

Add to your `CLAUDE.md` file:

```markdown
## Canary Instruction
Every response must start with ///
```

### Configuration File

Edit `~/.claude/canary-config.json`:

```json
{
  "canary_pattern": "^///",
  "failure_threshold": 2,
  "auto_action": "warn",
  "check_interval": 2
}
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `canary_pattern` | Regex to verify response format | `^///` |
| `failure_threshold` | Failures before critical alert | `2` |
| `auto_action` | `warn` or `block` conversation | `warn` |
| `check_interval` | Check interval in seconds | `2` |

## Usage

### Daemon Commands

```bash
~/.claude/plugins/canary-daemon-global.sh status   # Check status
~/.claude/plugins/canary-daemon-global.sh restart  # Restart daemon
~/.claude/plugins/canary-daemon-global.sh stop     # Stop daemon
~/.claude/plugins/canary-daemon-global.sh watch    # Run in foreground (debug)
```

### What Happens When Context Rot is Detected

1. **First failure**: Warning notification
2. **Consecutive failures**: Critical alert recommending `/compact`
3. **If `auto_action=block`**: Prevents sending more messages until cleared

## How It Works

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   CLAUDE.md     │     │  Canary Daemon   │     │  Notification   │
│                 │     │                  │     │                 │
│ "Start with ///"│────▶│ Monitor responses│────▶│ "Context rot    │
│                 │     │ Check pattern    │     │  detected!"     │
└─────────────────┘     └──────────────────┘     └─────────────────┘
```

1. Daemon monitors `~/.claude/projects/*/transcript.jsonl` files
2. Extracts Claude's responses and checks against canary pattern
3. Tracks consecutive failures
4. Sends system notification when threshold exceeded

## Logs & State

- **Daemon log**: `~/.claude/canary.log`
- **State file**: `~/.claude/canary-state.json`
- **Config file**: `~/.claude/canary-config.json`

## Limitations

⚠️ Due to Claude Code API limitations, this plugin **cannot** automatically execute `/compact` or `/clear`. It only:
- Sends warning notifications
- Optionally blocks conversation until you take action

You must manually run `/compact` or `/clear` when notified.

## Troubleshooting

### Notifications not showing?
- **macOS**: System Preferences → Notifications → Allow from Terminal
- **Linux**: Install `notify-send` (`apt install libnotify-bin`)

### Daemon not starting?
```bash
# Check logs
cat ~/.claude/canary.log

# Run in foreground to debug
~/.claude/plugins/canary-daemon-global.sh watch
```

### False positives?
- Adjust `canary_pattern` regex
- Increase `failure_threshold`
- Make sure your canary instruction is clear and simple

## Uninstall

```bash
# Stop daemon
~/.claude/plugins/canary-daemon-global.sh stop

# Remove files
rm -f ~/.claude/plugins/canary-*.sh
rm -f ~/.claude/canary-config.json
rm -f ~/.claude/canary-state.json

# macOS: Remove LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.claude.canary.plist
rm -f ~/Library/LaunchAgents/com.claude.canary.plist

# Linux: Remove systemd service
systemctl --user disable claude-canary.service
rm -f ~/.config/systemd/user/claude-canary.service
```

## Related Concepts

- **Context window management** - Managing LLM context limits
- **Context rot / context corruption** - Degradation of AI response quality over extended sessions
- **Prompt injection detection** - Monitoring AI behavior consistency
- **Claude Code CLI** - Anthropic's official CLI tool for Claude

## Contributing

Issues and PRs welcome!

## License

MIT License

---

**Keywords**: Claude Code, context rot, context corruption, context window, LLM monitoring, Claude CLI, AI context management, canary test, prompt degradation detection
