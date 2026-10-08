#!/data/data/com.termux/files/usr/bin/bash
# Does this machine's dynamic loader resolve the libraries Julia looks up by
# soname, and does the lookup land on a file that exists?
#
# Why this exists: base/Makefile:166 runs `libwhich -p <soname> 2>/dev/null` for
# every USE_SYSTEM_* library and turns an empty answer into
#	"System library symlink failure: Unable to locate libpcre2-8.so on your
#	system!" + false (run 37811196090, 47 minutes into a build, with the
#	loader's own reason thrown away by that 2>/dev/null).  Nothing in the
#	message says whether dlopen failed, whether it answered with a name that is
#	not a path, or whether the file was unreadable.  A fresh process per
#	library, one small clang call and the loader's stderr visible answers it in
#	seconds.
#
# Every stage is reported before the next one runs, because the failure mode
# found in run 37811196090 killed the tool without printing anything: a stdout
# line is only trustworthy if the protocol guarantees it was flushed, and an
# empty stdout means the binary never reached main().
#
# The built-in probe is libwhich's patched `-p` algorithm (dlopen the soname,
# then walk dl_iterate_phdr and ask each recorded image about its handle with
# RTLD_NOLOAD), compiled by the clang this environment builds with, so it
# carries the same PT_INTERP, RUNPATH and DT_NEEDED as the binary
# deps/libwhich.mk produces.
#
# Usage: bash scripts/probe-library-resolution.sh [--src-dir DIR] [--patch FILE]
#	--src-dir DIR  DIR holds libwhich.c (the pinned upstream source); the real
#	               tool is built and run too, and its output goes through the
#	               shell chain base/Makefile applies to it.
#	--patch FILE   deps patch to apply to that source before building it.
#   PROBE_LIBS="..."  override the sonames to probe
#   PROBE_KEEP=1      leave the workdir in place for inspection
set -uo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
LW_SRC=""
LW_PATCH=""
while [ $# -gt 0 ]; do
	case "$1" in
		--src-dir) LW_SRC="${2:?--src-dir needs a directory}"; shift 2 ;;
		--patch) LW_PATCH="${2:?--patch needs a file}"; shift 2 ;;
		-h|--help) sed -n '2,36p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

