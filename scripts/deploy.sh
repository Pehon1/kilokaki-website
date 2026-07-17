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

drift_guard

# --check stops here: the guard is the thing under test, and it must be
# exercisable without deploying. --dry-run exits before the guard, so it
# never tested it.
if $CHECK_ONLY; then
  echo "[--check] Guard passed. Nothing was deployed."
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

# --- Purge Cloudflare cache ---
echo "→ Purging Cloudflare cache..."
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"purge_everything":true}' > /dev/null
echo "✓ Cloudflare cache purged."

# --- Restart Varnish (CF purge does NOT clear Varnish — blog index is Varnish-cached) ---
echo "→ Restarting Varnish cache..."
curl -s -X POST "https://api.cloudways.com/public/v1/service/${CW_SERVER_ID}/${CW_APP_ID}/restart" \
  -H "Authorization: Bearer ${CW_API_TOKEN}" \
  -H "Content-Type: application/json" > /dev/null
sleep 5
echo "✓ Varnish restarted."

# --- Health check ---
echo ""
echo "→ Checking site..."
sleep 3
STATUS=$(curl -sI "https://kilokaki.com" | head -1)
echo "  https://kilokaki.com → $STATUS"

STATUS_BLOG=$(curl -sI "https://kilokaki.com/blog/" | head -1)
echo "  https://kilokaki.com/blog/ → $STATUS_BLOG"

STATUS_HT=$(curl -sI "https://kilokaki.com/how-to/" | head -1)
echo "  https://kilokaki.com/how-to/ → $STATUS_HT"

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
