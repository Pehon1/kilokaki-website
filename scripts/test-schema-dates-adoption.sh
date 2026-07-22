#!/usr/bin/env bash
# test-schema-dates-adoption.sh — mutation harness for the TZ-bucket deletion.
#
# WHAT THIS PROVES, and the order matters:
#
#   1. THE SHIP GATE (rows B1/B2/B3). The verdict on an adopted post must be
#      IDENTICAL whether its adopting commit ran at 00:03 SGT or 11:08 SGT.
#      That is the entire fix. Rows B1/B2 assert byte-identical output across the
#      two hours; row B3 runs the SAME two fixtures against the PRE-FIX checker
#      (cbaa8a8) and asserts the verdicts DIFFER there. Without B3, B1/B2 are a
#      pair of green runs that would also be green against a script that never
#      looked at anything — an invariant nobody has seen violated is
#      indistinguishable from a constant.
#
#   2. The new buckets can go RED (C, D, E, F). A checker that is green on the
#      whole corpus — which this one now is, 0 bugs over 78 — has to be shown
#      failing on demand or it is wallpaper.
#
#   3. Absence is LOUD (E, F, H). blog/adopted.json missing or unparseable must
#      never degrade into "no adoptions to spare". That is the exact shape that
#      has scored green on this project before.
#
# Rows F and H share exit code 1 and 2 respectively with ordinary outcomes, so
# the MARKER is the entire signal there. Anyone dropping the marker checks to
# "simplify" this file deletes the instrument and leaves the alarm behind.
#
# Every fixture is a REAL git repo built with controlled commit dates, because
# the defect being tested lives in the interaction between a commit timestamp
# and a timezone. A fixture that fakes the git layer cannot exercise it.
#
# Emits RAN/PASS/FAIL and aborts if RAN != PASS+FAIL. A suite that dies halfway
# and a suite with a shrinking FAIL count read alike from the summary line.
#
# ---------------------------------------------------------------------------
# PROVEN RED — transcribed from real runs in a `git worktree add --detach` at
# 5fa6bbe, 2026-07-22 15:1x SGT. NOT predicted. Every row below was produced by
# mutating scripts/check-schema-dates.py, running this suite unpiped, and
# copying what it printed. Control before each: RAN 15 PASS 15 FAIL 0, rc 0.
#
#   M1  restore the TZ bucket (drop the declaration branch, re-add the
#       `published == commit-in-UTC` exoneration) — i.e. the pre-fix behaviour
#                     -> RAN 15  PASS 10  FAIL 5   rc 1
#                        FAIL: 0, B1, B2, C, E
#       B2 is the one that matters: "verdicts DIFFER across the adoption hour".
#       The ship gate goes red on the exact defect it was written for.
#
#   M2  drop ONLY the declaration branch; no TZ test
#                     -> RAN 15  PASS 11  FAIL 4   rc 1
#                        FAIL: 0, A, B1, C
#       🔴 READ THIS ONE. B2 stays GREEN. Invariance across the adoption hour is
#       necessary but NOT sufficient — with nothing hour-dependent left in the
#       script, the two verdicts agree by being equally wrong. A and B1 are what
#       carry "adopted posts are judged by declaration AT ALL". Anyone trimming
#       this suite to "just the ship gate" deletes the rows that catch M2 and
#       keeps the row that does not.
#
#   M3  load_adopted() returns {} instead of None when the file is absent
#                     -> RAN 15  PASS 13  FAIL 2   rc 1
#                        FAIL: E, H
#       The absence-is-UNKNOWN rows. H is the dangerous half: the writer stops
#       failing closed and would run unguarded over a corpus it cannot classify.
#
#   M4  ORPHAN bucket no longer appended
#                     -> RAN 15  PASS 14  FAIL 1   rc 1
#                        FAIL: D
#
# RAN stayed 15 under every mutation, so each FAIL count above is a verdict and
# not a suite that died early.
# ---------------------------------------------------------------------------

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
REPO="$PWD"

