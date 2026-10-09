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
# Usage: bash soname-aliases.sh <julia source tree> [<prefix>]
#   stdout  one verdict per demanded name, machine readable:
#             native <name>                    $PREFIX/lib answers it as spelled
#             alias <name> <unversioned-name>  point <name> at that file and the
#                                              loader answers it
#             built <name>                     this recipe compiles it, so the
#                                              versioned file exists in the tree
#             absent <name>                    nothing answers it on Android
#   stderr  the same table for a human reading the build log.
# Exits 2 if the tree or the library directory cannot be read; "no output" must
# never be read as "nothing was checked".
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

# Libraries this recipe compiles itself, so no alias is created for them: deps
# stages libblastrampoline and LLVM into $(build_shlibdir) - `usr/lib` during the
# build, `$PREFIX/lib/julia` after make install - under their own versioned file
# names, which is the directory the loading object already searches.  Nothing
# here claims those names are reachable under a *different* directory: the Julia
# code that asks for them by literal has to be told both trees, which is what
# stdlib-libblastrampoline_jll.jl.patch does.  libLLVM carries Julia's version
# (the readelf -V check in build.sh is what pins that).
built_by_us="libblastrampoline libLLVM"

while read -r name; do
	[ -n "$name" ] || continue
	unversioned=${name%%.so*}.so
	if [ -e "$LIBDIR/$name" ]; then
		echo "native $name"
		printf '  native        %s\n' "$name" >&2
	elif [ -e "$LIBDIR/$unversioned" ]; then
		echo "alias $name $unversioned"
		printf '  aliased       %-22s -> %s\n' "$name" "$unversioned" >&2
	elif printf '%s\n' $built_by_us | grep -qx -- "${name%%.so*}"; then
		echo "built $name"
		printf '  built here    %s\n' "$name" >&2
	else
		echo "absent $name"
		printf '  left absent   %s (no %s and no %s in %s)\n' \
			"$name" "$name" "$unversioned" "$LIBDIR" >&2
	fi
done <<< "$demanded"
exit 0
