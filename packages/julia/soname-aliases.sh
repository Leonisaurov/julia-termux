#!/data/data/com.termux/files/usr/bin/bash
# The versioned library names Julia's own code asks the loader for, and what the
# Termux prefix can answer with.
#
# Why this exists: `dlopen` on Android matches the *file name*, so a request for
# "libgmp.so.10" is not satisfied by $PREFIX/lib/libgmp.so however correct that
# library is.  base/gmp.jl and base/mpfr.jl hardcode glibc-style versioned names
# - upstream builds its own GMP, whose SONAME does carry the version - so the
# sysimage bootstrap died with
#	LoadError("gmp.jl", …, "could not load library \"libgmp.so.10\"")
# at sysimage.mk:129, 49 minutes into run 37851961397, once the triplet was
# fixed.  Which names are asked is a property of the source, so it is read from
# the source instead of from a list somebody keeps.
#
# Coverage boundary, stated rather than guessed: this reads *literals*.  A name
# built by interpolation ("libgfortran.so." * major, "libopenblas$(libsuffix).so")
# is not a literal and is not reported here; those sites belong to the stdlib
# patches that skip or resolve their own dlopen, and PROGRESS.md names them as the
# candidate blockers of the precompile stage.
#
# Usage: bash soname-aliases.sh <configured julia source tree> [<prefix>]
#   stdout  one verdict per demanded name, machine readable:
#             native <name>                    $PREFIX/lib answers it as spelled
#             alias <name> <unversioned-name>  point <name> at that file and the
#                                              loader answers it
#             built <name>                     this recipe compiles it, so the
#                                              versioned file exists in the tree
#             absent <name>                    nothing answers it on Android
#   stderr  the same table for a human reading the build log.
# Exits 2 if the tree or the library directory cannot be read, if the tree is not
# configured (the `built` verdict is asked of make), or if make refuses to answer;
# "no output" must never be read as "nothing was checked".
set -uo pipefail

TREE="${1:?usage: soname-aliases.sh <julia source tree> [<prefix>]}"
LIBDIR="${2:-${PREFIX:-/data/data/com.termux/files/usr}/lib}"
TREE="$(cd "$TREE" 2>/dev/null && pwd)" || { echo "FAIL  no such directory: $1" >&2; exit 2; }
[ -d "$TREE/base" ] || { echo "FAIL  $TREE/base missing: not a julia source tree" >&2; exit 2; }
[ -d "$LIBDIR" ] || { echo "FAIL  no library directory to check against: $LIBDIR" >&2; exit 2; }