PREFIX_REF="cbaa8a8"     # last commit before the TZ bucket was deleted
INTERVAL_V1_REF="a069755" # interval arm v1: scored floor-pinned posts as clean
WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT

DECLARED=28
RAN=0; PASSED=0; FAILED=0

# check <name> <want_rc> <want_marker> <thunk...>
# The thunk is DEFERRED, never a value. A raise inside a value argument kills the
# suite at assertion 1, and the resulting nonzero exit reads exactly like a
# caught failure. Proven on this project 2026-07-22: "ZERO FAIL, exit 1".
check() {
  local name="$1" want_rc="$2" want_marker="$3"; shift 3
  RAN=$((RAN + 1))
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [[ "$rc" == "$want_rc" ]] && grep -qF -- "$want_marker" <<<"$out"; then
    PASSED=$((PASSED + 1)); printf '  PASS  %-52s rc=%s\n' "$name" "$rc"
  else
    FAILED=$((FAILED + 1))
    printf '  FAIL  %-52s rc=%s (want %s) marker=%q\n' "$name" "$rc" "$want_rc" "$want_marker"
    printf '        got: %s\n' "$(head -c 400 <<<"$out" | tr '\n' ' ')"
  fi
}

# check_differ <name> <fileA> <fileB>  — asserts two captured outputs DIFFER.
check_differ() {
  local name="$1" a="$2" b="$3"
  RAN=$((RAN + 1))
  if ! diff -q "$a" "$b" >/dev/null 2>&1; then
    PASSED=$((PASSED + 1)); printf '  PASS  %-52s (outputs differ, as required)\n' "$name"
  else
    FAILED=$((FAILED + 1))
    printf '  FAIL  %-52s outputs are IDENTICAL — the pre-fix defect did not reproduce,\n' "$name"
    printf '        so the ship gate above is proving nothing.\n'
  fi
}

# check_same <name> <fileA> <fileB>  — asserts two captured outputs are IDENTICAL.
check_same() {
  local name="$1" a="$2" b="$3"
  RAN=$((RAN + 1))
  if diff -q "$a" "$b" >/dev/null 2>&1; then
    PASSED=$((PASSED + 1)); printf '  PASS  %-52s (byte-identical verdict)\n' "$name"
  else
    FAILED=$((FAILED + 1))
    printf '  FAIL  %-52s verdicts DIFFER across the adoption hour:\n' "$name"
    diff "$a" "$b" | head -20 | sed 's/^/        /'
  fi
}

