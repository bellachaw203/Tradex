#!/usr/bin/env bash
# Validate the frontend's environment configuration.
#
# Checks that:
#   1. every VITE_* variable read in app/ source is documented in .env.example
#   2. .env.example documents nothing the code no longer reads
#   3. no real .env file is committed
#   4. .env.example ships no secret values
#
# Vite inlines every VITE_* variable into the client bundle, so an undocumented
# variable is a silent misconfiguration and a populated secret is a published
# secret.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

APP_DIR="app"
EXAMPLE="$APP_DIR/.env.example"
fail=0

echo "→ validating $EXAMPLE"

[ -f "$EXAMPLE" ] || { echo "✗ $EXAMPLE is missing" >&2; exit 1; }

used="$(grep -rhoE 'import\.meta\.env\.VITE_[A-Z0-9_]+' "$APP_DIR/app" \
  --include='*.ts' --include='*.tsx' 2>/dev/null \
  | sed 's/.*env\.//' | sort -u)"

documented="$(grep -oE '^[[:space:]]*#?[[:space:]]*(VITE_[A-Z0-9_]+)[[:space:]]*=' "$EXAMPLE" \
  | grep -oE 'VITE_[A-Z0-9_]+' | sort -u)"

missing="$(comm -23 <(echo "$used") <(echo "$documented") || true)"
stale="$(comm -13 <(echo "$used") <(echo "$documented") || true)"

if [ -n "$missing" ]; then
  echo "✗ read in code but absent from $EXAMPLE:" >&2
  echo "$missing" | sed 's/^/    /' >&2
  fail=1
fi

if [ -n "$stale" ]; then
  echo "✗ documented in $EXAMPLE but never read:" >&2
  echo "$stale" | sed 's/^/    /' >&2
  echo "    Remove them, or the example drifts away from the app." >&2
  fail=1
fi

[ -z "$missing$stale" ] && echo "  ✓ $(echo "$used" | wc -l | tr -d ' ') VITE_* variables documented and used"

# .env.example is a template: keys must be listed, values must be blank or
# a safe public default. Anything that looks like credential material is a leak.
echo "→ checking $EXAMPLE for secret values"
while IFS= read -r line; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  key="${line%%=*}"
  value="${line#*=}"
  [ -z "$value" ] && continue

  case "$key" in
    *SECRET*|*PRIVATE*|*KEY*|*TOKEN*|*PASSWORD*|*MNEMONIC*)
      # VITE_NETWORK_PASSPHRASE is a public network identifier, not a credential.
      case "$key" in
        VITE_NETWORK_PASSPHRASE) continue ;;
      esac
      echo "✗ $key has a non-empty value in $EXAMPLE — templates must ship empty" >&2
      fail=1
      ;;
  esac

  # A Stellar secret seed is 56 chars starting with S.
  if printf '%s' "$value" | grep -qE '\bS[A-Z2-7]{55}\b'; then
    echo "✗ $key contains what looks like a Stellar secret seed" >&2
    fail=1
  fi
done < "$EXAMPLE"
[ "$fail" -eq 0 ] && echo "  ✓ no secret values in the template"

echo "→ checking for committed .env files"
if git rev-parse --git-dir >/dev/null 2>&1; then
  tracked="$(git ls-files | grep -E '(^|/)\.env(\.|$)' | grep -v '\.env\.example$' || true)"
  if [ -n "$tracked" ]; then
    echo "✗ real environment files are tracked by git:" >&2
    echo "$tracked" | sed 's/^/    /' >&2
    fail=1
  else
    echo "  ✓ no .env files tracked"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ environment validation failed" >&2
  exit 1
fi

echo "✓ environment configuration valid"
