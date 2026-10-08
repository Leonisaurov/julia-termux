#!/usr/bin/env bash
TERMUX_PKG_HOMEPAGE=https://julialang.org/
TERMUX_PKG_DESCRIPTION="High-performance dynamic programming language for scientific computing"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION=1.12.6
TERMUX_PKG_SRCURL=https://github.com/JuliaLang/julia/releases/download/v${TERMUX_PKG_VERSION}/julia-${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=5440ad37977af766a075e5cc9c430b66ba958ede69a70ccf308bb7d8e1d69478
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_HOSTBUILD=false

# Runtime: every library below is either DT_NEEDED by libjulia-* or dlopen'ed
# by a stdlib.  Termux's libgmp/libmpfr/libopenblas/libpcre2-8 ship without a
# versioned soname, so Julia's hardcoded "libgmp.so.10"-style names are
# satisfied by the symlinks created in termux_step_post_make_install.
TERMUX_PKG_DEPENDS="7zip, curl, libc++, libgit2, libgmp, libmpfr, libnghttp2, libopenblas, libssh2, openssl, pcre2, suitesparse, zlib"
# The build tools are not implicit here: the deps/ build downloads and patches
# tarballs (curl, xz for .tar.xz), Make.inc calls contrib/relative_path.py to
# compute the loader's DEP_LIBS rpath strings (python), and termux_step_patch_package
# plus deps/*.mk both shell out to patch.  dsymutil/ar/ranlib/objcopy/readelf come
# from llvm (Termux does not take them from binutils), and git is probed by the CI
# gate as well as used by contrib/*.sh.  ca-certificates is what makes the deps/
# downloads over TLS work at all.  blas-openblas is not a typo for libopenblas:
# with USE_SYSTEM_BLAS=1 Make.inc names the library after the alias
# (LIBBLASNAME=libblas, LIBLAPACKNAME=liblapack), and base/Makefile links
# -lblas/-llapack against it and asks the loader to resolve those very sonames, so
# the build needs the alias package.  A build dependency only: the symlink
# julia-base writes into usr/lib/julia is absolute to $PREFIX/lib/libopenblas.so,
# which the runtime list above already covers.
TERMUX_PKG_BUILD_DEPENDS="binutils, blas-openblas, ca-certificates, clang, cmake, diffutils, file, findutils, gawk, git, lld, llvm, m4, make, patch, patchelf, perl, pkg-config, python, sed, tar, which, xz-utils"

# The *.patch files sitting next to this recipe are applied by
# termux_step_patch_package() before configure.  patches/deps/*.patch are
# content patches for Julia's own bundled deps; deps/*.mk reads them from
# $(SRCDIR)/patches/, because deps/Makefile redefines SRCDIR to deps/ itself.
termux_step_pre_configure() {
	mkdir -p "${TERMUX_PKG_SRCDIR}/deps/patches"
	# shellcheck disable=SC2086
	install -m 644 "${TERMUX_PKG_BUILDER_DIR}"/patches/deps/*.patch \
		"${TERMUX_PKG_SRCDIR}/deps/patches/" || termux_error_exit "missing deps patches"
}

termux_step_configure() {
	cd "${TERMUX_PKG_SRCDIR}"

	# Bionic has no libgcc_s; clang's compiler-rt builtins provide the same
	# symbols and must be linked whole-archive into the runtime and loader.
	local _builtins
	_builtins=$(ls "${TERMUX_PREFIX}"/lib/clang/*/lib/linux/"libclang_rt.builtins-${TERMUX_ARCH}-android.a" 2>/dev/null | head -n 1)
	if [ -z "${_builtins}" ]; then
		termux_error_exit "libclang_rt.builtins-${TERMUX_ARCH}-android.a not found under ${TERMUX_PREFIX}/lib/clang"
	fi

	# Make.inc hardcodes FC := gfortran (Make.inc:541) and then refuses to
	# configure at all when `$(FC) -dM -E` reports no __GNUC__ (Make.inc:1431-1434)
	# - run 37795904301 died there with
	# "Attempting to build OpenBLAS or SuiteSparse without a functioning fortran
	# compiler!".  Nothing in this configuration compiles a Fortran source: BLAS
	# and LAPACK come from Termux's OpenBLAS, built with -DC_LAPACK=ON (pure C),
	# and SuiteSparse from Termux's package, so the guard is the only consumer of
	# $(FC) left - deps/csl.mk, the other parse-time user, is inert because
	# USE_SYSTEM_CSL := 1.  Termux's Fortran compiler is flang, but it drags a
	# second LLVM toolchain (mlir, libllvm, libandroid-complex-math-static) into
	# the closure to satisfy a probe, so point FC at the clang that
	# BUILD_DEPENDS already guarantees.  The override has to live in Make.user:
	# Make.inc includes it a second time at Make.inc:754, after line 541 ran.
	_julia_fc="${TERMUX_PREFIX}/bin/clang"
	if [ -z "$("${_julia_fc}" -dM -E - < /dev/null 2>/dev/null | grep __GNUC__ | cut -d' ' -f3)" ]; then
		termux_error_exit "${_julia_fc} does not answer the probe Julia's Make.inc makes of FC (-dM -E, __GNUC__)"
	fi

	# Single source of truth for the build configuration.  Do NOT add CC/CXX:
	# Make.inc detects clang from `cc --version` and picks USECLANG itself, and
	# Termux's clang already targets the device's Android API level.
	cat > Make.user <<-EOF
