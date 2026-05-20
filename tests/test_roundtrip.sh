#!/usr/bin/env bash
# Roundtrip tests — content survives text → base64 → parse_text --base64 → text.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

eval "$(sed '/^# --- Main ---$/q' "$SCRIPT_DIR/../scripts/tmux-bridge")"

ROUNDTRIP_TMP="/tmp/smux-rt-test-$$"

echo "=== test_roundtrip.sh ==="

# Helper: encode input as single-line base64, feed through parse_text --stdin --base64.
# Returns the decoded result text (trailing newlines preserved from parse_text,
# but outermost $(...) strips them — use read_stdin trick for full fidelity).
roundtrip() {
  local input="$1"
  local b64
  b64=$(printf '%s' "$input" | base64 | tr -d '\n')
  printf '%s' "$b64" > "$ROUNDTRIP_TMP"
  local out
  # Use printf-x trick to preserve trailing newlines through $(...)
  out=$(parse_text --stdin --base64 <"$ROUNDTRIP_TMP" 2>&1; rc=$?; printf 'RESULT=%sx' "$GET_TEXT_RESULT"; exit $rc)
  rm -f "$ROUNDTRIP_TMP"
  # Strip trailing x and RESULT= prefix
  out="${out%x}"
  printf '%s' "${out#RESULT=}"
}

test_name "roundtrip: plain ASCII"
result=$(roundtrip 'hello world from tmux-bridge')
assert_eq "$result" "hello world from tmux-bridge"

test_name "roundtrip: text with single quotes"
result=$(roundtrip "it's 'quoted' here")
assert_eq "$result" "it's 'quoted' here"

test_name "roundtrip: text with dollar signs and backticks"
result=$(roundtrip '$PATH `cmd` $(sub)')
assert_eq "$result" '$PATH `cmd` $(sub)'

test_name "roundtrip: text with newlines"
input=$'line one\nline two\nline three'
result=$(roundtrip "$input")
assert_eq "$result" $'line one\nline two\nline three' "newlines preserved in roundtrip"

test_name "roundtrip: JSON payload"
json='{"key":"value","nested":{"arr":[1,2,3]}}'
result=$(roundtrip "$json")
assert_eq "$result" "$json"

test_name "roundtrip: empty string"
result=$(roundtrip '')
assert_eq "$result" ""

test_name "roundtrip: emoji"
result=$(roundtrip '🖥️🌉✅')
assert_eq "$result" '🖥️🌉✅'

test_name "roundtrip: trailing newline preserved"
# The roundtrip helper uses the printf-x trick to preserve trailing newlines
# through $(...), so a trailing \n in the input survives the full roundtrip.
input=$'ends with newline\n'
result=$(roundtrip "$input"; printf x)
result="${result%x}"
assert_eq "$result" $'ends with newline\n' "trailing newline preserved"

# ---- stdin auto-detect roundtrip ----
test_name "stdin auto-detect preserves content"
input="auto-detected pipe content"
printf '%s' "$input" > "$ROUNDTRIP_TMP"
result=$(parse_text <"$ROUNDTRIP_TMP" 2>&1; rc=$?; printf 'RESULT=%s\n' "$GET_TEXT_RESULT"; exit $rc)
rm -f "$ROUNDTRIP_TMP"
result=$(echo "$result" | sed -n 's/^RESULT=//p')
assert_eq "$result" "$input"

summary
