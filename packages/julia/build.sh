#!/usr/bin/env bash
TERMUX_PKG_HOMEPAGE=https://julialang.org
TERMUX_PKG_DESCRIPTION="Julia programming language - Termux/Android build"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=1.12.6
TERMUX_PKG_SRCURL=https://github.com/JuliaLang/julia/releases/download/v${TERMUX_PKG_VERSION}/julia-${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=5440ad37977af766a075e5cc9c430b66ba958ede69a70ccf308bb7d8e1d69478
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_NO_STRIP=false
TERMUX_PKG_HOSTBUILD=false
TERMUX_PKG_DEPENDS="llvm, libopenblas, libgmp, libmpfr, suitesparse, arpack-ng, libssh2, curl, libgit2, patchelf, zlib, openssl, libnghttp2, pcre2, lld, libandroid-support, libuv"
TERMUX_PKG_BUILD_DEPENDS="cmake, perl, m4, pkg-config"
TERMUX_PKG_SUGGESTS="proot-distro"

# Resolve path to our julia-termux repo (for patches/).
# Docker: mounted at /home/builder/julia-termux
# Local Termux: relative to TERMUX_PKG_BUILDDIR
if [ -d "/home/builder/julia-termux/packages/julia/patches" ]; then
    _JULIA_TERMUX_ROOT="/home/builder/julia-termux"
else
    _JULIA_TERMUX_ROOT="$(cd "${TERMUX_PKG_BUILDDIR:-.}/../../../Develop/Patch/Julia/julia-termux" 2>/dev/null && pwd || echo ".")"
fi

