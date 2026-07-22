#!/usr/bin/env bash
# test-check-cited-paths.sh — the suite check-cited-paths.sh's header promised.
#
# WHY THIS EXISTS. `check-cited-paths.sh` shipped with a header sentence reading
# "The suite's red arm (a224c71) is what keeps this honest across future edits."
# There was no suite. A forward reference to a missing artifact, in the header of
# the instrument built to catch docs that cite things which do not exist — the
# same defect one level up. Coco blocked the merge on it, correctly.
#
# WHAT A ROW MUST DO. Every row asserts an exact exit code, and every row was
# proven to FAIL by mutating the checker until it went the other way. A row that
# has never been observed red is decoration; see rows E/F for why that is not a
# rhetorical worry here.
#
# HERMETIC ON PURPOSE. Rows A-F build their own fixtures under a temp dir and
# cite paths this script creates. They do NOT cite `~/.openclaw-nori/...`.
# `check-cited-paths.sh` resolves paths against the machine it runs on, so a
# suite that cited another agent's workspace would go red when THAT agent
# reorganised — a red with no defect in this repo and nobody able to act on it.
# Row G is the deliberate exception and is asserted narrowly; see there.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${SCRIPT_DIR}/check-cited-paths.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE="${REPO_ROOT}/fixtures/a224c71-README.md"

