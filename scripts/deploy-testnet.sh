#!/usr/bin/env bash
# Full Stellar Testnet deployment for Tradex.
#
#   1. creates + funds the deployer identity (if missing)
#   2. builds the Soroban contracts to wasm
#   3. deploys orderbook, perp-engine and the USDC collateral SAC
#   4. initializes the perp-engine
#   5. registers the 7 markets and seeds their oracle prices
#
# Usage:
#   ./scripts/deploy-testnet.sh
#
# Env overrides:
#   SOURCE   stellar CLI identity to deploy from   (default: tradex-deployer)
#   NETWORK  stellar network                       (default: testnet)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${SOURCE:-tradex-deployer}"
NETWORK="${NETWORK:-testnet}"
WASM_DIR="$ROOT/target/wasm32v1-none/release"

log() { printf '\n\033[32m=== %s\033[0m\n' "$*"; }

# ── 1. Deployer identity ──────────────────────────────────────────────
if ! stellar keys address "$SOURCE" >/dev/null 2>&1; then
  log "Creating + funding identity '$SOURCE'"
  stellar keys generate "$SOURCE" --network "$NETWORK" --fund
fi
ADMIN="$(stellar keys address "$SOURCE")"
log "Deployer: $ADMIN"

# ── 2. Build contracts ────────────────────────────────────────────────
log "Building contracts"
export VK_COMMIT_JSON="$ROOT/circuits/keys/order_commitment_vk.json"
export VK_CANCEL_JSON="$ROOT/circuits/keys/order_cancel_vk.json"
export VK_MATCH_JSON="$ROOT/circuits/keys/order_match_vk.json"
export VK_NOTE_SPEND_JSON="$ROOT/circuits/keys/note_spend_vk.json"
export VK_POOL_INSERT_JSON="$ROOT/circuits/keys/shielded_insert_vk.json"
export VK_POOL_WITHDRAW_JSON="$ROOT/circuits/keys/shielded_withdraw_vk.json"

cd "$ROOT"
cargo build --target wasm32v1-none --release \
  -p orderbook -p perp-engine -p shielded-pool -p collateral -p verifier-groth16

if command -v wasm-opt >/dev/null 2>&1; then
  for w in orderbook perp_engine shielded_pool collateral verifier_groth16; do
    wasm-opt -Oz --strip-debug --strip-producers --strip-target-features \
      "$WASM_DIR/$w.wasm" -o "$WASM_DIR/$w.wasm"
  done
fi

# ── 3. Deploy ─────────────────────────────────────────────────────────
log "Deploying orderbook"
ORDERBOOK_ID=$(stellar contract deploy --wasm "$WASM_DIR/orderbook.wasm" \
  --source "$SOURCE" --network "$NETWORK" 2>/dev/null | tail -1)

log "Deploying perp-engine"
PERP_ID=$(stellar contract deploy --wasm "$WASM_DIR/perp_engine.wasm" \
  --source "$SOURCE" --network "$NETWORK" 2>/dev/null | tail -1)

log "Deploying USDC collateral SAC"
stellar contract asset deploy --asset "USDC:$ADMIN" \
  --source "$SOURCE" --network "$NETWORK" >/dev/null 2>&1 || true
USDC_ID=$(stellar contract id asset --asset "USDC:$ADMIN" \
  --network "$NETWORK" 2>/dev/null | tail -1)

# ── 4. Initialize ─────────────────────────────────────────────────────
log "Initializing perp-engine"
stellar contract invoke --id "$PERP_ID" --source "$SOURCE" --network "$NETWORK" -- \
  initialize --admin "$ADMIN" --token "$USDC_ID" >/dev/null

# ── 5. Markets ────────────────────────────────────────────────────────
log "Registering markets"
PERP_ID="$PERP_ID" SOURCE="$SOURCE" NETWORK="$NETWORK" \
  "$ROOT/scripts/register-markets.sh"

# ── Done ──────────────────────────────────────────────────────────────
cat <<EOF

=====================================================================
 Deployment complete
=====================================================================
  perp-engine       $PERP_ID
  orderbook         $ORDERBOOK_ID
  collateral (USDC) $USDC_ID
  admin             $ADMIN

 Put these in app/.env (copy from app/.env.example), or update the
 TESTNET_DEPLOYMENT defaults in app/app/lib/contracts.ts:

  VITE_PERP_ENGINE_ID=$PERP_ID
  VITE_ORDERBOOK_ID=$ORDERBOOK_ID
  VITE_COLLATERAL_TOKEN_ID=$USDC_ID
  VITE_SIMULATION_SOURCE=$ADMIN
=====================================================================
EOF
