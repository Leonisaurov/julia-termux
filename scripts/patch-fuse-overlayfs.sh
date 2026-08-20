#!/bin/bash
# patch-fuse-overlayfs.sh — Remove fuse-overlayfs from termux-packages.
# Just delete the block entirely; the script continues to set up the toolchain.
set -euo pipefail

TP="${1:-/home/builder/termux-packages}"
F="$TP/scripts/build/toolchain/termux_setup_toolchain_29.sh"

if [ ! -f "$F" ]; then
    echo "[patch-fuse] $F not found, skipping"
    exit 0
fi

echo "[patch-fuse] patching $F ..."

# Delete the fuse-overlayfs block entirely:
#   if ! mountpoint -q ...; then
#       fuse-overlayfs \
#           ... \
#           -o workdir=...
#   fi
awk '
/if ! mountpoint -q.*TERMUX_STANDALONE_TOOLCHAIN/ { skip=1; next }
skip && /fuse-overlayfs/ { next }
skip && /-o (lowerdir|upperdir|workdir)/ { next }
skip && /^fi$/ { skip=0; next }
skip { next }
{ print }
' "$F" > "$F.tmp" && mv "$F.tmp" "$F"

echo "[patch-fuse] done. Verifying..."
grep -n 'mountpoint\|fuse-overlayfs' "$F" || echo "[patch-fuse] OK: no fuse references remain"
