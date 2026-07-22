#!/usr/bin/env bash
# content-gate.sh — pre-deploy gate: does this working tree hold every piece of
# shippable content that origin/main holds?
#
# WHY THIS EXISTS
# deploy.sh ships a WORKING TREE. It does not ship HEAD, and it does not ship a
# branch. So the only honest pre-deploy question is about file CONTENT:
#
#     "of the files about to ship, does origin hold a version carrying work
#      that this tree does not have?"
#
# The rule this replaces was `git log origin/main..HEAD` — a COMMIT COUNT, kept
# as prose in an agent's memory file. On 2026-07-22 the branch diverged: Blog #65
# existed on both sides under different hashes (d2d936f origin / 84f45d3 local).
# The commit-list rule still listed #65 as "riding" when origin already had that
# content. It did not fail loudly; it went VERBOSE — and an over-reporting guard
# reads as a conservative one, so nothing about its output invites re-reading.
#
# Counting commits is the wrong instrument the moment a branch diverges. Two
# hashes can carry one change, and one hash can carry none of the files that ship.
# This gate reads content.
#
# It also exists as a FILE because the old rule only ever ran when a human or an
# agent remembered to run it. A note calibrates you after the fact; only an
# executable stops you.
#
# EXIT CODES
#   0  pass — a receipt was printed. Only this counts as a pass.
#   1  BLOCK — origin holds shippable content this tree does not.
#   2  UNKNOWN — the gate could not run (no git, no remote, fetch failed).
#      Not a pass. An unfetched ref answers a question about yesterday.
#
# Usage: bash scripts/content-gate.sh [<src_dir>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
REMOTE_REF="${KILOKAKI_GATE_REF:-origin/main}"
REMOTE_NAME="${REMOTE_REF%%/*}"
REMOTE_BRANCH="${REMOTE_REF#*/}"

# Paths this repo actually publishes. Deliberately mirrors deploy.sh's
# RSYNC_FILTER: a gate that measures a different file set than the deploy ships
# is measuring someone else's deploy. If that list changes, change this one.
is_shippable() {
  case "$1" in
    blog/*.html|blog/*.png|blog/*.jpg|blog/*.jpeg|blog/*.webp|blog/*.svg|blog/*.css|blog/*.js) return 0 ;;
    how-to/*.html|how-to/*.png|how-to/*.jpg|how-to/*.css|how-to/*.js) return 0 ;;
    mini/*.html|mini/*.png|mini/*.css|mini/*.js) return 0 ;;
    index.html|about.html|pricing.html|how-to-log-food.html|how-to-track-meals.html) return 0 ;;
    robots.txt|sitemap.xml|logo.png|og-blog-default.png|photo-log.png) return 0 ;;
    *.css|*.js|*.svg|*.ico|*.webp|*.jpg|*.jpeg|*.woff|*.woff2|*.ttf)
      # Root-level web assets only — deploy.sh's allow-list is not recursive here.
      [[ "$1" != */* ]] && return 0 || return 1 ;;
    *) return 1 ;;
  esac
}

echo "→ Content gate: comparing shippable files in the working tree against ${REMOTE_REF}..."

cd "$SRC_DIR" || { echo "UNKNOWN: cannot enter $SRC_DIR" >&2; exit 2; }

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "UNKNOWN: $SRC_DIR is not a git checkout — nothing to compare against." >&2
  echo "This gate cannot answer. That is not a pass." >&2
  exit 2
fi

if ! git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
  echo "UNKNOWN: no remote named '${REMOTE_NAME}'." >&2
  exit 2
fi

# Fetch is mandatory. A remote-tracking ref is only as fresh as the last fetch,
# and a stale ref reports "in sync" for the same reason a dead probe reports
# "no drift": it has nothing to say and says nothing. Both look like green.
if ! git fetch --quiet "$REMOTE_NAME" "$REMOTE_BRANCH" 2>/dev/null; then
  echo "UNKNOWN: could not fetch ${REMOTE_REF}." >&2
  echo "Refusing to compare against a ref that may predate today's pushes." >&2
  exit 2
fi

if ! git rev-parse --verify --quiet "$REMOTE_REF" >/dev/null; then
  echo "UNKNOWN: ${REMOTE_REF} does not resolve after a successful fetch." >&2
  exit 2
fi

# THE MEASUREMENT.
# `git diff --name-only <ref>` compares the ref against the WORKING TREE, which
# is what rsync uploads — uncommitted edits included. Not HEAD. Not a commit range.
divergent=()
while IFS= read -r f; do
  [[ -n "$f" ]] && is_shippable "$f" && divergent+=("$f")
