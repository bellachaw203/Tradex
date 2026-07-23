#!/usr/bin/env bash
# Restore an environment's deployment manifests from the most recent CD run.
#
# Deployment history has to survive between workflow runs, or rollback has
# nothing to roll back to. Manifests are carried forward in the CD workflow's
# artifacts rather than committed, so this workflow needs no write access to
# the repository — a deploy job that can push to main is a much larger blast
# radius than one that cannot.
#
# Missing history is not an error: the first deploy to a new environment
# legitimately has none.
#
# Usage: GH_TOKEN=... ./scripts/ci/restore-manifests.sh <environment>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ENV_NAME="${1:?usage: restore-manifests.sh <environment>}"
REPO="${GITHUB_REPOSITORY:-}"
DEST="$ROOT/deploy/manifests/$ENV_NAME"

if [ -z "$REPO" ] || ! command -v gh >/dev/null 2>&1; then
  echo "· not running in Actions (or gh unavailable) — keeping local manifests"
  exit 0
fi

mkdir -p "$DEST"

echo "→ looking for previous deployment manifests for '$ENV_NAME'"

# Newest first; artifact names are deployment-<env>-<run_id>.
artifact="$(gh api "repos/$REPO/actions/artifacts?per_page=100" \
  --jq "[.artifacts[]
         | select(.expired == false)
         | select(.name | startswith(\"deployment-${ENV_NAME}-\"))]
        | sort_by(.created_at) | reverse | .[0].id" 2>/dev/null || echo 'null')"

if [ -z "$artifact" ] || [ "$artifact" = "null" ]; then
  echo "· no previous deployment artifact found — this looks like the first deploy to $ENV_NAME"
  exit 0
fi

echo "→ downloading artifact $artifact"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if ! gh api "repos/$REPO/actions/artifacts/$artifact/zip" > "$tmp/manifests.zip" 2>/dev/null; then
  echo "⚠ could not download artifact $artifact — continuing without history" >&2
  exit 0
fi

unzip -qo "$tmp/manifests.zip" -d "$tmp/extracted" || {
  echo "⚠ artifact $artifact is not a readable zip — continuing without history" >&2
  exit 0
}

# The artifact is uploaded with the manifest directory as its root, so its
# contents land directly in the environment's directory.
count=0
while IFS= read -r file; do
  cp "$file" "$DEST/"
  count=$((count + 1))
done < <(find "$tmp/extracted" -type f \( -name '*.json' -o -name '*.log' -o -name '*.md' \))

echo "✓ restored $count manifest file(s) into $DEST"

if [ -f "$DEST/latest.json" ]; then
  node -e '
    const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))
    console.log(`  previous deployment: ${m.timestamp} (commit ${String(m.commit).slice(0, 8)})`)
  ' "$DEST/latest.json" || true
fi
