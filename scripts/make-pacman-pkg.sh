#!/data/data/com.termux/files/usr/bin/bash
# Convert a Termux .deb into a pacman .pkg.tar.xz.
#
# Why starting from the .deb and not from a build tree: the .deb is the artifact CI
# inspects and publishes, so deriving the pacman payload from it guarantees the two
# formats contain the same bytes.  Reading the metadata out of the deb's control
# member keeps the dependency list in one place (the recipe) instead of a copy that
# rots the moment the recipe changes.
#
# The .PKGINFO/.BUILDINFO/.MTREE layout mirrors
# termux-packages/scripts/build/termux_step_create_pacman_package.sh.
#
# Usage: bash scripts/make-pacman-pkg.sh PATH/TO/package.deb [OUTPUT_DIR]
set -euo pipefail
shopt -s dotglob globstar

DEB="${1:-}"
OUTPUT_DIR="${2:-$PWD/output}"
[ -n "$DEB" ] || { echo "usage: $0 PATH/TO/package.deb [OUTPUT_DIR]" >&2; exit 2; }
[ -f "$DEB" ] || { echo "no such package: $DEB" >&2; exit 2; }
for tool in bsdtar dpkg-deb xz; do
	command -v "$tool" > /dev/null || { echo "$tool is required" >&2; exit 3; }
done

# This script runs both on a device (where /tmp does not exist) and in CI (where
# $TMPDIR does).
TMPBASE="${TMPDIR:-}"
[ -n "$TMPBASE" ] && [ -d "$TMPBASE" ] || TMPBASE=/tmp
[ -w "$TMPBASE" ] || TMPBASE=/data/data/com.termux/files/usr/tmp
WORK="$(mktemp -d "$TMPBASE/make-pacman.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PAYLOAD="$WORK/pkg"
CTRL="$WORK/ctrl"
mkdir -p "$PAYLOAD" "$CTRL"
dpkg-deb -x "$DEB" "$PAYLOAD"
dpkg-deb -e "$DEB" "$CTRL"

# Optional fields: a missing one is empty, not a build failure.
control_field() { { grep -m1 "^$1:" "$CTRL/control" || true; } | cut -d: -f2- | sed 's/^ *//'; }

NAME="$(control_field Package)"
VERSION="$(control_field Version)"
ARCH="$(control_field Architecture)"
DESC="$(control_field Description)"
HOMEPAGE="$(control_field Homepage)"
MAINTAINER="$(control_field Maintainer)"
[ -n "$NAME" ] && [ -n "$VERSION" ] && [ -n "$ARCH" ] || {
	echo "could not read Package/Version/Architecture from $DEB" >&2; exit 3; }

# A deb Version carries no revision suffix when the recipe set none; pacman wants
# pkgver = VERSION-REL, which is what termux_step_create_pacman_package.sh emits.
case "$VERSION" in
	*-*) PKGVER="$VERSION" ;;
	*)   PKGVER="$VERSION-0" ;;
esac

# Maintainer scripts have no equivalent in this conversion: pacman runs INSTALL hooks
# with different arguments and a different lifecycle than dpkg.  Silently dropping
# them would ship a package that installs differently from the .deb.
for s in preinst postinst prerm postrm config; do
	if [ -e "$CTRL/$s" ]; then
		echo "$DEB carries a $s script; this script only converts payload and metadata" >&2
		exit 4
	fi
done

INSTALLSIZE="$(du -bs "$PAYLOAD" | cut -f1)"
EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}"
PKGFILE="$OUTPUT_DIR/$NAME-$PKGVER-$ARCH.pkg.tar.xz"

# deb dependency predicates are not pacman syntax: strip the version, and pad a
# comparison-only relation the way termux-packages does.
dep_lines() {
	control_field "$1" | tr ',' '\n' | sed 's/ *([^)]*)//g; s/^ *//; s/ *$//' |
		awk '{ if ($0 != "") printf "%s = %s\n", "'"$2"'", $1 }'
}

cd "$PAYLOAD"
{
	echo "pkgname = $NAME"
	echo "pkgbase = $NAME"
	echo "pkgver = $PKGVER"
	echo "pkgdesc = $DESC"
	echo "url = $HOMEPAGE"
	echo "builddate = $EPOCH"
	echo "packager = $MAINTAINER"
	echo "size = $INSTALLSIZE"
	echo "arch = $ARCH"
	# No license field: a .deb control member does not carry one, and inventing a
	# value here would be exactly the kind of metadata that silently goes stale.
	dep_lines Pre-Depends depend
	dep_lines Depends depend
	dep_lines Provides provides
	dep_lines Conflicts conflict
	dep_lines Replaces replaces
} > .PKGINFO

{
	echo "format = 2"
	echo "pkgname = $NAME"
	echo "pkgbase = $NAME"
	echo "pkgver = $PKGVER"
	echo "pkgarch = $ARCH"
	echo "packager = $MAINTAINER"
	echo "builddate = $EPOCH"
} > .BUILDINFO

# Every entry must share one mtime, otherwise .MTREE records a different time for the
# metadata files than the package claims.
find . -exec touch -h -d "@$EPOCH" {} +

printf '%s\0' **/* | bsdtar -cnf - --format=mtree \
	--options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
	--null --files-from - --exclude .MTREE | gzip -c -f -n > .MTREE
touch -d "@$EPOCH" .MTREE

mkdir -p "$OUTPUT_DIR"
printf '%s\0' **/* | bsdtar --no-fflags -cnf - --null --files-from - | xz -c -z - > "$PKGFILE"
touch -d "@$EPOCH" "$PKGFILE"

echo "[make-pacman-pkg] $DEB -> $PKGFILE"
ls -lh "$PKGFILE"
