#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Build local de Julia usando el build system oficial de Termux y tcr.
# No requiere Docker: el host Termux ya aporta clang/LLVM y el NDK toolchain.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
TCR=${TCR:-"$HOME/.local/bin/tcr"}
TP_DIR=${TERMUX_PACKAGES_DIR:-"$HOME/.cache/julia-termux/termux-packages"}
TP_URL=${TERMUX_PACKAGES_URL:-https://github.com/termux/termux-packages.git}
JOBS=${TERMUX_PKG_MAKE_PROCESSES:-1}
FORMAT=debian
ACTION=build
CONTINUE=1
FORCE=0

usage() {
    cat <<EOF
Uso: $0 [opciones]

  -j, --jobs N       jobs de termux-packages (default: $JOBS)
  --format FORMATO   debian o pacman (default: $FORMAT)
  --packages DIR     checkout de termux-packages
  --dry-run          valida el entorno y muestra el comando
  --update           actualiza el checkout de termux-packages
  --continue         reanuda el build cacheado después de un fallo
  --force            reaplica configuración/parches y fuerza el paquete
  -h, --help         muestra esta ayuda

Variables: TCR, TERMUX_PACKAGES_DIR, TERMUX_PACKAGES_URL,
           TERMUX_PKG_MAKE_PROCESSES.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -j[0-9]*) JOBS=${1#-j}; shift;;
        -j|--jobs) [ "$#" -ge 2 ] || { echo "--jobs requiere N" >&2; exit 2; }; JOBS=$2; shift 2;;
        --format) [ "$#" -ge 2 ] || { echo "--format requiere un valor" >&2; exit 2; }; FORMAT=$2; shift 2;;
        --packages) [ "$#" -ge 2 ] || { echo "--packages requiere DIR" >&2; exit 2; }; TP_DIR=$2; shift 2;;
        --dry-run) ACTION=dry-run; shift;;
        --update) ACTION=update; shift;;
        --continue) CONTINUE=1; shift;;
        --force) FORCE=1; shift;;
        -h|--help) usage; exit 0;;
        *) echo "opción desconocida: $1" >&2; usage >&2; exit 2;;
    esac
done

case "$JOBS" in ''|*[!0-9]*|0) echo "jobs debe ser un entero positivo" >&2; exit 2;; esac
case "$FORMAT" in debian|pacman) ;; *) echo "formato debe ser debian o pacman" >&2; exit 2;; esac

die() { echo "[build-local] error: $*" >&2; exit 1; }

# Termux uses the temporary directory under PREFIX as its canonical location. Keep this
# explicit so neither the wrapper nor termux-packages chooses another temp path.
: "${TMPDIR:=/data/data/com.termux/files/usr/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"
test -d "$TMPDIR" && test -w "$TMPDIR" || die "TMPDIR no es escribible: $TMPDIR"
command -v git >/dev/null 2>&1 || die "git no está instalado"
[ -x "$TCR" ] || die "no se encontró el wrapper ejecutable: $TCR"
command -v clang >/dev/null 2>&1 || die "clang no está instalado"
command -v make >/dev/null 2>&1 || die "make no está instalado"
[ "$(uname -m)" = aarch64 ] || die "este builder local requiere aarch64; use CI para otra arquitectura"

if [ ! -d "$TP_DIR/.git" ]; then
    mkdir -p "$(dirname -- "$TP_DIR")"
    echo "[build-local] clonando termux-packages en $TP_DIR"
    git clone --depth=1 "$TP_URL" "$TP_DIR"
elif [ "$ACTION" = update ]; then
    git -C "$TP_DIR" pull --ff-only
fi
[ -x "$TP_DIR/build-package.sh" ] || die "checkout inválido: falta build-package.sh"

mkdir -p "$TP_DIR/packages/julia"
cp "$ROOT/packages/julia/build.sh" "$TP_DIR/packages/julia/build.sh"
chmod +x "$TP_DIR/packages/julia/build.sh"
mkdir -p "$ROOT/output"

# build-package.sh no acepta -a en on-device builds: la arquitectura ya es la
# del Termux anfitrión. El preflight exige aarch64 y Julia fija el target
# Android correspondiente en Make.user.
cmd=("$TP_DIR/build-package.sh" -I -s --format "$FORMAT" -j "$JOBS")
[ "$CONTINUE" -eq 1 ] && cmd+=( -c )
[ "$FORCE" -eq 1 ] && cmd+=( -f )
cmd+=( julia )
printf '[build-local] comando:'
printf ' %q' "$TCR" "${cmd[@]}"
printf '\n'
printf '[build-local] prefijo: %s | jobs: %s | formato: %s\n' "$PREFIX" "$JOBS" "$FORMAT"

if [ "$ACTION" = dry-run ]; then
    exit 0
fi

export TERMUX_PREFIX="$PREFIX"
export TERMUX_PKG_MAKE_PROCESSES="$JOBS"
export TERMUX_PKG_API_LEVEL="${TERMUX_PKG_API_LEVEL:-29}"
export TERMUX_PKG_BUILD_IN_SRC=true
"$TCR" -j "$JOBS" -- "${cmd[@]}"

# termux-packages normalmente escribe en output/ del checkout. Copia los
# artefactos al repositorio para que el resultado sea fácil de encontrar.
find "$TP_DIR/output" -maxdepth 1 -type f \( -name 'julia-*.deb' -o -name 'julia-*.pkg.tar.*' \) -exec cp -f {} "$ROOT/output/" \; 2>/dev/null || true
echo "[build-local] artefactos:" 
find "$ROOT/output" -maxdepth 1 -type f -name 'julia-*' -print
