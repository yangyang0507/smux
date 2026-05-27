#!/usr/bin/env bash
# Golden tests for .smux DSL parsing.
# Runs each fixture in tests/fixtures/smux-dsl/ through parse_layout()
# and parse_pipeline(), outputs TSV+base64 normalized format, compares
# against companion .expected files.
#
# Usage:
#   bash tests/test_dsl_spec.sh              # verify against .expected
#   bash tests/test_dsl_spec.sh --update      # regenerate .expected files
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
eval "$(sed '/^# --- Main ---$/q' "$SCRIPT_DIR/../install.sh")"
set +e  # re-apply after eval installs its own set -e

FIXTURE_DIR="$SCRIPT_DIR/fixtures/smux-dsl"
MODE="${1:-verify}"

# Normalize output format:
#   layout<TAB>panes=N<TAB>cols=M
#   pane<TAB>idx<TAB>col<TAB>label<TAB>cmd_b64
#   pipeline<TAB>name<TAB>steps=N
#   step<TAB>idx<TAB>from<TAB>to<TAB>prompt_b64
#   error<TAB>message_substring
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

golden_parse() {
  local file="$1" raw
  # Run in subshell so error()'s exit 1 only kills the subshell.
  # error() writes to stdout (golden format), 2>&1 captures any residual stderr.
  raw=$(
    # Override error: golden format + exit subshell
    error() { printf 'error\t%s\n' "$*"; exit 1; }

    local layout_line_out
    # layout_line calls error() on failure (multiple layouts, empty file).
    # The overridden error() writes error\t... to stdout and exits the
    # command substitution.  So layout_line_out already has the error text.
    layout_line_out=$(layout_line "$file" 2>/dev/null) || true
    if [[ "$layout_line_out" =~ ^error ]]; then
      # Error message already captured — print it and exit
      printf '%s\n' "$layout_line_out"
      exit 1
    fi

    parse_layout "$layout_line_out"
    printf 'layout\tpanes=%d\tcols=%d\n' "$SMUX_PANE_COUNT" "$SMUX_COL_COUNT_TOTAL"
    local i
    for (( i=0; i<SMUX_PANE_COUNT; i++ )); do
      printf 'pane\t%d\t%d\t%s\t%s\n' "$i" \
        "${SMUX_PANE_COLS[i]}" \
        "${SMUX_PANE_LABELS[i]}" \
        "$(printf '%s' "${SMUX_PANE_COMMANDS[i]}" | base64 | tr -d '\n')"
    done

    # --- Pipeline ---
    if grep -q '^pipeline:' "$file" 2>/dev/null; then
      parse_pipeline "$file"
      printf 'pipeline\t%s\tsteps=%d\n' "$SMUX_FLOW_NAME" "$SMUX_FLOW_STEP_COUNT"
      local j
      for (( j=0; j<SMUX_FLOW_STEP_COUNT; j++ )); do
        printf 'step\t%d\t%s\t%s\t%s\n' "$j" \
          "${SMUX_FLOW_STEP_FROM[j]}" \
          "${SMUX_FLOW_STEP_TO[j]}" \
          "$(printf '%s' "${SMUX_FLOW_STEP_PROMPT[j]}" | base64 | tr -d '\n')"
      done
    fi
  ) 2>&1
  printf '%s' "$raw"
}

echo "=== test_dsl_spec.sh ==="

total=0
passed=0
failed=0

for fixture in "$FIXTURE_DIR"/*.smux; do
  [[ -f "$fixture" ]] || continue
  base=$(basename "$fixture" .smux)
  expected="$FIXTURE_DIR/$base.expected"
  total=$((total + 1))

  if [[ "$MODE" == "--update" ]]; then
    golden_parse "$fixture" > "$expected"
    echo "  updated: $base.expected"
    continue
  fi

  test_name "dsl golden: $base"
  actual=$(golden_parse "$fixture")

  if [[ ! -f "$expected" ]]; then
    fail "missing .expected file for $base"
    failed=$((failed + 1))
    continue
  fi

  expected_content=$(cat "$expected")
  if [[ "$actual" != "$expected_content" ]]; then
    echo -e "    \033[0;31mFAIL\033[0m: output differs from .expected"
    echo "    --- expected ---"
    echo "$expected_content"
    echo "    --- actual ---"
    echo "$actual"
    echo "    --- diff ---"
    diff <(echo "$expected_content") <(echo "$actual") || true
    failed=$((failed + 1))
  else
    echo -e "    \033[0;32mOK\033[0m"
    passed=$((passed + 1))
  fi
done

if [[ "$MODE" == "--update" ]]; then
  echo "Updated $total .expected files."
  exit 0
fi

echo ""
echo "Golden tests: $passed/$total passed"
if [[ $failed -gt 0 ]]; then
  echo -e "\033[0;31m$failed FAILED\033[0m"
  exit 1
fi
echo -e "\033[0;32mAll golden tests passed.\033[0m"
