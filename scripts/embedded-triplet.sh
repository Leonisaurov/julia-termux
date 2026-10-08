#!/data/data/com.termux/files/usr/bin/bash
# The platform string the sysimage embeds, as make and Julia's own script compute it.
#
# Why this exists: base/Makefile:85 writes
#	const BUILD_TRIPLET = "$(BB_TRIPLET_LIBGFORTRAN_CXXABI)"
# into build_h.jl, and that variable is a `$(shell ...)` of
# contrib/normalize_triplet.py over `$(HOSTCC) -dumpmachine` (Make.inc:1380) whose
# exit status nothing ever checks.  When the script does not recognise the triple it
# prints "ERROR: Unmatchable platform string '<triple>'!" to *stdout*, so the error
# text becomes the constant; base/binaryplatforms.jl:958 then appends
# "-julia_version+<ver>", `parse(Platform, ...)` finds no match and throws at :769,
# and the bootstrap aborts in sysimage.mk - 47 minutes into run 37841320064, with
# Termux clang's triple `aarch64-unknown-linux-android24` mangled into
# `aarch64-unknown-linux-gnu24` by the patch that tried to fix this one layer too low.
#
# So the question is not "does this string look like a linux triplet" - a hand
# written expectation is what let the previous answer be wrong.  The question make
# can answer is: does the value it is about to embed survive a round trip through
# the same grammar (contrib/normalize_triplet.py) that
# base/binaryplatforms.jl's triplet_regex implements?
#
# Usage: bash scripts/embedded-triplet.sh <staged and configured julia tree>
#   stdout  the triplet on one line, when it is valid
#   stderr  the compiler triple, the embedded value and the round trip, always
# Exits 2 if the tree is not configured or make refuses to parse it, 1 if the value
# is empty or does not round trip, 0 otherwise.  A caller must never read "no
# output" as "nothing to check".
set -uo pipefail

TREE="${1:?usage: embedded-triplet.sh <julia source tree>}"
TREE="$(cd "$TREE" 2>/dev/null && pwd)" || { echo "FAIL  no such directory: $1" >&2; exit 2; }
for f in Make.inc Make.user contrib/normalize_triplet.py; do
	[ -f "$TREE/$f" ] || { echo "FAIL  $TREE/$f missing: the tree must be patched and configured" >&2; exit 2; }
done

MK="$TREE/rehearse-triplet.mk"
cleanup() { rm -f "$MK"; }
trap cleanup EXIT

{
	echo 'JULIAHOME := $(CURDIR)'
	echo 'include Make.inc'
	# Report the inputs and the output of the assignment Make.inc really makes.
	echo '$(info MACHINE $(BUILD_MACHINE))'
	echo '$(info TRIPLET $(BB_TRIPLET_LIBGFORTRAN_CXXABI))'
	# Re-feed the embedded value to Julia's own normaliser, with Julia's own
	# $(PYTHON) and $(invoke_python) wrapper: an accepted-and-unchanged answer is
	# what binaryplatforms.jl needs to parse.
	echo '$(info ROUNDTRIP $(shell $(call invoke_python,$(JULIAHOME)/contrib/normalize_triplet.py) $(BB_TRIPLET_LIBGFORTRAN_CXXABI)))'
	echo 'rehearse-triplet:'
	printf '\t@:\n'
} > "$MK"

out=$(cd "$TREE" && make -f "$(basename "$MK")" rehearse-triplet 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
	echo "FAIL  make refused to evaluate the triplet (rc=$rc):" >&2
	printf '%s\n' "$out" | tail -12 >&2
	exit 2
fi

field() { printf '%s\n' "$out" | sed -n "s/^$1 //p" | head -1; }
machine=$(field MACHINE)
triplet=$(field TRIPLET)
roundtrip=$(field ROUNDTRIP)

printf 'compiler triple  %s\n' "${machine:-<unknown>}" >&2
printf 'embedded value   %s\n' "${triplet:-<empty>}" >&2
printf 'round trip       %s\n' "${roundtrip:-<empty>}" >&2

if [ -z "$triplet" ]; then
	echo "FAIL  BB_TRIPLET_LIBGFORTRAN_CXXABI is empty: contrib/normalize_triplet.py" \
		"produced nothing for triple '$machine', so base/Makefile would embed an empty" \
		"BUILD_TRIPLET" >&2
	exit 1
fi
if printf '%s' "$triplet" | grep -q 'ERROR'; then
	echo "FAIL  the embedded BUILD_TRIPLET is a script error message, not a triplet." >&2
	exit 1
fi
if [ "$triplet" != "$roundtrip" ]; then
	echo "FAIL  the embedded triplet is not expressible in the grammar" \
		"base/binaryplatforms.jl parses: round trip gave '$roundtrip'" >&2
	exit 1
fi
printf '%s\n' "$triplet"
