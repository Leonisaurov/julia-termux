#!/bin/bash
# patch-fuse-overlayfs.sh — Disable fuse-overlayfs in termux-packages build system.
# GitHub Actions blocks FUSE mounts via AppArmor/seccomp.
# This patches termux_setup_toolchain_29.sh to use cp instead of fuse-overlayfs.
set -euo pipefail

TP="${1:-/home/builder/termux-packages}"
F="$TP/scripts/build/toolchain/termux_setup_toolchain_29.sh"

if [ ! -f "$F" ]; then
    echo "[patch-fuse] $F not found, skipping"
    exit 0
fi

# Replace the fuse-overlayfs mount check with "if false"
sed -i 's|if ! mountpoint -q "${TERMUX_STANDALONE_TOOLCHAIN}"; then|if false; then|' "$F"

# After the fi that closes the fuse block, add cp fallback
sed -i '/^fi$/a\
rm -rf "${TERMUX_STANDALONE_TOOLCHAIN}"\
cp "${NDK}/toolchains/llvm/prebuilt/linux-x86_64" "${TERMUX_STANDALONE_TOOLCHAIN}" -r\
cp "${NDK}/source.properties" "${TERMUX_STANDALONE_TOOLCHAIN}"' "$F"

echo "[patch-fuse] patched $F"
