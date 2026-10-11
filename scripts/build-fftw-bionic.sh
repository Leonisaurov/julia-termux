#!/data/data/com.termux/files/usr/bin/bash
#
# build-fftw-bionic.sh — the bionic FFTW artifact FFTW_jll can load on Termux.
#
# Why this exists: FFTW_jll's official artifact is a glibc build, so on this port it
# downloads (2.8 MB of duplication) and then cannot load - `dlopen failed: library
# "libm.so.6" not found`.  Termux ships its own fftw, but with upstream's split layout
# (`fftw_init_threads` in libfftw3_threads.so, no NEON codelets) while the JLL and its
# consumer expect the official layout: threads merged into libfftw3 (that is what
# `--with-combined-threads` is for, and what FFTW.jl's libfftw3_no_init asks for).  This
# script builds the library natively with the bionic clang and packages it the way the
# official artifact is packaged, so an Overrides.toml entry can point FFTW_jll at it:
# no download, and the library actually loads.
#
# Measured on the device (2026-10-11), with the artifact installed and the official
# glibc artifact moved out of the depot:
#   libfftw3_path = .../fftw-bionic/lib/libfftw3.so
#   fft/ifft ok = true   rfft ok = true   FFTW.get_num_threads() = 2
#
# What it does NOT have: the Fortran wrappers (`dfftw_*`/`sfftw_*`), because fftw
# generates them with a Fortran compiler and this environment has none.  No Julia
# consumer calls them (FFTW.jl uses the C API), and the classifier reports them as the
# only gap against the official artifact.
#
# Usage: build-fftw-bionic.sh <outdir>
#
# Output: <outdir>/lib, <outdir>/include, <outdir>/lib/{cmake,pkgconfig}, and a tarball
# next to <outdir> named fftw-bionic-<version>-aarch64.tar.gz with its .sha256.

set -euo pipefail

FFTW_VERSION=3.3.11
# Pinned: the artifact is a product, so the source it comes from is pinned by content.
FFTW_SHA256=5630c24cdeb33b131612f7eb4b1a9934234754f9f388ff8617458d0be6f239a1
FFTW_URL="https://fftw.org/fftw-${FFTW_VERSION}.tar.gz"
# The official artifact's own naming: libtool -version-info 10:11:7 -> .so.3.7.11.
SONAME_REAL_SUFFIX="3.7.11"

OUT="${1:?usage: build-fftw-bionic.sh <outdir>}"
# Create the parent before normalising through `cd`: the first CI run normalised an
# outdir whose parent did not exist yet, the substitution came back empty, and the build
# tried to write /fftw-bionic.
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

# 1. The tarball, before the prefix is anywhere near this process.  On the CI runners
#    bionic has no DNS (the termux-builder action documents it and routes its own fetches
#    through the host's curl), so the host's curl is the one that resolves - and it only
#    works while LD_PRELOAD is still clear.  The cache path is therefore decided here and
#    exported: after the re-exec below TMPDIR is the prefix's, so a path recomputed there
#    would look empty, fetch again, and this time run the host's curl with the bionic
#    preload inherited (measured: "invalid ELF header", exit 127).
if [ -z "${FFTW_BIONIC_CACHE:-}" ]; then
	FFTW_BIONIC_CACHE="${TMPDIR:-/tmp}/fftw-${FFTW_VERSION}.tar.gz"
fi
if [ ! -f "$FFTW_BIONIC_CACHE" ]; then
	CURL=curl
	if [ -n "${TERMUX_BUILDER_HOSTBIN:-}" ] && [ -x "${TERMUX_BUILDER_HOSTBIN}/curl" ]; then
		CURL="${TERMUX_BUILDER_HOSTBIN}/curl"
	fi
	echo "== fetching fftw $FFTW_VERSION (sha256 pinned)"
	"$CURL" -sSL --fail -o "$FFTW_BIONIC_CACHE.part" "$FFTW_URL"
	mv "$FFTW_BIONIC_CACHE.part" "$FFTW_BIONIC_CACHE"
fi
echo "$FFTW_SHA256  $FFTW_BIONIC_CACHE" | sha256sum -c -
export FFTW_BIONIC_CACHE

# 2. Re-exec under the prefix's own bash before touching the toolchain, the way
#    build-package.sh is launched.  Sourcing the action's environment puts the bionic
#    libtermux-exec in LD_PRELOAD; the runner's /bin/sh is glibc, and its loader reads
#    that preload as an ELF, resolves its DT_NEEDED "libc.so" against Debian's linker
#    script and dies with "invalid ELF header" (measured: exit 127 in the first CI run).
#    Run by the prefix's bash the preload is real, /bin/sh inside configure resolves into
#    the prefix, and the FHS paths the Makefiles assume work.
if [ -n "${TERMUX_BUILDER_ENV:-}" ] && [ -f "$TERMUX_BUILDER_ENV" ] &&
	[ "${FFTW_BIONIC_REEXEC:-0}" != 1 ]; then
	# shellcheck disable=SC1090 # the path is the action's, not a file in this repo
	. "$TERMUX_BUILDER_ENV"
	export FFTW_BIONIC_REEXEC=1
	exec "${TERMUX_BUILDER_ROOT:-/data/data/com.termux/files/usr}/bin/bash" "$0" "$@"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fftw-bionic.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