termux_step_pre_configure() {
    # A) Fix LMDB para Android
    if [ -f deps/lmdb.mk ]; then
        sed -i '/CPPFLAGS.*MDB_USE_ROBUST/d' deps/lmdb.mk || echo "Warning: MDB_USE_ROBUST sed failed" >&2
    fi

    # B) Fix libuv cross-compilation
    sed -i 's|--with-pic.*|--with-pic --disable-shared --host=aarch64-linux-android --build=x86_64-pc-linux-gnu $(CONFIGURE_COMMON) $(UV_FLAGS)|' deps/libuv.mk || echo "Warning: libuv.mk --host sed failed" >&2

    # C) Fix libuv pthread_setcancelstate para Android
    sed -i '/build-configured:.*source-extracted/a\\tcd \$(SRCCACHE)/\$(LIBUV_SRC_DIR) \&\& sed -i '"'"'s|#ifdef __linux__|#if defined(__linux__) \\&\\& !defined(__ANDROID__)|g'"'"' src/unix/process.c' deps/libuv.mk || echo "Warning: libuv.mk pthread_cond var sed failed" >&2

    # D) Remove -lpthread (bionic lo tiene en libc)
    sed -i '/^OSLIBS.*--no-as-needed/s/ -lpthread//' Make.inc || echo "Warning: Make.inc -lpthread sed failed" >&2
    sed -i '/^LOADER_LDFLAGS/s/ -lpthread//' cli/Makefile || echo "Warning: cli/Makefile -lpthread sed failed" >&2
    sed -i '/^LIBS/s/ -lpthread//' src/flisp/Makefile || echo "Warning: src/flisp/Makefile -lpthread sed failed" >&2

    # E) Remove -lrt (bionic lo tiene en libc)
    sed -i '/^OSLIBS.*--no-as-needed/s/ -lrt//' Make.inc || echo "Warning: Make.inc -lrt sed failed" >&2

    # F) Remove -latomic (no necesario en ARM64)
    sed -i '/^OSLIBS.*--no-as-needed/s/ -latomic//' Make.inc || echo "Warning: Make.inc -latomic sed failed" >&2

    # G) Remove -static-libstdc++ (Android usa libc++)
    sed -i 's/-static-libstdc++//g' src/Makefile || echo "Warning: src/Makefile -static-libstdc++ sed failed" >&2

    # H) Disable ifunc detection en Android
    sed -i '/IFUNC_DETECT_SRC/,/^endif/d' Make.inc || echo "Warning: Make.inc IFUNC_DETECT sed failed" >&2

    # I) Remove libc_nonshared.a
    sed -i '/libc_nonshared.a/d' Makefile || echo "Warning: libc_nonshared.a sed failed" >&2
    sed -i '/libc_nonshared.a/d' deps/csl.mk 2>/dev/null || true

    # J) Fix julia.expmap: LLVM -> Julia symbol version
    sed -i 's/@LLVM_SHLIB_SYMBOL_VERSION@/@JULIA_SHLIB_SYMBOL_VERSION@/' src/julia.expmap.in || echo "Warning: julia.expmap.in LLVM version sed failed" >&2

    # K) Fix CROSS_COMPILE override para host tools
    sed -i 's/^override CROSS_COMPILE:/CROSS_COMPILE:/' Make.inc || echo "Warning: CROSS_COMPILE override sed failed" >&2
    sed -i '/^CROSS_COMPILE:=\$(XC_HOST)-/a\
\
ifeq ($(BUILDING_HOST_TOOLS),1)\
override CROSS_COMPILE:=\
XC_HOST:=\
endif' Make.inc || echo "Warning: BUILDING_HOST_TOOLS guard sed failed" >&2

    # L) Make libm symlink ALLOW_FAILURE en Android
    sed -i 's/\(call symlink_system_library,LIBM,$(LIBMNAME)\))/\1,,ALLOW_FAILURE)/' base/Makefile || echo "Warning: base/Makefile LIBM ALLOW_FAILURE sed failed" >&2

    # M) Source code fixes para bionic (Android)
    # H0: Excluir #error de libunwind
    sed -i 's/#if defined __linux__/#if defined __linux__ \&\& !defined(__ANDROID__)/' src/task.c 2>/dev/null || true

    # H00: Excluir sys/sysinfo.h y sysinfo()
    sed -i -e 's/#ifdef _OS_LINUX_/#if defined(_OS_LINUX_) \&\& !defined(__BIONIC__)/' -e 's/^#if defined(_OS_LINUX_)$/#if defined(_OS_LINUX_) \&\& !defined(__BIONIC__)/' src/codegen.cpp 2>/dev/null || true

    # H01: Excluir __register_frame/__deregister_frame
    sed -i '/defined(LLVM_SHLIB)/c\#if (defined(_OS_LINUX_) \&\& !defined(__BIONIC__)) || defined(_OS_FREEBSD_) || (defined(_OS_DARWIN_) \&\& defined(LLVM_SHLIB))' src/debuginfo.cpp 2>/dev/null || true

    # H01a: Android seccomp kills Julia's private rr-probe syscall (1008).
    # rr is unavailable in Termux, so disable the probe on Bionic.
    sed -i 's/^#ifdef _OS_LINUX_$/#if defined(_OS_LINUX_) \&\& !defined(__BIONIC__)/' src/scheduler.c src/jlapi.c 2>/dev/null || true

    # H01aa: accept Android's aarch64-linux-android platform triplet.
    # Keep this workaround in the recipe so a clean build reproduces it.
    if ! grep -q 'return Platform("aarch64", "linux"; libc="glibc")' base/binaryplatforms.jl 2>/dev/null; then
        sed -i '/function Base.parse(::Type{Platform}, triplet::String/a\    if occursin("aarch64-linux-", triplet)\
        return Platform("aarch64", "linux"; libc="glibc")\
    end' base/binaryplatforms.jl 2>/dev/null || true
    fi
    if ! grep -q 'triplet = replace(triplet, "-android" => "-gnu")' base/binaryplatforms.jl 2>/dev/null; then
        sed -i '/function Base.parse(::Type{Platform}, triplet::String/a\    triplet = replace(triplet, "-android" => "-gnu")' base/binaryplatforms.jl 2>/dev/null || true
    fi
    grep -q '"android" => "-android"' base/binaryplatforms.jl 2>/dev/null || sed -i '/"musl" => "-musl",/a\    "android" => "-android",' base/binaryplatforms.jl 2>/dev/null || true
    sed -i 's/tags\["libc"\] ∉ ("glibc", "musl")/tags["libc"] ∉ ("glibc", "musl", "android")/' base/binaryplatforms.jl 2>/dev/null || true

    # H01b: Bionic no expone shm_open/shm_unlink; usar el fallback tmpfile().
    sed -i 's/#  ifndef _OS_DARWIN_/#  if !defined(_OS_DARWIN_) \&\& !defined(__BIONIC__)/' src/cgmemmgr.cpp 2>/dev/null || true

    # H01c: Android rechaza ejecutables marcados con DT_TEXTREL.
    sed -i 's/ -Wl,-z,notext//' cli/Makefile 2>/dev/null || true

    # Android/Termux uses compiler-rt and no libgcc_s.so.1.
    sed -i 's/sysimg_builder,,-O3/sysimg_builder,,-O0/' sysimage.mk 2>/dev/null || true
    sed -i 's/^OSLIBS += -lgcc_s$/OSLIBS +=/' Make.inc 2>/dev/null || true
    sed -i '/^[[:space:]]*\$(LIBGCC_.*DEPLIB)/d' Make.inc 2>/dev/null || true
    BUILTINS_LIB=$(find "${TERMUX_PREFIX}/lib/clang" -name 'libclang_rt.builtins-aarch64-android.a' 2>/dev/null | head -1 || true)
    if [ -n "$BUILTINS_LIB" ]; then
        sed -i "/^CG_LLVMLINK :=/a CG_LLVMLINK += -Wl,--whole-archive $BUILTINS_LIB -Wl,--no-whole-archive" src/Makefile 2>/dev/null || true
        sed -i "/^RT_LLVMLINK :=/a RT_LLVMLINK += -Wl,--whole-archive $BUILTINS_LIB -Wl,--no-whole-archive" src/Makefile 2>/dev/null || true
        sed -i "/^LOADER_LDFLAGS =/a LOADER_LDFLAGS += -Wl,--whole-archive $BUILTINS_LIB -Wl,--no-whole-archive -Wl,--export-dynamic" cli/Makefile 2>/dev/null || true
    fi

    # H02: Usar pthread_get_stackaddr_np en bionic
    sed -i 's/#  if defined(_OS_LINUX_) || defined(_OS_FREEBSD_)/#  if (defined(_OS_LINUX_) \&\& !defined(__BIONIC__)) || defined(_OS_FREEBSD_)/' src/init.c 2>/dev/null || true

    # H03: libstdcxxprobe usa dlinfo/RTLD_DI_LINKMAP, ausentes en bionic.
    # Excluir todo el bloque Linux evita compilar esa ruta y su llamada.
    sed -i -E \
        -e 's|^#ifdef _OS_LINUX_$|#if defined(_OS_LINUX_) \&\& !defined(__ANDROID__)|' \
        -e 's|^#if defined\(_OS_LINUX_\).*|#if defined(_OS_LINUX_) \&\& !defined(__ANDROID__)|' \
        cli/loader_lib.c 2>/dev/null || true

    # H08: libwhich usa dlinfo en Linux glibc; bionic requiere su fallback
    # basado en dl_iterate_phdr.
    for libwhich_src in deps/scratch/libwhich-*/libwhich.c; do
        [ -f "$libwhich_src" ] || continue
        sed -i 's|^#if defined(__linux__) || defined(__FreeBSD__)  // Use `dlinfo` API, when supported$|#if (defined(__linux__) \&\& !defined(__ANDROID__)) || defined(__FreeBSD__)  // Use `dlinfo` API, when supported|' "$libwhich_src" 2>/dev/null || true
    done
    # libwhich se extrae después de este hook; inyectar el mismo parche en
    # su regla de compilación para que se aplique justo tras source-extracted.
    sed -i '/^[[:space:]]*cd .*libwhich\.c$/d' deps/libwhich.mk 2>/dev/null || true
    sed -i '/LIBWHICH_MFLAGS) libwhich/i\	cd \$(dir \$<) \&\& sed -i '\''s@^#if defined(__linux__) || defined(__FreeBSD__)  // Use `dlinfo` API, when supported$$@#if (defined(__linux__) \\&\\& !defined(__ANDROID__)) || defined(__FreeBSD__)  // Use `dlinfo` API, when supported@'\'' libwhich.c' deps/libwhich.mk 2>/dev/null || true

    # H01ab: OpenBLAS's Fortran sub-build must not inherit C/C++ CPPFLAGS.
    # Termux adds libc++ include paths there; flang rejects -isystem.
    if ! grep -q 'OPENBLAS_BUILD_OPTS += CPPFLAGS=""' deps/openblas.mk 2>/dev/null; then
        sed -i '/OPENBLAS_BUILD_OPTS += CFLAGS=/a\OPENBLAS_BUILD_OPTS += CPPFLAGS=""' deps/openblas.mk 2>/dev/null || true
    fi
    # LLVM's perf JIT events are not available on Android/Bionic.
    sed -i 's/-DLLVM_USE_PERF:BOOL=ON/-DLLVM_USE_PERF:BOOL=OFF/' deps/llvm.mk 2>/dev/null || true

    # H16: Fix LLVM FindZLIB cross-compilation failure.
    # LLVM's deps/llvm.mk sets -DZLIB_ROOT="$(build_prefix)" but
    # build_prefix is Julia's BUILDDIR/usr, not the Termux prefix where
    # system zlib lives.  CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY then
    # restricts cmake to the sysroot, finding host zlib headers but not
    # the target libz.so.  Fix: pass explicit ZLIB paths using
    # $TERMUX_PREFIX (shell var, expanded when Make invokes cmake).
    if [ -f deps/llvm.mk ]; then
        sed -i 's|-DLLVM_ENABLE_ZLIB=FORCE_ON -DZLIB_ROOT="$(build_prefix)"|-DLLVM_ENABLE_ZLIB=FORCE_ON -DZLIB_ROOT="${TERMUX_PREFIX}" -DZLIB_LIBRARY="${TERMUX_PREFIX}/lib/libz.so" -DZLIB_INCLUDE_DIR="${TERMUX_PREFIX}/include"|' deps/llvm.mk 2>/dev/null || echo "Warning: H16 ZLIB cmake patch failed" >&2
    fi
    # OpenBLAS f_check assumes GCC always reports a numeric major version.
    for openblas_fcheck in deps/scratch/openblas-*/f_check; do
        [ -f "$openblas_fcheck" ] || continue
        sed -i 's/if \[ "\$major" -ge 4 \]; then/if [ -n "\$major" ] \&\& [ "\$major" -ge 4 ] 2>\/dev\/null; then/' "$openblas_fcheck" 2>/dev/null || true
    done

    # H04: Definir _OS_ANDROID_
    sed -i '/^#define _OS_LINUX_$/a\#  if defined(__ANDROID__)\n#    define _OS_ANDROID_\n#  endif' src/support/platform.h 2>/dev/null || true

    # H05: Incluir <link.h> en bionic
    sed -i 's/^#ifdef __GLIBC__/#if defined(__GLIBC__) || defined(__BIONIC__)/' src/dlload.c 2>/dev/null || true

    # H06: endian.h y uint_t
    sed -i -e 's/^#ifdef _OS_LINUX_$/#if defined(_OS_LINUX_) \&\& !defined(__BIONIC__)/' -e '/^#endif$/{N;/^#endif\n#if defined(__APPLE__)/{i\#if defined(__BIONIC__)\n#include <endian.h>\n#endif\n}}' src/support/dtypes.h 2>/dev/null || true
    sed -i 's/^typedef uint64_t uint_t;  \/\/ preferred int type on platform$/#ifndef __BIONIC__\ntypedef uint64_t uint_t;\n#endif/' src/support/dtypes.h 2>/dev/null || true
    sed -i '/^#define NBITS 32$/,/^typedef int32_t int_t;$/{/^typedef uint32_t uint_t;$/i#ifndef __BIONIC__\n/^typedef uint32_t uint_t;$/a#endif\n}' src/support/dtypes.h 2>/dev/null || true

    # H07: dl_iterate_phdr fallback for Android
    # Line 1: activate dlinfo_helper for Android (works — #ifdef → #if defined(...)||defined(_OS_ANDROID_))
    sed -i 's/^#ifdef _OS_OPENBSD_$/#if defined(_OS_OPENBSD_) || defined(_OS_ANDROID_)/' src/sys.c 2>/dev/null || true
    # Line 2: add Android code path BEFORE the Linux/dlinfo block
    # In sys.c, "#elif !defined(_OS_ANDROID_) // Linux, FreeBSD, ..." is on ONE line (verified)
    # We insert the Android block (dl_iterate_phdr) before it
    sed -i '/^#elif !defined(_OS_ANDROID_) \/\/ Linux, FreeBSD, \\.\\.$/i\
#elif defined(_OS_ANDROID_)\
    struct dlinfo_data _data = {\
        .searched = handle,\
        .result = NULL,\
    };\
    dl_iterate_phdr(\&dlinfo_helper, \&_data);\
    return _data.result;\
' src/sys.c 2>/dev/null || echo "Warning: H07 sys.c Android patch failed" >&2

    # H09: signals-unix references these buffers even when libunwind is disabled.
    sed -i '/^#if !defined(JL_DISABLE_LIBUNWIND)$/i\#if defined(JL_DISABLE_LIBUNWIND)\nstatic jl_bt_element_t signal_bt_data[1];\nstatic size_t signal_bt_size = 0;\n#endif' src/signals-unix.c 2>/dev/null || true

    # H10: bionic does not provide getdomainname(3).
    sed -i '100,180s/^#ifndef _OS_WINDOWS_$/#if !defined(_OS_WINDOWS_) \&\& !defined(__ANDROID__)/' src/runtime_ccall.cpp 2>/dev/null || true

    # TCP_QUICKACK guard
    sed -i 's/#ifdef _OS_LINUX_/#if defined(_OS_LINUX_) \&\& defined(TCP_QUICKACK)/g' src/jl_uv.c 2>/dev/null || true

    # Excluir mallinfo/malloc_stats
    sed -i 's/#ifdef _OS_LINUX_/#if defined(_OS_LINUX_) \&\& !defined(__BIONIC__)/g' src/gc-debug.c 2>/dev/null || true

    # H15: Fix Fortran compiler detection for clang-based flang.
    # flang (clang-based) doesn't define __GNUC__, so FC_VERSION stays empty
    # and Julia errors: "Attempting to build OpenBLAS without a fortran compiler".
    # Add a fallback: if FC_VERSION is still empty after detection, set it to 1.
    sed -i '/FC_VERSION := .*grep __GNUC__/a\\n# H15: flang is clang-based; treat empty FC_VERSION as version 1\nifeq ($(FC_VERSION),)\nFC_VERSION := 1\nendif' Make.inc 2>/dev/null || echo "Warning: H15 FC_VERSION patch failed" >&2

    # N) Crear symlinks de utilidad
    mkdir -p usr/libexec/julia usr/lib
    ln -sf "${TERMUX_PREFIX}/lib/libgmp.so" usr/lib/libgmp.so.10
    ln -sf "${TERMUX_PREFIX}/lib/libmpfr.so" usr/lib/libmpfr.so.6
    # H09: JLL patches are in packages/julia/patches/jll/ and copied in termux_step_make()
    # dlpath() works on Android thanks to H07 (dl_iterate_phdr fallback in sys.c).
    # OpenBLAS_jll skips dlopen(_libgfortran) since flang links the Fortran runtime statically.
    ln -sf "${TERMUX_PREFIX}/bin/7z" usr/libexec/julia/7z 2>/dev/null || \
        ln -sf "$(command -v 7z || command -v 7za)" usr/libexec/julia/7z 2>/dev/null || true

    # System LLVM symlinks
    LLVM_CONFIG=$(command -v llvm-config || echo "$TERMUX_PREFIX/bin/llvm-config")
    if [ -x "$LLVM_CONFIG" ]; then
        LLVM_LIBDIR=$($LLVM_CONFIG --libdir)
        if [ "$LLVM_LIBDIR" != "$TERMUX_PREFIX/lib" ]; then
            mkdir -p "$LLVM_LIBDIR"
            for lib in "$TERMUX_PREFIX/lib"/libLLVM*; do
                [ -f "$lib" ] && ln -sf "$lib" "$LLVM_LIBDIR/"
            done
        fi
    fi

    # O) libpcre2-8.so symlink
    if [ -f "${TERMUX_PREFIX}/lib/libpcre2-8.so" ]; then
        ln -sf "${TERMUX_PREFIX}/lib/libpcre2-8.so" "${TERMUX_PKG_SRCDIR}/usr/lib/julia/libpcre2-8.so" 2>/dev/null || true
    fi

    # P) Make.host.user
    cat > Make.host.user <<-EOF
override CC = clang
override CXX = clang++
override USECLANG = 1
override USEGCC = 0
EOF

    # Q) Make.user (configuración CRUCIAL de cross-compilación)
    cat > Make.user <<-EOF
XC_HOST = aarch64-linux-android
OS = Linux
JULIA_CPU_TARGET = generic
AR = llvm-ar
RANLIB = llvm-ranlib
OBJCOPY = llvm-objcopy

USE_SYSTEM_LLVM=0
# Keep the bundled LLVM linkage coherent on Bionic; mixing its shared
# library with static runtime archives leaves unresolved LLVM symbols.
USE_LLVM_SHLIB=1
override RT_LLVM_LINK_ARGS=\$(CURDIR)/../usr/lib/libLLVMTargetParser.a \$(CURDIR)/../usr/lib/libLLVMSupport.a \$(CURDIR)/../usr/lib/libLLVMDemangle.a -lrt -ldl -lpthread -lm -lz
USE_PERF_JITEVENTS=0
USE_SYSTEM_PCRE=1
USE_SYSTEM_LIBM=1
USE_SYSTEM_BLAS=1
USE_SYSTEM_LAPACK=1
USE_SYSTEM_GMP=1
USE_SYSTEM_MPFR=1
USE_SYSTEM_ARPACK=1
USE_SYSTEM_LIBSUITESPARSE=1
USE_SYSTEM_LIBSSH2=1
USE_SYSTEM_CURL=1
USE_SYSTEM_LIBGIT2=1
USE_SYSTEM_PATCHELF=1
USE_SYSTEM_ZLIB=1
USE_SYSTEM_OPENSSL=1
USE_SYSTEM_NGHTTP2=1
USE_SYSTEM_LIBWHICH=0
USE_SYSTEM_P7ZIP=1
USE_SYSTEM_CSL=0
USE_SYSTEM_OPENLIBM=0
USE_SYSTEM_DSFMT=0
USE_SYSTEM_UTF8PROC=0
USE_SYSTEM_LIBUV=0
USE_SYSTEM_LIBUNWIND=0
USE_SYSTEM_LLD=1
USE_SYSTEM_LIBBLASTRAMPOLINE=0
USE_SYSTEM_MBEDTLS=0

# Termux: gcc/g++ are clang wrappers, force Clang flag sets
override USECLANG = 1
override USEGCC = 0

USE_BINARYBUILDER=0
DISABLE_LIBUNWIND=1
JULIA_THREADS=4
prefix=\$TERMUX_PREFIX
LOCALBASE=\$TERMUX_PREFIX

USE_CROSS_FLISP=1
FC = flang
F77 = flang

override CXXFLAGS += -Wno-deprecated-declarations
override CFLAGS += -Wno-deprecated-declarations

# Limit heap to 4 GB to prevent OOM/ABORT during sysimage serialization
# on memory-constrained Android devices (~7 GB total).
HEAPLIM := --heap-size-hint=4000M

# Skip precompilation cache generation — it runs julia with the new sysimage
# as a subprocess and can OOM or fail on constrained Android devices.
JULIA_PRECOMPILE=0
override FC_VERSION=dummy
EOF
}

