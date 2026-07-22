#!/usr/bin/env bash
# test-sitemap-gate.sh — prove sitemap-gate.sh cannot pass without a receipt.
#
# WHY THIS EXISTS
# The PROVEN RED table in sitemap-gate.sh has six rows, A–F, every one of them
# transcribed from a real run. None of them covers the branch at :99-105:
#
#     generator exits 0 AND printed no freshness receipt  ->  must be UNKNOWN
#
# That omission is not one gap among six. Every other row in that table ends in
# exit 1 or exit 2, and deploy.sh:225 aborts on any non-zero — so a bug anywhere
# in those branches degrades toward BLOCKING a deploy that was probably fine.
# Annoying, visible, self-correcting. The rc=0 branch is the only path in the
# file that can reach `exit 0`, which means it is the only place where a bug
# fails OPEN: a silently-succeeding generator gets waved through, deploy.sh sees
# rc 0, and a stale sitemap ships next to fresh HTML in one rsync. The exact
# incident the gate was written for, straight back through the gate's own door.
#
# Coco named it 2026-07-22: "the only place a bug fails open — and it's the only
# one untested."
#
# WHY IT NEEDS ITS OWN HARNESS RATHER THAN A ROW IN THE OLD TABLE
# Rows A–F mutate the tree and let the REAL gen-sitemap.py react. There is no
# tree state that makes a correct gen-sitemap.py exit 0 while printing nothing —
# to observe this branch at all, the generator has to be the thing under
# control. So the subject here is sitemap-gate.sh with a STUB generator beside
# it, in a temp dir, resolved by the gate's own SCRIPT_DIR logic. No network, no
# repo mutation, no dependency on the shared checkout.
#
# THE HARNESS PROVES ITSELF FIRST
# A stub-driven test that only ever asserts red is indistinguishable from a
# harness that is broken in a way that makes everything red. Case 1 is therefore
# a POSITIVE CONTROL: same stub, marker present, must exit 0. If case 1 fails,
# nothing below it means anything and the run says so.
#
# EXIT CODES
#   0  every case behaved as specified.
#   1  a case failed. Named, with expected vs actual.
#   3  harness/layout failure (subject missing, or python3 unavailable). NOT a
#      gate regression — an absent subject otherwise surfaces as N identical
#      assertion failures and sends the reader debugging the wrong file.
#
# Usage: bash scripts/test-sitemap-gate.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="${SCRIPT_DIR}/sitemap-gate.sh"

# These are the strings sitemap-gate.sh matches on. Duplicated here on purpose:
# if someone edits the marker in the gate and not here, these cases go red and
# the reader is told the contract moved. A shared constant would hide that.
FRESH_MARKER="OK: sitemap.xml is current"
STALE_MARKER="STALE: sitemap.xml does not match the tree"

# --- Preflight -------------------------------------------------------------
if [[ ! -f "$SUBJECT" ]]; then
  echo "EXIT 3: harness/layout failure, NOT a sitemap-gate regression." >&2
  echo "  subject not found: $SUBJECT" >&2
  exit 3
fi
if ! command -v python3 &>/dev/null; then
  echo "EXIT 3: harness/layout failure — python3 not on PATH." >&2
  echo "  the gate short-circuits to UNKNOWN before reaching any branch here," >&2
  echo "  so every case below would pass for the wrong reason. Refusing to run." >&2
  exit 3
fi

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

STAGE="${TMPROOT}/scripts"
mkdir -p "$STAGE"
cp "$SUBJECT" "${STAGE}/sitemap-gate.sh"

# --- Stub generator --------------------------------------------------------
# The gate invokes `python3 "${SCRIPT_DIR}/gen-sitemap.py" --check` and captures
# stdout+stderr together, so the stub only has to control (output, exit code).
cat > "${STAGE}/gen-sitemap.py" <<'STUB'
import os, sys
sys.stdout.write(os.environ.get("STUB_OUT", ""))
sys.stdout.flush()
sys.exit(int(os.environ.get("STUB_RC", "0")))
STUB

PASS=0
FAIL=0

# run_case <name> <expected_rc> <stub_rc> <stub_out>
run_case() {
  local name="$1" want="$2" rc="$3" out="$4"
  local got=0
  STUB_RC="$rc" STUB_OUT="$out" bash "${STAGE}/sitemap-gate.sh" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then
    echo "  ✓ ${name} — exit ${got}"
    PASS=$((PASS + 1))
  else
    echo "  ✗ ${name} — expected exit ${want}, got ${got}" >&2
    FAIL=$((FAIL + 1))
  fi
}

echo "→ test-sitemap-gate.sh — the rc=0 branch is the only one that can fail open."
echo ""

# --- 1. POSITIVE CONTROL ---------------------------------------------------
# Must pass, or every red below is meaningless.
run_case "1  control: rc 0 WITH receipt -> PASS" \
  0 0 "${FRESH_MARKER}
  scanned 94 urls"

if [[ $FAIL -ne 0 ]]; then
  echo "" >&2
  echo "ABORT: the positive control failed. The harness cannot produce a green," >&2
  echo "so nothing it calls red is evidence of anything. Fix the harness first." >&2
  exit 1
fi

# --- 2. THE UNTESTED ROW ---------------------------------------------------
# rc 0, no receipt. This is the fail-open case.
run_case "2  rc 0, output EMPTY (silent success) -> UNKNOWN" \
  2 0 ""

run_case "3  rc 0, plausible output, no receipt -> UNKNOWN" \
  2 0 "wrote sitemap.xml
done."

# A near-miss matters more than an absent one: a reworded generator message is
# the LIMIT the gate documents in its own header. Confirm it degrades to UNKNOWN
# rather than substring-matching its way to a pass.
run_case "4  rc 0, receipt REWORDED (near-miss) -> UNKNOWN" \
  2 0 "OK: sitemap.xml is up to date"

# The other direction of the same mistake: stale text on a zero exit must not
# be read as a pass just because the process ended well.
run_case "5  rc 0 carrying the STALE line -> UNKNOWN" \
  2 0 "${STALE_MARKER}"

# --- 3. CROSS-CHECK: the branches the A-F table already claims --------------
# Cheap here, and it verifies the stub harness agrees with rows recorded against
# the real generator. A disagreement means one of the two is lying.
run_case "6  rc 1 WITH stale receipt -> BLOCK" \
  1 1 "${STALE_MARKER}
  move /blog/x/ 2026-07-16 -> 2026-07-22"

run_case "7  rc 1 without stale receipt (crash) -> UNKNOWN  [row E]" \
  2 1 "Traceback (most recent call last):
ValueError: bad date"

run_case "8  rc 2 (generator's own error path) -> UNKNOWN" \
  2 2 "ERROR: cannot parse sitemap.xml"

# --- 4. Receipt is required on stdout AND stderr paths ---------------------
# The gate captures 2>&1, so a generator that prints its receipt to stderr must
# still pass. Documents the coupling rather than leaving it to be rediscovered.
cat > "${STAGE}/gen-sitemap.py" <<'STUB'
import os, sys
sys.stderr.write(os.environ.get("STUB_OUT", ""))
sys.stderr.flush()
sys.exit(int(os.environ.get("STUB_RC", "0")))
STUB
run_case "9  rc 0, receipt on STDERR -> PASS (gate captures 2>&1)" \
  0 0 "${FRESH_MARKER}"

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "${PASS}/${PASS} cases passed."
  exit 0
fi
echo "${PASS} passed, ${FAIL} FAILED." >&2
exit 1