# ---------------------------------------------------------------------------
# Fixture builder.
#
# build_fixture <dir> <adoption_commit_date> <checker_source_ref_or_LIVE>
#
#   blog/normal-post.html   committed 2026-07-10, datePublished 2026-07-10.
#                           The control post: judged against git in every arm,
#                           and it must stay green in all of them. If a mutation
#                           ever turns THIS red, the mutation is hitting the
#                           wrong thing.
#   blog/adopted-post.html  datePublished 2026-07-16, but first committed by the
#                           adoption commit whose date is the argument. This is
#                           the post the whole fix is about.
#   blog/adopted.json       declares adopted-post as published 2026-07-16.
#
# Both posts are padded past STUB_BYTES (2000) so population() counts them as
# real posts rather than redirect stubs.
# ---------------------------------------------------------------------------
build_fixture() {
  local dir="$1" adopt_date="$2" src="$3"
  mkdir -p "$dir/blog" "$dir/scripts"

  python3 - "$dir" <<'PY'
import os, sys
d = sys.argv[1]

# THE TWO POSTS MUST NOT RESEMBLE EACH OTHER. first_commit() runs
# `git log --diff-filter=A --follow`, and --follow does rename/copy detection:
# with two near-identical files it pairs the second one back to the FIRST post's
# commit and returns 2026-07-10 for both. Measured, not guessed — the first
# version of this fixture used one template for both posts and rows B3/B4/E2
# went red because every adoption resolved to the wrong commit regardless of its
# hour. Distinct bodies are load-bearing; do not "tidy" them into one template.
def post(path, published, filler):
    body = "<p>" + (filler + " ") * 40 + "</p>\n"
    html = f"""<!doctype html>
<html lang="en-SG"><head>
<title>Fixture Post {os.path.basename(path)} | KiloKaki</title>
<meta name="description" content="fixture {os.path.basename(path)}">
<link rel="canonical" href="https://kilokaki.com/blog/{os.path.basename(path)}">
<script type="application/ld+json">
{{
  "@context": "https://schema.org",
  "@type": "BlogPosting",
  "headline": "Fixture Post {os.path.basename(path)}",
  "datePublished": "{published}",
  "dateModified": "{published}"
}}
</script>
</head><body>
{body}</body></html>
"""
    open(os.path.join(d, path), "w", encoding="utf-8").write(html)
    assert os.path.getsize(os.path.join(d, path)) >= 2000, "fixture post is under STUB_BYTES"

post("blog/normal-post.html",  "2026-07-10",
     "Ordinary post authored in git; kopi tea kaya toast half boiled egg breakfast set.")
post("blog/adopted-post.html", "2026-07-16",
     "Adopted from production; hawker centre economy rice cai fan portion sizing guide.")
PY

  cat > "$dir/blog/adopted.json" <<'JSON'
{
  "_README": ["fixture"],
  "adopted": {
    "blog/adopted-post.html": {
      "datePublished": "2026-07-16",
      "adopting_commit": "fixture",
      "evidence": {"first_serve_utc": "2026-07-16T15:48:26+00:00", "third_party": true}
    }
  }
}
JSON

  # Evidence for the interval arm. Committed dates above are 2026-07-10 02:00Z
  # (normal-post) and 16:03Z/03:08Z (adopted-post, per $MIDNIGHT/$MIDDAY), so:
  #
  #   normal-post   first serve AFTER its commit  -> invariant holds, silent
  #   adopted-post  first serve BEFORE its commit -> an adoption, and adopted.json
  #                 declares it, so the arm CORROBORATES rather than flags
  #
  # 15:48:26Z is before BOTH candidate adoption instants on purpose. If it were
  # only before one, the ship gate (B2) would go red for a fixture reason rather
  # than a script reason, and a fixture that moves with the hour cannot prove a
  # verdict does not.
  mkdir -p "$dir/evidence"
  cat > "$dir/evidence/first-200-utc.json" <<'JSON'
{
  "_what": "fixture: first 200 per URL",
  "_not": "not a publish date",
  "_retention_floor_utc": "2026-07-01T00:00:00Z",
  "pages": {
    "/blog/normal-post.html":  {"live_by": "2026-07-10", "first_200_utc": "2026-07-10T05:00:00Z"},
    "/blog/adopted-post.html": {"live_by": "2026-07-16", "first_200_utc": "2026-07-16T15:48:26Z"}
  }
}
JSON

  if [[ "$src" == "LIVE" ]]; then
    cp "$REPO/scripts/check-schema-dates.py" "$REPO/scripts/fix-schema-dates.py" "$dir/scripts/"
  else
    git -C "$REPO" show "$src:scripts/check-schema-dates.py" > "$dir/scripts/check-schema-dates.py"
    git -C "$REPO" show "$src:scripts/fix-schema-dates.py"   > "$dir/scripts/fix-schema-dates.py"
  fi

  (
    cd "$dir" || exit 2
    git init -q .
    git config user.email fixture@kilokaki.test
    git config user.name  Fixture
    git add blog/normal-post.html
    GIT_AUTHOR_DATE="2026-07-10 10:00:00 +0800" GIT_COMMITTER_DATE="2026-07-10 10:00:00 +0800" \
      git commit -q -m "post: normal-post"
    git add blog/adopted-post.html blog/adopted.json
    GIT_AUTHOR_DATE="$adopt_date" GIT_COMMITTER_DATE="$adopt_date" \
      git commit -q -m "adopt: adopted-post from production"
  ) || return 2
}

