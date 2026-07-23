#!/usr/bin/env bash
# Validate the frontend production build.
#
# `vite build` exiting 0 does not prove the bundle is shippable: the entry HTML
# may reference a hashed chunk that was never emitted, static assets may be
# missing, or a secret may have been inlined into the client bundle by Vite's
# import.meta.env substitution. All three ship silently.
#
# Usage: ./scripts/ci/validate-frontend-build.sh [build-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="${1:-$ROOT/app/build/client}"

fail=0
echo "→ validating frontend build in $BUILD_DIR"

if [ ! -d "$BUILD_DIR" ]; then
  echo "✗ build directory not found: $BUILD_DIR — run 'npm run build' in app/" >&2
  exit 1
fi

# 1. Entry document.
if [ ! -s "$BUILD_DIR/index.html" ]; then
  echo "  ✗ index.html is missing or empty" >&2
  fail=1
else
  echo "  ✓ index.html present ($(wc -c < "$BUILD_DIR/index.html" | tr -d ' ') bytes)"
fi

# 2. Hashed JS/CSS bundles were emitted.
js_count="$(find "$BUILD_DIR/assets" -name '*.js' 2>/dev/null | wc -l | tr -d ' ')"
css_count="$(find "$BUILD_DIR/assets" -name '*.css' 2>/dev/null | wc -l | tr -d ' ')"

if [ "$js_count" -eq 0 ]; then
  echo "  ✗ no JavaScript bundles were emitted" >&2
  fail=1
else
  echo "  ✓ $js_count JS bundle(s), $css_count CSS bundle(s)"
fi

# 3. Every asset the entry document references actually exists. A dangling
#    reference is a blank page in production.
missing=0
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  case "$ref" in
    http*|//*|data:*|'#'*) continue ;;
  esac
  # Strip cache-busting query strings and fragments: `/favicon.png?v=3`
  # is a reference to `/favicon.png`.
  ref="${ref%%\#*}"
  ref="${ref%%\?*}"
  [ -z "$ref" ] && continue
  target="$BUILD_DIR/${ref#/}"
  if [ ! -f "$target" ]; then
    echo "  ✗ index.html references a missing asset: $ref" >&2
    missing=$((missing + 1))
  fi
done <<EOF
$(grep -oE '(src|href)="[^"]+"' "$BUILD_DIR/index.html" 2>/dev/null | sed -E 's/^(src|href)="//; s/"$//')
EOF

if [ "$missing" -gt 0 ]; then
  fail=1
else
  echo "  ✓ every referenced asset resolves"
fi

# 4. Static assets the app depends on at runtime.
for asset in favicon.ico fonts; do
  if [ ! -e "$BUILD_DIR/$asset" ]; then
    echo "  ⚠ static asset not found in build output: $asset" >&2
  fi
done

# 5. No secret material inlined into the client bundle. Vite replaces every
#    import.meta.env.VITE_* reference at build time, so a populated
#    VITE_MINTER_SECRET ends up as a literal string in shipped JavaScript.
echo "→ scanning bundle for inlined credentials"
leaks=0
for pattern in 'S[A-Z2-7]{55}' '-----BEGIN [A-Z ]*PRIVATE KEY-----'; do
  if hits="$(grep -rlE "$pattern" "$BUILD_DIR" 2>/dev/null)"; then
    if [ -n "$hits" ]; then
      echo "  ✗ credential-shaped string found in the built bundle:" >&2
      printf '%s\n' "$hits" | sed 's/^/      /' >&2
      leaks=$((leaks + 1))
    fi
  fi
done

if [ "$leaks" -gt 0 ]; then
  echo "  → a VITE_* secret was set at build time and is now public." >&2
  echo "    Rotate it, then remove it from the build environment." >&2
  fail=1
else
  echo "  ✓ no credential material in the bundle"
fi

# 6. Bundle size, reported for trend visibility.
total_kb="$(du -sk "$BUILD_DIR" | cut -f1)"
js_kb="$(find "$BUILD_DIR/assets" -name '*.js' -exec du -ck {} + 2>/dev/null | tail -1 | cut -f1 || echo 0)"
echo "→ bundle size: ${total_kb} KiB total, ${js_kb} KiB JavaScript"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Frontend bundle"
    echo
    echo "| Metric | Value |"
    echo "| --- | ---: |"
    echo "| Total build output | ${total_kb} KiB |"
    echo "| JavaScript | ${js_kb} KiB |"
    echo "| JS chunks | ${js_count} |"
    echo "| CSS chunks | ${css_count} |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ frontend build validation failed" >&2
  exit 1
fi

echo "✓ frontend build is valid and shippable"
