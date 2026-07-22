#!/usr/bin/env bash
# provenance-gate.sh — pre-deploy gate: is the tree about to ship a clean,
# published checkout, and is the script running the gates part of it?
#
# WHY THIS EXISTS
# deploy.sh contains zero git invocations. `grep -n 'git ' scripts/deploy.sh`
# returns one comment and nothing else. SRC_DIR is derived as SCRIPT_DIR/..,
# so the deploy ships whatever tree the script happens to be sitting in, and
# until this file existed nothing anywhere asked whether that tree was a
# checkout of anything at all. A copy in /tmp with .git stripped is, to every
# other gate, just a directory of HTML.
#
# The three existing gates each ask about a DIFFERENT COPY of the site:
#   sitemap-gate.sh  "does sitemap.xml match the pages in this tree?"
#   content-gate.sh  "does ORIGIN hold shippable work this tree is missing?"
#   drift_guard      "does PRODUCTION hold files this repo would delete?"
# None of them asks the prior question: WHAT IS THIS TREE. This one does, and
# it needs no network to answer, so nothing forces it below the other gates.
#
# WHERE IT RUNS, AND WHY THAT IS THE WHOLE POINT
# It is anchored in deploy.sh directly after argument parsing — ABOVE the
# `if $DRY_RUN; ... exit 0` early return, which sits above all three other
# gates and skips every one of them. A guard whose thesis is "the script
# running the gates is committed" cannot itself be skippable by the one flag
# that already skips the gates. That is the defect one layer up, and it is the
# shape this repo keeps shipping.
#
# EXIT CODES  (deliberately the same alphabet as sitemap-gate.sh / content-gate.sh)
#   0  pass — clean, published checkout. A receipt was printed. Only this is a pass.
#   1  BLOCK — git answered, and the answer was no: dirty tree, or HEAD is not
#      an ancestor of the remote ref. Real, attributable, fixable.
#   2  UNKNOWN — the gate could not reach a verdict: not a worktree, no HEAD,
#      no remote ref, git errored. NOT a pass.
#
# THE 1-vs-2 DISTINCTION IS THE LOAD-BEARING PART
# Every git query below is read for THREE outcomes, never two. `git merge-base
# --is-ancestor` returns 0 for yes, 1 for no, and something else for "I could
# not evaluate that" — and the third case is the one that has cost this repo
# before. content-gate.sh:95 and :112 both end in `|| true`, which collapses
# exactly that third case into an empty result the loop then reads as "nothing
# divergent". An errored query is not a zero result. Nothing here uses `|| true`.
#
# STALENESS FAILS TOWARD BLOCK, DELIBERATELY
# The ancestry check reads the local remote-tracking ref and does NOT fetch, so
# this gate stays network-free. A stale origin/main makes the check STRICTER,
# not looser: an older ref is less likely to contain HEAD, so staleness produces
# a false BLOCK, never a false pass. That is the opposite polarity to
# content-gate.sh's fetch requirement, where a stale ref would have reported
# "in sync" for the same reason a dead probe reports "no drift". Same fact,
# opposite direction, so the two gates want opposite treatments.
#
# LIMITS, STATED IN SOURCE
#  - `status --porcelain` is repo-wide, not scoped to shippable paths. An
#    untracked scratch file in the tree blocks the deploy. That is intended:
#    the question is "is this a clean checkout", not "are the files I happen to
#    upload clean". Narrowing it to the allow-list would let an edit to
#    deploy.sh or to any gate ship unreviewed, which is the case this exists for.
#  - It proves the tree matches a PUBLISHED COMMIT. It does not prove that
#    commit was reviewed, approved, or that anyone wanted it deployed. Ship
#    authorisation is a human, not a gate.
#
# PROVEN RED (2026-07-22). Transcribed from `bash scripts/test-provenance-gate.sh`,
# RAN 10/10 PASS 10 FAIL 0, suite exit 0. Every row also asserts WHICH BRANCH
# fired, not just the code — see below for why that is not belt-and-braces.
#
#   A  clean published checkout (control)          -> 0  PASS + receipt
#   B  working tree dirty                          -> 1  BLOCK
#   C  HEAD not an ancestor of origin/main         -> 1  BLOCK
#   D  .git stripped, no enclosing repo            -> 2  UNKNOWN
#   E  .git stripped, copy inside ANOTHER repo     -> 2  UNKNOWN  <-- the row the
#      toplevel==SRC_DIR assertion exists for. `rev-parse --git-dir` walks upward
#      and answers YES here, about a repo that does not contain these files.
#   F  origin/main does not resolve                -> 2  UNKNOWN
#   G  unborn HEAD (no commit)                     -> 2  UNKNOWN
#   H  git off PATH (bash kept reachable)          -> 2  UNKNOWN
#   I  dirty tree + --dry-run VIA deploy.sh        -> 1  BLOCK   <-- the placement
#      row. --dry-run returns at deploy.sh:230, above all three other gates.
#   J  clean tree + --dry-run reaches secrets check-> 0  (receipt present, then
#      "deploy env not found"). I's non-zero and a missing-env non-zero are the
#      same code; without J, I proves nothing about which one it was.
#
# THE FIRST RUN WAS 6/10, AND THE FOUR FAILURES WERE ALL THE SAME BUG — MINE.
# `cd "$X" && pwd` returns the LOGICAL path; git's --show-toplevel returns the
# PHYSICAL one. macOS $TMPDIR lives under /var, a symlink to /private/var, so
# the toplevel comparison saw two spellings of one directory and this gate said
# UNKNOWN to every input, including a pristine checkout. Rows D–H still returned
# their expected 2. Only the CONTROL could fail — a gate stuck at UNKNOWN is
# indistinguishable from a working one until something is supposed to pass, and
# a suite of nothing but mutation rows would have shipped it green.
# That is why every row now asserts a marker string as well as a code.
#
# Usage: bash scripts/provenance-gate.sh <src_dir> [remote_ref]
set -uo pipefail

