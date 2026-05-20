# smux Tutorial

A complete guide covering tmux basics, smux workspace management, and cross-pane agent communication.

---

## What is smux?

smux is three things in one:

| Component | What it does |
|-----------|-------------|
| **tmux config** | Ready-to-use tmux with keyboard shortcuts, mouse support, and pane labels |
| **smux CLI** | Declarative workspace: define pane layouts in `.smux` and launch with one command |
| **tmux-bridge** | Cross-pane communication: agents in different panes can read, type, and message each other |

Install:

```bash
curl -fsSL https://raw.githubusercontent.com/yangyang0507/smux/main/install.sh | bash
```

---

## Part 1: tmux Basics

tmux is a **terminal multiplexer** — it lets you run multiple terminal sessions inside a single window, detach and reattach them, and split your screen into panes.

### Key Concepts

```
┌─────────────────────────────────────────────┐
│  tmux server                                │
│  ├── session: myproject                     │
│  │   ├── window 0: main                     │
│  │   │   ├── pane 0:  zsh                  │
│  │   │   ├── pane 1:  codex                │
│  │   │   └── pane 2:  claude               │
│  │   └── window 1: logs                     │
│  └── session: docs                          │
└─────────────────────────────────────────────┘
```

- **Server**: One tmux server runs in the background. All sessions live here.
- **Session**: A named workspace (like a project). Detach and reattach anytime.
- **Window**: Like a tab within a session. Each window has its own pane layout.
- **Pane**: A single terminal split. Where you run commands.

### Sessions

```bash
tmux                    # start a new session (auto-named)
tmux new -s myproject  # start a named session
tmux attach -t myproject  # reattach to existing
tmux detach             # detach: Ctrl+b, then d
tmux ls                 # list all sessions
tmux kill-session -t myproject  # kill a session
```

Detaching is safe — everything keeps running in the background. Reattach later to pick up where you left off.

### Panes (with smux keybindings)

smux remaps tmux to use **Option (Alt)** instead of `Ctrl+b` prefix:

| Shortcut | Action |
|----------|--------|
| `Option+i` / `k` / `j` / `l` | Navigate up/down/left/right |
| `Option+n` | New pane (horizontal split, auto-tile) |
| `Option+w` | Close current pane |
| `Option+o` | Cycle pane layouts |
| `Option+g` | Mark pane (for swapping) |
| `Option+y` | Swap current pane with marked pane |

### Windows

| Shortcut | Action |
|----------|--------|
| `Option+m` | New window |
| `Option+u` | Next window |
| `Option+h` | Previous window |

### Copy and Paste

| Operation | How |
|-----------|-----|
| **Copy** (mouse) | Drag to select text — auto-copies to system clipboard |
| **Copy** (keyboard) | `Option+Tab` to enter copy mode → `v` to start selection → move with `i/j/k/l` → `y` to copy |
| **Paste** | `Option+v` |

### Scrolling

| Shortcut | Action |
|----------|--------|
| `Option+Tab` | Enter/exit scroll mode |
| `i` / `k` | Scroll up/down (line by line) |
| `Shift+I` / `Shift+K` | Half-page up/down |
| `q` or `Escape` | Exit scroll mode |
| Scroll wheel | Scroll naturally |

---

## Part 2: smux Workspace

smux adds a declarative way to define multi-pane layouts. Instead of manually creating panes and starting commands, you write a `.smux` file and run one command.

### Your First Workspace

Create a `.smux` file in your project root:

```
# .smux
# | split columns     , stack within column
# Each cell: LABEL COMMAND (or just LABEL for empty shell)
# # starts an inline comment outside double quotes

cmd | writer codex, tester npm test | reviewer claude
```

Preview it:

```bash
smux start --preview
```

```
┌──────────┬──────────┬──────────┐
│          │  writer  │          │
│   cmd    │  codex   │ reviewer │
│  (zsh)   │──────────│  claude  │
│          │  tester  │          │
│          │ npm test │          │
└──────────┴──────────┴──────────┘
```

