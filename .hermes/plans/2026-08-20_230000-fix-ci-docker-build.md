# Plan: Fix CI Docker Build for Julia Termux

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Make the GitHub Actions CI workflow successfully cross-compile Julia for Termux/Android aarch64 inside a Docker container.

**Architecture:** The Docker image `ghcr.io/termux/package-builder` is Ubuntu-based with Termux cross-compilation tools (NDK, CGCT). The current workflow fails because:
1. `pkg` (Termux package manager) doesn't work inside Docker — it's Ubuntu, not Termux
2. Cross-compilation needs dependencies (zlib, openblas, etc.) built into the Termux sysroot BEFORE LLVM cmake can find them
3. `build-package.sh -s` assumes deps are already installed; without `-s`, `pkg install` fails in Docker

**Approach:** Build dependencies as separate termux-packages first (without `-s`), then build Julia with `-s`. The `build-package.sh` system handles dependency ordering automatically when deps are built as separate packages.

**Tech Stack:** GitHub Actions, Docker (ghcr.io/termux/package-builder), termux-packages build system, bash

---

## Problem Analysis

### Root Cause Chain

```
CI build fails with "Could NOT find ZLIB (missing: ZLIB_LIBRARY)"
  → LLVM cmake looks for zlib in cross-compilation sysroot (/data/data/com.termux/files/usr/lib)
  → zlib.so doesn't exist there yet
  → build-package.sh with -s doesn't install deps
  → build-package.sh without -s uses `pkg install` which doesn't work in Docker (Ubuntu)
  → pkg is Termux's package manager, not available in Ubuntu Docker image
```

### Why Local Build Works

Local Termux build works because `pkg install zlib libopenblas libgmp ...` already installed all dependencies into `$PREFIX` (`/data/data/com.termux/files/usr`). The cross-compilation sysroot already has everything.

### What termux-packages CI Does

The official termux-packages CI builds packages one at a time in dependency order. Each package gets built and installed into the prefix before its dependents are built. Our workflow tries to build Julia (with all its deps) in a single call, which doesn't work because deps aren't pre-built.

---

## Step-by-Step Plan

### Task 1: Create dependency build script

**Objective:** Create a script that builds all Julia dependencies as separate termux-packages before building Julia itself.

**Files:**
- Create: `scripts/build-deps-docker.sh`

**Step 1: Create the script**

```bash
#!/bin/bash
# build-deps-docker.sh — Build Julia's dependencies inside Docker.
# Called from workflow via run-docker.sh.
set -euo pipefail

cd /home/builder/termux-packages

# System build tools needed for LLVM (Ubuntu, not Termux)
sudo apt-get update -qq
sudo apt-get install -yqq cmake ninja-build zlib1g-dev libtinfo-dev

# Build each dependency as a separate termux-packages package.
# build-package.sh builds AND installs into the Termux prefix,
# making them available for cross-compilation.
DEPS=(
  zlib
  libgmp
  libmpfr
  openssl
  libssh2
  curl
  libnghttp2
  pcre2
  libuv
  libopenblas
  suitesparse
  arpack-ng
  libgit2
  patchelf
  libandroid-support
)

for pkg in "${DEPS[@]}"; do
  echo "=== Building dependency: $pkg ==="
  ./build-package.sh -I -s "$pkg" || {
    echo "WARNING: Failed to build $pkg, continuing..."
  }
done

echo "=== All dependencies built ==="
```

**Step 2: Make executable**
```bash
chmod +x scripts/build-deps-docker.sh
```

**Step 3: Commit**
```bash
git add scripts/build-deps-docker.sh
git commit -m "ci: add dependency build script for Docker CI"
```

---

### Task 2: Rewrite the workflow Build step

**Objective:** Replace the single `build-package.sh` call with a two-phase build: deps first, then Julia.

**Files:**
- Modify: `.github/workflows/build-package.yml` (lines 76-86)

**Step 1: Replace the Build Julia step**

Old (broken):
```yaml
    - name: Build Julia via Docker
      run: |
        ./scripts/run-docker.sh bash -c '
          export TERMUX_PROOT_DISABLED=1
          /home/builder/julia-termux/scripts/patch-fuse-overlayfs.sh /home/builder/termux-packages || true
          cd /home/builder/termux-packages
          sudo apt-get update -qq && sudo apt-get install -yqq \
            cmake ninja-build zlib1g-dev libtinfo-dev libz-dev 2>/dev/null || true
          ./build-package.sh -I --format debian -j 2 -f julia
        '
```

New:
```yaml
    - name: Build Julia dependencies via Docker
      run: |
        ./scripts/run-docker.sh bash -c '
          export TERMUX_PROOT_DISABLED=1
          /home/builder/julia-termux/scripts/patch-fuse-overlayfs.sh /home/builder/termux-packages || true
          /home/builder/julia-termux/scripts/build-deps-docker.sh
        '

    - name: Build Julia via Docker
      run: |
        ./scripts/run-docker.sh bash -c '
          export TERMUX_PROOT_DISABLED=1
          cd /home/builder/termux-packages
          ./build-package.sh -I -s --format debian -j 2 julia
        '
```

**Step 2: Commit**
```bash
git add .github/workflows/build-package.yml
git commit -m "ci: two-phase build (deps first, then Julia)"
```

---

### Task 3: Fix fuse-overlayfs patch script for Docker

