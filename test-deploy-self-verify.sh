#!/usr/bin/env bash
# test-deploy-self-verify.sh — Self-verify gate must fire BEFORE any network call.
# Creates fresh git repos from scratch (avoids nested git repo issues).
set -euo pipefail

PASS=0 FAIL=0 TOTAL=0

# --- Helpers ---
assert_contains() {
  TOTAL=$((TOTAL + 1))
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    PASS=$((PASS + 1))
    echo "  ✓ $label"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $label (pattern not found: $needle)"
  fi
}

assert_not_contains() {
  TOTAL=$((TOTAL + 1))
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    FAIL=$((FAIL + 1))
    echo "  ✗ $label (should NOT contain: $needle)"
  else
    PASS=$((PASS + 1))
    echo "  ✓ $label"
  fi
}

# Source files
SRC_SCRIPTS="/Users/pehonong/.openclaw-mochi/workspace/kilokaki-site/scripts"
SRC_ROOT="/Users/pehonong/.openclaw-mochi/workspace/kilokaki-site"

# Create a minimal git repo for testing
make_repo() {
  local tmpdir="$1"
  mkdir -p "$tmpdir/scripts"
  cp "$SRC_SCRIPTS/deploy.sh" "$tmpdir/scripts/"
  cp "$SRC_SCRIPTS/content-gate.sh" "$tmpdir/scripts/"
  cp "$SRC_SCRIPTS/deploy.env.example" "$tmpdir/scripts/"
  cp "$SRC_ROOT/index.html" "$tmpdir/"
  (
    cd "$tmpdir"
    git init -q
    git config user.email "test@test"
    git config user.name "test"
    git add -A
    git commit -q -m "test baseline"
  )
}

# --- Test 1: Clean tree → self-verify passes, SHA printed ---
echo "=== Test 1: clean tree → self-verify passes, SHA printed ==="
tmpdir=$(mktemp -d)
make_repo "$tmpdir"
(
  cd "$tmpdir"
  bash scripts/deploy.sh --check > "$tmpdir/out.txt" 2>&1 || true
)
out=$(cat "$tmpdir/out.txt")
assert_contains "self-verify passes" "✓ Self-verify: deploy.sh is committed, tree is clean" "$out"
assert_contains "SHA printed" "deploy.sh committed under: [0-9a-f]\{8\}" "$out"
assert_not_contains "no upload" "Files uploaded" "$out"
rm -rf "$tmpdir"

# --- Test 2: Dirty deploy.sh → aborts before network ---
echo "=== Test 2: dirty deploy.sh → aborts before network ==="
tmpdir=$(mktemp -d)
make_repo "$tmpdir"
(
  cd "$tmpdir"
  echo "# DIRTY" >> scripts/deploy.sh
  bash scripts/deploy.sh --check > "$tmpdir/out.txt" 2>&1 || true
)
out=$(cat "$tmpdir/out.txt")
assert_contains "dirty tree aborts" "ABORT: uncommitted changes detected" "$out"
assert_not_contains "no upload" "Files uploaded" "$out"
assert_not_contains "no drift guard" "Drift guard" "$out"
rm -rf "$tmpdir"

# --- Test 3: Dirty index.html → aborts before network ---
echo "=== Test 3: dirty index.html → aborts before network ==="
tmpdir=$(mktemp -d)
make_repo "$tmpdir"
(
  cd "$tmpdir"
  echo "<!-- DIRTY -->" >> index.html
  bash scripts/deploy.sh --check > "$tmpdir/out.txt" 2>&1 || true
)
out=$(cat "$tmpdir/out.txt")
assert_contains "dirty index.html aborts" "ABORT: uncommitted changes detected" "$out"
assert_not_contains "no upload" "Files uploaded" "$out"
rm -rf "$tmpdir"

# --- Test 4: Untracked deploy.sh → aborts ---
echo "=== Test 4: untracked deploy.sh → aborts ==="
tmpdir=$(mktemp -d)
make_repo "$tmpdir"
(
  cd "$tmpdir"
  git rm --cached scripts/deploy.sh > /dev/null 2>&1
  echo "# UNTRACKED" >> scripts/deploy.sh
  bash scripts/deploy.sh --check > "$tmpdir/out.txt" 2>&1 || true
)
out=$(cat "$tmpdir/out.txt")
assert_contains "untracked deploy.sh aborts" "ABORT" "$out"
rm -rf "$tmpdir"

# --- Summary ---
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
