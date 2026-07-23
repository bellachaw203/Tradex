#!/usr/bin/env bash
# Roll an environment back to a previous deployment.
#
# What rollback means for Soroban contracts
# -----------------------------------------
# A deployed contract is immutable and its address is permanent. "Rolling back"
# therefore does not undo anything on-chain — it re-points the *clients*
# (frontend, keepers, docs) at the previous, known-good set of contract IDs, and
# restores that manifest as the environment's current state.
#
# That is the honest and safe operation. Anything else — deploying a fresh copy
# of the old code — creates a third address with empty state, which is not a
# rollback.
#
# Usage:
#   ./deploy/rollback.sh staging                    # roll back one deployment
#   ./deploy/rollback.sh production --to 20260101T120000Z
#   ./deploy/rollback.sh staging --list
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_NAME="${1:?usage: rollback.sh <environment> [--to <timestamp>|--list]}"
shift || true

TARGET=""
LIST_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to)   TARGET="${2:?--to needs a manifest timestamp}"; shift 2 ;;
    --list) LIST_ONLY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

MANIFEST_DIR="$ROOT/deploy/manifests/$ENV_NAME"
[ -d "$MANIFEST_DIR" ] || { echo "✗ no deployment history for '$ENV_NAME'" >&2; exit 1; }

# Newest first, excluding the `latest.json` pointer.
mapfile -t HISTORY < <(find "$MANIFEST_DIR" -maxdepth 1 -name '*.json' ! -name 'latest.json' \
  -printf '%f\n' 2>/dev/null | sort -r)

if [ "${#HISTORY[@]}" -eq 0 ]; then
  echo "✗ no manifests found in $MANIFEST_DIR" >&2
  exit 1
fi

describe() {
  node -e '
    const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))
    const ids = (m.contracts || []).map((c) => `${c.name}=${c.id.slice(0, 8)}…`).join(" ")
    console.log(`  ${m.timestamp}  commit ${String(m.commit).slice(0, 8)}  ${ids}`)
  ' "$1"
}

echo "→ deployment history for $ENV_NAME (newest first)"
current=""
[ -f "$MANIFEST_DIR/latest.json" ] && current="$(node -p "require('$MANIFEST_DIR/latest.json').timestamp" 2>/dev/null || echo '')"

for m in "${HISTORY[@]}"; do
  marker="  "
  [ "${m%.json}" = "$current" ] && marker="→ "
  printf '%s' "$marker"
  describe "$MANIFEST_DIR/$m"
done

[ "$LIST_ONLY" -eq 1 ] && exit 0

# ── Pick the target manifest ────────────────────────────────────────────────
if [ -n "$TARGET" ]; then
  CHOSEN="${TARGET%.json}.json"
  [ -f "$MANIFEST_DIR/$CHOSEN" ] || { echo "✗ no manifest '$CHOSEN' in $MANIFEST_DIR" >&2; exit 1; }
else
  # One step back from whatever is current.
  if [ "${#HISTORY[@]}" -lt 2 ]; then
    echo "✗ only one deployment recorded — there is nothing to roll back to." >&2
    exit 1
  fi
  if [ -n "$current" ]; then
    CHOSEN=""
    for i in "${!HISTORY[@]}"; do
      if [ "${HISTORY[$i]%.json}" = "$current" ]; then
        CHOSEN="${HISTORY[$((i + 1))]:-}"
        break
      fi
    done
    [ -n "$CHOSEN" ] || { echo "✗ current deployment is already the oldest recorded." >&2; exit 1; }
  else
    CHOSEN="${HISTORY[1]}"
  fi
fi

echo
echo "→ rolling $ENV_NAME back to $CHOSEN"
describe "$MANIFEST_DIR/$CHOSEN"

# ── Verify the target is real before switching to it ────────────────────────
echo "→ verifying the target deployment is live on-chain"

network="$(node -p "require('$MANIFEST_DIR/$CHOSEN').network")"
if command -v stellar >/dev/null 2>&1; then
  unreachable=0
  while IFS= read -r pair; do
    name="${pair%%=*}"
    id="${pair##*=}"
    if stellar contract info interface --id "$id" --network "$network" >/dev/null 2>&1; then
      echo "  ✓ $name ($id) is live"
    else
      echo "  ✗ $name ($id) could not be read on $network" >&2
      unreachable=1
    fi
  done < <(node -p "
    require('$MANIFEST_DIR/$CHOSEN').contracts.map((c) => c.name + '=' + c.id).join('\n')
  ")

  if [ "$unreachable" -ne 0 ]; then
    echo "✗ refusing to roll back to a deployment whose contracts are not readable." >&2
    exit 1
  fi
else
  echo "  ⚠ stellar CLI unavailable — skipping the on-chain liveness check" >&2
fi

# ── Switch ──────────────────────────────────────────────────────────────────
# The superseded manifest is preserved under a rollback- name, so rolling back
# a rollback is possible and the history stays complete.
if [ -n "$current" ] && [ -f "$MANIFEST_DIR/latest.json" ]; then
  cp "$MANIFEST_DIR/latest.json" "$MANIFEST_DIR/rollback-from-${current}.json"
fi

cp "$MANIFEST_DIR/$CHOSEN" "$MANIFEST_DIR/latest.json"

cat > "$MANIFEST_DIR/ROLLBACK.md" <<EOF
# Rollback — $ENV_NAME

- **When:** $(date -u '+%Y-%m-%dT%H:%M:%SZ')
- **By:** ${GITHUB_ACTOR:-$(git config user.name 2>/dev/null || echo unknown)}
- **From:** ${current:-unknown}
- **To:** ${CHOSEN%.json}
- **Run:** ${GITHUB_RUN_ID:-local}

The contract addresses below are now the environment's current deployment.
Redeploy the frontend and restart the keepers so they pick them up.

\`\`\`json
$(cat "$MANIFEST_DIR/$CHOSEN")
\`\`\`
EOF

echo
echo "✓ $ENV_NAME now points at ${CHOSEN%.json}"
echo
echo "  Remaining steps (these are what actually move traffic):"
echo "    1. Redeploy the frontend with the restored contract IDs"
echo "    2. Restart the keepers against the restored perp-engine"
echo "    3. Update the environment's VITE_* repository variables"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### ⏪ Rollback: $ENV_NAME"
    echo
    echo "- From: \`${current:-unknown}\`"
    echo "- To: \`${CHOSEN%.json}\`"
    echo
    echo "Frontend redeploy and keeper restart are still required."
  } >> "$GITHUB_STEP_SUMMARY"
fi
