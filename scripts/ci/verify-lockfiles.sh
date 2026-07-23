#!/usr/bin/env bash
# Verify that every lockfile in the repo is present, committed and in sync with
# its manifest.
#
# A drifted lockfile means CI and production install different dependency
# versions than the developer tested — the failure mode is silent, so it is
# gated here rather than discovered later.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

fail=0
ok()   { printf '  ✓ %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*" >&2; fail=1; }
note() { printf '  · %s\n' "$*"; }

echo "→ Cargo lockfiles"

# --locked makes cargo refuse to update Cargo.lock; if the manifest and the
# lockfile disagree, this exits non-zero instead of rewriting the lockfile.
for manifest in Cargo.toml tools/e2e/Cargo.toml tools/rust-circuits/Cargo.toml keepers/Cargo.toml; do
  [ -f "$manifest" ] || continue
  lock="$(dirname "$manifest")/Cargo.lock"

  if [ "$manifest" = "Cargo.toml" ]; then
    lock="Cargo.lock"
  fi

  if [ ! -f "$lock" ]; then
    # Workspace members inherit the root lockfile; only standalone manifests
    # (those declaring their own [workspace]) need one of their own.
    if grep -q '^\[workspace\]' "$manifest"; then
      bad "$lock is missing for standalone manifest $manifest"
    else
      note "$manifest uses the workspace lockfile"
    fi
    continue
  fi

  if cargo metadata --locked --format-version 1 --manifest-path "$manifest" >/dev/null 2>&1; then
    ok "$lock in sync with $manifest"
  else
    bad "$lock is out of date — run 'cargo update --workspace --manifest-path $manifest' and commit the result"
  fi
done

echo "→ npm lockfile (app/)"

if [ ! -f app/package-lock.json ]; then
  bad "app/package-lock.json is missing"
else
  # `npm ci --dry-run` fails when package.json and package-lock.json disagree,
  # which is exactly the drift we want to catch.
  if (cd app && npm ci --dry-run --no-audit --no-fund >/dev/null 2>&1); then
    ok "app/package-lock.json in sync with app/package.json"
  else
    bad "app/package-lock.json is out of date — run 'npm install' in app/ and commit the lockfile"
  fi

  version="$(node -p "require('./app/package-lock.json').lockfileVersion")"
  if [ "$version" -lt 3 ]; then
    bad "app/package-lock.json is lockfileVersion $version; npm >= 9 (v3) is required"
  else
    ok "lockfileVersion $version"
  fi
fi

# The repo is npm-canonical. A second package manager's lockfile drifts
# silently and produces a different dependency tree than CI installs.
if [ -f app/bun.lock ] || [ -f app/yarn.lock ] || [ -f app/pnpm-lock.yaml ]; then
  bad "a non-npm lockfile exists in app/ (bun.lock / yarn.lock / pnpm-lock.yaml).
      This repo installs with 'npm ci'; delete the extra lockfile so one
      dependency tree is authoritative."
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ lockfile verification failed" >&2
  exit 1
fi

echo "✓ all lockfiles verified"
