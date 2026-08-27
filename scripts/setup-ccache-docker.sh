#!/bin/bash
# Configure ccache for CI builds inside the package-builder container.
# This file is sourced by each docker exec because shell state is ephemeral.
set -euo pipefail

command -v ccache >/dev/null 2>&1 || {
    echo '[ccache] ccache is not installed in the builder image' >&2
    return 1 2>/dev/null || exit 1
}

: "${CCACHE_DIR:=/home/builder/.cache/ccache}"
export CCACHE_DIR
export CCACHE_BASEDIR=/home/builder
export CCACHE_COMPILERCHECK=content
export CCACHE_NOHASHDIR=true

mkdir -p "$CCACHE_DIR" "$HOME/.local/bin"
ccache --max-size=5G

for name in \
    aarch64-linux-android-clang \
    aarch64-linux-android-clang++ \
    aarch64-linux-android-gcc \
    aarch64-linux-android-g++; do
    command -v "$name" >/dev/null 2>&1 || continue
    case "$name" in
        *-clang|*-clang++|*-gcc|*-g++)
            ln -sf "$(command -v ccache)" "$HOME/.local/bin/$name"
            ;;
    esac
done
export PATH="$HOME/.local/bin:$PATH"

echo "[ccache] $(ccache --version | head -1)"
ccache --show-stats || true
