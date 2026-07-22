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

# --- Sitemap gate ---
# Runs FIRST of the three: it needs no network, so it is the cheapest, and it
# answers the most local question — "is sitemap.xml consistent with the HTML
# about to ship beside it?" The other two ask about origin and about production.
#
# This exists because `gen-sitemap.py --check` was written "for CI/cron" and then
# had no caller of any kind for its whole life. Six days of lastmod drift across
# 63 URLs surfaced on 2026-07-22 only because someone asked for a regen. The
# detector worked; nothing ran it. Fail closed: exit 1 stale, exit 2 unknown,
# both abort. See sitemap-gate.sh for why exit 1 alone is not trusted.
sitemap_rc=0
bash "${SCRIPT_DIR}/sitemap-gate.sh" || sitemap_rc=$?
if [[ $sitemap_rc -ne 0 ]]; then
  echo "" >&2
  echo "ABORT: sitemap gate exit $sitemap_rc. Nothing was deployed." >&2
  exit 1
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

# --- Sitemap staleness gate: DELIBERATELY NOT HERE ---
# This branch used to call `gen-sitemap.py --check` directly and abort on its
# exit 1. Removed 2026-07-22 by Coco's ruling: the gate lives in
# scripts/sitemap-gate.sh on branch sitemap-gate (b63dabf), which does NOT trust
# the generator's exit 1 — it distinguishes stale (1) from "could not reach a
# verdict" (2), because a generator that raises also exits 1 and my version read
# that as a clean stale-detection.
#
# DO NOT RE-ADD A CALLER HERE. Two callers is the failure mode, not two files:
# the merge of this branch and sitemap-gate is CLEAN (measured, exit 0, zero
# conflict markers) and lands BOTH gates — the rejected design survives after
# drift_guard with nothing to make a reviewer look. If you want the check, the
# answer is sitemap-gate.sh, once it merges.

# --check stops here: the guards are the thing under test, and they must be
# exercisable without deploying. --dry-run exits before them, so it never
# tested either one.
if $CHECK_ONLY; then
  echo "[--check] Guards passed. Nothing was deployed."
  exit 0
fi

# --- Upload recursively via rsync + sshpass ---
# --out-format is not cosmetic: it is the input to derive_cache_paths() below.
# Without an itemized record of what moved, the only honest purge set is a
# hand-maintained guess, which is what this replaced.
echo "→ Uploading files (recursive)..."
XFER_LOG="$(mktemp -t kk-rsync-xfer.XXXXXX)"
trap 'rm -f "$XFER_LOG"' EXIT

rsync_rc=0
rsync -avz --delete --out-format='%i %n' \
  "${RSYNC_FILTER[@]}" \
  -e "$SSH_CMD" \
  "$SRC_DIR/" \
  "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PUBLIC_HTML}/" \
  | tee "$XFER_LOG" || rsync_rc=${PIPESTATUS[0]}

if [[ $rsync_rc -ne 0 ]]; then
  echo "ABORT: rsync failed (exit $rsync_rc). Nothing further was attempted." >&2
  exit 1
fi

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
#
# THE PATH SET IS DERIVED, NOT DECLARED.
# It used to be `CACHE_PATHS=(/sitemap.xml / /blog/ /how-to/)` — a hand-kept
# list. That list covers the incident that produced it and nothing after: a
# newly-published /blog/<new-slug>/ is not in it, so Varnish keeps serving the
# 404 it cached before the post existed and verify-edge never looks. The script
# said as much in its own post-deploy text, which is honest and is not a fix.
# (Cloudflare is purge_everything, so CF was never the exposure — the exposure
# is the origin PURGE loop and the acceptance check, both of which take this
# list verbatim.)
#
# Two sets, because they answer different questions:
#   PURGE  — everything that moved, INCLUDING deletions. A deleted page is
#            exactly the object you most need evicted.
#   VERIFY — only paths that still exist in the tree. verify-edge diffs the
#            edge against a repo file; a deleted path has none, and it would
#            correctly return UNKNOWN, i.e. a red deploy for a clean delete.
# NO `mapfile` AND NO BARE `${arr[@]}` BELOW — both are bash 4 conveniences and
# macOS ships bash 3.2.57. `mapfile` is merely absent (127, loud). The empty-array
# expansion is the nasty one: under `set -u`, bash 3.2 treats `"${empty[@]}"` as
# an unbound variable and aborts — so a deploy that changed nothing would die
# AFTER uploading, before purging. Hence `${arr[@]+...}` throughout.
MAX_PATHS=40