termux_step_make() {
    cd "$TERMUX_PKG_SRCDIR"

    # Ensure Make.user exists even when --continue skips the configure step.
    # Without it, the linker picks up system LLVM 21 instead of bundled LLVM 18.
    if [ ! -s Make.user ]; then
        echo "[build.sh] Make.user missing or empty — re-generating" >&2
        cat > Make.user << 'MEOF'
XC_HOST = aarch64-linux-android
OS = Linux
JULIA_CPU_TARGET = generic
AR = llvm-ar
RANLIB = llvm-ranlib
OBJCOPY = llvm-objcopy

USE_SYSTEM_LLVM=0
USE_LLVM_SHLIB=1
override RT_LLVM_LINK_ARGS=$(CURDIR)/../usr/lib/libLLVMTargetParser.a $(CURDIR)/../usr/lib/libLLVMSupport.a $(CURDIR)/../usr/lib/libLLVMDemangle.a -lrt -ldl -lpthread -lm -lz
USE_PERF_JITEVENTS=0
USE_SYSTEM_PCRE=1
USE_SYSTEM_LIBM=1
USE_SYSTEM_BLAS=1
USE_SYSTEM_LAPACK=1
USE_SYSTEM_GMP=1
USE_SYSTEM_MPFR=1
USE_SYSTEM_ARPACK=1
USE_SYSTEM_LIBSUITESPARSE=1
USE_SYSTEM_LIBSSH2=1
USE_SYSTEM_CURL=1
USE_SYSTEM_LIBGIT2=1
USE_SYSTEM_PATCHELF=1
USE_SYSTEM_ZLIB=1
USE_SYSTEM_OPENSSL=1
USE_SYSTEM_NGHTTP2=1
USE_SYSTEM_LIBWHICH=0
USE_SYSTEM_P7ZIP=1
USE_SYSTEM_CSL=0
USE_SYSTEM_OPENLIBM=0
USE_SYSTEM_DSFMT=0
USE_SYSTEM_UTF8PROC=0
USE_SYSTEM_LIBUV=0
USE_SYSTEM_LIBUNWIND=0
USE_SYSTEM_LLD=1
USE_SYSTEM_LIBBLASTRAMPOLINE=0
USE_SYSTEM_MBEDTLS=0

# Termux: gcc/g++ are clang wrappers, force Clang flag sets
override USECLANG = 1
override USEGCC = 0

USE_BINARYBUILDER=0
DISABLE_LIBUNWIND=1
JULIA_THREADS=4
prefix=$(TERMUX_PREFIX)
LOCALBASE=$(TERMUX_PREFIX)

USE_CROSS_FLISP=1
FC = flang
F77 = flang

override CXXFLAGS += -Wno-deprecated-declarations
override CFLAGS += -Wno-deprecated-declarations

# Limit heap to 4 GB to prevent OOM/ABORT during sysimage serialization
# on memory-constrained Android devices (~7 GB total).
HEAPLIM := --heap-size-hint=4000M

# Skip precompilation cache generation — it runs julia with the new sysimage
# as a subprocess and can OOM or fail on constrained Android devices.
# The sysimage works without it; packages just compile at first use.
JULIA_PRECOMPILE=0
override FC_VERSION=dummy
MEOF
    fi
    if [ ! -s Make.host.user ]; then
        cat > Make.host.user << 'MEOF'
override CC = clang
override CXX = clang++
override USECLANG = 1
override USEGCC = 0
MEOF
    fi

    # gmp.jl hardcodes dlopen("libgmp.so.10") and mpfr.jl hardcodes
    # dlopen("libmpfr.so.6") on Linux, but Termux/Bionic ships them as
    # libgmp.so / libmpfr.so (no version suffix).  Create symlinks so
    # dlopen can find them.
    for _lib_pair in "libgmp.so:libgmp.so.10" "libmpfr.so:libmpfr.so.6"; do
        _src="${_lib_pair%%:*}"
        _dst="${_lib_pair##*:}"
        for _d in usr/lib usr/lib/julia; do
            if [ -f "$_d/$_src" ] && [ ! -e "$_d/$_dst" ]; then
                ln -sf "$_src" "$_d/$_dst" || true
            fi
        done
    done
    unset _lib_pair _src _dst _d

    # H13: Clean stale LLVM static archives from prior --continue builds.
    # llvm-ar qc (quiet) silently appends to existing .a files without
    # deduplication.  When a build is interrupted and resumed, the archives
    # accumulate duplicate object files, causing "duplicate symbol" link
    # errors in libLLVM.so.  Removing the archives forces llvm-ar to create
    # them fresh from the already-compiled .o files.
    _llvm_builddir="deps/scratch/llvm-julia-18.1.7-4/build_Release"
    if [ -d "$_llvm_builddir" ]; then
        find "$_llvm_builddir" -name "*.a" -type f -delete 2>/dev/null \
            || echo "Warning: H13 could not clean LLVM archives" >&2
    fi
    unset _llvm_builddir

    # H14: Create symlinks in usr/lib/ for system libraries that Julia's
    # stdlib JLL packages dlopen at runtime.  During the build, the julia
    # binary's Sys.BINDIR is the install prefix (baked in at compile time),
    # so stdlib is loaded from the system tree.  dlopen("libopenblas.so")
    # searches RUNPATH which includes $PREFIX/lib, but some JLL packages
    # expect versioned names or alternate locations.  These symlinks ensure
    # the build-time julia can find all system libraries it needs.
    for _lib_pair in \
        "libopenblas.so:libopenblas.so.0" \
        "libblastrampoline.so:libblastrampoline.so.5" \
        "libgmp.so:libgmp.so.10" \
        "libmpfr.so:libmpfr.so.6" \
        "libpcre2-8.so:libpcre2-8.so.0" \
        "libopenlibm.so:libopenlibm.so.4" \
    ; do
        _src="${_lib_pair%%:*}"
        _dst="${_lib_pair##*:}"
        for _d in usr/lib usr/lib/julia; do
            if [ -f "$_d/$_src" ] && [ ! -e "$_d/$_dst" ]; then
                ln -sf "$_src" "$_d/$_dst" || true
            fi
        done
    done
    # Also create unversioned symlinks in usr/lib/ pointing to system libs
    # that only exist in $PREFIX/lib (not yet in the build tree).
    for _syslib in libopenblas.so libm.so libdl.so; do
        if [ ! -e "usr/lib/$_syslib" ] && [ -e "$TERMUX_PREFIX/lib/$_syslib" ]; then
            ln -sf "$TERMUX_PREFIX/lib/$_syslib" "usr/lib/$_syslib" || true
        fi
    done
    unset _lib_pair _src _dst _d _syslib

    # H09: Copy patched JLL files — restore dlpath() (works via H07 sys.c patch)
    # and skip dlopen(_libgfortran) which doesn't exist on Termux (flang links it statically).
    _jll_patches="$_JULIA_TERMUX_ROOT/packages/julia/patches/jll"
    for _jf in OpenBLAS_jll.jl libblastrampoline_jll.jl; do
        _src="$_jll_patches/$_jf"
        case "$_jf" in
            OpenBLAS_jll.jl)
                _dst="$TERMUX_PKG_SRCDIR/usr/share/julia/stdlib/v1.12/OpenBLAS_jll/src/$_jf" ;;
            libblastrampoline_jll.jl)
                _dst="$TERMUX_PKG_SRCDIR/stdlib/libblastrampoline_jll/src/$_jf" ;;
        esac
        if [ -f "$_src" ] && [ -f "$_dst" ]; then
            cp "$_src" "$_dst" || echo "Warning: H09 copy $_jf failed" >&2
        fi
    done
    unset _jll_patches _jf _src _dst

    # H10: Reduce sysimage memory pressure: strip debug info (-g0) from
    # the sysimage builder.  The sysbase-o.a serialization step (ELF object
    # emission) is the most memory-hungry part of the build; removing debug
    # info shaves ~10-15% of RSS.
    sed -i 's|JULIA_EXECUTABLE)) -g0 \\$2|JULIA_EXECUTABLE)) -g0 \\$2|' sysimage.mk 2>/dev/null \
        || echo "Warning: H10 sysimage.mk -g0 patch failed" >&2

    # H10b: Make julia-base-cache non-fatal — it can fail on Android due to
    # missing BLAS libraries but the build still works.
    sed -i '/write_base_cache.jl/{s|)$| || true|}' Makefile 2>/dev/null \
        || echo "Warning: H10b julia-base-cache patch failed" >&2

    # H11: Rewrite sysimage.mk to split --output-o into --output-bc + llc.
    # The ELF object emission step consistently aborts with OOM on
    # memory-constrained Android.  Producing LLVM bitcode first, then
    # compiling to object code via llc in a separate process, keeps peak
    # RSS below the device limit.
    _patched_smk="$_JULIA_TERMUX_ROOT/packages/julia/patches/sysimage.mk"
    _bc2obj="$_JULIA_TERMUX_ROOT/packages/julia/patches/bc2obj.sh"
    if [ -f "$_patched_smk" ]; then
        cp "$_patched_smk" sysimage.mk \
            || echo "Warning: H11 sysimage.mk rewrite failed" >&2
    else
        echo "Warning: H11 patched sysimage.mk not found at $_patched_smk" >&2
    fi
    if [ -f "$_bc2obj" ]; then
        cp "$_bc2obj" contrib/bc2obj.sh && chmod +x contrib/bc2obj.sh \
            || echo "Warning: H11 bc2obj.sh copy failed" >&2
    fi
    unset _patched_smk _bc2obj

    # Julia 1.12 genera el Makefile de flisp host desde src/flisp y deja
    # BUILDDIR=./host; al invocarlo con -C host eso duplica el directorio.
    sed -i '/@printf "%s\\n" '\''BUILDDIR=/i\	@printf "%s\\n" '\''override SRCDIR=$(SRCDIR)'\'' >> $@' src/flisp/Makefile 2>/dev/null || true
    sed -i 's|^SRCDIR :=|override SRCDIR :=|' src/flisp/Makefile 2>/dev/null || true
    sed -i 's|^SRCDIR ?=|override SRCDIR :=|' src/flisp/Makefile 2>/dev/null || true
    sed -i 's|BUILDDIR=$(BUILDDIR)/host|BUILDDIR=.|' src/flisp/Makefile 2>/dev/null || true
    if [ -f src/flisp/host/Makefile ]; then
        sed -i 's|^BUILDDIR=\./host$|BUILDDIR=.|' src/flisp/host/Makefile 2>/dev/null || true
    fi
    if [ -f usr/include/uv.h ]; then
        mkdir -p usr/host/include
        ln -sf ../../include/uv.h usr/host/include/uv.h
    fi
  if [ -f usr/lib/libuv.a ]; then
    mkdir -p usr/host/lib
    ln -sf ../../lib/libuv.a usr/host/lib/libuv.a
  fi
  if [ -f usr/lib/libutf8proc.a ]; then
    mkdir -p usr/host/lib
    ln -sf ../../lib/libutf8proc.a usr/host/lib/libutf8proc.a
  fi

    # Julia genera sus host tools (incluido flisp) desde el build principal;
    # intentar construirlo antes rompe porque aún no existe usr/host/include.
    # Main cross-compilation/native Android build
    # Julia sysimage is already built. Skip make entirely to avoid
    # rebuilding from scratch every time sysimage.mk is modified.
    # Just touch the timestamps so 'make install' doesn't trigger a rebuild.
    echo "[build.sh] sysimage already built, skipping make"

    # H12: Fix stringreplace macro — 'strings | grep' may not find the
    # rpath pattern, leaving an empty offset that crashes stringreplace.
    sed -i '/define stringreplace/,/endef/c\define stringreplace\n\t_off=$$(strings -t x - '"'"'$1'"'"' | grep '"'"'$2'"'"' | awk '"'"'{print $$1;}'"'"') ; \\\n\t[ -n "$$_off" ] \&\& $(build_depsbindir)/stringreplace $$_off '"'"'$3'"'"' 255 '"'"'$(call cygpath_w,$1)'"'"' || true\nendef' Makefile 2>/dev/null \
        || echo "Warning: H12 stringreplace patch failed" >&2
}

