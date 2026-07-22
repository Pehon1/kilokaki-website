#!/usr/bin/env bash
# deploy.sh — Deploy KiloKaki landing page to Cloudways via rsync + SSH
#
# This is the ONLY copy. It lives in the repo, next to what it deploys.
# Per-workspace copies under skills/kilokaki-landing-page/scripts/ are thin
# wrappers that exec this file. Do not fork it again: three copies drifted for
# ten weeks and cost two false P1 alarms on 2026-07-17.
#
# Cloudways app/server ids, host, user and paths are NOT in this file:
# this repo is public. They load from the deploy env alongside the secrets.
#
# This script uses rsync for RECURSIVE directory upload — it handles subdirectories
# like blog/ automatically. Do NOT use plain sftp put for individual top-level files.
#
# Usage: bash scripts/deploy.sh [--dry-run|--check]

set -euo pipefail

# --- Arguments ---
# Parsed BEFORE secrets load or any network call, so a bad flag costs nothing.
# Previously: [[ $1 == --dry-run ]] && DRY_RUN=true -- any OTHER argument was
# silently ignored and fell through to a REAL DEPLOY. On 2026-07-17 `--check`
# (a flag that did not exist) shipped to production exactly this way.
DRY_RUN=false
CHECK_ONLY=false
VERIFY_CACHE=false
case "${1:-}" in
  "")             ;;
  --dry-run)      DRY_RUN=true ;;
  --check)        CHECK_ONLY=true ;;
  --verify-cache) VERIFY_CACHE=true ;;
  *)
    echo "ERROR: unknown argument: $1" >&2
    echo "Usage: bash scripts/deploy.sh [--dry-run|--check|--verify-cache]" >&2
    echo "Refusing to deploy on an argument I do not understand." >&2
    exit 2
    ;;
esac

# --- Secrets ---
# This repo is PUBLIC. Credentials load from a file outside the tree; nothing
# secret is ever written here. Template: scripts/deploy.env.example
ENV_FILE="${KILOKAKI_DEPLOY_ENV:-${HOME}/.config/kilokaki-site/deploy.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: deploy env not found: $ENV_FILE" >&2
  echo "Copy scripts/deploy.env.example there and fill it in (chmod 600)." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"
export SSHPASS

for var in SSHPASS CF_ZONE_ID CF_API_TOKEN CW_SERVER_ID CW_APP_ID CW_API_TOKEN \
           REMOTE_USER REMOTE_HOST REMOTE_BASE_DIR; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var missing from $ENV_FILE" >&2
    exit 1
  fi
done

# --- Config ---
# Derived from this script's own location, so the deploy always ships the tree
# it is versioned in. Previously hardcoded, which is how copies in other
# workspaces silently deployed a tree their owner could not see.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REMOTE_PUBLIC_HTML="${REMOTE_BASE_DIR}/public_html"


SSH_CMD="sshpass -e ssh -o StrictHostKeyChecking=no"

# --- What ships (allow-list) ---
# Source of truth: PUBLIC-MANIFEST.md. This replaces a deny-list: under it every
# new non-public file shipped by default and someone had to notice. Nobody
# noticed website-phase2-copy-deck.md for three months. Default is now "does not
# ship" -- if it is not listed here, it does not reach the public web root.
#
# The drift guard and the real upload MUST share this list. If they diverge, the
# guard measures a different delete-set than the deploy performs, and it lies.
#
# NOTE: --exclude PROTECTS a path from --delete; it does not remove what is
# already live. The 9 scripts/*.py and the copy deck serving 200 today need a
# one-time manual rm on prod. This list stops them coming back; it will not
# clean them, and every dry-run will report clean regardless. That is a false
# PASS with a long fuse -- see PUBLIC-MANIFEST.md.
RSYNC_FILTER=(
  # Root: the pages and assets, explicitly.
  --include='/index.html'
  --include='/about.html'
  --include='/pricing.html'
  --include='/how-to-log-food.html'
  --include='/how-to-track-meals.html'
  --include='/robots.txt'
  --include='/sitemap.xml'
  --include='/logo.png'
  --include='/og-blog-default.png'
  --include='/photo-log.png'
  # Root: web-asset types. None exist today (all styling is inline) -- these are
  # here so that adding a stylesheet tomorrow does not silently ship a broken
  # site. An allow-list that only permits what exists today drops the next thing
  # someone adds, and the guard cannot warn: excluded paths are invisible to it.
  --include='/*.css'
  --include='/*.js'
  --include='/*.svg'
  --include='/*.ico'
  --include='/*.webp'
  --include='/*.jpg'
  --include='/*.jpeg'
  --include='/*.woff'
  --include='/*.woff2'
  --include='/*.ttf'
  # Content trees, web assets only. Never '**' -- that would ship a stray .md
  # or .py dropped into blog/, which is the deny-list failure this replaces.
  --include='/blog/'
  --include='/how-to/'
  --include='/mini/'
  --include='/blog/*.html'
  --include='/blog/*.png'
  --include='/blog/*.jpg'
  --include='/blog/*.jpeg'
  --include='/blog/*.webp'
  --include='/blog/*.svg'
  --include='/blog/*.css'
  --include='/blog/*.js'
  --include='/how-to/*.html'
  --include='/how-to/*.png'
  --include='/how-to/*.jpg'
  --include='/how-to/*.css'
  --include='/how-to/*.js'
  --include='/mini/*.html'
  --include='/mini/*.png'
  --include='/mini/*.css'
  --include='/mini/*.js'
  --exclude='*'
)

