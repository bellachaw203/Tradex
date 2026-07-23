#!/usr/bin/env bash
# Install a pinned CI tool from its upstream GitHub release.
#
# Prebuilt binaries rather than `cargo install` / `go install`: a source build
# of the Stellar CLI costs ~10 minutes per job, a download costs seconds.
#
# Versions are pinned by default so a CI run is reproducible; set the matching
# *_VERSION variable (or pass "latest") to move deliberately.
#
# Usage:
#   ./scripts/ci/install-tool.sh gitleaks   [version]
#   ./scripts/ci/install-tool.sh stellar    [version]
#   ./scripts/ci/install-tool.sh actionlint [version]
set -euo pipefail

TOOL="${1:?usage: install-tool.sh <gitleaks|stellar|actionlint> [version]}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Pinned known-good versions. Bump deliberately, in their own commit.
DEFAULT_GITLEAKS_VERSION=8.28.0
DEFAULT_STELLAR_VERSION=23.1.4
DEFAULT_ACTIONLINT_VERSION=1.7.7

resolve_latest() {
  # Uses GITHUB_TOKEN when present to avoid the unauthenticated rate limit.
  local repo="$1" auth=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL "${auth[@]}" "https://api.github.com/repos/$repo/releases/latest" \
    | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/'
}

install_gitleaks() {
  local version="${1:-${GITLEAKS_VERSION:-$DEFAULT_GITLEAKS_VERSION}}"
  [ "$version" = "latest" ] && version="$(resolve_latest zricethezav/gitleaks)"

  local url="https://github.com/gitleaks/gitleaks/releases/download/v${version}/gitleaks_${version}_linux_x64.tar.gz"
  echo "→ installing gitleaks $version"
  curl -fsSL "$url" -o "$TMP/gitleaks.tar.gz"
  tar -xzf "$TMP/gitleaks.tar.gz" -C "$TMP" gitleaks
  sudo install -m 0755 "$TMP/gitleaks" "$BIN_DIR/gitleaks"
  gitleaks version
}

install_stellar() {
  local version="${1:-${STELLAR_VERSION:-$DEFAULT_STELLAR_VERSION}}"
  [ "$version" = "latest" ] && version="$(resolve_latest stellar/stellar-cli)"

  local url="https://github.com/stellar/stellar-cli/releases/download/v${version}/stellar-cli-${version}-x86_64-unknown-linux-gnu.tar.gz"
  echo "→ installing stellar-cli $version"

  if curl -fsSL "$url" -o "$TMP/stellar.tar.gz"; then
    tar -xzf "$TMP/stellar.tar.gz" -C "$TMP"
    sudo install -m 0755 "$TMP/stellar" "$BIN_DIR/stellar"
  else
    # A renamed or missing release asset must not silently skip the install.
    echo "⚠ prebuilt binary unavailable at $url — falling back to cargo install" >&2
    cargo install --locked stellar-cli --version "$version"
  fi
  stellar --version
}

install_actionlint() {
  local version="${1:-${ACTIONLINT_VERSION:-$DEFAULT_ACTIONLINT_VERSION}}"
  [ "$version" = "latest" ] && version="$(resolve_latest rhysd/actionlint)"

  local url="https://github.com/rhysd/actionlint/releases/download/v${version}/actionlint_${version}_linux_amd64.tar.gz"
  echo "→ installing actionlint $version"
  curl -fsSL "$url" -o "$TMP/actionlint.tar.gz"
  tar -xzf "$TMP/actionlint.tar.gz" -C "$TMP" actionlint
  sudo install -m 0755 "$TMP/actionlint" "$BIN_DIR/actionlint"
  actionlint --version | head -1
}

case "$TOOL" in
  gitleaks)   install_gitleaks   "${2:-}" ;;
  stellar)    install_stellar    "${2:-}" ;;
  actionlint) install_actionlint "${2:-}" ;;
  *) echo "✗ unknown tool: $TOOL (expected gitleaks, stellar or actionlint)" >&2; exit 2 ;;
esac