run_checker() { ( cd "$1" && python3 scripts/check-schema-dates.py ); }
run_fixer()   { local d="$1"; shift; ( cd "$d" && python3 scripts/fix-schema-dates.py "$@" ); }

MIDNIGHT="2026-07-17 00:03:24 +0800"   # UTC date 2026-07-16 — the hour that walked
MIDDAY="2026-07-17 11:08:36 +0800"     # UTC date 2026-07-17 — the hour that got flagged

echo "=== baseline: the real corpus ==="
# 🔴 CLOSED 2026-07-22. These two rows were pinned to a KNOWN OPEN FINDING —
# blog/how-to-log-durian.html, an undeclared adoption served 1414s before its own
# commit, invisible to the date arm because both instants fall on 2026-07-16.
# The declaration landed, so they are restored to the exact assertion the pin
# said to restore. The marker was NOT widened to make both states pass.
#
# The coverage those rows used to provide did not survive the fix on its own — a
# green row proves the finding is gone, never that the instrument that found it
# still works. Rows N1/N2 below re-establish it from the other side: they take
# durian back out of the real blog/adopted.json and require it to come back.
# (Those rows exist as of 2026-07-22. This comment named them before they were
# written — the sentence you are reading was the coverage. See §N.)
check "0a: real repo, unmutated -> 0 bugs, exit 0" 0 "0 real bugs over 78 judged posts" \
  python3 "$REPO/scripts/check-schema-dates.py"
check "0b: ...and the date arm still accounts for all 78" 0 "78  accounted for / 78 real posts" \
  python3 "$REPO/scripts/check-schema-dates.py"
check "0c: durian is now CORROBORATED, not merely silent" 0 \
  "5  declared adoptions CORROBORATED by a pre-commit serve" \
  python3 "$REPO/scripts/check-schema-dates.py"

echo
echo "=== N: remove the durian declaration and require the finding to come BACK ==="
# These are the rows the 0a/0b comment above promises. Until 2026-07-22 that
# comment cited "rows N1/N2 below" and there were no such rows — the claim of
# coverage was the whole coverage. Written now, not deleted, because the gap it
# described is real: 0a/0b go green the moment the finding is fixed, and would
# stay green against a checker rewritten to score every adopted post clean.
#
# The mutation is on the REAL blog/adopted.json, so restoration is registered in
# the EXIT trap BEFORE the file is touched. A restore line at the end of this
# block would leave the repo mutated for any run that dies between the two.
ADOPTED_REAL="$REPO/blog/adopted.json"
cp "$ADOPTED_REAL" "$WORK/adopted.json.orig" || exit 2
trap 'cp -f "$WORK/adopted.json.orig" "$ADOPTED_REAL" 2>/dev/null; rm -rf "$WORK"' EXIT

# Mutate, then PROVE the mutation applied. A mutation that silently no-ops
# produces a green row that reads exactly like a caught regression — on this
# project M4's first attempt did not apply and was re-run rather than counted.
# Asserted structurally against the `adopted` map, never by grepping the whole
# file: "durian" also appears in _README prose, so a file-wide grep would match
# the mutated file and the check could not go red.
python3 - "$ADOPTED_REAL" <<'PY' || exit 2
import json, sys
p = sys.argv[1]
d = json.load(open(p))
key = "blog/how-to-log-durian.html"
if key not in d["adopted"]:
    sys.exit("ABORT: durian not declared at baseline; row N is testing nothing.")
del d["adopted"][key]
json.dump(d, open(p, "w"), indent=2)
d2 = json.load(open(p))
if key in d2["adopted"]:
    sys.exit("ABORT: durian still declared after mutation; N did not apply.")
PY