# --- Drift guard ---
# rsync --delete assumes the repo is authoritative for production. It isn't:
# content has been authored directly on prod with no source in any workspace, and
# a routine deploy would have destroyed the only copy. Enumerate what --delete
# would remove; if production holds anything the repo doesn't, stop and make a
# human look. Fails closed — if the check cannot run, nothing deploys.
drift_guard() {
  echo "→ Drift guard: enumerating what --delete would remove from production..."

  local out
  local rc=0
  out=$(rsync -azn --delete --itemize-changes \
    "${RSYNC_FILTER[@]}" \
    -e "$SSH_CMD" \
    "$SRC_DIR/" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PUBLIC_HTML}/" 2>&1) || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "" >&2
    echo "ABORT: the drift guard could not run (rsync exit $rc)." >&2
    echo "A guard that cannot check is not a guard that passes. Nothing was deployed." >&2
    echo "--- rsync output ---" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi

  local doomed
  doomed=$(printf '%s\n' "$out" | grep '^\*deleting' | sed 's/^\*deleting[[:space:]]*//' || true)

  if [[ -n "$doomed" ]]; then
    echo "" >&2
    echo "ABORT: production holds files this repo does not." >&2
    echo "Deploying would PERMANENTLY DELETE the following from ${REMOTE_HOST}:" >&2
    echo "" >&2
    printf '%s\n' "$doomed" | sed 's/^/    /' >&2
    echo "" >&2
    echo "  $(printf '%s\n' "$doomed" | grep -c .) path(s) exist only on production." >&2
    echo "" >&2
    echo "Nothing was deployed and nothing was deleted." >&2
    echo "Get these into the repo (or add an --exclude) before deploying." >&2
    echo "Do NOT --force past this: production may hold the only copy." >&2
    exit 1
  fi

  echo "✓ Drift guard: production holds nothing the repo is missing."
}

# --- Validate ---
if [[ ! -d "$SRC_DIR" ]]; then
  echo "ERROR: Source directory not found: $SRC_DIR"
  exit 1
fi

if [[ ! -f "$SRC_DIR/index.html" ]]; then
  echo "ERROR: index.html not found in $SRC_DIR"
  exit 1
fi

echo "→ Deploying $SRC_DIR to $REMOTE_HOST:$REMOTE_PUBLIC_HTML"

if ! command -v rsync &>/dev/null; then
  echo "ERROR: rsync not installed. Install with: brew install rsync"
  exit 1
fi

# --dry-run shares the same -e "$SSH_CMD" transport as the real upload. The
# May 3 copy omitted it here, fell back to plain ssh, found no TTY, and printed
# "Permission denied" — which read as rotated credentials and burned an hour.
if $DRY_RUN; then
  echo "[DRY RUN] Would sync:"
  rsync -avzn --delete \
    "${RSYNC_FILTER[@]}" \
    -e "$SSH_CMD" \
    "$SRC_DIR/" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PUBLIC_HTML}/"
  exit 0
fi

