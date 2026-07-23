#!/usr/bin/env bash
# Validate the compiled Soroban contract artifacts.
#
# `cargo build` succeeding is not enough: a contract can compile yet be
# undeployable because it is missing the metadata sections Soroban requires, or
# because it has silently grown past the size the target network accepts. Both
# failures otherwise surface at deploy time, against a funded account.
#
# Size budgets live in wasm-budgets.json — see that file for what they mean.
#
# Usage: ./scripts/ci/validate-wasm.sh [wasm-dir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WASM_DIR="${1:-$ROOT/target/wasm32v1-none/release}"
BUDGETS="$HERE/wasm-budgets.json"

# Contracts that must exist after a full build.
EXPECTED="orderbook perp_engine shielded_pool collateral verifier_groth16"

fail=0
total=0

# The budgets file is piped in rather than require()d by path: this script runs
# under MSYS bash on Windows too, where node cannot resolve a `/c/...` path.
read_budget() {
  node -e '
    let s = ""
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      const json = JSON.parse(s)
      const key = process.argv[1]
      process.stdout.write(String(key === "@warn" ? json.warn_at_percent : (json.budgets[key] ?? 0)))
    })
  ' "$1" < "$BUDGETS"
}

warn_at="$(read_budget '@warn')"

echo "→ validating contract artifacts in $WASM_DIR"

[ -d "$WASM_DIR" ] || { echo "✗ wasm directory not found: $WASM_DIR" >&2; exit 1; }

budget_for() { read_budget "$1"; }

for name in $EXPECTED; do
  path="$WASM_DIR/$name.wasm"

  if [ ! -f "$path" ]; then
    echo "  ✗ $name.wasm was not produced" >&2
    fail=1
    continue
  fi

  size="$(wc -c < "$path" | tr -d ' ')"
  total=$((total + size))

  # 1. Valid wasm module: magic bytes \0asm followed by version 1.
  magic="$(head -c 8 "$path" | od -An -tx1 | tr -d ' \n')"
  if [ "$magic" != "0061736d01000000" ]; then
    echo "  ✗ $name.wasm is not a valid wasm module (header: $magic)" >&2
    fail=1
    continue
  fi

  # 2. Contract spec: Soroban embeds a `contractspecv0` custom section
  #    describing the exported functions. Without it, clients cannot generate
  #    bindings and the contract is effectively opaque on-chain.
  if ! grep -aq 'contractspecv0' "$path"; then
    echo "  ✗ $name.wasm has no contractspecv0 section — is this a Soroban contract?" >&2
    fail=1
    continue
  fi

  # 3. Env metadata: records the SDK/protocol interface version. The network
  #    rejects contracts built against an incompatible interface.
  if ! grep -aq 'contractenvmetav0' "$path"; then
    echo "  ✗ $name.wasm has no contractenvmetav0 section" >&2
    fail=1
    continue
  fi

  # 4. Size budget — catches an unnoticed regression before deploy time.
  budget="$(budget_for "$name")"
  if [ "$budget" -eq 0 ]; then
    printf '  ⚠ %-20s %7s bytes  (no budget defined in wasm-budgets.json)\n' "$name.wasm" "$size"
    continue
  fi

  pct=$((size * 100 / budget))
  if [ "$size" -gt "$budget" ]; then
    printf '  ✗ %-20s %7s bytes  (%s%% of its %s-byte budget)\n' "$name.wasm" "$size" "$pct" "$budget" >&2
    echo "    The contract grew past its budget. If the growth is intended, raise" >&2
    echo "    the budget in scripts/ci/wasm-budgets.json in this same change." >&2
    fail=1
    continue
  fi

  printf '  ✓ %-20s %7s bytes  (%s%% of budget)\n' "$name.wasm" "$size" "$pct"
  if [ "$pct" -gt "$warn_at" ]; then
    echo "    ⚠ within ${warn_at}% of budget — consider wasm-opt -Oz or trimming the contract" >&2
  fi
done

echo "  ─────────────────────────────────────────────"
printf '  total %s bytes across %s contracts\n' "$total" "$(echo "$EXPECTED" | wc -w | tr -d ' ')"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Contract artifacts"
    echo
    echo "| Contract | Size | Budget | Used |"
    echo "| --- | ---: | ---: | ---: |"
    for name in $EXPECTED; do
      path="$WASM_DIR/$name.wasm"
      if [ ! -f "$path" ]; then
        echo "| \`$name\` | — | — | **missing** |"
        continue
      fi
      size="$(wc -c < "$path" | tr -d ' ')"
      budget="$(budget_for "$name")"
      if [ "$budget" -eq 0 ]; then
        echo "| \`$name\` | $size B | — | — |"
      else
        echo "| \`$name\` | $size B | $budget B | $((size * 100 / budget))% |"
      fi
    done
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ contract artifact validation failed" >&2
  exit 1
fi

echo "✓ all contract artifacts valid"
