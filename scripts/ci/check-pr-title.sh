#!/usr/bin/env bash
# Validate a pull-request title against the Conventional Commits spec.
#
# This is enforced rather than merely encouraged because release.yml derives
# the semantic version bump and the changelog from merged PR titles. A title of
# "fixes" produces no release entry; a breaking change without the marker
# produces a minor bump for a change that breaks users.
#
# Usage: ./scripts/ci/check-pr-title.sh "<title>"
set -euo pipefail

TITLE="${1:?usage: check-pr-title.sh \"<title>\"}"

# Keep in lockstep with the changelog sections in scripts/ci/changelog.sh.
TYPES="feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert"

# Scopes reflect the top-level areas of the monorepo.
SCOPES="contracts|orderbook|perp-engine|shielded-pool|collateral|verifier|circuits|app|frontend|keepers|tee|tools|e2e|ci|deploy|deps|release|docs|infra"

# type(scope)!: description   — scope and `!` (breaking) are optional.
PATTERN="^(${TYPES})(\((${SCOPES})\))?!?: .+"

if ! printf '%s' "$TITLE" | grep -qE "$PATTERN"; then
  cat >&2 <<EOF
✗ PR title does not follow Conventional Commits.

  Got:      $TITLE

  Expected: <type>(<scope>)!: <description>

  Types:    ${TYPES//|/, }
  Scopes:   ${SCOPES//|/, }   (optional)
  '!'       marks a breaking change (optional)

  Examples:
    feat(perp-engine): support cross-margin liquidations
    fix(app): stop the order book flickering on reconnect
    feat(contracts)!: change the register_asset signature
    chore(deps): bump soroban-sdk to 27.0.0

  The release workflow derives the version bump and changelog from these
  titles, so the type is what decides whether a release happens at all.
EOF
  exit 1
fi

# Length: the title becomes a changelog line and a squash-merge commit subject.
length="$(printf '%s' "$TITLE" | wc -c | tr -d ' ')"
if [ "$length" -gt 100 ]; then
  echo "✗ PR title is $length characters; keep it under 100 so it reads as a commit subject." >&2
  exit 1
fi

description="${TITLE#*: }"
if [ "${#description}" -lt 10 ]; then
  echo "✗ description \"$description\" is too short to be useful in a changelog." >&2
  exit 1
fi

# A title ending in a period reads wrong as a commit subject and in a changelog.
case "$TITLE" in
  *.) echo "✗ drop the trailing period from the PR title." >&2; exit 1 ;;
esac

echo "✓ PR title follows Conventional Commits: $TITLE"

if printf '%s' "$TITLE" | grep -qE "^(${TYPES})(\((${SCOPES})\))?!:"; then
  echo "::notice::Breaking change detected — this will trigger a MAJOR version bump."
fi
