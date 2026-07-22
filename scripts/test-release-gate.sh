#!/usr/bin/env bash
# test-release-gate.sh — the rows that make release-gate.sh's green mean something.
#
# A gate whose pass could not have failed is decoration. Rows B/C/D/E/F must go
# RED; if they do not, row A's green proves nothing. Each row asserts an exact
# exit code and the output is printed on mismatch.
#
# HERMETIC. Every row builds a throwaway repo with a local bare remote under a
# temp dir. Nothing here touches kilokaki-website, its origin, or any real tag.
# `origin` inside the sandbox is a path on disk, so row D can break it by
# pointing it somewhere that does not exist without needing the network to be
# down.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${SCRIPT_DIR}/release-gate.sh"
[[ -x "$GATE" ]] || { echo "ABORT: gate not executable: $GATE" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; ROWS_SKIPPED=0

# A sandbox: work repo + bare "origin", one commit, identity set locally so the
# suite does not depend on the runner having a global git identity.
sandbox() {
  local name="$1" work="${TMP}/${1}" bare="${TMP}/${1}.git"
  rm -rf "$work" "$bare"
  return 9   # injected: sandbox cannot build
  git init -q "$work"
  git -C "$work" config user.email test@kilokaki
  git -C "$work" config user.name Test
  git -C "$work" config commit.gpgsign false
  echo "content-$name" > "$work/file.txt"
  git -C "$work" add -A
  git -C "$work" commit -qm "base commit for $name"
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -q origin HEAD:refs/heads/main
  printf '%s' "$work"
}

# --- ITEM 1: CONSUME THE SUBSHELL'S STATUS -----------------------------------
# `W=$(mk x)` is a COMMAND SUBSTITUTION, i.e. a subshell. When `sandbox`
# aborts -- set -u on an unbound var, git failing, disk full -- the abort is
# CONTAINED: the parent gets W="" plus a non-zero $?, and if nobody reads $?
# the row proceeds against an empty path. `git -C ""` does not error; it means
# THE CURRENT DIRECTORY. That is exactly how a sibling build of this suite
# committed into a real checkout and pushed four release/* tags to a real origin
# while printing "6 of 9 ok".
#
# Measured: `W="$(f rowA)"; rc=$?` -> `W=[]  rc=1`. The status was ALWAYS there.
# It was never read. Detection without consumption -- so this wrapper reads it.
#
# Fail CLOSED with exit 3, not FAIL+1: a harness that cannot build a fixture has
# not found a defect, it has stopped being an instrument. Counting it as a failed
# row would let a broken harness report "15 of 16" -- and a partial pass reads as
# honest coverage in a way a total pass never does. 3 is distinct from 1 (a real
# red) on purpose.
mk() {
  local __w __rc
  __w=$(sandbox "$1"); __rc=$?
  if (( __rc != 0 )); then
    printf 'ABORT %-56s sandbox exited %s -- fixture never built\n' "sandbox/$1" "$__rc" >&2
    exit 3
  fi
  if [[ -z "$__w" || ! -d "$__w" ]]; then
    printf 'ABORT %-56s sandbox returned no usable path [%s]\n' "sandbox/$1" "$__w" >&2
    exit 3
  fi
  printf '%s' "$__w"
}

# run <label> <expected_rc> <dir> [needle]
run() {
  local label="$1" want="$2" dir="$3" needle="${4:-}"
  local out rc
  out=$("$GATE" "$dir" 2>&1); rc=$?
  if [[ "$rc" != "$want" ]]; then
    printf 'FAIL  %-56s rc=%s want=%s\n' "$label" "$rc" "$want"
    printf '%s\n' "$out" | sed 's/^/        /'
    FAIL=$((FAIL + 1)); return
  fi
  if [[ -n "$needle" ]] && ! grep -q -- "$needle" <<<"$out"; then
    printf 'FAIL  %-56s rc ok but output lacks: %s\n' "$label" "$needle"
    printf '%s\n' "$out" | sed 's/^/        /'
    FAIL=$((FAIL + 1)); return
  fi
  printf 'ok    %-56s rc=%s\n' "$label" "$rc"
  PASS=$((PASS + 1))
}

# --- A: annotated release tag on origin, peeling to HEAD ---------------------
W=$(mk a)
git -C "$W" tag -a release/2026-07-23 -m "authorized: row A" HEAD
git -C "$W" push -q origin release/2026-07-23
run "A  annotated release tag on origin peels to HEAD" 0 "$W" "authorized by refs/tags/release/2026-07-23"

# --- B: tag exists on origin but peels to a DIFFERENT commit -----------------
# The freeze case that matters most: an old release is tagged, the tree has
# moved on. Authorized yesterday is not authorized now.
W=$(mk b)
git -C "$W" tag -a release/old -m "authorized: an earlier commit" HEAD
git -C "$W" push -q origin release/old
echo "moved on" >> "$W/file.txt"
git -C "$W" commit -qam "advance past the authorized commit"
git -C "$W" push -q origin HEAD:refs/heads/main
run "B  tag peels to a different commit" 1 "$W" "NOT AUTHORIZED"

# --- C: no release/* tag on origin at all ------------------------------------
W=$(mk c)
run "C  no release/* tag on origin" 1 "$W" "No release/\* tags exist"

# --- D: ls-remote cannot reach the remote ------------------------------------
# UNKNOWN, not "not authorized". Collapsing these two would let a network
# failure read as a policy verdict.
W=$(mk d)
git -C "$W" remote set-url origin "${TMP}/definitely-not-a-repo-$$"
run "D  ls-remote fails -> UNKNOWN, not a verdict" 2 "$W" "UNKNOWN"

# --- E: tag exists LOCALLY only, never pushed --------------------------------
# The single-disk claim. This is the row that makes "published artifact"
# mean something rather than being a slogan.
W=$(mk e)
git -C "$W" tag -a release/local-only -m "never pushed" HEAD
run "E  tag is local-only, not on origin" 1 "$W" "NOT AUTHORIZED"

# --- F: LIGHTWEIGHT tag on origin pointing at HEAD ---------------------------
# Control for requirement 4 (peel the tag). A lightweight tag publishes ONE
# ls-remote line whose sha IS the commit and which carries no `^{}` suffix, no
# tagger, no date and no message. A gate that matched unpeeled lines would go
# green here. It must not: there is nothing to record about the act.
W=$(mk f)
git -C "$W" tag release/lightweight HEAD
git -C "$W" push -q origin release/lightweight
run "F  lightweight tag at HEAD is rejected" 1 "$W" "none of these are annotated"

# --- G: not a git checkout ---------------------------------------------------
# deploy.sh ships a DIRECTORY. A /tmp copy with .git stripped is, to every other
# gate, just a folder of HTML — so this gate must refuse rather than pass.
mkdir -p "${TMP}/plain-dir"
run "G  target is not a git checkout -> UNKNOWN" 2 "${TMP}/plain-dir" "not a git checkout"

# --- H: repo with no commits (HEAD unresolvable) -----------------------------
git init -q "${TMP}/unborn"
run "H  unresolvable HEAD -> UNKNOWN" 2 "${TMP}/unborn" "UNKNOWN"

# --- I: annotated tag not matching the release/* namespace -------------------
# Scope control: the gate must not be satisfied by just any annotated tag.
W=$(mk i)
git -C "$W" tag -a v1.0.0 -m "not a release authorization" HEAD
git -C "$W" push -q origin v1.0.0
run "I  annotated non-release/* tag does not authorize" 1 "$W" "NOT AUTHORIZED"

# =============================================================================
# CALL-SITE ROWS — does deploy.sh actually READ this gate's verdict?
# =============================================================================
# Rows A-I above exercise the gate in ISOLATION. Every one of them stays green
# if you neuter the call site: change `-ne 0` to `-gt 2` in deploy.sh and the
# suite still reports 9/9 while every deploy ships unauthorized. That is the
# defect this whole gate was built for -- `gen-sitemap.py --check` was written
# "for CI/cron" and had no caller of any kind for its whole life -- reappearing
# one layer up, in the tests for the fix.
#
# These rows are STATIC. deploy.sh is never executed, in any form: it is read as
# text, and the mutants are temp COPIES under $TMP. Nothing here can reach
# production, the remote, or the real checkout.
#
# THE HARNESS NEEDS ITS OWN POSITIVE CONTROL. A mutation that silently fails to
# apply reports green for the same reason the defect would: `sed` exiting 0
# having changed nothing is indistinguishable, downstream, from "the check is
# uncoverable". `mutant()` therefore `cmp`s every copy against the original and
# fails loudly if they match. This is not paranoia -- it is what a BSD `sed`
# no-op did to the mutation run that proved rows A-I.

DEPLOY="${SCRIPT_DIR}/deploy.sh"
[[ -r "$DEPLOY" ]] || { echo "ABORT: cannot read $DEPLOY" >&2; exit 2; }

# The guarding predicate, extracted as TEXT so it can be EVALUATED rather than
# spell-checked. A literal grep for `-ne 0` would red-flag `!= 0` and `-gt 0`,
# which are both correct, and that kind of false alarm is how a check gets
# deleted. Evaluating it accepts every correct spelling and rejects every
# incorrect one. First match is necessarily the outer `if`; the `-eq 1` hint
# branch is nested inside it.
call_site_predicate() {
  grep -m1 -E '^[[:space:]]*if \[\[ .*\$release_rc.* \]\]; then' "$1" \
    | sed -E 's/^[[:space:]]*if \[\[ (.*) \]\]; then[[:space:]]*$/\1/'
}

# The body of the guarded block, brace-counted rather than "up to the first fi",
# because the block contains a nested `if`.
call_site_block() {
  awk '
    /^[[:space:]]*if \[\[ .*\$release_rc.* \]\]; then/ && !seen { seen=1; depth=1; next }
    seen && depth > 0 {
      if ($0 ~ /^[[:space:]]*if[[:space:]]/)   depth++
      if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) { depth--; if (depth == 0) next }
      if (depth > 0) print
    }
  ' "$1"
}

