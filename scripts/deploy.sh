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
case "${1:-}" in
  "")        ;;
  --dry-run) DRY_RUN=true ;;
  --check)   CHECK_ONLY=true ;;
  *)
    echo "ERROR: unknown argument: $1" >&2
    echo "Usage: bash scripts/deploy.sh [--dry-run|--check]" >&2
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
gate_rc=0
bash "${SCRIPT_DIR}/content-gate.sh" "$SRC_DIR" || gate_rc=$?
if [[ $gate_rc -ne 0 ]]; then
  echo "" >&2
  echo "ABORT: content gate exit $gate_rc. Nothing was deployed." >&2
  exit 1
fi

drift_guard

# --- Sitemap staleness guard ---
# gen-sitemap.py grew a --check mode ("exit 1 if sitemap.xml is stale, write
# nothing") and then had NO caller anywhere: not here, not in crontab, not in a
# LaunchAgent, not in any other workspace. Grepped 2026-07-22. A check nothing
# runs is a check that does not exist — the same defect class as a purge whose
# result goes to /dev/null. This is its caller.
echo "→ Checking sitemap.xml is current with the tree..."
sitemap_rc=0
python3 "${SCRIPT_DIR}/gen-sitemap.py" --check || sitemap_rc=$?
if [[ $sitemap_rc -ne 0 ]]; then
  echo "" >&2
  echo "ABORT: sitemap.xml is stale (gen-sitemap.py --check exit $sitemap_rc)." >&2
  echo "  Run: python3 scripts/gen-sitemap.py   then review and commit the result." >&2
  echo "  Nothing was deployed." >&2
  exit 1
fi
echo "✓ sitemap.xml matches the tree."

# --check stops here: the guards are the thing under test, and they must be
# exercisable without deploying. --dry-run exits before them, so it never
# tested either one.
if $CHECK_ONLY; then
  echo "[--check] Guards passed. Nothing was deployed."
  exit 0
fi

# --- Upload recursively via rsync + sshpass ---
echo "→ Uploading files (recursive)..."
rsync -avz --delete \
  "${RSYNC_FILTER[@]}" \
  -e "$SSH_CMD" \
  "$SRC_DIR/" \
  "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PUBLIC_HTML}/"

echo "✓ Files uploaded."

# --- Fix permissions: 644 for files, 755 for dirs ---
echo "→ Fixing permissions (644 files, 755 dirs)..."
sshpass -e ssh -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" \
  "find ${REMOTE_PUBLIC_HTML} -type f -exec chmod 644 {} \; && find ${REMOTE_PUBLIC_HTML} -type d -exec chmod 755 {} \;"

echo "✓ Permissions fixed."

# --- Purge the caches, and read the answers ---
# Replaces two curl calls that piped their results to /dev/null and printed a
# checkmark unconditionally. Both were structurally incapable of failing; on
# 2026-07-22 they printed green while the edge served a six-day-old sitemap.
# cache-purge.sh exits 0 pass / 1 BLOCK / 2 UNKNOWN, and every checkmark it
# prints is downstream of a comparison proven to go red (test-cache-purge.sh).
CACHE_PATHS=(/sitemap.xml / /blog/ /how-to/)
purge_rc=0
bash "${SCRIPT_DIR}/cache-purge.sh" "${CACHE_PATHS[@]}" || purge_rc=$?
if [[ $purge_rc -ne 0 ]]; then
  echo "" >&2
  echo "FILES ARE UPLOADED, CACHES ARE NOT CONFIRMED PURGED (exit $purge_rc)." >&2
  echo "  The origin has the new bytes; the edge may still be serving old ones." >&2
  echo "  Do NOT declare this deploy done. Resolve the purge, then run:" >&2
  echo "    bash scripts/cache-purge.sh ${CACHE_PATHS[*]}" >&2
  echo "    bash scripts/verify-edge.sh ${CACHE_PATHS[*]}" >&2
  exit 1
fi

# --- Acceptance check: ask the EDGE, not ourselves ---
# The old health check was `curl -sI ... | head -1` on three paths. All three
# returned 200 through the entire stale-sitemap window, because a stale object
# is still a 200. Every other signal in this script reports on an action this
# script performed; this is the only one that does not.
echo ""
sleep 3
verify_rc=0
bash "${SCRIPT_DIR}/verify-edge.sh" "${CACHE_PATHS[@]}" || verify_rc=$?
if [[ $verify_rc -ne 0 ]]; then
  echo "" >&2
  echo "DEPLOY NOT VERIFIED (verify-edge.sh exit $verify_rc)." >&2
  if [[ $verify_rc -eq 1 ]]; then
    echo "  The edge is serving something other than the tree that was just shipped." >&2
  else
    echo "  The edge could not be checked. That is not the same as it being fine." >&2
  fi
  exit 1
fi

echo ""
echo "✓ Done! — files uploaded, caches purged (checked), edge serving this tree (checked)."

# --- Post-deploy ---
# The old text here told the operator to curl-verify their slug by hand, and
# asserted "CF purge + Varnish restart = origin correct + CDN correct". That
# equation is what failed on 2026-07-22: both steps "succeeded" and the CDN was
# wrong. verify-edge.sh above now does the check that sentence was asking a
# human to remember, on the paths this deploy actually touched.
echo ""
echo "Verified above: ${CACHE_PATHS[*]}"
echo "Shipped a new blog/how-to page? It is only covered if its path is in that"
echo "list. Check it explicitly:"
echo "    bash scripts/verify-edge.sh /blog/your-slug/"
echo ""
echo "Troubleshooting:"
echo "  403 on homepage?       → chmod fix above + check index.php.bak exists"
echo "  403 on /blog/ or /how-to/? → dirs got 700 from rsync — run: sshpass -e ssh ${REMOTE_USER}@${REMOTE_HOST} 'find ${REMOTE_PUBLIC_HTML} -type d -exec chmod 755 {} \;'"
echo "  verify-edge BLOCK on one path? → that path is still cached somewhere the"
echo "    targeted PURGE did not reach. Re-run cache-purge.sh for it, then"
echo "    verify-edge.sh again. If it persists, restart Varnish from the"
echo "    Cloudways dashboard (the API fallback needs CW_EMAIL, absent today)."
