#!/bin/bash
set -euo pipefail

# run-docker.sh — Wrapper para ejecutar builds dentro del contenedor de
# termux-packages. Patrón idéntico a termux-packages/scripts/run-docker.sh.
#
# Uso:
#   ./scripts/run-docker.sh                                  # shell interactivo
#   ./scripts/run-docker.sh ./scripts/build-local.sh         # build completo
#   ./scripts/run-docker.sh bash -c 'cd ... && ./build-package.sh ...'
#
# El contenedor monta:
#   - termux-packages (con TODOS sus scripts/) en /home/builder/termux-packages
#   - julia-termux (nuestro repo) en /home/builder/julia-termux
#   - ~/.termux-build (cache) en /home/builder/.termux-build
#
# Variables de entorno:
#   TERMUX_BUILDER_IMAGE_NAME   Imagen Docker (default: ghcr.io/termux/package-builder)
#   CONTAINER_NAME              Nombre del contenedor (default: julia-termux-builder)
#   TERMUX_DOCKER_RUN_EXTRA_ARGS  Args extra para docker run (solo al crear)
#   TERMUX_DOCKER_EXEC_EXTRA_ARGS Args extra para docker exec

SCRIPTDIR=$(cd "$(dirname "$0")" && pwd)
REPOROOT=$(cd "$SCRIPTDIR/.." && pwd)

: "${TERMUX_BUILDER_IMAGE_NAME:=ghcr.io/termux/package-builder}"
: "${CONTAINER_NAME:=julia-termux-builder}"
: "${TERMUX_DOCKER_RUN_EXTRA_ARGS:=}"
: "${TERMUX_DOCKER_EXEC_EXTRA_ARGS:=}"

CONTAINER_HOME_DIR=/home/builder
TP_DIR="${TERMUX_PACKAGES_DIR:-$HOME/.cache/julia-termux/termux-packages}"

_show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [COMMAND]

Run a command in the Julia Termux builder container.

Options:
  -h, --help              Show this help

The container mounts:
  - termux-packages → /home/builder/termux-packages  (build system)
  - julia-termux    → /home/builder/julia-termux      (our repo with patches)
  - ~/.termux-build → /home/builder/.termux-build     (build cache)
EOF
    exit 0
}

while (( $# != 0 )); do
    case "$1" in
        -h|--help) shift; _show_usage;;
        --) shift; break;;
        -*) echo "Error: Unknown option '$1'" >&2; exit 1;;
        *) break;;
    esac
done

# NOTE: termux-packages checkout is managed by the workflow / caller.
# This script does NOT clone it — the caller ensures $TP_DIR exists.

# CI detection
if [ "${CI:-}" = "true" ]; then
    CI_OPT="--env CI=true"
else
    CI_OPT=""
fi

# SELinux-aware volume mounts
_selinux_opt() {
    if [ -n "$(command -v getenforce 2>/dev/null)" ] && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
        echo ":z"
    else
        echo ""
    fi
}

SEC_SELINUX=$(_selinux_opt)

VOLUMES=(
    --volume "$TP_DIR:$CONTAINER_HOME_DIR/termux-packages${SEC_SELINUX}"
    --volume "$REPOROOT:$CONTAINER_HOME_DIR/julia-termux${SEC_SELINUX}"
    --volume "$HOME/.termux-build:$CONTAINER_HOME_DIR/.termux-build${SEC_SELINUX}"
)

# Docker tty detection
if [ -t 1 ]; then
    DOCKER_TTY="--tty"
else
    DOCKER_TTY=""
fi

echo "Running container '$CONTAINER_NAME' from image '$TERMUX_BUILDER_IMAGE_NAME'..."
echo "  termux-packages: $TP_DIR"
echo "  julia-termux:    $REPOROOT"
echo "  build cache:     $HOME/.termux-build"

# Create container if it doesn't exist
if ! docker container inspect "$CONTAINER_NAME" > /dev/null 2>&1; then
    echo "Creating new container..."
    docker run \
        --detach \
        --init \
        --name "$CONTAINER_NAME" \
        "${VOLUMES[@]}" \
        --tty \
        $TERMUX_DOCKER_RUN_EXTRA_ARGS \
        "$TERMUX_BUILDER_IMAGE_NAME"

    # Fix uid/gid to match host (needed for file ownership in mounted volumes)
    if [ "$(uname)" != "Darwin" ]; then
        if [ "$(id -u)" -ne 1001 ] && [ "$(id -u)" -ne 0 ]; then
            echo "Adjusting builder uid/gid to $(id -u):$(id -g)..."
            docker exec $DOCKER_TTY $TERMUX_DOCKER_EXEC_EXTRA_ARGS "$CONTAINER_NAME" \
                sudo chown -R "$(id -u):$(id -g)" "$CONTAINER_HOME_DIR" 2>/dev/null || true
            docker exec $DOCKER_TTY $TERMUX_DOCKER_EXEC_EXTRA_ARGS "$CONTAINER_NAME" \
                sudo usermod -u "$(id -u)" builder 2>/dev/null || true
            docker exec $DOCKER_TTY $TERMUX_DOCKER_EXEC_EXTRA_ARGS "$CONTAINER_NAME" \
                sudo groupmod -g "$(id -g)" builder 2>/dev/null || true
        fi
    fi
fi

# Start container if stopped
if [ "$(docker container inspect -f '{{ .State.Running }}' "$CONTAINER_NAME" 2>/dev/null)" = "false" ]; then
    docker start "$CONTAINER_NAME" > /dev/null 2>&1
fi

# Default to bash if no command given
if [ "$#" -eq 0 ]; then
    set -- bash
fi

docker exec $CI_OPT --interactive $DOCKER_TTY $TERMUX_DOCKER_EXEC_EXTRA_ARGS "$CONTAINER_NAME" "$@"