prefix=${TERMUX_PREFIX}
LOCALBASE=${TERMUX_PREFIX}
USE_BINARYBUILDER := 0
JULIA_CPU_TARGET := generic

# Julia 1.12 pins LLVM 18.1.7 with Julia's own patches and a JL_LLVM_18.1
# symbol version; Termux only offers LLVM 21, so build it from deps/llvm.mk.
USE_SYSTEM_LLVM := 0
USE_SYSTEM_LLD := 1
USE_SYSTEM_PATCHELF := 1
USE_SYSTEM_P7ZIP := 1

# Provided by Termux packages (see TERMUX_PKG_DEPENDS).
USE_SYSTEM_ZLIB := 1
USE_SYSTEM_PCRE := 1
USE_SYSTEM_GMP := 1
USE_SYSTEM_MPFR := 1
USE_SYSTEM_OPENSSL := 1
USE_SYSTEM_LIBSSH2 := 1
USE_SYSTEM_NGHTTP2 := 1
USE_SYSTEM_CURL := 1
USE_SYSTEM_LIBGIT2 := 1
USE_SYSTEM_LIBSUITESPARSE := 1
USE_SYSTEM_BLAS := 1
USE_SYSTEM_LAPACK := 1
USE_SYSTEM_LIBM := 1
# No libgcc_s/libstdc++/libgfortran to bundle on Bionic.
USE_SYSTEM_CSL := 1

# Bundled on purpose: Julia pins its own libuv fork (patched here for bionic's
# missing pthread_cancel), a utf8proc fork, dSFMT and libwhich.  Termux's
# versions of these are different releases and Julia's code assumes its own.
USE_SYSTEM_LIBUV := 0
USE_SYSTEM_UTF8PROC := 0
USE_SYSTEM_DSFMT := 0
USE_SYSTEM_LIBWHICH := 0

# Fortran: see termux_step_pre_configure.  Make.inc:541 sets FC := gfortran
# before the second include of Make.user, this line is what turns that guard off,
# and nothing below deps/ ever runs the compiler.
FC := ${_julia_fc}

# Termux's libopenblas exports ILP32 symbols (dgemm_), not the 64_ suffixed ones.
USE_BLAS64 := 0
# Build Julia's own libblastrampoline; it forwards to $PREFIX/lib/libopenblas.so.
USE_SYSTEM_LIBBLASTRAMPOLINE := 0

# aarch64 uses Julia's own assembly task switching (JL_HAVE_ASM), so libunwind
# is neither needed nor portable here.
DISABLE_LIBUNWIND := 1
# Android has no perf(1) JIT sampling interface for LLVM to hook into.
USE_PERF_JITEVENTS := 0

CLANG_RT_BUILTINS := ${_builtins}

# Precompiled stdlibs are what makes Pkg/LinearAlgebra behave like the real
# package; the CI runner has the memory for it.
JULIA_PRECOMPILE := 1
EOF
	echo "[build.sh] generated Make.user with CLANG_RT_BUILTINS=${_builtins}"
}

termux_step_make() {
	cd "${TERMUX_PKG_SRCDIR}"
	# Precompilation spawns one Julia process per task; keep it at the same
	# width as the make parallelism so the runner's memory is not oversubscribed.
	export JULIA_NUM_PRECOMPILE_TASKS="${TERMUX_PKG_MAKE_PROCESSES}"
	make -j"${TERMUX_PKG_MAKE_PROCESSES}"
}

