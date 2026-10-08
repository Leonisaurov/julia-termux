#!/data/data/com.termux/files/usr/bin/bash
# Static gate for packages/<pkg>/build.sh: rehearses the patch stage against the
# real upstream source tree WITHOUT compiling anything.
#
# Why this exists: `sed -i` exits 0 even when its pattern matches nothing, so a
# recipe can silently skip patches and only fail ~70 minutes into a CI build.
# This script answers, per file the recipe tries to patch: does it exist in the
# upstream tarball, and did the patch stage actually modify it?
#
# Usage: bash scripts/rehearse-recipe.sh [package]      (default: julia)
#   REHEARSAL_KEEP=1  leave the workdir in place for inspection
#   REHEARSAL_CACHE=...  where the source tarball is cached (default $PREFIX/tmp/julia-rehearse-cache)
set -uo pipefail

PKG="${1:-julia}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECIPE="$REPO_ROOT/packages/$PKG/build.sh"
[ -f "$RECIPE" ] || { echo "no recipe at $RECIPE" >&2; exit 2; }

CACHE_DIR="${REHEARSAL_CACHE:-$PREFIX/tmp/julia-rehearse-cache}"
KEEP="${REHEARSAL_KEEP:-0}"
WORK="$(mktemp -d "$PREFIX/tmp/julia-rehearse.XXXXXX")"
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

if [ ! -f "$TARBALL" ] || { [ -n "$SHA256" ] && ! sha256sum "$TARBALL" | grep -q "^$SHA256 "; }; then
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

# ---- files the recipe tries to patch ----
# The operand of each sed call, not every token that looks like a path: the
# sed *scripts* are patterns, and harvesting them produced ~10 phantom MISS
# lines per genuine finding.  scripts/extract-sed-targets.py blanks quoted
# regions first, so only real file arguments survive.
python3 "$REPO_ROOT/scripts/extract-sed-targets.py" "$RECIPE" \
	| grep -v '^deps/scratch/' > "$WORK/targets.txt" 2> "$WORK/targets.stats"
cat "$WORK/targets.stats"
# paths built with $src/$_var loop variables are not statically resolvable
grep -v '\$' "$WORK/targets.txt" > "$WORK/targets.static.txt" || true
echo "== patch targets named by the recipe: $(wc -l < "$WORK/targets.static.txt") (plus $(grep -c '\$' "$WORK/targets.txt" || true) dynamic)"

# ---- snapshot everything, run the patch stage, snapshot again ----
snap() { (cd "$SRCDIR" && find . -type f -print0 | xargs -0 sha256sum) > "$1"; }
snap "$WORK/hash-before.txt"

FAKEPREFIX="$WORK/prefix"
mkdir -p "$FAKEPREFIX/lib" "$FAKEPREFIX/bin" "$FAKEPREFIX/include" "$WORK/massage"

TERMUX_PKG_BUILDDIR="$SRCDIR" \
TERMUX_PKG_SRCDIR="$SRCDIR" \
TERMUX_PKG_MASSAGEDIR="$WORK/massage" \
TERMUX_PREFIX="$FAKEPREFIX" \
TERMUX_HOST_PLATFORM="aarch64-linux-android" \
TERMUX_ARCH=aarch64 \
TERMUX_API_LEVEL=35 \
TERMUX_PKG_VERSION="$VERSION" \
TERMUX_ABI="35,aarch64" \
TERMUX_PKG_MAKE_PROCESSES=1 \
TERMUX_TOPDIR="$WORK/topdir" \
	bash -c '
		set +e -o pipefail
		cd "'"$SRCDIR"'" || exit 9
		source "'"$RECIPE"'"
		# the recipe locates our external patches/ via a docker mount or a
		# device-relative path; point it at this checkout instead
		_JULIA_TERMUX_ROOT="'"$REPO_ROOT"'"
		termux_step_pre_configure > '"$WORK/hook-stdout.txt"' 2> '"$WORK/hook-stderr.txt"'
		echo $? > '"$WORK/hook-rc.txt"'
	'
