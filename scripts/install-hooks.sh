#!/usr/bin/env bash
# install-hooks.sh — copy tracked hooks into .git/hooks.
#
# Git does not version .git/hooks, so a tracked hook is inert until copied.
# This script is that copy. It is the runner the hook would otherwise lack —
# and it too must be invoked by a person, which is stated rather than hidden:
# an uninstalled hook enforces nothing and the repo cannot tell you so.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/hooks"
DEST="$(git -C "${SCRIPT_DIR}/.." rev-parse --git-path hooks 2>/dev/null)"
[[ -n "$DEST" ]] || { echo "ABORT: not a git checkout" >&2; exit 2; }
DEST="$(cd "${SCRIPT_DIR}/.." && cd "$DEST" && pwd)"
n=0
for h in "$SRC"/*; do
  [[ -f "$h" ]] || continue
  install -m 0755 "$h" "${DEST}/$(basename "$h")"
  echo "installed $(basename "$h") -> ${DEST}/"
  n=$((n + 1))
done
(( n > 0 )) || { echo "ABORT: no hooks found in $SRC" >&2; exit 2; }
echo "$n hook(s) installed."
