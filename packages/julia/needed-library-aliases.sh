#!/data/data/com.termux/files/usr/bin/bash
# The DT_NEEDED names the ELF files in <dir> carry but the directory cannot
# answer, as `alias <name> <target>` lines for the caller to symlink into <dir>.
# <target> is relative to <libdir>.
#
# Why this exists: libLLVM.so.18.1jl is linked with RUNPATH '$ORIGIN' only, so
# every DT_NEEDED name it carries has to exist in the same directory - the loader
# never falls back to $PREFIX/lib for it.  libz.so.1 is one of them and no Julia
# source spells it, so soname-aliases.sh (which reads source literals) does not
# demand it, even though $PREFIX/lib/libz.so.1 exists.  The installed julia died
# with
#	dlopen failed: library "libz.so.1" not found: needed by .../libLLVM.so.18.1jl
# and the same tree ran as soon as the link existed (device probe, 2026-10-09).
# The names come from the objects themselves: the package's own ELF files are
# the authority on what their loader will ask for.
#
# A name the platform's own directories already answer is left alone: the
# default namespace resolves it, and a $ORIGIN alias pointing at a $PREFIX
# symlink could shadow the real one (libm.so is the case: $PREFIX/lib/libm.so
# is a symlink to /system/lib64/libm.so).
#
# Usage: bash needed-library-aliases.sh <dir> [<libdir>]
#   stdout  one 'alias <name> <target>' per name
# Exits 2 if the directories cannot be read, if readelf is missing, or if <dir>
# holds no ELF file - "no output" must never be read as "nothing was needed".
set -uo pipefail

DIR="${1:?usage: needed-library-aliases.sh <dir> [<libdir>]}"
LIBDIR="${2:-${PREFIX:-/data/data/com.termux/files/usr}/lib}"
[ -d "$DIR" ] || { echo "FAIL  no such directory: $DIR" >&2; exit 2; }
[ -d "$LIBDIR" ] || { echo "FAIL  no library directory: $LIBDIR" >&2; exit 2; }

_readelf=$(command -v readelf || command -v llvm-readelf)
[ -n "$_readelf" ] || { echo "FAIL  no readelf in PATH" >&2; exit 2; }

_out=""
_elfs=0
for _f in "$DIR"/*; do
	[ -f "$_f" ] || continue
	[ -L "$_f" ] && continue
	case "$(od -An -N4 -tx1 "$_f" 2>/dev/null | tr -d ' \n')" in
	7f454c46) : ;;
	*) continue ;;
	esac
	_elfs=$((_elfs + 1))
	while IFS= read -r _name; do
		[ -n "$_name" ] || continue
		[ -e "$DIR/$_name" ] && continue
		[ -e "/system/lib64/$_name" ] && continue
		[ -e "/system/lib/$_name" ] && continue
		if [ -e "$LIBDIR/$_name" ]; then
			_out+="alias $_name $_name"$'\n'
		else
			_unversioned="${_name%%.so*}.so"
			[ -e "$LIBDIR/$_unversioned" ] && _out+="alias $_name $_unversioned"$'\n'
		fi
	done < <("$_readelf" -d "$_f" 2>/dev/null |
		sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p')
done
[ "$_elfs" -gt 0 ] || {
	echo "FAIL  no ELF file in $DIR: nothing was inspected" >&2
	exit 2
}
printf '%s' "$_out" | sort -u
unset _out _elfs _f _name _unversioned _readelf
exit 0