SRC_DIR="${1:?usage: provenance-gate.sh <src_dir> [remote_ref]}"
REMOTE_REF="${2:-origin/main}"

echo "→ Provenance gate: is ${SRC_DIR} a clean, published checkout?"

if ! command -v git &>/dev/null; then
  echo "UNKNOWN: git is not on PATH — provenance cannot be established." >&2
  echo "A gate that cannot check is not a gate that passes." >&2
  exit 2
fi

if [[ ! -d "$SRC_DIR" ]]; then
  echo "UNKNOWN: ${SRC_DIR} is not a directory." >&2
  exit 2
fi

# `pwd -P`, not `pwd`. git reports PHYSICAL paths from --show-toplevel; bash's
# `cd` keeps the LOGICAL one it was handed. On macOS, $TMPDIR is /var/folders/...
# and /var is a symlink to /private/var, so the same directory arrives at the
# comparison below under two spellings and the toplevel check fires on a tree
# that is its own root. Caught 2026-07-22 by this suite's CONTROL row, which is
# the only row that could have caught it: every mutation row still returned its
# expected 2, for the wrong reason. A gate that says UNKNOWN to everything is
# indistinguishable from a working one until something is supposed to pass.
SRC_ABS="$(cd -P "$SRC_DIR" 2>/dev/null && pwd -P)" || {
  echo "UNKNOWN: cannot enter ${SRC_DIR}." >&2
  exit 2
}

# --- 1. Is it a worktree AT ALL, and is it THIS tree's worktree? ---
# `rev-parse --git-dir` alone is not enough. It walks UPWARD: a copy dropped
# into /tmp with .git stripped answers yes if any ancestor directory happens to
# be a repo, and then every subsequent query describes a repo that does not
# contain these files. The toplevel must be the tree itself.
toplevel=""
rc=0
toplevel=$(git -C "$SRC_ABS" rev-parse --show-toplevel 2>/dev/null) || rc=$?
if [[ $rc -ne 0 || -z "$toplevel" ]]; then
  echo "UNKNOWN: ${SRC_ABS} is not inside a git worktree (rev-parse rc=${rc})." >&2
  echo "Nothing can say where these files came from. That is not a pass." >&2
  exit 2
fi

