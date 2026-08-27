#!/bin/bash
# build-deps-docker.sh — Build Julia's cross-compilation dependencies inside Docker.
# Called from CI workflow via run-docker.sh.
#
# The Docker image (ghcr.io/termux/package-builder) is Ubuntu-based.
# `pkg` (Termux package manager) is NOT available. We must build each
# dependency as a separate termux-packages package so they get installed
# into the Termux prefix (/data/data/com.termux/files/usr) where the
# cross-compilation toolchain can find them.
#
# Usage: run-docker.sh bash -c '/home/builder/julia-termux/scripts/build-deps-docker.sh'
set -euo pipefail

cd /home/builder/termux-packages

# --- System build tools (Ubuntu apt, not Termux pkg) ---
# LLVM cmake needs zlib-dev, ncurses-dev on the HOST side for
# cross-compilation configuration.
echo "=== Installing host build tools ==="
sudo apt-get update -qq
sudo apt-get install -yqq ccache cmake ninja-build zlib1g-dev libtinfo-dev
. /home/builder/julia-termux/scripts/setup-ccache-docker.sh

# --- Cross-compilation dependencies ---
# Each package is built AND installed into the Termux prefix by
# build-package.sh. Julia's LLVM cmake will then find them there.
#
# Order matters: later packages may depend on earlier ones.
# The list matches TERMUX_PKG_DEPENDS in packages/julia/build.sh.
DEPS=(
  zlib
  openssl
  libgmp
  libmpfr
  pcre2
  libuv
  curl
  libnghttp2
  libssh2
  libgit2
  libopenblas
  suitesparse
  arpack-ng
  patchelf
  libandroid-support
)

echo "=== Building ${#DEPS[@]} dependencies ==="
FAILED=()
for pkg in "${DEPS[@]}"; do
  echo ""
  echo "=== [$pkg] Building... ==="
  if ./build-package.sh -I -s -a aarch64 "$pkg"; then
    echo "=== [$pkg] OK ==="
  else
    echo "=== [$pkg] FAILED (non-fatal) ==="
    FAILED+=("$pkg")
  fi
done

echo ""
echo "=== Dependency build summary ==="
echo "Total: ${#DEPS[@]}  Failed: ${#FAILED[@]}"
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "Failed packages: ${FAILED[*]}"
fi
echo "=== Done ==="
