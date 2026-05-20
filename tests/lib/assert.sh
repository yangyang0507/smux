#!/usr/bin/env bash
# Minimal assertion library for smux tests. Zero external dependencies.

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ASSERT_PASSED=0
ASSERT_FAILED=0
CURRENT_TEST=""

test_name() {
  CURRENT_TEST="$1"
  echo "  $1..."
}

assert_eq() {
  local got="$1" expected="$2" msg="${3:-}"
  if [[ "$got" != "$expected" ]]; then
    echo -e "    ${RED}FAIL${NC}: expected '$expected', got '$got'${msg:+ — $msg}"
    ((++ASSERT_FAILED))
    return 1
  fi
  echo -e "    ${GREEN}OK${NC}"
  ((++ASSERT_PASSED))
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "    ${RED}FAIL${NC}: expected to contain '$needle'${msg:+ — $msg}"
    echo "    got: $haystack"
    ((++ASSERT_FAILED))
    return 1
  fi
  echo -e "    ${GREEN}OK${NC}"
  ((++ASSERT_PASSED))
}

assert_status() {
  local got=$1 expected=$2 msg="${3:-}"
  if [[ "$got" -ne "$expected" ]]; then
    echo -e "    ${RED}FAIL${NC}: expected exit status $expected, got $got${msg:+ — $msg}"
    ((++ASSERT_FAILED))
    return 1
  fi
  echo -e "    ${GREEN}OK${NC}"
  ((++ASSERT_PASSED))
}

assert_ok() {
  local desc="${1:-command}"
  shift
  if "$@"; then
    echo -e "    ${GREEN}OK${NC}"
    ((++ASSERT_PASSED))
  else
    echo -e "    ${RED}FAIL${NC}: $desc failed (exit $?)"
    ((++ASSERT_FAILED))
  fi
}

summary() {
  local total=$((ASSERT_PASSED + ASSERT_FAILED))
  echo ""
  if [[ $ASSERT_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All $total assertions passed.${NC}"
  else
    echo -e "${RED}$ASSERT_FAILED/$total assertions FAILED.${NC}"
  fi
  return $ASSERT_FAILED
}