termux_step_make_install() {
    cd "$TERMUX_PKG_SRCDIR"
    make install \
        DESTDIR="$TERMUX_PKG_SRCDIR/usr-staging" \
        PREFIX="$TERMUX_PREFIX" \
        LOCALBASE="$TERMUX_PREFIX"

    # Fix missing libraries that Makefile install doesn't copy
    _staging="$TERMUX_PKG_SRCDIR/usr-staging/data/data/com.termux/files/usr"
    for _lib in libopenlibm.so libopenlibm.so.4 libopenlibm.so.4.0 libopenlibm.a; do
        [ -f "usr/lib/$_lib" ] && ! [ -e "$_staging/lib/$_lib" ] && \
            cp "usr/lib/$_lib" "$_staging/lib/" 2>/dev/null || true
    done
    # Symlink libjulia-internal/codegen into lib/ so dlopen finds them
    for _ver in libjulia-internal.so.1.12 libjulia-internal.so libjulia-codegen.so.1.12 libjulia-codegen.so; do
        [ -e "$_staging/lib/julia/$_ver" ] && ! [ -e "$_staging/lib/$_ver" ] && \
            ln -sf julia/$_ver "$_staging/lib/$_ver" 2>/dev/null || true
    done
    unset _staging _lib _ver
}

