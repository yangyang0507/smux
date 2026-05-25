# smux v2.3 — Agent Pipeline & Message Improvements

## Overview

v2.3 adds agent workflow pipelines (A → B → C automated hand-offs) and improves the `message` / `file` commands with `--enter` and `--brief` flags.

---

## Pipeline (Flow)

### Problem

smux v2.2 provides workspace creation (`.smux` → panes) and point-to-point agent communication (`tmux-bridge message/read/keys`). But there's no way to define multi-step workflows where agent output chains automatically: A completes → B receives context → B completes → C receives context.

### Design

Pipelines are defined in `.smux` as a `pipeline:` block below the layout line. The pipeline runs inside an already-started smux session and is tracked via `/tmp` state files.

### `.smux` Pipeline Syntax

```
# Layout line (unchanged)
cmd | writer codex, tester "npm test | grep skip" | reviewer claude

# Pipeline block (new)
pipeline: review
  steps:
    writer -> tester   "Run tests on the changes and report results"
    tester -> reviewer "Review the test results and code quality"
```

**Grammar:**
- `pipeline: <name>` — pipeline declaration
- `steps:` — step block marker
- `FROM -> TO "<PROMPT>"` — step: from label, to label, and the natural-language prompt the next agent receives
- Indented lines under `steps:` are parsed as steps; blank/comment lines skipped
- Inline `#` comments and double-quoted prompts supported

### Parsing

`parse_pipeline()` in `install.sh` reuses the existing `strip_inline_comment()` and `trim()` utilities from the layout parser. A new `pipeline_lines()` extractor filters `.smux` lines to only pipeline-relevant content, keeping the parsing orthogonal to `layout_line()`.

`layout_line()` was updated to skip pipeline lines and indented step lines, so existing workspaces with pipeline blocks don't break.

### State Tracking

Two files in `$TMPDIR`:

| File | Pattern | Content |
|------|---------|---------|
| State | `tmux-bridge-flow-<session>-<name>` | Current step index (0-based) |
| Context | `tmux-bridge-flow-<session>-<name>.ctx` | KEY=VALUE: session, name, steps, step_N=FROM\|TO\|PANE_ID\|PROMPT |

The context file pre-resolves all pane IDs at start time, so `tmux-bridge flow step` doesn't need to re-query labels on each step.

### Flow Commands

| Command | Where | Purpose |
|---------|-------|---------|
| `smux flow start [--pipeline <name>] [message...]` | install.sh | Explicit start with optional initial message |
| `smux flow status` | install.sh | Show all steps and current progress |
| `smux flow reset [--pipeline <name>]` | install.sh | Delete state + context files |
| `tmux-bridge flow step` | scripts/tmux-bridge | Agent submits current step → routes to next |

### Auto-Start

When `tmux-bridge flow step` is called with no active pipeline:
1. Reads `@smux_project` from the tmux session
2. Opens and parses `.smux` with an inline parser (`flow_parse_smux` in tmux-bridge)
3. Validates the calling agent's `@name` matches step 0's `from` label
4. Writes state and context files
5. Routes output to the first target agent

### Routing Protocol

Each `flow step` call:
1. Captures the sender pane's last 50 lines via `capture-pane -S -50`
2. Constructs `[flow: <name> step N/TOTAL] <prompt>`
3. Types `--- output from previous step ---` separator
4. Types captured output line by line
5. Sends Enter to submit
6. Advances state; clears state + context on last step with `[flow: <name> done]` message

### Limitations (by design)

- Single pipeline per `.smux`
- Labels must match pane `@name` values (set by `smux start`)
- No branching or conditional steps
- Agent must explicitly call `tmux-bridge flow step`; no auto-detection
- Context capture is fixed at 50 lines

---

## Message `--enter`

### Problem

Agent-to-agent `message` required three steps: `message` (type) → `read` (verify) → `keys Enter` (submit). The `read` between type and submit was often rote for agent-to-agent communication where immediate submission is desired.

### Design

A `--enter` flag on `message` that auto-sends Enter after typing:

```bash
# Before (3 steps)
printf '%s' "$msg" | tmux-bridge message codex --stdin
tmux-bridge read codex 20
tmux-bridge keys codex Enter

# After (1 step)
printf '%s' "$msg" | tmux-bridge message codex --stdin --enter
```

`--enter` is parsed from any argument position — it's extracted before `parse_text()` runs, so it works with `--enter --stdin`, `--stdin --enter`, or `--enter 'hello'`.

`type` is unchanged — it remains "type without Enter" for non-agent interactions where verification matters.

---

## File `--brief`

### Problem

When an agent sends both `file` and `message` to the same target, two `[tmux-bridge from:...]` headers appeared — one from `file`, one from `message`.

### Design

`--brief` on `file` omits the `[tmux-bridge from:...]` header, leaving only the file metadata:

```
# Without --brief (standalone file):
[tmux-bridge from:claude pane:%4 at:...] Shared file 'diff.txt' (42 lines, 1234 bytes, full): /tmp/...

# With --brief (combined with message):
Shared file 'diff.txt' (42 lines, 1234 bytes, full): /tmp/...
```

The sender info is provided by the accompanying `message` command.

---

## Compatibility

All changes are additive:
- `.smux` files without `pipeline:` blocks behave exactly as before
- `message` without `--enter` preserves the original behavior
- `file` without `--brief` preserves the original header
- Tab completions updated for all new commands and flags