done < <(git diff --name-only "$REMOTE_REF" -- . || true)

# The blocking half, in two steps — and the second step is the whole point.
#
# `HEAD...REMOTE` diffs the merge-base against the remote, so it names every file
# origin has TOUCHED since the fork. That is a history question, and history
# over-reports: when the same change lands on both sides under different hashes
# (Blog #65, 2026-07-22 — d2d936f origin / 84f45d3 local), origin "touched" the
# file and my tree already holds those exact bytes. There is nothing to lose.
#
# The first draft of this gate blocked on that list alone and produced a false
# BLOCK on precisely the case it was written for. A gate whose thesis is "read
# content, not commits" cannot decide with the commit graph. So the history list
# is only a CANDIDATE SET; the verdict comes from comparing bytes.
candidates=()
while IFS= read -r f; do
  [[ -n "$f" ]] && is_shippable "$f" && candidates+=("$f")
done < <(git diff --name-only "HEAD...${REMOTE_REF}" -- . || true)

# Now the content test: of the files origin touched, which ones does origin
# actually hold a DIFFERENT body for than what this deploy would upload?
# `divergent` is already worktree-vs-origin. Anything in both lists is origin-only
# work whose bytes are genuinely absent here. Anything in candidates but not in
# divergent is a duplicate landing — identical bytes, two hashes, nothing at risk.
doomed=()
for f in ${candidates+"${candidates[@]}"}; do
  for d in ${divergent+"${divergent[@]}"}; do
    if [[ "$f" == "$d" ]]; then doomed+=("$f"); break; fi
  done
done

# Third measurement: files that exist on origin but NOT in this working tree.
# These never show up in the two lists above when the deletion is local-only —
# from the commit graph that reads as "local is ahead," which the checks above
# treat as healthy. But deploy.sh runs `rsync --delete`, so an absent file is not
# a no-op: it REMOVES that page from production. The pass receipt was also
# calling these "WILL ship", which is false twice over — it does not exist, and
# what happens to it is a delete, not an upload.
removed=()
while IFS= read -r f; do
  [[ -n "$f" ]] && is_shippable "$f" && [[ ! -e "$f" ]] && removed+=("$f")
done < <(git ls-tree -r --name-only "$REMOTE_REF" || true)

# A file that is absent locally is not "differing content" — drop it from the
# ship list so the receipt describes uploads only.
shipping=()
for d in ${divergent+"${divergent[@]}"}; do
  [[ -e "$d" ]] && shipping+=("$d")
done

if [[ ${#removed[@]} -gt 0 ]]; then
  echo "" >&2
  echo "BLOCK: ${REMOTE_REF} holds shippable files this working tree does not have." >&2
  echo "deploy.sh runs rsync --delete, so these would be REMOVED from production:" >&2
  echo "" >&2
  printf '    %s\n' "${removed[@]}" >&2
  echo "" >&2
  echo "  ${#removed[@]} live page(s) would be deleted." >&2
  echo "  If the removal is intentional, commit and push the deletion first —" >&2
  echo "  then origin no longer holds them and this gate passes." >&2
  echo "  Nothing was deployed." >&2
  exit 1
fi

if [[ ${#doomed[@]} -gt 0 ]]; then
  echo "" >&2
  echo "BLOCK: ${REMOTE_REF} holds shippable content this working tree does not." >&2
  echo "Deploying now would publish an older body over newer work:" >&2
  echo "" >&2
  printf '    %s\n' "${doomed[@]}" >&2
  echo "" >&2
  echo "  ${#doomed[@]} shippable file(s) are behind ${REMOTE_REF}." >&2
  echo "  Reconcile first (rebase or pull), then re-run this gate." >&2
  echo "  Nothing was deployed." >&2
  exit 1
fi

# Pass receipt. It names the files, so "clean" is falsifiable and silence is not
# mistakable for it. A gate that prints nothing on success is indistinguishable
# from a gate that never ran.
if [[ ${#shipping[@]} -eq 0 ]]; then
  echo "✓ Content gate: working tree matches ${REMOTE_REF} on every shippable file."
  echo "  Nothing new would ship. If you expected a change, it is not in this tree."
else
  echo "✓ Content gate: nothing on ${REMOTE_REF} is missing here, nothing gets deleted."
  echo "  ${#shipping[@]} shippable file(s) differ from ${REMOTE_REF} and WILL ship:"
  printf '      %s\n' "${shipping[@]}"
fi
exit 0
