#!/data/data/com.termux/files/usr/bin/bash
# Static gate for packages/<pkg>/build.sh: replays the patch stage, the
# endianness decision the patched tree makes, the configure stage and Julia's
# own Make.inc parse against the real upstream tarball WITHOUT compiling
# anything.
#
# Why this exists: a *.patch that no longer matches upstream silently produces a
# `.rej` and a half-patched tree, and a USE_SYSTEM_* flag pointing at a library
# Termux does not ship only fails ~70 minutes into a CI build.  All of it is
# answerable in seconds from the tarball and $PREFIX, so CI is not allowed to
# start until it is.
#
# Usage: bash scripts/rehearse-recipe.sh [package]      (default: julia)
#   REHEARSAL_KEEP=1  leave the workdir in place for inspection
#   REHEARSAL_CACHE=...  where the source tarball is cached
#                     (default $PREFIX/tmp/<pkg>-rehearse-cache)
#   REHEARSAL_SKIP_DOWNLOAD=1  fail instead of fetching the tarball
set -uo pipefail

PKG="${1:-julia}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECIPE="$REPO_ROOT/packages/$PKG/build.sh"
[ -f "$RECIPE" ] || { echo "no recipe at $RECIPE" >&2; exit 2; }

CACHE_DIR="${REHEARSAL_CACHE:-$PREFIX/tmp/$PKG-rehearse-cache}"
KEEP="${REHEARSAL_KEEP:-0}"
WORK="$(mktemp -d "$PREFIX/tmp/$PKG-rehearse.XXXXXX")"
cleanup() {
	if [ "$KEEP" = 1 ]; then
		echo "# workdir kept at $WORK"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT

mkdir -p "$CACHE_DIR"

recipe_var() { grep -m1 "^$1=" "$RECIPE" | cut -d= -f2- | tr -d '\r'; }
VERSION="$(recipe_var TERMUX_PKG_VERSION)"
SRCURL="$(recipe_var TERMUX_PKG_SRCURL)"
SHA256="$(recipe_var TERMUX_PKG_SHA256)"
[ -n "$VERSION" ] && [ -n "$SRCURL" ] || { echo "cannot read TERMUX_PKG_VERSION/TERMUX_PKG_SRCURL" >&2; exit 2; }
SRCURL="${SRCURL//\$\{TERMUX_PKG_VERSION\}/$VERSION}"
TARBALL="$CACHE_DIR/$(basename "${SRCURL%%\?*}")"

echo "== package=$PKG version=$VERSION"
echo "== srcurl=$SRCURL"

if [ ! -f "$TARBALL" ]; then
	if [ "${REHEARSAL_SKIP_DOWNLOAD:-0}" = 1 ]; then
		echo "FAIL  no cached tarball at $TARBALL and REHEARSAL_SKIP_DOWNLOAD=1"
		exit 3
	fi
	echo "== downloading source tarball (sources only, no compilation)"
	curl --fail --location --retry 3 -o "$TARBALL.part" "$SRCURL" || { echo "download failed" >&2; exit 3; }
	mv "$TARBALL.part" "$TARBALL"
fi
if [ -n "$SHA256" ]; then
	if sha256sum "$TARBALL" | grep -q "^$SHA256 "; then
		echo "PASS  sha256 matches the recipe pin"
	else
		echo "FAIL  sha256 mismatch: expected $SHA256, got $(sha256sum "$TARBALL" | cut -d' ' -f1)"
		exit 4
	fi
else
	echo "WARN  TERMUX_PKG_SHA256 empty in the recipe"
fi

SRCDIR="$WORK/src"
mkdir -p "$SRCDIR"
tar -xf "$TARBALL" -C "$SRCDIR" || { echo "extract failed" >&2; exit 3; }
SRCDIR="$(find "$SRCDIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
echo "== source tree: $(basename "$SRCDIR")"

# ---- replay termux_step_patch_package() ----
# Same file selection (maxdepth 1, *.patch), same @TOKEN@ substitution, same
# `patch -p1`.  Deliberately NOT --silent: a patch that fails must be named.
# Values mirror the on-device Termux environment; a recipe whose patches use a
# token we do not substitute would apply garbage, so the token list is checked.
TOKENS="TERMUX_APP_PACKAGE TERMUX_BASE_DIR TERMUX_CACHE_DIR TERMUX_HOME TERMUX_PREFIX TERMUX_PREFIX_CLASSICAL TERMUX_ENV__S_TERMUX TERMUX_ENV__S_TERMUX_APP TERMUX_ENV__S_TERMUX_API_APP TERMUX_ENV__S_TERMUX_ROOTFS TERMUX_ENV__S_TERMUX_EXEC"
# TERMUX_PREFIX resolves to the real prefix: the point of the rehearsal is to
# catch a substituted patch text that no longer matches upstream.
sed_cmd=""
for tok in $TOKENS; do
	case "$tok" in
		TERMUX_APP_PACKAGE) val=com.termux ;;
		TERMUX_BASE_DIR|TERMUX_PREFIX|TERMUX_PREFIX_CLASSICAL) val="$PREFIX" ;;
		TERMUX_CACHE_DIR) val="$PREFIX/lib" ;;
		TERMUX_HOME) val="${TERMUX_ANDROID_HOME:-$HOME}" ;;
		*) val="" ;;
	esac
	sed_cmd="$sed_cmd -e s%@$tok@%$val%g"