check "N1: undeclared durian is re-reported as a real bug" 1 \
  "UNDECLARED ADOPTION - served before its own commit, absent from blog/adopted.json  (1)" \
  python3 "$REPO/scripts/check-schema-dates.py"

# Second operand, different bucket. If the checker stopped emitting the
# UNDECLARED line entirely, N1 would go red for the right reason but so would a
# checker that merely renamed the marker. The corroborated count is computed by
# a different branch and must fall 5 -> 4 on the same mutation.
check "N2: ...and the corroborated count falls 5 -> 4" 1 \
  "4  declared adoptions CORROBORATED by a pre-commit serve" \
  python3 "$REPO/scripts/check-schema-dates.py"

# N3 — the SECOND OPERAND's own red arm. Until 2026-07-22 cross_check() had no
# row in this suite at all: SILENT_ADOPTION was emitted by check-schema-dates.py
# and asserted by nothing. It was the only bucket whose red arm had never been
# demonstrated, which is the same shape as the N1/N2 gap one level up — the
# operand that exists to catch a wrong verdict, itself unchecked.
#
# Deliberately the SAME mutation as N1/N2 and a DIFFERENT function: N1 is the
# interval arm (interval_arm), N3 is the commit-message operand (cross_check).
# One mutation that two independent code paths must both notice is worth more
# than two mutations each seen by one path. Note the wording differs from N1 on
# purpose — "UNDECLARED ADOPTION" is the interval arm's word for served-before-
# commit; "SILENT ADOPTION" is this operand's word for declared-by-a-commit-
# message-but-absent-from-the-file. cross_check() gives each mismatch its own
# word precisely so the two can never be collapsed, so the suite must assert
# them separately or that design decision is untested.
check "N3: ...and the commit-message operand fires SILENT_ADOPTION" 1 \
  "SILENT ADOPTION - declared by a commit message, absent from blog/adopted.json  (1)" \
  python3 "$REPO/scripts/check-schema-dates.py"

cp -f "$WORK/adopted.json.orig" "$ADOPTED_REAL" || exit 2

echo
echo "=== A: the fixture itself is green — positive control ==="
# If A is not green, every red row below is red for the wrong reason and the
# suite is measuring a broken fixture rather than the script.
build_fixture "$WORK/a" "$MIDNIGHT" LIVE || exit 2
check "A: fixture, adoption 00:03 -> 0 bugs, exit 0" 0 "0 real bugs over 2 judged posts" \
  run_checker "$WORK/a"

echo
echo "=== B: THE SHIP GATE — the verdict must not move with the adoption hour ==="
build_fixture "$WORK/b_mid"  "$MIDDAY" LIVE || exit 2
run_checker "$WORK/a"     > "$WORK/out.fix.midnight" 2>&1
run_checker "$WORK/b_mid" > "$WORK/out.fix.midday"   2>&1

check "B1: adoption 11:08 -> 0 bugs, exit 0" 0 "0 real bugs over 2 judged posts" \
  run_checker "$WORK/b_mid"
check_same "B2: 00:03 vs 11:08 verdict identical (SHIP GATE)" \
  "$WORK/out.fix.midnight" "$WORK/out.fix.midday"

# B3 is the row that makes B1/B2 mean anything. Same two fixtures, pre-fix
# checker. If these do NOT differ, the defect never reproduced here and the
# invariance above is vacuous.
build_fixture "$WORK/pre_mn"  "$MIDNIGHT" "$PREFIX_REF" || exit 2
build_fixture "$WORK/pre_mid" "$MIDDAY"   "$PREFIX_REF" || exit 2
run_checker "$WORK/pre_mn"  > "$WORK/out.pre.midnight" 2>&1
run_checker "$WORK/pre_mid" > "$WORK/out.pre.midday"   2>&1
check_differ "B3: PRE-FIX ($PREFIX_REF) verdict DOES move with the hour" \
  "$WORK/out.pre.midnight" "$WORK/out.pre.midday"
