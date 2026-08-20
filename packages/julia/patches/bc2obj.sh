#!/bin/sh
# bc2obj.sh — Convert a Julia bitcode archive (.bc.a) to an ELF object archive (.o.a)
# Usage: bc2obj.sh <input-bc.a> <output-o.a> <llvm-ar> <llvm-link> <llc>
# Writes to <output>.tmp so the caller can do a final mv.
set -e
INPUT="$1"
OUTPUT="$2"
LLVM_AR="$3"
LLVM_LINK="$4"
LLVM_LLC="$5"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Extract all .bc files from the archive
"$LLVM_AR" x "$INPUT" --output="$TMPDIR"

# Compile each .bc file to .o individually (avoids llvm-link module flag conflicts)
for bc in "$TMPDIR"/*.bc; do
    obj="${bc%.bc}.o"
    "$LLVM_LLC" -filetype=obj -o "$obj" "$bc"
done

# Archive all .o files into the output
"$LLVM_AR" rcs "$OUTPUT" "$TMPDIR"/*.o
