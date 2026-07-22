#!/usr/bin/env bash
# release-gate.sh — may this tree be shipped AT ALL?
#
# Wired THIRD in deploy.sh (:324) -- after provenance-gate.sh and SELF_VERIFY,
# before sitemap-gate. This is a deliberate deviation from the spec's "wire it
# first", flagged to Coco rather than taken silently, and the reason the two
# above it stay above it is that neither needs credentials, network or env, so
# neither can be the thing that spends.
#
# The header of this file used to say "Runs FIRST of the gates in deploy.sh",
# which was false when written. The property that actually matters is measured,
# not positional: NOTHING IS SPENT before the verdict lands. Nothing executed
# above deploy.sh:324 reaches the network -- the sshpass line there is an
# assignment and the rsync is inside a function called 60 lines later. Rows O
# and P of test-release-gate.sh pin that; "logically prior" would not have.
#
# It is still the cheapest question and the prior one: every other gate asks
# whether the tree is coherent and current, and all of that work is wasted if
# shipping is not permitted.
#
# THIS IS NOT AN AUTHORIZATION SYSTEM. Say it plainly because a green here will
# be quoted later: any agent can create and push a `release/*` tag, exactly as
# any agent could edit a tracked file. This gate proves that an explicit,
# published act occurred naming this exact commit. It does NOT prove who
# performed it, that they were entitled to, or that anyone reviewed anything.
# A pass is evidence of intent, not of approval. Do not cite a green from this
# script as "<person> approved this ship" — it cannot support that claim.
#
# WHY THIS EXISTS. On 2026-07-23 the shared checkout sat at e93ce0e, clean, 19
# commits ahead of live cbaa8a8, during a deploy freeze — and all four existing
# gates were green, because a tree 19 commits ahead of production is a perfectly
# COHERENT and perfectly CURRENT tree. That is exactly the tree a freeze exists
# to stop. The freeze lived in agent chat messages and in nobody's code; same
# defect class as `gen-sitemap.py --check`, written "for CI/cron" and then
# having no caller of any kind for its whole life.
#
# WHY A TAG AND NOT A TRACKED FILE. The obvious design — commit RELEASED_SHA
# with the authorized sha in it — self-references: writing sha X and committing
# it moves HEAD to Y, so the gate never matches. The fix everyone then adds is
# "…or HEAD^ if the only delta is the authorization file", and that escape hatch
# is a hole shaped precisely like the thing being gated. Tags do not perturb
# HEAD or the tree, so the problem does not arise. Requiring the tag on ORIGIN
# rather than locally makes authorization a published artifact instead of a
# single-disk claim.
#
# ANNOTATED ONLY, and the strictness is deliberate. A lightweight tag carries no
# tagger, no date and no message, so it records that a name points somewhere and
# nothing about the act. This gate rejects lightweight `release/*` tags with a
# message saying why, rather than accepting them and logging an empty
# authorization.
#
# EXITS
#   0  a release/* tag on origin peels to HEAD
#   1  resolved successfully, no matching tag. NOT AUTHORIZED.
#   2  UNKNOWN — could not reach a verdict (no network, ls-remote non-zero,
#      unresolvable HEAD, unparseable output). deploy.sh aborts on 1 AND 2:
#      "could not check" is not "may ship".
#
# READ-ONLY. This script writes nothing — no fetch, no local tag, no ref update.
# A gate that mutates the repo it is judging can change the answer it is about
# to give. One consequence, accepted deliberately: the tag's annotation message
# can only be printed when the tag object happens to be present locally. When it
# is not, the gate still passes and says the message is unavailable rather than
# fetching it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
REMOTE="${RELEASE_GATE_REMOTE:-origin}"
PATTERN='refs/tags/release/*'

echo "→ Release gate: is this commit authorized to ship?"

# --- resolve the tree's own commit ------------------------------------------
if ! git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "UNKNOWN: $SRC_DIR is not a git checkout — cannot identify what would ship." >&2
  exit 2
fi

