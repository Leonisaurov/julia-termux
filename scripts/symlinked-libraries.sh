#!/data/data/com.termux/files/usr/bin/bash
# The sonames julia's base/Makefile will ask the loader to resolve, as decided
# by make itself.
#
# Why this exists: the macro at base/Makefile:162 runs `libwhich -p <name>` for
# every system library and turns an empty answer into
#	"System library symlink failure: Unable to locate <name> on your system!"
# + false, inside the julia-base target, once LLVM is already built.  Which
# names those are, and which may come back empty, is not a list a person keeps:
# it is the product of the $(eval $(call symlink_system_library,...)) calls under
# OS/ARCH conditionals, of Make.inc's LIBMNAME/LIBBLASNAME/LIBLAPACKNAME/SHLIB_EXT
# and of the recipe's USE_SYSTEM_* flags.  A hand-written checklist proved that:
# the gate watched libopenblas.so while the build died on libblas.so
# (run 37823556050, 44 minutes).
#
# Usage: bash scripts/symlinked-libraries.sh <staged and configured julia tree>
#   stdout  one soname per line: only the lookups whose empty answer aborts the
#           build (guard active, no ALLOW_FAILURE)
#   stderr  the whole decision table, so a reader sees what was skipped and why
# Exits non-zero if the tree is not configured, if base/Makefile changed shape or
# if make refuses to parse it - a caller must never read "no output" as
# "nothing to check".
set -uo pipefail

TREE="${1:?usage: symlinked-libraries.sh <julia source tree>}"
TREE="$(cd "$TREE" 2>/dev/null && pwd)" || { echo "FAIL  no such directory: $1" >&2; exit 2; }
for f in Make.inc Make.user base/Makefile; do
	[ -f "$TREE/$f" ] || { echo "FAIL  $TREE/$f missing: the tree must be patched and configured" >&2; exit 2; }
done

MK="$TREE/rehearse-symlinks.mk"
cleanup() { rm -f "$MK"; }
trap cleanup EXIT

# The symlink machinery of base/Makefile: from the conditional that opens it to
# the target that consumes the list, conditionals included, so make resolves the
# branches exactly as the build does.  Keyed on content, not line numbers,
# because the recipe patches this file.
begin=$(grep -n -m1 'WINNT emscripten' "$TREE/base/Makefile" | cut -d: -f1)
end=$(grep -n -m1 '^symlink_system_libraries:' "$TREE/base/Makefile" | cut -d: -f1)
if [ -z "$begin" ] || [ -z "$end" ] || [ "$begin" -ge "$end" ]; then
	echo "FAIL  base/Makefile no longer holds the symlink block between" \
		"'WINNT emscripten' and 'symlink_system_libraries:'" >&2
	exit 2
fi

{
	echo 'JULIAHOME := $(CURDIR)'
	echo 'include Make.inc'
	# Record the calls instead of generating their rules.  The name is expanded by
	# the same versioned_libname/SHLIB_EXT the real macro uses, and $5 reports the
	# guard the real macro tests with `ifneq ($(USE_SYSTEM_$1),0)`.
	echo 'define symlink_system_library'
	echo '$(info CALL $(1) $(notdir $(call versioned_libname,$(2),$(3))) $(if $(filter ALLOW_FAILURE,$(4)),allow-failure,fatal) $(USE_SYSTEM_$(1)))'
	echo 'endef'
	sed -n "${begin},${end}p" "$TREE/base/Makefile" | awk '
		/^define symlink_system_library$/ { skip = 1; next }
		skip { if ($0 == "endef") skip = 0; next }
		{ print }'
	# libLLVM is a rule of its own, under two guards, outside the macro.
	echo 'ifneq ($(USE_SYSTEM_LLVM),0)'
	echo 'ifneq ($(USE_LLVM_SHLIB),0)'
	echo 'rehearse-llvm := $(info CALL LLVM libLLVM.$(SHLIB_EXT) fatal 1)'
	echo 'endif'
	echo 'endif'
	echo 'rehearse-symlinks:'
	printf '\t@:\n'
} > "$MK"

out=$(cd "$TREE" && make -f "$(basename "$MK")" rehearse-symlinks 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
	echo "FAIL  make refused to parse Make.inc with the recipe's Make.user (rc=$rc)" >&2
	printf '%s\n' "$out" | tail -12 | sed 's/^/        /' >&2
	exit 2
fi

if ! printf '%s\n' "$out" | grep -q '^CALL '; then
	echo "FAIL  no symlink_system_library call survived the conditionals" >&2
	printf '%s\n' "$out" | tail -6 | sed 's/^/        /' >&2
	exit 2
fi

# The table on stderr: asked-or-not and fatal-or-not, for every call site.
printf '%s\n' "$out" | awk '$1 == "CALL" {
		status = ($5 == "0" ? "not asked" : ($4 == "fatal" ? "REQUIRED" : "allowed to fail"))
		printf "  %-14s %-28s USE_SYSTEM_%s=%s\n", status, $3, $2, ($5 == "" ? "unset" : $5)
	}' >&2

required=$(printf '%s\n' "$out" | awk '$1 == "CALL" && $4 == "fatal" && $5 != "0" { print $3 }' | sort -u)
if [ -z "$required" ]; then
	echo "FAIL  the build would ask for nothing, which is not a credible answer" >&2
	exit 2
fi
printf '%s\n' "$required"
exit 0
