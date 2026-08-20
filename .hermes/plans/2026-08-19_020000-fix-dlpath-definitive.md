# Plan: Restaurar dlpath en JLLs

**Goal:** Hacer que Julia funcione en Android restaurando dlpath en los JLLs.

**Root cause:** Los JLL patches bypasean dlpath con paths hardcodeados. El path hardcodeado produce un path vacío → lbt_forward("") falla → BLAS no carga → Julia muere.

**Fix:** Restaurar dlpath (que funciona gracias al H07 en sys.c) y quitar dlopen(_libgfortran) innecesario.

---

## Task 1: Crear packages/julia/patches/jll/OpenBLAS_jll.jl

**Archivo:** `packages/julia/patches/jll/OpenBLAS_jll.jl`

Copiar el siguiente contenido EXACTO (es el original de Julia 1.12.6 con UN cambio: se quitó la línea `dlopen(_libgfortran)`):

```julia
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

if Sys.iswindows()
    const libopenblas = "libopenblas$(libsuffix).dll"
    const _libgfortran = string("libgfortran-", libgfortran_version(HostPlatform()).major, ".dll")
elseif Sys.isapple()
    const libopenblas = "@rpath/libopenblas$(libsuffix).dylib"
    const _libgfortran = string("@rpath/", "libgfortran.", libgfortran_version(HostPlatform()).major, ".dylib")
else
    const libopenblas = "libopenblas$(libsuffix).so"
    const _libgfortran = string("libgfortran.so.", libgfortran_version(HostPlatform()).major)
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

    global libopenblas_handle = dlopen(libopenblas)
    global libopenblas_path = dlpath(libopenblas_handle)
    global artifact_dir = dirname(Sys.BINDIR)
    LIBPATH[] = dirname(libopenblas_path)
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
```

**Cambio vs original:** Se eliminó la línea `dlopen(_libgfortran)` (libgfortran no existe en Termux porque flang vincula el runtime de Fortran estáticamente en OpenBLAS).

**Verificación:**
```bash
grep dlpath packages/julia/patches/jll/OpenBLAS_jll.jl
# Debe mostrar: global libopenblas_path = dlpath(libopenblas_handle)

grep gfortran packages/julia/patches/jll/OpenBLAS_jll.jl | grep dlopen
# No debe mostrar nada (no hay dlopen de gfortran)
```

---

## Task 2: Crear packages/julia/patches/jll/libblastrampoline_jll.jl

**Archivo:** `packages/julia/patches/jll/libblastrampoline_jll.jl`

Copiar el siguiente contenido EXACTO (es el original de Julia 1.12.6 sin cambios):

```julia
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

function __init__()
    global libblastrampoline_handle = dlopen(libblastrampoline)
    global libblastrampoline_path = dlpath(libblastrampoline_handle)
    global artifact_dir = dirname(Sys.BINDIR)
    LIBPATH[] = dirname(libblastrampoline_path)
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
```

**Verificación:**
```bash
grep dlpath packages/julia/patches/jll/libblastrampoline_jll.jl
# Debe mostrar: global libblastrampoline_path = dlpath(libblastrampoline_handle)
```

---

## Task 3: Build

```bash
cd /data/data/com.termux/files/home/Develop/Patch/Julia/julia-termux
./scripts/build-local.sh -j2 --format debian
```

---

## Task 4: Verificación

```bash
julia -e 'println(dlpath("libopenblas"))'
# Debe mostrar: /data/data/com.termux/files/usr/lib/libopenblas.so

julia -e 'using LinearAlgebra; println(BLAS.get_config())'
# Debe mostrar la config de BLAS sin errores
```

---

## Evidencia de que dlpath funciona en Android

```
# C test: jl_pathname_for_handle retorna path correcto
RESULT: /data/data/com.termux/files/usr/lib/libopenblas.so

# strace: dlopen encuentra ambas librerías
openat(..., "/usr/lib/libopenblas.so") = 15
openat(..., "/usr/lib/julia/libblastrampoline.so.5") = 15

# libopenblas.so tiene símbolos LP64 (28 dgemm_ symbols)
# libgfortran NO existe (flang vincula staticamente)
```
