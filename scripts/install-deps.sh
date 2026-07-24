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

get_stanza() {
  awk -v pkg="$1" '/^Package: /{found=($2==pkg)} found{print} /^$/{if(found) exit}' /tmp/Packages
}

echo "=== Downloading Packages metadata ==="
curl -sL "$PACKAGES_URL" -o /tmp/Packages

echo "=== Installing dependencies ==="
for pkg in "${DEPS[@]}"; do
  echo "  -> $pkg"
  stanza=$(get_stanza "$pkg")
  filename=$(echo "$stanza" | grep "^Filename:" | awk '{print $2}' || true)
  sha256=$(echo "$stanza" | grep "^SHA256:" | awk '{print $2}' || true)
  if [ -z "$filename" ]; then
    echo "     SKIP (not found in repo)"
    continue
  fi
  deb_name="${filename##*/}"
  echo "     Downloading $deb_name"
  curl -sL "${REPO_BASE}/${filename}" -o "/tmp/$deb_name"
  if [ -n "$sha256" ]; then
    echo "     Verifying"
    echo "$sha256  /tmp/$deb_name" | sha256sum -c - > /dev/null 2>&1 || {
      echo "     ERROR: SHA256 mismatch for $pkg"
      rm -f "/tmp/$deb_name"
      exit 1
    }
  fi
  echo "     Extracting"
  dpkg-deb -x "/tmp/$deb_name" / 2>/dev/null || true
  rm -f "/tmp/$deb_name"
done

echo "=== All dependencies installed ==="
