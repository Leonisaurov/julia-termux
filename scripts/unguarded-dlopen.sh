#!/data/data/com.termux/files/usr/bin/bash
# Which of the given library names Julia's own code hands to dlopen() *without* a
# guard, and where.
#
# Why this exists: packages/julia/soname-aliases.sh classifies a demanded versioned
# name as `absent` when neither the prefix nor deps answers it, and the gate treated
# every such name as a note unless `julia-base` (make) required it.  Run 37876520515
# is the hole that left: stdlib/CompilerSupportLibraries_jll/src/…jll:57-64 calls
#	   global libgcc_s_handle = dlopen(libgcc_s)
# with no guard at all, so a name nothing answers raised inside `__init__` and killed
# `pkgimage.mk:28 stdlib/release.image` with "Failed to precompile
# CompilerSupportLibraries_jll" 59 minutes into the run - the same shape of death as
# the gmp name that run 37851961397 died on.  An unguarded demand is fatal whether
# make asked for it or not: what separates a note from a wall is the call site.
#
# What counts as tolerated, per base/libdl.jl:119-125: `dlopen(name; throw_error =
# false)` answers `nothing` (not `C_NULL` - that is `dlopen_e`, line 160) instead of
# raising, so the site survives a missing library.  Anything else raises.
#
# Two hops are read, because a patch is allowed to route the load through a helper in
# the same file: the first looks for dlopen(<identifier>) directly, the second for
# helper(<identifier>) where `helper` is a function defined in that file, and judges
# the helper's own dlopen calls.  A helper that never calls dlopen is not a loader.
#
# Coverage boundary, stated rather than guessed: this reads the literals of the
# source and the identifiers bound to them, so a name built by interpolation
# ("libgfortran.so." * major) has no site here and gets no verdict.  Only a linux
# spelling can be in the list at all (the Windows and macOS branches of the same
# `const` spell `.dll` and `.dylib`), so they need no special handling.  A `try` is
# credited only when it opens before the call inside the same top-level
# `function … end`, which is how these stubs are written; a guard in a block outside
# that region is not seen.
#
# Usage: bash unguarded-dlopen.sh <julia source tree> [<name>…]
#   names may also arrive on stdin, one per line (the gate pipes them)
#   stdout  one line per call site, machine readable:
#             guarded   <name> <file>:<line>
#             unguarded <name> <file>:<line>
#   stderr  the same sites for a human reading the build log, with the helper named
# Exits 2 if the tree cannot be read or no name was given.  "No site" is a normal
# answer (a literal can live in a docstring, as "libbar.so" does in
# base/binaryplatforms.jl:813) and exits 0; the caller reads it as
# "nothing here loads this name".
set -uo pipefail
shopt -s nullglob

TREE="${1:?usage: unguarded-dlopen.sh <julia source tree> [name…]}"
TREE="$(cd "$TREE" 2>/dev/null && pwd)" || { echo "FAIL  no such directory: $1" >&2; exit 2; }
[ -d "$TREE/base" ] || { echo "FAIL  $TREE/base missing: not a julia source tree" >&2; exit 2; }
[ -d "$TREE/stdlib" ] || { echo "FAIL  $TREE/stdlib missing: not a julia source tree" >&2; exit 2; }
shift

