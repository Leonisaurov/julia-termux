#!/data/data/com.termux/files/usr/bin/bash
# The directory the bionic loader searches for a dlopen issued by Julia's own
# runtime library - which is the directory that library is linked into, because
# that is all its DT_RUNPATH says.
#
# Why this exists: base/gmp.jl asks for "libgmp.so.10" and src/dlload.c:376 hands
# that bare name to dlopen from libjulia-internal.so.  src/Makefile:417 links
# libjulia-internal into $(build_shlibdir) with $(RPATH_LIB), and Make.inc:1475
# makes RPATH_LIB exactly -Wl,-rpath,'$$ORIGIN', so the search set is the
# library's own directory.  Run 37862103015 created every alias the source
# demands and still died at sysimage.mk:129 with
#	LoadError("gmp.jl", …, "could not load library \"libgmp.so.10\"\n
#	dlopen failed: library \"libgmp.so.10\" not found")
# because the aliases sat in usr/lib/julia, which nothing with that RUNPATH reads.
# Reproduced on the phone with the same layout: alias in usr/lib/julia -> not
# found, same alias in usr/lib -> resolved.
#
# make install moves the same object to $(private_libdir) and rewrites its rpath
# to '$$ORIGIN:$$ORIGIN/$(reverse_private_libdir_rel)' (Makefile:468-481), so the
# installed tree has its own answer.  Both are asked of make here rather than
# asserted, because a recipe that hardcodes where the runtime library lives is
# how the 50-minute run above was spent on a directory name.
#
# Usage: runtime-library-dir.sh <julia source tree> [<prefix>]
#   stdout  one line per tree, machine readable:
#             build <dir relative to the source tree>
#             install <dir relative to the prefix>
#   stderr  the same, for a human reading the gate log, plus the rpath the
#           loader was actually told to use.
# Exits 2 if make refuses to answer or the answer does not carry $ORIGIN; "no
# output" must never be read as "nothing to alias".
set -uo pipefail

TREE="${1:?usage: runtime-library-dir.sh <julia source tree> [<prefix>]}"
PREFIX="${2:-${PREFIX:-/data/data/com.termux/files/usr}}"
TREE="$(cd "$TREE" 2>/dev/null && pwd)" || { echo "FAIL  no such directory: $1" >&2; exit 2; }
[ -f "$TREE/Make.inc" ] || { echo "FAIL  $TREE/Make.inc missing: not a julia source tree" >&2; exit 2; }

MK="$TREE/rehearse-runtimedirs.mk"
cleanup() { rm -f "$MK"; }
trap cleanup EXIT

# The same prefix= override termux_step_make_install passes to make, so the
# installed paths mean the same thing here as they will in the recipe.
{
	echo 'JULIAHOME := $(CURDIR)'
	echo 'include Make.inc'
	# $(info) prints while the assignment is expanded, so each answer arrives as
	# one labelled line of make's stderr.
	echo 'rehearse-build := $(info BUILD $(build_shlibdir))'
	echo 'rehearse-install := $(info INSTALL $(private_libdir))'
	echo 'rehearse-rpath := $(info RPATH $(RPATH_LIB))'
	echo 'rehearse-irel := $(info INSTALL-RPATH $(reverse_private_libdir_rel))'
	echo 'rehearse-dirs:'
	printf '\t@:\n'
} > "$MK"

out=$(cd "$TREE" && make -f "$(basename "$MK")" rehearse-dirs "prefix=$PREFIX" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
	echo "FAIL  make refused to evaluate Make.inc with the recipe's Make.user (rc=$rc)" >&2
	printf '%s\n' "$out" | tail -12 | sed 's/^/        /' >&2
	exit 2
fi

build=$(printf '%s\n' "$out" | awk '$1 == "BUILD" { sub(/^BUILD /, ""); print; exit }')
install=$(printf '%s\n' "$out" | awk '$1 == "INSTALL" { sub(/^INSTALL /, ""); print; exit }')
rpath=$(printf '%s\n' "$out" | awk '$1 == "RPATH" { sub(/^RPATH /, ""); print; exit }')
irel=$(printf '%s\n' "$out" | awk '$1 == "INSTALL-RPATH" { sub(/^INSTALL-RPATH /, ""); print; exit }')
[ -n "$build" ] && [ -n "$install" ] && [ -n "$rpath" ] && [ -n "$irel" ] || {
	echo "FAIL  make did not answer BUILD, INSTALL, RPATH and INSTALL-RPATH" >&2
	printf '%s\n' "$out" | tail -12 | sed 's/^/        /' >&2
	exit 2
}

# Everything below is only true while the loader is told to look at the object's
# own directory; if upstream ever puts an absolute path there this script says so
# instead of reporting a directory the recipe could not use.
case "$rpath" in
	*ORIGIN*) ;;
	*) echo "FAIL  RPATH_LIB no longer mentions \$ORIGIN: $rpath" >&2; exit 2 ;;
esac

case "$build" in
	"$TREE"/*) build_rel=${build#"$TREE"/} ;;
	*) echo "FAIL  $(build_shlibdir) is not inside the source tree: $build" >&2; exit 2 ;;
esac
case "$install" in
	"$PREFIX"/*) install_rel=${install#"$PREFIX"/} ;;
	*) echo "FAIL  $(private_libdir) is not inside the prefix: $install" >&2; exit 2 ;;
esac

printf 'build %s\n' "$build_rel"
printf 'install %s\n' "$install_rel"
printf '  searched at build time   %s  (RUNPATH %s)\n' "$build" "$rpath" >&2
printf '  searched after install   %s and %s/%s\n' "$install" "$install" "$irel" >&2
exit 0
