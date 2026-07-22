#!/usr/bin/env bash
# verify-edge.sh — ask the EDGE what it is serving, and compare it to the bytes
# we reviewed. The only post-deploy check in this repo that deploy.sh does not
# own the answer to.
#
# WHY THIS EXISTS
# deploy.sh's health checks were `curl -sI https://kilokaki.com | head -1` — a
# status line. On 2026-07-22 all three returned 200 while the edge served a
# six-day-old sitemap.xml. They were honest and they were irrelevant: a stale
# object is still a 200. Every other indicator in the deploy reports on an action
# the script itself performed, which makes the whole script structurally
# incapable of observing the one layer that ignores it.
#
# THE DISCRIMINATOR
# Fetch through the edge, diff against the repo file. That answers both halves at
# once: it moved, AND it moved to the artifact that was reviewed. A count check
# (live `grep -c '<loc>'` = 93 vs repo 94) catches the same class and is what
# caught this one; a byte diff is strictly stronger and needs no per-file rule.
#
# `age` is reported but does NOT decide. Nori's tell — age climbing by exactly
# the elapsed wall-clock seconds across a deploy (4206 -> 4255 over ~49s) — proves
# it is the SAME cached object. It is good corroboration and a bad verdict: a
# fresh object also ages, and a low age proves nothing on its own. Content decides.
#
# EXIT CODES
#   0  pass — every checked path matched the repo byte for byte.
#   1  BLOCK — the edge is serving something other than what this tree holds.
#   2  UNKNOWN — could not check (no network, unmapped path, missing repo file).
#      Not a pass. "I could not look" and "I looked and it was fine" are the two
#      states this whole file exists to keep apart.
#
# Usage: bash scripts/verify-edge.sh <url-path> [<url-path> ...]

set -euo pipefail

SITE_HOST="${SITE_HOST:-kilokaki.com}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${VERIFY_SRC_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
BASE_URL="${VERIFY_BASE_URL:-https://${SITE_HOST}}"

