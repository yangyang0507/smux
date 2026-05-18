# smux v2.1 Design — Quality of Life

## Overview

v2.1 makes `smux start` failures self-explanatory and first-time setup under a minute. No new DSL features — just `init`, `doctor`, and better errors.

Priority order: **better errors → `smux init` → `smux doctor`**.

---

## 1. Better Error Messages

Every existing error gets replaced with a specific, actionable message.

### Implementation

All error strings live in `cmd_start`, `parse_layout`, `session_name_for`, `find_project_root`, `require_smux_session`. No new infrastructure needed — just replace `error "..."` with richer text.

| Current | v2.1 | Where |
|---------|------|-------|
| `No .smux found from $PWD upward.` | `No .smux found from /path/foo upward. Run 'smux init' to create one.` | `find_project_root` |
| `Invalid session name '...'.` | `Invalid session name 'my project'. Session names must match [A-Za-z0-9_.-]+. Use 'smux start -n my-project'.` | `session_name_for` |
| `Unclosed quote in .smux layout.` | `Unclosed quote in .smux layout: cmd \| tester "npm test. Fix the quote, then run 'smux start --dry-run' to verify.` | `parse_layout` |
| `Empty column/pane in .smux layout.` | `Empty pane near 'cmd \| , tester' in .smux. Remove the extra comma or add a label.` | `parse_layout` |
| `Invalid label '...'.` | `Invalid label 'test runner'. Labels must match [A-Za-z0-9_.-]+. Use 'test-runner npm test'.` | `parse_layout` |
| `Session 'X' already exists.` (smux) | `Session 'myproj' already exists and is smux-managed. Use 'smux attach -n myproj', or 'smux start --replace' to rebuild it.` | `start_layout` |
| `Session 'X' exists and is not managed by smux.` | `Session 'dev' already exists but is not managed by smux. Choose another name with '-n', or handle it manually in tmux.` | `start_layout` |
| `.smux must contain exactly one layout line.` | `.smux has multiple layout lines or is empty. .smux requires exactly one layout line.` | `layout_line` |

---

## 2. `smux init`

### Mental Model

`.smux` has one DSL. `smux init` either teaches that DSL or safely writes it to a file.

### Syntax

```bash
smux init                                      # print DSL guide (no write)
smux init 'cmd | codex codex | claude claude'   # validate and write
smux init --force 'cmd | codex'                 # overwrite existing
```

### Behavior

**No args:** Print a help guide showing common layouts and syntax. Exit 0. Do not create `.smux`.

```text
Usage: smux init [--force] '<layout>'

Common layouts:
  Two agents:
    codex codex | claude claude
  Agent + shell:
    codex codex | cmd
  Writer + tests:
    writer codex, tester npm test
  Full workflow:
    cmd | writer codex, tester "npm test" | reviewer claude

Syntax:
  LABEL COMMAND    pane labeled LABEL running COMMAND
  LABEL            empty shell pane (e.g. `cmd`)
  |                split columns
  ,                stack within column

  Tip: `cmd` is just a label, not a required keyword.

Examples:
  smux init 'codex codex | claude claude'
  smux init 'cmd | writer codex, tester "npm test" | reviewer claude'

Then: smux start --preview  (or)  smux start
```

**With LAYOUT argument:**
1. Parse with the **same parser** as `smux start --dry-run` (reuse `parse_layout`)
2. If valid, write to `./.smux` (refuse overwrite unless `--force`)
3. Print the file and suggest `smux start --preview`

### Implementation (~25 lines)

```bash
cmd_init() {
  local force=0 layout=""
  while (($#)); do
    case "$1" in
      --force) force=1; shift ;;
      *) layout="${layout:+$layout }$1"; shift ;;
    esac
  done

  # No args: print DSL guide
  if [[ -z "$layout" ]]; then
    cat <<'INIT_HELP'
Usage: smux init [--force] '<layout>'

Common layouts:
  Two agents:
    codex codex | claude claude
  Agent + shell:
    codex codex | cmd
  Writer + tests:
    writer codex, tester npm test
  Full workflow:
    cmd | writer codex, tester "npm test" | reviewer claude

Syntax:
  LABEL COMMAND    pane labeled LABEL running COMMAND
  LABEL            empty shell pane (e.g. `cmd`)
  |                split columns
  ,                stack within column

  Tip: `cmd` is just a label, not a required keyword.

Examples:
  smux init 'codex codex | claude claude'
  smux init 'cmd | writer codex, tester "npm test" | reviewer claude'

Then: smux start --preview  (or)  smux start
INIT_HELP
    return 0
  fi

  # Validate by parsing (reuses start's parser)
  parse_layout "$layout" || exit 1

  if [[ -f ".smux" ]] && (( ! force )); then
    error ".smux already exists. Use --force to overwrite."
  fi

  echo "# | split columns     , stack within column"  > .smux
  echo "# Each cell: LABEL COMMAND (or just LABEL for empty shell)" >> .smux
  echo "" >> .smux
  echo "$layout" >> .smux

  info "Created .smux:"
  cat .smux
  echo ""
  info "Next: smux start --preview  (or)  smux start"
}
```

---

## 3. `smux doctor`

### Behavior

Read-only diagnostic. Reports `[ok]` / `[warn]` / `[fail]` with suggested fixes. Never mutates tmux state or files.

### Checks (in order)

| # | Check | Status | Details |
|---|-------|--------|---------|
| 1 | `tmux` binary exists | fail if missing | `command -v tmux` |
| 2 | tmux version | warn if < 3.2 | `tmux -V` |
| 3 | tmux server reachable | info if no sessions; fail if unresponsive | `tmux list-sessions` |
| 4 | `smux` CLI path + version | ok/warn | `command -v smux`, `smux version` |
| 5 | `tmux-bridge` binary | ok/fail | `command -v tmux-bridge` |
| 6 | tmux config loaded | warn if pane-border-format missing `@name` | `tmux show-options -g pane-border-format` |
| 7 | Current project `.smux` | ok if found + parses; info if none | `find_project_root` + `parse_layout` |
| 8 | Session conflicts (default name) | info if session exists, with smux/non-smux status | `session_project` |
| 9 | Smux-managed sessions | list session, project, panes, missing labels | `tmux list-sessions` + `@smux_project` |

### Output Format

```
smux doctor
[ok]   tmux installed: 3.6a
[ok]   tmux server reachable (2 sessions)
[ok]   smux CLI: ~/.smux/bin/smux 2.0.1
[ok]   tmux-bridge: ~/.smux/bin/tmux-bridge
[ok]   tmux config loaded (smux)
[warn] project .smux not found in /path/foo → run 'smux init'
[info] smux sessions: smux (2 panes: pi, codex)
```

### Implementation (~60 lines)

A single `cmd_doctor()` function that runs each check and prints the result line. Each check is a small helper or inline test. No side effects.

---

## 4. File Changes

| File | Change | Added |
|------|--------|-------|
| `install.sh` | `cmd_init`, `cmd_doctor`, improved error strings | ~100 lines |
| `docs/design-v2.1.md` | This document | new |
| `skills/smux/SKILL.md` | Add `init`/`doctor` to workspace commands table | minor |
| `README.md` | Mention v2.1 features | minor |

---

## 5. Not in Scope

- Automatic doctor fixes (keeps it read-only)
- Interactive wizard / template picker (default template is sufficient)
- Global templates / `~/.config/smux/`
- JSON/structured output
- Pane size constraints
- Read guard file cleanup
