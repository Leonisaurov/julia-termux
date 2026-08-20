#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
shopt -s globstar dotglob

# Genera un paquete pacman (.pkg.tar.xz) desde el directorio usr-staging
# de un build anterior de termux-packages.

STAGING="${1:-$HOME/.termux-build/julia/src/usr-staging}"
OUTPUT_DIR="${2:-$PWD/output}"
PKG_NAME="julia"
PKG_VERSION="1.12.6-1"
PKG_ARCH="aarch64"
PREFIX="/data/data/com.termux/files/usr"

PKGVER="${PKG_VERSION}"
PKGFILE="${OUTPUT_DIR}/${PKG_NAME}-${PKGVER}-${PKG_ARCH}.pkg.tar.xz"

echo "[make-pacman-pkg] staging: $STAGING"
echo "[make-pacman-pkg] output:  $PKGFILE"

[ -d "$STAGING/data/data/com.termux/files/usr" ] || {
    echo "Error: no se encontro $STAGING/data/data/com.termux/files/usr" >&2
    exit 1
}

# Calcular tamaño instalado
INSTALLSIZE=$(du -bs "$STAGING" | cut -f1)
EPOCH=$(date +%s)

# Crear directorio temporal de trabajo
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

cd "$WORKDIR"

# Copiar el contenido del staging al working directory
cp -a "$STAGING"/* .

# --- .PKGINFO ---
cat > .PKGINFO <<EOF
pkgname = $PKG_NAME
pkgbase = $PKG_NAME
pkgver = $PKGVER
pkgdesc = Julia programming language - Termux/Android build
url = https://julialang.org
builddate = $EPOCH
packager = @termux
size = $INSTALLSIZE
arch = $PKG_ARCH
license = MIT
depend = llvm
depend = libopenblas
depend = blas-openblas
depend = libgmp
depend = libmpfr
depend = suitesparse
depend = arpack-ng
depend = libssh2
depend = curl
depend = libgit2
depend = patchelf
depend = zlib
depend = openssl
depend = libnghttp2
depend = pcre2
depend = 7zip
depend = lld
depend = libandroid-support
depend = libuv
EOF

# --- .BUILDINFO ---
cat > .BUILDINFO <<EOF
format = 2
pkgname = $PKG_NAME
pkgbase = $PKG_NAME
pkgver = $PKGVER
pkgarch = $PKG_ARCH
packager = @termux
builddate = $EPOCH
EOF

# Touch all files to have the same mtime
find . -exec touch -h -d "@$EPOCH" {} +

# Crear .MTREE
printf '%s\0' **/* | bsdtar -cnf - --format=mtree \
    --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
    --null --files-from - --exclude .MTREE | \
    gzip -c -f -n > .MTREE
touch -d "@$EPOCH" .MTREE

# Crear el paquete final
mkdir -p "$OUTPUT_DIR"
printf '%s\0' **/* | bsdtar --no-fflags -cnf - --null --files-from - | \
    xz -c -z - > "$PKGFILE"
touch -d "@$EPOCH" "$PKGFILE"

echo "[make-pacman-pkg] paquete creado: $PKGFILE"
ls -lh "$PKGFILE"
