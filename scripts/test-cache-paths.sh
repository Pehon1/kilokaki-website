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
# From `MAX_PATHS=` down to the last line before the purge call — which means
# the block includes the CAP. It did not until 2026-07-22: the extraction
# stopped at the counts line, so every assertion below ran on an uncapped
# derivation and the cap shipped with no harness at all.
BLOCK="$(sed -n '/^MAX_PATHS=/,/^purge_rc=/p' "$DEPLOY_SH" | sed '$d')"

echo "=== extraction ==="
if [[ -z "$BLOCK" ]]; then
  echo "  FAIL  — could not extract the derivation block from deploy.sh."
  echo "          The markers moved. This test is testing NOTHING until fixed."
  exit 1
fi
for needle in 'to_url_path()' 'dedupe_into VERIFY_PATHS' 'dedupe_into CACHE_PATHS' \
              '_deleted+=' 'dropped_purge=' 'dropped_verify=' ; do
  if [[ "$BLOCK" == *"$needle"* ]]; then
    ok "block contains ${needle}"
  else
    bad "block contains ${needle}" "present" "absent — extraction is partial"
  fi
done

DERIVE_ERR="$(mktemp -t kk-derive-err.XXXXXX)"

derive() { # derive <fixture-file>; sets CACHE_PATHS / VERIFY_PATHS, stderr -> $DERIVE_ERR
  XFER_LOG="$1"
  unset CACHE_PATHS VERIFY_PATHS _changed _deleted dropped_purge dropped_verify
  eval "$BLOCK" >/dev/null 2>"$DERIVE_ERR"
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

# --- Fixture 4: the cap fires while the tree has deletions ------------------
# THE ROW THIS FILE WAS EXTENDED FOR.
# CACHE_PATHS is VERIFY_PATHS followed by the delete-only paths. The old cap
# truncated CACHE_PATHS and then re-derived `VERIFY_PATHS=(${CACHE_PATHS[@]})`
# from the result — so whenever the purge set overflowed and the verify set did
# not, the truncated tail of deleted paths was assigned INTO the verify set.
# verify-edge then diffs the edge against a repo file that no longer exists,
# returns UNKNOWN, and reds a deploy whose only sin was deleting files.
#
# Shape: 10 changed (verify = 12 with the floor), 40 deleted (purge = 52).
# 52 > 40, so the cap fires on the purge set; 12 < 40, so the verify set must
# come through it untouched.
FIX4="$(mktemp -t kk-xfer4.XXXXXX)"
{
  echo "sending incremental file list"
  for i in $(seq 1 10); do echo ">f+++++++++ blog/live-${i}/index.html"; done
  for i in $(seq 1 40); do echo "*deleting   blog/gone-${i}/index.html"; done
} > "$FIX4"

echo "=== fixture 4: cap fires on the purge set, tree has deletions ==="
derive "$FIX4"

check "the cap actually fired (purge set truncated to MAX_PATHS)" \
  "40" "${#CACHE_PATHS[@]}"

check "the verify set is UNDER the cap and was left alone" \
  "12" "${#VERIFY_PATHS[@]}"

check "NO deleted path leaked into the verify set" \
  "0" "$(printf '%s\n' ${VERIFY_PATHS[@]+"${VERIFY_PATHS[@]}"} | grep -c '^/blog/gone-')"

check "a live changed path is still verified" \
  "yes" "$(printf '%s\n' ${VERIFY_PATHS[@]+"${VERIFY_PATHS[@]}"} | grep -qx '/blog/live-7/' && echo yes || echo no)"

check "the dropped purge paths are named on stderr" \
  "yes" "$(grep -q 'were NOT purged' "$DERIVE_ERR" && echo yes || echo no)"

# --- Fixture 5: the cap fires on the VERIFY set -----------------------------
# The other half. When the verify set itself overflows, paths ARE dropped from
# verification — that is the cap doing its job. The bug is dropping them
# quietly: the old block's only warning said "were NOT purged" and handed back
# a cache-purge.sh line, so an operator who ran exactly what they were told
# still had unverified paths and no way to know which. "A cap that drops paths
# silently is the same bug as the hand-kept list" — that sentence was true of
# the purge set and false of the verify set, in the same block.
FIX5="$(mktemp -t kk-xfer5.XXXXXX)"
{
  echo "sending incremental file list"
  for i in $(seq 1 50); do echo ">f+++++++++ blog/post-${i}/index.html"; done
} > "$FIX5"

echo "=== fixture 5: cap fires on the verify set ==="
derive "$FIX5"

check "the verify set is truncated to MAX_PATHS" \
  "40" "${#VERIFY_PATHS[@]}"

check "the dropped verify paths are named on stderr" \
  "yes" "$(grep -q 'were NOT verified' "$DERIVE_ERR" && echo yes || echo no)"

check "the operator is told to verify-edge them, not just purge them" \
  "yes" "$(grep -q 'verify-edge.sh /blog/post-' "$DERIVE_ERR" && echo yes || echo no)"

check "a dropped path is named individually, not just counted" \
  "yes" "$(grep -q '^  /blog/post-50/$' "$DERIVE_ERR" && echo yes || echo no)"

rm -f "$FIX1" "$FIX2" "$FIX4" "$FIX5" "$DERIVE_ERR"

echo ""
echo "passed: $pass   failed: $fail"
[[ $fail -eq 0 ]] || exit 1
