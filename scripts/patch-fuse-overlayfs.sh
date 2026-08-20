#!/bin/bash
# patch-fuse-overlayfs.sh — Replace fuse-overlayfs with cp in termux-packages.
set -euo pipefail

TP="${1:-/home/builder/termux-packages}"
F="$TP/scripts/build/toolchain/termux_setup_toolchain_29.sh"

if [ ! -f "$F" ]; then
    echo "[patch-fuse] $F not found, skipping"
    exit 0
fi

echo "[patch-fuse] patching $F ..."

# Replace the fuse-overlayfs block with cp of the NDK toolchain.
awk '
/if ! mountpoint -q.*TERMUX_STANDALONE_TOOLCHAIN/ {
    print "\t# fuse-overlayfs disabled for GitHub Actions (no /dev/fuse)"
    print "\t# Copy NDK toolchain instead of overlay mount"
    print "\tlocal _NDK_TC=\"${NDK}/toolchains/llvm/prebuilt/linux-x86_64\""
    print "\tif [ -d \"$_NDK_TC\" ]; then"
    print "\t\trm -rf \"${TERMUX_STANDALONE_TOOLCHAIN}\""
    print "\t\tcp -a \"$_NDK_TC\" \"${TERMUX_STANDALONE_TOOLCHAIN}\""
    print "\tfi"
    skip=1; next
}
skip && /fuse-overlayfs/ { next }
skip && /-o (lowerdir|upperdir|workdir)/ { next }
skip && /^[[:space:]]*fi[[:space:]]*$/ { skip=0; next }
skip { next }
{ print }
' "$F" > "$F.tmp" && mv "$F.tmp" "$F"

echo "[patch-fuse] done."
grep -c 'fuse-overlayfs' "$F" && echo "ERROR: fuse refs remain" || echo "[patch-fuse] OK: clean"