# check_call_site <deploy.sh> -> 0 intact, 1 neutered
check_call_site() {
  local f="$1" cond rc
  # 1. the gate is invoked at all, and its exit code is captured
  grep -qE 'release-gate\.sh"[[:space:]]+"\$SRC_DIR"[[:space:]]*\|\|[[:space:]]*release_rc=\$\?' "$f" || return 1
  # 2. the predicate fires on BOTH 1 and 2 -- could-not-check is not may-ship --
  #    and does not fire on 0, or the gate would block every authorized deploy.
  cond=$(call_site_predicate "$f")
  [[ -n "$cond" ]] || return 1
  for rc in 1 2; do
    ( release_rc=$rc; eval "[[ $cond ]]" ) || return 1
  done
  ( release_rc=0; eval "[[ $cond ]]" ) && return 1
  # 3. the guarded block terminates the script. A block that warns and falls
  #    through is a gate with a reader and no teeth.
  grep -qE '^[[:space:]]*exit [1-9]' <<<"$(call_site_block "$f")" || return 1
  return 0
}

# mutant <name> <sed script> -> path to a mutated COPY, proven to differ.
#
# Separate `local` statements deliberately: `local a="$1" b="${a}"` reads `a`
# before it is assigned under `set -u` and aborts the function mid-way. That bug
# was in this file for one revision and it produced FOUR green mutant rows --
# `mutant` died, returned the empty string, `check_call_site` failed on a
# nonexistent path, and "red" was recorded. Every mutation row passed while no
# mutation had been applied. The cmp control below never ran, because the
# function never reached it. See run_cs's readability guard, which is what
# actually closes this hole.
mutant() {
  local name="$1"
  local script="$2"
  local out="${TMP}/deploy-${name}.sh"
  sed "$script" "$DEPLOY" > "$out" 2>/dev/null
  if cmp -s "$DEPLOY" "$out"; then
    printf 'FAIL  %-56s MUTATION IS A NO-OP -- proves nothing\n' "mutant/${name}" >&2
    # A MARKER FILE, not FAIL=$((FAIL+1)). Every call to this function is inside
    # a command substitution, so it runs in a SUBSHELL: an incremented counter
    # dies with it, and the warning above -- which reaches stderr just fine --
    # becomes a detection that cannot vote. Measured: 4 FAIL lines printed under
    # a "1 FAILED, 15 passed" summary and exit 0. The filesystem is the only
    # channel out of a subshell, so the verdict travels on it.
    : > "${TMP}/.noop-${name}"
  fi
  printf '%s' "$out"
}

