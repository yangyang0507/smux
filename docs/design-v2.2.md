# smux v2.2 Design — Agent Transport & Automation

## Overview

v2.2 makes `tmux-bridge` safe for automated agent use. v2.1 gave us workspace lifecycle (`init`, `start`, `stop`, `doctor`). v2.2 adds robust text transport, file staging, atomic updates, completion, and guardrails to prevent agents from corrupting each other's state.

Priority order: **input safety → file transfer → install sync → completion**.

---

## 1. Input Safety

### Problem

Before v2.2, `tmux-bridge type` and `message` accepted raw argv text — fine for humans, dangerous for agents. Shell quoting of AI-generated text is fundamentally fragile: single quotes fail on embedded `'`, double quotes expose `$` and `!`. Messages could be truncated or corrupted mid-transport.

Additionally, if the target pane was in tmux copy-mode or a tmux prompt, `send-keys` would inject text into the wrong context — corrupting scrollback or filling tmux prompts with command text.

### `--stdin` and `--base64` Transport

Two new flags for `type` and `message`:

| Flag | Behavior |
|------|---------|
| `--stdin` | Read exact bytes from stdin, preserving trailing newlines |
| `--base64` | Decode a base64-encoded argument (single token or `--stdin --base64`) |

**Precedence:** `--stdin` > `--base64` > piped stdin auto-detect > argv text

```bash
# Agent path (robust default)
printf '%s' "$msg" | tmux-bridge message codex --stdin

# Base64 for hostile shell contexts
b64=$(printf '%s' "$msg" | base64 | tr -d '\n')
tmux-bridge message codex --base64 "$b64"

# Base64 + stdin for complex payloads
printf '%s' "$msg" | tmux-bridge message codex --stdin --base64
```

**Implementation:** `parse_text()` in `scripts/tmux-bridge` handles all four input mechanisms. `read_stdin()` uses the `cat; printf x` trick to preserve trailing newlines (as described in POSIX). Base64 decode uses the same trailing-newline preservation pattern.

### Mode Guard

`require_normal_mode()` checks `#{pane_in_mode}` before any `type`/`message`/`keys`/`file`:

```bash
if [[ $(tmux display -t "$target" -p '#{pane_in_mode}') != "0" ]]; then
  die "target pane is in tmux copy-mode or a tmux prompt. Run: tmux-bridge wake $target"
fi
```

This prevents agents from accidentally typing into copy-mode scrollback or filling tmux prompts.

### `tmux-bridge wake`

Explicit command to send Escape to a pane and exit tmux mode/prompt:

```bash
tmux-bridge wake codex
```

Sends exactly one Escape. Use deliberately — it may interrupt scrollback or search.

---

## 2. File Transfer

### Problem

`type` and `message` send text inline — fine for short messages but dangerous for diffs, logs, or reports. Long content can fill the target agent's prompt with noise, and tmux's `send-keys` has practical limits on content length.

### `tmux-bridge file`

Stages content to a temp file and types only a short path notice into the target pane:

```bash
# From local path
tmux-bridge file codex /tmp/review.diff

# From stdin
git diff | tmux-bridge file codex --stdin --name review.diff
```

**Flow:**
1. Copy input to `/tmp/tmux-bridge-file-<RANDOM>-<PID>-<epoch>-<safe_name>`
2. Truncate at `--max-bytes` (default 262144) / `--max-lines` (default 2000)
3. Append `[tmux-bridge: content truncated to ...]` if truncated
4. `chmod 600` the staged file
5. Type notice into target pane: `[tmux-bridge from:...] Shared file 'name' (N lines, M bytes, full/truncated): <path>`
6. Print staged path to stdout

**Options:**

| Flag | Default | Description |
|------|---------|-------------|
| `--stdin` | — | Read from stdin instead of a file path |
| `--name` | basename or `stdin.txt` | Display name for the staged file |
| `--max-bytes` | 262144 | Max bytes before truncation |
| `--max-lines` | 2000 | Max lines before truncation |

**Truncation:** `copy_limited_file()` uses `head -c` for byte limit and `awk` for line limit, appending a truncation notice to the staged file.

---

## 3. Install Sync

