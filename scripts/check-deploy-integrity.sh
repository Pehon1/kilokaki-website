#!/usr/bin/env bash
# check-deploy-integrity.sh — fail if the deploy tooling has drifted.
#
# WHY THIS EXISTS
# On 2026-07-17 three forks of deploy.sh had been diverging for ten weeks. The
# drift guard existed in exactly one workspace. Coco read her copy and correctly
# reported the guard was wired in; Nori read hers and correctly reported it did
# not exist. Both were right about their own file. Nobody was right about the
# system. That cost a morning and produced two false P1 alarms.
#
# Divergence is now structurally hard: one canonical script, three thin wrappers.
# This asserts it stayed that way. Read-only. No network, no credentials.
#
# Usage: bash scripts/check-deploy-integrity.sh   (exit 0 = intact, 1 = drifted)

set -uo pipefail

CANONICAL="${HOME}/.openclaw/workspace/kilokaki-site/scripts/deploy.sh"
ENV_FILE="${HOME}/.config/kilokaki-site/deploy.env"
WRAPPERS=(
  "${HOME}/.openclaw-kilokaki/workspace/skills/kilokaki-landing-page/scripts/deploy.sh"
  "${HOME}/.openclaw/workspace/skills/kilokaki-landing-page/scripts/deploy.sh"
  "${HOME}/.openclaw-nori/workspace/skills/kilokaki-landing-page/scripts/deploy.sh"
)

fail=0
note() { echo "  $*"; }
bad()  { echo "✗ $*" >&2; fail=1; }

echo "→ Deploy integrity check"

# 1. Canonical exists.
if [[ ! -f "$CANONICAL" ]]; then
  bad "canonical script missing: $CANONICAL"
  echo "" >&2
  echo "ABORT: nothing to check against." >&2
  exit 1
fi
note "canonical: $CANONICAL"

# 2. Every wrapper is present, is a wrapper, and targets the canonical.
#    A wrapper that has grown logic is a fork wearing a wrapper's name.
for w in "${WRAPPERS[@]}"; do
  short="${w#"${HOME}"/}"
  if [[ ! -f "$w" ]]; then bad "wrapper missing: $short"; continue; fi
  if ! grep -q 'exec bash "$REAL"' "$w"; then
    bad "not a wrapper (has it been forked again?): $short"; continue
  fi
  if ! grep -q 'kilokaki-site/scripts/deploy.sh' "$w"; then
    bad "wrapper points somewhere other than the canonical: $short"; continue
  fi
  lines=$(wc -l < "$w" | tr -d ' ')
  if (( lines > 30 )); then
    bad "wrapper has grown to ${lines} lines — logic is leaking back in: $short"
  fi
done

# 3. All wrappers identical to each other. Three copies that merely *look* like
#    wrappers can still disagree; that is how this started.
hashes=$(for w in "${WRAPPERS[@]}"; do [[ -f "$w" ]] && shasum "$w" | awk '{print $1}'; done | sort -u | wc -l | tr -d ' ')
if [[ "$hashes" == "1" ]]; then
  note "3 wrappers, 1 distinct hash — no divergence"
else
  bad "wrappers disagree: ${hashes} distinct versions across 3 copies"
  for w in "${WRAPPERS[@]}"; do
    [[ -f "$w" ]] && echo "    $(shasum "$w" | cut -c1-12)  ${w#"${HOME}"/}" >&2
  done
fi

# 4. No secret has crept back into the canonical. This repo is public.
if grep -qE '(SSHPASS=["'"'"']..|Bearer (cfut_|cw\.ut_)[A-Za-z0-9]{16})' "$CANONICAL"; then
  bad "a credential is hardcoded in the canonical script — this repo is PUBLIC"
else
  note "canonical holds no secrets"
fi

# 5. Credentials exist, outside the tree, not world-readable.
if [[ ! -f "$ENV_FILE" ]]; then
  bad "deploy env missing: ${ENV_FILE#"${HOME}"/} (deploy will fail closed)"
else
  perms=$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null)
  if [[ "$perms" != "600" ]]; then
    bad "deploy env is mode ${perms}, expected 600: ${ENV_FILE#"${HOME}"/}"
  else
    note "deploy env present, mode 600, outside the tree"
  fi
fi

echo ""
if (( fail )); then
  echo "✗ DEPLOY TOOLING HAS DRIFTED — do not deploy until this passes." >&2
  echo "  Three copies disagreeing is what produced the 2026-07-17 alarms." >&2
  exit 1
fi
echo "✓ Deploy tooling intact: one canonical, three identical wrappers, no secrets in the tree."
