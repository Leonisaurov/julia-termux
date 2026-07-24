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

	# Fix gfortran check: Make.inc errors when no gfortran is found even when
	# USE_SYSTEM_OPENBLAS=1 and USE_SYSTEM_LIBSUITESPARSE=1 are set (variables
	# may not be propagated at the time of the check). Remove the error lines.
	sed -i '/ifneq.*USE_SYSTEM_OPENBLAS.*USE_SYSTEM_LIBSUITESPARSE/,+2d' Make.inc

	cat > Make.user <<-EOF
	override CC=$CC
	override CXX=$CXX
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
	prefix=$TERMUX_PREFIX
	LOCALBASE=$TERMUX_PREFIX

	override CXXFLAGS += -Wno-deprecated-declarations
	override CFLAGS += -Wno-deprecated-declarations
	EOF
}

termux_step_make() {
	cd "$TERMUX_PKG_SRCDIR"
	make -j${TERMUX_PKG_MAKE_PROCESSES} \
		HOSTCC="gcc" \
		HOSTCXX="g++" \
		HOST_LDFLAGS="" \
		PREFIX="$TERMUX_PREFIX" \
		LOCALBASE="$TERMUX_PREFIX" \
		release
}

termux_step_make_install() {
	cd "$TERMUX_PKG_SRCDIR"
	make install \
		PREFIX="$TERMUX_PREFIX" \
		LOCALBASE="$TERMUX_PREFIX"
}
