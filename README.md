# smux

One-command tmux setup with terminal automation for AI agents.

- **For you** — keyboard-driven tmux config with Option-key bindings, mouse support, and pane labels
- **For agents** — `tmux-bridge` CLI lets any agent read, type, and send keys to any pane
- **Agent-to-agent** — Claude Code can prompt Codex in the next pane, and Codex replies back. Any agent that can run bash can participate.
- **Agent pipeline** — define multi-step workflows in `.smux` (A → B → C), agents call `tmux-bridge flow step` to chain output
- **Declarative workspace** — define pane layout + startup commands in `.smux`, launch with one command

📖 **[smux Tutorial](docs/tutorial.md)** — complete guide covering tmux, smux, and tmux-bridge

```bash
tmux-bridge read codex 20
tmux-bridge message codex --enter 'review src/auth.ts'
```

## Quick Start

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/yangyang0507/smux/main/install.sh | bash

# Create a workspace layout in your project
smux init 'cmd | writer codex, tester npm test | reviewer claude'

# Launch
smux start --preview    # preview the layout
smux start              # create the tmux session
smux stop               # stop it
```

This installs:
- **tmux** if not already installed (via Homebrew, apt, dnf, pacman, or apk)
- **tmux.conf** with Option-key bindings, mouse support, pane labels, and a minimal status bar
- **tmux-bridge** CLI for cross-pane agent communication
- **smux CLI** for workspace lifecycle management

Everything lives in `~/.smux/`.

## Update

```bash
smux update --check   # compare installed vs source
smux update --dry-run  # preview changes
smux update            # apply updates
```

## Uninstall

```bash
smux uninstall
```

## AI Agent Skills

Install the smux skill to teach your agents how to use tmux-bridge:

```bash
npx skills add yangyang0507/smux
```

Works with Claude Code, Codex, Cursor, Copilot, and [40+ other agents](https://skills.sh).

## Keybindings

All keybindings use **Option (Alt)** with no prefix required.

### Panes

| Key | Action |
|---|---|
| `Option+i/k/j/l` | Navigate up/down/left/right (no wrap) |
| `Option+n` | New pane (split + auto-tile) |
| `Option+w` | Close pane |
| `Option+o` | Cycle layouts |
| `Option+g` | Mark pane |
| `Option+y` | Swap with marked pane |

### Windows

| Key | Action |
|---|---|
| `Option+m` | New window |
| `Option+u` | Next window |
| `Option+h` | Previous window |

### Scrolling

| Key | Action |
|---|---|
| `Option+Tab` | Toggle scroll mode |
| `i/k` | Scroll up/down |
| `Shift+I/K` | Half-page up/down |
| `q` or `Escape` | Exit scroll mode |

### Copy & Paste

| Operation | How |
|-----------|-----|
| Copy (mouse) | Drag to select text — auto-copies to clipboard |
| Copy (keyboard) | `Option+Tab` → `v` to select → `y` to copy |
| Paste | `Option+v` |

### Mouse

- Click to select panes
- Drag to select text (auto-copies to clipboard)
- Scroll wheel to scroll

## tmux-bridge

A CLI for cross-pane communication. Any tool that can run bash can use it — Claude Code, Codex, Gemini CLI, or a plain shell script.

| Command | Description |
|---|---|
| `tmux-bridge list` | Show all panes with target, process, label |
| `tmux-bridge read <target> [lines]` | Read last N lines from a pane |
| `tmux-bridge type <target> <text>` | Type text into a pane (no Enter) |
| `tmux-bridge message <target> <text>` | Type a labeled cross-pane message (use `--enter` to auto-submit) |
| `tmux-bridge file <target> <path>` | Stage a file and send the shared path to the target |
| `tmux-bridge keys <target> <key>...` | Send keys (Enter, Escape, C-c, etc.) |
| `tmux-bridge flow step` | Submit current pipeline step and route to next agent |
| `tmux-bridge wake <target>` | Explicitly send Escape to leave tmux mode/prompt |
| `tmux-bridge name <target> <label>` | Label a pane for easy addressing |
| `tmux-bridge resolve <label>` | Look up a pane by label |
| `tmux-bridge id` | Print this pane's ID |

See the [smux skill](skills/smux/SKILL.md) for full documentation on agent-to-agent workflows.

## Pipeline (Flow)

Define agent workflows in `.smux` with a `pipeline:` block. Each step specifies which agent hands off to which:

```
cmd | writer codex, tester npm test | reviewer claude

pipeline: review
  steps:
    writer -> tester   "Run tests on the changes and report results"
    tester -> reviewer "Review the test results and code quality"
```

```bash
smux flow start "Implement login with JWT auth"
smux flow status                  # see progress
smux flow reset                   # restart pipeline

# Agents submit steps from within their panes:
tmux-bridge flow step             # auto-starts pipeline if not running
```

## Workspace Commands

```bash
smux init [--force] '<layout>'
smux start [-n <name>] [-d] [--replace] [--dry-run] [--preview]
smux stop  [-n <name>]
smux attach [-n <name>]
smux status
smux status --agents
smux flow start [--pipeline <name>] [message...]
smux flow status
smux flow reset [--pipeline <name>]
smux update [--check] [--dry-run]
smux doctor
```

| Command | Description |
|---|---|
| `smux init` | Show `.smux` syntax help and common layouts |
| `smux init '<layout>'` | Validate and write `.smux` in the current directory |
| `smux start` | Create a tmux session from `.smux` layout |
| `smux start --dry-run` | Print the parsed session/pane plan without creating anything |
| `smux start --preview` | Show the layout without creating anything |
| `smux start -d` | Start detached (CI / remote / agent loop) |
| `smux start --replace` | Replace an existing smux-managed session |
| `smux stop` | Kill the smux-managed session |
| `smux attach` | Re-attach to the session |
| `smux status` | List all smux-managed sessions |
| `smux status --agents` | List labeled panes for agent discovery |
| `smux update` | Update installed files to latest |
| `smux update --check` | Check for drift between source and installed files |
| `smux update --dry-run` | Show what update would do without changing files |
| `smux flow start [--pipeline <name>] [message...]` | Start an agent pipeline with an initial task |
| `smux flow status` | Show pipeline steps and current progress |
| `smux flow reset [--pipeline <name>]` | Reset pipeline to the first step |
| `smux doctor` | Diagnose tmux, config, project layout, and sessions |

`.smux` syntax:
```
# | split columns     , stack within column
# Each cell: LABEL COMMAND (or just LABEL for empty shell pane)
# # starts an inline comment outside double quotes

cmd | writer codex, tester "npm test | grep skip" | reviewer claude
```

## Tab Completion

```bash
source ~/.smux/completions/tmux-bridge.bash  # tmux-bridge <tab> → subcommands, pane labels
source ~/.smux/completions/smux.bash          # smux <tab> → subcommands, session names
```

Add to `~/.bashrc` or `~/.zshrc` for automatic loading. `smux doctor` checks completion status.

## Requirements

- macOS (requires [Homebrew](https://brew.sh)) or Linux
- tmux 3.2+ (installed automatically)
