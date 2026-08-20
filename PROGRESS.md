# PROGRESS.md — Estado del Proyecto julia-termux

> Última actualización: 2026-08-20 ~16:30 CST

---

## Resumen

Proyecto para cross-compilar Julia v1.12.6 para Termux/Android (aarch64) usando
el build system de termux-packages. Repositorio: Leonisaurov/julia-termux.

**Estado actual**: Build local muerto (OOM/SIGTERM). CI fallando en error de
cross-compilation de LLVM (ZLIB). Pendiente investigación y fix.

---

## Build Local (Termux en dispositivo)

**Status**: PARADO (parado manualmente por el usuario, no por OOM)

**Último estado conocido**: 51% de LLVM compilado con `-j1`
- Session: `proc_bcac578822a6` (exit code -15 / SIGTERM)
- LLVM estaba en `Transforms/IPO` (~16h de compilación)
- Cache en `~/.termux-build/` preservada (solo borrar `deps/scratch/llvm-julia-*/`)
- La compilación de LLVM es la etapa más pesada (~8h normalmente)

**¿Por qué se paró?**: Parado manualmente por el usuario.
`./scripts/build-local.sh -j1 --format debian --continue` cuando el dispositivo
tenga suficiente RAM libre.

**Archivos relevantes**:
- `~/.termux-build/` — cache del build (sagrada, no borrar completo)
- `~/.termux-build/julia/src/deps/scratch/llvm-julia-18.1.7-4/` — LLVM build dir

---

## CI (GitHub Actions)

**Status**: FALLANDO — 5 runs fallidos, 1 en progreso

### Último error conocido
```
Could NOT find ZLIB (missing: ZLIB_LIBRARY) (found version "1.3.1")
```

### Causa raíz identificada
Julia's `deps/llvm.mk` configura LLVM cmake con:
```makefile
LLVM_CMAKE += -DLLVM_ENABLE_ZLIB=FORCE_ON -DZLIB_ROOT="$(build_prefix)"
```
El problema: `$(build_prefix)` apunta a `BUILDDIR/usr` (directorio de build de
Julia), NO al prefix de Termux (`/data/data/com.termux/files/usr`) donde el
step de deps instaló zlib.

El cmake toolchain de termux-packages restringe la búsqueda de librerías al
sysroot (`CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY`). Resultado:
- Headers: encontrados (del host Ubuntu v1.3.1)
- Librería: NO encontrada (busca en sysroot, no en Termux prefix)

### Fix aplicado (H16)
En `packages/julia/build.sh`, sed-parchea `deps/llvm.mk` para usar
`${TERMUX_PREFIX}` en lugar de `$(build_prefix)`:
```makefile
# Antes:
-DZLIB_ROOT="$(build_prefix)"
# Después:
-DZLIB_ROOT="${TERMUX_PREFIX}" -DZLIB_LIBRARY="${TERMUX_PREFIX}/lib/libz.so" -DZLIB_INCLUDE_DIR="${TERMUX_PREFIX}/include"
```

**Pendiente**: El fix H16 usa `${TERMUX_PREFIX}` con llaves pero el último run
(32422559792) todavía mostraba `ERMUX_PREFIX` — significa que el sed anterior
(usando `$TERMUX_PREFIX` sin llaves) fue el que se ejecutó. El fix con llaves
(`${TERMUX_PREFIX}`) fue pushado pero el run actual (32424126077) está en
progreso y debería usar el fix correcto.

### Runs de CI
| Run ID     | Status    | Error                              |
|------------|-----------|-------------------------------------|
| 32424126077| in_progress| (pendiente — primer run con fix {}) |
| 32422559792| failure   | ZLIB: `ERMUX_PREFIX` (sin {})       |
| 32420949217| failure   | ZLIB: `ERMUX_PREFIX` (sin {})       |
| 32337297450| failure   | ZLIB: cmake no lo encuentra         |
| 32336273499| failure   | ZLIB: cmake no lo encuentra         |

### Bugs resueltos en CI
1. **Docker install** — Docker ya viene pre-instalado en GH Actions runners
2. **Cache permissions** — `chmod 777 ~/.termux-build` para container Docker
3. **fuse-overlayfs** — GitHub Actions bloquea FUSE (AppArmor). Fix: sed-parchea
   `termux_setup_toolchain_29.sh` para usar `cp` en vez de `fuse-overlayfs`
4. **nounset** — `_JULIA_TERMUX_ROOT: unbound variable`. Fix: declarar globalmente
5. **Package names** — `openblas` → `libopenblas`, `gmp` → `libgmp`, `p7zip` eliminado
6. **cmake not found** — Docker es Ubuntu, no Termux. Fix: `apt-get install cmake`
7. **ZLIB_LIBRARY** — cmake busca en sysroot, no en Termux prefix. Fix: H16

---

## Archivos Clave

| Archivo | Descripción |
|---------|-------------|
| `packages/julia/build.sh` | Core: ~460 líneas, 30+ parches inline |
| `.github/workflows/build-package.yml` | CI: dos steps (deps + Julia) |
| `scripts/run-docker.sh` | Wrapper Docker (basado en termux-packages) |
| `scripts/build-local.sh` | Build local en Termux |
| `scripts/build-deps-docker.sh` | Instala deps cross-compilation en Docker |
| `scripts/patch-fuse-overlayfs.sh` | Deshabilita fuse-overlayfs para Docker |
| `scripts/install-deps.sh` | Instala dependencias en Termux |

---

## Lo que Sigue

1. **Esperar run 32424126077** — Si `${TERMUX_PREFIX}` con llaves funciona,
   LLVM configurará correctamente con ZLIB
2. **Si funciona**: El build de CI tardará ~30-60min (compila LLVM + Julia)
3. **Recolectar release**: El artifact `.deb` se publica en `julia-latest`
4. **Probar en Termux**: Instalar el `.deb` y verificar que `julia --version` funciona
5. **Build local**: Relanzar con `--continue` cuando el dispositivo tenga RAM libre

---

## Notas para el Próximo Agente

- **NUNCA** ejecutar instalaciones sin preguntar al usuario
- **NUNCA** borrar `~/.termux-build` completo — solo `deps/scratch/llvm-julia-*/`
- **SIEMPRE** builds en background+notify
- **Cache sagrada**: `~/.termux-build` se preserva entre builds
- El build local con `-j1` tarda ~16-20h para LLVM completo
- El Docker image es Ubuntu (usa `apt`), NO Termux (usa `pkg`)
- `set -euo pipefail` en `build-package.sh` — TODO sed necesita `|| true`
- El sed en `termux_step_pre_configure()` corre DESPUÉS de extract (el source
  ya existe en `$SRCDIR`)
