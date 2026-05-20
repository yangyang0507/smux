#!/usr/bin/env bash
# Tests for read guard — mark/require/clear state machine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

# Source function definitions only
eval "$(sed '/^# --- Main ---$/q' "$SCRIPT_DIR/../scripts/tmux-bridge")"

# Override die to not exit (read_guard helper funcs don't call die directly,
# but require_read calls die on guard miss)
die() { echo "error: $*" >&2; return 1; }

echo "=== test_read_guard.sh ==="

# Use a unique pane ID for this test run
TEST_PANE="%test$$"
GUARD_FILE="/tmp/tmux-bridge-read-${TEST_PANE//%/_}"

cleanup() { rm -f "$GUARD_FILE"; }
trap cleanup EXIT
cleanup

# ---- mark_read ----
test_name "mark_read creates guard file"
mark_read "$TEST_PANE"
assert_ok "guard file exists" test -f "$GUARD_FILE"

# ---- require_read success ----
test_name "require_read passes when guard exists"
if require_read "$TEST_PANE" 2>/dev/null; then
  echo -e "    ${GREEN}OK${NC}"
  ((ASSERT_PASSED++))
else
  echo -e "    ${RED}FAIL${NC}: require_read should pass when guard exists"
  ((ASSERT_FAILED++))
fi

# ---- clear_read ----
test_name "clear_read removes guard file"
clear_read "$TEST_PANE"
assert_ok "guard file removed" test ! -f "$GUARD_FILE"

# ---- require_read fails ----
test_name "require_read fails when guard missing"
if require_read "$TEST_PANE" 2>/dev/null; then
  echo -e "    ${RED}FAIL${NC}: require_read should fail when guard is absent"
  ((ASSERT_FAILED++))
else
  echo -e "    ${GREEN}OK${NC}"
  ((ASSERT_PASSED++))
fi

# ---- require_read error message ----
test_name "require_read prints error on guard miss"
err=$(require_read "$TEST_PANE" 2>&1 || true)
assert_contains "$err" "must read the pane before interacting"

# ---- full cycle: mark -> require -> clear -> require fails ----
test_name "read guard full cycle"
mark_read "$TEST_PANE"
if require_read "$TEST_PANE" 2>/dev/null; then
  echo -e "    ${GREEN}step1: OK${NC}"
  ((ASSERT_PASSED++))
else
  fail "step1: require_read after mark"
fi
clear_read "$TEST_PANE"
if ! require_read "$TEST_PANE" 2>/dev/null; then
  echo -e "    ${GREEN}step2: OK${NC}"
  ((ASSERT_PASSED++))
else
  fail "step2: require_read after clear should fail"
fi

summary
