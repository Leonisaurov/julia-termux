ARG TERMUX_BUILDER_IMAGE=ghcr.io/termux/package-builder:latest
FROM ${TERMUX_BUILDER_IMAGE}

# The package-builder image is the cross-compilation base. Keep this derived
# image small and install only host tools used by Julia's CI workflow.
USER root
RUN apt-get update -qq \
    && apt-get install -yqq --no-install-recommends \
        ccache cmake ninja-build zlib1g-dev libtinfo-dev \
    && rm -rf /var/lib/apt/lists/*

USER builder
