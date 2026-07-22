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
# Routes on the URL, because one stub now serves three different callers:
# Cloudflare purge_cache, the api/v1 OAuth mint, and api/v1 service/state.
# The two api/v1 callers use `-o <file> -w '%{http_code}'`, so this has to honour
# both: body to the file, status code to stdout. Getting that split wrong would
# make the subject read a status code as a body and pass for the wrong reason.
url=""; outfile=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && outfile="$a"
  case "$a" in https://*) url="$a" ;; esac
  prev="$a"
done

emit() { # <body> <http_code>
  if [[ -n "$outfile" ]]; then printf '%s' "$1" > "$outfile"; printf '%s' "$2"
  else printf '%s' "$1"; fi
}

case "$url" in
  *oauth/access_token*)
    # The stub VALIDATES the api_key it was handed, rather than accepting any
    # string. Without this the harness is blind to the original defect: sending
    # CW_API_TOKEN instead of CW_API_KEY would mint a token here and every case
    # would stay green. A stub that answers 200 to anything cannot test an
    # authentication bug — it only tests the plumbing around one.
    sent_key=""
    for a in "$@"; do case "$a" in api_key=*) sent_key="${a#api_key=}" ;; esac; done
    if [[ -z "${STUB_MINT_CODE:-}" && -n "${STUB_GOOD_API_KEY:-}" \
          && "$sent_key" != "$STUB_GOOD_API_KEY" ]]; then
      emit '{"error":"invalid_credentials","error_description":"The user credentials were incorrect."}' 403
      exit 0
    fi
    emit "${STUB_MINT_BODY:-{\"access_token\":\"tok-abc\",\"expires_in\":3600\}}" \
         "${STUB_MINT_CODE:-200}"
    exit "${STUB_MINT_RC:-0}" ;;
  *service/state*)
    emit "${STUB_STATE_BODY:-{\"status\":true\}}" "${STUB_STATE_CODE:-200}"
    exit "${STUB_STATE_RC:-0}" ;;
esac

# Cloudflare. -f is what makes a 4xx a non-zero exit. 22 is curl's code for it.
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
#
# It MIRRORS the real deploy.env key-for-key, including the Cloudways OAuth pair
# added 2026-07-22. That is not decoration. Before then this fixture had no
# CW_EMAIL, and the "no CW_EMAIL -> refuses" case built its input with
# `grep -v '^CW_EMAIL='` — over a file that never contained CW_EMAIL. The case
# passed without ever removing anything: green about a mutation it did not make.
# Same family as the refusal tests that pinned the wrong refusal. A fixture that
# does not carry the var cannot prove what happens when the var goes missing.
GOOD_ENV="${TMPROOT}/deploy.env"
cat > "$GOOD_ENV" <<'ENV'
SSHPASS=not-a-real-password
CF_ZONE_ID=zone123
CF_API_TOKEN=cftoken123
REMOTE_USER=deployuser
REMOTE_HOST=deploy.example.invalid
CW_SERVER_ID=srv123
CW_APP_ID=app123
CW_API_TOKEN=cwtoken-41-chars-and-the-WRONG-credential
CW_EMAIL=deploy@example.invalid
CW_API_KEY=cwapikey-30-chars-the-right-one
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

