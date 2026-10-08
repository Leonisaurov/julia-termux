#!/data/data/com.termux/files/usr/bin/bash
# Definition of done for the Julia Termux port: installs a CI-produced package
# bundle on this device and asserts that it actually works.
#
# Run this on Termux, never in CI. CI builds; the device proves.
#
# Usage:
#   bash scripts/device-smoke.sh <bundle> [--network] [--runtests [tags]]
#     <bundle>  path or URL to a .deb, .pkg.tar.xz, or a .tar.gz/.zip holding them
#     --network also exercise Pkg downloads (needs network + a registry)
#     --runtests run parts of Julia's own test suite through tcr
#   SMOKE_KEEP=1  keep the workdir (default: removed on exit, always)
set -uo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BUNDLE="${1:-}"
[ -n "$BUNDLE" ] || { echo "usage: $0 <bundle> [--network] [--runtests [tags]]" >&2; exit 2; }
shift
NETWORK=0
RUNTESTS=0
TEST_TAGS="${TEST_TAGS:-linalg sparsearrays libdl sockets errors}"
while [ $# -gt 0 ]; do
	case "$1" in
	--network) NETWORK=1 ;;
	--runtests)
		RUNTESTS=1
		[ -n "${2:-}" ] && { TEST_TAGS="$2"; shift; }
		;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

WORK="$(mktemp -d "$PREFIX/tmp/julia-smoke.XXXXXX")"
SMOKE_KEEP="${SMOKE_KEEP:-0}"
cleanup() {
	if [ "$SMOKE_KEEP" = 1 ]; then
		echo "# workdir kept at $WORK"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT

avail_kb=$(df -k "$PREFIX" | awk 'NR==2 {print $4}')
if [ "${avail_kb:-0}" -lt 614400 ]; then
	echo "refusing to run: less than 600 MB free on $PREFIX ($avail_kb KB). Clean up first." >&2
	exit 1
fi

export JULIA_DEPOT_PATH="$WORK/depot"
export JULIA_COMPILED_CACHE_PATH="$WORK/cache"
export TMPDIR="$WORK"
mkdir -p "$JULIA_DEPOT_PATH" "$JULIA_COMPILED_CACHE_PATH"

inst="$(dirname "$0")/install-deps.sh"
[ -f "$inst" ] || inst=""

echo "== julia device smoke $(date -u +%FT%TZ) =="
echo "bundle: $BUNDLE"
echo "free: $((avail_kb / 1024)) MB"

DLDIR="$WORK/dl"
mkdir -p "$DLDIR"
case "$BUNDLE" in
http://* | https://*)
	curl --fail --location --retry 3 -o "$DLDIR/$(basename "$BUNDLE")" "$BUNDLE" || exit 3
	BUNDLE="$DLDIR/$(basename "$BUNDLE")"
	;;
esac
[ -f "$BUNDLE" ] || { echo "bundle not found: $BUNDLE" >&2; exit 2; }

# checksums, if the bundle ships them
BASEDIR="$(dirname "$BUNDLE")"
if [ -f "$BASEDIR/SHA256SUMS" ] || [ -f "$BASEDIR/SHA256SUMS.txt" ]; then
	sums="$BASEDIR/SHA256SUMS"
	[ -f "$sums" ] || sums="$BASEDIR/SHA256SUMS.txt"
	(cd "$BASEDIR" && sha256sum -c "$(basename "$sums")") || { echo "checksum verification FAILED" >&2; exit 4; }
	echo "PASS  checksums verified"
fi

PKGFILES="$WORK/pkgfiles"
mkdir -p "$PKGFILES"
case "$BUNDLE" in
*.tar.gz | *.tgz | *.zip)
	tar -xf "$BUNDLE" -C "$PKGFILES" 2>/dev/null || unzip -q "$BUNDLE" -d "$PKGFILES"
	;;
*) cp "$BUNDLE" "$PKGFILES/" ;;
esac
find "$PKGFILES" -name '*.pkg.tar.*' > "$WORK/pacman.list"
find "$PKGFILES" -name '*.deb' > "$WORK/dpkg.list"
echo "packages found: pacman=$(wc -l < "$WORK/pacman.list") dpkg=$(wc -l < "$WORK/dpkg.list")"

