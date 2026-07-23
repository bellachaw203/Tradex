#!/usr/bin/env bash
# Generate a changelog section from Conventional Commit messages.
#
# Deliberately dependency-free (no semantic-release, no changesets): the input
# is `git log`, the output is markdown. That keeps the release path debuggable
# and keeps a supply-chain-sensitive repo from pulling a release toolchain into
# CI just to format text.
#
# Usage:
#   ./scripts/ci/changelog.sh 1.2.0                    # since the last tag
#   ./scripts/ci/changelog.sh 1.2.0 v1.1.0             # since an explicit tag
#   ./scripts/ci/changelog.sh 1.2.0 v1.1.0 --prepend   # write into CHANGELOG.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERSION="${1:?usage: changelog.sh <version> [since-tag] [--prepend]}"
SINCE="${2:-}"
PREPEND=0
[ "${2:-}" = "--prepend" ] && { SINCE=""; PREPEND=1; }
[ "${3:-}" = "--prepend" ] && PREPEND=1

if [ -z "$SINCE" ]; then
  SINCE="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo '')"
fi
RANGE="${SINCE:+$SINCE..}HEAD"

SECTION_FILE="$(mktemp)"
trap 'rm -f "$SECTION_FILE"' EXIT

REPO_URL="$(git config --get remote.origin.url 2>/dev/null | sed -E 's#git@github\.com:#https://github.com/#; s#\.git$##' || echo '')"

# Conventional-commit type → changelog heading. Types absent from this list
# (chore, style, test…) are intentionally not published: they describe work on
# the repo, not changes to the software users run.
section_for() {
  case "$1" in
    feat)     echo "### ✨ Features" ;;
    fix)      echo "### 🐛 Bug fixes" ;;
    perf)     echo "### ⚡ Performance" ;;
    refactor) echo "### ♻️ Refactoring" ;;
    docs)     echo "### 📚 Documentation" ;;
    build)    echo "### 📦 Build" ;;
    ci)       echo "### 🔧 CI/CD" ;;
    revert)   echo "### ⏪ Reverts" ;;
    *)        echo "" ;;
  esac
}

emit_section() {
  local type="$1" heading body
  heading="$(section_for "$type")"
  [ -z "$heading" ] && return 0

  body="$(git log "$RANGE" --no-merges --format='%H%x1f%s' 2>/dev/null \
    | while IFS=$(printf '\037') read -r sha subject; do
        # Match "type: …", "type(scope): …" and the breaking "!" variants.
        printf '%s' "$subject" | grep -qE "^${type}(\([^)]+\))?!?: " || continue

        scope="$(printf '%s' "$subject" | sed -nE 's/^[a-z]+\(([^)]+)\)!?:.*/\1/p')"
        text="${subject#*: }"
        short="${sha:0:7}"

        if [ -n "$REPO_URL" ]; then
          link=" ([\`$short\`]($REPO_URL/commit/$sha))"
        else
          link=" (\`$short\`)"
        fi

        if [ -n "$scope" ]; then
          echo "- **${scope}**: ${text}${link}"
        else
          echo "- ${text}${link}"
        fi
      done)"

  if [ -n "$body" ]; then
    echo "$heading"
    echo
    echo "$body"
    echo
  fi
}

# ── Build the section ───────────────────────────────────────────────────────
{
  echo "## [$VERSION] — $(date -u '+%Y-%m-%d')"
  echo

  # Breaking changes lead, because they are the reason a reader opens a
  # changelog at all.
  # Two passes rather than one: a commit body can contain newlines, so it
  # cannot be read line-by-line alongside the subject. `--grep` searches the
  # full message, `!` in the subject is matched here.
  breaking="$(
    {
      git log "$RANGE" --no-merges --format='%H%x1f%s' 2>/dev/null \
        | while IFS=$(printf '\037') read -r sha subject; do
            printf '%s' "$subject" | grep -qE '^[a-z]+(\([^)]+\))?!:' || continue
            echo "- ${subject#*: } (\`${sha:0:7}\`)"
          done
      git log "$RANGE" --no-merges --grep='^BREAKING[ -]CHANGE' --format='%H%x1f%s' 2>/dev/null \
        | while IFS=$(printf '\037') read -r sha subject; do
            echo "- ${subject#*: } (\`${sha:0:7}\`)"
          done
    } | sort -u
  )"

  if [ -n "$breaking" ]; then
    echo "### ⚠️ BREAKING CHANGES"
    echo
    echo "$breaking"
    echo
  fi

  for type in feat fix perf refactor docs build ci revert; do
    emit_section "$type"
  done

  count="$(git log "$RANGE" --no-merges --oneline 2>/dev/null | wc -l | tr -d ' ')"
  contributors="$(git log "$RANGE" --no-merges --format='%an' 2>/dev/null | sort -u | sed 's/^/- /')"

  echo "### 📊 Release details"
  echo
  echo "- Commits: $count"
  if [ -n "$SINCE" ] && [ -n "$REPO_URL" ]; then
    echo "- Full diff: [\`$SINCE...v$VERSION\`]($REPO_URL/compare/$SINCE...v$VERSION)"
  fi
  if [ -n "$contributors" ]; then
    echo
    echo "**Contributors**"
    echo
    echo "$contributors"
  fi
} > "$SECTION_FILE"

if [ "$PREPEND" -eq 1 ]; then
  header='# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Entries are generated from Conventional Commit messages by
`scripts/ci/changelog.sh` — edit the commit messages, not this file.
'
  {
    printf '%s\n' "$header"
    cat "$SECTION_FILE"
    if [ -f CHANGELOG.md ]; then
      # Drop the old preamble, keep every previously released section.
      awk '/^## \[/{found=1} found{print}' CHANGELOG.md
    fi
  } > CHANGELOG.md.new
  mv CHANGELOG.md.new CHANGELOG.md
  echo "✓ CHANGELOG.md updated for $VERSION" >&2
else
  cat "$SECTION_FILE"
fi