# Exactly the files packages/julia/soname-aliases.sh reads its demands from: a site
# outside them is not a demand the gate knows about.
sources=()
for f in "$TREE"/base/*.jl "$TREE"/stdlib/*/src/*.jl; do sources+=("$f"); done
[ "${#sources[@]}" -gt 0 ] || { echo "FAIL  no .jl sources to read the call sites from" >&2; exit 2; }

names=$(
	if [ "$#" -gt 0 ]; then printf '%s\n' "$@"
	elif [ ! -t 0 ]; then cat
	fi | tr -d ' \t\r' | grep -v '^$' | sort -u
)
[ -n "$names" ] || { echo "FAIL  no library name to look for" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/unguarded-XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

# A soname is data, not a pattern: "libstdc++.so.6" would otherwise read as `c++` -
# one or more `c`, one or more of that - and match nothing.
ere() { printf '%s' "$1" | sed -e 's/[][(){}.*+?|^$\/]/\\&/g'; }

# The top-level `function` line that opens the region containing line $2 of file $1.
enclosing_function() {
	awk -v n="$2" 'NR <= n && /^function[[:space:]]/ { ln = NR } END { print ln + 0 }' "$1"
}

# Does a `try` open before line $3 inside the region that starts at line $2?  The
# first `end` at column 0 closes the region, so a try after it does not count.
try_before() {
	[ "$2" -gt 0 ] || return 0
	awk -v from="$2" -v n="$3" '
		NR > from && /^end([^A-Za-z0-9_]|$)/ { exit }
		NR > from && NR < n && /^[[:space:]]*try([^A-Za-z0-9_]|$)/ { print NR; exit }' "$1"
}

# Report one site.  $1 name, $2 file (tree-relative), $3 line, $4 guarded|unguarded,
# $5 how the load happens ("" for a direct dlopen, "via helper()" for the second hop).
emit() {
	printf '%s %s %s:%s\n' "$4" "$1" "$2" "$3" | tee -a "$WORK/all"
	if [ -n "$5" ]; then
		printf '  %-9s %-18s %s:%s  (%s)\n' "$4" "$1" "$2" "$3" "$5" >&2
	else
		printf '  %-9s %-18s %s:%s\n' "$4" "$1" "$2" "$3" >&2
	fi
}

while read -r name; do
	[ -n "$name" ] || continue
	pattern=$(ere "$name")
	grep -l -F -- "\"$name\"" "${sources[@]}" 2>/dev/null > "$WORK/files" || true
	[ -s "$WORK/files" ] || continue
	files=()
	while read -r f; do files+=("$f"); done < "$WORK/files"

	# The stubs bind the literal to an identifier and pass the identifier:
	#   const libgcc_s = "libgcc_s.so.1"  …  dlopen(libgcc_s)
	grep -h -o -E 'const[[:space:]]+[A-Za-z_][A-Za-z0-9_!]*[[:space:]]*=[[:space:]]*"'"$pattern"'"' \
		"${files[@]}" 2>/dev/null | sed -E 's/^const[[:space:]]+//; s/[[:space:]]*=.*$//' |
		sort -u > "$WORK/idents"
	idents=$(cat "$WORK/idents")

	# ---- hop 1: the identifier is given straight to dlopen ----
	: > "$WORK/sites"
	for ident in $name $idents; do
		grep -n -H -E '\bdlopen(_e)?\([^)]*\<'"$(ere "$ident")"'\>' "${files[@]}" \
			>> "$WORK/sites" 2>/dev/null || true
	done
	if [ -s "$WORK/sites" ]; then
		sort -u -t: -k1,1 -k2,2n "$WORK/sites" | sed "s|^$TREE/||" > "$WORK/uniq"
		while read -r site; do
			[ -n "$site" ] || continue
			file=${site%%:*}
			rest=${site#*:}
			line=${rest%%:*}
			case "$site" in
				*throw_error*|*dlopen_e*) verdict=guarded ;;
				*)
					if [ -n "$(try_before "$TREE/$file" "$(enclosing_function "$TREE/$file" "$line")" "$line")" ]; then
						verdict=guarded
					else
						verdict=unguarded
					fi
					;;
			esac
			emit "$name" "$file" "$line" "$verdict" ""
		done < "$WORK/uniq"
		continue
	fi

	# ---- hop 2: the identifier goes to a helper defined in the same file ----
	# Skipping this would make a guarded patch look like "nothing loads this name",
	# which is exactly the reading a gate must not trust.
	for ident in $idents; do
		grep -n -H -E '[A-Za-z_][A-Za-z0-9_!]*\('"$ident"'\)' "${files[@]}" 2>/dev/null \
			>> "$WORK/calls" || true
	done
	[ -s "$WORK/calls" ] || continue
	sort -u -t: -k1,1 -k2,2n "$WORK/calls" | sed "s|^$TREE/||" > "$WORK/uniq"
	while read -r call; do
		[ -n "$call" ] || continue
		file=${call%%:*}
		rest=${call#*:}
		line=${rest%%:*}
		body=${rest#*:}
		callee=$(printf '%s\n' "$body" |
			grep -o -E '[A-Za-z_][A-Za-z0-9_!]*\('"$ident"'\)' | head -1 | sed -E 's/\(.*$//')
		[ -n "$callee" ] || continue
		case "$callee" in dlopen|dlopen_e) continue ;; esac
		def=$(grep -n -E '^(function[[:space:]]+'"$(ere "$callee")"'([^A-Za-z0-9_]|$)|'"$(ere "$callee")"'\()' "$TREE/$file" |
			head -1 | cut -d: -f1)
		[ -n "$def" ] || continue
		hbody=$(awk -v from="$def" 'NR >= from { print } NR > from && /^end([^A-Za-z0-9_]|$)/ { exit }' "$TREE/$file")
		loads=$(printf '%s\n' "$hbody" | grep -n -E '\bdlopen(_e)?\(' || true)
		[ -n "$loads" ] || continue
		if printf '%s\n' "$loads" | grep -qvE 'throw_error[[:space:]]*=[[:space:]]*false|dlopen_e'; then
			verdict=unguarded
		else
			verdict=guarded
		fi
		emit "$name" "$file" "$line" "$verdict" "via $callee()"
	done < "$WORK/uniq"
done <<< "$names"

# An empty stdout must never be readable as "everything is guarded": say so out loud.
if [ ! -s "$WORK/all" ]; then
	printf 'no dlopen site for any of the %s name(s): nothing in these files loads them\n' \
		"$(printf '%s\n' "$names" | grep -c .)" >&2
fi
exit 0
