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
PASS=0; FAIL=0

# A sandbox: work repo + bare "origin", one commit, identity set locally so the
# suite does not depend on the runner having a global git identity.
sandbox() {
  local name="$1" work="${TMP}/${1}" bare="${TMP}/${1}.git"
  rm -rf "$work" "$bare"
  git init -q --bare "$bare"
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
W=$(sandbox a)
git -C "$W" tag -a release/2026-07-23 -m "authorized: row A" HEAD
git -C "$W" push -q origin release/2026-07-23
run "A  annotated release tag on origin peels to HEAD" 0 "$W" "authorized by refs/tags/release/2026-07-23"

# --- B: tag exists on origin but peels to a DIFFERENT commit -----------------
# The freeze case that matters most: an old release is tagged, the tree has
# moved on. Authorized yesterday is not authorized now.
W=$(sandbox b)
git -C "$W" tag -a release/old -m "authorized: an earlier commit" HEAD
git -C "$W" push -q origin release/old
echo "moved on" >> "$W/file.txt"
git -C "$W" commit -qam "advance past the authorized commit"
git -C "$W" push -q origin HEAD:refs/heads/main
run "B  tag peels to a different commit" 1 "$W" "NOT AUTHORIZED"

# --- C: no release/* tag on origin at all ------------------------------------
W=$(sandbox c)
run "C  no release/* tag on origin" 1 "$W" "No release/\* tags exist"

# --- D: ls-remote cannot reach the remote ------------------------------------
# UNKNOWN, not "not authorized". Collapsing these two would let a network
# failure read as a policy verdict.
W=$(sandbox d)
git -C "$W" remote set-url origin "${TMP}/definitely-not-a-repo-$$"
run "D  ls-remote fails -> UNKNOWN, not a verdict" 2 "$W" "UNKNOWN"

# --- E: tag exists LOCALLY only, never pushed --------------------------------
# The single-disk claim. This is the row that makes "published artifact"
# mean something rather than being a slogan.
W=$(sandbox e)
git -C "$W" tag -a release/local-only -m "never pushed" HEAD
run "E  tag is local-only, not on origin" 1 "$W" "NOT AUTHORIZED"

# --- F: LIGHTWEIGHT tag on origin pointing at HEAD ---------------------------
# Control for requirement 4 (peel the tag). A lightweight tag publishes ONE
# ls-remote line whose sha IS the commit and which carries no `^{}` suffix, no
# tagger, no date and no message. A gate that matched unpeeled lines would go
# green here. It must not: there is nothing to record about the act.
W=$(sandbox f)
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
W=$(sandbox i)
git -C "$W" tag -a v1.0.0 -m "not a release authorization" HEAD
git -C "$W" push -q origin v1.0.0
run "I  annotated non-release/* tag does not authorize" 1 "$W" "NOT AUTHORIZED"

echo
if (( FAIL > 0 )); then
  echo "test-release-gate: ${FAIL} FAILED, ${PASS} passed"
  exit 1
fi
echo "test-release-gate: all ${PASS} rows passed"
exit 0
