# This file is a part of Julia. License is MIT: https://julialang.org/license

## dummy stub for https://github.com/JuliaBinaryWrappers/OpenBLAS_jll.jl
baremodule OpenBLAS_jll
using Base, Libdl, Base.BinaryPlatforms

# We are explicitly NOT loading this at runtime, as it contains `libgomp`
# which conflicts with `libiomp5`, breaking things like MKL.  In the future,
# we hope to transition to a JLL interface that provides a more granular
# interface than eagerly dlopen'ing all libraries provided in the JLL
# which will eliminate issues like this, where we avoid loading a JLL
# because we don't want to load a library that we don't even use yet.
# using CompilerSupportLibraries_jll
# Because of this however, we have to manually load the libraries we
# _do_ care about, namely libgfortran

const PATH_list = String[]
const LIBPATH_list = String[]

export libopenblas

# These get calculated in __init__()
const PATH = Ref("")
const LIBPATH = Ref("")
artifact_dir::String = ""
libopenblas_handle::Ptr{Cvoid} = C_NULL
libopenblas_path::String = ""

if Base.USE_BLAS64
    const libsuffix = "64_"
else
    const libsuffix = ""
end

# Termux ships OpenBLAS as a plain system library in $PREFIX/lib; there is no
# artifact directory to discover.  `Sys.BINDIR` is $PREFIX/bin both when the
# system image is generated and on the device, so this path is stable.
const termux_libdir = joinpath(dirname(Sys.BINDIR), "lib")
const termux_openblas_path = joinpath(termux_libdir, "libopenblas$(libsuffix).so")

if Sys.iswindows()
    const libopenblas = "libopenblas$(libsuffix).dll"
    const _libgfortran = string("libgfortran-", something(libgfortran_version(HostPlatform()), v"0.0.0").major, ".dll")
elseif Sys.isapple()
    const libopenblas = "@rpath/libopenblas$(libsuffix).dylib"
    const _libgfortran = string("@rpath/", "libgfortran.", something(libgfortran_version(HostPlatform()), v"0.0.0").major, ".dylib")
else
    const libopenblas = "libopenblas$(libsuffix).so"
    const _libgfortran = string("libgfortran.so.", something(libgfortran_version(HostPlatform()), v"0.0.0").major)
end

function __init__()
    # make sure OpenBLAS does not set CPU affinity (#1070, #9639)
    if !haskey(ENV, "OPENBLAS_MAIN_FREE")
        ENV["OPENBLAS_MAIN_FREE"] = "1"
    end

    # Ensure that OpenBLAS does not grab a huge amount of memory at first,
    # since it instantly allocates scratch buffer space for the number of
    # threads it thinks it needs to use.
    # X-ref: https://github.com/xianyi/OpenBLAS/blob/c43ec53bdd00d9423fc609d7b7ecb35e7bf41b85/README.md#setting-the-number-of-threads-using-environment-variables
    # X-ref: https://github.com/JuliaLang/julia/issues/45434
    if !haskey(ENV, "OPENBLAS_NUM_THREADS") &&
       !haskey(ENV, "GOTO_NUM_THREADS") &&
       !haskey(ENV, "OMP_NUM_THREADS")
        # We set this to `1` here, and then LinearAlgebra will update
        # to the true value in its `__init__()` function.
        ENV["OPENBLAS_DEFAULT_NUM_THREADS"] = "1"
    end

    # NOTE: dlopen(_libgfortran) is not performed.  Termux's OpenBLAS is linked
    # against the Fortran runtime statically, so libgfortran.so does not exist.

    # `dlpath()` is deliberately NOT used here: it routes through
    # `jl_pathname_for_handle`, whose glibc implementation relies on
    # `dlinfo(RTLD_DI_LINKMAP)`, which Bionic does not provide.  A NULL return
    # used to make `unsafe_string` throw "cannot convert NULL to string"; the
    # error was caught, `libopenblas_path` stayed "" and that empty string got
    # baked into sys.so, so libblastrampoline was told to forward to "" and
    # every Julia process died at BLAS init.  The path is known statically, so
    # this stub must never depend on the loader to report it.
    global libopenblas_handle = dlopen(termux_openblas_path)
    if libopenblas_handle == C_NULL
        error("OpenBLAS_jll: could not dlopen ", termux_openblas_path,
              " — check that the libopenblas package is installed and that ",
              termux_libdir, " contains libopenblas", libsuffix, ".so")
    end
    global libopenblas_path = termux_openblas_path
    global artifact_dir = dirname(Sys.BINDIR)
    LIBPATH[] = termux_libdir
    push!(LIBPATH_list, LIBPATH[])
end

# JLLWrappers API compatibility shims.  Note that not all of these will really make sense.
# For instance, `find_artifact_dir()` won't actually be the artifact directory, because
# there isn't one.  It instead returns the overall Julia prefix.
is_available() = true
find_artifact_dir() = artifact_dir
dev_jll() = error("stdlib JLLs cannot be dev'ed")
best_wrapper = nothing
get_libopenblas_path() = libopenblas_path

end  # module OpenBLAS_jll
