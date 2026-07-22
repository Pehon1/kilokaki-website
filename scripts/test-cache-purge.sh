#!/usr/bin/env bash
# test-cache-purge.sh — prove cache-purge.sh can go RED.
#
# WHY THIS EXISTS
# `cache-purge.sh:43` claimed "Every checkmark printed below is downstream of a
# comparison that has been PROVEN to go red — see scripts/test-cache-purge.sh."
# That file did not exist when the sentence was written. A citation to a
# non-existent proof is the same defect the whole cache-purge rewrite was built
# to kill, one level up: a claim asserted at the moment of intent and read later
# as a statement of fact. Coco's acceptance criterion says it plainly — if you
# cannot make it go red on demand, it is not a check yet.
#
# HERMETIC BY CONSTRUCTION
# `curl` and `sshpass` are stubbed on PATH, so no case here touches Cloudflare,
# the Cloudways API, or the production host. That is not politeness: a test that
# needs a broken production token to prove the failure branch can only be run by
# breaking production, which means it never gets run.
#
# EXIT CODES
#   0  every case behaved as specified — the red branches went red.
#   1  a case failed. Named, with expected vs actual.
#   3  harness/layout failure (subject missing). NOT a cache-purge regression —
#      an absent subject otherwise surfaces as N identical assertion failures and
#      sends the reader debugging the wrong file.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="${SCRIPT_DIR}/cache-purge.sh"

# --- Preflight: the subject must exist before any assertion means anything ---
if [[ ! -f "$SUBJECT" ]]; then
  echo "EXIT 3: harness/layout failure, NOT a cache-purge regression." >&2
  echo "  subject not found: $SUBJECT" >&2
  echo "  (moved? renamed? this test resolves it repo-relative from its own path)" >&2
  exit 3
fi

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="${TMPROOT}/bin"
mkdir -p "$BIN"

# ---------------------------------------------------------------------------
# Stub: curl. Only the Cloudflare call runs locally; the Varnish PURGEs run on
# the far side of sshpass. Behaviour is driven by STUB_CF_*.
# ---------------------------------------------------------------------------
cat > "${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
# -f is what makes a 4xx a non-zero exit. 22 is curl's code for it.
if [[ "${STUB_CF_HTTP_FAIL:-0}" == "1" ]]; then
  echo "curl: (22) The requested URL returned error: 400"
  exit 22
fi
printf '%s' "${STUB_CF_BODY:-{\"success\":true,\"errors\":[],\"result\":{\"id\":\"z\"}\}}"
exit 0
STUB

# ---------------------------------------------------------------------------
# Stub: sshpass. Stands in for the whole remote PURGE loop. STUB_SSH_OUT is the
# literal stdout the real remote loop would produce; STUB_SSH_RC its exit code.
# ---------------------------------------------------------------------------
cat > "${BIN}/sshpass" <<'STUB'
#!/usr/bin/env bash
if [[ "${STUB_SSH_RC:-0}" != "0" ]]; then
  echo "${STUB_SSH_OUT:-ssh: connect to host: Connection refused}" >&2
  exit "${STUB_SSH_RC}"
fi
printf '%s\n' "${STUB_SSH_OUT:-}"
exit 0
STUB

chmod +x "${BIN}/curl" "${BIN}/sshpass"

# --- A complete, valid env file. Cases mutate copies of it, never this one. ---
GOOD_ENV="${TMPROOT}/deploy.env"
cat > "$GOOD_ENV" <<'ENV'
SSHPASS=not-a-real-password
CF_ZONE_ID=zone123
CF_API_TOKEN=cftoken123
REMOTE_USER=deployuser
REMOTE_HOST=deploy.example.invalid
ENV

pass=0
fail=0
declare -a FAILED=()

# run_case <name> <expected_rc> <expected_substring> [--] <args...>
# Env for the subject is inherited from the caller's `export`s.
run_case() {
  local name="$1" want_rc="$2" want_txt="$3"; shift 3
  [[ "${1:-}" == "--" ]] && shift

  local out="${TMPROOT}/out.$$"
  local rc=0
  # Redirected to a file, never piped. `cmd | tail; echo $?` reports tail's
  # status — that trap cost two agents an hour on 2026-07-22 and it is not
  # getting a third turn inside the harness that exists to catch it.
  PATH="${BIN}:${PATH}" bash "$SUBJECT" "$@" > "$out" 2>&1 || rc=$?

  local got_txt=""
  grep -qF "$want_txt" "$out" && got_txt="ok"

  if [[ "$rc" == "$want_rc" && "$got_txt" == "ok" ]]; then
    printf '  ✓ %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  ✗ %s\n' "$name"
    printf '      expected rc=%s containing: %s\n' "$want_rc" "$want_txt"
    printf '      got      rc=%s\n' "$rc"
    sed 's/^/      | /' "$out"
    fail=$((fail + 1))
    FAILED+=("$name")
  fi
  rm -f "$out"
}

echo "cache-purge.sh — red-on-demand proof"
echo ""

# ---------------------------------------------------------------------------
# Group 1: arguments and config. These run before any network shape is set up,
# because a check that cannot be configured must refuse rather than no-op.
# ---------------------------------------------------------------------------
export KILOKAKI_DEPLOY_ENV="$GOOD_ENV"
export STUB_CF_HTTP_FAIL=0 STUB_CF_BODY='{"success":true}'
export STUB_SSH_RC=0 STUB_SSH_OUT=""

run_case "no paths -> UNKNOWN, not a silent pass" 2 "no paths given"
run_case "unquotable path -> refuse before it reaches a remote shell" 2 \
  "refusing to purge a path I cannot safely quote" -- '/a;rm -rf /'