[[ -x "$CHECKER" ]] || { echo "ABORT: checker not executable: $CHECKER" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0

# run <label> <expected_rc> <file> [grep_assertion]
run() {
  local label="$1" want="$2" file="$3" needle="${4:-}"
  local out rc
  out=$("$CHECKER" "$file" 2>&1); rc=$?
  if [[ "$rc" != "$want" ]]; then
    printf 'FAIL  %-58s rc=%s want=%s\n' "$label" "$rc" "$want"
    printf '%s\n' "$out" | sed 's/^/        /'
    FAIL=$((FAIL + 1)); return
  fi
  if [[ -n "$needle" ]] && ! grep -q -- "$needle" <<<"$out"; then
    printf 'FAIL  %-58s rc ok but output lacks: %s\n' "$label" "$needle"
    printf '%s\n' "$out" | sed 's/^/        /'
    FAIL=$((FAIL + 1)); return
  fi
  printf 'ok    %-58s rc=%s\n' "$label" "$rc"
  PASS=$((PASS + 1))
}

# ---------------------------------------------------------------------------
# Rows A/B — the resolve/does-not-resolve pair. One variable: the file's
# existence. The doc bytes are identical across both.
# ---------------------------------------------------------------------------
REAL="${TMP}/cited-artifact.json"
echo '{}' > "$REAL"
cat > "${TMP}/ab.md" <<EOF
# Evidence

    source: ${REAL}
EOF
# The checker only reads ~/-rooted tokens, so express the temp path that way.
HOME_REL="${TMP#"$HOME"/}"
if [[ "$HOME_REL" != "$TMP" ]]; then
  cat > "${TMP}/ab.md" <<EOF
# Evidence

    source: ~/${HOME_REL}/cited-artifact.json
EOF
else
  # mktemp landed outside \$HOME; put the fixture under \$HOME instead so the
  # ~/-rooted requirement is satisfiable. Refusing beats silently skipping.
  ALT="$(mktemp -d "${HOME}/.ccp-test-XXXXXX")"
  trap 'rm -rf "$TMP" "$ALT"' EXIT
  REAL="${ALT}/cited-artifact.json"; echo '{}' > "$REAL"
  cat > "${TMP}/ab.md" <<EOF
# Evidence

    source: ~/${ALT#"$HOME"/}/cited-artifact.json
EOF
fi

run "A  green: cited path resolves" 0 "${TMP}/ab.md" "all 1 cited path"
rm -f "$REAL"
run "B  red: same doc, cited path deleted" 1 "${TMP}/ab.md" "does not resolve"

# ---------------------------------------------------------------------------
# Rows C/D — refusal. Zero citations is NOT a pass, and neither is an unreadable
# file. Both must exit 2, distinct from both 0 and 1.
# ---------------------------------------------------------------------------
printf '# nothing\n\nprose mentioning `~/some/path` only.\n' > "${TMP}/none.md"
run "C  refuse: zero citations extracted" 2 "${TMP}/none.md" "INSTRUMENT REFUSES"
run "D  refuse: file does not exist" 2 "${TMP}/absent.md" "no such file"

# ---------------------------------------------------------------------------
# Rows E/F — CONDITION 2 IN ISOLATION, and this pair is the reason the suite
# exists in this shape.
#
# The original proof used `evidence/README.md`, where every backticked `~/` path
# sits in UNINDENTED prose. Condition 1 (indent >= 4) excludes those lines by
# itself, so the observed green held whether or not the backtick strip existed —
# a vacuous row that credited condition 2 for work condition 1 had already done.
# Coco caught it. These two rows differ ONLY in the backticks: same indent, same
# path, same surrounding text. Delete the `sed 's/`[^`]*`//g'` line from the
# checker and row E goes red — nothing else in this suite would notice.
#
# BOTH DOCS CARRY A REAL RESOLVING CITATION as well, and that is load-bearing.
# First draft of row E used a doc whose ONLY `~/` token was the backticked one;
# it exited 2, not 0, because stripping the backticks leaves zero citations and
# zero is a refusal. Correct checker behaviour, wrong expected value — the row
# would have "passed" as a refusal and proved nothing about the strip. Keeping
# CITED > 0 is what makes E a green rather than a refusal, and therefore what
# makes the E/F difference attributable to condition 2.
# ---------------------------------------------------------------------------
DEAD='~/.openclaw-nori/workspace/state/live-by/live_by.json'
LIVE="~/${REAL#"$HOME"/}"
echo '{}' > "$REAL"
printf '# Corrections\n\n    source: %s\n    note: `%s` is dead, do not cite it\n' "$LIVE" "$DEAD" > "${TMP}/mention.md"
printf '# Corrections\n\n    source: %s\n    note: %s is dead, do not cite it\n'   "$LIVE" "$DEAD" > "${TMP}/citation.md"
run "E  green: indented BACKTICKED dead path is a mention" 0 "${TMP}/mention.md" "all 1 cited path"
run "F  red:   indented BARE dead path is a citation" 1 "${TMP}/citation.md" "does not resolve"

# ---------------------------------------------------------------------------
# Row H — CONDITION 1 IN ISOLATION. Added after the mutation matrix showed that
# deleting the indent gate outright turned NO row red: rows A-G all survived a
# checker that treats every line of prose as a citation block. Condition 2 had a
# dedicated pair and condition 1 had nothing, which is the same vacuity Coco
# caught in the original proof, one condition over. Found by mutating, not by
# reading — a suite is only as good as the mutations it has actually been run
# against.
#
# The dead path here is UNINDENTED and BARE. Backticks are deliberately absent
# so condition 2 cannot be what excludes it; if this row goes red, only the
# indent gate can have been the thing that stopped counting it.
# ---------------------------------------------------------------------------
printf '# Notes\n\n    source: %s\n\nprose citing %s inline, which is a mention.\n' \
  "$LIVE" "$DEAD" > "${TMP}/prose.md"
run "H  green: UNINDENTED bare dead path is prose" 0 "${TMP}/prose.md" "all 1 cited path"

# ---------------------------------------------------------------------------
# Row G — the historical red arm the header promised, read from a COMMITTED
# FIXTURE rather than by sha.
#
# `98476e79` (the a224c71 revert) is a loose object with 0 refs and
# gc.pruneExpire unset: prune-eligible ~2026-08-05. A suite that read it by sha
# would pass today and die silently in two weeks, and the failure would look
# like a mystery rather than a missing file. Committed, non-reproduction is a
# fixture problem with an obvious owner.
#
# ASSERTED NARROWLY, on purpose. The fixture cites six paths, four of which live
# in ~/.openclaw-nori/ and resolve or not depending on whose machine this runs
# on. So this row asserts only what is invariant everywhere: rc=1, and the
# phantom `live_by.json` named among the failures. It does NOT assert "2 of 6" —
# that count is a fact about one disk, and pinning it would make this row go red
# on a clean checkout for a reason that is not a defect.
# ---------------------------------------------------------------------------
if [[ -f "$FIXTURE" ]]; then
  run "G  red: a224c71 fixture, phantom path caught" 1 "$FIXTURE" "live_by.json"
else
  printf 'FAIL  %-58s fixture missing: %s\n' "G  red: a224c71 fixture" "$FIXTURE"
  FAIL=$((FAIL + 1))
fi

echo
if (( FAIL > 0 )); then
  echo "test-check-cited-paths: ${FAIL} FAILED, ${PASS} passed"
  exit 1
fi
echo "test-check-cited-paths: all ${PASS} rows passed"
exit 0
