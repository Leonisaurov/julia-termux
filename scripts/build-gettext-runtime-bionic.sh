#!/data/data/com.termux/files/usr/bin/bash
#
# build-gettext-runtime-bionic.sh — the composed override directory GettextRuntime_jll needs.
#
# Why this exists: `find $PREFIX -name 'libintl*'` on the device returns headers, jars and
# perl modules - and no library.  Termux's gettext 1.0 ships `libasprintf.so` but **not**
# `libintl`, and `GettextRuntime_jll` declares both, so the JLL's `__init__` dies on
# `dlopen .../libintl.so: not found` (measured 2026-10-11).  Glib depends on this JLL, and
# Cairo and HarfBuzz depend on Glib, so this one library was blocking the whole stack.
#
# Unlike the FFTW and LERC artifacts this is a *composed* directory, not a build product:
#   lib/libintl.so     <- built here from gettext, because the system has none
#   lib/libasprintf.so <- symlink to $PREFIX/lib/libasprintf.so
#   bin/{gettext,envsubst,ngettext} <- symlinks to the system's programs
# The symlinks are absolute $PREFIX paths on purpose: on Termux the prefix never moves, and
# the JLL resolves each declared product through `artifact_dir` anyway.
#
# Its `libasprintf` gap (10 symbols: the pre-1.0 spellings, while the system is 1.0) is a
# declared accepted gap - see Yggdrasil-termux/tools/jlls-accepted-gaps.txt.
#
# Usage: build-gettext-runtime-bionic.sh <outdir>
#
# Output: <outdir> as described above, plus a tarball next to it named
# gettext-runtime-bionic-<version>-aarch64.tar.gz with its .sha256.

set -euo pipefail

GETTEXT_VERSION=1.0
# Pinned: the artifact is a product, so the source it comes from is pinned by content.
GETTEXT_SHA256=85d99b79c981a404874c02e0342176cf75c7698e2b51fe41031cf6526d974f1a
GETTEXT_URL="https://ftp.gnu.org/pub/gnu/gettext/gettext-${GETTEXT_VERSION}.tar.gz"
# The JLL's declared products, with the kind that decides where each one has to come from.
# Read from its generated wrapper (aarch64-linux-gnu-cxx11.jl) and checked below.
PRODUCTS_LIB="lib/libintl.so lib/libasprintf.so"
PRODUCTS_EXE="bin/gettext bin/envsubst bin/ngettext"

OUT="${1:?usage: build-gettext-runtime-bionic.sh <outdir>}"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

if [ -z "${GETTEXT_BIONIC_CACHE:-}" ]; then
	GETTEXT_BIONIC_CACHE="${TMPDIR:-/tmp}/gettext-${GETTEXT_VERSION}.tar.gz"
fi
if [ ! -f "$GETTEXT_BIONIC_CACHE" ]; then
	CURL=curl
	if [ -n "${TERMUX_BUILDER_HOSTBIN:-}" ] && [ -x "${TERMUX_BUILDER_HOSTBIN}/curl" ]; then
		CURL="${TERMUX_BUILDER_HOSTBIN}/curl"
	fi
	echo "== fetching gettext $GETTEXT_VERSION (sha256 pinned)"
	"$CURL" -sSL --fail -o "$GETTEXT_BIONIC_CACHE.part" "$GETTEXT_URL"
	mv "$GETTEXT_BIONIC_CACHE.part" "$GETTEXT_BIONIC_CACHE"
fi
echo "$GETTEXT_SHA256  $GETTEXT_BIONIC_CACHE" | sha256sum -c -
export GETTEXT_BIONIC_CACHE

# Re-exec under the prefix's bash: see build-lerc-bionic.sh (glibc /bin/sh + bionic LD_PRELOAD
# is "invalid ELF header", exit 127).
if [ -n "${TERMUX_BUILDER_ENV:-}" ] && [ -f "$TERMUX_BUILDER_ENV" ] &&
	[ "${GETTEXT_BIONIC_REEXEC:-0}" != 1 ]; then
	# shellcheck disable=SC1090 # the path is the action's, not a file in this repo
	. "$TERMUX_BUILDER_ENV"
	export GETTEXT_BIONIC_REEXEC=1
	exec "${TERMUX_BUILDER_ROOT:-/data/data/com.termux/files/usr}/bin/bash" "$0" "$@"
