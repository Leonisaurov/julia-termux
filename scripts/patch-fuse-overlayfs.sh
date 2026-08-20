#!/bin/bash
# patch-fuse-overlayfs.sh — Disable fuse-overlayfs in termux-packages.
# Replaces fuse-overlayfs overlay mount with plain cp of NDK toolchain.
set -euo pipefail

TP="${1:-/home/builder/termux-packages}"
F="$TP/scripts/build/toolchain/termux_setup_toolchain_29.sh"

if [ ! -f "$F" ]; then
    echo "[patch-fuse] $F not found, skipping"
    exit 0
fi

echo "[patch-fuse] patching $F ..."

# Use awk to find and replace the fuse-overlayfs block.
# The block is:
#   if ! mountpoint -q "${TERMUX_STANDALONE_TOOLCHAIN}"; then
#       fuse-overlayfs \
#           "${TERMUX_STANDALONE_TOOLCHAIN}" \
#           -o lowerdir=... \
#           -o upperdir=... \
#           -o workdir=...
#   fi
# Replace with cp of the NDK toolchain.

awk '
/if ! mountpoint -q.*TERMUX_STANDALONE_TOOLCHAIN/ { found=1; next }
found && /fuse-overlayfs/ { next }
found && /-o lowerdir/ { next }
found && /-o upperdir/ { next }
found && /-o workdir/ { next }
found && /^fi$/ {
    # Replace the fi with our cp commands
    print "\trm -rf \"${TERMUX_STANDALONE_TOOLCHAIN}\""
    print "\tcp \"${NDK}/toolchains/llvm/prebuilt/linux-x86_64\" \"${TERMUX_STANDALONE_TOOLCHAIN}\" -r"
    print "\tcp \"${NDK}/source.properties\" \"${TERMUX_STANDALONE_TOOLCHAIN}\""
    found=0
    next
}
{ print }
' "$F" > "$F.tmp" && mv "$F.tmp" "$F"

echo "[patch-fuse] done. Verifying..."
grep -n 'mountpoint\|fuse-overlayfs\|TERMUX_STANDALONE_TOOLCHAIN.*cp\|TERMUX_STANDALONE_TOOLCHAIN.*rm' "$F" | head -10
