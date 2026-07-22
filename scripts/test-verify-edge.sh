#!/usr/bin/env bash
# test-verify-edge.sh — prove what verify-edge.sh can and cannot see.
#
# WHY THIS EXISTS
# verify-edge.sh holds the strongest authority of any gate in this repo: it is
# the one that can say DEPLOY NOT VERIFIED after the bytes are already on the
# edge. It is also the least proven. Every other gate here has a harness; this
# one shipped on a single live run against kilokaki.com, which is not a test —
# it is one sample of one tree against one cache state, unrepeatable by design.
#
# THE THING BEING TESTED IS NOT THE DIFF
# A byte comparison is not where this file can go wrong. `normalize_to()` is.
# It exists because Cloudflare's Email Address Obfuscation rewrites HTML in
# flight, so a raw diff is red-forever on every page holding a mailto: — a check
# that cries wolf inside a week and then gets switched off. Normalizing is the
# right call and it is also the only place in the file that can fail OPEN:
# every byte it collapses is a byte the edge is no longer being checked on.
#
# verify-edge.sh already says this in prose — "a new Cloudflare feature would be
# an unknown-unknown that this function would silently absorb only if I widened
# it carelessly." That sentence is correct and it is not a test. Nori's line
# from this morning, about a different file and just as true here: a comment
# that correctly describes the bug is not a gate.
#
# ROW 3 IS THE POINT OF THIS FILE
# Rows 2 and 3 feed the harness the SAME tree with the SAME real byte difference
# and change exactly one thing between them — the normalizer:
#
#     row 2   shipped normalizer (mailto: only)   ->  exit 1, BLOCK    (red)
#     row 3   normalizer widened ONE notch        ->  exit 0, "match"  (GREEN)
#
# Row 3 asserts the GREEN. That is deliberate and it is the whole design: the
# suite demonstrates the failure mode instead of asserting its absence. A row
# that asserted "widening cannot hide drift" would be a claim about code nobody
# has written yet; this one is a receipt showing the exact widening that hides
# a real difference, sitting next to the diff it hides. The next person tempted
# to add one more `sed -e` to normalize_to() has to walk past it.
#
# Stated plainly, because it is the honest limit of row 3: a row that asserts
# exit 0 cannot detect a fail-open — a bug that greens everything greens this
# too. Row 3 does not defend the normalizer. Row 2 does. Row 3 exists to make
# the blind spot executable and reviewable, and the PAIR is the proof: identical
# inputs, one variable, opposite verdicts.
#
# HERMETIC
# No network, no shared checkout, no live site. Every case runs against a local
# http.server on an ephemeral port with a purpose-built docroot, and a fake
# SRC_DIR — both env-overridable on the subject already (VERIFY_BASE_URL,
# VERIFY_SRC_DIR), so nothing here needs the subject modified to be testable.
# Row 3 is the one exception and it mutates a COPY in a temp dir: the red proof
# on 2026-07-22 corrupted a real tree to prove a point, and the lesson recorded
# was that a deliberate corruption's blast radius is wherever it was performed.
#
# THE HARNESS PROVES ITSELF FIRST
# Case 1 is a POSITIVE CONTROL: matching bytes, must exit 0. A harness that only
# ever asserts red is indistinguishable from one broken so that everything is
# red. If case 1 fails, nothing below it means anything and the run says so.
#
# EXIT CODES
#   0  every case behaved as specified.
#   1  a case failed. Named, with expected vs actual.
#   3  harness/layout failure (subject missing, python3/curl unavailable, or the
#      local server never came up). NOT a verify-edge regression — an absent
#      subject otherwise surfaces as N identical failures and sends the reader
#      to debug the wrong file.
#
# Usage: bash scripts/test-verify-edge.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="${SCRIPT_DIR}/verify-edge.sh"

# --- Preflight -------------------------------------------------------------
harness_fail() {
  echo "EXIT 3: harness/layout failure, NOT a verify-edge regression." >&2
  echo "  $1" >&2
  exit 3
}