done

echo
echo "===== patch stage report ====="
patch_fail=0
applied_count=0
for patch in $(find "$REPO_ROOT/packages/$PKG" -mindepth 1 -maxdepth 1 \
	-name '*.patch' -o -name '*.patch'"${TERMUX_ARCH_BITS:-64}" | sort); do
	name="$(basename "$patch")"
	if grep -q '@TERMUX[A-Z_]*@' "$patch"; then
		subst_note=" (tokens substituted)"
	else
		subst_note=""
	fi
	if (cd "$SRCDIR" && eval "sed $sed_cmd" "\"$patch\"" | patch -p1 -f --dry-run > "$WORK/dry.txt" 2>&1); then
		if (cd "$SRCDIR" && eval "sed $sed_cmd" "\"$patch\"" | patch -p1 -f > "$WORK/apply.txt" 2>&1); then
			printf 'APPLY %-46s ok%s\n' "$name" "$subst_note"
			applied_count=$((applied_count + 1))
		else
			printf 'FAIL  %-46s applied cleanly in dry-run but not for real\n' "$name"
			sed 's/^/        /' "$WORK/apply.txt"
			patch_fail=$((patch_fail + 1))
		fi
	else
		printf 'FAIL  %-46s does not apply\n' "$name"
		grep -E 'hunk|Reversed|does not apply|malformed|can.t find|No such file' "$WORK/dry.txt" \
			| head -6 | sed 's/^/        /'
		patch_fail=$((patch_fail + 1))
	fi
done
echo "-- $applied_count patch file(s) applied against $(basename "$SRCDIR") --"

# ---- the endianness decision the patched tree actually makes ----
# flisp's `#if BYTE_ORDER == BIG_ENDIAN` guards a branch upstream never
# compiles and that does not even parse (src/flisp/flisp.c:990 is a #define
# without its line continuation), so when <sys/endian.h> and dtypes.h form a
# macro cycle the build dies there instead of at a #error (run 37803324627).
# Preprocessing one header answers the question for free; compiling flisp.c
# costs a runner minute to learn the same thing.
echo
echo "===== endianness macros ====="
endian_fail=0
cat > "$WORK/endian-probe.c" <<'EOF'
#include "src/support/dtypes.h"
#if BYTE_ORDER == BIG_ENDIAN
#error "the big-endian branch would be compiled"
#endif
int probe_byte_order_is_little[BYTE_ORDER == LITTLE_ENDIAN ? 1 : -1];
EOF
if clang -std=gnu11 -fsyntax-only -I "$SRCDIR" "$WORK/endian-probe.c" 2> "$WORK/endian.txt"; then
	echo "OK    BYTE_ORDER resolves to a value; flisp's big-endian branch stays dead"
else
	echo "FAIL  the patched tree does not settle BYTE_ORDER"
	grep -E 'error|is not defined|expanded from' "$WORK/endian.txt" | head -8 | sed 's/^/        /'
	endian_fail=1