install_pkgs() {
	if [ -s "$WORK/pacman.list" ] && command -v pacman >/dev/null 2>&1; then
		pacman -U --noconfirm --overwrite '*' $(cat "$WORK/pacman.list")
	elif [ -s "$WORK/dpkg.list" ] && command -v dpkg >/dev/null 2>&1; then
		# llvm-julia must land before julia if the recipe splits them
		sort -r $(cat "$WORK/dpkg.list") | xargs -r dpkg -i
	else
		return 1
	fi
}
if ! install_pkgs; then
	echo "install failed — no pacman/dpkg usable package found" >&2
	exit 5
fi
echo "installed; hash table refreshed for: $(command -v julia || echo none)"

pass=0
fail=0
check() {
	local name="$1" code="$2" log="$WORK/out.$1.log" rc
	timeout "${TIMEOUT:-300}" julia --startup=no -e "$code" >"$log" 2>&1
	rc=$?
	if [ "$rc" -eq 0 ]; then
		printf 'PASS  %s\n' "$name"
		pass=$((pass + 1))
	else
		printf 'FAIL  %s (rc=%s)\n' "$name" "$rc"
		sed -e 's|^|        |' "$log" | head -15
		fail=$((fail + 1))
	fi
}

check version '--version'
check hello 'println("hello ", 6*7)'
check dlpath_regression '
using Libdl
# jl_pathname_for_handle must not return NULL on Bionic (H07: dl_iterate_phdr)
for lib in ("libblastrampoline.so.5", "libgmp.so.10", "libmpfr.so.6")
    h = dlopen(lib)
    h == C_NULL && error("dlopen failed for $lib")
    p = dlpath(h)
    isempty(p) && error("dlpath returned empty for $lib")
    isfile(p) || error("dlpath gave a non-existent path for $lib: $p")
    println(lib, " -> ", p)
end
'
check blas_vendor '
using LinearAlgebra
v = Base.BLAS.vendor()
println("BLAS vendor: ", v)
'
check linear_algebra '
using LinearAlgebra, Random, Test
Random.seed!(1234)
A = [4.0 1.0 0.0; 1.0 3.0 1.0; 0.0 1.0 2.0]
b = [1.0, 2.0, 3.0]
x = A \ b
@test norm(A * x - b) < 1e-10
n = 200
M = randn(n, n)
@test norm(M * (inv(M) * ones(n)) - ones(n)) < 1e-6
@test norm(cholesky(Symmetric(A + 3I)).U) > 0
@test norm(lu(A).U * lu(A).L - A) < 1e-10
d = rand(n)
@test norm((Diagonal(d) * rand(n)) - d .* rand(n)) == 0
println("eig max abs: ", maximum(abs.(eigvals(Symmetric(A)))))
'
check gemm_threads '
using LinearAlgebra, Base.Threads, Test
println("nthreads=", nthreads())
A = Matrix{Float64}(I, 50, 50)
BLAS.set_num_threads(2)
@test sum(A * A) ≈ 50.0
BLAS.set_num_threads(1)
@test sum(A * A) ≈ 50.0
println("gemm ok across BLAS thread counts")
'
check threads_spawn '
using Base.Threads
c = Atomic{Int64}(0)
@threads for _ in 1:256 atomic_add!(c, 1)
c[] == 256 || error("threaded loop lost iterations: $(c[])")
println("threads ok")
'
check sparse_arrays '
using SparseArrays, LinearAlgebra
S = spdiagm(0 => [4.0, 3.0, 2.0], 1 => [-1.0, -1.0], -1 => [-1.0, -1.0])
x = S \ [1.0, 2.0, 3.0]
@test norm(S * x - [1.0, 2.0, 3.0]) < 1e-10
println("nnz=", nnz(S), " sum=", sum(S))
'
check suitesparse '
using SuiteSparse, SparseArrays, LinearAlgebra
A = spdiagm(0 => [4.0, 3.0, 2.0], 1 => [-1.0, -1.0], -1 => [-1.0, -1.0])
F = cholesky(A)
println("chol factor: ", typeof(F.factors))
@test norm(F \ [1.0, 2.0, 3.0] - A \ [1.0, 2.0, 3.0]) < 1e-10
'
check arpack '
using SparseArrays, LinearAlgebra, Test
n = 20
S = spdiagm(0 => fill(2.0, n), 1 => fill(-1.0, n - 1), -1 => fill(-1.0, n - 1))
vals = sort(real.(eigs(S; which=:LM, nev=3, tol=1e-9)[1]))
# largest Ritz values of the 1-D Laplacian + 2I: 2 - 2cos(k*pi/(n+1))
expected = [2 - 2cos(k * pi / (n + 1)) for k in (n, n - 1, n - 2)]
@test all(isapprox.(reverse(vals), expected; rtol=1e-6))
println("arpack eig: ", vals)
'
check libgit2 '
using LibGit2
repo = mktemp(dir=TMPDIR)
isdir(joinpath(repo, ".git")) && error("tmp dir collision")
r = LibGit2.init(repo)
write(joinpath(repo, "f.txt"), "hello")
LibGit2.add!(r, "f.txt")
c = LibGit2.commit(r, "first"; author=Sig("t <t@example.com>"), committer=Sig("t <t@example.com>"))
println("commit ", string(LibGit2.GitHash(c)))
close(r)
'
check pkg_status 'using Pkg; Pkg.status()'
check pcre_jit '
using Libdl, Test
# Julia asks PCRE2 to JIT every compiled regex (base/regex.jl); SLJIT writes into
# executable memory, which is exactly what breaks under emulated runtimes.
h = dlopen("libpcre2-8.so")
h == C_NULL && error("libpcre2-8.so not found")
val = Ref{Cint}(-1)
rc = ccall((:pcre2_config_8, h), Cint, (UInt32, Ref{Cint}), 1, val)  # PCRE2_CONFIG_JIT
rc == 0 || error("pcre2_config failed with ", rc)
println("pcre2 jit support: ", val[])
m = match(r"^(\w+)@([\d.]+)$", "julia@1.12.6")
m === nothing && error("regex did not match")
@test m[1] == "julia"
@test occursin(r"^\d+\.\d+\.\d+", string(VERSION))
println("regex+jit ok")
'
if [ "$NETWORK" = 1 ]; then
	check pkg_add '