check "B4: PRE-FIX @00:03 exonerates it as a TZ artifact" 0 "TZ artifacts (ignored)" \
  run_checker "$WORK/pre_mn"
check "B5: PRE-FIX @11:08 reports the same post as drift" 1 "MINOR DRIFT" \
  run_checker "$WORK/pre_mid"

echo
echo "=== C/D/E/F: the new buckets must be able to go red ==="

# C — an adopted post whose HTML disagrees with its declaration.
build_fixture "$WORK/c" "$MIDNIGHT" LIVE || exit 2
python3 - "$WORK/c/blog/adopted-post.html" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read().replace('"datePublished": "2026-07-16"',
                                             '"datePublished": "2026-07-20"')
open(p, "w", encoding="utf-8").write(s)
PY
check "C: adopted post drifts from declaration -> exit 1" 1 "ADOPTED POST DISAGREES WITH ITS DECLARATION  (1)" \
  run_checker "$WORK/c"

# D — a declaration naming a post that is not in the population. Shares exit 1
# with a date bug but is the OPPOSITE diagnosis, so it gets its own bucket.
build_fixture "$WORK/d" "$MIDNIGHT" LIVE || exit 2
python3 - "$WORK/d/blog/adopted.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["adopted"]["blog/ghost-post.html"] = {"datePublished": "2026-01-01", "adopting_commit": "none"}
json.dump(d, open(p, "w"), indent=2)
PY
check "D: declaration for an absent post -> ORPHAN, exit 1" 1 "DECLARED-BUT-ABSENT" \
  run_checker "$WORK/d"

# E — adopted.json absent. The adopted post falls back to git and MUST be
# flagged. This is the row that proves absence is loud: under the pre-fix
# checker this identical state exited 0.
build_fixture "$WORK/e" "$MIDNIGHT" LIVE || exit 2
rm "$WORK/e/blog/adopted.json"
check "E: adopted.json ABSENT -> says ABSENT and flags, exit 1" 1 "ABSENT — 0 declarations" \
  run_checker "$WORK/e"
build_fixture "$WORK/e_pre" "$MIDNIGHT" "$PREFIX_REF" || exit 2
rm "$WORK/e_pre/blog/adopted.json"
check "E2: PRE-FIX on the same state exits 0 — the silent pass" 0 "0 real bugs" \
  run_checker "$WORK/e_pre"

# F — adopted.json present but unparseable. Must NOT degrade to "no adoptions".
# Shares exit 1 with "bugs found", so the marker is the whole signal here.
build_fixture "$WORK/f" "$MIDNIGHT" LIVE || exit 2
printf '{ "adopted": { ' > "$WORK/f/blog/adopted.json"
check "F: adopted.json UNPARSEABLE -> raises, never 'nothing to spare'" 1 "JSONDecodeError" \
  run_checker "$WORK/f"

echo
echo "=== G/H: the writer must refuse the adopted set, and fail closed ==="

# G — fix-schema-dates.py --apply must REFUSE the adopted post and leave its
# bytes alone, even when the post's date disagrees with git.
build_fixture "$WORK/g" "$MIDDAY" LIVE || exit 2
before=$(shasum -a 256 < "$WORK/g/blog/adopted-post.html")
check "G: --apply REFUSES the adopted post" 0 "REFUSED   adopted-post.html" \
  run_fixer "$WORK/g" --apply
after=$(shasum -a 256 < "$WORK/g/blog/adopted-post.html")
RAN=$((RAN + 1))
if [[ "$before" == "$after" ]]; then
  PASSED=$((PASSED + 1)); printf '  PASS  %-52s (bytes unchanged after --apply)\n' "G2: adopted post not rewritten"
else
  FAILED=$((FAILED + 1)); printf '  FAIL  %-52s adopted post WAS REWRITTEN by --apply\n' "G2: adopted post not rewritten"
fi

