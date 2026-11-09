#!/usr/bin/env bash
# Install the pinned Bitwarden Secrets Manager CLI, checksum verified, into
# ~/.local/bin (or $BWS_INSTALL_DIR). Safe to re-run.
#
# Taken from Bitwarden's GitHub release rather than Homebrew: the Homebrew route
# is the one macOS blocked as malware in October 2026. The macOS binary is signed
# by Bitwarden Inc, and the check below ties this install to the published sum.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source versions.env

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  triple=aarch64-apple-darwin;     sum=$BWS_SHA256_DARWIN_ARM64 ;;
  Linux-x86_64)  triple=x86_64-unknown-linux-gnu; sum=$BWS_SHA256_LINUX_AMD64 ;;
  *) echo "no pinned bws build for $(uname -s)-$(uname -m)"; exit 1 ;;
esac

dest=${BWS_INSTALL_DIR:-$HOME/.local/bin}
if [[ -x $dest/bws && $("$dest/bws" --version) == "bws $BWS_VERSION" ]]; then
  echo "bws $BWS_VERSION already installed in $dest"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
zip="bws-$triple-$BWS_VERSION.zip"
curl -fsSL -o "$tmp/$zip" "https://github.com/bitwarden/sdk-sm/releases/download/bws-v$BWS_VERSION/$zip"

if command -v sha256sum >/dev/null; then
  actual=$(sha256sum "$tmp/$zip" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$tmp/$zip" | cut -d' ' -f1)
fi
[[ $actual == "$sum" ]] || { echo "checksum mismatch for $zip: got $actual"; exit 1; }

unzip -q -d "$tmp/out" "$tmp/$zip"
mkdir -p "$dest"
install -m 0755 "$tmp/out/bws" "$dest/bws"
echo "installed $("$dest/bws" --version) in $dest"