[[ -f "$SUBJECT" ]] || harness_fail "subject not found: $SUBJECT"
command -v python3 &>/dev/null || harness_fail "python3 not on PATH — no local edge to serve from."
command -v curl    &>/dev/null || harness_fail "curl not on PATH — the subject cannot fetch anything."

TMPROOT=$(mktemp -d)
SRV_PID=""
cleanup() {
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

pass=0
fail=0

# --- Fixtures --------------------------------------------------------------
# One page, three knobs: the anchor text (a real content difference), the email
# anchor (the region normalize_to collapses), and whatever the edge injects just
# before </body>. Everything else is fixed, so any diff a case produces is the
# one the case put there.
page() {  # <anchor-text> <email-block> <pre-body-close-injection>
  cat <<EOF
<!doctype html>
<html><head><title>KiloKaki</title></head>
<body>
<nav><a href="/pricing.html">$1</a></nav>
<p>Stop counting. Start knowing.</p>
$2
${3}</body>
</html>
EOF
}

MAILTO='<p><a href="mailto:hello@kilokaki.com">hello@kilokaki.com</a></p>'
MAILTO_OTHER='<p><a href="mailto:support@kilokaki.com">support@kilokaki.com</a></p>'

# Transcribed from live bytes, not from the prose in verify-edge.sh. Measured
# 2026-07-22 against https://kilokaki.com/ :
#
#     ...</div>\n<script data-cfasync="false" src="/cdn-cgi/scripts/5c5dd728/
#     cloudflare-static/email-decode.min.js"></script></body>\n</html>\n
#
# The injection is INLINE — it sits between an existing newline and </body> and
# adds no newline of its own. That detail decides whether the whole normalizer
# works: an earlier draft of this fixture put the script on its own line, and
# rows 4 and 5 went red at 183B vs 182B. The residue was a newline my fixture
# invented, not one Cloudflare emits. Worth stating because the tempting fix was
# to widen the subject's sed to eat surrounding whitespace — patching real code
# to satisfy a wrong fixture, which is row 3's hazard arriving by the back door.
CF_ANCHOR='<p><a href="/cdn-cgi/l/email-protection#3e564b52"><span class="__cf_email__" data-cfemail="deb6ab">[email&#160;protected]</span></a></p>'
CF_SCRIPT='<script data-cfasync="false" src="/cdn-cgi/scripts/7d0fa10a/cloudflare-static/email-decode.min.js"></script>'

# --- Local edge ------------------------------------------------------------
start_server() {  # <docroot>
  local root="$1" portfile="${TMPROOT}/port"
  rm -f "$portfile"
  python3 - "$root" "$portfile" >/dev/null 2>&1 <<'PY' &
import sys, os, functools, http.server, socketserver
root, portfile = sys.argv[1], sys.argv[2]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
class Server(socketserver.TCPServer):
    allow_reuse_address = True
httpd = Server(("127.0.0.1", 0), handler)
with open(portfile + ".tmp", "w") as f:
    f.write(str(httpd.server_address[1]))
os.replace(portfile + ".tmp", portfile)
httpd.serve_forever()
PY
  SRV_PID=$!
  local i
  for i in $(seq 1 200); do
    [[ -s "$portfile" ]] && { PORT=$(cat "$portfile"); return 0; }
    kill -0 "$SRV_PID" 2>/dev/null || harness_fail "local server died before binding a port."
    sleep 0.05
  done
  harness_fail "local server never reported a port within 10s."
}

stop_server() {
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null
  wait "$SRV_PID" 2>/dev/null
  SRV_PID=""
}

# --- Assertion -------------------------------------------------------------
# Takes the true exit code of the subject, never the subject's own claim about
# itself. Both suites in this repo print their own "N/N passed"; on 2026-07-22 a
# capture of one came back empty and would have been quoted as a result.
check() {  # <label> <expected-rc> <actual-rc> [<must-contain-in-output>]
  local label="$1" want="$2" got="$3" needle="${4:-}"
  if [[ "$got" != "$want" ]]; then
    echo "  ✗ ${label}"
    echo "      expected exit ${want}, got ${got}"
    echo "      ---- subject output ----"
    sed 's/^/      /' <<<"$OUT"
    fail=$((fail + 1))
    return
  fi
  if [[ -n "$needle" ]] && ! grep -qF -- "$needle" <<<"$OUT"; then
    echo "  ✗ ${label}"
    echo "      exit ${got} as expected, but output is missing: ${needle}"
    echo "      ---- subject output ----"
    sed 's/^/      /' <<<"$OUT"
    fail=$((fail + 1))
    return
  fi
  echo "  ✓ ${label}"
  pass=$((pass + 1))
}

# Run <subject> against the current server + repo dir. Sets OUT and RC.
run_subject() {  # <subject-path> <repo-dir> [<path> ...]
  local subject="$1" repo="$2"; shift 2
  RC=0
  OUT=$(VERIFY_BASE_URL="http://127.0.0.1:${PORT}" \
        VERIFY_SRC_DIR="$repo" \
        bash "$subject" "$@" 2>&1) || RC=$?
}

# Build a live docroot + repo dir that differ only where the caller says.
scenario() {  # <name> <live-anchor> <live-email> <live-inject> <repo-anchor> <repo-email> <repo-inject>
  local name="$1"
  LIVE="${TMPROOT}/${name}/live"; REPO="${TMPROOT}/${name}/repo"
  mkdir -p "$LIVE" "$REPO"
  page "$2" "$3" "$4" > "${LIVE}/index.html"
  page "$5" "$6" "$7" > "${REPO}/index.html"
}

echo "test-verify-edge.sh — subject: ${SUBJECT}"
echo ""

# --- 1. POSITIVE CONTROL ---------------------------------------------------
# Identical bytes, nothing for the normalizer to touch. If this is not exit 0,
# every red below is the harness talking, not the subject.
scenario control "Pricing" "" "" "Pricing" "" ""
start_server "$LIVE"
run_subject "$SUBJECT" "$REPO" /
check "1  positive control — live == repo, exits 0" 0 "$RC" "byte-identical"
stop_server

# --- 2. REAL DRIFT, shipped normalizer -------------------------------------
# The edge serves "Pricing (beta)", the tree says "Pricing". Nine bytes, outside
# any email anchor. This is the whole reason the file exists.
scenario drift "Pricing (beta)" "$MAILTO" "" "Pricing" "$MAILTO" ""
DRIFT_LIVE="$LIVE"; DRIFT_REPO="$REPO"
start_server "$DRIFT_LIVE"
run_subject "$SUBJECT" "$DRIFT_REPO" /
check "2  real drift, shipped normalizer — BLOCKs (exit 1)" 1 "$RC" "BLOCK: the edge is serving"

# --- 3. THE ROW: same drift, normalizer widened one notch -> GREEN ---------
# Identical server, identical repo dir, identical path. The ONLY change is the
# normalizer: `mailto:[^"]*` becomes `[^"]*`, which is one plausible edit away
# from what ships — "make it cover the other anchors Cloudflare rewrites" — and
# it collapses every anchor on the page to <<EMAIL>>, drift included.
#
# The mutation is applied to a COPY. The repo tree is not touched, here or
# anywhere in this file.
WIDENED="${TMPROOT}/verify-edge.widened.sh"
sed 's|<a href="mailto:\[^"\]\*">|<a href="[^"]*">|' "$SUBJECT" > "$WIDENED"
if cmp -s "$SUBJECT" "$WIDENED"; then
  harness_fail "the widening sed matched nothing — normalize_to() moved. Row 3 would pass for the wrong reason."
fi
run_subject "$WIDENED" "$DRIFT_REPO" /
check "3  SAME drift, widened normalizer — swallowed, exits 0 GREEN" 0 "$RC" "cf-norm"
stop_server

# --- 4. Cloudflare obfuscation, genuinely matching content ------------------
# The case normalize_to() was written for: edge rewrote the mailto, nothing else
# differs. Must pass, and must SAY it normalized rather than pass silently.
scenario cfmatch "Pricing" "$CF_ANCHOR" "$CF_SCRIPT" "Pricing" "$MAILTO" ""
CF_LIVE="$LIVE"; CF_REPO="$REPO"
start_server "$CF_LIVE"
run_subject "$SUBJECT" "$CF_REPO" /
check "4  cf email obfuscation, real match — passes, declares cf-norm" 0 "$RC" "cf-normalized"

# --- 5. The documented blind spot, made executable -------------------------
# Swap the email address itself. Both sides collapse to <<EMAIL>>, so this is a
# real content change the check cannot see. verify-edge.sh states this in its
# own pass line; this is the row that keeps that statement true.
scenario blindspot "Pricing" "$CF_ANCHOR" "$CF_SCRIPT" "Pricing" "$MAILTO_OTHER" ""
BS_LIVE="$LIVE"; BS_REPO="$REPO"
run_subject "$SUBJECT" "$BS_REPO" /
check "5  blind spot — email address differs, still exits 0" 0 "$RC" "Blind spot"

# --- 6. Escape hatch actually escapes --------------------------------------
# VERIFY_CF_NORMALIZE=false is the documented way to investigate a suspected new
# edge rewrite. If it silently kept normalizing, the one tool for finding an
# unknown-unknown would be the thing hiding it.
RC=0
OUT=$(VERIFY_BASE_URL="http://127.0.0.1:${PORT}" \
      VERIFY_SRC_DIR="$CF_REPO" \
      VERIFY_CF_NORMALIZE=false \
      bash "$SUBJECT" / 2>&1) || RC=$?
check "6  VERIFY_CF_NORMALIZE=false — same tree now BLOCKs (exit 1)" 1 "$RC" "DIFFERS"
stop_server

# --- 7. Non-200 is a failure, not a skip -----------------------------------
# Repo holds the file, the edge does not serve it. A 404 that counted as
# "checked" would be the original defect — a status line standing in for content.
scenario missing "Pricing" "$MAILTO" "" "Pricing" "$MAILTO" ""
printf '%s' "gone" > "${REPO}/orphan.html"
start_server "$LIVE"
run_subject "$SUBJECT" "$REPO" /orphan.html
check "7  edge returns 404 — BLOCK (exit 1)" 1 "$RC" "HTTP 404"

# --- 8. Unmappable path is UNKNOWN, never skipped --------------------------
run_subject "$SUBJECT" "$REPO" "sitemap.xml"
check "8  path with no leading slash — UNKNOWN (exit 2)" 2 "$RC" "cannot map to a repo file"

# --- 9. No repo counterpart is UNKNOWN -------------------------------------
run_subject "$SUBJECT" "$REPO" /not-in-the-repo.html
check "9  no repo counterpart — UNKNOWN (exit 2)" 2 "$RC" "no repo counterpart"

# --- 10. Zero paths is UNKNOWN, not a vacuous pass -------------------------
run_subject "$SUBJECT" "$REPO"
check "10 no paths given — UNKNOWN (exit 2)" 2 "$RC" "means nothing"
stop_server

# --- Verdict ---------------------------------------------------------------
echo ""
total=$((pass + fail))
if [[ $fail -gt 0 ]]; then
  echo "FAIL: ${fail}/${total} case(s) did not behave as specified."
  exit 1
fi
echo "PASS: ${pass}/${total} cases."
echo ""
echo "Row 3 passed, which means the widening DOES hide real drift. That row is a"
echo "receipt for a hazard, not a clean bill of health — read it next to row 2."
exit 0