# H — writer fails closed when it cannot classify the corpus.
build_fixture "$WORK/h" "$MIDNIGHT" LIVE || exit 2
rm "$WORK/h/blog/adopted.json"
check "H: --apply with adopted.json ABSENT -> refuses, exit 2" 2 "REFUSING TO RUN" \
  run_fixer "$WORK/h" --apply

echo
echo "=== I/J/K/L/M: the interval arm ==="

# I — THE ROW THE DATE ARM CANNOT EMIT. Adoption commit at 22:55:39 +0800, so its
# LOCAL date is 2026-07-16 and the post's schema says 2026-07-16: equal, so the
# date arm hits `continue` and the post vanishes from every one of its buckets.
# adopted.json is present and declares NOTHING ({} — a real state, distinct from
# absent). Evidence puts the first 200 at 14:32:05Z, 1414s before the commit.
# This is blog/how-to-log-durian.html reproduced in a controlled tree.
#
# I1 and I2 are one run asserted twice on purpose. I1 alone would pass against a
# checker that flagged the post for the WRONG reason (drift, orphan, anything);
# I2 pins that the date arm stayed silent, which is what makes the arm load-
# bearing rather than redundant.
DURIAN_HOUR="2026-07-16 22:55:39 +0800"
build_fixture "$WORK/i" "$DURIAN_HOUR" LIVE || exit 2
cat > "$WORK/i/blog/adopted.json" <<'JSON'
{ "_README": ["fixture: present, declares nothing"], "adopted": {} }
JSON
python3 - "$WORK/i/evidence/first-200-utc.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["pages"]["/blog/adopted-post.html"]["first_200_utc"] = "2026-07-16T14:32:05Z"
json.dump(d, open(p, "w"), indent=2)
PY
check "I1: undeclared adoption, same local date -> flagged, exit 1" 1 \
  "UNDECLARED ADOPTION - served before its own commit, absent from blog/adopted.json  (1)" \
  run_checker "$WORK/i"
check "I2: ...and the date arm saw NOTHING (0 drift) in that run" 1 \
  "MINOR DRIFT <=3d - authored-vs-committed slippage  (0)" \
  run_checker "$WORK/i"

# J — evidence absent. Must REFUSE (exit 2), never report "0 undeclared
# adoptions". Same shape as row E one layer down: an arm that cannot run and
# prints a zero is indistinguishable from a clean corpus.
build_fixture "$WORK/j" "$MIDNIGHT" LIVE || exit 2
rm "$WORK/j/evidence/first-200-utc.json"
check "J: evidence ABSENT -> INSTRUMENT REFUSES, exit 2" 2 "INSTRUMENT REFUSES" \
  run_checker "$WORK/j"

# K — THE WRONG-ARTIFACT TRAP, as a test. ~/.../evidence/adoption-logs/live-by.json
# and ~/.../state/live-by/first-serve-by-page.json are both live, both real, both
# answer "when did this go live", and only the second has first_200_utc. Fed the
# wrong one, a loose loader gets a valid dict with zero matching keys and reports
# the corpus clean. The guard is schema identity — `bounds` is not `pages` — so it
# refuses instead. (Called THE HYPHEN TRAP until 8d00738, after a phantom filename
# `live_by.json` that never existed; the trap is real, the hyphen was not. The
# assertion below never depended on either name — which is the point of testing
# schema rather than convention.)
build_fixture "$WORK/k" "$MIDNIGHT" LIVE || exit 2
cat > "$WORK/k/evidence/first-200-utc.json" <<'JSON'
{ "_what": "the OTHER artifact", "bounds": { "how-to-log-a-buffet": "2026-07-16" } }
JSON
check "K: wrong artifact (bounds, not pages) -> REFUSES, exit 2" 2 "has no \`pages\` map" \
  run_checker "$WORK/k"