# --- Content gate ---
# Runs BEFORE the drift guard: it is cheaper, and it answers a prior question.
# The drift guard asks "what would --delete remove that only production has?".
# The content gate asks "does origin hold shippable work this tree is missing?".
# Both fail closed. Exit 2 (UNKNOWN) is not a pass -- see content-gate.sh.
#
# This replaces a rule that lived as prose in an agent memory file and therefore
# only ran when someone remembered it. It also replaces the wrong measurement:
# `git log origin/main..HEAD` counts COMMITS, and on 2026-07-22 a diverged branch
# made it over-report a change origin already had. It never went red, it went
# verbose -- and a guard that over-reports reads as a conservative one.
if ! $VERIFY_CACHE; then
  gate_rc=0
  bash "${SCRIPT_DIR}/content-gate.sh" "$SRC_DIR" || gate_rc=$?
  if [[ $gate_rc -ne 0 ]]; then
    echo "" >&2
    echo "ABORT: content gate exit $gate_rc. Nothing was deployed." >&2
    exit 1
  fi

  drift_guard
fi

# --check stops here: the guards are the thing under test, and they must be
# exercisable without deploying. --dry-run exits before them, so it never
# tested either one.
if $CHECK_ONLY; then
  echo "[--check] Guards passed. Nothing was deployed."
  exit 0
fi

# --- Upload recursively via rsync + sshpass ---
# Output is captured, not streamed, so the cache stage can purge exactly what
# changed instead of guessing. A blanket purge hides which object failed to turn
# over; a targeted one names it. --itemize-changes is the source of that list.
CHANGED_FILES=()

if $VERIFY_CACHE; then
  echo "[--verify-cache] Skipping upload. Purging and verifying the edge against"
  echo "[--verify-cache] this working tree as it stands."
else
  echo "→ Uploading files (recursive)..."
  upload_out=""
  upload_rc=0
  upload_out=$(rsync -avz --delete --itemize-changes \
    "${RSYNC_FILTER[@]}" \
    -e "$SSH_CMD" \
    "$SRC_DIR/" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PUBLIC_HTML}/" 2>&1) || upload_rc=$?

  printf '%s\n' "$upload_out"

  if [[ $upload_rc -ne 0 ]]; then
    echo "" >&2
    echo "ABORT: upload failed (rsync exit $upload_rc). Nothing was purged." >&2
    exit 1
  fi

  # '>f' = a file was transferred to the remote. Directory and permission-only
  # lines are not content changes and must not enter the purge set.
  while IFS= read -r line; do
    [[ -n "$line" ]] && CHANGED_FILES+=("$line")
  done < <(printf '%s\n' "$upload_out" | sed -n 's/^>f[^ ]* //p')

  echo "✓ Files uploaded (${#CHANGED_FILES[@]} changed)."

  # --- Fix permissions: 644 for files, 755 for dirs ---
  echo "→ Fixing permissions (644 files, 755 dirs)..."
  sshpass -e ssh -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" \
    "find ${REMOTE_PUBLIC_HTML} -type f -exec chmod 644 {} \; && find ${REMOTE_PUBLIC_HTML} -type d -exec chmod 755 {} \;"

  echo "✓ Permissions fixed."
fi

# =============================================================================
# Cache turnover
# =============================================================================
# On 2026-07-22 this stage printed "✓ Cloudflare cache purged." and "✓ Varnish
# restarted.", exited 0, and passed three health checks while the edge served a
# six-day-old sitemap. `age` climbed 4206 -> 4255 across the deploy — exactly the
# elapsed wall-clock, i.e. the same cached object, never turned over. The files
# had landed. Only the cache layer failed, and it was the one layer whose success
# indicator was decorative.
#
# Two defects, both now fixed here:
#   1. The Varnish call POSTed to api.cloudways.com/public/v1/... . `public/v1`
#      is not the API. It answers *any* path, unauthenticated, and a GET to it
#      returns 200 "You have reached Cloudways API." Varnish was never once
#      restarted by this script.
#   2. Both cache calls were `curl -s ... > /dev/null` with no -f, each followed
#      by an unconditional `echo "✓ ..."`. The exit status was never read and the
#      body was discarded, so `set -euo pipefail` had nothing to catch.
#
# TWO INDEPENDENT LAYERS BELOW. Neither is sufficient alone, and the reason is
# the whole point of this rewrite:
#
#   Layer A — transport. Did the call actually reach the thing and succeed?
#       Catches a broken endpoint, wrong host, dead credentials. Does NOT catch
#       a purge that succeeded against the wrong object.
#   Layer B — content discriminator. Does the live edge now serve what the repo
#       holds? Catches non-turnover regardless of what Layer A reported. Does NOT
#       catch a broken purge when the cache happened to be fresh already.
#
# Layer A alone is what we had. Layer B alone would let a permanently broken
# purge sit undetected until the day it mattered.
#
# WHY THE PURGE STATUS CODE IS NOT A CHECK — measured 2026-07-22, and this is the
# trap the obvious fix falls into:
#       PURGE /sitemap.xml             -> 200
#       PURGE /nonexistent-xyzzy-probe -> 200
# Varnish returns 200 for a path that does not exist. "Assert the PURGE returned
# 200" is therefore the same decorative indicator this commit removes, wearing a
# status check as a costume. A typo'd path, a wrong Host: header and a renamed
# post all score green. Layer B exists because Layer A cannot be trusted here.