fi

# ---- run the recipe's own configure steps ----
mkdir -p "$WORK/massage"
TERMUX_PKG_BUILDER_DIR="$REPO_ROOT/packages/$PKG" \
TERMUX_PKG_SRCDIR="$SRCDIR" \
TERMUX_PKG_BUILDDIR="$SRCDIR" \
TERMUX_PKG_MASSAGEDIR="$WORK/massage" \
TERMUX_PKG_DATADIR="$WORK/data" \
TERMUX_PKG_TMPDIR="$WORK/tmp" \
TERMUX_PKG_CACHEDIR="$CACHE_DIR" \
TERMUX_PKG_VERSION="$VERSION" \
TERMUX_PKG_MAKE_PROCESSES=1 \
TERMUX_PREFIX="$PREFIX" \
TERMUX_BASE_DIR="$PREFIX" \
TERMUX_ANDROID_HOME="${TERMUX_ANDROID_HOME:-$HOME}" \
TERMUX_APP_PACKAGE=com.termux \
TERMUX_ARCH=aarch64 \
TERMUX_ARCH_BITS=64 \
TERMUX_API_LEVEL="${TERMUX_API_LEVEL:-35}" \
TERMUX_HOST_PLATFORM="aarch64-linux-android" \
TERMUX_ON_DEVICE_BUILD=true \
TERMUX_DEBUG_BUILD=false \
	bash -c '
		set +e -o pipefail
		cd "'"$SRCDIR"'" || exit 9
		termux_error_exit() { echo "termux_error_exit: $*" >&2; exit 7; }
		source "'"$RECIPE"'"
		termux_step_pre_configure > '"$WORK/pre-stderr.txt"' 2>&1
		echo $? > '"$WORK/pre-rc.txt"'
		[ "$(cat '"$WORK/pre-rc.txt"')" = 0 ] || exit 0
		termux_step_configure > '"$WORK/conf-stderr.txt"' 2>&1
		echo $? > '"$WORK/conf-rc.txt"'
	' 2>"$WORK/env-stderr.txt"
PRE_RC=$(cat "$WORK/pre-rc.txt" 2>/dev/null || echo "n/a")
CONF_RC=$(cat "$WORK/conf-rc.txt" 2>/dev/null || echo "n/a")

echo
echo "===== recipe hooks ====="
printf 'pre_configure rc=%s\n' "$PRE_RC"
[ -s "$WORK/pre-stderr.txt" ] && sed 's/^/   /' "$WORK/pre-stderr.txt" | head -10
printf 'configure   rc=%s\n' "$CONF_RC"
[ -s "$WORK/conf-stderr.txt" ] && sed 's/^/   /' "$WORK/conf-stderr.txt" | head -10
[ -s "$WORK/env-stderr.txt" ] && { echo "-- sourcing errors --"; sed 's/^/   /' "$WORK/env-stderr.txt" | head -10; }

# ---- the generated configuration must not resurrect the cross-build hacks ----
echo
echo "===== Make.user ====="
if [ ! -f "$SRCDIR/Make.user" ]; then
	echo "FAIL  termux_step_configure produced no Make.user"
	make_user_fail=1
	MU=/dev/null
else
	make_user_fail=0
	MU="$WORK/Make.user"
	cp "$SRCDIR/Make.user" "$MU"
	for banned in XC_HOST HOSTCC HOST_CMAKEFLAGS BUILDOFFLINE flang F77= RT_LLVM_LINK_ARGS \
		USE_SYSTEM_LLVM:=1 JULIA_PRECOMPILE:=0 'usr-staging' '@TERMUX_'; do
		if grep -q "$banned" "$MU"; then
			printf 'FAIL  Make.user still carries %s\n' "$banned"
			make_user_fail=$((make_user_fail + 1))
		fi
	done
	grep -Ec '^[a-zA-Z_]+ *[:?]?=' "$MU" | sed 's/^/   settings: /'
	grep -E '^(USE_SYSTEM_|DISABLE_|USE_BLAS|JULIA_PRECOMPILE|CLANG_RT_BUILTINS|prefix|LOCALBASE)' "$MU" \
		| sed 's/^/   /'
fi

