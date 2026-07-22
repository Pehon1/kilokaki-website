#!/usr/bin/env bash
# cache-purge.sh — turn over the caches in front of this site, and PROVE it.
#
# WHY THIS EXISTS
# On 2026-07-22 `deploy.sh` shipped sitemap `0c43b52`, exited 0, printed
# `✓ Files uploaded.`, `✓ Cloudflare cache purged.`, `✓ Varnish restarted.`,
# `✓ Done!` and three green health checks — while the edge served a six-day-old
# sitemap.xml for the whole window. Every indicator was honest. Not one of them
# could see the layer that failed.
#
# The two cache steps it replaces were unfalsifiable in two different ways:
#
#   CLOUDFLARE (was deploy.sh:261)
#     curl -s -X POST .../purge_cache ... > /dev/null
#     No -f, no body read. Cloudflare answers a bad token with 400 and a
#     permission-less token with 200 + {"success":false}. Both scored as PASS.
#
#   VARNISH (was deploy.sh:269)
#     curl -s -X POST https://api.cloudways.com/public/v1/service/$SRV/$APP/restart
#     Same shape, plus the endpoint is wrong: the real Cloudways API is api/v1,
#     not public/v1. MEASURED 2026-07-22 from this host:
#         GET  https://api.cloudways.com/public/v1/<any path>  -> 200 "You have
#              reached Cloudways API."   (marketing string, unauthenticated)
#         POST https://api.cloudways.com/public/v1/<any path>  -> 403, Cloudflare
#              "Attention Required!" HTML block page. Including the bare root.
#     The line under test is a POST, so it has been collecting 403s. `curl -sf`
#     against it exits 56 ("The requested URL returned error: 403"), 3/3 runs —
#     so -f WOULD have gone red here. It never ran with -f, and the result went
#     to /dev/null, so nothing ever looked. The checkmark below it was a printf.
#     It distinguished exactly one thing: that TCP/TLS reached Cloudways.
#
# WHAT REPLACES IT
# The targeted PURGE Nori verified 2026-07-16 and again 2026-07-22:
#     curl -X PURGE -H "Host: kilokaki.com" http://127.0.0.1/<path>   (over SSH)
# Cheaper than a restart, non-disruptive, and — the part that matters — it
# returns a status code per path, so a 403 or a dead socket can be wrong out loud.
# That is a TRANSPORT guarantee and it is the limit of what it buys: measured
# 2026-07-22, this Varnish answers 200 to a PURGE of a path that does not exist
# (GET of the same path: 404). See the note at the status comparison below. The
# purge cannot confirm itself; scripts/verify-edge.sh confirms it on content.
#
# THE RULE THIS FILE IS BUILT ON
# A 200 is not success. An exit code is not success. Success is a claim read out
# of the response body, or a status code compared against an expected one. If a
# step cannot fail, it is not a check; it is decoration. Every checkmark printed
# below is downstream of a comparison that has been PROVEN to go red — see
# scripts/test-cache-purge.sh.
#
# DO NOT "JUST ADD -f" — this is the wrong lesson and it is the tempting one.
# The defect above was never an UNFAILABLE check. It was an UNREAD one: the
# result went to /dev/null and the checkmark below it was an unconditional
# printf, so no flag on the curl line could have changed the verdict. -f only
# promotes a bad STATUS into a bad exit code; it cannot see a 200 carrying
# {"success":false}, which is exactly how the Cloudflare step passed with a
# permission-less token. Adding -f to the old lines would have fixed the
# Varnish case by luck (403) and left the Cloudflare case broken, while making
# both look reviewed. The fix is to READ the answer and COMPARE it — -f is one
# narrow instance of that, never a substitute for it.
#
# This purges. It does NOT verify the edge — that is scripts/verify-edge.sh, and
# it is a separate file on purpose: everything here reports on our own actions,
# and self-reporting is the exact blind spot that cost six days of stale sitemap.
#
# EXIT CODES
#   0  pass — every purge returned a result we checked and it was the good one.
#   1  BLOCK — a purge demonstrably failed. Named, with the response.
#   2  UNKNOWN — could not run (missing env, ssh unreachable, bad arguments).
#      Not a pass. A purge that could not be attempted has not happened.
#
# Usage: bash scripts/cache-purge.sh <url-path> [<url-path> ...]
#   e.g. bash scripts/cache-purge.sh /sitemap.xml /blog/ /

set -euo pipefail

SITE_HOST="${SITE_HOST:-kilokaki.com}"