toplevel_abs="$(cd -P "$toplevel" 2>/dev/null && pwd -P)" || toplevel_abs="$toplevel"
if [[ "$toplevel_abs" != "$SRC_ABS" ]]; then
  echo "UNKNOWN: ${SRC_ABS} is not the root of a checkout." >&2
  echo "The enclosing repo is ${toplevel_abs}, which is a DIFFERENT tree than the" >&2
  echo "one about to ship. Its HEAD and its cleanliness say nothing about these files." >&2
  exit 2
fi

# --- 2. Does HEAD resolve? ---
# An empty repo, or a HEAD pointing at an unborn branch, resolves nothing.
head_sha=""
rc=0
head_sha=$(git -C "$SRC_ABS" rev-parse --verify HEAD 2>/dev/null) || rc=$?
if [[ $rc -ne 0 || -z "$head_sha" ]]; then
  echo "UNKNOWN: HEAD does not resolve in ${SRC_ABS} (rc=${rc})." >&2
  echo "A checkout with no commit has no provenance to check." >&2
  exit 2
fi

# --- 3. Is the working tree clean? ---
# Read rc BEFORE reading output. Empty output from a git that failed is
# indistinguishable from empty output from a clean tree, and empty reads as
# pass — which is how a dead probe has scored green here twice before.
rc=0
status_out=$(git -C "$SRC_ABS" status --porcelain 2>/dev/null) || rc=$?
if [[ $rc -ne 0 ]]; then
  echo "UNKNOWN: 'git status --porcelain' exited ${rc}." >&2
  echo "No answer is not a clean answer." >&2
  exit 2
fi
if [[ -n "$status_out" ]]; then
  echo "" >&2
  echo "BLOCK: working tree is dirty — this deploy would ship bytes that are in" >&2
  echo "no commit, and therefore in no review and in no history." >&2
  echo "--- uncommitted ---" >&2
  printf '%s\n' "$status_out" >&2
  echo "" >&2
  echo "Fix: commit and push the change, or stash it. Then re-run." >&2
  exit 1
fi

# --- 4. Is HEAD published? ---
# Read for three outcomes. `--is-ancestor` returns 0 yes, 1 no, and anything
# else means it could not evaluate the question at all.
rc=0
git -C "$SRC_ABS" rev-parse --verify --quiet "$REMOTE_REF" >/dev/null 2>&1 || rc=$?
if [[ $rc -ne 0 ]]; then
  echo "UNKNOWN: ${REMOTE_REF} does not resolve in ${SRC_ABS}." >&2
  echo "There is no published ref to measure this checkout against." >&2
  exit 2
fi

remote_sha=$(git -C "$SRC_ABS" rev-parse "$REMOTE_REF" 2>/dev/null) || remote_sha="?"

rc=0
git -C "$SRC_ABS" merge-base --is-ancestor HEAD "$REMOTE_REF" 2>/dev/null || rc=$?
case "$rc" in
  0) ;;
  1)
    echo "" >&2
    echo "BLOCK: HEAD (${head_sha:0:7}) is not an ancestor of ${REMOTE_REF} (${remote_sha:0:7})." >&2
    echo "This tree holds commits nobody else has. Deploying publishes work that" >&2
    echo "exists in exactly one place: this laptop." >&2
    echo "" >&2
    echo "Note: this gate does NOT fetch, by design. If you pushed a moment ago," >&2
    echo "'git fetch origin' and re-run — a stale ref fails this way on purpose." >&2
    echo "" >&2
    echo "Fix: git push, then re-run." >&2
    exit 1
    ;;
  *)
    echo "UNKNOWN: 'merge-base --is-ancestor' exited ${rc} — it could not evaluate" >&2
    echo "whether HEAD is contained in ${REMOTE_REF}." >&2
    echo "Not yes and not no. That is not a pass." >&2
    exit 2
    ;;
esac

# The receipt. Exit 0 with nothing printed is silence wearing a pass's costume.
echo "✓ Provenance gate: clean checkout, HEAD published."
echo "  tree:   ${SRC_ABS}"
echo "  HEAD:   ${head_sha:0:7}  (ancestor of ${REMOTE_REF} @ ${remote_sha:0:7})"
echo "  status: clean (git status --porcelain empty)"
exit 0