# L — DARKNESS IS LOUD BUT DOES NOT GATE. Floor raised above normal-post's commit
# and its row removed: the arm has zero pre-commit coverage for that post and says
# so by name. Exit stays 0 — logs rotate on a 30-day cycle and an arm that turns
# permanently red on expiry is an arm that gets deleted. The failure this guards
# is the opposite one: skipping quietly and reporting green.
build_fixture "$WORK/l" "$MIDNIGHT" LIVE || exit 2
python3 - "$WORK/l/evidence/first-200-utc.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["_retention_floor_utc"] = "2026-07-16T00:00:00Z"
del d["pages"]["/blog/normal-post.html"]
json.dump(d, open(p, "w"), indent=2)
PY
check "L: floor above commit -> DARK by name, exit 0 (never a permanent red)" 0 \
  "interval arm dark for 1 post(s)" \
  run_checker "$WORK/l"

# M — THE UNTESTABLE PASS. Row L's twin, and the difference is one line: L
# DELETES the serve row, M KEEPS it. That single change used to flip the post
# from "DARK, named, unjudgeable" to "invariant holds" — a silent promotion into
# the clean bucket, because the code only asked "is first >= commit?" and never
# "could first have been less?". Below the retention floor it could not: the log
# starts at the floor, so first >= floor > commit is forced by arithmetic. The
# invariant did not hold, it was never tested.
#
# Measured on the real corpus at the fix: 65 of 73 "invariant holds" were this.
# The arm's own headline was 89% a claim about posts its evidence cannot reach —
# the same defect it was built to catch (a rule that cannot go red reporting
# green), one level up, in the detector.
M_FLOOR="2026-07-16T00:00:00Z"
build_fixture "$WORK/m" "$MIDNIGHT" LIVE || exit 2
python3 - "$WORK/m/evidence/first-200-utc.json" "$M_FLOOR" <<'PY'
import json, sys
p, floor = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["_retention_floor_utc"] = floor
# The row STAYS — that is the whole distinction from row L.
assert "/blog/normal-post.html" in d["pages"], "fixture lost the row M depends on"
json.dump(d, open(p, "w"), indent=2)
PY
check "M1: floor above commit, row PRESENT -> UNDECIDABLE, not clean" 0 \
  "1  UNDECIDABLE - has a serve row" \
  run_checker "$WORK/m"

# M2 is what makes M1 mean anything. Identical fixture, the checker as it stood
# at a069755. If this does NOT report the post as holding the invariant, the
# defect never reproduced and M1 is asserting a bucket that was never wrong.
build_fixture "$WORK/m_pre" "$MIDNIGHT" "$INTERVAL_V1_REF" || exit 2
python3 - "$WORK/m_pre/evidence/first-200-utc.json" "$M_FLOOR" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["_retention_floor_utc"] = sys.argv[2]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
check "M2: PRE-FIX ($INTERVAL_V1_REF) scores the same post as clean" 0 \
  "1  first serve at or after first commit — invariant holds" \
  run_checker "$WORK/m_pre"

# M3 — the denominator must move with the bucket. Splitting UNDECIDABLE out and
# leaving the summary line quoting the old total would report the honest count
# in one place and the flattering one in the place people read.
check "M3: ...and the judged count excludes it" 0 \
  "interval arm judged 1 post(s); 1 outside its reach" \
  run_checker "$WORK/m"

echo
echo "--- RAN $RAN / declared $DECLARED · PASS $PASSED · FAIL $FAILED ---"
if [[ "$RAN" != "$((PASSED + FAILED))" ]]; then
  echo ">>> ABORT: RAN != PASS+FAIL. The suite did not finish; this is not a verdict."
  exit 2
fi
if [[ "$RAN" != "$DECLARED" ]]; then
  echo ">>> ABORT: RAN $RAN but $DECLARED rows are declared. A suite that dies"
  echo "    halfway and one that passes have the same summary line without this."
  exit 2
fi
[[ "$FAILED" == 0 ]] && { echo ">>> ALL GREEN"; exit 0; } || { echo ">>> $FAILED FAILED"; exit 1; }
