#!/usr/bin/env bash
# test-commit-msg-hook.sh — does the hook read the names the RUNTIME sets?
#
# WHY ROW D EXISTS, and it is the whole reason for this file. The first version
# of commit-msg read CLAUDE_SESSION_ID / SESSION_ID / OPENCLAW_SESSION_ID. None
# of those exist in an agent shell, so every commit got `Session: unknown` --
# not a failure, a constant. Three arms "proved" the hook worked and every one
# of them SET THE VARIABLE ITSELF, so all three were asking whether the hook
# reads what the test hands it. None asked what production hands it.
#
# Row D closes that by supplying nothing: it runs the hook under the ambient
# environment and requires a real id. It is the only row here that can fail when
# the harness is renamed, and it is therefore the only row that is about
# production rather than about this file.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/hooks/commit-msg"
[[ -x "$HOOK" ]] || { echo "ABORT: hook not executable: $HOOK" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; UNKNOWN=0

# emit <msg> -> path to a message file the hook has processed
emit() { local f="${TMP}/msg.$RANDOM"; printf '%s\n' "$1" > "$f"; "$HOOK" "$f" >/dev/null 2>&1; printf '%s' "$f"; }
trailer() { grep -E "^${2}:" "$1" | head -1 | sed -E "s/^${2}:[[:space:]]*//"; }
row() {
  local label="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then printf 'ok    %-52s %s\n' "$label" "$got"; PASS=$((PASS+1))
  else printf 'FAIL  %-52s got=%q want=%q\n' "$label" "$got" "$want"; FAIL=$((FAIL+1)); fi
}

# --- A: explicit transcript id is used verbatim ------------------------------
row "A  CLAUDE_CODE_SESSION_ID is used" "abc-123" \
  "$(CLAUDE_CODE_SESSION_ID=abc-123 OPENCLAW_MCP_SESSION_ID= bash -c '
     f=$(mktemp); printf "subject\n" > "$f"; "$0" "$f" >/dev/null 2>&1
     grep -E "^Session:" "$f" | sed -E "s/^Session:[[:space:]]*//"' "$HOOK")"

# --- B: no id anywhere -> unknown, never silence -----------------------------
row "B  scrubbed env -> unknown, not silence" "unknown" \
  "$(env -u CLAUDE_CODE_SESSION_ID -u OPENCLAW_MCP_SESSION_ID bash -c '
     f=$(mktemp); printf "subject\n" > "$f"; "$0" "$f" >/dev/null 2>&1
     grep -E "^Session:" "$f" | sed -E "s/^Session:[[:space:]]*//"' "$HOOK")"

# --- C: an existing trailer is never overwritten -----------------------------
row "C  existing trailer left alone" "supplied-by-caller" \
  "$(CLAUDE_CODE_SESSION_ID=should-not-win bash -c '
     f=$(mktemp); printf "subject\n\nSession: supplied-by-caller\n" > "$f"; "$0" "$f" >/dev/null 2>&1
     grep -E "^Session:" "$f" | head -1 | sed -E "s/^Session:[[:space:]]*//"' "$HOOK")"

# --- E: `unknown` is a placeholder, not a supplied value --------------------
# fe2c9c0 was committed under a stale installed hook, got `Session: unknown`,
# and --amend under the FIXED hook preserved it -- the original rule said "any
# value, including unknown". A placeholder that survives the conditions that
# would resolve it is a wrong value with a polite name.
row "E  unknown placeholder gets refilled" "real-id-42" \
  "$(CLAUDE_CODE_SESSION_ID=real-id-42 bash -c '
     f=$(mktemp); printf "subject\n\nSession: unknown\n" > "$f"; "$0" "$f" >/dev/null 2>&1
     grep -E "^Session:" "$f" | head -1 | sed -E "s/^Session:[[:space:]]*//"' "$HOOK")"

# --- F: refilling must not leave two Session lines ---------------------------
row "F  exactly one Session line after refill" "1" \
  "$(CLAUDE_CODE_SESSION_ID=real-id-42 bash -c '
     f=$(mktemp); printf "subject\n\nSession: unknown\n" > "$f"; "$0" "$f" >/dev/null 2>&1
     grep -cE "^Session:" "$f"' "$HOOK")"

# --- D: THE PRODUCTION ROW. Nothing supplied; ambient env must carry an id. ---
amb=$(trailer "$(emit 'ambient row')" Session)
if [[ -z "${CLAUDE_CODE_SESSION_ID:-}${OPENCLAW_MCP_SESSION_ID:-}" ]]; then
  # Not an agent shell. This is NOT a pass -- it is "could not check", and
  # collapsing those two is the failure this whole repo keeps re-learning.
  printf 'UNKN  %-52s no ambient session id: not an agent shell\n' "D  ambient env yields a real id"
  UNKNOWN=$((UNKNOWN+1))
elif [[ "$amb" == "unknown" || -z "$amb" ]]; then
  printf 'FAIL  %-52s got=%q -- hook reads names the runtime does not set\n' "D  ambient env yields a real id" "$amb"
  FAIL=$((FAIL+1))
else
  printf 'ok    %-52s %s\n' "D  ambient env yields a real id" "$amb"; PASS=$((PASS+1))
fi

echo
(( FAIL > 0 ))    && { echo "test-commit-msg-hook: ${FAIL} FAILED, ${PASS} passed"; exit 1; }
(( UNKNOWN > 0 )) && { echo "test-commit-msg-hook: ${UNKNOWN} UNKNOWN, ${PASS} passed -- not a pass"; exit 2; }
echo "test-commit-msg-hook: all ${PASS} rows passed"
