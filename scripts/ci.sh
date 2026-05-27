#!/usr/bin/env bash
# CI checks for smux. Run from repo root: bash scripts/ci.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=== git diff --check ==="
git diff --check
echo "PASS"
echo ""

echo "=== shellcheck ==="
shellcheck install.sh scripts/tmux-bridge scripts/ci.sh
echo "PASS"
echo ""

echo "=== tests ==="
tests/run.sh
echo "PASS"
echo ""

echo "=== update dry-run ==="
# Capture to avoid SIGPIPE from head in pipefail mode
update_out=$(bash install.sh update --dry-run 2>&1)
echo "$update_out" | head -20
echo "PASS"
echo ""

echo "All checks passed."
