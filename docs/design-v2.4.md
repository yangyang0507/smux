# smux v2.4 — Engineering Quality & Maintainability

## Overview

v2.4 focuses on engineering quality: test coverage, static analysis, and parser standardization. No new user-facing features — the goal is to make the codebase safe to evolve for v2.5+ and a potential v3.

Priority order: **parser tests + shellcheck + CI → parser contract + fixtures → unified parser (remove duplication) → minor portability fixes**.

Note: source modularization (`lib/`, `bridge/`, `scripts/build.sh`) was evaluated and intentionally not adopted — the dual source-of-truth burden (edit modules → build → commit both) outweighed the benefits at current file sizes (~1500 and ~900 lines). Single-file editing is preferred unless files grow significantly.

---

## 1. Shellcheck & Static Analysis

### Problem

`install.sh` (1423 lines) and `scripts/tmux-bridge` (842 lines) have never been statically analyzed. Common bash pitfalls — unquoted variables, unused assignments, portability issues — accumulate silently.

### Design

Add `.shellcheckrc` at the repo root. Do **not** globally disable SC2034 or SC2154 — suppress locally where needed:

```
# .shellcheckrc
shell=bash
```

For environment variables, always use the `${VAR:-}` pattern:
```bash
# Good — shellcheck knows it's intentionally optional
local pane="${TMUX_PANE:-}"
```

For global state arrays consumed by sourced callers, suppress at the declaration site:
```bash
# shellcheck disable=SC2034
SMUX_PANE_LABELS=()
```

Run shellcheck on both files in CI:
```bash
shellcheck install.sh scripts/tmux-bridge
```

Expected warning categories and fixes:

| Category | Example | Fix |
|----------|---------|-----|
| SC2086 | Unquoted `$variable` | Quote: `"$variable"` |
| SC2046 | Unquoted `$(command substitution)` | Quote |
| SC2004 | `$((...))` arithmetic | Use `(( ))` instead |
| SC2034 | Global arrays only read by callers | Local `# shellcheck disable=SC2034` at declaration |
| SC2154 | Env vars | Use `${VAR:-}` pattern |

### Deliverables

- `.shellcheckrc` at repo root (minimal — only `shell=bash`)
- `shellcheck` passes on both files with zero warnings (after local suppressions)
- Add shellcheck step to `scripts/ci.sh` (see Section 5)

---

## 2. Parser Test Coverage

### Problem

The DSL parsing functions — `split_aware()`, `strip_inline_comment()`, `parse_layout()`, `quote_balanced()`, `unquote_command()` — are the core of `.smux` interpretation but have no independent tests. `test_smux_workspace.sh` tests `parse_layout()` indirectly through the CLI, but doesn't cover edge cases.

### Design

Add `tests/test_parser.sh` covering:

#### `strip_inline_comment()`

| Input | Expected | Case |
|-------|----------|------|
| `hello # world` | `hello ` | Basic inline comment |
| `"hello # world"` | `"hello # world"` | `#` inside double quotes preserved |
| `"hello \" # world"` | `"hello \" # world"` | Escaped quote before `#` |
| `# full line comment` | `` | Full-line comment returns empty |
| `no comment` | `no comment` | No `#` at all |
| `trailing \#` | `trailing \` | **Current behavior**: backslash is literal outside quotes, `#` starts comment |

Note: `\#` outside double quotes is **not** an escape. The current `strip_inline_comment()` only processes backslash escapes inside double quotes. Outside quotes, `\` is literal and `#` starts a comment. This is intentional — matches shell convention where `#` is always a comment unless quoted.

#### `split_aware()`

| Input | Delim | Expected | Case |
|-------|-------|----------|------|
| `a,b,c` | `,` | `a`, `b`, `c` | Simple split |
| `a,"b,c",d` | `,` | `a`, `"b,c"`, `d` | Delimiter inside quotes |
| `a,,b` | `,` | `a`, ``, `b` | Empty segment |
| `"a,b` | `,` | error (return 2) | Unbalanced quotes |
| `a,b,"c,d"` | `,` | `a`, `b`, `"c,d"` | Quotes at end |
| `echo a b,c` | `,` | `echo a b`, `c` | Spaces in bare command |