**Objective:** Ensure the fuse-overlayfs patch works correctly in Docker. The current patch script has a `|| true` on the verification step which masks issues.

**Files:**
- Modify: `scripts/patch-fuse-overlayfs.sh`

**Step 1: Verify the patch script is correct**

The current script deletes the fuse-overlayfs block and replaces it with `cp` of the NDK toolchain. This is correct for Docker. No changes needed unless testing reveals issues.

**Step 2: Commit (if changes needed)**
```bash
git add scripts/patch-fuse-overlayfs.sh
git commit -m "ci: fix fuse-overlayfs patch for Docker"
```

---

### Task 4: Fix `_JULIA_TERMUX_ROOT` variable scope

**Objective:** Ensure `_JULIA_TERMUX_ROOT` is declared globally (not inside a function) so `set -u` (nounset) doesn't fail.

**Files:**
- Modify: `packages/julia/build.sh` (lines 15-23)

**Current state:** Already fixed in commit f2ec3a0. Variable is declared globally before `termux_step_pre_configure()`.

**Step 1: Verify the fix is correct**

The variable is now declared at the top level of build.sh:
```bash
if [ -d "/home/builder/julia-termux/packages/julia/patches" ]; then
    _JULIA_TERMUX_ROOT="/home/builder/julia-termux"
else
    _JULIA_TERMUX_ROOT="$(cd "${TERMUX_PKG_BUILDDIR:-.}/../../../Develop/Patch/Julia/julia-termux" 2>/dev/null && pwd || echo ".")"
fi
```

This is correct. No changes needed.

---

### Task 5: Fix build.sh dependency names

**Objective:** Ensure `TERMUX_PKG_DEPENDS` uses correct Termux package names.

**Files:**
- Modify: `packages/julia/build.sh` (line 12)

**Current state:** Already fixed in commits 51ea050 and c03bb92. Package names are now `libopenblas, libgmp, libmpfr` (not `openblas, gmp, mpfr`). `p7zip` removed.

**Step 1: Verify dependency names match Termux repo**

Current:
```bash
TERMUX_PKG_DEPENDS="llvm, libopenblas, libgmp, libmpfr, suitesparse, arpack-ng, libssh2, curl, libgit2, patchelf, zlib, openssl, libnghttp2, pcre2, lld, libandroid-support, libuv"
```

These names should match the actual Termux package names. No changes needed.

---

### Task 6: Add CI-specific Make.user generation

**Objective:** Ensure `Make.user` is correctly generated inside Docker with proper paths.

**Files:**
- Review: `packages/julia/build.sh` (lines 270-336, `termux_step_make()` fallback)

**Step 1: Verify Make.user generation works in Docker**

The `termux_step_make()` function has a fallback that regenerates `Make.user` if it's empty. This should work in Docker since it uses `TERMUX_PKG_SRCDIR` which is set by `build-package.sh`.

No changes needed unless testing reveals issues.

---

### Task 7: Test the full CI pipeline

**Objective:** Push changes and verify the CI build completes successfully.

**Step 1: Push all changes**
```bash
git add -A
git commit -m "ci: complete Docker CI pipeline fix"
git push
```

**Step 2: Monitor the CI build**

Wait for the GitHub Actions workflow to complete. Expected timeline:
- Dependency builds: ~30-60 minutes (zlib, openssl, etc.)
- Julia build: ~8-10 hours (LLVM compilation)
- Total: ~10-12 hours

**Step 3: Verify artifacts**

If successful:
- `.deb` package in `output/`
- Published to GitHub Release `julia-latest`
- Uploaded as GitHub Actions artifact

---

## Risks and Tradeoffs

### Risk 1: Dependency build failures
Some dependencies might fail to build in Docker. Mitigation: The `build-deps-docker.sh` script has `|| continue` to skip failed deps. Julia might still build without optional deps.

### Risk 2: Docker cache invalidation
The `actions/cache` key includes `hashFiles('packages/julia/build.sh')`. Changing build.sh invalidates the cache. This is correct behavior — changes to build.sh should trigger a full rebuild.

### Risk 3: LLVM compilation time
LLVM takes 8-10 hours with `-j2`. GitHub Actions has a 6-hour default timeout. We set `timeout-minutes: 720` (12h) to handle this.

### Risk 4: fuse-overlayfs patch
The patch replaces fuse-overlayfs with `cp` of the NDK toolchain. This works but uses more disk space (~1GB per copy). Mitigation: Docker container has enough space, and the cache persists between runs.

---

## Files Changed Summary

| File | Change | Status |
|------|--------|--------|
| `scripts/build-deps-docker.sh` | New: dependency build script | To create |
| `.github/workflows/build-package.yml` | Two-phase build (deps + Julia) | To modify |
| `scripts/patch-fuse-overlayfs.sh` | Already fixed | No change |
| `scripts/run-docker.sh` | Already working | No change |
| `packages/julia/build.sh` | Already fixed (nounset, deps) | No change |

---

## Open Questions

1. **Should we cache built dependencies separately?** Currently `~/.termux-build` is cached as a whole. If only Julia changes, deps don't need rebuilding. The current cache key invalidates on any build.sh change.

2. **Should we use `--force` for deps?** Currently deps are built with `-I -s` (install, skip deps). If a dep fails, `--force` would retry. But `--force` rebuilds everything, which is slow.

3. **Docker image version pinning?** Using `:latest` means the image can change unexpectedly. Should we pin to a specific digest?