using Pkg
Pkg.activate(mktemp(dir=TMPDIR))
Pkg.add("Example")
using Example
println("greet: ", Example.hello("julia"))
'
	check pkg_instantiate_download '
using Pkg
Pkg.activate(mktemp(dir=TMPDIR))
Pkg.add(PackageSpec(name="JSON", version="0.21"))
using JSON
println(JSON.parse("{\"a\":1}"))
'
	check mbedtls_https '
using MbedTLS, Sockets
println("MbedTLS ", MbedTLS.VERSION_STRING)
'
else
	echo "SKIP  Pkg network tests (pass --network to run them)"
fi
check sharedarrays_sockets 'using SharedArrays, Sockets, Distributed; println("ok")'
check unicode_fft '
using FFTW, Random, LinearAlgebra
x = randn(64)
@test norm(fft(ifft(x)) - x) < 1e-8
println("fft ok")
'
check interactive_utils 'using InteractiveUtils; versioninfo(; verbose=false)'
check codegen_llvm '
# exercises libjulia-codegen and the LLVM it links
using InteractiveUtils, Test
f(x, y) = x * y + 1
io = IOBuffer()
code_llvm(io, f, (Int, Int); raw=true)
ir = String(take!(io))
occursin("define ", ir) || error("no LLVM IR was emitted")
@test occursin("mul", ir)
println("llvm emitted ", length(ir), " chars")
'

if [ "$RUNTESTS" = 1 ]; then
	if [ ! -d "$PREFIX/share/julia/test" ]; then
		echo "FAIL  the installed package ships no test suite ($PREFIX/share/julia/test)" >&2
		fail=$((fail + 1))
	else
		echo "-- running Julia test suite subsets through tcr (tags: $TEST_TAGS) --"
		TCR="$(command -v tcr || echo "$HOME/.local/bin/tcr")"
		[ -x "$TCR" ] || TCR=""
		for tag in $TEST_TAGS; do
			log="$WORK/runtest.$tag.log"
			code="Base.runtests([\"$tag\"]; nthreads=1, verbose=false)"
			if [ -n "$TCR" ]; then
				timeout "${RUNTEST_TIMEOUT:-3600}" "$TCR" julia --startup=no -e "$code" >"$log" 2>&1
			else
				timeout "${RUNTEST_TIMEOUT:-3600}" julia --startup=no -e "$code" >"$log" 2>&1
			fi
			rc=$?
			if [ "$rc" -eq 0 ]; then
				printf 'PASS  runtests:%s\n' "$tag"
				pass=$((pass + 1))
			else
				printf 'FAIL  runtests:%s (rc=%s)\n' "$tag" "$rc"
				tail -20 "$log" | sed -e 's|^|        |'
				fail=$((fail + 1))
			fi
		done
	fi
fi

echo
echo "== summary: $pass pass, $fail fail =="
[ "$fail" -eq 0 ] || exit 6
echo "SMOKE: PASS"