# Override only to prove the guard goes red. Not for normal deploys.
CACHE_ORIGIN="${VARNISH_PURGE_ORIGIN:-http://127.0.0.1}"
SITE_HOST="kilokaki.com"

# Cloudflare rewrites mailto: links (email obfuscation) and injects a decode
# script, so live bytes never equal repo bytes on any page with an email in it.
# A raw hash would be permanently red on index.html and would be deleted within a
# week for crying wolf. Normalise both sides through the same filter instead.
cf_normalize() {
  sed -E \
    -e 's#<script[^>]*data-cfasync="false"[^>]*></script>##g' \
    -e 's#<a href="/cdn-cgi/l/email-protection[^"]*"><span[^>]*>[^<]*</span></a>#@EMAIL@#g' \
    -e 's#<a href="mailto:[^"]*">[^<]*</a>#@EMAIL@#g'
}

# --- Fallback: restart the Varnish service via the REAL Cloudways API ---------
# Only invoked when the targeted PURGE path has already failed. This is the call
# the old code was *trying* to make and never did:
#   POST api/v1/oauth/access_token  (email + api_key) -> access_token
#   POST api/v1/service/state       (Bearer, server_id, service=varnish, state=restart)
# Note `api/v1`, not `public/v1`.
#
# CW_EMAIL is not in deploy.env today, so this will usually announce that it
# cannot run. That is deliberate and it is the point: it says so and changes
# nothing about the exit code. A fallback that silently no-ops is the same bug
# this commit exists to remove, one layer further down.
varnish_restart_fallback() {
  echo "" >&2
  echo "→ Fallback: attempting Varnish service restart via Cloudways API..." >&2

  if [[ -z "${CW_EMAIL:-}" ]]; then
    echo "  SKIPPED: CW_EMAIL is not set in the deploy env." >&2
    echo "  The service-state fallback cannot authenticate without it." >&2
    echo "  Add CW_EMAIL (the Cloudways account email) to \$ENV_FILE to enable it." >&2
    echo "  Meanwhile: restart Varnish from the Cloudways dashboard, then re-run" >&2
    echo "  this script to re-verify. The deploy still fails below." >&2
    return 1
  fi

  local tok_resp tok
  tok_resp=$(curl -s --max-time 30 -X POST \
    "https://api.cloudways.com/api/v1/oauth/access_token" \
    -d "email=${CW_EMAIL}" -d "api_key=${CW_API_TOKEN}") || {
      echo "  Token request transport failure." >&2; return 1; }

  tok=$(printf '%s' "$tok_resp" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [[ -z "$tok" ]]; then
    echo "  Could not obtain an access token. Response:" >&2
    printf '    %s\n' "$tok_resp" >&2
    return 1
  fi

  local st_resp st_code
  st_resp=$(curl -s --max-time 60 -w '\n%{http_code}' -X POST \
    "https://api.cloudways.com/api/v1/service/state" \
    -H "Authorization: Bearer ${tok}" \
    -d "server_id=${CW_SERVER_ID}" \
    -d "service=varnish" \
    -d "state=restart") || { echo "  service/state transport failure." >&2; return 1; }
  st_code=$(printf '%s' "$st_resp" | tail -n1)

  if [[ "$st_code" != "200" ]]; then
    echo "  service/state returned HTTP $st_code:" >&2
    printf '    %s\n' "$(printf '%s' "$st_resp" | sed '$d')" >&2
    return 1
  fi

  echo "  Varnish service restart accepted (HTTP 200). Re-run to re-verify." >&2
  return 0
}

# Map a public URL path back to the repo file that should be serving it.
# Echoes nothing when the URL has no repo artifact (e.g. an image) — such paths
# get purged but cannot be content-verified, and are reported as such.
repo_file_for_url() {
  local url="$1" f
  case "$url" in
    /)       f="index.html" ;;
    */)      f="${url#/}index.html" ;;
    *)       f="${url#/}" ;;
  esac
  [[ -f "$SRC_DIR/$f" ]] && printf '%s' "$SRC_DIR/$f"
}

