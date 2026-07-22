#!/usr/bin/env bash
# sitemap-gate.sh — pre-deploy gate: does sitemap.xml still describe this tree?
#
# WHY THIS EXISTS
# `gen-sitemap.py --check` was written to answer exactly this, and its docstring
# says "(for CI/cron)". There was no CI and no cron. Zero callers: not a crontab
# line, not a launchd plist, not a .sh, not a .github/. Its only mention anywhere
# in the tree was a prose line in PUBLIC-MANIFEST.md.
#
# The cost of that showed up on 2026-07-22: six days of lastmod drift across 63
# URLs surfaced only because a human happened to ask for a regen. A detector
# nobody runs does not detect; it documents an intention. The generator was never
# the weak part — the invocation was, which is the same failure this repo already
# has twice in its comments (a rule kept as prose in an agent memory file, and a
# `git log` count nobody re-read because it went verbose instead of red).
#
# So this is not new logic. It is the missing caller, made mandatory by the only
# thing that runs every time: the deploy.
#
# WHAT IT ASKS
# The other two gates ask about OTHER copies of the site:
#   content-gate.sh  "does ORIGIN hold shippable work this tree is missing?"
#   drift_guard      "does PRODUCTION hold files this repo would delete?"
# This one asks about internal consistency, and needs no network to answer:
#   sitemap-gate.sh  "does sitemap.xml match the pages in this tree?"
# It is therefore the cheapest of the three and runs first.
#
# EXIT CODES  (deliberately the same alphabet as content-gate.sh)
#   0  pass — sitemap.xml is current. A receipt was printed. Only this is a pass.
#   1  BLOCK — sitemap.xml is stale. Deploying would publish a sitemap that
#      disagrees with the HTML shipping alongside it in the same rsync.
#   2  UNKNOWN — the gate could not reach a verdict. NOT a pass.
#
# THE EXIT-1 AMBIGUITY, AND WHY THIS GATE DOES NOT INHERIT IT
# gen-sitemap.py returns 2 for every error it handles and 1 for stale. But an
# UNHANDLED exception in python is also exit 1. So generator-exit-1 alone cannot
# distinguish "the sitemap is stale" from "the generator crashed" — and those
# want different humans. This gate therefore requires the STALE RECEIPT LINE,
# not just the code: exit 1 WITH the marker is a real stale verdict; exit 1
# WITHOUT it is a crash wearing a stale verdict's costume, and is reported as
# UNKNOWN.
#
# LIMIT, STATED IN SOURCE: the marker below is a string owned by gen-sitemap.py.
# If someone rewords that message this gate stops recognising stale and starts
# reporting UNKNOWN. That is the safe direction (UNKNOWN blocks the deploy too)
# but it is a degradation, not a pass, and it will be loud rather than silent.
#
# PROVEN RED (2026-07-22). Every row below was RUN and its exit code
# TRANSCRIBED, not predicted. Two rows are recorded because they first failed to
# be tests at all, which is the point of writing the table after the run:
#
#   A  clean tree (control)                              -> 0  PASS + receipt
#   B  sitemap lastmod hand-edited backwards             -> 1  BLOCK
#   C  gen-sitemap.py absent                             -> 2  UNKNOWN
#   D  page carries a future dateModified                -> 2  UNKNOWN
#   E  generator raises (python exit 1, no STALE marker) -> 2  UNKNOWN  <-- the
#      row the marker check exists for. Without it this is an exit 1 and reads
#      as "stale sitemap", sending someone to regenerate a sitemap that is fine.
#   F  python3 off PATH (shim dir, bash+coreutils kept)  -> 2  UNKNOWN
#
# D's first attempt: the injector asserted on a file with no dateModified, died,
# and the gate then ran against a CLEAN TREE and returned 0. A pass, recorded
# under a mutation's name. F's first attempt put python3 out of reach by also
# putting bash out of reach: exit 127, the script never executed. Both would have
# been indistinguishable from real rows in a table written from intent. The
# injector now exits non-zero unless the substitution count is exactly 1, and F
# asserts python3 is unreachable while bash is.
#
# Usage: bash scripts/sitemap-gate.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR="${SCRIPT_DIR}/gen-sitemap.py"

# Owned by gen-sitemap.py's --check branch. See LIMIT above.
STALE_MARKER="STALE: sitemap.xml does not match the tree"
FRESH_MARKER="OK: sitemap.xml is current"

echo "→ Sitemap gate: does sitemap.xml still describe this tree?"

if [[ ! -f "$GENERATOR" ]]; then
  echo "UNKNOWN: generator not found at ${GENERATOR}." >&2
  echo "A gate that cannot check is not a gate that passes." >&2
  exit 2
fi

if ! command -v python3 &>/dev/null; then
  echo "UNKNOWN: python3 not on PATH — the generator cannot run." >&2
  exit 2
fi

# Not `python3 ... | grep`: the pipe would hand us grep's exit status and the
# generator's verdict would be lost. This repo has already paid for that once.
out=""
rc=0
out=$(python3 "$GENERATOR" --check 2>&1) || rc=$?

case "$rc" in
  0)
    if [[ "$out" != *"$FRESH_MARKER"* ]]; then
      echo "UNKNOWN: generator exited 0 but printed no freshness receipt." >&2
      echo "An exit code with no receipt is silence, not a pass." >&2
      printf '%s\n' "$out" >&2
      exit 2
    fi
    echo "✓ Sitemap gate: sitemap.xml matches the tree."
    printf '%s\n' "$out" | tail -3
    exit 0
    ;;
  1)
    if [[ "$out" != *"$STALE_MARKER"* ]]; then
      echo "UNKNOWN: generator exited 1 without the stale receipt." >&2
      echo "Exit 1 is also what an unhandled traceback returns. This is a crash," >&2
      echo "not a stale-sitemap verdict, and it wants a different human." >&2
      echo "--- generator output ---" >&2
      printf '%s\n' "$out" >&2
      exit 2
    fi
    echo "" >&2
    echo "BLOCK: sitemap.xml is stale — it does not describe the pages in this tree." >&2
    echo "Deploying now would publish HTML and a sitemap that disagree, in one rsync." >&2
    echo "--- what moved ---" >&2
    printf '%s\n' "$out" | grep -E '^\s{2}(move|new)\s' >&2 || true
    echo "" >&2
    echo "Fix: python3 scripts/gen-sitemap.py   (then review the diff and commit it)" >&2
    exit 1
    ;;
  *)
    echo "UNKNOWN: generator exited ${rc} — it could not reach a verdict." >&2
    echo "--- generator output ---" >&2
    printf '%s\n' "$out" >&2
    exit 2
    ;;
esac
