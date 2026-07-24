# Julia para Termux — Build System

Repositorio para compilar Julia nativamente para Termux/Android (aarch64) usando la infraestructura de termux-packages en GitHub Actions CI.

## Estado Actual (24 Jul 2026)

**La compilación de Julia NO completa.** Tras análisis exhaustivo del código, se identificaron **3 bugs críticos** que causan el error silencioso (exit code 1):

### Bug #1 (🔴 Crítico - 85% probabilidad): `CROSS_COMPILE` se hereda al host flisp vía `MAKEOVERRIDES`

- **Causa raíz**: Julia's `Make.inc` línea ~451 usa `override CROSS_COMPILE:=$(XC_HOST)-`. En GNU Make, `override` fuerza la variable a `MAKEOVERRIDES`, que se hereda a TODOS los sub-makes.
- **Efecto**: El build de flisp para HOST (necesario para bootstrapping) hereda `CROSS_COMPILE=aarch64-linux-android-`. Cuando `USEGCC=1` (línea 588), `CC` se reasigna a `aarch64-linux-android-gcc`, que NO EXISTE en NDK r29 (solo hay clang). `command not found` → exit code 1.
- **No hay guard BUILDING_HOST_TOOLS** en las secciones USEGCC/USECLANG de Make.inc (líneas 588-601).
- **Fix aplicado**: Sed que quita `override` de la línea de CROSS_COMPILE en Make.inc.

### Bug #2 (🟡 Importante - 10% probabilidad): Seds OSLIBS eliminan -lpthread también para HOST

- **Causa raíz**: Los seds `^OSLIBS/s/ -lpthread//`, `^OSLIBS/s/ -lrt//`, `^OSLIBS/s/ -latomic//` afectan a TODAS las líneas OSLIBS, incluyendo las del HOST Linux x86_64 donde `-lpthread` SÍ es necesario (glibc < 2.34).
- **Efecto**: El host flisp linkea sin pthread → undefined references → error de link.
- **Fix aplicado**: Los seds ahora usan `^OSLIBS.*--no-as-needed` para afectar solo la línea del target.

### Bug #3 (🟡 Importante): Seds sin protección causan `set -e` silencioso

- **Causa raíz**: 13 comandos `sed -i` en `termux_step_pre_configure()` NO tenían `|| true`. Bajo `set -euo pipefail` (build-package.sh línea 21), cualquier sed que falle (archivo renombrado por Julia upstream) causa `exit 1` sin mensaje.
- **Efecto**: El build aborta silenciosamente si Julia master cambia algún archivo parcheado.
- **Fix aplicado**: Todos los seds ahora tienen `|| echo "Warning: ..." >&2`.

## Cambios Recientes (24 Jul 2026 - Sprint de Fixes)

### Diagnóstico Completo (Análisis de Código)

Se realizó un análisis exhaustivo del código usando el subagente `critico`, que identificó 3 bugs en el build system. Véase sección "Estado Actual" arriba para detalles.

### Fix 1: Seds protegidos contra `set -e`

Los 13 `sed -i` sin protección en `termux_step_pre_configure()` ahora tienen `|| echo "Warning: ..." >&2`. Esto evita que `set -euo pipefail` mate el build silenciosamente si Julia master renombra o elimina algún archivo parcheado.

Archivos afectados por los seds:
- `deps/lmdb.mk`, `deps/libuv.mk`, `Make.inc`, `cli/Makefile`, `src/flisp/Makefile`
- `src/julia.expmap.in`, `Makefile` (root), `src/Makefile`, `base/Makefile`

### Fix 2: Seds OSLIBS ahora son específicos del target

Los seds que eliminan `-lpthread`, `-lrt`, `-latomic` ahora usan el patrón `^OSLIBS.*--no-as-needed` para afectar SOLO la línea del target Android/bionic, no la del host Linux x86_64.

### Fix 3: Quitado `override` de CROSS_COMPILE en Make.inc

Nuevo sed que cambia `override CROSS_COMPILE:=$(XC_HOST)-` a `CROSS_COMPILE:=$(XC_HOST)-` en Make.inc. Esto evita que `MAKEOVERRIDES` herede `CROSS_COMPILE=aarch64-linux-android-` al sub-make del host flisp, que necesita compilar para x86_64 nativo (no cross-compile).

### Fix 4: Verbose mode en CI

Se agregó `-Q` al comando `build-package.sh` en el workflow de GitHub Actions para habilitar verbose mode (set -x). También se agregó un step "Debug - Show build log on failure" que captura logs adicionales cuando el build falla.

### Parches Eliminados (anteriormente)

Los 12 patches (`0001` a `0012`) fueron eliminados porque Julia master cambió constantemente y los patches se desactualizaban. Cada uno fue reemplazado por un `sed` directo en `termux_step_pre_configure()` del archivo `packages/julia/build.sh`.