Launch:

```bash
smux start
```

This creates a tmux session, splits panes according to the layout, runs each command, and labels every pane.

### `.smux` Syntax Reference

```
LABEL COMMAND        pane with a command (first word = label, rest = command)
LABEL                empty shell pane (no command)
|                    split new column to the right
,                    stack new pane below in the same column
#                    full-line or inline comment outside double quotes
```

**Examples:**

```
# Two agents side by side
codex codex | claude claude

# Agent + shell
codex codex | cmd

# Vertical stack (no columns)
writer codex, tester npm test

# Full workflow: shell | agents | review
cmd | writer codex, tester "npm test" | reviewer claude
```

**Quotes:** Only needed when a command contains `|` or `,`:

```
runner "make test | grep -v skip"    # | inside quotes is part of the command
```

### Commands

| Command | Description |
|---------|-------------|
| `smux start` | Create session from `.smux` and attach |
| `smux start --preview` | Show Unicode layout preview (no create) |
| `smux start --dry-run` | Print parsed pane list (no create) |
| `smux start -d` | Start detached (CI, remote, scripts) |
| `smux start --replace` | Kill and rebuild existing session |
| `smux start -n <name>` | Custom session name (`[A-Za-z0-9_.-]+`) |
| `smux stop` | Kill the smux session |
| `smux attach` | Re-attach to existing session |
| `smux status` | List all smux-managed sessions |
| `smux status --agents` | List labeled panes for agent discovery |
| `smux init` | Print DSL help and example layouts |
| `smux init '<layout>'` | Write `.smux` from a layout string |
| `smux doctor` | Diagnose tmux and smux state |

### Quick Start with `smux init`

```bash
smux init                          # see help with example layouts
smux init 'codex codex | cmd'      # write that layout to ./.smux
smux start --preview               # check it looks right
smux start                         # launch
```

### Example Workflow

```bash
# 1. Set up a new project
cd ~/projects/myapp

# 2. Create a layout
smux init 'cmd | writer codex, tester npm test | reviewer claude'

# 3. Preview
smux start --preview

# 4. Launch
smux start

# Now you have 4 panes: shell, writer (codex), tester (npm test), reviewer (claude)
# Each pane is labeled — see the borders

# 5. Detach to free your terminal
# (Ctrl+b, d — or just close the terminal window, tmux keeps running)

# 6. Come back later
smux attach

# 7. Check what's running
smux status
smux status --agents

# 8. Done for the day
smux stop
```

---

## Part 3: tmux-bridge — Agent Communication

tmux-bridge lets AI agents (or any process) talk to each other across tmux panes. One agent can read what's in another pane, type text into it, or send a labeled message.

### Core Commands

| Command | What it does |
|---------|-------------|
| `tmux-bridge list` | Show all panes with label, process, and location |
| `tmux-bridge read <target> [n]` | Read last n lines from a pane (default 50) |
| `tmux-bridge type <target> <text>` | Type text into a pane (no Enter pressed) |
| `tmux-bridge message <target> <text>` | Type a labeled message with sender info |
| `tmux-bridge keys <target> <key>` | Send a special key (Enter, Escape, C-c, etc.) |
| `tmux-bridge wake <target>` | Explicitly send Escape to leave tmux mode/prompt |
| `tmux-bridge name <target> <label>` | Label a pane for easy addressing |
| `tmux-bridge resolve <label>` | Find a pane by label |
| `tmux-bridge id` | Print current pane's ID |

### Read Guard

tmux-bridge enforces **read-before-act**: you must read a pane before you can type into it or send keys to it.

```
$ tmux-bridge type codex 'hello'
error: must read the pane before interacting. Run: tmux-bridge read codex
```

This prevents agents from blindly typing into a pane they haven't checked first.

