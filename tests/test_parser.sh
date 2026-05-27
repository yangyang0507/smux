#!/usr/bin/env bash
# Tests for .smux DSL parser functions — strip_inline_comment, split_aware,
# quote_balanced, unquote_command, parse_layout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

# Source function definitions only (stop before # --- Main ---)
eval "$(sed '/^# --- Main ---$/q' "$SCRIPT_DIR/../install.sh")"

echo "=== test_parser.sh ==="

# ==========================================================================
# strip_inline_comment
# ==========================================================================

test_name "strip_inline_comment: basic inline comment"
out=$(strip_inline_comment 'hello # world')
assert_eq "$out" "hello "

test_name "strip_inline_comment: # inside double quotes preserved"
out=$(strip_inline_comment '"hello # world"')
assert_eq "$out" '"hello # world"'

test_name "strip_inline_comment: escaped quote before #"
out=$(strip_inline_comment '"hello \" # world"')
assert_eq "$out" '"hello \" # world"'

test_name "strip_inline_comment: full-line comment returns empty"
out=$(strip_inline_comment '# full line comment')
assert_eq "$out" ""

test_name "strip_inline_comment: no # at all"
out=$(strip_inline_comment 'no comment here')
assert_eq "$out" "no comment here"

test_name "strip_inline_comment: backslash-hash outside quotes (literal backslash, # starts comment)"
out=$(strip_inline_comment 'trailing \#')
assert_eq "$out" 'trailing \'

test_name "strip_inline_comment: multiple # — first unquoted one starts comment"
out=$(strip_inline_comment 'a # b # c')
assert_eq "$out" "a "

test_name "strip_inline_comment: # at start"
out=$(strip_inline_comment '#comment')
assert_eq "$out" ""

test_name "strip_inline_comment: empty string"
out=$(strip_inline_comment '')
assert_eq "$out" ""

test_name "strip_inline_comment: quoted # with surrounding text"
out=$(strip_inline_comment 'prefix "keep # here" suffix # comment')
assert_eq "$out" 'prefix "keep # here" suffix '

# ==========================================================================
# split_aware
# ==========================================================================

test_name "split_aware: simple comma split"
out=$(split_aware 'a,b,c' ',')
assert_eq "$out" $'a\nb\nc'

test_name "split_aware: comma inside double quotes preserved"
out=$(split_aware 'a,"b,c",d' ',')
assert_eq "$out" $'a\n"b,c"\nd'

test_name "split_aware: empty segment between commas"
out=$(split_aware 'a,,b' ',')
assert_eq "$out" $'a\n\nb'

