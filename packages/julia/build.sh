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

	# Fix libuv pthread_setcancelstate for Android/bionic: Julia's bundled
	# patch (libuv-android-pthread-cancel.patch) has line numbers that are out
	# of sync with the current libuv source, so it fails to apply under -f.
	# Replace it with a freshly generated version for libuv commit e6b9850f.
	cat > deps/patches/libuv-android-pthread-cancel.patch <<-PATCHEOF
	--- a/src/unix/process.c
	+++ b/src/unix/process.c
	@@ -283,7 +283,7 @@
	   return NULL;
	 }
	 
	-#ifdef __linux__
	+#if defined(__linux__) && !defined(__ANDROID__)
	 static int uv__execvpe(const char *file, char *const argv[], char *const envp[]) {
	   const char *p;
	   const char *z;
	@@ -382,13 +382,13 @@
	 
	 
	 static void uv__write_int(
	-#ifdef __linux__
	+#if defined(__linux__) && !defined(__ANDROID__)
	                             volatile int* fd,
	 #else
	                             int fd,
	 #endif
	                             int val) {
	-#ifdef __linux__
	+#if defined(__linux__) && !defined(__ANDROID__)
	   *fd = val;
	 #else
	   ssize_t n;
	@@ -405,7 +405,7 @@
	 
	 
	 static void uv__write_errno(
	-#ifdef __linux__
	+#if defined(__linux__) && !defined(__ANDROID__)
	                             volatile int* error_fd
	 #else
	                             int error_fd
	@@ -416,7 +416,7 @@
	 
	 /* May share the parent's memory space. Do not alter global state. */
	 static void uv__process_child_init(const uv_process_options_t* options,
	-#ifdef __linux__
	+#if defined(__linux__) && !defined(__ANDROID__)
	                                    volatile int* error_fd,
	 #else
	                                    int error_fd,
	@@ -568,7 +568,7 @@
	   if (sigprocmask(SIG_SETMASK, &signewset, NULL) != 0)
	     abort();
	 
	-#ifdef __linux__
	+#if defined(__linux__) && !defined(__ANDROID__)
	   if (options->env != NULL) {
	     uv__execvpe(options->file, options->args, options->env);
	   } else {
	@@ -977,7 +977,7 @@
	 #endif
	 
	 static int uv__spawn_and_init_child_fork(const uv_process_options_t* options,
	-#ifdef __linux__
	+#if defined(__linux__) && !defined(__ANDROID__)
	                                          volatile int* error_fd,
	 #else
	                                          int error_fd,
	@@ -1002,7 +1002,7 @@
	   if (pthread_sigmask(SIG_BLOCK, &signewset, &sigoldset) != 0)
	     abort();
	 
	-#ifdef __linux__
	+#if defined(__linux__) && !defined(__ANDROID__)
	   *pid = vfork();
	 #else
	   *pid = fork();
	@@ -1035,7 +1035,7 @@
	     pid_t* pid) {
	   int err;
	   int status;
	-#ifdef __linux__
	+#if defined(__linux__) && !defined(__ANDROID__)
	   volatile int exec_errorno;
	   int cancelstate;
	 #else
	@@ -1074,7 +1074,7 @@
	 
	 #endif
	 
	-#ifdef __linux__
	+#if defined(__linux__) && !defined(__ANDROID__)
	   /* Acquire write lock to prevent opening new fds in worker threads */
	   uv_rwlock_wrlock(&loop->cloexec_lock);
	   pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &cancelstate);
	PATCHEOF

	# Fix gfortran check: Make.inc errors when no gfortran is found, even when
	# USE_SYSTEM_OPENBLAS=1 and USE_SYSTEM_LIBSUITESPARSE=1 are set. We'll
	# pass FC_VERSION=dummy on the make command line to bypass the check.
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
		FC_VERSION=dummy \
		release
}

termux_step_make_install() {
	cd "$TERMUX_PKG_SRCDIR"
	make install \
		PREFIX="$TERMUX_PREFIX" \
		LOCALBASE="$TERMUX_PREFIX"
}