# run_cs <label> <pass|red> <file>
#
# The readability guard is the load-bearing line. Without it an unreadable path
# -- a mutant that was never written -- scores as `red`, so a broken harness is
# indistinguishable from a working detector. "Could not check" is not "checked
# and found neutered", exactly as exit 2 is not exit 1 in the gate itself.
run_cs() {
  local label="$1" want="$2" f="$3" got
  if [[ -z "$f" || ! -s "$f" ]]; then
    printf 'FAIL  %-56s HARNESS BROKEN: mutant missing or empty (%s)\n' "$label" "${f:-<empty>}"
    FAIL=$((FAIL + 1)); return
  fi
  if check_call_site "$f"; then got=pass; else got=red; fi
  if [[ "$got" != "$want" ]]; then
    printf 'FAIL  %-56s got=%s want=%s\n' "$label" "$got" "$want"
    FAIL=$((FAIL + 1)); return
  fi
  printf 'ok    %-56s %s\n' "$label" "$got"
  PASS=$((PASS + 1))
}

# --- J: the real deploy.sh reads the verdict ---------------------------------
run_cs "J  deploy.sh call site is intact" pass "$DEPLOY"

# --- K: invocation deleted ---------------------------------------------------
# The gate is on disk, tested, green in isolation, and nothing calls it.
run_cs "K  mutant: gate never invoked" red \
  "$(mutant no-invoke '/release-gate\.sh/d')"

