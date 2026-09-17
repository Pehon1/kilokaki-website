#!/usr/bin/env bash
# absorption-ledger-gate.sh — the reader for docs/provenance.md.
#
# NAMED TO DISAMBIGUATE from scripts/provenance-gate.sh, which asks a DIFFERENT
# question: "is the tree about to ship a clean, published checkout?". This one
# asks "is every production-originated file in this repo registered in the
# ledger?". Neither subsumes the other; the old name invited exactly the
# conflation that let 2b41803 be read as escalated.
#
# A ledger nothing reads is the `state/pending-sends/` failure: writing it down
# reads as handling it. This is the thing that reads it.
#
# Exit codes:
#   0  PASS  — and a receipt is printed. No receipt, no pass.
#   1  FAIL  — a finding, named, with the row it came from.
#   2  UNKNOWN — could not run the check. NOT a pass. Every gate needs a defined
#      output for "I could not run this", or the run improvises one.
set -uo pipefail

LEDGER="docs/provenance.md"
fail=0

die_unknown() { printf 'UNKNOWN: %s\n' "$1" >&2; exit 2; }

git rev-parse --git-dir >/dev/null 2>&1 || die_unknown "not inside a git repository"
[ -f "$LEDGER" ]                        || die_unknown "$LEDGER not found (cwd=$PWD)"

# Rows are the table lines under "## Rows" ONLY. The file contains a second table
# ("Known publish routes") whose cells also hold backticked paths -- an unanchored
# match reads it as data. Section-scope first, then match.
section=$(awk '/^## Rows/{f=1;next} /^## /{f=0} f' "$LEDGER")
rows=$(printf '%s\n' "$section" | grep -E '^\| `[^`]+\.[a-z]+` \|' || true)
n_rows=$(printf '%s' "$rows" | grep -c . || true)
[ "$n_rows" -gt 0 ] || die_unknown "parsed 0 rows from $LEDGER — the parser or the table changed"

# ---- A. every row is well formed --------------------------------------------
while IFS= read -r row; do
  [ -n "$row" ] || continue
  path=$(printf '%s' "$row" | sed -E 's/^\| `([^`]+)`.*/\1/')
  sha=$(printf '%s' "$row" | grep -oE '`[0-9a-f]{7,40}`' | head -1 | tr -d '`')
  esc=$(printf '%s' "$row" | awk -F'|' '{print $6}')

  if [ -z "$sha" ]; then
    echo "FAIL: row for $path names no absorbing commit"; fail=1; continue
  fi
  if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
    echo "FAIL: row for $path cites $sha, which is not a commit in this repo"; fail=1
  fi
  # Rule 2: a receipt is a channel+message id, or the explicit admission there is none.
  if ! printf '%s' "$esc" | grep -qE '(UNESCALATED|[0-9]{17,20})'; then
    echo "FAIL: row for $path has no escalation receipt and does not say UNESCALATED"; fail=1
  fi
done <<< "$rows"

# ---- B. the audit's memory: no unregistered absorption -----------------------
# Shape-match the commit message, not one author's vocabulary.
absorb_re='from production|from prod|track unattributed|restore: .*production'
scanned=$(git log --all --format=%H | wc -l | tr -d ' ')
# -E is load-bearing: --grep defaults to BASIC regex, where the alternation above is
# a literal. Without it this scan matches nothing and reports a clean zero.
# PATH SCOPE is load-bearing, not tidiness. An absorption necessarily ADDS a
# published web artifact. A commit that merely *discusses* absorption -- like the
# one that introduced this ledger -- matches the message shape and adds no page.
# Without the scope, the detector counts its own documentation. (Caught red by
# this script on 2026-09-17, one commit after it was written.)
PUBLISHED=(':(glob)blog/**/*.html' ':(glob)*.html' 'sitemap.xml')
matched=$(git log --all --format=%H -E --regexp-ignore-case --grep="$absorb_re" --diff-filter=A -- "${PUBLISHED[@]}" | wc -l | tr -d ' ')
[ "$matched" -gt 0 ] || die_unknown "absorption pattern matched 0 of $scanned commits -- the pattern or the regex mode is broken, and an empty scan is not a pass"
unreg=0
while IFS='|' read -r sha subj; do
  [ -n "$sha" ] || continue
  short=${sha:0:7}
  if ! grep -qF "$short" "$LEDGER"; then
    echo "FAIL: $short absorbs production content and is NOT in $LEDGER"
    echo "        $subj"
    unreg=$((unreg+1)); fail=1
  fi
done < <(git log --all --format='%H|%s' -E --regexp-ignore-case --grep="$absorb_re" --diff-filter=A -- "${PUBLISHED[@]}")

# ---- receipt ----------------------------------------------------------------
echo "---"
echo "ledger        : $LEDGER"
echo "rows checked  : $n_rows"
echo "commits scanned: $scanned  | matched absorption shape: $matched"
echo "unregistered absorptions: $unreg"
if [ "$fail" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
fi
echo "RESULT: FAIL"
exit 1
