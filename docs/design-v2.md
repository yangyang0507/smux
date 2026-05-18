# smux v2 Design

## Overview

Add **declarative pane layout and lifecycle management** on top of existing tmux config + tmux-bridge. One command to open a labeled tmux multi-pane workspace.

**v2 does exactly one thing: reliably rebuild a labeled tmux workspace from a project root with a single readable config line.**

---

## 1. Config File `.smux`

Single file in project root. `smux start` walks up from cwd to find the nearest `.smux`.

### Syntax

```
# | split columns     , stack within column
# Each cell: LABEL COMMAND (or just LABEL for empty shell)

cmd | writer codex, tester npm test | reviewer claude
```

**Rules:**

| Rule | Description |
|------|-------------|
| `#` | Comment line |
| Blank line | Ignored |
| `\|` | Split new column horizontally |
| `,` | Stack new pane vertically within current column |
| `LABEL COMMAND` | First `[A-Za-z0-9_.-]+` word is label, remainder is command |
| `LABEL` | Label only, empty shell pane (no command) |

**No command-only shorthand.** To run `codex` with label `codex`, write `codex codex`. Explicit, simple parser, no ambiguity.

**No multi-line syntax.** Single-line DSL covers all layouts.

### Quote Rules

Everything after the label is the command. Plain spaces do NOT require quotes:

```
tester npm test -- --watch    # natural
```

Quotes are only needed when the command contains `,` or `|`:

```
runner "make test | grep -v skip"
```

Quotes are a `.smux` parsing-layer marker — **stripped before send-keys**. Minimal escape: `\"` and `\\`.

### Parser Requirements

Quote-aware: `|` and `,` inside double quotes are NOT recognized as delimiters, and spaces are not split. Outside quotes: first space separates label from command.

### Examples

```
cmd | writer codex, tester npm test | reviewer claude
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

### Syntax Decision

Chose `|` + `,`. No JSON/YAML/TOML.

---

## 2. CLI Commands

### `smux start`

```bash
smux start [-n <name>] [-d] [--replace] [--dry-run] [--preview]
```

| Option | Description |
|--------|-------------|
| `-n <name>` | Session name, defaults to project dir basename. Constrained to `[A-Za-z0-9_.-]+` |
| `-d` | Detached mode: launch in background, don't attach |
| `--replace` | Kill and replace existing smux session with same name |
| `--dry-run` | Print structured pane/label/command list, don't execute |
| `--preview` | Append Unicode layout preview (implies `--dry-run`) |

**Flow:** Find `.smux` → resolve session name → duplicate check → parse layout → create session → split panes → send-keys → set labels → attach (default)

**Safety:** `--replace` and `smux stop` only operate on sessions with `@smux_project` marker. If a session with the same name exists without the marker, reject and prompt.

**Failure handling:** send-keys errors are reported (e.g. invalid target). After commands are sent, tmux manages the processes; smux does not track whether commands exit. Panes and labels are always preserved.

### `--dry-run` Output

Structured (human-readable) output:

```text
session: myproj
project: /Users/dy/src/myproj
panes:
  cmd        (zsh)
  writer     codex
  tester     npm test -- --watch
  reviewer   claude
```

### `--preview` Output

Appends a Unicode layout preview to `--dry-run`:

```text
session: myproj
project: /Users/dy/src/myproj

┌──────────┬──────────┬──────────┐
│   cmd    │  writer  │ reviewer │
│  (zsh)   │  codex   │  claude  │
│          │──────────│          │
│          │  tester  │          │
│          │ npm tes… │          │
└──────────┴──────────┴──────────┘

panes:
  cmd        (zsh)
  writer     codex
  tester     npm test -- --watch
  reviewer   claude
```

**Preview rules:**

- Column width based on the longest label/command in that column
- Row height determined by the number of panes in the column
- Long commands truncated to `npm tes…` (trailing `…`)
- Uses Unicode box-drawing characters

### `smux stop [-n <name>]`

Kill a smux session (must have `@smux_project` marker, otherwise refuse). Without `-n`, walks up from cwd to find `.smux` and derives session name.

### `smux attach [-n <name>]`

Attach to an existing session. Without `-n`, walks up from cwd to find `.smux` and derives session name.

### `smux status`

List all smux-managed sessions (by `@smux_project` marker):

```
SESSION     PROJECT         PANES   LABELS
myproj      ~/src/myproj    4       cmd, writer, tester, reviewer
```

Label info read from `@smux_label` pane option (set by `smux start`).

---

## 3. Pane Creation Order

**Columns first, then stack within columns.** When creating column N, the split target is the top pane of column N-1 (not column 0).

```
Layout: cmd | writer codex, tester npm-test | reviewer claude

Steps:
1. new-session -d           → %0 = cmd       col[0]
2. split-window -h -t %0    → %1 = writer    col[1] top
3. split-window -h -t %1    → %2 = reviewer  col[2] top
4. select-layout even-horizontal              # equalize column widths
5. split-window -v -t %1    → %3 = tester    col[1] bottom

Result:
┌──────────┬──────────┬──────────┐
│    %0    │    %1    │    %2    │
│   cmd    │  writer  │ reviewer │
│          ├──────────┤          │
│          │    %3    │          │
│          │  tester  │          │
└──────────┴──────────┴──────────┘
```

**Implementation notes:**

- Record the first pane (top pane) of each column after creation. Subsequent vertical splits within that column target this top pane.
- **Equal height for multi-pane columns:** For k panes in a column, split sequentially top-to-bottom, using `(k-i)/k` of remaining space for pane i, achieving roughly equal heights.

---

## 4. Session Management

- **Naming:** `-n <name>` (`[A-Za-z0-9_.-]+` only) or project directory basename. Invalid basenames are rejected with a prompt to use `-n`.
- **Marker:** `@smux_project` (session option, points to project root)
- **Pane markers:** Each pane gets `@smux_label=<label>` (pane option, for `status` queries; requires tmux 3.2+)
- **Safety:** `stop` and `--replace` only operate on sessions with `@smux_project`.
- **Idempotent start:**
  - No `@smux_project` → reject, prompt manual handling
  - Has `@smux_project`, no `--replace` → reject, suggest `smux attach` or `--replace`
  - Has `@smux_project` + `--replace` → kill and rebuild

---

## 5. Roadmap

### v2.0

- `.smux` DSL (`|` + `,`)
- Quote-aware parser (with quote stripping, `\"` `\\` escape)
- `smux start / stop / attach / status`
- Auto-labeling (`@smux_label`)
- `-n` / `-d` / `--replace` / `--dry-run` / `--preview`
- `--dry-run` structured output + `--preview` Unicode layout preview
- `#` comments and blank lines
- Session safety (refuse non-smux sessions)
- Correct pane creation order (column-first, target previous column top)

### v2.1

- Size constraints (`cmd:40%`)

### Deferred

Multi-line syntax, nested layouts, config include, watch/restart — keep it thin.

---

## 6. File Changes

| File | Change | Added |
|------|--------|-------|
| `install.sh` | Add 4 commands + quote-aware parser + layout preview renderer | ~180 lines |
| `scripts/tmux-bridge` | No changes | 0 |
| `skills/smux/SKILL.md` | No changes | 0 |

**v2.0 total project size: under 1000 lines.**
