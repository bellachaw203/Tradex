#!/usr/bin/env bash
# Scan the working tree (or a commit range) for credential material.
#
# This is deliberately self-contained: no network, no external tool, so it runs
# identically in the pre-commit hook and in CI. Gitleaks runs alongside it in
# the security workflow for broader coverage.
#
# The highest-value patterns for this repo are Stellar secret seeds (S...) and
# raw private keys — a leaked deployer seed means a compromised protocol admin.
#
# Usage:
#   ./scripts/ci/scan-secrets.sh                 # staged + tracked files
#   ./scripts/ci/scan-secrets.sh --staged        # staged changes only (hook)
#   ./scripts/ci/scan-secrets.sh --range A..B    # files changed in a range
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

MODE="tracked"
RANGE=""
case "${1:-}" in
  --staged) MODE="staged" ;;
  --range)  MODE="range"; RANGE="${2:?--range needs a git range}" ;;
  '')       ;;
  *)        echo "unknown argument: $1" >&2; exit 2 ;;
esac

case "$MODE" in
  staged) files="$(git diff --cached --name-only --diff-filter=ACM)" ;;
  range)  files="$(git diff --name-only --diff-filter=ACM "$RANGE")" ;;
  *)      files="$(git ls-files)" ;;
esac

# Binary blobs, lockfiles and the committed proving/verifying keys are public
# by design and produce nothing but false positives.
files="$(printf '%s\n' "$files" | grep -vE '\.(png|jpg|jpeg|gif|ico|svg|woff2?|ttf|wasm|bin|ptau|zkey|r1cs|sym|ipynb)$' || true)"
files="$(printf '%s\n' "$files" | grep -vE '(^|/)(package-lock\.json|bun\.lock|Cargo\.lock)$' || true)"
files="$(printf '%s\n' "$files" | grep -vE '^circuits/keys/' || true)"
files="$(printf '%s\n' "$files" | grep -vE '^scripts/ci/scan-secrets\.sh$' || true)"
files="$(printf '%s\n' "$files" | grep -vE '^\.gitleaks\.toml$' || true)"

if [ -z "$files" ]; then
  echo "✓ no files to scan"
  exit 0
fi

# name|regex — one rule per line.
RULES='
Stellar secret seed|\bS[A-Z2-7]{55}\b
PEM private key|-----BEGIN [A-Z ]*PRIVATE KEY-----
SSH private key|-----BEGIN OPENSSH PRIVATE KEY-----
AWS access key id|\bAKIA[0-9A-Z]{16}\b
GitHub token|\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b
Slack token|\bxox[abprs]-[0-9A-Za-z-]{10,}\b
Google API key|\bAIza[0-9A-Za-z_-]{35}\b
Private key hex (64)|\b(0x)?[0-9a-fA-F]{64}\b.*(private|secret|seed|priv_?key)
Generic assignment|(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password)["'"'"']?\s*[:=]\s*["'"'"'][A-Za-z0-9_\-/+=]{16,}["'"'"']
'

hits=0
echo "→ scanning $(printf '%s\n' "$files" | wc -l | tr -d ' ') files for credential material"

while IFS= read -r rule; do
  [ -z "$rule" ] && continue
  name="${rule%%|*}"
  pattern="${rule#*|}"

  while IFS= read -r file; do
    [ -f "$file" ] || continue

    # `allowlist-secret-scan` marks a reviewed, intentional match (e.g. a
    # documented example key in prose).
    if match="$(grep -nEI "$pattern" "$file" 2>/dev/null | grep -v 'allowlist-secret-scan' || true)"; then
      if [ -n "$match" ]; then
        printf '\n✗ %s in %s\n' "$name" "$file" >&2
        # Print the location but redact the value itself so the finding does
        # not become a second copy of the secret in the CI log.
        printf '%s\n' "$match" | sed -E 's/(.{0,12}).*/  \1… [redacted]/' >&2
        hits=$((hits + 1))
      fi
    fi
  done <<EOF
$files
EOF
done <<EOF
$RULES
EOF

if [ "$hits" -gt 0 ]; then
  cat >&2 <<'MSG'

✗ potential secrets detected.

  If a match is a real credential:
    1. do NOT commit it — rotate it if it was ever pushed
    2. move the value into a GitHub Actions secret / local .env (git-ignored)

  If a match is a documented, non-sensitive example, append the marker
  `allowlist-secret-scan` on that line.
MSG
  exit 1
fi

echo "✓ no secrets detected"
