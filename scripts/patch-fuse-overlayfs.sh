#!/bin/bash
# patch-fuse-overlayfs.sh — Disable fuse-overlayfs in termux-packages build system.
# GitHub Actions blocks FUSE mounts via AppArmor/seccomp.
# Replaces fuse-overlayfs mount with a simple cp of the NDK toolchain.
set -euo pipefail

TP="${1:-/home/builder/termux-packages}"
F="$TP/scripts/build/toolchain/termux_setup_toolchain_29.sh"

if [ ! -f "$F" ]; then
    echo "[patch-fuse] $F not found, skipping"
    exit 0
fi

# Strategy: replace the fuse-overlayfs block with cp.
# The block looks like:
#   if ! mountpoint -q "${TERMUX_STANDALONE_TOOLCHAIN}"; then
#       fuse-overlayfs ... return
#   fi
# We replace the entire if block with cp commands.

python3 -c "
import re
with open('$F', 'r') as f:
    content = f.read()

# Match the fuse-overlayfs if block (from 'if ! mountpoint' to the next 'fi')
pattern = r'if ! mountpoint -q \"\$\{TERMUX_STANDALONE_TOOLCHAIN\}\"; then.*?^fi'
replacement = '''if true; then
    rm -rf \"\${TERMUX_STANDALONE_TOOLCHAIN}\"
    cp \"\${NDK}/toolchains/llvm/prebuilt/linux-x86_64\" \"\${TERMUX_STANDALONE_TOOLCHAIN}\" -r
    cp \"\${NDK}/source.properties\" \"\${TERMUX_STANDALONE_TOOLCHAIN}\"
fi'''

new_content = re.sub(pattern, replacement, content, count=1, flags=re.DOTALL | re.MULTILINE)

with open('$F', 'w') as f:
    f.write(new_content)

print('[patch-fuse] patched $F')
"
