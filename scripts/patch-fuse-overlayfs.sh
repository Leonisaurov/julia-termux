#!/bin/bash
# patch-fuse-overlayfs.sh — Remove fuse-overlayfs from termux-packages.
set -euo pipefail

TP="${1:-/home/builder/termux-packages}"
F="$TP/scripts/build/toolchain/termux_setup_toolchain_29.sh"

if [ ! -f "$F" ]; then
    echo "[patch-fuse] $F not found, skipping"
    exit 0
fi

echo "[patch-fuse] patching $F ..."

# Delete the fuse-overlayfs if-block. The fi is indented with a tab.
awk '
/if ! mountpoint -q.*TERMUX_STANDALONE_TOOLCHAIN/ { skip=1; next }
skip && /fuse-overlayfs/ { next }
skip && /-o (lowerdir|upperdir|workdir)/ { next }
skip && /^[[:space:]]*fi[[:space:]]*$/ { skip=0; next }
skip { next }
{ print }
' "$F" > "$F.tmp" && mv "$F.tmp" "$F"

echo "[patch-fuse] done. Verifying..."
grep -n 'mountpoint\|fuse-overlayfs' "$F" || echo "[patch-fuse] OK: clean"
# Show the area where the block was (should now be empty space or next code)
grep -n 'TERMUX_STANDALONE_TOOLCHAIN.*\.\|standalone-toolchain' "$F" | head -5