export KILOKAKI_DEPLOY_ENV="${TMPROOT}/nope.env"
run_case "missing env file -> UNKNOWN" 2 "deploy env not found" -- /sitemap.xml

INCOMPLETE_ENV="${TMPROOT}/incomplete.env"
grep -v '^CF_API_TOKEN=' "$GOOD_ENV" > "$INCOMPLETE_ENV"
export KILOKAKI_DEPLOY_ENV="$INCOMPLETE_ENV"
run_case "env missing CF_API_TOKEN -> UNKNOWN, names the var" 2 \
  "CF_API_TOKEN missing" -- /sitemap.xml

export KILOKAKI_DEPLOY_ENV="$GOOD_ENV"

# ---------------------------------------------------------------------------
# Group 2: Cloudflare. Case 2b is the whole reason the body assertion exists.
# ---------------------------------------------------------------------------
export STUB_SSH_OUT=$'PURGE\t/sitemap.xml\t200\nPURGE-END'

export STUB_CF_HTTP_FAIL=1
run_case "CF 4xx (bad token) -> BLOCK" 1 \
  "BLOCK: Cloudflare purge request failed" -- /sitemap.xml

export STUB_CF_HTTP_FAIL=0
export STUB_CF_BODY='{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}'
run_case "CF HTTP 200 + success:false -> BLOCK (the case -f cannot see)" 1 \
  "did not report success:true" -- /sitemap.xml

export STUB_CF_BODY='{"success":true}'

# ---------------------------------------------------------------------------
# Group 3: Varnish transport. NOTE what these do and do not prove — see the
# measured note at the bottom of this file.
# ---------------------------------------------------------------------------
export STUB_SSH_OUT=$'PURGE\t/sitemap.xml\t403\nPURGE-END'
run_case "PURGE 403 (ACL blocks us) -> BLOCK" 1 \
  "did not return 200/204" -- /sitemap.xml

export STUB_SSH_OUT=$'PURGE\t/sitemap.xml\t000\nPURGE-END'
run_case "PURGE 000 (no answer at all) -> BLOCK" 1 \
  "did not return 200/204" -- /sitemap.xml

export STUB_SSH_OUT=$'PURGE\t/sitemap.xml\t200'
run_case "no PURGE-END marker (loop cut short) -> UNKNOWN" 2 \
  "did not run to completion" -- /sitemap.xml

export STUB_SSH_OUT=$'PURGE\t/sitemap.xml\t200\nPURGE-END'
run_case "2 paths asked, 1 result line -> UNKNOWN" 2 \
  "result line(s)" -- /sitemap.xml /blog/

export STUB_SSH_RC=255 STUB_SSH_OUT="ssh: connect to host: Connection refused"
run_case "ssh unreachable -> UNKNOWN, explicitly not a pass" 2 \
  "could not reach" -- /sitemap.xml
export STUB_SSH_RC=0

# ---------------------------------------------------------------------------
# Group 3b: the api/v1 restart fallback. Nori, 2026-07-22: "no CW_EMAIL in
# deploy.env means it must refuse loudly, not print a checkmark — otherwise we
# rebuild the bug one layer down." The step this fallback replaces printed
# `✓ Varnish restarted` in exactly this configuration. Pinning the refusal is
# the only thing that stops it coming back.
# ---------------------------------------------------------------------------
export CACHE_PURGE_FALLBACK_RESTART=true
NO_EMAIL_ENV="${TMPROOT}/no-email.env"
grep -v '^CW_EMAIL=' "$GOOD_ENV" > "$NO_EMAIL_ENV"
export KILOKAKI_DEPLOY_ENV="$NO_EMAIL_ENV"
run_case "api/v1 fallback, no CW_EMAIL -> UNKNOWN, refuses by name" 2 \
  "Refusing to print a checkmark for a call I cannot authenticate" -- /sitemap.xml
run_case "api/v1 fallback, no CW_EMAIL -> never prints a Varnish checkmark" 2 \
  "CW_EMAIL is absent" -- /sitemap.xml
unset CACHE_PURGE_FALLBACK_RESTART
export KILOKAKI_DEPLOY_ENV="$GOOD_ENV"

# ---------------------------------------------------------------------------
# Group 4: the happy path. Last on purpose — a green run only means something
# once the red branches above have been shown to fire.
# ---------------------------------------------------------------------------
export STUB_SSH_OUT=$'PURGE\t/sitemap.xml\t200\nPURGE\t/blog/\t204\nPURGE-END'
run_case "all good -> pass" 0 \
  "Eviction is NOT proven here" -- /sitemap.xml /blog/

echo ""
if [[ $fail -gt 0 ]]; then
  echo "FAIL: passed=${pass} failed=${fail}" >&2
  printf '    %s\n' "${FAILED[@]}" >&2
  exit 1
fi

echo "passed=${pass} failed=0"
echo ""
echo "MEASURED 2026-07-22 against the live host, and it bounds what Group 3 proves:"
echo "    PURGE /this-path-does-not-exist-mochi-probe-7f3a  -> 200"
echo "    GET   /this-path-does-not-exist-mochi-probe-7f3a  -> 404"
echo "Varnish answers 200 for purging a path that does not exist and was never"
echo "cached. So a 200 here proves the request REACHED Varnish and the PURGE ACL"
echo "did not reject it. It proves nothing about cache state, and it must never be"
echo "the post-deploy acceptance check. That job belongs to scripts/verify-edge.sh,"
echo "which compares live bytes to the artifact being shipped."
exit 0