#### `quote_balanced()`

| Input | Expected | Case |
|-------|----------|------|
| `"hello"` | true | Balanced |
| `"hello` | false | Missing closing quote |
| `"he\"llo"` | true | Escaped quote inside |
| `no quotes` | true | No quotes at all |

#### `unquote_command()`

| Input | Expected | Case |
|-------|----------|------|
| `"echo hello"` | `echo hello` | Strip outer quotes |
| `"echo \"quoted\""` | `echo "quoted"` | Unescape inner quotes |
| `"path\\to"` | `path\to` | Unescape backslashes |
| `bare cmd` | `bare cmd` | No quotes, unchanged |
| `""` | `` | Empty quoted string |

#### `parse_layout()`

| Input | Expected | Case |
|-------|----------|------|
| `a cmd` | 1 pane, label `a`, cmd `cmd` | Single pane |
| `a echo hello, b test` | 2 panes; cmd1=`echo hello` | Command with spaces |
| `a cmd, b test` | 2 panes in 1 column | Comma-separated |
| `a cmd \| b test` | 2 columns | Pipe-separated |
| `a, b \| c` | col0: 2 panes, col1: 1 pane | Mixed |
| `\| b` | error (empty column) | Leading pipe |
| `a \|` | error (empty column) | Trailing pipe |
| `a, , b` | error (empty pane) | Double comma |
| `a "echo \| pipe"` | 1 pane, cmd=`echo \| pipe` | Pipe inside quotes |

### Deliverables

- `tests/test_parser.sh` with ~40-50 test cases
- All tests pass without tmux (pure function tests)
- `tests/run.sh` updated to include the new test file

---

## 3. Parser Contract (.smux DSL Specification)

### Problem