test_name "split_aware: unbalanced quotes returns error"
out=$(split_aware '"a,b' ',' 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "2"

test_name "split_aware: quotes at end"
out=$(split_aware 'a,b,"c,d"' ',')
assert_eq "$out" $'a\nb\n"c,d"'

test_name "split_aware: spaces in bare text"
out=$(split_aware 'echo a b,c' ',')
assert_eq "$out" $'echo a b\nc'

test_name "split_aware: pipe delimiter"
out=$(split_aware 'col1|col2|col3' '|')
assert_eq "$out" $'col1\ncol2\ncol3'

test_name "split_aware: pipe inside quotes"
out=$(split_aware 'a,"b|c",d' '|')
assert_eq "$out" 'a,"b|c",d'

test_name "split_aware: single segment (no delimiter)"
out=$(split_aware 'hello' ',')
assert_eq "$out" "hello"

test_name "split_aware: empty string"
out=$(split_aware '' ',')
assert_eq "$out" ""

# ==========================================================================
# quote_balanced
# ==========================================================================

test_name "quote_balanced: balanced double quotes"
quote_balanced '"hello"' && out=true || out=false
assert_eq "$out" "true"

test_name "quote_balanced: missing closing quote"
quote_balanced '"hello' && out=true || out=false
assert_eq "$out" "false"

test_name "quote_balanced: escaped quote inside"
quote_balanced '"he\"llo"' && out=true || out=false
assert_eq "$out" "true"

test_name "quote_balanced: no quotes at all"
quote_balanced 'no quotes' && out=true || out=false
assert_eq "$out" "true"

test_name "quote_balanced: empty string"
quote_balanced '' && out=true || out=false
assert_eq "$out" "true"

test_name "quote_balanced: multiple quoted sections"
quote_balanced '"a" "b"' && out=true || out=false
assert_eq "$out" "true"

test_name "quote_balanced: odd number of quotes"
quote_balanced '"a" "b' && out=true || out=false
assert_eq "$out" "false"

# ==========================================================================
# unquote_command
# ==========================================================================

test_name "unquote_command: strip outer double quotes"
out=$(unquote_command '"echo hello"')
assert_eq "$out" "echo hello"

test_name "unquote_command: unescape inner quotes"
out=$(unquote_command '"echo \"quoted\""')
assert_eq "$out" 'echo "quoted"'

test_name "unquote_command: unescape backslashes"
out=$(unquote_command '"path\\to"')
assert_eq "$out" 'path\to'

test_name "unquote_command: bare command unchanged"
out=$(unquote_command 'bare cmd')
assert_eq "$out" "bare cmd"

test_name "unquote_command: empty quoted string"
out=$(unquote_command '""')
assert_eq "$out" ""

test_name "unquote_command: leading/trailing whitespace trimmed"
out=$(unquote_command '  "hello"  ')
assert_eq "$out" "hello"

test_name "unquote_command: single token no quotes"
out=$(unquote_command 'cmd')
assert_eq "$out" "cmd"

# ==========================================================================
# parse_layout
# ==========================================================================

test_name "parse_layout: single pane"
parse_layout 'a cmd'
assert_eq "$SMUX_PANE_COUNT" "1"
assert_eq "${SMUX_PANE_LABELS[0]}" "a"
assert_eq "${SMUX_PANE_COMMANDS[0]}" "cmd"

test_name "parse_layout: command with spaces"
parse_layout 'a echo hello world'
assert_eq "$SMUX_PANE_COUNT" "1"
assert_eq "${SMUX_PANE_LABELS[0]}" "a"
assert_eq "${SMUX_PANE_COMMANDS[0]}" "echo hello world"

test_name "parse_layout: two panes comma-separated"
parse_layout 'a cmd, b test'
assert_eq "$SMUX_PANE_COUNT" "2"
assert_eq "${SMUX_PANE_LABELS[0]}" "a"
assert_eq "${SMUX_PANE_COMMANDS[0]}" "cmd"
assert_eq "${SMUX_PANE_LABELS[1]}" "b"
assert_eq "${SMUX_PANE_COMMANDS[1]}" "test"

test_name "parse_layout: two columns pipe-separated"
parse_layout 'a cmd | b test'
assert_eq "$SMUX_PANE_COUNT" "2"
assert_eq "$SMUX_COL_COUNT_TOTAL" "2"
assert_eq "${SMUX_PANE_LABELS[0]}" "a"
assert_eq "${SMUX_PANE_LABELS[1]}" "b"

test_name "parse_layout: mixed comma and pipe"
parse_layout 'a, b | c'
assert_eq "$SMUX_PANE_COUNT" "3"
assert_eq "$SMUX_COL_COUNT_TOTAL" "2"
assert_eq "${SMUX_COL_COUNT[0]}" "2"
assert_eq "${SMUX_COL_COUNT[1]}" "1"

test_name "parse_layout: pipe inside double quotes preserved"
parse_layout 'a "echo | pipe" | b test'
assert_eq "$SMUX_PANE_COUNT" "2"
assert_eq "${SMUX_PANE_COMMANDS[0]}" 'echo | pipe'

test_name "parse_layout: comma inside double quotes preserved"
parse_layout 'a "echo , comma" | b test'
assert_eq "$SMUX_PANE_COUNT" "2"
assert_eq "${SMUX_PANE_COMMANDS[0]}" 'echo , comma'

test_name "parse_layout: empty shell pane (label only)"
parse_layout 'a | b'
assert_eq "$SMUX_PANE_COUNT" "2"
assert_eq "${SMUX_PANE_LABELS[0]}" "a"
assert_eq "${SMUX_PANE_COMMANDS[0]}" ""
assert_eq "${SMUX_PANE_LABELS[1]}" "b"
assert_eq "${SMUX_PANE_COMMANDS[1]}" ""

test_name "parse_layout: error on empty column (leading pipe)"
out=$(parse_layout '| b' 2>&1) && rc=0 || rc=$?
assert_neq "$rc" "0"
assert_contains "$out" "Empty column"

test_name "parse_layout: error on empty column (trailing pipe)"
out=$(parse_layout 'a |' 2>&1) && rc=0 || rc=$?
assert_neq "$rc" "0"
assert_contains "$out" "Empty column"

test_name "parse_layout: error on empty pane (double comma)"
out=$(parse_layout 'a, , b' 2>&1) && rc=0 || rc=$?
assert_neq "$rc" "0"
assert_contains "$out" "Empty pane"

test_name "parse_layout: error on invalid label"
out=$(parse_layout 'bad-label! cmd' 2>&1) && rc=0 || rc=$?
assert_neq "$rc" "0"
assert_contains "$out" "Invalid label"

test_name "parse_layout: error on unclosed quote"
out=$(parse_layout 'a "unclosed' 2>&1) && rc=0 || rc=$?
assert_neq "$rc" "0"
assert_contains "$out" "Unclosed quote"

test_name "parse_layout: label with dots and dashes"
parse_layout 'my-app.staging cmd'
assert_eq "$SMUX_PANE_COUNT" "1"
assert_eq "${SMUX_PANE_LABELS[0]}" "my-app.staging"

test_name "parse_layout: label with underscores"
parse_layout 'test_runner cmd'
assert_eq "$SMUX_PANE_COUNT" "1"
assert_eq "${SMUX_PANE_LABELS[0]}" "test_runner"

test_name "parse_layout: three columns"
parse_layout 'a | b | c'
assert_eq "$SMUX_PANE_COUNT" "3"
assert_eq "$SMUX_COL_COUNT_TOTAL" "3"

test_name "parse_layout: column width tracking"
parse_layout 'a cmd | b test'
assert_eq "${SMUX_COL_COUNT[0]}" "1"
assert_eq "${SMUX_COL_COUNT[1]}" "1"

# ==========================================================================
# parse_pipeline — quoted name regression
# ==========================================================================

test_name "parse_pipeline: quoted pipeline name strips quotes"
tmp_smux=$(mktemp)
cat > "$tmp_smux" <<'SMUX'
pipeline: "review-flow"
steps:
  a -> b "do the thing"
SMUX
parse_pipeline "$tmp_smux"
assert_eq "$SMUX_FLOW_NAME" "review-flow"
assert_eq "$SMUX_FLOW_STEP_COUNT" "1"
rm -f "$tmp_smux"

test_name "parse_pipeline: unquoted pipeline name preserved"
tmp_smux=$(mktemp)
cat > "$tmp_smux" <<'SMUX'
pipeline: review-flow
steps:
  a -> b "do the thing"
SMUX
parse_pipeline "$tmp_smux"
assert_eq "$SMUX_FLOW_NAME" "review-flow"
assert_eq "$SMUX_FLOW_STEP_COUNT" "1"
rm -f "$tmp_smux"

# ==========================================================================
# completion detection — tilde regression
# ==========================================================================

test_name "completion detection: literal tilde path matches"
tmp_rc=$(mktemp)
echo 'source ~/.smux/completions/tmux-bridge.bash' > "$tmp_rc"
grep -Fq '~/.smux/completions/tmux-bridge.bash' "$tmp_rc" && out=true || out=false
assert_eq "$out" "true"
rm -f "$tmp_rc"

test_name "completion detection: \$HOME path matches"
tmp_rc=$(mktemp)
echo 'source $HOME/.smux/completions/tmux-bridge.bash' > "$tmp_rc"
grep -Fq '$HOME/.smux/completions/tmux-bridge.bash' "$tmp_rc" && out=true || out=false
assert_eq "$out" "true"
rm -f "$tmp_rc"

test_name "completion detection: expanded path matches"
tmp_rc=$(mktemp)
echo "source $HOME/.smux/completions/tmux-bridge.bash" > "$tmp_rc"
grep -Fq "$HOME/.smux/completions/tmux-bridge.bash" "$tmp_rc" && out=true || out=false
assert_eq "$out" "true"
rm -f "$tmp_rc"

summary
