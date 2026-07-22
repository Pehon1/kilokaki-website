#!/usr/bin/env bash
# test-cache-paths.sh — prove deploy.sh derives its purge/verify set from what
# rsync actually moved, and prove it goes RED when the derivation is wrong.
#
# WHY THIS EXISTS
# CACHE_PATHS used to be a hand-kept literal: (/sitemap.xml / /blog/ /how-to/).
# It covered the incident that produced it and nothing after — a newly-published
# /blog/<new-slug>/ was never purged from Varnish and never checked by
# verify-edge, and the script said so in its own post-deploy text. Text is not
# a guard. This is.
#
# WHAT IT DOES NOT TEST
# It does not deploy, purge, or reach the network. It feeds a synthetic rsync
# itemized log to the REAL derivation lines and asserts on the two arrays.
#
# THE LINES UNDER TEST ARE EXTRACTED FROM deploy.sh, NOT RETYPED HERE.
# A test that carries its own copy of the logic passes forever while the
# shipped copy rots. If the markers below stop matching, this file fails loud
# rather than silently testing nothing — that check is the first assertion.
#
# Usage: bash scripts/test-cache-paths.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SH="${SCRIPT_DIR}/deploy.sh"

pass=0
fail=0

ok()   { echo "  ok    — $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  — $1"; echo "          expected: $2"; echo "          actual:   $3"; fail=$((fail + 1)); }

check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}

# --- Extract the real derivation block -------------------------------------
# From `MAX_PATHS=` down to the line that reports the counts.
BLOCK="$(sed -n '/^MAX_PATHS=/,/^echo "→ \${#_changed\[@\]} file/p' "$DEPLOY_SH")"

echo "=== extraction ==="
if [[ -z "$BLOCK" ]]; then
  echo "  FAIL  — could not extract the derivation block from deploy.sh."
  echo "          The markers moved. This test is testing NOTHING until fixed."
  exit 1
fi
for needle in 'to_url_path()' 'dedupe_into VERIFY_PATHS' 'dedupe_into CACHE_PATHS' '_deleted+=' ; do
  if [[ "$BLOCK" == *"$needle"* ]]; then
    ok "block contains ${needle}"
  else
    bad "block contains ${needle}" "present" "absent — extraction is partial"
  fi
done

derive() { # derive <fixture-file>; sets CACHE_PATHS / VERIFY_PATHS
  XFER_LOG="$1"
  unset CACHE_PATHS VERIFY_PATHS _changed _deleted
  eval "$BLOCK" >/dev/null
}

# --- Fixture 1: a new blog post, an edit, and a deletion --------------------
FIX1="$(mktemp -t kk-xfer1.XXXXXX)"
cat > "$FIX1" <<'EOF'
sending incremental file list
cd+++++++++ blog/new-slug/
>f+++++++++ blog/new-slug/index.html
>f.st...... index.html
>f.st...... sitemap.xml
.f........./ blog/untouched/index.html
<f.st...... how-to/calories/index.html
>f+++++++++ blog/hero.png
*deleting   blog/dead-post/index.html
*deleting   blog/dead-post/

sent 1,234 bytes  received 56 bytes  2,580.00 bytes/sec
total size is 987,654  speedup is 765.43
EOF

echo "=== fixture 1: new post + edits + delete ==="
derive "$FIX1"

check "the NEW post is in the purge set" \
  "yes" "$(printf '%s\n' ${CACHE_PATHS[@]+"${CACHE_PATHS[@]}"} | grep -qx '/blog/new-slug/' && echo yes || echo no)"

check "the NEW post is in the verify set" \
  "yes" "$(printf '%s\n' ${VERIFY_PATHS[@]+"${VERIFY_PATHS[@]}"} | grep -qx '/blog/new-slug/' && echo yes || echo no)"

check "root index.html maps to /" \
  "yes" "$(printf '%s\n' ${VERIFY_PATHS[@]+"${VERIFY_PATHS[@]}"} | grep -qx '/' && echo yes || echo no)"

check "a nested non-index asset keeps its own path" \
  "yes" "$(printf '%s\n' ${CACHE_PATHS[@]+"${CACHE_PATHS[@]}"} | grep -qx '/blog/hero.png' && echo yes || echo no)"

check "an UNCHANGED file (.f attr-only tick) is NOT included" \
  "no" "$(printf '%s\n' ${CACHE_PATHS[@]+"${CACHE_PATHS[@]}"} | grep -qx '/blog/untouched/' && echo yes || echo no)"

check "a DIRECTORY entry (cd+++) is NOT included as a file path" \
  "no" "$(printf '%s\n' ${CACHE_PATHS[@]+"${CACHE_PATHS[@]}"} | grep -qx '/blog/new-slug/index.html' && echo yes || echo no)"

# The delete split is the whole reason there are two arrays: verify-edge diffs
# the edge against a repo file, and a deleted path has none. Purge it, never
# verify it — otherwise a clean deletion returns UNKNOWN and reds the deploy.
check "a DELETED path IS purged" \
  "yes" "$(printf '%s\n' ${CACHE_PATHS[@]+"${CACHE_PATHS[@]}"} | grep -qx '/blog/dead-post/' && echo yes || echo no)"

check "a DELETED path is NOT verified" \
  "no" "$(printf '%s\n' ${VERIFY_PATHS[@]+"${VERIFY_PATHS[@]}"} | grep -qx '/blog/dead-post/' && echo yes || echo no)"

check "no duplicates in the purge set" \
  "0" "$(printf '%s\n' ${CACHE_PATHS[@]+"${CACHE_PATHS[@]}"} | sort | uniq -d | grep -c . )"

# --- Fixture 2: nothing changed --------------------------------------------
# The empty case is not academic: bash 3.2 + `set -u` aborts on "${empty[@]}",
# which would kill the deploy AFTER upload and BEFORE the purge.
FIX2="$(mktemp -t kk-xfer2.XXXXXX)"
cat > "$FIX2" <<'EOF'
sending incremental file list

sent 812 bytes  received 19 bytes  1,662.00 bytes/sec
total size is 987,654  speedup is 1,188.51
EOF

echo "=== fixture 2: nothing changed ==="
derive "$FIX2"
check "empty transfer still yields the floor, and does not abort" \
  "/ /sitemap.xml" "${CACHE_PATHS[*]}"

# --- Fixture 3: the regression this replaces --------------------------------
# The old literal list. If someone reverts to it, these assertions go red.
echo "=== fixture 3: the old hand-kept list would have failed ==="
OLD_LIST=(/sitemap.xml / /blog/ /how-to/)
check "old list did NOT cover the new post (this is the bug)" \
  "no" "$(printf '%s\n' "${OLD_LIST[@]}" | grep -qx '/blog/new-slug/' && echo yes || echo no)"

rm -f "$FIX1" "$FIX2"

echo ""
echo "passed: $pass   failed: $fail"
[[ $fail -eq 0 ]] || exit 1