# Only the linux branch of these constants can spell a name ".so": the Windows
# and macOS branches spell theirs ".dll" and ".dylib", which is why no parsing of
# the if/elseif structure is needed to read the demands of this platform.
demanded=$(
	grep -h -o -E '"lib[A-Za-z0-9_+.-]*\.so(\.[0-9]+)*"' \
		"$TREE"/base/*.jl "$TREE"/stdlib/*/src/*.jl 2>/dev/null |
		tr -d '"' | sort -u
)
[ -n "$demanded" ] || { echo "FAIL  no dlopen'able library name found in the source" >&2; exit 2; }

# Libraries this build produces itself, so no alias is created for them: `staged-install`
# and `install-<dep>` in deps/tools/common.mk untar each dependency into
# $(build_prefix), whose lib directory is $(build_shlibdir) - `usr/lib` during the
# build, `$PREFIX/lib/julia` after make install - which is the directory the loading
# object already searches.  Nothing here claims those names are reachable under a
# *different* directory: the Julia code that asks for them by literal has to be told
# both trees, which is what stdlib-libblastrampoline_jll.jl.patch does.
#
# The set is read from deps/*.mk rather than kept as a list, because the build's own
# text is what decides it.  Two spellings cover it:
#   1. a literal `libNAME.$(SHLIB_EXT)` (also `$$(`, as inside a define) in a rule -
#      covers what this recipe links or copies by hand: libblastrampoline, libdSFMT,
#      libgfortblas, libopenlibm, libz, libssl, ...
#   2. the source package of a dependency that builds from source, `$(SRCCACHE)/NAME-$(VER)` -
#      covers a dependency whose install is upstream's own `make install` and never
#      spells its soname here.
# Comparison is on the lowercased basename, so libLLVM matches a `libllvm` spelling.
# A name a dependency gets from a tarball with an unrelated package name falls through
# to `absent`; that is the boundary of this derivation, and the guard rule in
# scripts/unguarded-dlopen.sh is what decides whether falling through is fatal.
#
# Which .mk files may be read at all is make's decision, not this file's.  The
# conditionals at the top of deps/Makefile switch each dependency off with a
# USE_SYSTEM_* / DISABLE_LIBUNWIND / SANITIZE flag, and this recipe sets several, so
# asking for $(DEP_LIBS) is the only reading that cannot drift.  Measured on the
# configured tree of the rehearsal:
#   DEPLIBS=JuliaSyntax blastrampoline libuv dsfmt llvm utf8proc terminfo libwhich
# `csl` is absent (USE_SYSTEM_CSL := 1, build.sh:104) and `unwind` is absent
# (DISABLE_LIBUNWIND := 1, build.sh:126), so a name spelled only in csl.mk or
# unwind.mk is not produced by this build.  Reading the text without that answer
# credited `libunwind.so.8` as built and hid the wall behind it: LibUnwind_jll and
# LLVMLibUnwind_jll dlopen names nothing builds here.
#
# A file is dropped when its stem is a dependency (it appears in a DEP_LIBS
# assignment) and that dependency is not in the answer; a file no DEP_LIBS
# assignment mentions (BOLT.mk, llvm-options.mk) stays, because nothing here turns
# it off.  Failing to ask make is an error, not an empty answer: an unread tree must
# never be read as "this build produces nothing".
DEPS="$TREE/deps"
[ -f "$TREE/Make.user" ] || {
	echo "FAIL  $TREE/Make.user missing: termux_step_configure has to generate it" \
		"before make can be asked which dependencies this build installs" >&2
	exit 2
}
[ -f "$DEPS/Makefile" ] || { echo "FAIL  $DEPS/Makefile missing: not a julia source tree" >&2; exit 2; }
mkout=$(cd "$DEPS" && make --eval='print-deplibs: ; @echo "DEPLIBS=$(DEP_LIBS)"' print-deplibs 2>&1)
deplibs=$(printf '%s\n' "$mkout" | sed -n 's/^DEPLIBS=//p' | tail -1)
if [ -z "$deplibs" ]; then
	echo "FAIL  make refused to answer DEP_LIBS for $DEPS" >&2
	printf '%s\n' "$mkout" | tail -12 | sed 's/^/        /' >&2
	exit 2
fi
printf '  DEP_LIBS      %s\n' "$deplibs" >&2
wanted=$(printf '%s\n' "$deplibs" | tr ' \t' '\n\n' | grep -E '^[A-Za-z][A-Za-z0-9_]*$' | sort -u)
# Every dependency name the makefile knows, from the assignments that add to DEP_LIBS.
deps_known=$(grep -E '^[[:space:]]*DEP_LIBS[[:space:]]*[:+]?=' "$DEPS/Makefile" |
	tr ' \t' '\n\n' | grep -E '^[A-Za-z][A-Za-z0-9_]*$' | sort -u)
sources=()
for mk in "$DEPS"/*.mk; do
	stem=$(basename "$mk" .mk)
	printf '%s\n' "$deps_known" | grep -qxF -- "$stem" || { sources+=("$mk"); continue; }
	if printf '%s\n' "$wanted" | grep -qxF -- "$stem"; then
		sources+=("$mk")
	else
		printf '  dep off       %-20s %s names are not built here\n' "$stem" "$(basename "$mk")" >&2
	fi
done
[ "${#sources[@]}" -gt 0 ] || { echo "FAIL  every dependency in deps/ is switched off" >&2; exit 2; }

built_names=$(
	{
		grep -h -o -E 'lib[A-Za-z0-9_+.-]*\.\$+\(SHLIB_EXT\)' "${sources[@]}" 2>/dev/null |
			sed -E 's/\.\$+\(SHLIB_EXT\)$//'
		grep -h -o -E '\$\(SRCCACHE\)/[Ll][Ii][Bb][A-Za-z0-9_+.-]*-\$' "${sources[@]}" 2>/dev/null |
			sed -E 's|^\$\(SRCCACHE\)/||; s/-\$$//'
	} | tr 'A-Z' 'a-z' | sort -u
)
[ -n "$built_names" ] || { echo "FAIL  no dependency this build installs spells a library name" >&2; exit 2; }
printf '  built names   %s\n' "$(printf '%s\n' "$built_names" | tr '\n' ' ')" >&2

while read -r name; do
	[ -n "$name" ] || continue
	unversioned=${name%%.so*}.so
	base=$(printf '%s' "${name%%.so*}" | tr 'A-Z' 'a-z')
	if [ -e "$LIBDIR/$name" ]; then
		echo "native $name"
		printf '  native        %s\n' "$name" >&2
	elif [ -e "$LIBDIR/$unversioned" ]; then
		echo "alias $name $unversioned"
		printf '  aliased       %-22s -> %s\n' "$name" "$unversioned" >&2
	elif [ -n "$base" ] && printf '%s\n' "$built_names" | grep -qx -- "$base"; then
		echo "built $name"
		printf '  built here    %s\n' "$name" >&2
	else
		echo "absent $name"
		printf '  left absent   %s (no %s and no %s in %s)\n' \
			"$name" "$name" "$unversioned" "$LIBDIR" >&2
	fi
done <<< "$demanded"
exit 0
