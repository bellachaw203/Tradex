#!/usr/bin/env bash
# Validate the committed Groth16 verifying keys and export the VK_* variables
# that the contract build scripts (build.rs) read at compile time.
#
# The verifying keys are baked into the contract wasm, so a missing or
# malformed key must fail loudly *before* cargo runs — otherwise the failure
# surfaces as an opaque build-script panic.
#
# Usage:
#   ./scripts/ci/circuit-keys.sh [keys-dir]          # validate + export to $GITHUB_ENV
#   eval "$(./scripts/ci/circuit-keys.sh --print)"   # export into a local shell
set -euo pipefail

PRINT_ONLY=0
if [ "${1:-}" = "--print" ]; then
  PRINT_ONLY=1
  shift
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEYS_DIR="$ROOT/${1:-circuits/keys}"

# VAR_NAME:filename — must stay in lockstep with the contracts' build.rs files.
KEYS="
VK_COMMIT_JSON:order_commitment_vk.json
VK_CANCEL_JSON:order_cancel_vk.json
VK_MATCH_JSON:order_match_vk.json
VK_NOTE_SPEND_JSON:note_spend_vk.json
VK_POOL_INSERT_JSON:shielded_insert_vk.json
VK_POOL_WITHDRAW_JSON:shielded_withdraw_vk.json
"

log() { [ "$PRINT_ONLY" -eq 1 ] || printf '%s\n' "$*" >&2; }

if [ ! -d "$KEYS_DIR" ]; then
  echo "✗ verifying-key directory not found: $KEYS_DIR" >&2
  echo "  Run 'make circuit-setup' to regenerate it." >&2
  exit 1
fi

# A verifying key that parses as JSON but is structurally wrong produces a
# contract that silently rejects every proof, so the shape is checked too.
validate_vk() {
  node -e '
    const fs = require("fs")
    const vk = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
    const required = ["protocol", "curve", "nPublic", "vk_alpha_1", "vk_beta_2", "vk_gamma_2", "vk_delta_2", "IC"]
    const missing = required.filter((k) => vk[k] === undefined)
    if (missing.length) throw new Error("missing fields: " + missing.join(", "))
    if (vk.protocol !== "groth16") throw new Error("expected protocol groth16, got " + vk.protocol)
    if (!Array.isArray(vk.IC) || vk.IC.length !== vk.nPublic + 1) {
      throw new Error("IC length " + (vk.IC || []).length + " does not match nPublic " + vk.nPublic + " + 1")
    }
  ' "$1"
}

fail=0
log "→ validating verifying keys in $KEYS_DIR"

for entry in $KEYS; do
  var="${entry%%:*}"
  file="${entry##*:}"
  path="$KEYS_DIR/$file"

  if [ ! -s "$path" ]; then
    echo "✗ $file is missing or empty" >&2
    fail=1
    continue
  fi

  if ! err="$(validate_vk "$path" 2>&1)"; then
    echo "✗ $file is not a valid Groth16 verifying key" >&2
    echo "$err" | tail -3 >&2
    fail=1
    continue
  fi

  if [ "$PRINT_ONLY" -eq 1 ]; then
    echo "export $var=\"$path\""
  else
    log "  ✓ $file"
    [ -n "${GITHUB_ENV:-}" ] && echo "$var=$path" >> "$GITHUB_ENV"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "✗ verifying-key validation failed" >&2
  exit 1
fi

log "✓ all verifying keys valid"