HEAD_SHA=$(git -C "$SRC_DIR" rev-parse --verify HEAD 2>/dev/null)
if [[ -z "$HEAD_SHA" || ! "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "UNKNOWN: could not resolve HEAD to a commit in $SRC_DIR." >&2
  exit 2
fi

# A detached HEAD is NOT treated as unknown, and this is a deliberate deviation
# from the spec's "detached/unresolvable HEAD -> 2". A checkout detached exactly
# at a release tag is the most natural shape a deploy checkout takes; failing it
# closed would teach people to route around the gate, which costs more than it
# buys. Unresolvable HEAD is still 2, above. Flagged to Coco rather than
# silently deviated.

# --- query origin ------------------------------------------------------------
LS_OUT=$(git -C "$SRC_DIR" ls-remote --tags "$REMOTE" "$PATTERN" 2>&1)
LS_RC=$?
if (( LS_RC != 0 )); then
  echo "UNKNOWN: git ls-remote --tags $REMOTE failed (exit $LS_RC)." >&2
  echo "  Cannot distinguish 'not authorized' from 'cannot see the remote'," >&2
  echo "  and those must not collapse into the same verdict. Refusing." >&2
  echo "--- ls-remote output ---" >&2
  printf '%s\n' "$LS_OUT" >&2
  exit 2
fi

if [[ -n "$LS_OUT" ]] && ! grep -qE '^[0-9a-f]{40}[[:space:]]+refs/tags/' <<<"$LS_OUT"; then
  echo "UNKNOWN: ls-remote returned output in an unrecognised shape. Refusing to parse." >&2
  printf '%s\n' "$LS_OUT" | sed 's/^/  /' >&2
  exit 2
fi

# --- find a tag that PEELS to HEAD -------------------------------------------
# An annotated tag yields two lines: the tag object at refs/tags/X, and the
# commit it points at, at refs/tags/X^{}. Comparing HEAD against the tag-object
# sha never matches, which would make this gate a permanent freeze that everyone
# learns to bypass. Match only on the peeled line.
MATCH_REF=""
while IFS=$'\t' read -r sha ref; do
  [[ -n "$sha" && -n "$ref" ]] || continue
  [[ "$ref" == *'^{}' ]] || continue          # peeled lines only => annotated only
  if [[ "$sha" == "$HEAD_SHA" ]]; then
    MATCH_REF="${ref%'^{}'}"
    break
  fi
done <<<"$LS_OUT"

if [[ -z "$MATCH_REF" ]]; then
  echo "" >&2
  echo "NOT AUTHORIZED: no annotated release/* tag on '$REMOTE' points at this commit." >&2
  echo "  HEAD: $HEAD_SHA" >&2
  if [[ -z "$LS_OUT" ]]; then
    echo "  No release/* tags exist on '$REMOTE' at all." >&2
  else
    echo "  release/* tags on '$REMOTE' (peeled where annotated):" >&2
    printf '%s\n' "$LS_OUT" | sed 's/^/    /' >&2
    # Name the lightweight case explicitly; otherwise it looks like the gate is
    # broken rather than like the tag is the wrong kind.
    if ! grep -q '\^{}' <<<"$LS_OUT"; then
      echo "  NOTE: none of these are annotated tags. Lightweight tags are" >&2
      echo "  rejected on purpose — they record no tagger, date or message," >&2
      echo "  so they cannot evidence the act they are supposed to evidence." >&2
      echo "  Create one with: git tag -a release/<name> -m '<why>' && git push $REMOTE release/<name>" >&2
    fi
  fi
  exit 1
fi

# --- pass: record WHICH authorization fired ----------------------------------
echo "✓ Release gate: authorized by $MATCH_REF"
echo "    commit: $HEAD_SHA"
TAG_NAME="${MATCH_REF#refs/tags/}"
if git -C "$SRC_DIR" rev-parse -q --verify "refs/tags/${TAG_NAME}" >/dev/null 2>&1; then
  MSG=$(git -C "$SRC_DIR" tag -l --format='%(contents)' "$TAG_NAME" 2>/dev/null | sed '/^$/d' | head -5)
  TAGGER=$(git -C "$SRC_DIR" tag -l --format='%(taggername) %(taggeremail) %(taggerdate:iso)' "$TAG_NAME" 2>/dev/null)
  [[ -n "$TAGGER" ]] && echo "    tagged: $TAGGER"
  [[ -n "$MSG" ]] && printf '    message: %s\n' "$MSG" | sed '2,$s/^/             /'
else
  echo "    (annotation unavailable locally — this gate does not fetch; run"
  echo "     'git fetch --tags $REMOTE' to read the message)"
fi
echo "    NOTE: this proves an explicit published act named this commit."
echo "    It does not prove who performed it or that anyone reviewed it."
exit 0
