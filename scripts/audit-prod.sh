#!/usr/bin/env bash
# audit-prod.sh — out-of-band inventory of production. READ ONLY.
#
# WHY THIS EXISTS, AND WHY IT IS NOT PART OF deploy.sh
# ----------------------------------------------------
# deploy.sh ships from an allow-list. rsync CANNOT SEE excluded paths: it will
# not upload them, will not delete them, and will not report them. A file that
# lands in an excluded path is invisible to the deploy AND to its drift guard,
# permanently, and the guard keeps printing green over it.
#
# That is not a bug in the guard -- default-deny is correct. It is the PRICE of
# default-deny, and this script is the payment. Proven 2026-07-17: with
# scripts/ excluded, `deploy.sh --check` reported "production holds nothing the
# repo is missing", exit 0, while nine .py files served 200 on the live site.
# Six minutes earlier the same guard correctly aborted on a blog/ file. The
# blindness lives in the filter, not the directory.
#
# So: this script MUST NOT import, source, or reimplement RSYNC_INCLUDES /
# RSYNC_EXCLUDES from deploy.sh. A check that shares the deploy's filter can
# only ever confirm the deploy's own opinion of the world. It asks the origin
# what is actually there, and diffs that against git. Nothing else.
#
# The nine .py files were found this way -- by hand, by a human, out of band.
# This is that method, made repeatable.
#
# Usage: bash scripts/audit-prod.sh
# Exit:  0 = no prod-only files
#        1 = prod-only files found (something is live that no repo can explain)
#        2 = setup/connection failure
#        3 = comparison VOID (canary failed -- see below; results discarded)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_FILE="${KILOKAKI_DEPLOY_ENV:-${HOME}/.config/kilokaki-site/deploy.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: deploy env not found: $ENV_FILE" >&2
  echo "Copy scripts/deploy.env.example there and fill it in (chmod 600)." >&2
  exit 2
fi
# shellcheck source=/dev/null
source "$ENV_FILE"
export SSHPASS

for var in SSHPASS REMOTE_USER REMOTE_HOST REMOTE_BASE_DIR; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var missing from $ENV_FILE" >&2
    exit 2
  fi
done

command -v sshpass >/dev/null || { echo "ERROR: sshpass not installed" >&2; exit 2; }

# The docroot, NOT REMOTE_BASE_DIR. REMOTE_BASE_DIR is the Cloudways app root;
# it also holds logs/, conf/, private_html/ -- none of it web-facing, none of it
# ever in the repo. Auditing there reports the whole app as "prod-only". Same
# derivation as deploy.sh:65, deliberately duplicated rather than sourced: this
# script must not import anything from deploy.sh that could couple it to the
# deploy's view of the world.
REMOTE_PUBLIC_HTML="${REMOTE_BASE_DIR}/public_html"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Inventory production -------------------------------------------------
# The remote does NOT sort. It emits raw `find` output and every sort happens
# here, locally, under one LC_ALL=C.
#
# `comm` silently emits garbage if its two inputs disagree on collation, and
# remote GNU sort and local BSD sort order '-' and '_' differently. On
# 2026-07-17 that alone invented seven phantom prod-only blog posts -- all seven
# were in the repo -- and nearly went out as a P0.
#
# The obvious fix is `LC_ALL=C sort` on both ends. That is NOT what this does,
# because it is not enough: it leaves a remote sort in the comparison and only
# asks it nicely to agree. Tested 2026-07-17 -- with a remote sort still in the
# pipeline and its locale ignored, this script reported a phantom prod-only file
# and the canary below did NOT catch it (the canary sorted correctly either way).
# One sort, one implementation, one locale, on one machine, is the only version
# with no second opinion to disagree with. Do not move sorting back to the
# remote.
echo "Inventorying production (read-only)..."
if ! sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
      "${REMOTE_USER}@${REMOTE_HOST}" \
      "cd '${REMOTE_PUBLIC_HTML}' && find . -type f" \
      2>"$TMP/err.txt" | sed 's|^\./||' | LC_ALL=C sort > "$TMP/prod.txt"; then
  echo "ERROR: could not inventory production. ssh said:" >&2
  sed 's/^/  /' "$TMP/err.txt" >&2
  echo >&2
  # An ssh failure prints to stdout too. `find | wc -l` over an error stream
  # returns a plausible-looking count that is not an inventory. On 2026-07-17
  # exactly that nearly went out as a finding: the exit code and the count both
  # lied, and only the message was true. Never treat a failed run as empty.
  echo "NOT reporting a file count from a failed connection." >&2
  exit 2
fi

if [[ ! -s "$TMP/prod.txt" ]]; then
  echo "ERROR: production inventory is empty. That is not a clean site; that is" >&2
  echo "a broken read. Refusing to report 'no drift' from no data." >&2
  exit 2
fi

git -C "$REPO_ROOT" ls-files | LC_ALL=C sort > "$TMP/repo.txt"

comm -23 "$TMP/prod.txt" "$TMP/repo.txt" > "$TMP/prod_only.txt"
comm -13 "$TMP/prod.txt" "$TMP/repo.txt" > "$TMP/repo_only.txt"

# --- Canary: prove the comparison is capable of being right ---------------
# A known-true row, independently verified, must land where it belongs. If a
# file that is demonstrably in BOTH sets shows up as exclusive to either, the
# diff is garbage and every other row in it is garbage too -- regardless of how
# plausible those rows look. This morning one impossible row is the only reason
# seven plausible ones were caught. Do not make the canary something a real
# outage could legitimately remove; index.html absent from prod is its own alarm.
CANARY="index.html"
if grep -qxF "$CANARY" "$TMP/prod.txt" && grep -qxF "$CANARY" "$TMP/repo.txt"; then
  if grep -qxF "$CANARY" "$TMP/prod_only.txt" || grep -qxF "$CANARY" "$TMP/repo_only.txt"; then
    echo "VOID: canary '$CANARY' is in both inventories but the diff calls it" >&2
    echo "exclusive. Collation or comparison is broken; results discarded." >&2
    exit 3
  fi
else
  echo "VOID: canary '$CANARY' missing from an inventory -- cannot establish" >&2
  echo "that this comparison works. Not reporting findings from an unproven diff." >&2
  exit 3
fi

# --- Report ---------------------------------------------------------------
PROD_N=$(wc -l < "$TMP/prod.txt" | tr -d ' ')
ONLY_N=$(wc -l < "$TMP/prod_only.txt" | tr -d ' ')

echo
echo "production files: $PROD_N   (repo tracks $(wc -l < "$TMP/repo.txt" | tr -d ' '))"
echo

# repo-only is EXPECTED and is not a finding: the repo deliberately holds plenty
# that must never ship (this script, the manifest, deploy.sh). Counting it here
# without judging it is the point -- judging it would require the deploy's
# filter, which is the one thing this script must not know.
echo "repo-only (not shipped -- expected, informational): $(wc -l < "$TMP/repo_only.txt" | tr -d ' ')"
echo

if [[ "$ONLY_N" -eq 0 ]]; then
  echo "PASS: zero prod-only files. Everything live is explained by the repo."
  exit 0
fi

echo "FAIL: $ONLY_N file(s) live on production with no source in the repo."
echo "These are invisible to the deploy and to its drift guard:"
sed 's/^/  /' "$TMP/prod_only.txt"
echo
echo "Each is either (a) exposure to remove, or (b) the only copy of something."
echo "Establish which BEFORE deleting. The guard fails closed for this reason."
exit 1
