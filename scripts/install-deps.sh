#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# install-deps.sh - Instala dependencias de Termux para build de Julia
# Ejecutable en Termux. En CI, termux-packages instala sus propias
# dependencias dentro del package-builder; no se deben descargar .deb con
# comodines HTTP (curl no expande esos patrones).

TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

echo "=== Installing Termux dependencies for Julia build ==="

DEPS=(
  llvm libllvm-static flang
  libopenblas blas-openblas
  suitesparse
  arpack-ng
  libgmp libmpfr
  zlib openssl
  libssh2 libgit2
  curl libnghttp2
  pcre2 utf8proc
  libuv p7zip
  patchelf lld which
  libandroid-support
)

command -v pkg >/dev/null 2>&1 || {
  echo "ERROR: pkg no está disponible; ejecute este script dentro de Termux." >&2
  exit 1
}
pkg update
pkg install -y "${DEPS[@]}"

echo "=== Dependencies installed ==="
echo "Termux prefix: $TERMUX_PREFIX"
ls -la "$TERMUX_PREFIX/lib/libLLVM"* 2>/dev/null || echo "No LLVM libs found"
