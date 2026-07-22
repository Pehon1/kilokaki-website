#!/usr/bin/env bash
# check-cited-paths.sh — every path a doc CITES must resolve on disk.
#
# WHY THIS EXISTS. `a224c71` silently reverted `1b21282` by composing its
# evidence/README.md edits onto the pre-fix text, restoring a `source` field
# pointing at ~/.openclaw-nori/workspace/state/live-by/live_by.json — a path
# that has never existed. Nothing caught it. Not review (the diff against the
# fix is empty, which is the tell), not the author field (every commit on this
# branch carries the same machine default), and not worktree isolation — the
# revert was authored INSIDE an isolated worktree, so isolation could not have
# prevented it. What survives a whole-file overwrite from a stale buffer is a
# CONTENT INVARIANT, checked on the tip, every run. This is that invariant.
#
# WHAT COUNTS AS A CITATION, and the two conditions are both load-bearing:
#
#   1. the line is indented >= 4 spaces (a block, not prose), AND
#   2. the path token is BARE — not wrapped in `backticks`.
#
# A path in prose backticks is a MENTION. This README deliberately quotes
# `live_by.json` in its own §Corrections to say the path is dead; a checker
# that cannot tell "cited as a source" from "named as a known-bad path" would
# go red on the correction and force the correction to be deleted to get green.
# That is worse than no check.
#
# SCOPE, stated rather than implied: only `~/`-rooted paths are checked. Scratch
# absolutes (/tmp/...) are expected not to exist, and repo-relative tokens sit
# inside shell one-liners where a bare `foo/bar` is as likely to be a sed
# expression as a file. Widening past `~/` needs a real tokeniser, not a regex.
#
# EXITS
#   0  every cited path resolves        1  one or more do not
#   2  INSTRUMENT REFUSES — file missing, or ZERO citations extracted.
#      Zero is a refusal and not a pass on purpose: a broken extractor finds
#      nothing, and "nothing failed to resolve" is the exact shape of a green
#      that proves nothing. The suite's red arm (a224c71) is what keeps this
#      honest across future edits.

set -uo pipefail

FILE="${1:-}"
[[ -n "$FILE" ]] || { echo "usage: check-cited-paths.sh <file>   (or - for stdin)" >&2; exit 2; }

if [[ "$FILE" == "-" ]]; then
  SRC=$(cat) || { echo "INSTRUMENT REFUSES: cannot read stdin" >&2; exit 2; }
  LABEL="<stdin>"
else
  [[ -f "$FILE" ]] || { echo "INSTRUMENT REFUSES: no such file: $FILE" >&2; exit 2; }
  SRC=$(cat "$FILE") || { echo "INSTRUMENT REFUSES: cannot read $FILE" >&2; exit 2; }
  LABEL="$FILE"
fi

CITED=0; BAD=0

while IFS= read -r line; do
  # condition 1: block, not prose
  [[ "$line" =~ ^[[:space:]]{4,} ]] || continue
  # condition 2: drop every `backticked` span, then read what is left
  stripped=$(sed 's/`[^`]*`//g' <<<"$line")

  for tok in $(grep -oE '~/[^[:space:]`,)]+' <<<"$stripped"); do
    tok="${tok%%[.,;:]}"
    CITED=$((CITED + 1))
    expanded="${HOME}/${tok#\~/}"

    if [[ "$expanded" == *[\*\?]* ]]; then
      # glob: >= 1 match is a resolution
      shopt -s nullglob
      matches=( $expanded )
      shopt -u nullglob
      if (( ${#matches[@]} > 0 )); then
        printf '  ok    %s  (glob, %d match)\n' "$tok" "${#matches[@]}"
      else
        printf '  BAD   %s  <- glob matches nothing\n' "$tok"; BAD=$((BAD + 1))
      fi
    elif [[ -e "$expanded" ]]; then
      printf '  ok    %s\n' "$tok"
    else
      printf '  BAD   %s  <- does not resolve\n' "$tok"; BAD=$((BAD + 1))
    fi
  done
done <<<"$SRC"

echo
if (( CITED == 0 )); then
  echo "INSTRUMENT REFUSES: 0 citations extracted from $LABEL."
  echo "  A checker that found nothing to check has not passed. Either the file"
  echo "  cites no ~/ path, or the extractor is broken; both need a human."
  exit 2
fi

if (( BAD > 0 )); then
  echo "$LABEL: $BAD of $CITED cited path(s) DO NOT RESOLVE"
  echo "  A provenance field whose path does not resolve is a stamp, not provenance."
  exit 1
fi

echo "$LABEL: all $CITED cited path(s) resolve"
exit 0
