#!/data/data/com.termux/files/usr/bin/bash
#
# build-lerc-bionic.sh — the LERC artifact LERC_jll needs on Termux.
#
# Why this exists: Termux packages no `libLerc` at all, and `Libtiff_jll` depends on
# `LERC_jll`, which `libwebp_jll` needs.  Measured on the device (2026-10-11): with the
# override in place, `Libtiff_jll` and `libwebp_jll` stop trying to load the glibc artifact
# (which dies on `libstdc++.so.6`) and resolve into this directory instead.
#
# This is the one artifact of the three that is a real build: FFTW needs it because Termux's
# fftw has a different layout, gettext-runtime because Termux ships no libintl, and LERC
# because Termux does not ship the library at all.
#
# Usage: build-lerc-bionic.sh <outdir>
#
# Output: <outdir>/lib/libLerc.so{,.4}, <outdir>/include, <outdir>/lib/pkgconfig, and a
# tarball next to <outdir> named lerc-bionic-<version>-aarch64.tar.gz with its .sha256.

set -euo pipefail

LERC_VERSION=4.2.0
# Pinned: the artifact is a product, so the source it comes from is pinned by content.
LERC_SHA256=a1fb593ed1fcb5b38800caf3c4454f872745202e961d00d745e53d81447e17c9
LERC_URL="https://github.com/Esri/lerc/archive/refs/tags/v${LERC_VERSION}.tar.gz"

OUT="${1:?usage: build-lerc-bionic.sh <outdir>}"
# Create the parent before normalising through `cd`, the way build-fftw-bionic.sh had to learn.
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

# 1. The source, before the prefix is anywhere near this process (bionic has no DNS on the
#    CI runners, and the host's curl only works while LD_PRELOAD is still clear).  The cache
#    path is decided and exported here so the re-exec below does not fetch again.
if [ -z "${LERC_BIONIC_CACHE:-}" ]; then
	LERC_BIONIC_CACHE="${TMPDIR:-/tmp}/lerc-${LERC_VERSION}.tar.gz"
fi
if [ ! -f "$LERC_BIONIC_CACHE" ]; then
	CURL=curl
	if [ -n "${TERMUX_BUILDER_HOSTBIN:-}" ] && [ -x "${TERMUX_BUILDER_HOSTBIN}/curl" ]; then
		CURL="${TERMUX_BUILDER_HOSTBIN}/curl"
	fi
	echo "== fetching LERC $LERC_VERSION (sha256 pinned)"
	"$CURL" -sSL --fail -o "$LERC_BIONIC_CACHE.part" "$LERC_URL"
	mv "$LERC_BIONIC_CACHE.part" "$LERC_BIONIC_CACHE"
fi
echo "$LERC_SHA256  $LERC_BIONIC_CACHE" | sha256sum -c -
export LERC_BIONIC_CACHE

# 2. Re-exec under the prefix's own bash before touching the toolchain: sourcing the action's
#    environment puts the bionic libtermux-exec in LD_PRELOAD, and the runner's glibc /bin/sh
#    dies on it ("invalid ELF header", exit 127).  Same shape as build-fftw-bionic.sh and as
#    the way build-package.sh is launched.
if [ -n "${TERMUX_BUILDER_ENV:-}" ] && [ -f "$TERMUX_BUILDER_ENV" ] &&
	[ "${LERC_BIONIC_REEXEC:-0}" != 1 ]; then
	# shellcheck disable=SC1090 # the path is the action's, not a file in this repo
	. "$TERMUX_BUILDER_ENV"
	export LERC_BIONIC_REEXEC=1
	exec "${TERMUX_BUILDER_ROOT:-/data/data/com.termux/files/usr}/bin/bash" "$0" "$@"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lerc-bionic.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

rm -rf "$OUT"
mkdir -p "$WORK/src" "$WORK/build"
tar xzf "$LERC_BIONIC_CACHE" -C "$WORK/src" --strip-components=1