fi

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gettext-bionic.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

rm -rf "$OUT"
mkdir -p "$WORK/src" "$OUT"
tar xzf "$GETTEXT_BIONIC_CACHE" -C "$WORK/src" --strip-components=1

echo "== configuring (only the runtime intl library is built)"
(
	cd "$WORK/src"
	# Two `test: =: unexpected operator` lines from gettext's own configure are expected and
	# harmless (measured); the build proceeds and the acceptance test below is what decides.
	./configure --prefix="$OUT" --enable-shared --disable-static --disable-libasprintf \
		--disable-csharp --disable-java --disable-native-java --disable-openmp --without-emacs \
		CC=clang CXX=clang++ CFLAGS="-O2 -fPIC" > "$WORK/configure.log"
	# gettext's tree is big; libintl lives in one subdirectory and is self-contained, so only
	# that one is built (measured: ~2 min, and it installs libintl.so with no versioned name).
	make -C gettext-runtime/intl -j2 > "$WORK/make.log"
	make -C gettext-runtime/intl install >> "$WORK/make.log"
)

echo "== composing the directory the JLL declares"
rm -f "$OUT/lib/libintl.la"
for rel in $PRODUCTS_LIB; do
	case "$rel" in
	lib/libintl.so) : ;; # built here, stays as it is
	*) ln -sfn "$PREFIX/$rel" "$OUT/$rel" ;;
	esac
done
mkdir -p "$OUT/bin"
for rel in $PRODUCTS_EXE; do
	ln -sfn "$PREFIX/$rel" "$OUT/$rel"
done

echo "== checking that every product the JLL declares resolves, and none is glibc"
missing=0
for rel in $PRODUCTS_LIB $PRODUCTS_EXE; do
	if [ ! -e "$OUT/$rel" ]; then
		echo "FAIL  $rel does not resolve" >&2
		missing=1
	fi
done
[ "$missing" -eq 0 ] || exit 1
needed="$(readelf -d "$OUT/lib/libintl.so" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
printf '   libintl.so  soname=%s symbols=%s needed=%s\n' \
	"$(readelf -d "$OUT/lib/libintl.so" | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')" \
	"$(nm -D --defined-only "$OUT/lib/libintl.so" | grep -c ' T ')" "$needed"
case "$needed" in
*libstdc++* | *libm.so.6* | *libc.so.6* | *libdl.so.2*)
	echo "FAIL  libintl.so wants a glibc library: $needed" >&2
	exit 1
	;;
esac

echo "== acceptance: a bionic program calls gettext through the built library"
cat > "$WORK/accept.c" <<'EOF'
#include <libintl.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    // With no catalogue bound, gettext returns the message unchanged - which is exactly what a
    // working libintl does before any .mo is loaded, and what this checks: that it is callable.
    const char *s = gettext("hola");
    const char *d = dgettext("dominio", "mundo");
    printf("gettext -> %s   dgettext -> %s\n", s, d);
    return (strcmp(s, "hola") == 0 && strcmp(d, "mundo") == 0) ? 0 : 1;
}
EOF
clang -O2 -I"$OUT/include" -o "$WORK/accept" "$WORK/accept.c" -L"$OUT/lib" -lintl
LD_LIBRARY_PATH="$OUT/lib" "$WORK/accept"

echo "== tarball"
TARBALL="$(dirname "$OUT")/gettext-runtime-bionic-${GETTEXT_VERSION}-aarch64.tar.gz"
tar czf "$TARBALL" -C "$(dirname "$OUT")" "$(basename "$OUT")"
sha256sum "$TARBALL" > "$TARBALL.sha256"
ls -l "$TARBALL" | awk '{print "   " $5 " bytes  " $9}'
cat "$TARBALL.sha256" | sed 's/^/   /'
