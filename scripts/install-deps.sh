#!/bin/bash
set -euo pipefail

DEPS=(
  libllvm
  libopenblas blas-openblas
  suitesparse
  arpack-ng
  libgmp libmpfr
  zlib openssl
  libssh2 libgit2
  curl libnghttp2
  pcre2 utf8proc
  libuv p7zip
  patchelf lld
)

PACKAGES_URL="https://packages-cf.termux.dev/apt/termux-main/dists/stable/main/binary-aarch64/Packages"
REPO_BASE="https://packages-cf.termux.dev/apt/termux-main"

echo "=== Downloading Packages metadata ==="
curl -sL "$PACKAGES_URL" -o /tmp/Packages

echo "=== Installing dependencies ==="
for pkg in "${DEPS[@]}"; do
  echo "  -> $pkg"
  filename=$(grep -A 3 "^Package: $pkg$" /tmp/Packages | grep "^Filename:" | awk '{print $2}')
  sha256=$(grep -A 3 "^Package: $pkg$" /tmp/Packages | grep "^SHA256:" | awk '{print $2}')
  if [ -z "$filename" ]; then
    echo "     SKIP (not found in repo)"
    continue
  fi
  deb_name="${filename##*/}"
  echo "     Downloading $deb_name"
  curl -sL "${REPO_BASE}/${filename}" -o "/tmp/$deb_name"
  echo "     Verifying"
  echo "$sha256  /tmp/$deb_name" | sha256sum -c - > /dev/null 2>&1 || {
    echo "     ERROR: SHA256 mismatch for $pkg"
    rm -f "/tmp/$deb_name"
    exit 1
  }
  echo "     Extracting"
  cd /tmp
  ar x "$deb_name"
  tar xJf data.tar.xz --no-overwrite-dir -C / 2>/dev/null || true
  rm -f data.tar.xz control.tar.xz debian-binary "$deb_name"
  cd /home/builder/termux-packages
done

echo "=== All dependencies installed ==="
