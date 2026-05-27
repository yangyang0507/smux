# smux v2.5 — Per-Project Pane Scope

## Motivation

`tmux-bridge list` shows **all panes across all tmux sessions**, regardless of project. When running multiple smux sessions in parallel (e.g., one per repo), `list` and label resolution mix panes from unrelated projects, making label-based commands (`message`, `type`, `read`) ambiguous or dangerous.

## Design

### Default: project-scoped visibility

`list` and `resolve` default to showing only panes whose CWD falls within the **current project scope**. `--all` / `-a` restores the global view.

### Project root discovery (`current_scope_root`)

Priority order:

1. `@smux_project` — the session option set by `smux start` (most reliable)
2. Walk up from `pane_current_path` to find `.smux` or `.git`
3. Fallback to `pane_current_path` itself

Both `@smux_project` and `pane_current_path` are normalized with `cd -P` / `pwd -P` before comparison, so symlinks and relative paths don't break matching.

If `TMUX_PANE` is unset (e.g., script/CI invocation), scope resolution fails gracefully and the command falls back to `--all` behavior. `doctor` reports "Scope: unavailable" with a cause-specific message.

### Scope boundary check (`pane_in_scope`)

A pane belongs to a project if its (normalized) CWD equals the root, or starts with `root/`. This prevents `/foo/bar` from matching `/foo/barista`.

### Commands affected

| Command | Behavior |
|---|---|
| `list` | Scoped by default; `--all` / `-a` for global |
| `resolve` | Scoped by default; `--all` / `-a` for global |
| `type`, `message`, `file`, `read`, `keys`, `wake`, `name` | Inherit scoping via `resolve_label` (no new flags) |

Session-management commands (`smux status`, `attach`, `stop`) and `flow step` are intentionally **not scoped** — they operate at the session level.

### Cross-project communication

Users who need to reach a pane in another project use `resolve --all <label>` to get the `%pane` ID, then pass that explicit `%pane` to `type`/`message`/etc. The explicit-pane path is always global and requires no flags on the action commands.

### Implementation

Three shared helpers, all in `scripts/tmux-bridge`:

- `current_scope_root` — discovers and normalizes the project root
- `pane_in_scope` — boundary check with symlink-safe comparison
- `list_panes_scoped [--all]` — emits uniform pipe-delimited pane data; `resolve_label` and `cmd_list` both consume it

`doctor` gains a "Scope root" and "Scoped panes" line to aid debugging.