# ---- Make.inc must accept the generated Make.user ----
# Make.inc decides at parse time whether the toolchain is usable: it hardcodes
# FC := gfortran (Make.inc:541) and aborts the build when the compiler behind it
# does not answer `-dM -E` with __GNUC__ (Make.inc:1431).  That check fires
# before a single object file is compiled, so it costs an hour to learn from CI
# and a second to learn here.
echo
echo "===== Make.inc parse ====="
inc_fail=0
if [ "$make_user_fail" -gt 0 ]; then
	echo "SKIP  no Make.user to parse"
elif [ ! -f "$SRCDIR/Make.inc" ]; then
	echo "FAIL  $SRCDIR/Make.inc absent"
	inc_fail=1
else
	probe="$SRCDIR/rehearse-parse-probe.mk"
	{
		echo 'JULIAHOME := $(CURDIR)'
		echo 'include Make.inc'
		echo 'rehearse-parse-probe:'
		printf '\t@echo "OS=$(OS) USECLANG=$(USECLANG) USEGCC=$(USEGCC) FC=$(FC) FC_VERSION=$(FC_VERSION)"\n'
	} > "$probe"
	parse_out=$(cd "$SRCDIR" && make -f "$(basename "$probe")" rehearse-parse-probe 2>&1)
	parse_rc=$?
	rm -f "$probe"
	printf '%s\n' "$parse_out" | tail -8 | sed 's/^/   /'
	if [ "$parse_rc" -ne 0 ]; then
		printf 'FAIL  Make.inc rejected the configuration (rc=%s)\n' "$parse_rc"
		inc_fail=1
	else
		# Empty FC_VERSION means the guard in Make.inc:1431 would fire; the parse
		# succeeds only because nothing here calls $(error) yet - check the value.
		printf '%s\n' "$parse_out" | grep -Eq 'FC_VERSION=[^ "]' \
			&& echo "OK    Make.inc parses the configuration" \
			|| { echo "FAIL  FC_VERSION is empty: Make.inc would demand a fortran compiler"; inc_fail=1; }
	fi
fi

# ---- every USE_SYSTEM_* := 1 must be backed by a real library or binary ----
echo
echo "===== system dependency reality check ====="
dep_fail=0
# name=<file under $PREFIX/lib|lib/julia|bin>  ; a leading "bin:" marks an executable
check_lib() {
	if [ -e "$PREFIX/lib/$1" ] || [ -e "$PREFIX/lib/julia/$1" ]; then
		printf 'OK    %-34s %s\n' "$2" "lib/$1"
	else
		printf 'FAIL  %-34s needs %s, absent in %s/lib\n' "$2" "$1" "$PREFIX"
		dep_fail=$((dep_fail + 1))
	fi
}
check_bin() {
	if command -v "$1" >/dev/null 2>&1; then
		printf 'OK    %-34s %s\n' "$2" "$(command -v "$1")"
	else
		printf 'FAIL  %-34s needs %s on PATH\n' "$2" "$1"
		dep_fail=$((dep_fail + 1))
	fi
}
while read -r flag _rest; do
	case "$flag" in
		USE_SYSTEM_ZLIB) check_lib libz.so "$flag" ;;
		USE_SYSTEM_PCRE) check_lib libpcre2-8.so "$flag" ;;
		USE_SYSTEM_GMP) check_lib libgmp.so "$flag" ;;
		USE_SYSTEM_MPFR) check_lib libmpfr.so "$flag" ;;
		USE_SYSTEM_OPENSSL) check_lib libcrypto.so "$flag" ;;
		USE_SYSTEM_LIBSSH2) check_lib libssh2.so "$flag" ;;
		USE_SYSTEM_NGHTTP2) check_lib libnghttp2.so "$flag" ;;
		USE_SYSTEM_CURL) check_lib libcurl.so "$flag" ;;
		USE_SYSTEM_LIBGIT2) check_lib libgit2.so "$flag" ;;
		USE_SYSTEM_LIBSUITESPARSE) check_lib libcholmod.so "$flag" ;;
		USE_SYSTEM_BLAS) check_lib libopenblas.so "$flag" ;;
		USE_SYSTEM_LAPACK) check_lib libopenblas.so "$flag" ;;
		USE_SYSTEM_LIBM) : ;; # bionic's libm comes from the system, not $PREFIX
		USE_SYSTEM_CSL) : ;;   # deliberately no libgcc_s/libstdc++ on bionic
		USE_SYSTEM_PATCHELF) check_bin patchelf "$flag" ;;
		USE_SYSTEM_P7ZIP) check_bin 7z "$flag" ;;
		USE_SYSTEM_LLD) check_bin lld "$flag" ;;
		*) printf 'WARN  %-34s no probe defined here\n' "$flag" ;;
	esac