# refute_case <name> <expected_rc> <FORBIDDEN_substring> [--] <args...>
# The mirror of run_case, and the fallback group needs it. Every check here
# asserts that some text IS present, which cannot express the actual defect
# class: printing `✓ Varnish restarted.` for a call that failed. Asserting the
# error appears does not prove the checkmark did not ALSO appear two lines up.
refute_case() {
  local name="$1" want_rc="$2" bad_txt="$3"; shift 3
  [[ "${1:-}" == "--" ]] && shift

  local out="${TMPROOT}/out.$$"
  local rc=0
  PATH="${BIN}:${PATH}" bash "$SUBJECT" "$@" > "$out" 2>&1 || rc=$?

  if [[ "$rc" == "$want_rc" ]] && ! grep -qF "$bad_txt" "$out"; then
    printf '  ✓ %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  ✗ %s\n' "$name"
    printf '      expected rc=%s and NO occurrence of: %s\n' "$want_rc" "$bad_txt"
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
#
# UPDATED 2026-07-22 after Coco falsified the premise these cases were written
# under. The old note said the fallback could not run because CW_EMAIL was
# absent. True, but not the reason it 403'd: the function was ALSO sending
# CW_API_TOKEN as the api_key, and that credential authenticates nowhere on
# api/v1. A missing var and a wrong var return the identical 403, so fixing only
# the missing one would have shipped a still-broken call under a green presence
# check. Hence the split below: presence cases prove the diagnosis, and the MINT
# cases prove the verdict. The corrupted-key case is the one Coco asked for by
# name — "I want to see it go red before I trust it green."
# ---------------------------------------------------------------------------
export CACHE_PURGE_FALLBACK_RESTART=true
# Must match CW_API_KEY in GOOD_ENV. The stub 403s anything else, so a subject
# that sends the wrong variable goes red here instead of sailing through.
export STUB_GOOD_API_KEY='cwapikey-30-chars-the-right-one'

# --- The regression test for the actual 2026-07-22 bug: the fallback must send
# CW_API_KEY as the api_key. Sending CW_API_TOKEN (present, well-formed, wrong)
# is what produced the 403 that got misdiagnosed as a missing CW_EMAIL.
run_case "fallback sends CW_API_KEY, not CW_API_TOKEN, as the api_key" 0 \
  "restart REQUESTED via api/v1" -- /sitemap.xml

# --- Presence: each var stripped INDIVIDUALLY from a fixture that really has it.
for v in CW_EMAIL CW_API_KEY CW_SERVER_ID; do
  STRIPPED="${TMPROOT}/no-${v}.env"
  grep -v "^${v}=" "$GOOD_ENV" > "$STRIPPED"
  # Guard the mutation itself. If the fixture ever stops carrying the var, this
  # says so instead of quietly passing on a no-op strip — the exact way the
  # previous version of this case was green without removing anything.
  if ! grep -q "^${v}=" "$GOOD_ENV"; then
    echo "EXIT 3: fixture does not contain ${v}; the strip below proves nothing." >&2
    exit 3
  fi
  export KILOKAKI_DEPLOY_ENV="$STRIPPED"
  run_case "fallback, no ${v} -> UNKNOWN, names the missing var" 2 \
    "absent from" -- /sitemap.xml
  refute_case "fallback, no ${v} -> prints NO Varnish checkmark" 2 \
    "✓ Varnish" -- /sitemap.xml
done
export KILOKAKI_DEPLOY_ENV="$GOOD_ENV"

# --- The mint. Present-but-WRONG key: every var set, 403 from Cloudways.
# This is the case a presence check structurally cannot catch, and it is the
# shape of the real bug: CW_API_TOKEN was present, well-formed, and wrong.
export STUB_MINT_CODE=403
export STUB_MINT_BODY='{"error":"invalid_credentials","error_description":"The user credentials were incorrect."}'
run_case "fallback, corrupted CW_API_KEY -> BLOCK on the mint" 1 \
  "Cloudways refused to mint an access_token" -- /sitemap.xml
run_case "fallback, corrupted CW_API_KEY -> states nothing was restarted" 1 \
  "NOTHING WAS RESTARTED" -- /sitemap.xml
run_case "fallback, corrupted CW_API_KEY -> echoes the 403 body, not just a code" 1 \
  "invalid_credentials" -- /sitemap.xml
refute_case "fallback, corrupted CW_API_KEY -> prints NO Varnish checkmark" 1 \
  "✓ Varnish" -- /sitemap.xml

# 200 with no token in it. Cheap to dismiss, and it is the Cloudflare
# success:false lesson one API over: a good status carrying a useless body.
export STUB_MINT_CODE=200 STUB_MINT_BODY='{"expires_in":3600}'
run_case "fallback, mint 200 but no access_token -> BLOCK" 1 \
  "Cloudways refused to mint an access_token" -- /sitemap.xml
refute_case "fallback, mint 200 without a token -> never calls service/state" 1 \
  "restart REQUESTED" -- /sitemap.xml

# --- service/state. Token good, restart refused: the failure must not be
# attributed to auth, or the runbook sends the next reader to the wrong key.
export STUB_MINT_CODE=200 STUB_MINT_BODY='{"access_token":"tok-abc"}'
export STUB_STATE_CODE=403 STUB_STATE_BODY='{"error":"forbidden"}'
run_case "fallback, mint OK + service/state 403 -> BLOCK, blames the restart" 1 \
  "this is the RESTART that failed, not the auth" -- /sitemap.xml
refute_case "fallback, service/state 403 -> prints NO Varnish checkmark" 1 \
  "✓ Varnish" -- /sitemap.xml

# --- Fallback happy path. Note what the checkmark is allowed to claim.
export STUB_STATE_CODE=200 STUB_STATE_BODY='{"status":true}'
run_case "fallback, mint OK + restart accepted -> pass" 0 \
  "restart REQUESTED via api/v1" -- /sitemap.xml
refute_case "fallback green NEVER claims Varnish was restarted" 0 \
  "✓ Varnish restarted" -- /sitemap.xml

unset CACHE_PURGE_FALLBACK_RESTART STUB_MINT_CODE STUB_MINT_BODY \
      STUB_STATE_CODE STUB_STATE_BODY
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
