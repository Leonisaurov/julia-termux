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
# versioned soname, while Julia's source asks the loader for the glibc-style
# versioned names by literal - see termux_link_soname_aliases below, which
# derives the aliases from the source rather than from this comment.
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

# Which versioned names the loader will be asked for is a property of Julia's
# source, so soname-aliases.sh reads it from the source: this recipe cannot drift
# from what the sysimage demands, and no hand-kept list decides what must exist.
# The helper reports one verdict per demanded name on stdout; only the "alias"
# ones need a link here, because "native" already answers itself and "built" gets
# its versioned file from deps/ or from julia's own make.
#
# Which directory gets the links is a fact about the loader, not a preference:
# the dlopen of a bare name happens in src/dlload.c:376, inside
# libjulia-internal.so, whose RUNPATH is exactly -rpath,'$ORIGIN' (RPATH_LIB,
# Make.inc:1475+1472) and which src/Makefile:417 links into $(build_shlibdir).
# So the search set is that one directory, and an alias anywhere else is a file
# nothing reads: run 37862103015 created all eight aliases in usr/lib/julia and
# died anyway at sysimage.mk:129 with 'dlopen failed: library "libgmp.so.10" not
# found'.  scripts/runtime-library-dir.sh asks make for that directory
# (build_shlibdir) and for the object's post-install home (private_libdir, whose
# RUNPATH make install rewrites at Makefile:481), and the gate compares both with
# the call sites below.
termux_link_soname_aliases() {
	local _dir="${1:?usage: termux_link_soname_aliases <directory>}"
	local _verdict _want _target _out

	# The aliases have to exist before make, and the directory is created *by*
	# make, so at this point it may not exist yet: run 37859841658 died 4 minutes
	# in with "ln: failed to create symbolic link
	# 'usr/lib/julia/libcurl.so.4': No such file or directory".
	mkdir -p "${_dir}"
	if ! _out=$(bash "${TERMUX_PKG_BUILDER_DIR}/soname-aliases.sh" \
		"${TERMUX_PKG_SRCDIR}" "${TERMUX_PREFIX}/lib"); then
		termux_error_exit "soname-aliases.sh could not derive the versioned names"
	fi
	while read -r _verdict _want _target; do
		[ "${_verdict}" = alias ] || continue
		ln -sfn "${TERMUX_PREFIX}/lib/${_target}" "${_dir}/${_want}"
	done <<<"${_out}"
}

termux_step_make() {
	cd "${TERMUX_PKG_SRCDIR}"

	# Julia dlopens glibc-style versioned names that it spells as literals
	# (base/gmp.jl:32 "libgmp.so.10", base/mpfr.jl:40 "libmpfr.so.6") and
	# Android's dlopen matches the *file name*, so the request is not satisfied by
	# $PREFIX/lib/libgmp.so however correct that library is.  Upstream does not
	# notice because it builds its own GMP, whose SONAME does carry the version.
	# These names are therefore asked *while the sysimage is bootstrapping*, which
	# is inside make: run 37851961397 died at sysimage.mk:129 with
	#	LoadError("gmp.jl", 32, "could not load library \"libgmp.so.10\"")
	# 49 minutes in, once the triplet was fixed - a link created after install
	# cannot help a build that never reaches install.  The run that added the
	# links (37862103015) failed with the same message, because they went to
	# usr/lib/julia: the object that asks is in usr/lib, so usr/lib - $(build_shlibdir
	# by make's own answer) - is the only directory the loader looks in here.
	termux_link_soname_aliases usr/lib

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

	# The installed tree is what julia runs from, so it needs the same versioned
	# names the build tree got before make.  make install does not carry them: it
	# copies $(JULIA_LIBS) by content, which would duplicate GMP into the package
	# instead of pointing at it - so the derivation is re-run here, against the
	# same source, and one list cannot disagree with the other.  The directory is
	# deliberately not the one the build tree used: libjulia-internal moves from
	# $(build_libdir) to $(private_libdir) on install and Makefile:481 gives it
	# RUNPATH '$$ORIGIN:$$ORIGIN/../', so this is where the object that answers the
	# dlopen lives from now on.
	termux_link_soname_aliases "${TERMUX_PREFIX}/lib/julia"

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
	unset _f _readelf
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