### Problem

`smux install` was one-way: it could install but not verify or selectively update. Users had no way to check if their installed files matched the latest source.

### `smux update --check` and `--dry-run`

```bash
smux update --check    # SHA-256 comparison of installed vs source
smux update --dry-run  # Show what would be installed without writing
smux update            # Apply updates (backup + atomically replace)
```

**Implementation:**

- **Manifest:** `sync_manifest()` maps repo paths to installed paths with permissions
- **Atomic install:** Download to temp → validate → `mv` to final location (prevents partial writes)
- **Checksum:** `sha256sum` comparison between installed and source files
- **Backup:** Existing config backed up to `~/.smux/backups/` before overwrite

**Manifest:**
```bash
sync_manifest() {
  # repo_path → installed_path → mode
  .tmux.conf              → ~/.smux/tmux.conf           (644)
  scripts/tmux-bridge     → ~/.smux/bin/tmux-bridge     (755)
  install.sh              → ~/.smux/bin/smux             (755)
  completions/tmux-bridge.bash → ~/.smux/completions/   (644)
  completions/smux.bash        → ~/.smux/completions/   (644)
}
```

---

## 4. Bash Completion

### Problem

No tab completion for smux or tmux-bridge commands, flags, or pane targets.

### `completions/smux.bash`

Completes: subcommands, session names (`smux attach -n <tab>`), flags (`--force`, `--dry-run`, `--preview`, `--agents`).

### `completions/tmux-bridge.bash`

Completes: subcommands, pane targets (by ID and `@name` label), key names (`Enter`, `C-c`, etc.), input flags (`--stdin`, `--base64`).

Both use `_smux_timeout`/`_tmux_bridge_timeout` to gracefully degrade if tmux server is not reachable.

---

## 5. Pane Semantics

### Inline Comments in `.smux`

`strip_inline_comment()` strips `#` and everything after, but only outside double quotes. This enables:

```
writer codex --dangerously-bypass-approvals # CI mode
tester "npm test | grep skip"  # pipe literal
```

### `smux status --agents`

Lists only labeled agent panes with pane IDs:

```
$ smux status --agents
myproj      pi    %0
myproj      codex %1
```

Uses `@smux_label` pane option. Requires read-before-act guard for safety.

---

## 6. Test Suite

Six test files using a minimal assertion library (`tests/lib/assert.sh`):

| Test | Coverage |
|------|----------|
| `test_parse_text.sh` | All input modes: `--stdin`, `--base64`, argv, `--` sentinel, auto-detect, edge cases |
| `test_read_guard.sh` | mark/require/clear state machine, error messages, full cycle |
| `test_roundtrip.sh` | Content fidelity through base64 encode→decode: ASCII, quotes, `$`, backticks, JSON, emoji, newlines |
| `test_smux_workspace.sh` | `layout_line()` inline comment stripping, quote preservation, `parse_layout()`, `status --agents` |
| `test_mode_guard.sh` | `require_normal_mode` rejects copy-mode, `wake` exits copy-mode, CLI integration |
| `test_file_transfer.sh` | File staging, `--stdin`, truncation by max lines |

---

## 7. File Changes

| File | Change |
|------|--------|
| `scripts/tmux-bridge` | `--stdin`/`--base64`, mode guard, `wake` command, `file` command, parse_text |
| `install.sh` | `smux update --check`/`--dry-run`, manifest, atomic install, inline comments, `status --agents` |
| `completions/smux.bash` | New: tab completion for smux CLI |
| `completions/tmux-bridge.bash` | New: tab completion for tmux-bridge |
| `tests/` | New: P0 test suite with assertion library |
| `docs/README.md` | file command, update flags, completion instructions |
| `docs/tutorial.md` | Part 3.5 file transfer, update section, completion section |
| `docs/design-v2.2.md` | This document |

---

## 8. Not in Scope

- Pipeline/workflow orchestration (v2.3)
- Message auto-submit / `--enter` (v2.3)
- File header suppression / `--brief` (v2.3)
- Multi-line `.smux` syntax
- JSON/structured output
- Agent auto-detection (no polling design maintained)
- Persistent read guard cleanup