rm -rf "$OUT"
mkdir -p "$OUT"

# fftw builds one precision per configure, so the official layout (libfftw3 + libfftw3f)
# is two passes into the same prefix.
for pass in double float; do
	src="$WORK/src-$pass"
	build="$WORK/build-$pass"
	mkdir -p "$src" "$build"
	tar xzf "$FFTW_BIONIC_CACHE" -C "$src" --strip-components=1
	extra=()
	[ "$pass" = float ] && extra+=(--enable-float)
	echo "== building $pass"
	(
		cd "$build"
		"$src/configure" --prefix="$OUT" --enable-shared --disable-static \
			--enable-threads --with-combined-threads --enable-neon --disable-fortran \
			"${extra[@]}" CC=clang CFLAGS="-O3 -fPIC" > "$WORK/configure-$pass.log"
		make -j2 > "$WORK/make-$pass.log"
		make install >> "$WORK/make-$pass.log"
	)
done

# libtool ignores -version-info on this host (its config.guess does not know the Android
# triplet: measured, `libfftw3.la` came out as `library_names='libfftw3.so libfftw3.so'`
# while the Makefile did carry SHARED_VERSION_INFO = 10:11:7).  The official naming is
# therefore produced here instead of relying on libtool: the real file with the version,
# the SONAME the JLL declares, and the two symlinks.
echo "== packaging the official layout"
(
	cd "$OUT/lib"
	rm -f ./*.la
	for suffix in "" f; do
		mv "libfftw3${suffix}.so" "libfftw3${suffix}.so.${SONAME_REAL_SUFFIX}"
		ln -sfn "libfftw3${suffix}.so.${SONAME_REAL_SUFFIX}" "libfftw3${suffix}.so.3"
		ln -sfn "libfftw3${suffix}.so.3" "libfftw3${suffix}.so"
		patchelf --set-soname "libfftw3${suffix}.so.3" "libfftw3${suffix}.so.${SONAME_REAL_SUFFIX}"
	done
)

echo "== checking what it is"
for lib in libfftw3 libfftw3f; do
	real="$OUT/lib/$lib.so.${SONAME_REAL_SUFFIX}"
	soname="$(readelf -d "$real" | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')"
	threads="$(nm -D --defined-only "$real" | grep -c 'init_threads' || true)"
	neon="$(nm -D --defined-only "$real" | grep -c '_neon' || true)"
	printf '   %-12s soname=%s threads=%s neon_codelets=%s\n' "$lib" "$soname" "$threads" "$neon"
	[ "$soname" = "$lib.so.3" ] || { echo "FAIL  $lib has soname '$soname', expected $lib.so.3" >&2; exit 1; }
	[ "$threads" -ge 1 ] || { echo "FAIL  $lib has no init_threads" >&2; exit 1; }
	[ "$neon" -ge 1 ] || { echo "FAIL  $lib has no NEON codelets" >&2; exit 1; }
	[ -f "$OUT/lib/$lib.so.3" ] || { echo "FAIL  $lib.so.3 missing" >&2; exit 1; }
done

# The acceptance test is not "it compiled": it is a bionic program that loads the library
# by the name the JLL declares, initializes the threads API and runs a transform - the
# same three things FFTW.jl does, and the same three that failed before.
echo "== acceptance: a bionic program loads it by soname, threads and all"
cat > "$WORK/accept.c" <<'EOF'
#include <fftw3.h>
#include <stdio.h>
int main(void) {
    if (!fftw_init_threads()) { fprintf(stderr, "fftw_init_threads failed\n"); return 1; }
    fftw_plan_with_nthreads(2);
    fftw_complex in[8], out[8];
    for (int i = 0; i < 8; i++) { in[i][0] = i; in[i][1] = 0; }
    fftw_plan p = fftw_plan_dft_1d(8, in, out, FFTW_FORWARD, FFTW_ESTIMATE);
    if (p == NULL) { fprintf(stderr, "no plan\n"); return 1; }
    fftw_execute(p);
    fftw_destroy_plan(p);
    fftw_cleanup_threads();
    printf("dc[1] = %.3f %.3f\n", out[1][0], out[1][1]);
    return 0;
}
EOF
clang -O2 -I"$OUT/include" -o "$WORK/accept" "$WORK/accept.c" -L"$OUT/lib" -lfftw3
LD_LIBRARY_PATH="$OUT/lib" "$WORK/accept"

echo "== tarball"
TARBALL="$(dirname "$OUT")/fftw-bionic-${FFTW_VERSION}-aarch64.tar.gz"
tar czf "$TARBALL" -C "$(dirname "$OUT")" "$(basename "$OUT")"
sha256sum "$TARBALL" > "$TARBALL.sha256"
ls -l "$TARBALL" | awk '{print "   " $5 " bytes  " $9}'
cat "$TARBALL.sha256" | sed 's/^/   /'