if [[ $# -eq 0 ]]; then
  echo "UNKNOWN: no paths given. A verification of zero paths exits 0 and means nothing." >&2
  exit 2
fi

# URL path -> repo file. Directory URLs serve their index.html; everything else
# is the file itself. Anything this cannot map is UNKNOWN, never skipped:
# silently dropping an unmappable path is how a check shrinks to nothing while
# still printing a checkmark.
repo_file_for() {
  local p="$1"
  case "$p" in
    */)  printf '%s' "${SRC_DIR}${p}index.html" ;;
    /*)  printf '%s' "${SRC_DIR}${p}" ;;
    *)   return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Cloudflare edge rewrites — normalize BOTH sides, symmetrically
# ---------------------------------------------------------------------------
# MEASURED 2026-07-22: `/` failed the byte diff by 241 bytes and it was not
# drift. Cloudflare's Email Address Obfuscation rewrites the HTML in flight:
#     repo: <a href="mailto:hello@kilokaki.com">hello@kilokaki.com</a>
#     live: <a href="/cdn-cgi/l/email-protection#3e56..."><span
#           class="__cf_email__" data-cfemail="deb6...">[email&#160;protected]</span></a>
#   + an injected <script src="/cdn-cgi/scripts/.../email-decode.min.js"></script>
#
# So a raw byte diff is structurally red-forever on every page containing a
# mailto:, which would make this check a boy-who-cried-wolf inside a week and
# then get switched off. The two answers were to drop those pages from the check
# (shrinking it to the pages least likely to break) or to normalize. Normalize.
#
# Both sides collapse to the SAME placeholder — the repo's mailto anchor and the
# edge's obfuscated anchor both become <<EMAIL>>. That is deliberate: it means
# this cannot be used to prove an email address is correct, and nothing else is
# touched. Every other byte on the page still has to match.
#
# Set VERIFY_CF_NORMALIZE=false to compare raw. Worth doing when investigating a
# suspected edge rewrite that is NOT one of these two: the normalizer is a
# known-unknowns list, and a new Cloudflare feature would be an unknown-unknown
# that this function would silently absorb only if I widened it carelessly.
CF_NORMALIZE="${VERIFY_CF_NORMALIZE:-true}"

normalize_to() {  # <src-file> <dst-file>
  if [[ "$CF_NORMALIZE" != "true" ]]; then
    cp "$1" "$2"
    return
  fi
  sed -E \
    -e 's|<script data-cfasync="false" src="/cdn-cgi/scripts/[^"]*email-decode\.min\.js"></script>||g' \
    -e 's|<a href="/cdn-cgi/l/email-protection[^"]*">[[:space:]]*<span class="__cf_email__"[^>]*>[^<]*</span></a>|<<EMAIL>>|g' \
    -e 's|<a href="mailto:[^"]*">[^<]*</a>|<<EMAIL>>|g' \
    "$1" > "$2"
}

pass=0
fail=0
unknown=0
declare -a MISMATCH=()
declare -a NORMALIZED=()

for path in "$@"; do
  file=""
  if ! file=$(repo_file_for "$path"); then
    echo "  ? ${path} — cannot map to a repo file" >&2
    unknown=$((unknown + 1))
    continue
  fi

  if [[ ! -f "$file" ]]; then
    echo "  ? ${path} — no repo counterpart at ${file#$SRC_DIR/}" >&2
    unknown=$((unknown + 1))
    continue
  fi

  tmp_body=$(mktemp)
  tmp_hdr=$(mktemp)
  rc=0
  curl -sS --compressed -o "$tmp_body" -D "$tmp_hdr" -w '%{http_code}' \
    "${BASE_URL}${path}" > "${tmp_body}.code" 2>"${tmp_hdr}.err" || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "  ? ${path} — fetch failed (curl exit $rc): $(cat "${tmp_hdr}.err")" >&2
    unknown=$((unknown + 1))
    rm -f "$tmp_body" "$tmp_hdr" "${tmp_body}.code" "${tmp_hdr}.err" "${tmp_body}.n" "${tmp_body}.r"
    continue
  fi

  code=$(cat "${tmp_body}.code")
  # `|| true` is load-bearing, not noise. Under `set -o pipefail` a grep that
  # matches nothing fails the whole pipeline, the assignment fails, and `set -e`
  # kills the loop MID-RUN with exit 1 — which this script's own contract reads
  # as BLOCK. Found by positive-controlling this file against the live site:
  # /sitemap.xml carries an `age` header, /robots.txt does not, so the run
  # verified one path, died on the second, and printed a verdict about four.
  # An absent optional header is not a finding; a check that dies while
  # reporting a failure is the exact shape this repo keeps getting bitten by.
  age=$(grep -i '^age:' "$tmp_hdr" | tail -1 | tr -d '\r' | awk '{print $2}' || true)
  cfs=$(grep -i '^cf-cache-status:' "$tmp_hdr" | tail -1 | tr -d '\r' | awk '{print $2}' || true)
  [[ -n "$age" ]] || age="-"
  [[ -n "$cfs" ]] || cfs="-"

  if [[ "$code" != "200" ]]; then
    echo "  ✗ ${path} — HTTP ${code}" >&2
    MISMATCH+=("${path} (HTTP ${code})")
    fail=$((fail + 1))
    rm -f "$tmp_body" "$tmp_hdr" "${tmp_body}.code" "${tmp_hdr}.err" "${tmp_body}.n" "${tmp_body}.r"
    continue
  fi

  norm_live="${tmp_body}.n"
  norm_repo="${tmp_body}.r"
  normalize_to "$tmp_body" "$norm_live"
  normalize_to "$file" "$norm_repo"

  # Say so, in the output, whenever normalization actually did something. The
  # masked region is a blind spot — swapping only the email address in the repo
  # passes this check (verified 2026-07-22). A blind spot recorded in a comment is
  # one nobody reads at the moment it matters; this puts it on the line that is
  # claiming the pass.
  norm_note=""
  if ! cmp -s "$tmp_body" "$norm_live"; then
    norm_note=" [cf-norm]"
    NORMALIZED+=("$path")
  fi

  if cmp -s "$norm_live" "$norm_repo"; then
    printf '  ✓ %-28s matches repo   (age=%s cf=%s)%s\n' "$path" "$age" "$cfs" "$norm_note"
    pass=$((pass + 1))
  else
    live_bytes=$(wc -c < "$norm_live" | tr -d ' ')
    repo_bytes=$(wc -c < "$norm_repo" | tr -d ' ')
    printf '  ✗ %-28s DIFFERS         (age=%s cf=%s, live %sB vs repo %sB)\n' \
      "$path" "$age" "$cfs" "$live_bytes" "$repo_bytes" >&2
    MISMATCH+=("${path} (live ${live_bytes}B vs repo ${repo_bytes}B, age=${age})")
    fail=$((fail + 1))
  fi

  rm -f "$tmp_body" "$tmp_hdr" "${tmp_body}.code" "${tmp_hdr}.err" "${tmp_body}.n" "${tmp_body}.r"
done

echo ""

# Completion assertion. Everything above is a per-path verdict; this is a verdict
# about the LOOP. If the run dies partway through, the counters below still hold
# real numbers from real paths and read as a finished verification of a shorter
# list. Asking "did I check as many paths as I was given?" is the cheapest way to
# tell a conclusion apart from an interruption wearing one.
checked=$((pass + fail + unknown))
if [[ $checked -ne $# ]]; then
  echo "UNKNOWN: given $# path(s), produced ${checked} verdict(s)." >&2
  echo "The loop did not run to completion. Nothing here is a result." >&2
  exit 2
fi

if [[ $fail -gt 0 ]]; then
  echo "BLOCK: the edge is serving ${fail} path(s) that do not match this tree:" >&2
  printf '    %s\n' "${MISMATCH[@]}" >&2
  echo "" >&2
  echo "Origin-correct is not live-correct. The files are right and the cache is not." >&2
  echo "Re-run: bash scripts/cache-purge.sh ${*}" >&2
  exit 1
fi

if [[ $unknown -gt 0 ]]; then
  echo "UNKNOWN: ${pass} path(s) verified, ${unknown} could not be checked." >&2
  echo "A partial verification is not a verification." >&2
  exit 2
fi

if [[ ${#NORMALIZED[@]} -gt 0 ]]; then
  echo "✓ Edge: ${pass}/${pass} path(s) match this tree (${#NORMALIZED[@]} after cf-normalization)."
  echo "  cf-normalized: ${NORMALIZED[*]}"
  echo "  Blind spot, stated rather than buried: inside a masked email anchor this"
  echo "  check cannot see a change. Everything outside it still had to match."
else
  echo "✓ Edge: ${pass}/${pass} path(s) byte-identical to this tree."
fi
exit 0
