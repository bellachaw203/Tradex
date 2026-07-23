#!/usr/bin/env bash
# Publish the built frontend bundle for an environment.
#
# `react-router build` with `ssr: false` produces a plain static SPA in
# app/build/client, so any static host will serve it. The target is chosen by
# FRONTEND_DEPLOY_TARGET in deploy/environments/<env>.env:
#
#   none    Validate the bundle and stop. The CD workflow still uploads it as a
#           downloadable artifact — the default, because publishing to a host
#           nobody configured would be a silent no-op dressed up as a success.
#   pages   Stage the bundle for actions/deploy-pages (the CD workflow does the
#           actual publish, since it needs the Pages OIDC token).
#   s3      Sync to S3_BUCKET, optionally invalidating CLOUDFRONT_DISTRIBUTION_ID.
#   rsync   rsync over SSH to RSYNC_TARGET.
#
# Usage: ./deploy/frontend.sh <environment> [--bundle <dir>]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_NAME="${1:?usage: frontend.sh <environment> [--bundle <dir>]}"
shift || true

BUNDLE="$ROOT/app/build/client"
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) BUNDLE="${2:?--bundle needs a path}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ENV_FILE="$ROOT/deploy/environments/${ENV_NAME}.env"
[ -f "$ENV_FILE" ] || { echo "✗ unknown environment '$ENV_NAME'" >&2; exit 1; }
set -a
# shellcheck disable=SC1090  # the path is built from the environment name
. "$ENV_FILE"
set +a

TARGET="${FRONTEND_DEPLOY_TARGET:-none}"

echo "→ frontend deployment: $ENV_NAME (target: $TARGET)"

# Never publish a bundle that has not been checked — this is the last point
# before it becomes public.
"$ROOT/scripts/ci/validate-frontend-build.sh" "$BUNDLE"

case "$TARGET" in
  none)
    echo "✓ bundle validated; no publish target configured for $ENV_NAME"
    echo "  Set FRONTEND_DEPLOY_TARGET in $ENV_FILE to publish it."
    ;;

  pages)
    # The workflow does the publishing; this just marks the bundle as the
    # artifact to upload and adds the SPA fallback GitHub Pages needs so deep
    # links do not 404.
    cp "$BUNDLE/index.html" "$BUNDLE/404.html"
    echo "pages-bundle=$BUNDLE" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "✓ bundle staged for GitHub Pages (404.html fallback added)"
    ;;

  s3)
    : "${S3_BUCKET:?S3_BUCKET must be set for the s3 target}"
    command -v aws >/dev/null 2>&1 || { echo "✗ aws CLI not installed" >&2; exit 1; }

    # Hashed assets are immutable and cached hard; index.html must not be, or
    # users keep loading the previous deployment.
    aws s3 sync "$BUNDLE/assets" "s3://$S3_BUCKET/assets" \
      --cache-control 'public,max-age=31536000,immutable' --delete
    aws s3 sync "$BUNDLE" "s3://$S3_BUCKET" \
      --exclude 'assets/*' --cache-control 'public,max-age=0,must-revalidate' --delete

    if [ -n "${CLOUDFRONT_DISTRIBUTION_ID:-}" ]; then
      aws cloudfront create-invalidation \
        --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" --paths '/*' >/dev/null
      echo "  ✓ CloudFront invalidation requested"
    fi
    echo "✓ published to s3://$S3_BUCKET"
    ;;

  rsync)
    : "${RSYNC_TARGET:?RSYNC_TARGET must be set for the rsync target}"
    rsync -az --delete "$BUNDLE/" "$RSYNC_TARGET/"
    echo "✓ published to $RSYNC_TARGET"
    ;;

  *)
    echo "✗ unknown FRONTEND_DEPLOY_TARGET '$TARGET' (none|pages|s3|rsync)" >&2
    exit 1
    ;;
esac

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "### Frontend: \`$ENV_NAME\` → \`$TARGET\`" >> "$GITHUB_STEP_SUMMARY"
fi
