#!/usr/bin/env bash
# Compute and apply the next semantic version.
#
# The bump is derived from the Conventional Commit messages since the last tag
# (which is why pr-quality.yml enforces the title format):
#
#   BREAKING CHANGE / `!`  → major
#   feat                   → minor
#   fix, perf              → patch
#   anything else only     → no release
#
# Version lives in [workspace.package] in the root Cargo.toml; every crate
# inherits it. app/package.json is kept in step so the frontend reports the
# same version as the contracts it talks to.
#
# Usage:
#   ./scripts/ci/bump-version.sh                 # detect bump, apply it
#   ./scripts/ci/bump-version.sh --dry-run       # report only, change nothing
#   ./scripts/ci/bump-version.sh --set 1.4.0     # force an explicit version
#   ./scripts/ci/bump-version.sh --level minor   # force a bump level
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

DRY_RUN=0
FORCED_VERSION=""
FORCED_LEVEL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --set)     FORCED_VERSION="${2:?--set needs a version}"; shift 2 ;;
    --level)   FORCED_LEVEL="${2:?--level needs major|minor|patch}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

current="$(grep -m1 -A5 '^\[workspace\.package\]' Cargo.toml | grep -m1 '^version' | sed -E 's/.*"([^"]+)".*/\1/')"
[ -n "$current" ] || { echo "✗ could not read version from [workspace.package] in Cargo.toml" >&2; exit 1; }

last_tag="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo '')"
if [ -n "$last_tag" ]; then
  range="${last_tag}..HEAD"
else
  range="HEAD"
fi

echo "→ current version: $current"
echo "→ commit range:    ${last_tag:-<repo start>}..HEAD"

# ── Work out the bump level ─────────────────────────────────────────────────
if [ -n "$FORCED_VERSION" ]; then
  next="$FORCED_VERSION"
  level="explicit"
else
  commits="$(git log --format='%s%n%b' "$range" 2>/dev/null || echo '')"

  level=""
  if printf '%s' "$commits" | grep -qE '^BREAKING[ -]CHANGE' \
     || printf '%s' "$commits" | grep -qE '^[a-z]+(\([^)]+\))?!:'; then
    level="major"
  elif printf '%s' "$commits" | grep -qE '^feat(\([^)]+\))?:'; then
    level="minor"
  elif printf '%s' "$commits" | grep -qE '^(fix|perf)(\([^)]+\))?:'; then
    level="patch"
  fi

  [ -n "$FORCED_LEVEL" ] && level="$FORCED_LEVEL"

  if [ -z "$level" ]; then
    echo "→ no release-worthy commits (no feat / fix / perf / breaking change)"
    {
      echo "release=false"
      echo "level=none"
      echo "current=$current"
      echo "version=$current"
    } >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "release=false"
    exit 0
  fi

  IFS=. read -r major minor patch <<EOF
$current
EOF
  # A 0.x version is pre-1.0: a breaking change bumps the minor, not the major,
  # which is what the ecosystem expects and what cargo's resolver assumes.
  case "$level" in
    major)
      if [ "$major" -eq 0 ]; then
        echo "→ pre-1.0: treating the breaking change as a minor bump"
        next="0.$((minor + 1)).0"
        level="minor (pre-1.0 breaking)"
      else
        next="$((major + 1)).0.0"
      fi
      ;;
    minor) next="$major.$((minor + 1)).0" ;;
    patch) next="$major.$minor.$((patch + 1))" ;;
    *) echo "✗ unknown bump level: $level" >&2; exit 2 ;;
  esac
fi

if ! printf '%s' "$next" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
  echo "✗ '$next' is not a valid semantic version" >&2
  exit 1
fi

if git rev-parse --verify --quiet "refs/tags/v$next" >/dev/null; then
  echo "✗ tag v$next already exists" >&2
  exit 1
fi

echo "→ bump level:      $level"
echo "→ next version:    $next"

{
  echo "release=true"
  echo "level=$level"
  echo "current=$current"
  echo "version=$next"
  echo "tag=v$next"
} >> "${GITHUB_OUTPUT:-/dev/null}"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "→ dry run: no files changed"
  exit 0
fi

# ── Apply ───────────────────────────────────────────────────────────────────
# Only the version inside [workspace.package] is touched — a naive
# s/0.1.0/0.2.0/ would also rewrite dependency version requirements.
node -e '
  const fs = require("fs")
  const [file, from, to] = process.argv.slice(1)
  const src = fs.readFileSync(file, "utf8")
  const section = /(\[workspace\.package\][^[]*?\nversion\s*=\s*")([^"]+)(")/
  if (!section.test(src)) throw new Error("[workspace.package] version not found in " + file)
  const out = src.replace(section, (_, a, cur, c) => {
    if (cur !== from) throw new Error(`expected version ${from}, found ${cur}`)
    return a + to + c
  })
  fs.writeFileSync(file, out)
' Cargo.toml "$current" "$next"
echo "  ✓ Cargo.toml [workspace.package] → $next"

node -e '
  const fs = require("fs")
  const [file, to] = process.argv.slice(1)
  const pkg = JSON.parse(fs.readFileSync(file, "utf8"))
  pkg.version = to
  // Re-serialise with the trailing newline npm itself writes.
  fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n")
' app/package.json "$next"
echo "  ✓ app/package.json → $next"

# Cargo.lock records member versions, so refresh it without touching anything
# else in the dependency graph.
cargo update --workspace --offline >/dev/null 2>&1 || cargo update --workspace >/dev/null
echo "  ✓ Cargo.lock refreshed"

(cd app && npm install --package-lock-only --no-audit --no-fund >/dev/null)
echo "  ✓ app/package-lock.json refreshed"

echo "✓ version bumped: $current → $next"
