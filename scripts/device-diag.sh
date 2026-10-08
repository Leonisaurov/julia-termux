#!/data/data/com.termux/files/usr/bin/bash
# Diagnostic of the julia build ALREADY installed on this device.
# Read-mostly: writes only inside a mktemp workdir under $PREFIX/tmp and removes
# it on exit. Heavy tests belong to scripts/device-smoke.sh.
set -uo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
WORKDIR="$(mktemp -d "$PREFIX/tmp/julia-diag.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

avail_kb=$(df -k "$PREFIX" | awk 'NR==2 {print $4}')
if [ "${avail_kb:-0}" -lt 614400 ]; then
	echo "refusing to run: less than 600 MB free on $PREFIX ($avail_kb KB)" >&2
	exit 1
fi

export JULIA_DEPOT_PATH="$WORKDIR/depot"
export JULIA_COMPILED_CACHE_PATH="$WORKDIR/cache"
export TMPDIR="$WORKDIR"
mkdir -p "$JULIA_DEPOT_PATH" "$JULIA_COMPILED_CACHE_PATH"

pass=0
fail=0

check() {
	local name="$1" code="$2"
	local log="$WORKDIR/out.$name.log" rc
	# shellcheck disable=SC2024
	timeout 180 julia --startup=no -e "$code" >"$log" 2>&1
	rc=$?
	if [ "$rc" -eq 0 ]; then
		printf 'PASS  %s\n' "$name"
		pass=$((pass + 1))
	else
		printf 'FAIL  %s  (rc=%s)\n' "$name" "$rc"
		sed -e "s|^|        |" "$log" | head -12
		fail=$((fail + 1))
	fi
}

echo "== julia-diag $(date -u +%FT%TZ) =="
echo "binary: $(command -v julia)"
echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<unset>}"

check version '--version'
check repl '-e nothing; println(1+1)'
check blas_vendor 'using LinearAlgebra; println(Base.BLAS.vendor())'
check linear_algebra '
using LinearAlgebra, Random
Random.seed!(42)
A = [4.0 1.0 0.0; 1.0 3.0 1.0; 0.0 1.0 2.0]
b = [1.0; 2.0; 3.0]
x = A \ b
res = norm(A * x - b)
res < 1e-9 || error("solve inaccurate: $res")
println("matmul ", sum(rand(4) .* rand(4, 4) |> vec))
println("norm ok ", res)
'
check cholesky_lu '
using LinearAlgebra
A = [4.0 1.0; 1.0 3.0]
println(chol(A).U, "\n", lu(A).U)
'
check sparse_arrays '
using SparseArrays
S = spdiagm(0 => [1.0, 2.0, 3.0], 1 => [1.0, 1.0])
println(sum(S), " ", nnz(S))
'
check suitesparse '
using SparseArrays, SuiteSparse, LinearAlgebra
A = spdiagm(0 => [4.0, 3.0, 2.0], 1 => [-1.0, -1.0], -1 => [-1.0, -1.0])
F = cholesky(A)
println(typeof(F.factors), " ", sum(F \ ones(3)))
'
check threads '-e println(Threads.nthreads())'
check threads_spawn '
using Base.Threads
c = Atomic{Int64}(0)
@threads for i in 1:64 atomic_add!(c, 1)
c[] == 64 || error("thread count wrong: $(c[])")
println("ok")
'
check libgit2 'using LibGit2; println(LibGit2.GitRepo)'
check pkg_status 'using Pkg; Pkg.status()'
check mbedtls 'using MbedTLS; println(MbedTLS.VERSION_STRING)'
check libdl_openblas '
using Libdl
h = dlopen("libopenblas.so")
h != C_NULL || error("dlopen libopenblas.so failed")
println(dlpath(h))
'
check libdl_lbt '
using Libdl
h = dlopen("libblastrampoline.so.5")
h != C_NULL || error("dlopen libblastrampoline.so.5 failed")
println(dlpath(h))
'
check dlpath_system_lib '
using Libdl
for lib in ("libgmp.so.10", "libmpfr.so.6", "libpcre2-8.so")
    h = dlopen(lib)
    h == C_NULL && error("dlopen $lib failed")
    p = try
        dlpath(h)
    catch e
        error("dlpath($lib) threw: ", sprint(e))
    end
    println(lib, " -> ", p)
end
'
check interactive_utils 'using InteractiveUtils; versioninfo()'
check sharedstdlibs 'using SharedArrays, Sockets, Distributed; println("ok")'

echo "== summary: $pass pass, $fail fail =="
exit "$fail"
