# This file is a part of Julia. License is MIT: https://julialang.org/license

## dummy stub for https://github.com/JuliaBinaryWrappers/libblastrampoline_jll.jl

baremodule libblastrampoline_jll
using Base, Libdl

const PATH_list = String[]
const LIBPATH_list = String[]

export libblastrampoline

# These get calculated in __init__()
const PATH = Ref("")
const LIBPATH = Ref("")
artifact_dir::String = ""
libblastrampoline_handle::Ptr{Cvoid} = C_NULL
libblastrampoline_path::String = ""

# NOTE: keep in sync with `Base.libblas_name` and `Base.liblapack_name`.
const libblastrampoline = if Sys.iswindows()
    "libblastrampoline-5.dll"
elseif Sys.isapple()
    "@rpath/libblastrampoline.5.dylib"
else
    "libblastrampoline.so.5"
end

# Julia builds libblastrampoline itself (USE_SYSTEM_LIBBLASTRAMPOLINE=0) and
# installs it into $(prefix)/lib/julia, which is the same absolute path at
# system-image generation time and on the device.
const termux_julia_libdir = joinpath(dirname(Sys.BINDIR), "lib", "julia")
const termux_lbt_path = joinpath(termux_julia_libdir, libblastrampoline)

function __init__()
    # See the note in OpenBLAS_jll: `dlpath()` cannot be used on Bionic, and an
    # empty `libblastrampoline_path` baked into sys.so breaks BLAS resolution.
    global libblastrampoline_handle = dlopen(termux_lbt_path)
    if libblastrampoline_handle == C_NULL
        error("libblastrampoline_jll: could not dlopen ", termux_lbt_path,
              " — check that libblastrampoline was installed into ", termux_julia_libdir)
    end
    global libblastrampoline_path = termux_lbt_path
    global artifact_dir = dirname(Sys.BINDIR)
    LIBPATH[] = termux_julia_libdir
    push!(LIBPATH_list, LIBPATH[])
end

# JLLWrappers API compatibility shims.  Note that not all of these will really make sense.
# For instance, `find_artifact_dir()` won't actually be the artifact directory, because
# there isn't one.  It instead returns the overall Julia prefix.
is_available() = true
find_artifact_dir() = artifact_dir
dev_jll() = error("stdlib JLLs cannot be dev'ed")
best_wrapper = nothing
get_libblastrampoline_path() = libblastrampoline_path

end  # module libblastrampoline_jll