done <<EOF
$(grep -E '^USE_SYSTEM_[A-Z0-9_]+ *:?= *1' "$MU" 2>/dev/null)
EOF

# dsymutil/ar/ranlib/objcopy are pulled by the symlink rules of base/Makefile
# when USE_SYSTEM_LLD is on; a missing one fails `make install`, not `make`.
for tool in dsymutil ar ranlib objcopy readelf cmake perl m4 patchelf which file pkg-config python xz curl git clang clang++ ld; do
	check_bin "$tool" "build tool $tool"
done

# ---- deps patches: the recipe copies them, deps/*.mk names them ----
echo
echo "===== bundled-dep patches ====="
ext_fail=0
if [ -d "$SRCDIR/deps/patches" ]; then
	for ref in $(grep -rho '\$(SRCDIR)/patches/[A-Za-z0-9_.-]*\.patch' "$SRCDIR"/deps/*.mk 2>/dev/null | sort -u); do
		rel="${ref#\$\(SRCDIR\)/}"
		if [ -e "$SRCDIR/deps/$rel" ] || [ -e "$SRCDIR/$rel" ]; then
			printf 'OK    %s\n' "$ref"
		else
			# $(SRCDIR) is redefined to deps/ inside deps/Makefile, so a name
			# pointing at a file Julia does not ship is a build-time dead rule.
			printf 'MISS  %-64s referenced by deps/*.mk, not in the tree\n' "$ref"
			ext_fail=$((ext_fail + 1))
		fi
	done
else
	echo "WARN  no deps/patches directory after pre_configure"
fi

# Julia's own LLVM patch rules name their files through a macro, so the grep
# above cannot see them; for LLVM < 19 the ittapi-cmake patch is a hard
# prerequisite of the LLVM build.
for name in $(grep -oE 'call (LLVM_PATCH|LLVM_PROJ_PATCH),[A-Za-z0-9_.-]+' "$SRCDIR"/deps/*.mk \
	| sed 's/.*,//' | sort -u); do
	if [ -e "$SRCDIR/deps/patches/$name.patch" ]; then
		printf 'OK    $(SRCDIR)/patches/%s.patch\n' "$name"
	else
		printf 'MISS  $(SRCDIR)/patches/%s.patch (LLVM rule, absent from the tarball)\n' "$name"
		ext_fail=$((ext_fail + 1))
	fi
done

# ---- our deps/*.patch files must apply to the tarball the deps build fetches ----
# The rules above only prove the file name resolves.  deps/*.mk fetches each
# bundled dep from api.github.com at a SHA pinned in deps/*.version, so replay
# the patch against that exact source, the way `make -C deps` will.
echo
echo "===== bundled-dep patch application ====="
dep_patch_fail=0
for mk in "$SRCDIR"/deps/*.mk; do
	dep="$(basename "$mk" .mk)"
	for ref in $(grep -o '\$(SRCDIR)/patches/termux-[A-Za-z0-9_.-]*\.patch' "$mk" 2>/dev/null); do
		patchfile="$SRCDIR/deps/${ref#\$\(SRCDIR\)/}"
		var="$(grep -m1 -o '^[A-Z_]*_TAR_URL' "$mk" | cut -d_ -f1)"
		url="$(grep -m1 "^${var}_TAR_URL" "$mk" | cut -d= -f2- | tr -d ' \r')"
		sha="$(grep -m1 "^${var}_SHA1" "$SRCDIR/deps/$dep.version" 2>/dev/null | cut -d= -f2- | tr -d ' \r')"
		if [ -z "$url" ] || [ -z "$sha" ]; then
			printf 'FAIL  %-40s cannot resolve %s_TAR_URL/%s_SHA1 from deps/%s.mk\n' \
				"$(basename "$patchfile")" "$var" "$var" "$dep"
			dep_patch_fail=$((dep_patch_fail + 1))
			continue
		fi
		dep_src="$WORK/dep-$dep"
		if [ ! -d "$dep_src" ]; then
			dep_tgz="$CACHE_DIR/$dep-$sha.tar.gz"
			if [ ! -f "$dep_tgz" ]; then
				if ! curl -sS --fail --location --retry 3 -o "$dep_tgz.part" "${url//\$1/$sha}"; then
					rm -f "$dep_tgz.part"
					printf 'FAIL  %-40s could not fetch %s\n' "$(basename "$patchfile")" "${url//\$1/$sha}"
					dep_patch_fail=$((dep_patch_fail + 1))
					continue
				fi
				mv "$dep_tgz.part" "$dep_tgz"
			fi
			mkdir -p "$dep_src"
			tar -xzf "$dep_tgz" -C "$dep_src" --strip-components 1 || {
				printf 'FAIL  %-40s unextractable dep tarball\n' "$(basename "$patchfile")"
				dep_patch_fail=$((dep_patch_fail + 1))
				continue
			}
		fi
		if (cd "$dep_src" && patch -p1 -f --dry-run < "$patchfile" > "$WORK/dep-dry.txt" 2>&1); then
			printf 'APPLY %-40s against %s %s\n' "$(basename "$patchfile")" "$dep" "${sha:0:8}"
		else
			printf 'FAIL  %-40s does not apply to %s %s\n' \
				"$(basename "$patchfile")" "$dep" "${sha:0:8}"
			grep -E 'hunk|Reversed|does not apply|can.t find|No such file' "$WORK/dep-dry.txt" \
				| head -6 | sed 's/^/        /'
			dep_patch_fail=$((dep_patch_fail + 1))
		fi
	done
done

# ---- declared packages must exist in the Termux repository ----
echo
echo "===== declared packages ====="
repo_fail=0
for pkg in $(grep -h '^TERMUX_PKG_DEPENDS=\|^TERMUX_PKG_BUILD_DEPENDS=' "$RECIPE" \
	| sed 's/^[^=]*="//; s/"$//' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$'); do
	# version predicates and soname suffixes are not package names
	base="$(printf '%s' "$pkg" | sed -E 's/[<>(].*$//; s/\*.*$//')"
	[ -n "$base" ] || continue
	cand="$(apt-cache policy "$base" 2>/dev/null | awk '/Candidate:/{print $2}')"
	if [ -z "$cand" ] || [ "$cand" = "none" ]; then
		printf 'FAIL  %-24s not in the Termux apt repository\n' "$base"
		repo_fail=$((repo_fail + 1))
	else
		printf 'OK    %-24s %s\n' "$base" "$cand"
	fi
done

echo
echo "===== summary ====="
printf 'patches_applied=%s patch_failures=%s endian=%s pre_rc=%s conf_rc=%s make_user=%s make_inc_parse=%s dep_failures=%s deps_patch_misses=%s dep_patch_failures=%s repo_failures=%s\n' \
	"$applied_count" "$patch_fail" "$endian_fail" "$PRE_RC" "$CONF_RC" "$make_user_fail" "$inc_fail" "$dep_fail" "$ext_fail" "$dep_patch_fail" "$repo_fail"
if [ "$patch_fail" -gt 0 ] || [ "$endian_fail" -gt 0 ] || [ "$PRE_RC" != 0 ] || [ "$CONF_RC" != 0 ] \
	|| [ "$make_user_fail" -gt 0 ] || [ "$inc_fail" -gt 0 ] || [ "$dep_fail" -gt 0 ] \
	|| [ "$ext_fail" -gt 0 ] || [ "$dep_patch_fail" -gt 0 ] || [ "$repo_fail" -gt 0 ]; then
	echo "GATE: FAIL — fix the recipe before launching any build"
	exit 5
fi
echo "GATE: PASS (every patch applies, endianness settles little-endian, configure produces a Make.user Make.inc accepts, every system dep is real)"
exit 0
