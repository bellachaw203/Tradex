#!/usr/bin/env bash
# Register the 7 Tradex markets on a freshly deployed perp-engine and seed
# their oracle prices.
#
# Asset IDs, names and prices MUST stay in lockstep with:
#   - keepers/src/main.rs           (MARKETS)
#   - app/app/context/market-context.tsx (MARKET_CATALOG)
#
# Prices are in the protocol's 7-decimal scale (1e7 = $1).
#
# Usage: PERP_ID=C... SOURCE=tradex-deployer ./scripts/register-markets.sh
set -euo pipefail

PERP_ID="${PERP_ID:?set PERP_ID to the deployed perp-engine contract id}"
SOURCE="${SOURCE:-tradex-deployer}"
NETWORK="${NETWORK:-testnet}"
ADMIN="$(stellar keys address "$SOURCE")"

# symbol | asset_id | name(hex) | price(1e7) | max_leverage
MARKETS="
BTC-PERP    0 425443       610000000000 50
XRP-PERP    1 585250          11200000 20
XLM-PERP    2 584c4d           1100000 10
SPACEX-PERP 3 535041434558  3500000000 10
TSLA-PERP   4 54534c41      3900000000 10
OIL-PERP    5 4f494c         700000000 10
GOLD-PERP   6 474f4c44     41790000000 20
"

echo "$MARKETS" | while read -r symbol id name_hex price lev; do
  [ -z "$symbol" ] && continue
  asset_hex=$(printf '%064x' "$id")

  echo "=== $symbol (asset_id=$id, price=$price, max_lev=${lev}x) ==="

  stellar contract invoke --id "$PERP_ID" --source "$SOURCE" --network "$NETWORK" -- \
    register_asset \
    --admin "$ADMIN" \
    --asset_id "$asset_hex" \
    --name "$name_hex" \
    --config "{ \"active\": true, \"initial_margin_bps\": \"1000\", \"ins_fund_bps\": \"50\", \"liq_full_reward_bps\": \"150\", \"liq_partial_reward_bps\": \"100\", \"maintenance_margin_bps\": \"500\", \"max_leverage\": $lev }" \
    2>&1 | tail -2

  sleep 2

  stellar contract invoke --id "$PERP_ID" --source "$SOURCE" --network "$NETWORK" -- \
    set_asset_price \
    --asset_id "$asset_hex" \
    --admin "$ADMIN" \
    --price "$price" \
    2>&1 | tail -2

  sleep 2
  echo "  OK $symbol"
done

echo "All 7 markets registered and priced."
