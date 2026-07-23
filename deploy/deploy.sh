#!/usr/bin/env bash
# Environment-driven deployment of the Tradex Soroban contracts.
#
# One script for every environment: the differences live in
# deploy/environments/<env>.env, not in branching logic here. It is used by
# .github/workflows/cd.yml and is equally runnable by hand.
#
# Every run writes a deployment manifest to deploy/manifests/<env>/, which is
# what makes rollback possible: the manifest records exactly which contract IDs
# and which source commit made up the last good deployment.
#
# Usage:
#   ./deploy/deploy.sh development
#   ./deploy/deploy.sh production --dry-run
#   ./deploy/deploy.sh staging --wasm-dir ./artifacts
#
# Required in the environment (not in the .env file — these are secrets):
#   STELLAR_DEPLOYER_SECRET   secret key of the deploying account
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_NAME="${1:?usage: deploy.sh <development|staging|production> [--dry-run]}"
shift || true

DRY_RUN=0
WASM_DIR="$ROOT/target/wasm32v1-none/release"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --wasm-dir) WASM_DIR="${2:?--wasm-dir needs a path}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ENV_FILE="$ROOT/deploy/environments/${ENV_NAME}.env"
[ -f "$ENV_FILE" ] || { echo "✗ unknown environment '$ENV_NAME' (no $ENV_FILE)" >&2; exit 1; }

set -a
# shellcheck disable=SC1090  # the path is built from the environment name
. "$ENV_FILE"
set +a

TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

if [ "$DRY_RUN" -eq 1 ]; then
  # A dry run writes to a scratch directory: its contract IDs are placeholders,
  # and a manifest left in deploy/manifests/ would be offered by rollback.sh as
  # a real target.
  MANIFEST_DIR="$(mktemp -d)"
  trap 'rm -rf "$MANIFEST_DIR"' EXIT
else
  MANIFEST_DIR="$ROOT/deploy/manifests/$ENV_NAME"
fi

MANIFEST="$MANIFEST_DIR/${TIMESTAMP}.json"
LOG_FILE="$MANIFEST_DIR/${TIMESTAMP}.log"

mkdir -p "$MANIFEST_DIR"