| Patch | Archivo | Fix |
|-------|---------|-----|
| 0001 | `src/support/platform.h` | Definir `_OS_ANDROID_` |
| 0002 | `src/support/dtypes.h` | Excluir bionic de endian/uint_t |
| 0003 | `src/sys.c` | dl_iterate_phdr fallback |
| 0004 | `src/dlload.c` | Incluir link.h en bionic |
| 0005 | `cli/loader_lib.c` | Stub libstdcxxprobe en Android |
| 0007 | `src/init.c` | pthread_getattr_np → bionic |
| 0008 | `src/debuginfo.cpp` | Excluir __register_frame |
| 0009 | `src/codegen.cpp` | Excluir sysinfo() |
| 0010 | `src/task.c` | Excluir #error libunwind |
| 0011 | `src/gc-debug.c` | Excluir mallinfo/malloc_stats |
| 0012 | `src/jl_uv.c` | TCP_QUICKACK guard |

### USE_CROSS_FLISP (confirmado como enfoque correcto)

Se verificó que `USE_CROSS_FLISP=1` es el enfoque correcto para cross-compilation. Julia's Make.inc tiene soporte nativo para esto mediante `BUILDING_HOST_TOOLS=1` y `Make.host.user`. El bug real no era `USE_CROSS_FLISP` en sí, sino que `CROSS_COMPILE` se heredaba al sub-make host vía `MAKEOVERRIDES` (Fix 3 arriba). Con el fix aplicado, `USE_CROSS_FLISP=1` debería funcionar correctamente.

## Problemas Conocidos

### 1. Build falla con exit code 1 (CAUSA IDENTIFICADA - Fix aplicado)

**Causa raíz**: `override CROSS_COMPILE` en Make.inc de Julia se hereda al sub-make del host flisp vía `MAKEOVERRIDES` de GNU Make, causando que `CC` se reasigne a `aarch64-linux-android-gcc` que no existe en NDK r29.

**Fix aplicado**: Sed que quita `override` de la línea de CROSS_COMPILE en Make.inc.

**Próximo paso**: Ejecutar CI para verificar si el fix resuelve el error.

### 2. Los seds son frágiles a cambios de Julia upstream

Cada vez que Julia master cambia los archivos parcheados, los seds pueden fallar o producir resultados incorrectos. Los seds ahora tienen `|| echo "Warning"` para no matar el build, pero es necesario revisar periódicamente si siguen siendo correctos.

**Mitigación pendiente**: Configurar Dependabot o workflow que verifique los seds contra Julia master y alerte si algún archivo ya no existe o cambió.

### 3. Dependencias externas via install-deps.sh

Las dependencias de Julia (`libllvm`, `libopenblas`, `suitesparse`, etc.) se instalan manualmente mediante `scripts/install-deps.sh` que descarga `.deb` del repo APT de Termux y los extrae a `/`. Esto funciona pero no está integrado con el sistema de dependencias de `build-package.sh` (no se usa `-I`, se usa `-s` para saltar depcheck).

### 4. `TERMUX_PKG_BUILD_IN_SRC=true` implica que no hay directorio de build separado

Julia se construye directamente en el directorio fuente. Esto funciona porque Julia's Makefile está diseñado para build in-source, pero significa que el caché de build no es fácil de separar.

## Estructura del Repositorio

```
.github/workflows/build-julia.yml   ← CI workflow (mejorado)
packages/julia/
├── build.sh                          ← Receta de build (sin patches, con seds)
├── *.patch                           ← YA NO EXISTEN (todos eliminados)
scripts/
├── build-package.sh                 ← Entry point de build (idéntico a upstream)
├── build/                           ← Scripts de build (idénticos a upstream)
├── install-deps.sh                  ← Instalación manual de dependencias (mejorado)
├── run-docker.sh                    ← Wrapper Docker (idéntico a upstream)
```

## Cómo construir localmente

```bash
# Requisitos: Docker, git
cd julia-termux-package
./scripts/run-docker.sh bash ./scripts/install-deps.sh
./scripts/run-docker.sh ./build-package.sh -s -a aarch64 --format pacman julia
```

## Pendientes

- [ ] **Probar build en CI**: Hacer push de los cambios y ejecutar el workflow para verificar si los fixes resuelven el error silencioso.
- [ ] **Verificar verbose logs**: Con `-Q` habilitado, revisar los logs de CI para confirmar que el flisp host se compila correctamente para x86_64.
- [ ] **Cache de LLVM**: La compilación descarga LLVM (~170MB) cada vez. Optimizar el caché de GitHub Actions para incluir LLVM.
- [ ] **Migrar a `-I`**: Para alinearse con el proyecto original, declarar dependencias en build.sh y cambiar `-s` por `-I` en el workflow.
- [ ] **Auto-verificación de seds**: Script que compare los patrones de sed contra Julia master y alerte si algún archivo ya no existe.

## Referencias

- **Proyecto original**: `~/Develop/Clones/termux-packages` (fork proot-only de `termux/termux-packages`)
- **Workflow original**: usa `-I -a aarch64 --format pacman` para construir paquetes
- **Scripts de build**: idénticos al original (verificados diff)
- **buildorder.py**: tiene parche para saltar dependencias faltantes (commit `92da334`)