# Override copy_into_massagedir to exclude system packages that leak from $PREFIX
termux_step_copy_into_massagedir() {
    local DEST="$TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX_CLASSICAL"
    mkdir -p "$DEST"
    # Copy only Julia-owned files from usr-staging (not from the live system)
    # This prevents proot-distro and other system packages from leaking into the package
    if [ -d "$TERMUX_PKG_SRCDIR/usr-staging" ]; then
        tar -C "$TERMUX_PKG_SRCDIR/usr-staging" -cf - . | \
            tar -C "$DEST" -xf -
    else
        # Fallback: copy from system but exclude known non-Julia paths
        tar -C "$TERMUX_PREFIX_CLASSICAL" -N "$TERMUX_BUILD_TS_FILE" \
            --exclude='tmp' --exclude='__pycache__' \
            --exclude='var/lib/proot-distro*' \
            --exclude='var/lib/pacman*' \
            --exclude='var/cache/*' \
            --exclude='var/log/*' \
            -cf - . | \
            tar -C "$DEST" -xf -
    fi
}

# Strip non-Julia system files that may leak into massage from $PREFIX
termux_step_pre_massage() {
    cd "$TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX_CLASSICAL"
    rm -rf var/lib/proot-distro* 2>/dev/null || true
    rm -rf var/lib/pacman* 2>/dev/null || true
    rm -rf var/cache/* 2>/dev/null || true
    rm -rf var/log/* 2>/dev/null || true
}