log()  { printf '\n\033[32m=== %s\033[0m\n' "$*" | tee -a "$LOG_FILE"; }
info() { printf '    %s\n' "$*" | tee -a "$LOG_FILE"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" | tee -a "$LOG_FILE" >&2; exit 1; }

log "Tradex deployment — $ENV_NAME"
info "network:  $STELLAR_NETWORK"
info "rpc:      $SOROBAN_RPC_URL"
info "commit:   $COMMIT"
info "wasm:     $WASM_DIR"
info "manifest: $MANIFEST"
[ "$DRY_RUN" -eq 1 ] && info "MODE:     dry run (nothing will be submitted)"

# ── Guard rails ─────────────────────────────────────────────────────────────
log "Checking guard rails"

if [ "${REQUIRE_CLEAN_TREE:-false}" = "true" ] && [ "$DRY_RUN" -eq 0 ]; then
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    die "working tree is dirty; $ENV_NAME deploys only from a clean checkout"
  fi
  info "✓ working tree is clean"
fi

if [ -n "${ALLOWED_BRANCHES:-}" ] && [ "$DRY_RUN" -eq 0 ]; then
  branch="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
  allowed=0
  for b in $ALLOWED_BRANCHES; do
    [ "$branch" = "$b" ] && allowed=1
  done
  # A tag ref is acceptable wherever REQUIRE_TAG is set — that is the release path.
  if [ "${REQUIRE_TAG:-false}" = "true" ] && printf '%s' "$branch" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
    allowed=1
  fi
  [ "$allowed" -eq 1 ] || die "branch '$branch' may not deploy to $ENV_NAME (allowed: $ALLOWED_BRANCHES)"
  info "✓ branch '$branch' is allowed"
fi

command -v stellar >/dev/null 2>&1 || die "the stellar CLI is not installed (scripts/ci/install-tool.sh stellar)"
info "✓ stellar CLI $(stellar --version | head -1)"

[ -d "$WASM_DIR" ] || die "wasm directory not found: $WASM_DIR"
"$ROOT/scripts/ci/validate-wasm.sh" "$WASM_DIR" | tee -a "$LOG_FILE" \
  || die "contract artifacts failed validation — refusing to deploy"

# ── Identity ────────────────────────────────────────────────────────────────
log "Configuring deployer identity"

SOURCE="${DEPLOYER_IDENTITY:-tradex-deployer}"

if [ -n "${STELLAR_DEPLOYER_SECRET:-}" ]; then
  # Piped via stdin so the secret never appears in a process listing or log.
  printf '%s' "$STELLAR_DEPLOYER_SECRET" \
    | stellar keys add "$SOURCE" --secret-key >/dev/null 2>&1 \
    || die "could not import STELLAR_DEPLOYER_SECRET"
  info "✓ imported deployer key from the environment"
elif stellar keys address "$SOURCE" >/dev/null 2>&1; then
  info "✓ using existing local identity '$SOURCE'"
elif [ "${ALLOW_FRIENDBOT_FUNDING:-false}" = "true" ]; then
  info "creating and funding a new identity '$SOURCE' via friendbot"
  [ "$DRY_RUN" -eq 1 ] || stellar keys generate "$SOURCE" --network "$STELLAR_NETWORK" --fund
elif [ "$DRY_RUN" -eq 1 ]; then
  # The point of a dry run is to validate the plan, so a missing credential is
  # reported rather than fatal — but loudly, because it means a real deploy to
  # this environment would fail.
  info "⚠ STELLAR_DEPLOYER_SECRET is not set — a real deploy to $ENV_NAME would fail here"
else
  die "no deployer key: set STELLAR_DEPLOYER_SECRET (friendbot funding is disabled for $ENV_NAME)"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  ADMIN="$(stellar keys address "$SOURCE")"
else
  ADMIN="$(stellar keys address "$SOURCE" 2>/dev/null || echo 'G<dry-run>')"
fi
info "deployer: $ADMIN"

# ── Deploy ──────────────────────────────────────────────────────────────────
log "Deploying contracts"

declare -A DEPLOYED=()

deploy_contract() {
  local name="$1" wasm="$WASM_DIR/$1.wasm"
  [ -f "$wasm" ] || die "$name.wasm not found in $WASM_DIR"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would deploy $name ($(wc -c < "$wasm") bytes)"
    DEPLOYED["$name"]="C<dry-run-$name>"
    return 0
  fi

  local id
  id="$(stellar contract deploy --wasm "$wasm" \
        --source "$SOURCE" --network "$STELLAR_NETWORK" 2>>"$LOG_FILE" | tail -1)"

  printf '%s' "$id" | grep -qE '^C[A-Z2-7]{55}$' \
    || die "$name deploy did not return a contract id (got: '$id') — see $LOG_FILE"

  DEPLOYED["$name"]="$id"
  info "✓ $name → $id"
}

for contract in ${CONTRACTS:-orderbook perp_engine}; do
  deploy_contract "$contract"
done

# The collateral token is a Stellar Asset Contract, not one of our wasm blobs.
log "Deploying the USDC collateral asset contract"
if [ "$DRY_RUN" -eq 1 ]; then
  USDC_ID="C<dry-run-usdc>"
  info "[dry-run] would deploy the USDC SAC for issuer $ADMIN"
else
  stellar contract asset deploy --asset "USDC:$ADMIN" \
    --source "$SOURCE" --network "$STELLAR_NETWORK" >>"$LOG_FILE" 2>&1 || true
  USDC_ID="$(stellar contract id asset --asset "USDC:$ADMIN" \
             --network "$STELLAR_NETWORK" 2>>"$LOG_FILE" | tail -1)"
  info "✓ USDC SAC → $USDC_ID"
fi

# ── Initialize ──────────────────────────────────────────────────────────────
PERP_ID="${DEPLOYED[perp_engine]:-}"

if [ "${INITIALIZE_PERP_ENGINE:-false}" = "true" ] && [ -n "$PERP_ID" ]; then
  log "Initializing perp-engine"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would initialize $PERP_ID with admin=$ADMIN token=$USDC_ID"
  else
    stellar contract invoke --id "$PERP_ID" --source "$SOURCE" --network "$STELLAR_NETWORK" -- \
      initialize --admin "$ADMIN" --token "$USDC_ID" >>"$LOG_FILE" 2>&1 \
      || die "perp-engine initialize failed — see $LOG_FILE"
    info "✓ initialized"
  fi
fi

if [ "${REGISTER_MARKETS:-false}" = "true" ] && [ -n "$PERP_ID" ]; then
  log "Registering markets"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would register the market catalogue"
  else
    PERP_ID="$PERP_ID" SOURCE="$SOURCE" NETWORK="$STELLAR_NETWORK" \
      "$ROOT/scripts/register-markets.sh" >>"$LOG_FILE" 2>&1 \
      || die "market registration failed — see $LOG_FILE"
    info "✓ markets registered"
  fi
fi

# ── Manifest ────────────────────────────────────────────────────────────────
log "Writing deployment manifest"

contracts_json="$(
  for name in "${!DEPLOYED[@]}"; do
    printf '{"name":"%s","id":"%s","sha256":"%s"},' \
      "$name" "${DEPLOYED[$name]}" \
      "$(sha256sum "$WASM_DIR/$name.wasm" 2>/dev/null | cut -d' ' -f1)"
  done | sed 's/,$//'
)"

