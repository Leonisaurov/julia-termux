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
	sed -i '/CPPFLAGS.*MDB_USE_ROBUST/d' deps/lmdb.mk

	# Fix libuv cross-compilation: the CI runner is x86_64, but the target is
	# aarch64-linux-android. Without --host, configure tries to run test programs
	# compiled for the target, which fail on the build machine.
	sed -i 's|--with-pic.*|--with-pic --host=aarch64-linux-android --build=x86_64-pc-linux-gnu $(CONFIGURE_COMMON) $(UV_FLAGS)|' deps/libuv.mk

	# Fix libuv pthread_setcancelstate for Android/bionic: Julia removed the
	# broken patch from libuv.mk entirely.  Insert a sed to add the missing
	# !defined(__ANDROID__) guard before the configure step.
	sed -i '/build-configured:.*source-extracted/a\\tcd \$(SRCCACHE)/\$(LIBUV_SRC_DIR) \&\& sed -i '"'"'s|#ifdef __linux__|#if defined(__linux__) \\&\\& !defined(__ANDROID__)|g'"'"' src/unix/process.c' deps/libuv.mk

	# Remove -lpthread from linker flags (bionic has pthreads in libc)
	# These use targeted patterns to avoid missing edge cases.
	sed -i '/^OSLIBS/s/ -lpthread/ /g' Make.inc
	sed -i '/^LOADER_LDFLAGS/s/ -lpthread/ /g' cli/Makefile
	sed -i '/^LIBS/s/ -lpthread/ /g' src/flisp/Makefile
	sed -i '/-lpthread/s/ -lpthread/ /g' src/support/Makefile
	# Also clean src/Makefile (used for julia-codegen link step)
	sed -i '/-lpthread/s/ -lpthread/ /g' src/Makefile

	# The host flisp build path (USE_CROSS_FLISP=1 -> src/flisp/host/) has
	# BUILDDIR/pattern bugs in GNU make.  We build host flisp manually below
	# in termux_step_make() with an absolute BUILDDIR and explicit CC=gcc.

	# Fix julia.expmap: merge the LLVM symbol into the Julia version block
	# and delete the separate LLVM version block entirely.  lld in Android's
	# NDK rejects files with multiple named version blocks, and during cross-
	# compilation LLVM_SHLIB_SYMBOL_VERSION is often empty (readelf fails),
	# producing an anonymous block that lld also rejects.
	# NOTE: the Makefile's sed (src/Makefile:560) then tries to substitute
	# @LLVM_SHLIB_SYMBOL_VERSION@ — with the block deleted there's no occurrence
	# left, so the empty variable is harmless.
	sed -i '/MMTK_\*;$/a\    _ZN4llvm3Any6TypeId*;' src/julia.expmap.in
	sed -i '/^@LLVM_SHLIB_SYMBOL_VERSION@ {/,/^};/d' src/julia.expmap.in

	# Fix gfortran check: Make.inc errors when no gfortran is found, even when
	# USE_SYSTEM_OPENBLAS=1 and USE_SYSTEM_LIBSUITESPARSE=1 are set. We'll
	# pass FC_VERSION=dummy on the make command line to bypass the check.
	cat > Make.user <<-EOF
	# CC/CXX are set here and also passed on the command line for the main
	# build.  We must NOT use override so that sub-make invocations for host
	# tools can set CC=gcc on the command line.
	CC=$CC
	CXX=$CXX
	AR=$AR
	RANLIB=$RANLIB

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
	# Cross-compilation: build flisp for the host (x86_64) so it can run on
	# the build machine to generate julia_flisp.boot.
	USE_CROSS_FLISP=1
	prefix=$TERMUX_PREFIX
	LOCALBASE=$TERMUX_PREFIX

	override CXXFLAGS += -Wno-deprecated-declarations
	override CFLAGS += -Wno-deprecated-declarations
	EOF
}

termux_step_make() {
	cd "$TERMUX_PKG_SRCDIR"

	# Build host flisp (needed to generate julia_flisp.boot on x86_64 host).
	# The USE_CROSS_FLISP path in the Makefile has BUILDDIR/pattern bugs with
	# relative paths, so we build manual with absolute BUILDDIR and CC=gcc.
	DUM_UV=$(pwd)/.dummy_uv_inc
	mkdir -p "$DUM_UV"
	echo > "$DUM_UV"/uv.h
	make -C src/support \
		BUILDDIR="$(pwd)/src/support/host" \
		CC="gcc" CXX="g++" AR="ar" RANLIB="ranlib" \
		LIBUV_INC="$DUM_UV" FC_VERSION=dummy libsupport.a
	make -C src/flisp \
		BUILDDIR="$(pwd)/src/flisp/host" \
		CC="gcc" CXX="g++" AR="ar" RANLIB="ranlib" \
		BUILDING_HOST_TOOLS=1 \
		LIBUV_INC="$DUM_UV" FC_VERSION=dummy release

	# Now run the main cross-compilation build (USE_CROSS_FLISP picks up the
	# host flisp we just built at src/flisp/host/flisp).
	make -j${TERMUX_PKG_MAKE_PROCESSES} \
		CC="$CC" CXX="$CXX" \
		HOSTCC="gcc" \
		HOSTCXX="g++" \
		HOST_LDFLAGS="" \
		PREFIX="$TERMUX_PREFIX" \
		LOCALBASE="$TERMUX_PREFIX" \
		FC_VERSION=dummy \
		USE_CROSS_FLISP=1 \
		release
}

termux_step_make_install() {
	cd "$TERMUX_PKG_SRCDIR"
	make install \
		PREFIX="$TERMUX_PREFIX" \
		LOCALBASE="$TERMUX_PREFIX"
}