to_url_path() {
  case "$1" in
    index.html)   printf '/' ;;
    */index.html) printf '/%s/' "${1%/index.html}" ;;
    *)            printf '/%s' "$1" ;;
  esac
}

# %i is rsync's itemized-change string. `>f`/`<f` = a file was transferred;
# `*deleting` = one was removed. Everything else — directory entries (cd/.d),
# attribute-only ticks (.f), and the summary lines — is not a cache event.
_changed=()
while IFS= read -r f; do
  [[ -n "$f" ]] && _changed+=("$f")
done < <(awk '$1 ~ /^[<>]f/ {sub(/^[^ ]+ /,""); print}' "$XFER_LOG")

_deleted=()
while IFS= read -r f; do
  [[ -n "$f" ]] && _deleted+=("$f")
done < <(awk '$1 == "*deleting" {sub(/^[^ ]+ +/,""); print}' "$XFER_LOG")

# Floor: / and /sitemap.xml are checked every run whether or not they moved.
# They are the two objects a stale edge hurts most, and verifying an unchanged
# path is a valid pass, not a false one.
_verify_raw=(/ /sitemap.xml)
for f in ${_changed[@]+"${_changed[@]}"}; do
  _verify_raw+=("$(to_url_path "$f")")
done
_purge_raw=(${_verify_raw[@]+"${_verify_raw[@]}"})
for f in ${_deleted[@]+"${_deleted[@]}"}; do
  _purge_raw+=("$(to_url_path "$f")")
done

dedupe_into() {  # dedupe_into <outvar> <path>...
  local __out=$1; shift
  local seen="" p result=()
  for p in "$@"; do
    case "$seen" in
      *"|${p}|"*) ;;
      *) result+=("$p"); seen="${seen}|${p}|" ;;
    esac
  done
  eval "$__out=(\${result[@]+\"\${result[@]}\"})"
}

dedupe_into VERIFY_PATHS ${_verify_raw[@]+"${_verify_raw[@]}"}
dedupe_into CACHE_PATHS  ${_purge_raw[@]+"${_purge_raw[@]}"}

echo "→ ${#_changed[@]} file(s) changed, ${#_deleted[@]} deleted → ${#CACHE_PATHS[@]} path(s) to purge."

# A cap that drops paths silently is the same bug as the hand-kept list, wearing
# a nicer hat. If it truncates, it says exactly what it dropped and how to
# finish the job by hand.
if [[ ${#CACHE_PATHS[@]} -gt $MAX_PATHS ]]; then
  dropped=(${CACHE_PATHS[@]:$MAX_PATHS})
  CACHE_PATHS=("${CACHE_PATHS[@]:0:$MAX_PATHS}")
  VERIFY_PATHS=(${CACHE_PATHS[@]+"${CACHE_PATHS[@]}"})
  echo "" >&2
  echo "WARNING: ${#dropped[@]} path(s) exceed the ${MAX_PATHS}-path cap and were NOT purged:" >&2
  printf '  %s\n' "${dropped[@]}" >&2
  echo "  Purge them after this run:" >&2
  echo "    bash scripts/cache-purge.sh ${dropped[*]}" >&2
fi

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
bash "${SCRIPT_DIR}/verify-edge.sh" "${VERIFY_PATHS[@]}" || verify_rc=$?
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
echo "Verified above: ${VERIFY_PATHS[*]}"
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