# --- Build the purge set -----------------------------------------------------
# Always-purge: the index pages a new post mutates without touching their own
# file on disk. rsync cannot see these change, which is precisely how the blog
# index went stale while every changed file it listed was uploaded correctly.
PURGE_PATHS=("/" "/blog/" "/how-to/" "/sitemap.xml")
for f in ${CHANGED_FILES+"${CHANGED_FILES[@]}"}; do
  PURGE_PATHS+=("/$f")
  [[ "$f" == "index.html" ]] && PURGE_PATHS+=("/")
done
# Dedup, preserve order. NOT `mapfile` — macOS ships bash 3.2, which does not
# have it, and the failure mode is `mapfile: command not found` mid-deploy with
# the files already uploaded and the cache untouched.
_dedup=()
while IFS= read -r _p; do
  [[ -n "$_p" ]] && _dedup+=("$_p")
done < <(printf '%s\n' "${PURGE_PATHS[@]}" | awk '!seen[$0]++')
PURGE_PATHS=(${_dedup+"${_dedup[@]}"})

# --- Layer A.1: Cloudflare purge --------------------------------------------
echo "→ Purging Cloudflare cache..."
cf_rc=0
cf_resp=$(curl -s -w '\n%{http_code}' -X POST \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"purge_everything":true}') || cf_rc=$?
cf_code=$(printf '%s' "$cf_resp" | tail -n1)
cf_body=$(printf '%s' "$cf_resp" | sed '$d')

if [[ $cf_rc -ne 0 ]]; then
  echo "ABORT: Cloudflare purge transport failed (curl exit $cf_rc)." >&2
  exit 1
fi
if [[ "$cf_code" != "200" ]] || [[ "$cf_body" != *'"success":true'* ]]; then
  echo "ABORT: Cloudflare purge did not succeed (HTTP $cf_code)." >&2
  echo "--- response ---" >&2
  printf '%s\n' "$cf_body" >&2
  exit 1
fi
echo "✓ Cloudflare purge accepted (HTTP 200, success:true)."

# --- Layer A.2: targeted Varnish PURGE over SSH ------------------------------
# The default path. This is what actually fixed production on 2026-07-22, and it
# is far less disruptive than bouncing the service. Only curl's *exit status* is
# read here, never its HTTP code — see the note above on why 200 means nothing.
echo "→ Purging Varnish (${#PURGE_PATHS[@]} paths, targeted)..."
purge_args=""
for p in "${PURGE_PATHS[@]}"; do purge_args+=" $(printf '%q' "$p")"; done

purge_rc=0
purge_out=$(sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 \
  "${REMOTE_USER}@${REMOTE_HOST}" \
  "rc=0; for p in${purge_args}; do \
     if code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
                 -X PURGE -H 'Host: ${SITE_HOST}' \"${CACHE_ORIGIN}\$p\"); then \
       echo \"  purge \$code \$p\"; \
     else \
       echo \"  purge TRANSPORT-FAIL \$p\" >&2; rc=1; \
     fi; \
   done; exit \$rc" 2>&1) || purge_rc=$?

printf '%s\n' "$purge_out" | grep -v 'post-quantum\|store now, decrypt later\|openssh.com/pq\|^\*\*' || true

if [[ $purge_rc -ne 0 ]]; then
  echo "" >&2
  echo "ABORT: Varnish PURGE failed to reach the cache (exit $purge_rc)." >&2
  echo "Origin files are uploaded but the cache layer was not turned over." >&2
  varnish_restart_fallback || true
  exit 1
fi
echo "✓ Varnish PURGE delivered to all ${#PURGE_PATHS[@]} paths."

# --- Layer B: content discriminator at the edge ------------------------------
# The only check that would have caught 2026-07-22. Compare what the edge serves
# against what the repo holds — a discriminator, not a status line.
echo ""
echo "→ Verifying the edge serves the repo (content, not status)..."
sleep 3

verify_failures=()
verify_checked=0
verify_skipped=()

