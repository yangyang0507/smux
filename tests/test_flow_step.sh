#!/usr/bin/env bash
# Integration test for tmux-bridge flow step auto-start.
# Covers the TSV ingestion path introduced in v2.4.4.
# Requires tmux running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_SESSION="smux-test-flow-$$"
TMPDIR_SESSION="${TMPDIR:-/tmp}"
TMP_PROJECT=$(mktemp -d "${TMPDIR:-/tmp}/smux-flow-test-XXXXXX")

cleanup() {
  rm -rf "$TMP_PROJECT"
  rm -f "$TMPDIR_SESSION"/tmux-bridge-flow-"${TEST_SESSION}"-*
  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== test_flow_step.sh ==="

# ==========================================================================
# Setup: create project with .smux pipeline, tmux session with two panes
# ==========================================================================

cat > "$TMP_PROJECT/.smux" <<'SMUX'
w writer, r reviewer

pipeline: review-flow
steps:
  w -> r "review this change"
  r -> w "feedback applied"
SMUX

# Create detached tmux session with two panes
tmux new-session -d -s "$TEST_SESSION" -c "$TMP_PROJECT" "sleep 600"
WRITER_PANE=$(tmux display-message -t "$TEST_SESSION" -p '#{pane_id}')
REVIEWER_PANE=$(tmux split-window -P -F '#{pane_id}' -h -t "$TEST_SESSION" -c "$TMP_PROJECT" "sleep 600")

# Verify pane IDs are valid
[[ -n "$WRITER_PANE" ]] || fail "writer pane id is empty"
[[ -n "$REVIEWER_PANE" ]] || fail "reviewer pane id is empty"
[[ "$WRITER_PANE" != "$REVIEWER_PANE" ]] || fail "writer and reviewer pane ids are the same"

# Label panes and set project
tmux set-option -t "$TEST_SESSION" @smux_project "$TMP_PROJECT"
tmux set-option -p -t "$WRITER_PANE" @name w
tmux set-option -p -t "$REVIEWER_PANE" @name r

# Resolve socket for the test session
TMUX_SOCKET=$(tmux display-message -t "$TEST_SESSION" -p '#{socket_path}')
[[ -n "$TMUX_SOCKET" ]] || fail "cannot determine tmux socket path"

# Helper: invoke real tmux-bridge CLI entrypoint
run_flow_step() {
  local pane="$1" smux_cli="$2"
  TMUX_BRIDGE_SOCKET="$TMUX_SOCKET" \
  TMUX_PANE="$pane" \
  SMUX_CLI="$smux_cli" \
    "$REPO_ROOT/scripts/tmux-bridge" flow step 2>&1
}

# ==========================================================================
# Test 1: SMUX_CLI fatal when set to invalid path
# ==========================================================================

test_name "flow step: SMUX_CLI invalid fails without fallback"
out=$(run_flow_step "$WRITER_PANE" /no/such/smux) && rc=0 || rc=$?
assert_neq "$rc" "0"
assert_contains "$out" "SMUX_CLI"

# ==========================================================================
# Test 2: auto-start flow from writer pane (step 0)
# ==========================================================================

test_name "flow step: auto-start from writer (step 1)"

out=$(run_flow_step "$WRITER_PANE" "$REPO_ROOT/install.sh"); rc=$?
assert_contains "$out" "auto-started from .smux"
assert_contains "$out" "review-flow"

# Check ctx file exists with expected content
ctx_file=$(find "$TMPDIR_SESSION" -maxdepth 1 -name "tmux-bridge-flow-${TEST_SESSION}-*.ctx" 2>/dev/null | head -1)
assert_neq "$ctx_file" ""
if [[ -n "$ctx_file" ]]; then
  ctx_content=$(cat "$ctx_file")
  assert_contains "$ctx_content" "name=review-flow"
  assert_contains "$ctx_content" "steps=2"
  assert_contains "$ctx_content" "step_0=w|r|"
  assert_contains "$ctx_content" "review this change"
  assert_contains "$ctx_content" "step_1=r|w|"
  assert_contains "$ctx_content" "feedback applied"

  # Check state file = 1 (completed step 0, next is step 1)
  state_file="${ctx_file%.ctx}"
  if [[ -f "$state_file" ]]; then
    state=$(cat "$state_file")
    assert_eq "$state" "1"
  else
    fail "state file missing after step 1"
  fi
fi

# ==========================================================================
# Test 3: flow step from reviewer pane (step 1, completes pipeline)
# ==========================================================================

test_name "flow step: reviewer completes pipeline"

out=$(run_flow_step "$REVIEWER_PANE" "$REPO_ROOT/install.sh"); rc=$?
assert_contains "$out" "done"

# After completion, ctx and state files should be cleaned up
if [[ -n "$ctx_file" ]]; then
  state_file="${ctx_file%.ctx}"
  if [[ -f "$state_file" || -f "$ctx_file" ]]; then
    fail "ctx/state files should be cleaned up after pipeline completes"
  else
    echo -e "    \033[0;32mOK\033[0m"
  fi
fi

summary
