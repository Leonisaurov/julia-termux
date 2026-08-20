#!/bin/bash
# patch-fuse-overlayfs.sh — Disable fuse-overlayfs in termux-packages build system.
# GitHub Actions blocks FUSE mounts via AppArmor/seccomp.
# Replaces fuse-overlayfs mount with cp of the NDK toolchain.
set -euo pipefail

TP="${1:-/home/builder/termux-packages}"
F="$TP/scripts/build/toolchain/termux_setup_toolchain_29.sh"

if [ ! -f "$F" ]; then
    echo "[patch-fuse] $F not found, skipping"
    exit 0
fi

echo "[patch-fuse] patching $F ..."

# Step 1: Replace "if ! mountpoint" with "if false" so fuse block is skipped
sed -i 's/if ! mountpoint -q "${TERMUX_STANDALONE_TOOLCHAIN}"; then/if false; then/' "$F" 2>/dev/null || \
sed -i 's/if ! mountpoint -q.*TERMUX_STANDALONE_TOOLCHAIN.*; then/if false; then/' "$F" 2>/dev/null || \
echo "[patch-fuse] WARNING: could not patch mountpoint line"

# Step 2: Remove the "return" inside the fuse block (so code falls through)
sed -i '/fuse-overlayfs/,/^fi$/{/^[[:space:]]*return$/d;}' "$F" 2>/dev/null || true

# Step 3: After the fi that closes the false block, insert cp commands
# Find the first "fi" after "if false" and add cp after it
awk '
/if false; then/ { found=1 }
found && /^fi$/ { print; print "    rm -rf \"${TERMUX_STANDALONE_TOOLCHAIN}\""; print "    cp \"${NDK}/toolchains/llvm/prebuilt/linux-x86_64\" \"${TERMUX_STANDALONE_TOOLCHAIN}\" -r"; print "    cp \"${NDK}/source.properties\" \"${TERMUX_STANDALONE_TOOLCHAIN}\""; found=0; next }
{ print }
' "$F" > "$F.tmp" && mv "$F.tmp" "$F"

echo "[patch-fuse] done. Verifying..."
grep -A2 'if false;' "$F" | head -5