termux_step_make_install() {
	cd "${TERMUX_PKG_SRCDIR}"
	# The install target fixes rpaths and rewrites the loader's DEP_LIBS
	# string; it is not parallel-safe.
	make -j1 install prefix="${TERMUX_PREFIX}" DESTDIR=
}

termux_step_post_make_install() {
	cd "${TERMUX_PREFIX}/lib/julia"

	# Base hardcodes glibc-style versioned names (base/gmp.jl, base/mpfr.jl).
	local _pair _want _target
	for _pair in "libgmp.so.10:libgmp.so" "libmpfr.so.6:libmpfr.so" "libpcre2-8.so.0:libpcre2-8.so"; do
		_want="${_pair%%:*}"
		_target="${_pair##*:}"
		if [ -e "${TERMUX_PREFIX}/lib/${_target}" ] && [ ! -e "${_want}" ]; then
			ln -sf "${TERMUX_PREFIX}/lib/${_target}" "${_want}"
		fi
	done

	# Fail here rather than in the artifact smoke test: a sysimage-less or
	# codegen-less julia installs cleanly and then does not run.
	for _f in "${TERMUX_PREFIX}/bin/julia" \
		"${TERMUX_PREFIX}/lib/julia/sys.so" \
		"${TERMUX_PREFIX}/lib/julia/libblastrampoline.so.5"; do
		[ -e "${_f}" ] || termux_error_exit "install produced no ${_f}"
	done

	# The bundled LLVM must carry Julia's own symbol version, otherwise
	# libjulia-codegen's versioned references do not resolve at load time.
	local _readelf
	_readelf=$(command -v readelf || command -v llvm-readelf)
	if [ -n "${_readelf}" ]; then
		"${_readelf}" -V "${TERMUX_PREFIX}/lib/julia/libLLVM-18jl.so" 2>/dev/null | \
			grep -q 'JL_LLVM_18\.1' || \
			termux_error_exit "libLLVM-18jl.so lacks the JL_LLVM_18.1 symbol version"
	fi
	unset _pair _want _target _f _readelf
}

# termux-packages packages an on-device build by copying everything *newer than the
# build timestamp* out of the live $PREFIX (scripts/build/
# termux_step_copy_into_massagedir.sh).  Anything an unrelated process touched while
# Julia compiled therefore arrives in the payload: a libandroid-glob .deb built on a
# phone shipped var/log/ntfy/ntfy.log and opt/flutter/** that way.  Julia's own
# footprint is small and known, so drop the rest before massaging - and print each
# pruned path, because a wrong guess must show up in the log instead of as a missing
# file in the package.
termux_step_pre_massage() {
	local _junk
	for _junk in var opt tmp run home srv; do
		[ -e "${_junk}" ] || continue
		echo "pre-massage: pruning foreign ${_junk}/"
		rm -rf "${_junk}"
	done
	unset _junk

	# Keeps only the listed name patterns at depth 1 of the given directory.
	_prune_foreign() {
		local _dir="$1"; shift
		[ -d "${_dir}" ] || return 0
		local _expr=("${_dir}" -mindepth 1 -maxdepth 1)
		local _keep
		for _keep in "$@"; do
			_expr+=( ! -name "${_keep}" )
		done
		find "${_expr[@]}" -print -exec rm -rf -- {} +
		unset _expr _keep
	}

	# Footprint taken from `dpkg -L julia` on the validated 1.12.6 install, which is
	# exactly: bin/julia, etc/julia/, include/julia/, lib/julia/ plus lib/libjulia*
	# and lib/libopenlibm*, libexec/julia/{7z,dsymutil,lld,...}, share/{julia,doc/
	# julia,man/man1/julia.1,metainfo/julia.appdata.xml,applications/julia.desktop}.
	# Note the metainfo file is julia.appdata.xml, not the org.julialang.* name other
	# desktop apps use - keeping the wrong pattern would delete the package's own file.
	_prune_foreign bin 'julia*'
	_prune_foreign etc julia
	_prune_foreign include julia
	_prune_foreign lib julia 'libjulia*' 'libopenlibm*'
	_prune_foreign libexec julia
	_prune_foreign share julia doc man metainfo applications
	_prune_foreign share/doc julia
	_prune_foreign share/man man1
	_prune_foreign share/man/man1 'julia*'
	_prune_foreign share/metainfo 'julia*'
	_prune_foreign share/applications 'julia*'
}
