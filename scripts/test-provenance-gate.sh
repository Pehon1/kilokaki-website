#!/usr/bin/env bash
# test-provenance-gate.sh — mutation harness for provenance-gate.sh
#
# WHY THIS FILE LOOKS LIKE THIS
# A PREDICTED exit code and a TRANSCRIBED one are byte-identical once written
# down. The rule here is that no row's expected value is authored from intent:
# the table in provenance-gate.sh is copied FROM this suite's output, after it
# ran. Three defences, each earned by a specific past failure:
#
#  1. Rows are THUNKS (function names), invoked one at a time. A row that dies
#     kills its own row, not the suite. A suite that exits non-zero because
#     assertion 1 raised, having never run rows 2..N, looks exactly like a
#     suite that ran everything and found one failure.
#  2. Every row asserts its MUTATION APPLIED before running the gate. A gate
#     run against an unmutated fixture returns 0 and gets recorded under the
#     mutation's name — a pass wearing a red row's costume.
#  3. RAN and TOTAL are both printed. A shrinking FAIL count and a suite dying
#     halfway read alike from the FAIL line alone.
#
# Usage: bash scripts/test-provenance-gate.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
GATE="${SCRIPT_DIR}/provenance-gate.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/provgate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

RAN=0; PASS=0; FAIL=0
declare -a RESULTS=()

# check <row-id> <description> <expected-rc> <thunk> [expected-marker]
# The thunk is a FUNCTION NAME, not a value: nothing is evaluated before check
# decides to run it, so a row that explodes cannot take the suite with it.
#
# The MARKER is not decoration. The first run of this suite (2026-07-22) had
# every mutation row return its expected code while the gate was answering
# UNKNOWN to literally everything — a symlinked $TMPDIR broke the toplevel
# comparison, so rows D–H were right for a reason that had nothing to do with
# what they mutate. Only the control could tell. rc alone cannot distinguish
# "the branch I am testing fired" from "some earlier branch fired first", and
# deploy.sh collapses gate exit 1 and 2 into its own exit 1, so rows that run
# through it can't see the difference at all without this.
check() {
  local id="$1" desc="$2" want="$3" thunk="$4" marker="${5:-}"
  RAN=$((RAN + 1))
  local got=0 out=""
  out=$("$thunk" 2>&1) || got=$?
  if [[ -n "$marker" && "$out" != *"$marker"* ]]; then
    FAIL=$((FAIL + 1))
    RESULTS+=("  $id  ran, rc=$got (want $want)  FAIL  $desc  [WRONG BRANCH: no '$marker']")
    printf '%s\n' "--- $id output ---" "$out" "--- end $id ---" >&2
    return
  fi
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    RESULTS+=("  $id  ran, rc=$got (want $want)  OK    $desc")
  else
    FAIL=$((FAIL + 1))
    RESULTS+=("  $id  ran, rc=$got (want $want)  FAIL  $desc")
    printf '%s\n' "--- $id output ---" "$out" "--- end $id ---" >&2
  fi
}

# fixture <name> -> prints path to a fresh clean clone carrying THIS commit.
#
# origin/main in the fixture is repointed at the tree under test, not at the
# real origin/main. Rows I and J execute the FIXTURE's deploy.sh, so cloning the
# published main would have tested last week's script and reported it as this
# one — the "wrong population" failure, in a suite whose subject is provenance.
# The fixture's HEAD is therefore the commit being graded, and "published" is
# simulated by pointing the remote ref at it.
SRC_SHA="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." rev-parse HEAD)"
fixture() {
  local d="${WORK}/$1"
  mkdir -p "$d"
  git clone --quiet --no-checkout "$REPO" "${d}/site" >/dev/null 2>&1 || return 90
  git -C "${d}/site" checkout --quiet -B main "$SRC_SHA" >/dev/null 2>&1 || return 91
  git -C "${d}/site" update-ref refs/remotes/origin/main "$SRC_SHA" >/dev/null 2>&1 || return 92
  [[ -f "${d}/site/scripts/provenance-gate.sh" ]] || return 93
  printf '%s\n' "${d}/site"
}

# assert_mutated: a mutation that silently no-ops produces a CLEAN fixture, and
# a clean fixture passes. Every row calls one of these before touching the gate.
must() { "$@" || { echo "MUTATION FAILED: $*" >&2; return 99; }; }

# ---------------------------------------------------------------- rows

# A  control: clean published checkout
row_A() {
  local s; s=$(fixture A) || return $?
  [[ -z "$(git -C "$s" status --porcelain)" ]] || { echo "fixture not clean" >&2; return 99; }
  bash "$GATE" "$s"
}

# B  dirty working tree -> git answers "no", BLOCK
row_B() {
  local s; s=$(fixture B) || return $?
  must bash -c "echo '<!-- uncommitted -->' >> '$s/about.html'"
  [[ -n "$(git -C "$s" status --porcelain)" ]] || { echo "mutation did not dirty tree" >&2; return 99; }
  bash "$GATE" "$s"
}

# C  local commit nobody has -> HEAD not an ancestor of origin/main, BLOCK
row_C() {
  local s; s=$(fixture C) || return $?
  must bash -c "echo '<!-- local only -->' >> '$s/about.html'"
  must git -C "$s" -c user.email=t@t -c user.name=t commit --quiet -am "local-only commit"
  git -C "$s" merge-base --is-ancestor HEAD origin/main 2>/dev/null \
    && { echo "mutation did not unpublish HEAD" >&2; return 99; }
  bash "$GATE" "$s"
}

# D  .git stripped, no enclosing repo -> UNKNOWN
row_D() {
  local s; s=$(fixture D) || return $?
  must rm -rf "$s/.git"
  [[ ! -e "$s/.git" ]] || { echo "mutation did not remove .git" >&2; return 99; }
  bash "$GATE" "$s"
}