HOOK_RC=$(cat "$WORK/hook-rc.txt" 2>/dev/null || echo "n/a")
snap "$WORK/hash-after.txt"

echo
echo "===== patch stage report ====="
echo "-- hook exit code: $HOOK_RC --"
if [ -s "$WORK/hook-stderr.txt" ]; then
	echo "-- stderr (grouped) --"
	grep -E 'Warning|error|No such file|not found|Permission denied' "$WORK/hook-stderr.txt" \
		| sed 's/[0-9]\+/N/g' | sort | uniq -c | sort -rn | head -40 | sed 's/^/   /'
fi

echo
echo "-- per declared patch target --"
missing=0
guarded=0
same=0
ok=0
while read -r rel; do
	[ -n "$rel" ] || continue
	hb=$(awk -v f="./$rel" '$2==f {print $1; exit}' "$WORK/hash-before.txt")
	ha=$(awk -v f="./$rel" '$2==f {print $1; exit}' "$WORK/hash-after.txt")
	if [ -z "$hb" ]; then
		# `if [ -f X ]` guards are legitimate for files that upstream deleted or
		# that the build generates (src/flisp/host/Makefile); they are not misses.
		if grep -qE "\[ (-f|-e) .?$rel\\b" "$RECIPE"; then
			printf 'GUARD %-48s absent here, but the recipe tests for it first\n' "$rel"
			guarded=$((guarded + 1))
		else
			printf 'MISS  %-48s absent in upstream tarball\n' "$rel"
			missing=$((missing + 1))
		fi
	elif [ "$hb" = "$ha" ]; then
		printf 'SAME  %-48s exists but the patch stage did not modify it\n' "$rel"
		same=$((same + 1))
	else
		printf 'OK    %-48s\n' "$rel"
		ok=$((ok + 1))
	fi
done < "$WORK/targets.static.txt"

echo
echo "-- files the patch stage modified --"
awk 'NR==FNR{h[$2]=$1;next} ($2 in h) && h[$2]!=$1 {print $2}' \
	"$WORK/hash-before.txt" "$WORK/hash-after.txt" | sort > "$WORK/changed.txt"
awk 'NR==FNR{h[$2]=1;next} !($2 in h) {print "NEW  " $2}' \
	"$WORK/hash-before.txt" "$WORK/hash-after.txt" | sort | head -20 | sed 's/^/   /'
sed 's|^|MOD  |' "$WORK/changed.txt" | head -25 | sed 's/^/   /'
wc -l < "$WORK/changed.txt" | tr -d ' ' | sed 's/^/   modified files: /'
notnamed=$(comm -23 "$WORK/changed.txt" <(sed 's|^|./|' "$WORK/targets.static.txt" | sort) | head -20)
[ -n "$notnamed" ] && { echo "   -- modified but not declared as a sed target --"; echo "$notnamed" | sed 's/^/      /'; }

echo
echo "-- external patch files referenced by the recipe --"
ext_missing=0
grep -o 'patches/[A-Za-z0-9_./-]*' "$RECIPE" | sort -u > "$WORK/ext_refs.txt"
while read -r ref; do
	[ -n "$ref" ] || continue
	path="$REPO_ROOT/packages/$PKG/${ref#packages/$PKG/}"
	if [ -e "$path" ]; then
		printf 'OK    %s\n' "$ref"
	else
		printf 'MISS  %s\n' "$ref"
		ext_missing=$((ext_missing + 1))
	fi
done < "$WORK/ext_refs.txt"

echo
echo "===== summary ====="
printf 'ok=%s same=%s missing=%s guarded=%s external_missing=%s hook_rc=%s\n' "$ok" "$same" "$missing" "$guarded" "$ext_missing" "$HOOK_RC"
if [ "$missing" -gt 0 ] || [ "$ext_missing" -gt 0 ] || [ "$same" -gt 0 ]; then
	echo "GATE: FAIL — fix the recipe before launching any build"
	exit 5
fi
echo "GATE: PASS (patch targets present and modified; run the bash -n / shellcheck gate too)"
exit 0