echo "== configuring and building"
cmake -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
	-DCMAKE_INSTALL_PREFIX="$OUT" \
	-DBUILD_SHARED_LIBS=ON \
	-S "$WORK/src" -B "$WORK/build" > "$WORK/cmake.log"
ninja -C "$WORK/build" > "$WORK/build.log"
ninja -C "$WORK/build" install >> "$WORK/build.log"

echo "== checking what it is"
for lib in libLerc; do
	real=$(ls "$OUT/lib/$lib.so".* 2>/dev/null | head -1)
	soname="$(readelf -d "$real" | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')"
	syms="$(nm -D --defined-only "$real" | grep -c ' T ' || true)"
	needed="$(readelf -d "$real" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
	printf '   %-8s soname=%s symbols=%s needed=%s\n' "$lib" "$soname" "$syms" "$needed"
	[ "$soname" = "$lib.so.4" ] || { echo "FAIL  $lib has soname '$soname', expected $lib.so.4" >&2; exit 1; }
	[ -f "$OUT/lib/$lib.so" ] || { echo "FAIL  $lib.so (the name the JLL declares) is missing" >&2; exit 1; }
	# The acceptance criterion that matters: it must not want anything glibc.  Measured
	# before: libc++_shared.so, libdl.so, libm.so, libc.so - all bionic.
	case "$needed" in
	*libstdc++* | *libm.so.6* | *libc.so.6* | *libdl.so.2*)
		echo "FAIL  $lib wants a glibc library: $needed" >&2
		exit 1
		;;
	esac
done

echo "== acceptance: a bionic program loads it by the name the JLL declares"
cat > "$WORK/accept.c" <<'EOF'
#include <Lerc_c_api.h>
#include <stdio.h>
int main(void) {
    // A real round trip through the C API: size, encode, decode, compare.  The signatures are
    // the ones in the installed Lerc_c_api.h, not guessed (the first version of this test passed
    // nine arguments to a ten-argument function and the compiler said so).
    float data[16];
    for (int i = 0; i < 16; i++) data[i] = (float)i;
    // 4x4, one band, dataType 6 = float, all pixels valid, maxZErr 0 = exact.
    unsigned int nBytes = 0;
    if (lerc_computeCompressedSize(data, 6, 1, 4, 4, 1, 0, 0, 0.0, &nBytes) != 0 || nBytes == 0) {
        fprintf(stderr, "lerc_computeCompressedSize failed\n");
        return 1;
    }
    unsigned char blob[4096];
    unsigned int written = 0;
    if (lerc_encodeForVersion(data, -1, 6, 1, 4, 4, 1, 0, 0, 0.0,
                              blob, (unsigned int)sizeof blob, &written) != 0) {
        fprintf(stderr, "lerc_encodeForVersion failed\n");
        return 1;
    }
    float out[16];
    if (lerc_decode(blob, written, 0, 0, 1, 4, 4, 1, 6, out) != 0) {
        fprintf(stderr, "lerc_decode failed\n");
        return 1;
    }
    for (int i = 0; i < 16; i++)
        if (out[i] != data[i]) { fprintf(stderr, "round trip differs at %d\n", i); return 1; }
    printf("lerc roundtrip -> %u bytes compressed, exact\n", written);
    return 0;
}
EOF
clang -O2 -I"$OUT/include" -o "$WORK/accept" "$WORK/accept.c" -L"$OUT/lib" -lLerc
LD_LIBRARY_PATH="$OUT/lib" "$WORK/accept"

echo "== tarball"
TARBALL="$(dirname "$OUT")/lerc-bionic-${LERC_VERSION}-aarch64.tar.gz"
tar czf "$TARBALL" -C "$(dirname "$OUT")" "$(basename "$OUT")"
sha256sum "$TARBALL" > "$TARBALL.sha256"
ls -l "$TARBALL" | awk '{print "   " $5 " bytes  " $9}'
cat "$TARBALL.sha256" | sed 's/^/   /'