# --- L: predicate widened past both failure codes ----------------------------
# Coco's exact neuter. Every deploy ships; rows A-I stay 9/9.
run_cs "L  mutant: predicate -gt 2 (1 and 2 both pass)" red \
  "$(mutant gt2 's/\$release_rc -ne 0/$release_rc -gt 2/')"

# --- M: predicate narrowed to exit 1 only ------------------------------------
# The subtle one. Blocks "not authorized" and lets UNKNOWN through, so a broken
# ls-remote becomes a may-ship. This is the mutation a well-meaning reader makes
# while "tightening" the check.
run_cs "M  mutant: predicate -eq 1 (UNKNOWN sails through)" red \
  "$(mutant eq1 's/\$release_rc -ne 0/$release_rc -eq 1/')"

# --- N: block no longer terminates -------------------------------------------
# Prints ABORT, deploys anyway. The loudest possible false receipt.
run_cs "N  mutant: guarded block warns but does not exit" red \
  "$(mutant no-exit '/if \[\[ \$release_rc -ne 0 \]\]/,/^fi$/{s/^  exit 1$/  echo "continuing"/;}')"

# --- O: nothing spends before the verdict ------------------------------------
# The gate is wired 4th, not 1st (provenance-gate and SELF_VERIFY precede it, on
# purpose: they need no credentials or network). The property that actually
# matters is not "first" but "nothing has spent anything yet" -- and that is the
# claim the header now makes, so it needs a row or it is another comment
# asserting what the code does not do.
#
# LIMIT, stated: this compares line numbers against three NAMED anchors. It is
# not a dataflow analysis. A new network call under a name not listed here is
# invisible to it. Anchors missing -> red, never pass.
check_spend_order() {
  local f="$1" gate ssh_use drift upload
  gate=$(grep -n 'release-gate\.sh' "$f" | head -1 | cut -d: -f1)
  ssh_use=$(grep -nE '^[[:space:]]*\$SSH_CMD[[:space:]]+"' "$f" | head -1 | cut -d: -f1)
  drift=$(grep -nE '^drift_guard[[:space:]]*$' "$f" | head -1 | cut -d: -f1)
  upload=$(grep -nE '^[[:space:]]*rsync -avz' "$f" | head -1 | cut -d: -f1)
  [[ -n "$gate" && -n "$drift" && -n "$upload" ]] || return 1
  (( gate < drift )) || return 1
  (( gate < upload )) || return 1
  [[ -z "$ssh_use" ]] || (( gate < ssh_use )) || return 1
  return 0
}
if check_spend_order "$DEPLOY"; then
  printf 'ok    %-56s %s\n' "O  gate precedes every named spend" pass; PASS=$((PASS + 1))
else
  printf 'FAIL  %-56s got=red want=pass\n' "O  gate precedes every named spend"; FAIL=$((FAIL + 1))
fi

# --- P: an ssh invocation hoisted above the gate -----------------------------
# Proves row O can go red. Without it, O is a green that could not have failed.
P_MUT="$(mutant early-ssh 's|^# --- Release gate ---$|$SSH_CMD "echo spent early"\n# --- Release gate ---|')"
if [[ -z "$P_MUT" || ! -s "$P_MUT" ]]; then
  printf 'FAIL  %-56s HARNESS BROKEN: mutant missing or empty\n' "P  mutant: ssh hoisted above the gate"; FAIL=$((FAIL + 1))
elif check_spend_order "$P_MUT"; then
  printf 'FAIL  %-56s got=pass want=red\n' "P  mutant: ssh hoisted above the gate"; FAIL=$((FAIL + 1))
else
  printf 'ok    %-56s %s\n' "P  mutant: ssh hoisted above the gate" red; PASS=$((PASS + 1))
fi

# --- harness self-audit: collect subshell verdicts ---------------------------
# Runs LAST because it reads markers every mutant row may have dropped. Without
# this loop the no-op warnings are stderr decoration.
NOOPS=0
for marker in "${TMP}"/.noop-*; do
  [[ -e "$marker" ]] || continue
  NOOPS=$((NOOPS + 1))
done
if (( NOOPS > 0 )); then
  echo "HARNESS: ${NOOPS} mutation(s) were no-ops -- those rows proved nothing" >&2
  FAIL=$((FAIL + NOOPS))
fi

echo
if (( FAIL > 0 )); then
  echo "test-release-gate: ${FAIL} FAILED, ${PASS} passed"
  exit 1
fi
echo "test-release-gate: all ${PASS} rows passed"
exit 0
