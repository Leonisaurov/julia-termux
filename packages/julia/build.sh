TERMUX_PKG_HOMEPAGE=https://julialang.org
TERMUX_PKG_DESCRIPTION="Julia programming language - Termux/Android build"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=1.14.0
TERMUX_PKG_SRCURL=https://github.com/JuliaLang/julia/archive/refs/heads/master.tar.gz
TERMUX_PKG_GIT_BRANCH=master
TERMUX_PKG_BUILD_IN_SRC=true
# Dependencies installed via CI workflow before build (not declared here to avoid
# buildorder.py looking up non-existent packages/ dir entries for each dep)
TERMUX_PKG_NO_STRIP=false
# Julia handles cross-compilation natively in its Makefile (no hostbuild target)
TERMUX_PKG_HOSTBUILD=false

termux_step_pre_configure() {
	cd "$TERMUX_PKG_SRCDIR"

	# Fix LMDB for Android/bionic: the forced MDB_USE_ROBUST=1 bypasses mdb.c's
	# built-in Android guard (lines 354-362), causing build failure on bionic.
	# Remove the forced flag so the guard can work.
	sed -i '/CPPFLAGS.*MDB_USE_ROBUST/d' deps/lmdb.mk || echo "Warning: MDB_USE_ROBUST sed on lmdb.mk failed" >&2

	# Fix libuv cross-compilation: the CI runner is x86_64, but the target is
	# aarch64-linux-android. Without --host, configure tries to run test programs
	# compiled for the target, which fail on the build machine.
	sed -i 's|--with-pic.*|--with-pic --host=aarch64-linux-android --build=x86_64-pc-linux-gnu $(CONFIGURE_COMMON) $(UV_FLAGS)|' deps/libuv.mk || echo "Warning: libuv.mk --host sed failed" >&2

	# Fix libuv pthread_setcancelstate for Android/bionic: Julia removed the
	# broken patch from libuv.mk entirely.  Insert a sed to add the missing
	# !defined(__ANDROID__) guard before the configure step.
	sed -i '/build-configured:.*source-extracted/a\\tcd \$(SRCCACHE)/\$(LIBUV_SRC_DIR) \&\& sed -i '"'"'s|#ifdef __linux__|#if defined(__linux__) \\&\\& !defined(__ANDROID__)|g'"'"' src/unix/process.c' deps/libuv.mk || echo "Warning: libuv.mk pthread_cond var sed failed" >&2

	# Remove -lpthread from all Makefiles (bionic has pthread in libc)
	sed -i '/^OSLIBS.*--no-as-needed/s/ -lpthread//' Make.inc || echo "Warning: Make.inc -lpthread sed failed" >&2
	sed -i '/^LOADER_LDFLAGS/s/ -lpthread//' cli/Makefile || echo "Warning: cli/Makefile -lpthread sed failed" >&2
	sed -i '/^LIBS/s/ -lpthread//' src/flisp/Makefile || echo "Warning: src/flisp/Makefile -lpthread sed failed" >&2

	# The host flisp build path (USE_CROSS_FLISP=1 -> src/flisp/host/) has
	# BUILDDIR/pattern bugs in GNU make.  We build host flisp manually below
	# in termux_step_make() with an absolute BUILDDIR and explicit CC=gcc.

	# Fix julia.expmap: replace LLVM version token with Julia version token
	# so the generated file has a single version block (lld rejects multiple)
	sed -i 's/@LLVM_SHLIB_SYMBOL_VERSION@/@JULIA_SHLIB_SYMBOL_VERSION@/' src/julia.expmap.in || echo "Warning: julia.expmap.in LLVM version sed failed" >&2

	# Fix gfortran check: Make.inc errors when no gfortran is found, even when
	# USE_SYSTEM_OPENBLAS=1 and USE_SYSTEM_LIBSUITESPARSE=1 are set. We'll
	# pass FC_VERSION=dummy on the make command line to bypass the check.

	# Pre-create the 7z symlink in build_private_libexecdir so that
	# base/Makefile's symlink_p7zip rule always succeeds (its $(shell which 7z)
	# may fail if PATH is scoped in a sub-make).  Even with
	# USE_SYSTEM_P7ZIP=1, the deps are skipped, but JL_PRIVATE_EXES always
	# lists "7z", so the file must exist at install time.
	mkdir -p usr/libexec/julia
	ln -sf "${TERMUX_PREFIX}/bin/7z" usr/libexec/julia/7z 2>/dev/null || \
		ln -sf "$(command -v 7z || command -v 7za)" usr/libexec/julia/7z 2>/dev/null || true

	# System LLVM was extracted from .deb into $TERMUX_PREFIX, but
	# llvm-config reports libdir relative to the build-time NDK sysroot
	# cache.  Symlink each reported .so/.a from the prefix to the
	# llvm-config-reported location so that Julia's Makefile can find
	# them.
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

	# Fix A: Remove -lrt from OSLIBS (bionic has librt functions in libc)
	sed -i '/^OSLIBS.*--no-as-needed/s/ -lrt//' Make.inc || echo "Warning: Make.inc -lrt sed failed" >&2

	# Fix B: Disable ifunc detection on Android (bionic doesn't support ifunc)
	sed -i '/IFUNC_DETECT_SRC/,/^endif/d' Make.inc || echo "Warning: Make.inc IFUNC_DETECT sed failed" >&2

	# Fix C: Skip copying glibc-specific CRT objects on Android
	sed -i '/libc_nonshared.a/d' Makefile || echo "Warning: libc_nonshared.a sed on Makefile failed" >&2

	# Fix D: Remove -static-libstdc++ for Android (uses libc++)
	sed -i 's/-static-libstdc++//g' src/Makefile || echo "Warning: src/Makefile -static-libstdc++ sed failed" >&2

	# Fix E: libc_nonshared.a in deps/csl.mk
	sed -i '/libc_nonshared.a/d' deps/csl.mk 2>/dev/null || true

	# Fix F: Remove -latomic from OSLIBS
	sed -i '/^OSLIBS.*--no-as-needed/s/ -latomic//' Make.inc || echo "Warning: Make.inc -latomic sed failed" >&2

	# Fix: Remove 'override' from CROSS_COMPILE to prevent MAKEOVERRIDES leakage
	# into host tool sub-makes (BUILDING_HOST_TOOLS=1). Without this,
	# CROSS_COMPILE=aarch64-linux-android- leaks via MAKEOVERRIDES, causing
	# aarch64-linux-android-gcc to be used for host flisp (doesn't exist in NDK).
	sed -i 's/^override CROSS_COMPILE:/CROSS_COMPILE:/' Make.inc || echo "Warning: CROSS_COMPILE override sed on Make.inc failed" >&2

	# Fix G: Make libm symlink ALLOW_FAILURE on Android/bionic.
	# On bionic, libm is part of libc — no standalone libm.so exists.
	# Julia's base/Makefile tries to locate it to create a runtime symlink.
	# Adding ALLOW_FAILURE ($4) makes the rule warn instead of abort.
	sed -i 's/\(call symlink_system_library,LIBM,$(LIBMNAME)\))/\1,,ALLOW_FAILURE)/' base/Makefile || echo "Warning: base/Makefile LIBM ALLOW_FAILURE sed failed" >&2

	# Nota: ldconfig se configura en el CI runner HOST (fuera de Docker) en el
	# workflow .github/workflows/build-julia.yml → paso "Configure linker cache".
	# No podemos usar sudo AQUÍ porque build-package.sh lo sobreescribe con una
	# función que llama exit 1 (ver build-package.sh líneas 506-510).

	# Make.host.user: compilador nativo del host para herramientas como flisp
	# cuando USE_CROSS_FLISP=1 está activado. Esto permite compilar flisp
	# para x86_64 (host) y ejecutarlo sin QEMU.
	cat > Make.host.user <<-EOF
	CC = gcc
	CXX = g++
	EOF

	# Fix H0: Excluir #error de libunwind en Android/bionic.
	# LLVM libunwind sí soporta UNW_REG_SP, a diferencia de Savannah libunwind.
	# Reemplaza patch 0010.
	if [ -f src/task.c ]; then
		sed -i 's/#if defined __linux__/#if defined __linux__ \&\& !defined(__ANDROID__)/' src/task.c 2>/dev/null || true
	fi

	# Fix H00: Excluir sys/sysinfo.h y sysinfo() en Android/bionic.
	# Estas funciones de glibc no existen en bionic. Reemplaza patch 0009.
	if [ -f src/codegen.cpp ]; then
		sed -i \
			-e 's/#ifdef _OS_LINUX_/#if defined(_OS_LINUX_) \&\& !defined(__BIONIC__)/' \
			-e 's/^#if defined(_OS_LINUX_)$/#if defined(_OS_LINUX_) \&\& !defined(__BIONIC__)/' \
			src/codegen.cpp 2>/dev/null || true
	fi

	# Fix H01: Excluir __register_frame/__deregister_frame en Android/bionic.
	# Estas funciones de libgcc_s no existen en bionic. Reemplaza patch 0008.
	if [ -f src/debuginfo.cpp ]; then
		sed -i 's/#if (defined(_OS_LINUX_) || defined(_OS_FREEBSD_) || (defined(_OS_DARWIN_) \&\& defined(LLVM_SHLIB)))/#if (defined(_OS_LINUX_) \&\& !defined(__BIONIC__)) || defined(_OS_FREEBSD_) || (defined(_OS_DARWIN_) \&\& defined(LLVM_SHLIB)))/' src/debuginfo.cpp 2>/dev/null || true
	fi

	# Fix H02: Usar pthread_get_stackaddr_np en Android/bionic.
	# pthread_getattr_np no existe en bionic. Reemplaza patch 0007 (condición).
	if [ -f src/init.c ]; then
		sed -i 's/#  if defined(_OS_LINUX_) || defined(_OS_FREEBSD_)/#  if (defined(_OS_LINUX_) \&\& !defined(__BIONIC__)) || defined(_OS_FREEBSD_)/' src/init.c 2>/dev/null || true
	fi

	# Fix H03: Stub libstdcxxprobe() en Android/bionic.
	# Android usa libc++, no libstdc++.so.6. Reemplaza patch 0005.
	if [ -f cli/loader_lib.c ]; then
		sed -i '/^static const char \*libstdcxxprobe(void)$/,/^}$/{
		/^{$/a\
		#if defined(__ANDROID__)\
		    (void)0;\
		    return NULL;\
		#else
		/^}$/i\
		#endif
		}' cli/loader_lib.c 2>/dev/null || true
	fi

	# Fix H04: Definir _OS_ANDROID_ cuando se detecta __ANDROID__.
	if [ -f src/support/platform.h ]; then
		sed -i '/^#define _OS_LINUX_$/a\
#  if defined(__ANDROID__)\
#    define _OS_ANDROID_\
#  endif' src/support/platform.h 2>/dev/null || true
	fi

	# Fix H05: Incluir <link.h> también en bionic (patch 0004).
	if [ -f src/dlload.c ]; then
		sed -i 's/^#ifdef __GLIBC__/#if defined(__GLIBC__) || defined(__BIONIC__)/' src/dlload.c 2>/dev/null || true
	fi

	# Fix H06: Incluir <endian.h> en bionic y excluir uint_t duplicada (patch 0002).
	if [ -f src/support/dtypes.h ]; then
		sed -i \
			-e 's/^#ifdef _OS_LINUX_$/#if defined(_OS_LINUX_) \&\& !defined(__BIONIC__)/' \
			-e '/^#endif$/{
			N
			/^#endif\n#if defined(__APPLE__)/{
			i\
