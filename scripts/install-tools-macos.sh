#!/usr/bin/env bash
# Install the CLI prerequisites on macOS from each project's official release
# binaries: pinned versions, SHA-256 verified, no Homebrew, no compiler, no sudo.
# (Homebrew no longer builds bottles for Intel Macs, so it falls back to
# compiling from source, which needs a current Xcode.)
#
# Usage:
#   scripts/install-tools-macos.sh                 # kubectl tofu kubeseal jq k3d
#   scripts/install-tools-macos.sh kubectl jq      # only some tools
#   FORCE=1 scripts/install-tools-macos.sh         # replace versions found elsewhere on PATH
#   BIN_DIR=/usr/local/bin scripts/install-tools-macos.sh
#
# Written for the bash 3.2 that ships with macOS.
set -euo pipefail

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
FORCE="${FORCE:-0}"

KUBECTL_VERSION=1.35.10   # matches the k3s version in cluster/k3d.yaml
TOFU_VERSION=1.13.9
KUBESEAL_VERSION=0.41.2
JQ_VERSION=1.8.2
K3D_VERSION=5.9.0

case "$(uname -s)/$(uname -m)" in
  Darwin/x86_64) ARCH=amd64 ;;
  Darwin/arm64) ARCH=arm64 ;;
  *)
    echo "error: this script is for macOS (Intel or Apple silicon)" >&2
    exit 1
    ;;
esac

# Expected SHA-256 of each download, taken from the projects' published checksums.
expected_sha() {
  case "$1/$ARCH" in
    kubectl/amd64) echo 4787e20d9029871845d8a57bf56f533870f5d98d9cf3b82b6f5e2ad5eaeee3a3 ;;
    kubectl/arm64) echo 77ec066f3404edb81760865c9cd812d03c25e9a89aa0349fd3c1aa60bd5fb068 ;;
    tofu/amd64) echo ac5505dd19d896f327d0ab727d4b853413c694931a7602b31f93c3a3e9d46d00 ;;
    tofu/arm64) echo 29ba2f4c78556a8d25476e5070fe4745495ef649c4a3b827170eb7436d23feb3 ;;
    kubeseal/amd64) echo e0f74cde61699a33c6c3e35ffa0733e7aa6bbcfcd81dab7dbffaa3c98f6764eb ;;
    kubeseal/arm64) echo 4f9ce57bb69c419f1a94e88e0d2d5755b395f7926e34d99bf91bc8e084e27ae4 ;;
    jq/amd64) echo e94b266e3c26690550006abe63152b782280f4e14374accdf04cbde844f00bc0 ;;
    jq/arm64) echo 2d75340ba57a4b4b4c8708a21c2dc8e958a48aaa8bba13b27f77f6e4c0eca07e ;;
    k3d/amd64) echo b4aabc37534f95b9c764e7823f2df923f50d57600837aa60a06266cce47db732 ;;
    k3d/arm64) echo fe106541d5d0a3f18debcd4d432a16f8c0ce3e6ddc06f8fbb6f696a122313e00 ;;
    *) return 1 ;;
  esac
}

url_for() {
  case "$1" in
    kubectl) echo "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/darwin/${ARCH}/kubectl" ;;
    tofu) echo "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_darwin_${ARCH}.zip" ;;
    kubeseal) echo "https://github.com/bitnami/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-darwin-${ARCH}.tar.gz" ;;
    jq) echo "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-macos-${ARCH}" ;;
    k3d) echo "https://github.com/k3d-io/k3d/releases/download/v${K3D_VERSION}/k3d-darwin-${ARCH}" ;;
    *) return 1 ;;
  esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$BIN_DIR"

install_tool() {
  local tool="$1" url sha download actual existing
  url="$(url_for "$tool")" || { echo "unknown tool: $tool" >&2; return 1; }
  sha="$(expected_sha "$tool")"

  existing="$(command -v "$tool" || true)"
  if [[ -n "$existing" && "$existing" != "$BIN_DIR/$tool" && "$FORCE" != "1" ]]; then
    echo "skip  $tool: already installed at $existing (FORCE=1 to install the pinned version in $BIN_DIR)"
    return 0
  fi

  download="$TMP/$tool.download"
  curl -fsSL --retry 3 -o "$download" "$url"
  actual="$(shasum -a 256 "$download" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    echo "error: checksum mismatch for $url" >&2
    echo "       expected $sha" >&2
    echo "       got      $actual" >&2
    return 1
  fi

  case "$url" in
    *.zip) unzip -o -q "$download" "$tool" -d "$TMP" && mv "$TMP/$tool" "$download" ;;
    *.tar.gz) tar -xzf "$download" -C "$TMP" "$tool" && mv "$TMP/$tool" "$download" ;;
  esac
  install -m 0755 "$download" "$BIN_DIR/$tool"
  echo "ok    $tool -> $BIN_DIR/$tool"
}

tools=("$@")
((${#tools[@]})) || tools=(kubectl tofu kubeseal jq k3d)
for t in "${tools[@]}"; do
  install_tool "$t"
done

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    echo "$BIN_DIR is not on your PATH. Add it once, then open a new terminal:"
    echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc"
    ;;
esac
