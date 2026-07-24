# Julia for Termux

This repository builds the [Julia programming language](https://julialang.org) for
Termux/Android using the [termux-packages](https://github.com/termux/termux-packages)
build infrastructure.

## Status

Work in progress. Julia master branch cross-compiled for aarch64 (Android).

## Directory Layout

```
├── .github/
│   ├── actions/zram/    – GitHub Action to enable zram for build
│   └── workflows/       – CI workflow
├── packages/julia/      – Build script and patches
│   ├── build.sh
│   ├── 0001-*.patch
│   └── ...
├── scripts/             – From termux-packages (Docker, build helpers)
├── build-package.sh     – From termux-packages
├── repo.json            – From termux-packages
└── README.md
```

## Build Locally

```bash
./scripts/run-docker.sh ./build-package.sh -I -a aarch64 julia
```

## Patches

Patches are applied via `termux_step_pre_configure()` in `build.sh`.
They adapt Julia's C/C++ runtime and build system for Android/bionic:

1. `0001-*` – Define `_OS_ANDROID_` in platform.h
2. `0002-*` – Bionic endian.h and uint_t compat in dtypes.h
3. `0003-*` – dl_iterate_phdr fallback for jl_pathname_for_handle
4. `0004-*` – Include link.h on bionic in dlload.c
5. `0005-*` – Stub libstdcxxprobe on Android
6. `0006-*` – Disable robust mutex in LMDB
7. `0007-*` – Relax gfortran check when using system libs
8. `0008-*` – Guard libunwind-dependent code in signals-unix.c
9. `0009-*` – Skip getdomainname on old Android APIs
10. `0010-*` – Apply libuv Android pthread-cancel patch
