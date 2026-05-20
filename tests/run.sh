#!/usr/bin/env bash
# Run all tmux-bridge tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "tmux-bridge test suite"
echo "====================="
echo ""

total_failures=0

run_one() {
  local test_file="$1"
  echo "[$(basename "$test_file")]"
  if bash "$test_file"; then
    echo "  => PASS"
    echo ""
  else
    echo "  => FAIL"
    ((total_failures++)) || true
    echo ""
  fi
}

# Tests that don't require tmux
run_one "$SCRIPT_DIR/test_parse_text.sh"
run_one "$SCRIPT_DIR/test_read_guard.sh"
run_one "$SCRIPT_DIR/test_roundtrip.sh"

# Integration tests create their own tmux sessions — only need tmux binary
if command -v tmux &>/dev/null; then
  run_one "$SCRIPT_DIR/test_smux_workspace.sh"
  run_one "$SCRIPT_DIR/test_mode_guard.sh"
  run_one "$SCRIPT_DIR/test_file_transfer.sh"
else
  echo "[test_smux_workspace.sh] SKIPPED (tmux not installed)"
  echo "[test_mode_guard.sh] SKIPPED (tmux not installed)"
  echo "[test_file_transfer.sh] SKIPPED (tmux not installed)"
  echo ""
fi

echo "====================="
if [[ $total_failures -eq 0 ]]; then
  echo "All test suites passed."
  exit 0
else
  echo "$total_failures suite(s) FAILED."
  exit 1
fi
