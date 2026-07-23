#!/usr/bin/env bash
# Decide which parts of the monorepo a change touches, and emit the result as
# GitHub Actions job outputs.
#
# This replaces a third-party path-filter action: the logic is a few lines of
# git, and keeping it here means it can be run and debugged locally.
#
# Anything that changes the pipeline itself (.github/, scripts/, deploy/) or the
# toolchain pins forces *everything* to run — a filter must never be the reason
# a broken change goes green.
#
# Usage: ./scripts/ci/changed-paths.sh [base-ref]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

BASE="${1:-}"

emit() {
  echo "$1=$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"
  return 0
}

run_all() {
  echo "→ $1: running every job" >&2
  emit contracts true
  emit frontend true
  emit circuits true
  emit tooling true
  emit docs_only false
  exit 0
}

# Manual runs, releases and anything without a comparable base run everything.
case "${GITHUB_EVENT_NAME:-}" in
  workflow_dispatch|schedule|release) run_all "event=${GITHUB_EVENT_NAME}" ;;
esac

if [ -z "$BASE" ]; then
  if [ -n "${GITHUB_BASE_REF:-}" ]; then
    BASE="origin/$GITHUB_BASE_REF"           # pull_request
  elif [ -n "${GITHUB_EVENT_BEFORE:-}" ] && [ "${GITHUB_EVENT_BEFORE}" != "0000000000000000000000000000000000000000" ]; then
    BASE="$GITHUB_EVENT_BEFORE"              # push
  else
    BASE="HEAD~1"
  fi
fi

if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
  run_all "base ref '$BASE' is not available"
fi

# Compare against the merge base so a stale branch does not appear to touch
# files that only moved on main.
MERGE_BASE="$(git merge-base "$BASE" HEAD 2>/dev/null || echo "$BASE")"
CHANGED="$(git diff --name-only "$MERGE_BASE"...HEAD)"

if [ -z "$CHANGED" ]; then
  echo "→ no files changed against $MERGE_BASE" >&2
  emit contracts false
  emit frontend false
  emit circuits false
  emit tooling false
  emit docs_only true
  exit 0
fi

echo "→ $(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ') file(s) changed against $MERGE_BASE" >&2

matches() { printf '%s\n' "$CHANGED" | grep -qE "$1"; }

# Pipeline, toolchain or lockfile changes invalidate every assumption below.
if matches '^\.github/|^scripts/|^deploy/|^Makefile$|^rust-toolchain\.toml$|^Cargo\.(toml|lock)$'; then
  run_all "pipeline or toolchain changed"
fi

contracts=false
frontend=false
circuits=false
tooling=false

matches '^(contracts|crates)/'          && contracts=true
matches '^app/'                         && frontend=true
matches '^circuits/'                    && circuits=true
matches '^(tools|keepers|infra)/'       && tooling=true

# The contracts embed the circuit verifying keys at compile time, so a circuit
# change is also a contract change.
[ "$circuits" = true ] && contracts=true

docs_only=false
if ! printf '%s\n' "$CHANGED" | grep -qvE '(\.md|\.png|\.jpg|\.svg|\.ipynb|^LICENSE$)$'; then
  docs_only=true
  echo "→ documentation-only change" >&2
fi

emit contracts "$contracts"
emit frontend "$frontend"
emit circuits "$circuits"
emit tooling "$tooling"
emit docs_only "$docs_only"