#if defined(__BIONIC__)\
#include <endian.h>\
/* bionic already defines LITTLE_ENDIAN, BIG_ENDIAN, BYTE_ORDER */\
#endif
			}
		}' src/support/dtypes.h 2>/dev/null || true
		sed -i 's/^typedef uint64_t uint_t;  \/\/ preferred int type on platform$/#ifndef __BIONIC__\ntypedef uint64_t uint_t;\n#endif/' src/support/dtypes.h 2>/dev/null || true
		sed -i '/^#define NBITS 32$/,/^typedef int32_t int_t;$/{
			/^typedef uint32_t uint_t;$/i\
#ifndef __BIONIC__
			/^typedef uint32_t uint_t;$/a\
#endif
		}' src/support/dtypes.h 2>/dev/null || true
	fi

	# Fix H07: Usar dl_iterate_phdr como fallback en Android/bionic (patch 0003).
	if [ -f src/sys.c ]; then
		sed -i 's/^#ifdef _OS_OPENBSD_$/#if defined(_OS_OPENBSD_) || defined(_OS_ANDROID_)/' src/sys.c 2>/dev/null || true
	fi

	# Fix H: TCP_QUICKACK guard for Android/bionic.
	# On Android, _OS_LINUX_ is defined but TCP_QUICKACK may not be
	# available in kernel headers. This replaces the original patch
	# 0012-jl-uv-tcp-quickack.patch with a more robust sed approach.
	sed -i 's/#ifdef _OS_LINUX_/#if defined(_OS_LINUX_) \&\& defined(TCP_QUICKACK)/g' src/jl_uv.c 2>/dev/null || true

	# Fix I: Excluir mallinfo/malloc_stats en Android/bionic.
	# Estas funciones de glibc no existen en bionic. Reemplaza patch 0011.
	sed -i 's/#ifdef _OS_LINUX_/#if defined(_OS_LINUX_) \&\& !defined(__BIONIC__)/g' src/gc-debug.c 2>/dev/null || true

	cat > Make.user <<-EOF
	XC_HOST = aarch64-linux-android
	# CC/CXX los genera Make.inc automáticamente con el prefijo CROSS_COMPILE
	AR = llvm-ar
	RANLIB = llvm-ranlib

	USE_SYSTEM_LLVM=1
	USE_SYSTEM_PCRE=1
	USE_SYSTEM_LIBM=1
	USE_SYSTEM_OPENBLAS=1
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
	USE_SYSTEM_LIBWHICH=1
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

	USE_BINARYBUILDER=0
	DISABLE_LIBUNWIND=1
	JULIA_THREADS=4
	prefix=$TERMUX_PREFIX
	LOCALBASE=$TERMUX_PREFIX

	USE_CROSS_FLISP=1

	override CXXFLAGS += -Wno-deprecated-declarations
	override CFLAGS += -Wno-deprecated-declarations
	EOF
}

termux_step_make() {
	cd "$TERMUX_PKG_SRCDIR"

	# Now run the main cross-compilation build using Julia's native
	# cross-compilation support (XC_HOST + USE_CROSS_FLISP=1).
	# HOSTCC=gcc compila herramientas como flisp para x86_64 nativamente,
	# eliminando la necesidad de QEMU para ejecutar binarios ARM.
	# Nota: CC/CXX se omiten explícitamente porque con XC_HOST definido,
	# Make.inc genera CC automáticamente como aarch64-linux-android-clang.
	# Pasarlos explícitamente causa doble prefijo.
	make -j${TERMUX_PKG_MAKE_PROCESSES} \
		HOSTCC="gcc" \
		HOSTCXX="g++" \
		HOST_LDFLAGS="" \
		PREFIX="$TERMUX_PREFIX" \
		LOCALBASE="$TERMUX_PREFIX" \
		FC_VERSION=dummy \
		release
}

termux_step_make_install() {
	cd "$TERMUX_PKG_SRCDIR"
	make install \
		PREFIX="$TERMUX_PREFIX" \
		LOCALBASE="$TERMUX_PREFIX"
}