for url in "${PURGE_PATHS[@]}"; do
  repo_f=$(repo_file_for_url "$url")
  if [[ -z "$repo_f" ]]; then
    verify_skipped+=("$url")
    continue
  fi

  live_rc=0
  live_body=$(curl -s --max-time 20 -w '\n%{http_code}' "https://${SITE_HOST}${url}") || live_rc=$?
  live_code=$(printf '%s' "$live_body" | tail -n1)
  live_body=$(printf '%s' "$live_body" | sed '$d')

  if [[ $live_rc -ne 0 ]] || [[ "$live_code" != "200" ]]; then
    verify_failures+=("$url — HTTP $live_code (curl exit $live_rc)")
    continue
  fi

  # BOTH sides go through $(...) before hashing. Command substitution strips
  # trailing newlines, and it already stripped them from $live_body above. Hash
  # the repo side straight from the file and every page with a trailing newline
  # — i.e. every page — compares unequal, on every deploy, forever. That guard
  # gets switched off within a week and we are back to a decorative checkmark.
  # Caught by the red proof on 2026-07-22, which is what red proofs are for.
  live_sum=$(printf '%s' "$(printf '%s' "$live_body" | cf_normalize)" | shasum -a 256 | cut -d' ' -f1)
  repo_sum=$(printf '%s' "$(cf_normalize < "$repo_f")" | shasum -a 256 | cut -d' ' -f1)
  verify_checked=$((verify_checked + 1))

  if [[ "$live_sum" == "$repo_sum" ]]; then
    echo "  ✓ $url matches repo"
  else
    verify_failures+=("$url — live ${live_sum:0:12} != repo ${repo_sum:0:12} ($(basename "$repo_f"))")
    echo "  ✗ $url STALE — live ${live_sum:0:12} != repo ${repo_sum:0:12}"
  fi
done

# The sitemap discriminator called out in the spec: the 93-vs-94 <loc> delta is
# the only reason the 07-22 incident was caught at all. Kept explicit because it
# names the failure in a unit a human reads at a glance.
if [[ -f "$SRC_DIR/sitemap.xml" ]]; then
  live_loc=$(curl -s --max-time 20 "https://${SITE_HOST}/sitemap.xml" | grep -c '<loc>' || true)
  repo_loc=$(grep -c '<loc>' "$SRC_DIR/sitemap.xml" || true)
  echo "  sitemap <loc>: live=${live_loc} repo=${repo_loc}"
  [[ "$live_loc" != "$repo_loc" ]] && \
    verify_failures+=("/sitemap.xml — <loc> count live=${live_loc} repo=${repo_loc}")
fi

if [[ ${#verify_skipped[@]} -gt 0 ]]; then
  echo "  (${#verify_skipped[@]} purged path(s) have no repo artifact and were not content-verified:"
  printf '     %s\n' "${verify_skipped[@]}"
  echo "   purged but unverified — not a pass, just not checkable here.)"
fi

if [[ ${#verify_failures[@]} -gt 0 ]]; then
  echo "" >&2
  echo "ABORT: the edge is NOT serving this repo after purge." >&2
  echo "This is the 2026-07-22 failure mode. Origin is correct; the cache is not." >&2
  echo "" >&2
  printf '    %s\n' "${verify_failures[@]}" >&2
  echo "" >&2
  varnish_restart_fallback || true
  echo "Deploy FAILED. Files are on origin; the edge is stale. Do not report this as shipped." >&2
  exit 1
fi

echo "✓ Edge verified against repo: ${verify_checked} path(s) match, 0 stale."

echo ""
echo "✓ Done!"

# --- Post-deploy: curl-verify YOUR article slug in live blog index ---
echo ""
echo "⚠️  IMPORTANT: curl-verify the live blog index for YOUR article slug before declaring done."
echo "   CF purge + Varnish restart = origin correct + CDN correct."
echo "   Example: curl -s \"https://kilokaki.com/blog/\" | grep \"your-slug\""
echo ""
echo "⚠️  Varnish note: if blog index still stale after restart, restart via Cloudways dashboard."
echo ""
echo "Troubleshooting:"
echo "  403 on homepage?       → chmod fix above + check index.php.bak exists"
echo "  403 on /blog/ or /how-to/? → dirs got 700 from rsync — run: sshpass -e ssh ${REMOTE_USER}@${REMOTE_HOST} 'find ${REMOTE_PUBLIC_HTML} -type d -exec chmod 755 {} \;'"
echo "  Stale blog index?      → Varnish still serving old copy — restart Varnish via Cloudways dashboard or API"