cat > "$MANIFEST" <<JSON
{
  "environment": "$ENV_NAME",
  "network": "$STELLAR_NETWORK",
  "rpc_url": "$SOROBAN_RPC_URL",
  "timestamp": "$TIMESTAMP",
  "commit": "$COMMIT",
  "ref": "${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}",
  "run_id": "${GITHUB_RUN_ID:-local}",
  "actor": "${GITHUB_ACTOR:-$(git config user.name 2>/dev/null || echo unknown)}",
  "dry_run": $([ "$DRY_RUN" -eq 1 ] && echo true || echo false),
  "admin": "$ADMIN",
  "collateral_token": "$USDC_ID",
  "contracts": [$contracts_json]
}
JSON

node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$MANIFEST" \
  || die "generated manifest is not valid JSON: $MANIFEST"

if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] manifest would be:"
  sed 's/^/      /' "$MANIFEST"
else
  # `latest.json` is what rollback.sh and the frontend config step read.
  cp "$MANIFEST" "$MANIFEST_DIR/latest.json"
  info "✓ $MANIFEST"
  info "✓ $MANIFEST_DIR/latest.json"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
log "Deployment complete — $ENV_NAME"

{
  echo "### Deployment: $ENV_NAME"
  echo
  echo "| Contract | ID |"
  echo "| --- | --- |"
  for name in "${!DEPLOYED[@]}"; do
    echo "| \`$name\` | \`${DEPLOYED[$name]}\` |"
  done
  echo "| \`collateral (USDC)\` | \`$USDC_ID\` |"
  echo
  echo "- Network: \`$STELLAR_NETWORK\`"
  echo "- Commit: \`$COMMIT\`"
  echo "- Admin: \`$ADMIN\`"
} | tee -a "$LOG_FILE" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

cat <<EOF

  Frontend configuration for this deployment:

    VITE_PERP_ENGINE_ID=${DEPLOYED[perp_engine]:-}
    VITE_ORDERBOOK_ID=${DEPLOYED[orderbook]:-}
    VITE_COLLATERAL_TOKEN_ID=$USDC_ID
    VITE_SIMULATION_SOURCE=$ADMIN

EOF
