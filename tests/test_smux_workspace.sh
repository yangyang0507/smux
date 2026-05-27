#!/usr/bin/env bash
# Tests for smux workspace parsing and agent status output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

eval "$(sed '/^# --- Main ---$/q' "$SCRIPT_DIR/../install.sh")"

TMP_SMUX="${TMPDIR:-/tmp}/smux-workspace-test-$$.smux"
TEST_SESSION="smux-test-agents-$$"

cleanup() {
  rm -f "$TMP_SMUX"
  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== test_smux_workspace.sh ==="

test_name "layout_line strips inline comments"
cat >"$TMP_SMUX" <<'EOF'
# full line comment
writer codex # inline comment
EOF
line=$(layout_line "$TMP_SMUX")
assert_eq "$line" "writer codex"

test_name "layout_line preserves # inside double quotes"
cat >"$TMP_SMUX" <<'EOF'
runner "printf '# keep this'" # inline comment
EOF
line=$(layout_line "$TMP_SMUX")
assert_eq "$line" "runner \"printf '# keep this'\""

test_name "parse_layout accepts commented layout"
parse_layout "$line"
assert_eq "${SMUX_PANE_LABELS[0]}" "runner"
assert_eq "${SMUX_PANE_COMMANDS[0]}" "printf '# keep this'"

test_name "status --agents lists labeled panes"
tmux new-session -d -s "$TEST_SESSION" -c "$SCRIPT_DIR/.." "sleep 60"
pane=$(tmux display-message -t "$TEST_SESSION" -p '#{pane_id}')
tmux set-option -t "$TEST_SESSION" @smux_project "$SCRIPT_DIR/.." >/dev/null
tmux set-option -p -t "$pane" @name reviewer >/dev/null
out=$(cmd_status --agents)
assert_contains "$out" "$TEST_SESSION"
assert_contains "$out" "$pane"
assert_contains "$out" "reviewer"

summary