### The Read-Act-Read Cycle

Every interaction follows three steps:

```
1. READ    tmux-bridge read <target>     # check the pane, satisfy guard
2. ACT     tmux-bridge message <target>  # type your message (no Enter)
3. READ    tmux-bridge read <target>     # verify the text landed
4. ACT     tmux-bridge keys <target> Enter  # press Enter to submit
```

### Sending a Message to Another Agent

```bash
# 1. Read the target pane
tmux-bridge read codex 20

# 2. Send a labeled message (auto-prepends sender info)
tmux-bridge message codex 'Please review src/auth.ts'

# 3. Verify the text appeared
tmux-bridge read codex 20

# 4. Press Enter to submit
tmux-bridge keys codex Enter

# STOP. Do not poll or wait. The other agent will reply into YOUR pane.
```

The receiving agent sees:

```
[tmux-bridge from:claude pane:%4 at:myproj:0.0] Please review src/auth.ts
```

The header tells them: who sent it (`from`), which pane to reply to (`pane`), and the session/window location (`at`).

### Replying to a Message

When you see a `[tmux-bridge from:...]` message in your pane, reply using the **pane** from the header:

```bash
tmux-bridge read %4 20
tmux-bridge message %4 '87% coverage. Missing OAuth refresh path (lines 142-168).'
tmux-bridge read %4 20
tmux-bridge keys %4 Enter
```

### Full Conversation Example

**Setup:** Two panes, one labeled `claude` running Claude Code, one labeled `codex` running Codex.

```
# Claude's pane:
tmux-bridge name "$(tmux-bridge id)" claude

# Codex's pane:
tmux-bridge name "$(tmux-bridge id)" codex
```

**Claude asks Codex for help:**

```bash
tmux-bridge read codex 20
tmux-bridge message codex 'What does the auth middleware expect in the header?'
tmux-bridge read codex 20
tmux-bridge keys codex Enter
```

**Codex sees:**
```
[tmux-bridge from:claude pane:%4 at:myproj:0.0] What does the auth middleware expect in the header?
```

**Codex replies:**

```bash
tmux-bridge read %4 20
tmux-bridge message %4 'It expects Authorization: Bearer <token> and validates JWT expiry.'
tmux-bridge read %4 20
tmux-bridge keys %4 Enter
```

**Claude receives the reply directly in its pane.** No polling. No waiting.

### Talking to Non-Agent Panes

If the target pane is a plain shell or running process (no agent that will reply), you DO need to read after sending to see the result:

```bash
tmux-bridge read worker 10        # see the prompt
tmux-bridge type worker 'y'       # type response
tmux-bridge read worker 10        # verify
tmux-bridge keys worker Enter     # submit
tmux-bridge read worker 20        # read the result
```

---

## Quick Reference

### tmux (smux keybindings)

| Shortcut | Action |
|----------|--------|
| `Option+i/j/k/l` | Navigate panes |
| `Option+n` | New pane |
| `Option+w` | Close pane |
| `Option+m` | New window |
| `Option+u/h` | Next/previous window |
| `Option+Tab` | Scroll mode |
| `Option+v` | Paste |

### smux CLI

| Command | Action |
|---------|--------|
| `smux start` | Launch workspace |
| `smux start --preview` | Preview layout |
| `smux stop` | Kill session |
| `smux attach` | Reattach |
| `smux status` | List sessions |
| `smux init` | Show DSL help |
| `smux doctor` | Diagnostics |

### tmux-bridge

| Command | Action |
|---------|--------|
| `tmux-bridge list` | List all panes |
| `tmux-bridge read <t> [n]` | Read n lines |
| `tmux-bridge message <t> <text>` | Send labeled message |
| `tmux-bridge type <t> <text>` | Type text |
| `tmux-bridge keys <t> <key>` | Send key |
| `tmux-bridge name <t> <label>` | Label pane |
