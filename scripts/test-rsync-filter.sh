#!/usr/bin/env bash
# test-rsync-filter.sh — what RSYNC_FILTER actually ships, measured with rsync.
#
# This suite exists because SELF_VERIFY and RSYNC_FILTER answer different
# questions and neither one covers the other. SELF_VERIFY asks "is the tree
# committed"; RSYNC_FILTER asks "which bytes leave this machine". A file can be
# invisible to the first and shippable by the second -- that gap is exactly the
# AppleDouble case below, and test-deploy-self-verify.sh structurally cannot
# catch it, because git never reports the file it would need to assert on.
#
# The filter is EXTRACTED from deploy.sh, never copied. A copied allow-list
# tests the copy: it stays green while the real list rots.
set -euo pipefail

PASS=0 FAIL=0 TOTAL=0
SRC_DEPLOY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy.sh"

assert_ships() {
  TOTAL=$((TOTAL + 1))
  local path="$1" shipped="$2"
  if grep -qxF "$path" <<<"$shipped"; then
    PASS=$((PASS + 1)); echo "  ✓ ships: $path"
  else
    FAIL=$((FAIL + 1)); echo "  ✗ SHOULD ship but did not: $path"
  fi
}

assert_blocked() {
  TOTAL=$((TOTAL + 1))
  local path="$1" shipped="$2"
  if grep -qxF "$path" <<<"$shipped"; then
    FAIL=$((FAIL + 1)); echo "  ✗ SHIPPED but must not: $path"
  else
    PASS=$((PASS + 1)); echo "  ✓ blocked: $path"
  fi
}

# Load the live filter array out of deploy.sh.
load_filter() {
  local block
  block=$(sed -n '/^RSYNC_FILTER=(/,/^)/p' "$SRC_DEPLOY")
  if [[ -z "$block" ]]; then
    echo "FATAL: could not extract RSYNC_FILTER from $SRC_DEPLOY" >&2
    exit 2
  fi
  eval "$block"
  if [[ ${#RSYNC_FILTER[@]} -lt 10 ]]; then
    echo "FATAL: extracted only ${#RSYNC_FILTER[@]} filter rules -- parse broke" >&2
    exit 2
  fi
}

# Build a source tree carrying one file per claim, then ask rsync.
manifest() {
  local src="$1"
  mkdir -p "$src/blog" "$src/how-to" "$src/mini"
  # must ship
  echo x > "$src/index.html"
  echo x > "$src/blog/real.html"
  echo x > "$src/blog/hero.png"
  echo x > "$src/how-to/photo.html"
  # AppleDouble: git-ignored AND matches a shipping glob. The whole point.
  echo x > "$src/blog/._ghost.html"
  echo x > "$src/blog/._sidecar.png"
  echo x > "$src/how-to/._ghost.html"
  # Root case. NOT '._index.html' -- that was the first draft of this line and
  # it was a free green: no root include globs .html (they are literal
  # filenames), so it could not ship with or without the exclude and the
  # assertion proved nothing. '._style.css' matches --include='/*.css'.
  echo x > "$src/._style.css"
  # controls: git-ignored, but no include matches them anyway. These must stay
  # green under BOTH the fixed and unfixed filter -- if one ever goes red it
  # means the exclude is over-reaching, not that the bug came back.
  echo x > "$src/blog/.post.html.swp"
  echo x > "$src/index.html~"
  echo x > "$src/.DS_Store"
  # control: a legitimate leading-dot name must be unaffected by '._*'
  echo x > "$src/blog/.well-known.html"
}

what_ships() {
  local src="$1" dest="$2"
  rsync -rn --itemize-changes "${RSYNC_FILTER[@]}" "$src/" "$dest/" \
    | awk '{print $2}' | sed 's:/$::' | sort
}

echo "=== RSYNC_FILTER: AppleDouble sidecars must not reach the CDN ==="
load_filter
echo "  (${#RSYNC_FILTER[@]} rules extracted from scripts/deploy.sh)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src" "$work/dest"
manifest "$work/src"
shipped=$(what_ships "$work/src" "$work/dest")

# The bug, asserted on the PATH rather than on a count or an exit code -- a
# count is satisfied by any four files, and rsync -n exits 0 either way.
assert_blocked "blog/._ghost.html"   "$shipped"
assert_blocked "blog/._sidecar.png"  "$shipped"
assert_blocked "how-to/._ghost.html" "$shipped"
assert_blocked "._style.css"         "$shipped"

# Positive control: the exclude must not have eaten the site.
assert_ships "index.html"        "$shipped"
assert_ships "blog/real.html"    "$shipped"
assert_ships "blog/hero.png"     "$shipped"
assert_ships "how-to/photo.html" "$shipped"
assert_ships "blog/.well-known.html" "$shipped"

# Negative controls: ignored, and already unshippable without the new rule.
assert_blocked "blog/.post.html.swp" "$shipped"
assert_blocked "index.html~"         "$shipped"
assert_blocked ".DS_Store"           "$shipped"

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