The `.smux` DSL is defined implicitly across four design docs and two parser implementations (`install.sh` and `tmux-bridge`'s `flow_parse_smux`). There's no single source of truth for what constitutes valid `.smux` syntax, what errors should be raised, or how edge cases behave.

### Design

Create `docs/smux-dsl.md` as the authoritative specification.

#### Tokenizer Rules

The parser is line-oriented with quote-awareness. The key rules, matching current implementation:

1. **Lines**: Read line by line. Blank lines and lines starting with `#` (outside quotes) are skipped.
2. **Layout line**: The first non-blank, non-comment, non-indented, non-`pipeline:`/`steps:` line is the layout.
3. **Inline comments**: `#` outside double quotes starts a comment. Backslash is **not** an escape outside quotes — `\#` is literal `\` followed by comment `#`.
4. **Quote handling**: Inside `"..."`, backslash protects the next character from being treated as structural (`"`, `\`, `#`). However, `unquote_command()` only truly unescapes `\"` → `"` and `\\` → `\`; other `\X` sequences pass through as-is (the backslash is kept).
5. **Columns**: Layout is split by `|` (quote-aware via `split_aware`).
6. **Panes**: Each column is split by `,` (quote-aware).
7. **Label**: First whitespace-delimited token of a pane cell. Must match `[A-Za-z0-9_.-]+`.
8. **Command**: Everything after the label (trimmed). May contain spaces; unquoted `|`, `,`, or `#` are structural (split/comment), so literal pipe/comma/hash require double quotes.
9. **Pipeline steps**: Indented lines under `steps:`. Format: `FROM -> TO REMAINDER`. `REMAINDER` is the prompt — if double-quoted, outer quotes are stripped (but inner escapes are **not** processed, unlike layout commands).

#### Grammar

```bnf
smux-file      = { comment-line | blank-line } layout-line
                 { comment-line | blank-line | pipeline-block }

layout-line    = column { "|" column }
column         = pane { "," pane }
pane           = LABEL [ SP command ]
LABEL          = LABEL_CHAR { LABEL_CHAR }
LABEL_CHAR     = ALPHA | DIGIT | "_" | "." | "-"
command        = quoted-cmd | bare-cmd
quoted-cmd     = '"' { qchar } '"'        # outer quotes stripped, \" and \\ unescaped
bare-cmd       = { any-char-except-unquoted-pipe-comma-hash }  # trimmed, no unescaping
qchar          = escape | any-char-except-quote
escape         = '\\' ( '"' | '\\' )

comment-line   = [ SP ] "#" ANY | blank-line
blank-line     = [ SP ] NEWLINE

pipeline-block = "pipeline:" SP NAME NEWLINE
                 INDENT "steps:" NEWLINE
                 { INDENT step-line NEWLINE }
step-line      = LABEL SP "->" SP LABEL SP prompt
prompt         = '"' { any-char } '"' | { any-char-to-eol }  # outer quotes stripped only

ALPHA          = "A"..."Z" | "a"..."z"
DIGIT          = "0"..."9"
SP             = " " | TAB
INDENT         = " " | TAB
```

#### Key Behavioral Differences from Naive BNF

| Aspect | Correct behavior | Common misconception |
|--------|-----------------|---------------------|
| Bare command | `cmd echo a b` → cmd=`echo a b` (spaces preserved) | Not `cmd` + `echo` as separate tokens |
| `\#` outside quotes | `trailing \#` → `trailing \` (backslash literal, `#` starts comment) | Not `trailing #` (no escape outside quotes) |
| `#` inside quotes | `"hello # world"` → `hello # world` (literal) | Not a comment |
| Pipeline prompt | `"prompt with spaces"` → `prompt with spaces` (outer quotes stripped) | Prompt can be multi-token bare text |
| Pipeline prompt escapes | Inner `\"` and `\\` are **not** unescaped in pipeline prompts | Unlike layout `unquote_command()` |

#### Error Specification

| Error | Condition | Message |
|-------|-----------|---------|
| Empty column | `\|` with no cells between pipes | `Empty column in .smux layout: ...` |
| Empty pane | `,,` with no label between commas | `Empty pane in .smux layout: ...` |
| Invalid label | Label doesn't match `[A-Za-z0-9_.-]+` | `Invalid label '...'. Labels must match [...]` |
| Unclosed quote | `"` without matching `"` | `Unclosed quote in .smux layout: ...` |
| Multiple layouts | More than one non-indented, non-pipeline line | `.smux has multiple layout lines.` |
| Missing pipeline name | Steps without `pipeline:` | `Steps found without a 'pipeline:' name` |
| Empty pipeline name | `pipeline:` with no name | `Pipeline name is empty` |

#### Test Fixtures

`tests/fixtures/smux-dsl/` contains `.smux` files and expected outputs:

```
tests/fixtures/smux-dsl/
  valid-basic.smux              # Single pane, simple command
  valid-spaces-in-cmd.smux      # cmd echo hello world → cmd="echo hello world"
  valid-two-col.smux            # Two columns
  valid-stacked.smux            # Comma-separated panes
  valid-pipeline.smux           # Layout + pipeline block
  valid-comments.smux           # Inline and full-line comments
  valid-quoted-cmd.smux         # "echo | pipe" with escaped special chars
  valid-quoted-prompt.smux      # Pipeline with quoted multi-word prompt
  error-empty-column.smux       # Expected: error
  error-unclosed-quote.smux     # Expected: error
  error-invalid-label.smux      # Expected: error
  edge-backslash-hash.smux      # \# outside quotes → literal \ then comment
  edge-pipe-in-quotes.smux      # | inside quotes preserved
  edge-comma-in-quotes.smux     # , inside quotes preserved
```

Each `.smux` file has a companion `.expected` file with either the parsed output or the expected error message.

#### Parser Equivalence Tests

Before removing `flow_parse_smux` from tmux-bridge (Section 5), run both parsers against the same pipeline fixtures and assert identical output:

```bash
# tests/test_parser_equivalence.sh
# Compare parse_pipeline (install.sh) and flow_parse_smux (tmux-bridge) outputs
# without eval — use smux parse-pipeline TSV output as the common format.
for fixture in tests/fixtures/smux-dsl/valid-pipeline*.smux; do
  # Get TSV from install.sh's parse_pipeline via smux parse-pipeline
  tsv_a=$(bash install.sh parse-pipeline "$fixture")
  # Get TSV from tmux-bridge's flow_parse_smux (emit same TSV format)
  tsv_b=$(source_tmux_bridge; flow_parse_smux_to_tsv "$fixture")
  # Assert identical
  diff <(echo "$tsv_a") <(echo "$tsv_b") || fail "parser mismatch: $fixture"
done
```

Only after all equivalence tests pass should `flow_parse_smux` be removed.

### Deliverables

- `docs/smux-dsl.md` with tokenizer rules, grammar, behavioral table, error table, and examples
- `tests/fixtures/smux-dsl/` with 14+ test fixtures
- `tests/test_dsl_spec.sh` that runs all fixtures through `parse_layout()` and `parse_pipeline()`
- `tests/test_parser_equivalence.sh` for dual-parser validation

---

## 4. Shared Utilities & Parser Unification

### Problem

Several patterns are duplicated across `install.sh` and `scripts/tmux-bridge`:

| Pattern | install.sh | tmux-bridge |
|---------|-----------|-------------|
| tmux version parsing | `check_tmux_version()` line 67 | (none) |
| `.smux` pipeline parsing | `parse_pipeline()` line 454 | `flow_parse_smux()` line 602 |
| `die()` helper | `error()` line 24 | `die()` line 10 |
| Pane label lookup | `find_pane_by_label()` line 514 | inline in `cmd_flow_step()` line 677 |

### Design

For the single-file build (Section 3), duplication in `install.sh` is resolved by having the generated file include shared implementations once.

For `tmux-bridge`, which remains a separate file:

#### 5a. Remove `flow_parse_smux` — TSV Output

`tmux-bridge flow step` auto-start currently reimplements the parser inline. Replace with a call to `smux parse-pipeline`, which outputs a safe TSV format (no `eval`, no injection risk):

```bash
# Portable base64 helpers (Linux base64 may wrap lines; macOS uses -D or -d)
b64_encode() { base64 | tr -d '\n'; }
b64_decode() { base64 -d 2>/dev/null || base64 -D; }

# New subcommand in install.sh
cmd_parse_pipeline() {
  local file="$1"
  parse_pipeline "$file" || { echo "NONE"; return 1; }
  # Output: TSV format, one line per field
  # Values base64-encoded to avoid shell quoting issues
  printf "name\t%s\n" "$(printf '%s' "$SMUX_FLOW_NAME" | b64_encode)"
  printf "steps\t%s\n" "$SMUX_FLOW_STEP_COUNT"
  local i
  for (( i=0; i<SMUX_FLOW_STEP_COUNT; i++ )); do
    printf "step\t%s\t%s\t%s\n" \
      "$(printf '%s' "${SMUX_FLOW_STEP_FROM[$i]}" | b64_encode)" \
      "$(printf '%s' "${SMUX_FLOW_STEP_TO[$i]}" | b64_encode)" \
      "$(printf '%s' "${SMUX_FLOW_STEP_PROMPT[$i]}" | b64_encode)"
  done
}
```

In `scripts/tmux-bridge`, parse the TSV output:

```bash
# Replace flow_parse_smux with:
local smux_bin
if [[ -n "${SMUX_CLI:-}" ]]; then
  [[ -x "$SMUX_CLI" ]] || die "SMUX_CLI=$SMUX_CLI is not executable"
  smux_bin="$SMUX_CLI"
elif [[ -x "$(dirname "$0")/smux" ]]; then
  smux_bin="$(dirname "$0")/smux"
else
  smux_bin="$(command -v smux 2>/dev/null)" || die "smux not found. Install smux or set SMUX_CLI."
fi

local parse_output
parse_output=$("$smux_bin" parse-pipeline "$project/.smux") || die "failed to parse $project/.smux"

SMUX_FLOW_TMP_NAME=""
SMUX_FLOW_TMP_COUNT=0
SMUX_FLOW_TMP_FROM=()
SMUX_FLOW_TMP_TO=()
SMUX_FLOW_TMP_PROMPT=()

while IFS=$'\t' read -r key val1 val2 val3; do
  case "$key" in
    name)   SMUX_FLOW_TMP_NAME=$(printf '%s' "$val1" | b64_decode) ;;
    steps)  SMUX_FLOW_TMP_COUNT="$val1" ;;
    step)   SMUX_FLOW_TMP_FROM+=("$(printf '%s' "$val1" | b64_decode)")
            SMUX_FLOW_TMP_TO+=("$(printf '%s' "$val2" | b64_decode)")
            SMUX_FLOW_TMP_PROMPT+=("$(printf '%s' "$val3" | b64_decode)") ;;
  esac
done <<< "$parse_output"
```

#### 5b. `smux` CLI Path Resolution

tmux-bridge must find the `smux` binary. Resolution order:

1. `$SMUX_CLI` environment variable — if set, must be executable; `die` immediately if not found (no silent fallback)
2. `$(dirname "$0")/smux` (sibling binary — works when both are in `~/.smux/bin/`)
3. `command -v smux` (PATH fallback)

#### 5c. `die()` / `error()`

Keep separate — different formatting (`error:` vs `[smux]`). Not worth unifying.

#### 5d. Pane Label Lookup

Extract `tmx_resolve_label()` in tmux-bridge, reuse in `cmd_flow_step`:

```bash
tmx_resolve_label() {
  local label="$1"
  local pane
  pane=$(tmx list-panes -a -F '#{pane_id} #{@name}' 2>/dev/null \
    | awk -v lbl="$label" '$2 == lbl { print $1; exit }')
  [[ -n "$pane" ]] || die "no pane found with label '$label'"
  echo "$pane"
}
```

### Deliverables

- `smux parse-pipeline` subcommand with TSV output (v2.4.3)
- `flow_parse_smux` kept as fallback in tmux-bridge; optional use of `smux parse-pipeline` via `SMUX_CLI` (v2.4.3)
- `flow_parse_smux` removed from `scripts/tmux-bridge` after `tests/test_parser_equivalence.sh` passes (v2.4.4)
- `SMUX_CLI` env var support + sibling-binary resolution (v2.4.3)
- `tmx_resolve_label()` extracted in tmux-bridge (v2.4.3)

---

## 5. CI Script

### Problem

No automated checks exist. Tests run manually; shellcheck is not enforced.

### Design

Add `scripts/ci.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== git diff --check ==="
git diff --check
echo "PASS"

echo "=== shellcheck ==="
shellcheck install.sh scripts/tmux-bridge scripts/ci.sh
echo "PASS"

echo "=== tests ==="
tests/run.sh
echo "PASS"

echo "=== update dry-run ==="
update_out=$(bash install.sh update --dry-run 2>&1)
echo "$update_out" | head -20
echo "PASS"

echo "All checks passed."
```

The update dry-run test catches manifest drift — if `sync_manifest()` references files that don't exist or have wrong paths, this will fail.

### Deliverables

- `scripts/ci.sh` (shellcheck + tests + update dry-run)

---

## 6. Minor Fixes

### 7a. `repeat_char()` Performance

Current implementation concatenates in a loop. Use `printf -v` (no external dependencies, works with unicode box-drawing chars):

```bash
repeat_char() {
  local ch="$1" n="$2"
  local out
  printf -v out '%*s' "$n" ''
  printf '%s' "${out// /$ch}"
}
```

Note: The original loop is fine for small `n` (preview widths are typically <24). This change is for correctness and readability, not performance. Do **not** use `seq` — it's an external dependency and breaks with certain unicode chars.

### 7b. `RANDOM` Fallback in tmux-bridge

Replace `${RANDOM:-0}` with `mktemp -d` to eliminate both the race and the `$RANDOM` availability issue:

```bash
# Before
id="${RANDOM:-0}-$$-$(date +%s)"
dest="${TMPDIR:-/tmp}/tmux-bridge-file-${id}-${safe_name}"

# After
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmux-bridge-file-XXXXXX")
dest="${tmp_dir}/${safe_name}"
```

`mktemp -d` creates the directory atomically (no race), and the file inside it inherits the unique directory name. Cleanup: `rm -rf "$tmp_dir"` after the file is no longer needed.

### 7c. `pgrep -P` Fallback

`ps --ppid` is GNU-specific. Use a multi-layer fallback:

```bash
find_child_pid() {
  local parent="$1"
  # Try pgrep (Linux, macOS with procps)
  local child
  child=$(pgrep -P "$parent" 2>/dev/null | head -1) && [[ -n "$child" ]] && { echo "$child"; return; }
  # Try ps with --ppid (GNU coreutils)
  child=$(ps -o pid= --ppid "$parent" 2>/dev/null | head -1) && [[ -n "$child" ]] && { echo "$child"; return; }
  # Fallback: scan all processes for matching ppid (works everywhere)
  ps -eo pid=,ppid= 2>/dev/null | awk -v ppid="$parent" '$2 == ppid { print $1; exit }'
}
```

### 7d. Stale Flow File Cleanup

`cmd_doctor()` warns about stale files, but also add a `--stale` flag to `smux flow reset`. Note: `find -mmin` is supported on macOS and GNU find, but not BusyBox. Best-effort is acceptable — if `find -mmin` fails, skip silently.

```bash
# In cmd_flow_reset()
if [[ "${1:-}" == "--stale" ]]; then
  local older_than="${2:-1440}"  # default 24h in minutes
  local stale
  stale=$(find "${TMPDIR:-/tmp}" -name "tmux-bridge-flow-*-*.ctx" -mmin +"$older_than" 2>/dev/null || true)
  if [[ -z "$stale" ]]; then
    echo "No stale flow files found."
    return 0
  fi
  echo "$stale" | while IFS= read -r f; do
    local state="${f%.ctx}"
    rm -f "$f" "$state"
    echo "Removed: $f"
  done
  return 0
fi
```

In `cmd_doctor()`:
```bash
if [[ -n "$stale_ctx" ]]; then
  doctor_warn "Stale flow files found (older than 24h):"
  echo "$stale_ctx" | while IFS= read -r f; do doctor_info "  $f"; done
  doctor_info "Fix: smux flow reset --stale"
fi
```

### 7e. Shared tmux Version Detection

Extract `get_tmux_version()` and reuse in both `check_tmux_version()` and `cmd_doctor()`:

```bash
get_tmux_version() {
  local raw ver major minor
  raw=$(tmux -V 2>/dev/null || echo "0.0")
  ver=$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")
  major="${ver%%.*}"
  minor="${ver#*.}"
  echo "${major:-0}.${minor:-0}"
}
```

### 7f. `detect_socket()` Scan Limit

Add a socket count limit and timeout to the fallback scan:

```bash
# In detect_socket(), before the socket scan loop:
local scan_count=0
local scan_limit=20
for sock in "$sock_dir"/*; do
  [[ -S "$sock" ]] || continue
  (( ++scan_count > scan_limit )) && break
  # ... existing check ...
done
```

### Deliverables

- `repeat_char()` rewritten with `printf -v`
- `RANDOM` replaced with `mktemp -d`
- `find_child_pid()` with 3-layer fallback
- `smux flow reset --stale` command
- `get_tmux_version()` extracted
- Socket scan limit in `detect_socket()`

---

## 7. Global Variable Naming Strategy

### Problem

`PANE_LABELS`, `FLOW_STEP_FROM`, etc. are bare global names. After modularization, if every module writes to unprefixed globals, pollution gets worse, not better.

### Design

Prefix all parser output variables with `SMUX_` (completed in v2.6.0):

| Old | New (v2.6.0+) |
|-----|----------------|
| `PANE_LABELS` | `SMUX_PANE_LABELS` |
| `PANE_COMMANDS` | `SMUX_PANE_COMMANDS` |
| `PANE_COLS` | `SMUX_PANE_COLS` |
| `PANE_COUNT` | `SMUX_PANE_COUNT` |
| `COL_START` | `SMUX_COL_START` |
| `COL_COUNT` | `SMUX_COL_COUNT` |
| `COL_COUNT_TOTAL` | `SMUX_COL_COUNT_TOTAL` |
| `FLOW_NAME` | `SMUX_FLOW_NAME` |
| `FLOW_STEP_FROM` | `SMUX_FLOW_STEP_FROM` |
| `FLOW_STEP_TO` | `SMUX_FLOW_STEP_TO` |
| `FLOW_STEP_PROMPT` | `SMUX_FLOW_STEP_PROMPT` |
| `FLOW_STEP_COUNT` | `SMUX_FLOW_STEP_COUNT` |
| `FLOW_TMP_NAME` | `SMUX_FLOW_TMP_NAME` |
| `FLOW_TMP_FROM` | `SMUX_FLOW_TMP_FROM` |
| `FLOW_TMP_TO` | `SMUX_FLOW_TMP_TO` |
| `FLOW_TMP_PROMPT` | `SMUX_FLOW_TMP_PROMPT` |
| `FLOW_TMP_COUNT` | `SMUX_FLOW_TMP_COUNT` |

`COL_WIDTH` is intentionally excluded — it is a preview scratch variable, not a parser output global.

Each parser function resets its output arrays at the start:

```bash
parse_layout() {
  SMUX_PANE_LABELS=()
  SMUX_PANE_COMMANDS=()
  # ...
}
```

This makes it clear which variables are parser output and prevents accidental cross-module pollution.

### Deliverables

- All parser output variables renamed with `SMUX_` prefix
- Parser functions reset output arrays at entry
- All consumers updated to use new names

---

## 8. Not in Scope

- New user-facing features
- Go/Rust rewrite (deferred to v3 evaluation; trigger: DSL/parser complexity exceeds bash maintainability)
- Multi-pipeline support
- JSON/structured output
- Agent auto-detection
- `.smux` schema validation beyond syntax

---

## 9. File Changes Summary

| File | Change |
|------|--------|
| `.shellcheckrc` | New: minimal shellcheck configuration |
| `scripts/ci.sh` | New: CI check runner (shellcheck + tests + update dry-run) |
| `docs/smux-dsl.md` | New: DSL specification |
| `tests/test_parser.sh` | New: 87 assertions covering 5 parser functions |
| `tests/test_dsl_spec.sh` | New: 17 golden fixtures for DSL conformance |
| `tests/test_flow_step.sh` | New: flow step integration test (13 assertions) |
| `tests/fixtures/smux-dsl/` | New: 17 test fixtures with `.expected` files |
| `install.sh` | Added: `smux parse-pipeline`, `SMUX_` prefixed vars, portability fixes, stale cleanup, --enter fix |
| `scripts/tmux-bridge` | Removed `flow_parse_smux`, added `resolve_smux` + TSV ingestion, `send_enter_after_literal`, portability fixes |

---

## 10. Changes Summary

All changes shipped as a single v2.4 release covering engineering quality and maintainability improvements:

| Area | Changes |
|------|---------|
| Static analysis | shellcheck zero-warning on `install.sh` and `scripts/tmux-bridge` |
| Parser tests | `tests/test_parser.sh` (87 assertions), `tests/test_dsl_spec.sh` (17 golden fixtures) |
| DSL spec | `docs/smux-dsl.md` with tokenizer rules, grammar, behavioral table, error table |
| CI | `scripts/ci.sh` (shellcheck + tests + update dry-run) |
| parse-pipeline | `smux parse-pipeline` TSV subcommand, tmux-bridge `flow step` uses it via `resolve_smux()` |
| `flow_parse_smux` | Removed (equivalence tests passed before removal) |
| Flow step test | `tests/test_flow_step.sh` (13 assertions, real CLI entrypoint) |
| Portability | `mktemp -d` for temp dirs, `pgrep -P` fallback, socket scan limit, `repeat_char` printf perf |
| Stale cleanup | `smux flow reset --stale` + doctor stale warning |
| SMUX_ prefix | 17 parser/layout/flow globals renamed with `SMUX_` prefix |
| --enter fix | `send_enter_after_literal` with configurable delay (`TMUX_BRIDGE_ENTER_DELAY`, default 1s) |

Only one behavior change: `tmux-bridge flow step` now requires `smux` CLI for pipeline auto-start (previously had built-in `flow_parse_smux`).

Source modularization (`lib/`, `bridge/`, `scripts/build.sh`) was evaluated and intentionally not adopted — the dual source-of-truth burden outweighed the benefits at current file sizes.