# E  .git stripped, but the copy sits INSIDE another repo -> UNKNOWN.
# This is the row `rev-parse --git-dir` alone cannot catch: it walks upward,
# finds the enclosing repo, and every later query then describes a tree that
# does not contain these files. The toplevel==SRC_DIR assertion exists for this.
row_E() {
  local outer="${WORK}/E-outer"
  mkdir -p "$outer"
  must git -C "$outer" init --quiet
  must git -C "$outer" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m outer
  local s; s=$(fixture E) || return $?
  must cp -R "$s" "${outer}/site"
  must rm -rf "${outer}/site/.git"
  git -C "${outer}/site" rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "mutation inert: enclosing repo not reachable from copy" >&2; return 99; }
  bash "$GATE" "${outer}/site"
}

# F  origin/main does not resolve -> UNKNOWN (never "nothing to compare, fine")
row_F() {
  local s; s=$(fixture F) || return $?
  git -C "$s" remote remove origin >/dev/null 2>&1
  git -C "$s" update-ref -d refs/remotes/origin/main >/dev/null 2>&1
  # The assertion is the gate, not the removal: `remote remove` already deletes
  # the tracking refs, so update-ref legitimately fails. Neither command's exit
  # code is read; only whether the ref is actually gone.
  git -C "$s" rev-parse --verify --quiet origin/main >/dev/null 2>&1 \
    && { echo "mutation did not remove origin/main" >&2; return 99; }
  bash "$GATE" "$s"
}

# G  unborn HEAD (init'd, never committed) -> UNKNOWN
row_G() {
  local s="${WORK}/G/site"
  mkdir -p "$s"
  must git -C "$s" init --quiet
  git -C "$s" rev-parse --verify HEAD >/dev/null 2>&1 \
    && { echo "mutation inert: HEAD resolves" >&2; return 99; }
  bash "$GATE" "$s"
}

# H  git off PATH -> UNKNOWN. Asserts git is unreachable AND bash still is:
# a shim that removes both produces exit 127 and the gate never executes, which
# is not a verdict at all. This repo has recorded that mistake once already.
row_H() {
  local s; s=$(fixture H) || return $?
  local shim="${WORK}/H-shim"; mkdir -p "$shim"
  for b in bash sh cd pwd rm mkdir printf echo command; do
    local p; p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "${shim}/${b}" 2>/dev/null
  done
  PATH="$shim" command -v git >/dev/null 2>&1 && { echo "shim inert: git still reachable" >&2; return 99; }
  PATH="$shim" command -v bash >/dev/null 2>&1 || { echo "shim too broad: bash unreachable" >&2; return 99; }
  PATH="$shim" bash "$GATE" "$s"
}

# I  THE PLACEMENT ROW (Coco, 2026-07-22): dirty tree + --dry-run, through
# deploy.sh, must still exit non-zero. --dry-run returns at deploy.sh:203, above
# all three other gates. If a guard about the deploy's own provenance is
# skippable by that flag, the defect has just been rebuilt one layer up.
# Runs with a deliberately absent env file: nothing here should reach secrets.
row_I() {
  local s; s=$(fixture I) || return $?
  must bash -c "echo '<!-- uncommitted -->' >> '$s/index.html'"
  [[ -n "$(git -C "$s" status --porcelain)" ]] || { echo "mutation did not dirty tree" >&2; return 99; }
  KILOKAKI_DEPLOY_ENV="${WORK}/no-such-env" bash "${s}/scripts/deploy.sh" --dry-run
}

# J  placement control: clean tree + --dry-run must get PAST the provenance gate
# and die at the missing env file instead. Proves row I's non-zero came from the
# gate and not from the absent env — two different exits at the same rc.
# Asserted on the RECEIPT, not the code.
row_J() {
  local s; s=$(fixture J) || return $?
  local out=""
  out=$(KILOKAKI_DEPLOY_ENV="${WORK}/no-such-env" bash "${s}/scripts/deploy.sh" --dry-run 2>&1)
  [[ "$out" == *"Provenance gate: clean checkout, HEAD published"* ]] \
    || { echo "no provenance receipt in output" >&2; printf '%s\n' "$out" >&2; return 98; }
  [[ "$out" == *"deploy env not found"* ]] \
    || { echo "did not reach the secrets check" >&2; printf '%s\n' "$out" >&2; return 97; }
  return 0
}

# ---------------------------------------------------------------- run

echo "provenance-gate.sh mutation suite"
echo "repo: $REPO"
echo ""

check A "clean published checkout (control)"            0 row_A "clean checkout, HEAD published"
check B "working tree dirty"                            1 row_B "working tree is dirty"
check C "HEAD not an ancestor of origin/main"           1 row_C "is not an ancestor of"
check D ".git stripped, no enclosing repo"              2 row_D "is not inside a git worktree"
check E ".git stripped, copy inside ANOTHER repo"       2 row_E "is not the root of a checkout"
check F "origin/main does not resolve"                  2 row_F "does not resolve in"
check G "unborn HEAD (no commit)"                       2 row_G "HEAD does not resolve"
check H "git off PATH (bash kept reachable)"            2 row_H "git is not on PATH"
check I "dirty tree + --dry-run via deploy.sh"          1 row_I "working tree is dirty"
check J "clean tree + --dry-run reaches secrets check"  0 row_J

echo ""
printf '%s\n' "${RESULTS[@]}"
echo ""
echo "RAN ${RAN}/10   PASS ${PASS}   FAIL ${FAIL}"
[[ $FAIL -eq 0 && $RAN -eq 10 ]] || exit 1
exit 0
