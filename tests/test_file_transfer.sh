#!/usr/bin/env bash
# Tests for tmux-bridge file — stages content and sends only a short path notice.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

CLI="$SCRIPT_DIR/../scripts/tmux-bridge"
TEST_SESSION="smux-test-file-$$"
TEST_INPUT="${TMPDIR:-/tmp}/smux-file-input-$$.txt"
STAGED_DIRS=()

cleanup() {
  local d
  for d in "${STAGED_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
  rm -f "$TEST_INPUT"
}
trap cleanup EXIT

# Record the parent dir of a staged file for cleanup
track_staged() { STAGED_DIRS+=("$(dirname "$1")"); }

tmux new-session -d -s "$TEST_SESSION" -c "$SCRIPT_DIR/.." "cat"
TEST_PANE=$(tmux display-message -t "$TEST_SESSION" -p '#{pane_id}')

echo "=== test_file_transfer.sh ==="

test_name "file stages local path and sends notice"
printf 'hello file\nsecond line\n' >"$TEST_INPUT"
TMUX_PANE="$TEST_PANE" "$CLI" read "$TEST_PANE" 2 >/dev/null
out=$(TMUX_PANE="$TEST_PANE" "$CLI" file "$TEST_PANE" "$TEST_INPUT")
track_staged "$out"
assert_contains "$out" "tmux-bridge-file"
assert_ok "staged file exists" test -f "$out"
staged=$(cat "$out")
assert_eq "$staged" $'hello file\nsecond line' "staged content preserved"
tmux send-keys -t "$TEST_PANE" Enter
sleep 0.1
pane_text=$(tmux capture-pane -t "$TEST_PANE" -p -S -)
assert_contains "$pane_text" "Shared file '$(basename "$TEST_INPUT")'"
assert_contains "$pane_text" "tmux-bridge-file"

test_name "file --stdin stages stdin content"
TMUX_PANE="$TEST_PANE" "$CLI" read "$TEST_PANE" 2 >/dev/null
out=$(printf 'from stdin\n' | TMUX_PANE="$TEST_PANE" "$CLI" file "$TEST_PANE" --stdin --name stdin.txt)
track_staged "$out"
assert_ok "stdin staged file exists" test -f "$out"
staged=$(cat "$out")
assert_eq "$staged" "from stdin" "stdin staged content"

test_name "file truncates by max lines"
printf 'one\ntwo\nthree\n' >"$TEST_INPUT"
TMUX_PANE="$TEST_PANE" "$CLI" read "$TEST_PANE" 2 >/dev/null
out=$(TMUX_PANE="$TEST_PANE" "$CLI" file "$TEST_PANE" --max-lines 2 "$TEST_INPUT")
track_staged "$out"
staged=$(cat "$out")
assert_contains "$staged" "one"
assert_contains "$staged" "two"
assert_contains "$staged" "content truncated"

summary