WORK="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/libprobe.XXXXXX")"
cleanup() {
	if [ "${PROBE_KEEP:-0}" = 1 ]; then echo "# workdir kept at $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

# The libraries base/Makefile probes WITHOUT the ALLOW_FAILURE fourth argument,
# for the configuration packages/julia/build.sh generates.  LIBM and CSL are
# allowed to fail and are not listed; DSFMT, LIBWHICH and LIBBLASTRAMPOLINE are
# built from deps/, so their rules never run.
DEFAULT_LIBS="libpcre2-8.so libopenblas.so libgmp.so libmpfr.so libcrypto.so \
libssl.so libssh2.so libnghttp2.so libcurl.so libgit2.so libamd.so libcamd.so \
libccolamd.so libcholmod.so libcolamd.so libumfpack.so libspqr.so \
libsuitesparseconfig.so"
LIBS="${PROBE_LIBS:-$DEFAULT_LIBS}"

cat > "$WORK/probe.c" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static const char **names;
static size_t n_names;

static int collect(struct dl_phdr_info *info, size_t size, void *data)
{
	(void)size; (void)data;
	names = realloc(names, (n_names + 1) * sizeof(*names));
	names[n_names++] = info->dlpi_name;
	return 0;
}

int main(int argc, char **argv)
{
	if (argc != 2) { fprintf(stderr, "usage: probe <soname>\n"); return 2; }
	void *h = dlopen(argv[1], RTLD_LAZY);
	/* Reported before anything else can kill this process: "LOAD <name> ok"
	 * means the loader found the library, whatever the answer is after it
	 * means it did not, and no line at all means main() never ran. */
	printf("LOAD %s %s\n", argv[1], h ? "ok" : dlerror());
	fflush(stdout);
	if (!h) return 1;
	dl_iterate_phdr(collect, NULL);
	const char *found = NULL;
	for (size_t i = 0; i < n_names; i++) {
		/* The main executable and the [vdso] carry no path here. */
		if (names[i][0] != '/') continue;
		/* RTLD_NOLOAD because the first entry of this list is the Android
		 * linker, and dlopening it for real is fatal. */
		void *h2 = dlopen(names[i], RTLD_LAZY | RTLD_NOLOAD);
		if (h2) dlclose(h2);
		if (h2 == h) { found = names[i]; break; }
	}
	if (!found) { printf("NOMATCH %s loaded, but no mapped image carries that handle\n", argv[1]); return 1; }
	if (access(found, F_OK) != 0) { printf("NOTHERE %s loader answered \"%s\", which does not exist\n", argv[1], found); return 1; }
	printf("RESOLVED %s %s\n", argv[1], found);
	return 0;
}
EOF

if ! clang -std=gnu11 -Wall -O0 -o "$WORK/probe" "$WORK/probe.c" 2>"$WORK/build.txt"; then
	echo "FAIL  the probe itself does not compile in this environment"
	sed 's/^/        /' "$WORK/build.txt" | head -10
	exit 2
fi

# The real tool, if a source directory was handed over.
LW=""
if [ -n "$LW_SRC" ]; then
	cp -a "$LW_SRC" "$WORK/libwhich"
	if [ -n "$LW_PATCH" ]; then
		if ! (cd "$WORK/libwhich" && patch -p1 -f < "$LW_PATCH" > "$WORK/lw-patch.txt" 2>&1); then
			echo "FAIL  $(basename "$LW_PATCH") does not apply to the libwhich source"
			sed 's/^/        /' "$WORK/lw-patch.txt" | head -6
			exit 2
		fi
	fi
	if ! make -C "$WORK/libwhich" CC="${CC:-clang}" libwhich > "$WORK/lw-build.txt" 2>&1; then
		echo "FAIL  libwhich does not build in this environment"
		tail -12 "$WORK/lw-build.txt" | sed 's/^/        /'
		exit 2
	fi
	LW="$WORK/libwhich/libwhich"
fi

echo "===== loader resolution probe ====="
echo "env:  LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<unset>}  LD_PRELOAD=${LD_PRELOAD:-<unset>}"
echo "linker: $(ls -l /system/bin/linker64 2>/dev/null | sed 's/^.*linker64/linker64/' || echo 'no /system/bin/linker64')"
for cfg in /linkerconfig/ld.config.txt /system/etc/ld.config.txt; do
	if ls -d "$cfg" >/dev/null 2>&1; then echo "config: $cfg readable"
	elif [ -e "$(dirname "$cfg")" ]; then echo "config: $cfg not readable by this uid"
	else echo "config: $cfg absent"; fi
done
readelf -d "$WORK/probe" | grep -E 'RUNPATH|RPATH|NEEDED' | sed 's/^/self:   /'
readelf -lW "$WORK/probe" | sed -n 's@.*\[Requesting program interpreter: \(.*\)\]@self:   interp  \1@p'
[ -n "$LW" ] && readelf -d "$LW" | grep -E 'RUNPATH|RPATH|NEEDED' | sed 's/^/libwhich: /'

fail=0

# Before blaming dlopen: does a binary built here even reach main()?  A dead-on-
# arrival binary makes every library below look unresolvable.
ctrl=$("$WORK/probe" 2>"$WORK/ctrl.txt"); ctrl_rc=$?
if [ "$ctrl_rc" -eq 2 ]; then
	printf 'CTRL  %-28s a freshly built binary reaches main() here\n' "startup"
else
	printf 'FAIL  %-28s a freshly built binary exits %s without reaching main():\n' "startup" "$ctrl_rc"
	[ -n "$ctrl" ] && printf '%s\n' "$ctrl" | sed 's/^/         stdout: /' | head -4
	sed 's/^/         stderr: /' "$WORK/ctrl.txt" | head -8
	fail=$((fail + 1))
fi

for lib in $LIBS; do
	if [ ! -e "$PREFIX/lib/$lib" ] && [ ! -e "$PREFIX/lib/julia/$lib" ]; then
		printf 'MISS  %-28s absent from %s/lib (nothing to resolve)\n' "$lib" "$PREFIX"
		continue
	fi
	out=$("$WORK/probe" "$lib" 2>"$WORK/stderr.txt"); rc=$?
	first=$(printf '%s\n' "$out" | sed -n '1p')
	case "$first" in
	"LOAD $lib ok")
		path=$(printf '%s\n' "$out" | sed -n 's@^RESOLVED '"$lib"' @@p')
		if [ -n "$path" ]; then
			printf 'OK    %-28s loader bound %s\n' "$lib" "$path"
		else
			printf 'FAIL  %-28s loaded (rc=%s) but the handle matched no mapped image: %s\n' \
				"$lib" "$rc" "${out#*LOAD $lib ok}"
			fail=$((fail + 1))
		fi
		;;
	"LOAD $lib "*)
		printf 'FAIL  %-28s dlopen failed: %s\n' "$lib" "${first#LOAD $lib }"
		sed 's/^/         stderr: /' "$WORK/stderr.txt" | head -8
		ls -l "$PREFIX/lib/$lib" 2>/dev/null | sed 's/^/         file:  /'
		fail=$((fail + 1))
		;;
	*)
		printf 'FAIL  %-28s the probe printed nothing (rc=%s): it died before main()\n' "$lib" "$rc"
		sed 's/^/         stderr: /' "$WORK/stderr.txt" | head -8
		ls -l "$PREFIX/lib/$lib" 2>/dev/null | sed 's/^/         file:  /'
		fail=$((fail + 1))
		;;
	esac

	# The consumer's own shell statement: base/Makefile asks libwhich, sends its
	# stderr to /dev/null and only tests `[ -e "$REALPATH" ]`.  Reproduce that,
	# then the resolve_path chain it runs on the answer.
	if [ -n "$LW" ]; then
		REALPATH=$("$LW" -p "$lib" 2>"$WORK/lw-stderr.txt"); lw_rc=$?
		if [ ! -e "$REALPATH" ]; then
			printf 'FAIL  %-28s libwhich -p rc=%s answered "%s"\n' "$lib" "$lw_rc" "$REALPATH"
			sed 's/^/         stderr: /' "$WORK/lw-stderr.txt" | head -8
			fail=$((fail + 1))
			continue
		fi
		lw_wd="$(pwd)"
		lw_link="$(readlink -n "$REALPATH" || true)"
		[ -n "$lw_link" ] && { lw_wd="$(dirname "$REALPATH")"; REALPATH="$lw_link"; }
		printf '%s\n' "$REALPATH" | grep -q '^/' || REALPATH="$lw_wd/$REALPATH"
		lw_soname=$(objdump -p "$REALPATH" 2>/dev/null | awk '/SONAME/ {print $2}')
		if [ -n "$lw_soname" ] && [ -e "$(dirname "$REALPATH")/$lw_soname" ]; then
			REALPATH="$(dirname "$REALPATH")/$lw_soname"
		fi
		printf 'TOOL  %-28s symlink target %s\n' "$lib" "$REALPATH"
	fi
done

n_probed=$(printf '%s\n' $LIBS | wc -l)
echo "-- $n_probed soname(s) probed, $fail failure(s) --"
if [ "$fail" -gt 0 ]; then
	echo "PROBE: FAIL — base/Makefile would abort julia-base on these; see the loader messages above"
	exit 5
fi
echo "PROBE: PASS (every library Julia symlinks loads by soname and the loader names a file that exists)"
exit 0