# --- Arguments ---
# Parsed before anything loads, same as deploy.sh: a bad argument costs nothing.
if [[ $# -eq 0 ]]; then
  echo "UNKNOWN: no paths given. Nothing to purge." >&2
  echo "Usage: bash scripts/cache-purge.sh <url-path> [<url-path> ...]" >&2
  echo "A purge of zero paths would exit 0 and mean nothing." >&2
  exit 2
fi

# Every path is checked against a strict allow-list of characters BEFORE it is
# interpolated into a remote shell command. These come from our own file list
# today, but "the input is trusted" is a property of today's caller, not of this
# script — and a filename with a backtick in it would run on production.
for p in "$@"; do
  if [[ ! "$p" =~ ^/[A-Za-z0-9._~/-]*$ ]]; then
    echo "UNKNOWN: refusing to purge a path I cannot safely quote: '$p'" >&2
    echo "Allowed: leading / then [A-Za-z0-9._~/-] only." >&2
    exit 2
  fi
done

# --- Secrets ---
ENV_FILE="${KILOKAKI_DEPLOY_ENV:-${HOME}/.config/kilokaki-site/deploy.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "UNKNOWN: deploy env not found: $ENV_FILE" >&2
  exit 2
fi
# shellcheck source=/dev/null
source "$ENV_FILE"
export SSHPASS

for var in SSHPASS CF_ZONE_ID CF_API_TOKEN REMOTE_USER REMOTE_HOST; do
  if [[ -z "${!var:-}" ]]; then
    echo "UNKNOWN: $var missing from $ENV_FILE — cannot purge." >&2
    exit 2
  fi
done

SSH_CMD=(sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15)

# ---------------------------------------------------------------------------
# Cloudflare
# ---------------------------------------------------------------------------
# -f so a 4xx/5xx is a non-zero exit, AND a body assertion so a 200 that says
# {"success":false} is a failure too. Cloudflare returns exactly that for a
# token that authenticates but lacks Zone.Cache Purge — the single most likely
# real-world breakage, and the one -f alone sails straight past.
purge_cloudflare() {
  echo "→ Cloudflare: purging zone cache..."

  local body rc=0
  body=$(curl -sS -f -X POST \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"purge_everything":true}' 2>&1) || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "" >&2
    echo "BLOCK: Cloudflare purge request failed (curl exit $rc)." >&2
    echo "--- response ---" >&2
    printf '%s\n' "$body" >&2
    return 1
  fi

  # THE ASSERTION. Not the exit code — the claim in the body.
  if [[ "$body" != *'"success":true'* ]]; then
    echo "" >&2
    echo "BLOCK: Cloudflare returned HTTP success but did not report success:true." >&2
    echo "A 200 is not a purge. This is the case -f cannot see." >&2
    echo "--- response ---" >&2
    printf '%s\n' "$body" >&2
    return 1
  fi

  echo "✓ Cloudflare: purge_everything acknowledged (success:true in body)."
  return 0
}

# ---------------------------------------------------------------------------
# Varnish
# ---------------------------------------------------------------------------
# One SSH round trip, N purges, one status code per path echoed back. Parsed
# here rather than trusted: the remote loop cannot fail the deploy on its own,
# so the verdict has to be computed on this side of the connection.
purge_varnish() {
  echo "→ Varnish: targeted PURGE for ${#PURGE_PATHS[@]} path(s) via ${REMOTE_HOST}..."

  local remote_script='set -u; for p in'
  for p in "${PURGE_PATHS[@]}"; do
    remote_script+=" '${p}'"
  done
  # %{http_code} per path, prefixed so a chatty shell profile cannot be mistaken
  # for a result line. Trailing "END" proves the loop ran to completion — without
  # it, an SSH cut mid-loop looks identical to a short path list.
  remote_script+='; do code=$(curl -s -o /dev/null -w "%{http_code}" -X PURGE'
  remote_script+=" -H \"Host: ${SITE_HOST}\" \"http://127.0.0.1\${p}\" || echo 000);"
  remote_script+=' printf "PURGE\t%s\t%s\n" "$p" "$code"; done; echo "PURGE-END"'

  local out rc=0
  out=$("${SSH_CMD[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "$remote_script" 2>&1) || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "" >&2
    echo "UNKNOWN: could not reach ${REMOTE_HOST} to purge Varnish (ssh exit $rc)." >&2
    echo "Nothing was purged. That is not the same as nothing needing a purge." >&2
    echo "--- output ---" >&2
    printf '%s\n' "$out" >&2
    return 2
  fi

  if [[ "$out" != *"PURGE-END"* ]]; then
    echo "" >&2
    echo "UNKNOWN: the remote purge loop did not run to completion." >&2
    echo "No PURGE-END marker. A truncated loop reports fewer failures, not fewer." >&2
    echo "--- output ---" >&2
    printf '%s\n' "$out" >&2
    return 2
  fi

  local -a bad=() seen=()
  local line path code
  while IFS= read -r line; do
    [[ "$line" == PURGE$'\t'* ]] || continue
    path="${line#PURGE$'\t'}"
    code="${path##*$'\t'}"
    path="${path%$'\t'*}"
    seen+=("$path")
    # READ WHAT THIS DOES AND DOES NOT PROVE. MEASURED 2026-07-22, live host:
    #     PURGE /this-path-does-not-exist-mochi-probe-7f3a  -> 200
    #     GET   /this-path-does-not-exist-mochi-probe-7f3a  -> 404
    # Varnish returns a synthetic 200 for purging a path that does not exist and
    # was never cacheable. So this comparison is a TRANSPORT check: 200/204 means
    # the request reached Varnish and the PURGE ACL did not reject it. It says
    # nothing whatsoever about whether an object was evicted.
    # Keep it — a 403 (ACL) or 000 (no answer) is a real, actionable failure and
    # this is the only place that catches them. But it must never be the
    # post-deploy acceptance check. Asserting on it would be the fake
    # `✓ Varnish restarted.` in better clothes: a status code that cannot say no.
    # Cache state is decided by scripts/verify-edge.sh, downstream, on content.
    if [[ "$code" != "200" && "$code" != "204" ]]; then
      bad+=("$path -> HTTP $code")
    fi
  done <<< "$out"

  # A result line per path, or we are reading someone else's output.
  if [[ ${#seen[@]} -ne ${#PURGE_PATHS[@]} ]]; then
    echo "" >&2
    echo "UNKNOWN: asked for ${#PURGE_PATHS[@]} purge(s), got ${#seen[@]} result line(s)." >&2
    echo "--- output ---" >&2
    printf '%s\n' "$out" >&2
    return 2
  fi

  if [[ ${#bad[@]} -gt 0 ]]; then
    echo "" >&2
    echo "BLOCK: ${#bad[@]} of ${#PURGE_PATHS[@]} Varnish purge(s) did not return 200/204:" >&2
    printf '    %s\n' "${bad[@]}" >&2
    echo "" >&2
    echo "The edge is still holding the old copy of those paths." >&2
    return 1
  fi

  echo "✓ Varnish: ${#seen[@]}/${#PURGE_PATHS[@]} path(s) purged, all 200/204."
  return 0
}

# ---------------------------------------------------------------------------
# Fallback: full Varnish restart via the REAL Cloudways API
# ---------------------------------------------------------------------------
# Not wired into the happy path. It is here so the runbook's "restart via the
# dashboard or API" has a correct implementation to point at instead of the
# public/v1 one that never worked.
#
# It refuses rather than pretends. The Cloudways API is OAuth: you POST email +
# api_key to /api/v1/oauth/access_token, get a bearer, and only then call
# /api/v1/service/state. `~/.config/kilokaki-site/deploy.env` holds CW_API_TOKEN
# but NO CW_EMAIL, so that exchange cannot be performed with today's config.
# Saying so is the whole point: the step it replaces printed a checkmark in
# exactly this situation.
restart_varnish_fallback() {
  echo "→ Varnish: full restart via Cloudways api/v1 (fallback)..."

  if [[ -z "${CW_EMAIL:-}" || -z "${CW_API_TOKEN:-}" || -z "${CW_SERVER_ID:-}" ]]; then
    echo "" >&2
    echo "UNKNOWN: cannot restart Varnish — the Cloudways API is not configured." >&2
    echo "  /api/v1/oauth/access_token needs CW_EMAIL + CW_API_TOKEN (the api key)." >&2
    echo "  CW_EMAIL is absent from ${ENV_FILE}." >&2
    echo "Refusing to print a checkmark for a call I cannot authenticate." >&2
    return 2
  fi

  local tok_body rc=0
  tok_body=$(curl -sS -f -X POST "https://api.cloudways.com/api/v1/oauth/access_token" \
    -d "email=${CW_EMAIL}" -d "api_key=${CW_API_TOKEN}" 2>&1) || rc=$?
  if [[ $rc -ne 0 || "$tok_body" != *'"access_token"'* ]]; then
    echo "BLOCK: Cloudways OAuth exchange failed (curl exit $rc)." >&2
    return 1
  fi
  local token
  token=$(printf '%s' "$tok_body" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [[ -n "$token" ]] || { echo "BLOCK: no access_token in the OAuth response." >&2; return 1; }

  local body
  rc=0
  body=$(curl -sS -f -X POST "https://api.cloudways.com/api/v1/service/state" \
    -H "Authorization: Bearer ${token}" \
    -d "server_id=${CW_SERVER_ID}" -d "service=varnish" -d "state=restart" 2>&1) || rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "BLOCK: Cloudways service/state restart failed (curl exit $rc)." >&2
    printf '%s\n' "$body" >&2
    return 1
  fi
  echo "✓ Varnish: restart requested via api/v1. Response: ${body}"
  return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
PURGE_PATHS=("$@")

if [[ "${CACHE_PURGE_FALLBACK_RESTART:-false}" == "true" ]]; then
  restart_varnish_fallback
  exit $?
fi

cf_rc=0
purge_cloudflare || cf_rc=$?

va_rc=0
purge_varnish || va_rc=$?

# Worst result wins, and BLOCK beats UNKNOWN: a purge we know failed is a
# stronger statement than one we could not attempt.
if [[ $cf_rc -eq 1 || $va_rc -eq 1 ]]; then
  echo "" >&2
  echo "ABORT: cache purge failed. The edge may still be serving the old copy." >&2
  exit 1
fi
if [[ $cf_rc -ne 0 || $va_rc -ne 0 ]]; then
  echo "" >&2
  echo "ABORT: cache purge could not be completed (UNKNOWN). Not a pass." >&2
  exit 2
fi

echo "✓ Caches purged: Cloudflare zone + ${#PURGE_PATHS[@]} targeted Varnish path(s)."
exit 0
