#!/usr/bin/env bash
# Tests for require_normal_mode — rejects type/message/keys when target in copy-mode.
# Creates an isolated tmux session for testing, cleans up after.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

eval "$(sed '/^# --- Main ---$/q' "$SCRIPT_DIR/../scripts/tmux-bridge")"

# Override die to not exit
die() { echo "error: $*" >&2; return 1; }

# Use an isolated tmux session
TEST_SESSION="smux-test-mode-$$"
cleanup() { tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true; }
trap cleanup EXIT

# Create detached test session
tmux new-session -d -s "$TEST_SESSION" -c "$SCRIPT_DIR/.."
TEST_PANE=$(tmux display-message -t "$TEST_SESSION" -p '#{pane_id}')
# Initialize socket detection for the test session
init_socket

echo "=== test_mode_guard.sh ==="

# ---- normal mode passes ----
test_name "require_normal_mode passes in normal mode"
# Default mode is 0 (normal)
if require_normal_mode "$TEST_PANE" 2>/dev/null; then
  echo -e "    ${GREEN}OK${NC}"
  ((ASSERT_PASSED++))
else
  fail "require_normal_mode should pass for normal mode pane"
fi

# ---- copy-mode rejects ----
test_name "require_normal_mode rejects in copy-mode"
tmux copy-mode -t "$TEST_PANE"
sleep 0.1
if require_normal_mode "$TEST_PANE" 2>/dev/null; then
  fail "require_normal_mode should reject copy-mode pane"
else
  echo -e "    ${GREEN}OK${NC}"
  ((ASSERT_PASSED++))
fi

# ---- error message contains hint ----
test_name "require_normal_mode error message has Escape/q hint"
err=$(require_normal_mode "$TEST_PANE" 2>&1 || true)
assert_contains "$err" "tmux-bridge wake"

# ---- back to normal mode passes ----
test_name "require_normal_mode passes after exiting copy-mode"
tmux send-keys -t "$TEST_PANE" Escape
sleep 0.1
if require_normal_mode "$TEST_PANE" 2>/dev/null; then
  echo -e "    ${GREEN}OK${NC}"
  ((ASSERT_PASSED++))
else
  fail "require_normal_mode should pass after exiting copy-mode"
fi

# ---- CLI integration: type/message/keys reject copy-mode ----
CLI="$SCRIPT_DIR/../scripts/tmux-bridge"

test_name "CLI: type rejects copy-mode pane"
# Exit copy-mode for baseline
tmux send-keys -t "$TEST_PANE" Escape; sleep 0.1
# Normal mode: should succeed
scripts/tmux-bridge read "$TEST_PANE" 3 >/dev/null 2>&1
if "$CLI" type "$TEST_PANE" 'test' 2>/dev/null; then
  echo -e "    ${GREEN}OK (normal mode)${NC}"
  ((++ASSERT_PASSED))
else
  fail "CLI type should succeed in normal mode"
fi

# Enter copy-mode
tmux copy-mode -t "$TEST_PANE"; sleep 0.1

# Copy-mode: type should be rejected (read guard still satisfied from above
# since the failed normal-mode send cleared it; re-read first)
scripts/tmux-bridge read "$TEST_PANE" 3 >/dev/null 2>&1
if "$CLI" type "$TEST_PANE" 'test' 2>/dev/null; then
  fail "CLI type should reject copy-mode"
else
  echo -e "    ${GREEN}OK (type rejected)${NC}"
  ((++ASSERT_PASSED))
fi

test_name "CLI: keys rejects copy-mode pane"
if "$CLI" keys "$TEST_PANE" Enter 2>/dev/null; then
  fail "CLI keys should reject copy-mode"
else
  echo -e "    ${GREEN}OK (keys rejected)${NC}"
  ((++ASSERT_PASSED))
fi

test_name "CLI: error message is user-friendly"
err=$("$CLI" type "$TEST_PANE" 'test' 2>&1 || true)
assert_contains "$err" "tmux-bridge wake"

test_name "CLI: wake returns ok in normal mode"
tmux send-keys -t "$TEST_PANE" Escape; sleep 0.1
out=$("$CLI" wake "$TEST_PANE")
assert_contains "$out" "already in normal mode"

test_name "CLI: wake exits copy-mode"
tmux copy-mode -t "$TEST_PANE"; sleep 0.1
out=$("$CLI" wake "$TEST_PANE")
assert_contains "$out" "returned to normal mode"
if require_normal_mode "$TEST_PANE" 2>/dev/null; then
  echo -e "    ${GREEN}OK (normal after wake)${NC}"
  ((++ASSERT_PASSED))
else
  fail "wake should return pane to normal mode"
fi

# Cleanup: exit copy-mode
tmux send-keys -t "$TEST_PANE" Escape; sleep 0.1

summary
