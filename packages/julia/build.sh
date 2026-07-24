TERMUX_PKG_HOMEPAGE=https://julialang.org
TERMUX_PKG_DESCRIPTION="Julia programming language - Termux/Android build"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=1.14.0
TERMUX_PKG_SRCURL=https://github.com/JuliaLang/julia/archive/refs/heads/master.tar.gz
TERMUX_PKG_GIT_BRANCH=master
TERMUX_PKG_BUILD_IN_SRC=true
# libllvm declarada abajo como TERMUX_PKG_BUILD_DEPENDS para que buildorder.py
# la encuentre y -I la descargue automáticamente desde el repositorio APT.
# Dependencias externas (openblas, suitesparse, etc.) se instalan dentro de
# termux_step_pre_configure() desde el mismo repositorio APT.
TERMUX_PKG_NO_STRIP=false
# Julia handles cross-compilation natively in its Makefile (no hostbuild target)
TERMUX_PKG_HOSTBUILD=false

# libllvm SÍ existe en packages/libllvm/, buildorder.py la encuentra y -I la descarga
TERMUX_PKG_BUILD_DEPENDS="libllvm"

termux_step_pre_configure() {
	cd "$TERMUX_PKG_SRCDIR"

	# ============================================================
	# INSTALAR DEPENDENCIAS EXTERNAS DESDE REPO APT
	# Estas dependencias no tienen directorio en packages/, pero se
	# descargan directamente del repositorio Termux como paquetes .deb
	# Esto se integra con -I del build system
	# ============================================================
	if [[ "$TERMUX_INSTALL_DEPS" == "true" ]]; then
		echo "=== Instalando dependencias externas desde repo APT ==="
		local external_deps=(
			libllvm-static
			libopenblas blas-openblas
			suitesparse
			arpack-ng
			libgmp libmpfr
			zlib openssl
			libssh2 libgit2
			curl libnghttp2
			pcre2 utf8proc
			libuv p7zip
			patchelf lld
		)
		local PACKAGES_URL="https://packages-cf.termux.dev/apt/termux-main/dists/stable/main/binary-aarch64/Packages"
		local REPO_BASE="https://packages-cf.termux.dev/apt/termux-main"

		curl -sL "$PACKAGES_URL" -o /tmp/Packages

		for pkg in "${external_deps[@]}"; do
			echo "  -> $pkg"
			local stanza
			stanza=$(awk -v pkg="$pkg" '/^Package: /{found=($2==pkg)} found{print} /^$/{if(found) exit}' /tmp/Packages)
			local filename
			filename=$(echo "$stanza" | grep "^Filename:" | awk '{print $2}' || true)
			local deb_sha256
			deb_sha256=$(echo "$stanza" | grep "^SHA256:" | awk '{print $2}' || true)
			[ -z "$filename" ] && { echo "     SKIP (not found in repo)"; continue; }
			local deb_name="${filename##*/}"
			echo "     Downloading $deb_name"
			curl -sL "${REPO_BASE}/${filename}" -o "/tmp/$deb_name"
			if [ -n "$deb_sha256" ]; then
				echo "     Verifying"
				echo "$deb_sha256  /tmp/$deb_name" | sha256sum -c - > /dev/null 2>&1 || {
					echo "     ERROR: SHA256 mismatch for $pkg"
					rm -f "/tmp/$deb_name"
					exit 1
				}
			fi
			echo "     Extracting to /"
			dpkg-deb -x "/tmp/$deb_name" / 2>/dev/null || true
			rm -f "/tmp/$deb_name"
		done
		echo "=== Dependencias externas instaladas ==="
	fi

	# ============================================================
	# PARCHES SED (sin cambios respecto al original)
	# ============================================================

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

	# Remove -lpthread from all Makefiles (bionic has pthread in libc)
	sed -i '/^OSLIBS/s/ -lpthread//' Make.inc
	sed -i '/^LIBS/s/ -lpthread//' cli/Makefile
	sed -i '/^LIBS/s/ -lpthread//' src/flisp/Makefile

	# The host flisp build path (USE_CROSS_FLISP=1 -> src/flisp/host/) has
	# BUILDDIR/pattern bugs in GNU make.  We build host flisp manually below
	# in termux_step_make() with an absolute BUILDDIR and explicit CC=gcc.

	# Fix julia.expmap: replace LLVM version token with Julia version token
	# so the generated file has a single version block (lld rejects multiple)
	sed -i 's/@LLVM_SHLIB_SYMBOL_VERSION@/@JULIA_SHLIB_SYMBOL_VERSION@/' src/julia.expmap.in

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
	sed -i '/^OSLIBS/s/ -lrt//' Make.inc

	# Fix B: Disable ifunc detection on Android (bionic doesn't support ifunc)
	sed -i '/IFUNC_DETECT_SRC/,/^endif/d' Make.inc

	# Fix C: Skip copying glibc-specific CRT objects on Android
	sed -i '/libc_nonshared.a/d' Makefile

	# Fix D: Remove -static-libstdc++ for Android (uses libc++)
	sed -i 's/-static-libstdc++//g' src/Makefile

	# Fix E: libc_nonshared.a in deps/csl.mk
	sed -i '/libc_nonshared.a/d' deps/csl.mk 2>/dev/null || true

	# Fix F: Remove -latomic from OSLIBS
	sed -i '/^OSLIBS/s/ -latomic//' Make.inc

	# Fix G: Make libm symlink ALLOW_FAILURE on Android/bionic.
	# On bionic, libm is part of libc — no standalone libm.so exists.
	# Julia's base/Makefile tries to locate it to create a runtime symlink.
	# Adding ALLOW_FAILURE ($4) makes the rule warn instead of abort.
	sed -i 's/\(call symlink_system_library,LIBM,$(LIBMNAME)\))/\1,,ALLOW_FAILURE)/' base/Makefile

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
	prefix=$TERMUX_PREFIX
	LOCALBASE=$TERMUX_PREFIX

	override CXXFLAGS += -Wno-deprecated-declarations
	override CFLAGS += -Wno-deprecated-declarations
	EOF
}

termux_step_make() {
	cd "$TERMUX_PKG_SRCDIR"

	# Now run the main cross-compilation build.  qemu-user-static (installed
	# in the CI workflow before the Docker container) lets the ARM flisp
	# binary run on the x86_64 build host.
	make -j${TERMUX_PKG_MAKE_PROCESSES} \
		CC="$CC" CXX="$CXX" \
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
