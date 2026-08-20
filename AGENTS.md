# AGENTS.md — Documentación Técnica para Agentes AI

> **Propósito**: Este archivo contiene información crítica que un agente AI necesita conocer antes de modificar el build system de Julia para Termux. Incluye bugs conocidos, trampas comunes, arquitectura del Makefile de Julia, y reglas para añadir nuevos parches. Sin esta información, los cambios pueden romper silenciosamente el build.

## Resumen del Proyecto

Repositorio independiente que cross-compila [Julia v1.12.6](https://julialang.org) para Termux/Android (aarch64) usando el build system de `termux-packages`. El archivo core es `packages/julia/build.sh` (~462 líneas) que contiene ~30+ parches inline para adaptar Julia de glibc a bionic.

### Comandos Clave

```bash
# Build local (requiere Termux aarch64 + ~/.local/bin/tcr)
./scripts/install-deps.sh                           # Instalar deps de Termux
./scripts/build-local.sh -j2 --format debian        # Compilar
./scripts/build-local.sh --dry-run --jobs 2         # Validar sin compilar
./scripts/build-local.sh --continue -j2             # Reanudar tras fallo

# CI/CD (GitHub Actions)
git push origin main                                # Dispara build-package.yml

# Diagnóstico
grep -n "error:" ~/.termux-build/julia/*.log | head -20
ls output/                                          # Paquetes compilados
```

### Convenciones

- Parches en `termux_step_pre_configure()` con formato: `# AÑO: Descripción`
- TODO `sed` lleva `|| echo "Warning: ..." >&2` o `2>/dev/null || true`
- Clasificación: A-P = dependencias/config, F1-F13 = linker/config, H0-H12 = source fixes
- Archivos externos en `packages/julia/patches/` para patches que no son sed inline

---

## Tabla de Contenidos

- [Bugs Críticos Conocidos](#bugs-críticos-conocidos)
  - [Bug #1: CROSS_COMPILE heredado a host flisp](#bug-1-cross_complete-heredado-a-host-flisp)
  - [Bug #2: Seds OSLIBS eliminan flags también para HOST](#bug-2-seds-oslibs-eliminan-flags-tambin-para-host)
  - [Bug #3: Seds sin protección causan set -e silencioso](#bug-3-seds-sin-proteccin-causan-set--e-silencioso)
  - [Bug #4: libuv cross-compilation --host se ignora sin --build](#bug-4-libuv-cross-compilation---host-se-ignora-sin---build)
  - [Bug #5: LMDB sed falla silenciosamente en ciertas versiones](#bug-5-lmdb-sed-falla-silenciosamente-en-ciertas-versiones)
- [Arquitectura del Build System de Julia](#arquitectura-del-build-system-de-julia)
  - [Make.inc: El corazón del build](#makeinc-el-corazn-del-build)
  - [Make.user: Configuración del usuario](#makeuser-configuracin-del-usuario)
  - [Flujo de decisión USE_SYSTEM_*](#flujo-de-decisin-use_system_)
- [Estrategia de Bootstrapping](#estrategia-de-bootstrapping)
  - [¿Por qué flisp host manual?](#por-qu-flisp-host-manual)
  - [El problema del huevo y la gallina](#el-problema-del-huevo-y-la-gallina)
- [Trampas de Cross-Compilación](#trampas-de-cross-compilacin)
  - [MAKEOVERRIDES: El veneno silencioso](#makeoverrides-el-veneno-silencioso)
  - [BUILDING_HOST_TOOLS: El escudo](#building_host_tools-el-escudo)
  - [HOSTCC vs CC en Julia](#hostcc-vs-cc-en-julia)
- [Reglas para Añadir Nuevos Parches](#reglas-para-aadir-nuevos-parches)
  - [Formato correcto de sed](#formato-correcto-de-sed)
  - [Clasificación de parches](#clasificacin-de-parches)
  - [Orden de aplicación](#orden-de-aplicacin)
- [Dependencias Problemáticas](#dependencias-problemticas)
  - [libuv: El caso especial](#libuv-el-caso-especial)
  - [LLVM: La dependencia más pesada](#llvm-la-dependencia-ms-pesada)
  - [OpenBLAS: Solo aarch64](#openblas-solo-aarch64)
- [Diagnóstico de Fallos](#diagnstico-de-fallos)
  - [Patrones de error comunes](#patrones-de-error-comunes)
  - [Cómo leer un log de build de Julia](#cmo-leer-un-log-de-build-de-julia)
- [Referencia Rápida](#referencia-rpida)

---

## Bugs Críticos Conocidos

### Bug #1 (🔴 Crítico — 85% de probabilidad de ocurrencia)

**Problema**: `CROSS_COMPILE` se hereda al host flisp vía `MAKEOVERRIDES`

La macro `override CROSS_COMPILE:=$(XC_HOST)-` en `Make.inc` de Julia hace que, incluso cuando se invoca `make` con `CROSS_COMPILE=""`, el valor **override** prevalezca porque Make propaga las variables marcadas con `override` a sub-makes vía `MAKEOVERRIDES`.

**Causa raíz**:
```makefile
# Make.inc (original de Julia)
override CROSS_COMPILE:=$(XC_HOST)-
# ↑ Esto causa que cualquier sub-make herede el override
```

**Efecto**:
- flisp (que debe compilarse para HOST = x86_64) recibe `CROSS_COMPILE=aarch64-linux-android-`
- El compilador intenta ejecutar un binario ARM64 en x86_64 → `Exec format error`
- El build falla con mensajes como `flisp: cannot execute binary file`

**Fix aplicado** (líneas 52-59 de `build.sh`):
1. Se quita `override` → `CROSS_COMPILE:=$(XC_HOST)-`
2. Se añade un guard condicional:
```makefile
ifeq ($(BUILDING_HOST_TOOLS),1)
override CROSS_COMPILE:=
XC_HOST:=
endif
```

**Verificación**: Busca en `Make.inc` después de aplicar parches:
```bash
grep -n "CROSS_COMPILE" Make.inc
# Debe mostrar:
# CROSS_COMPILE:=$(XC_HOST)-    (sin "override" al inicio)
# ifeq ($(BUILDING_HOST_TOOLS),1)
# override CROSS_COMPILE:=
```

**⚠️ Al modificar**: Si tocas `Make.inc` o la sección K de `build.sh`, verifica que:
1. El `override` original está removido
2. El guard `BUILDING_HOST_TOOLS` está presente
3. El host build manual en `termux_step_make()` pasa `BUILDING_HOST_TOOLS=1`

---

### Bug #2 (🟡 Importante — 10% de probabilidad)

**Problema**: Los `sed` sobre `OSLIBS` eliminan flags también para el HOST

```bash
# build.sh línea 29 (peligroso):
sed -i '/^OSLIBS.*--no-as-needed/s/ -lpthread//' Make.inc
```

Este `sed` modifica **todas** las líneas que contienen `OSLIBS` en `Make.inc`. Pero `Make.inc` define tanto `OSLIBS` (para el target) como `HOST_OSLIBS` (para el host). Si la expresión regular no es lo suficientemente específica, puede afectar las flags del host también.

**Fix**: Usar siempre `^OSLIBS` (anclado al inicio de línea) para afectar solo la definición principal. No usar patrones genéricos que matcheen `HOST_OSLIBS`.

**Verificación**:
```bash
grep "^OSLIBS" Make.inc
grep "^HOST_OSLIBS" Make.inc
# Asegurarse de que HOST_OSLIBS aún contiene -lpthread si es necesario
```

---

### Bug #3 (🟡 Importante — siempre presente si no se cuida)

**Problema**: Seds sin protección causan `set -e` silencioso

El build system de termux-packages ejecuta `build.sh` con `set -e` (errexit). Si un `sed -i` falla porque el patrón no existe en el archivo (por ejemplo, porque Julia cambió el Makefile entre versiones), el script **termina inmediatamente** sin error visible.

**Ejemplo de fallo silencioso**:
```bash
# Sin protección (build.sh no usa esto):
sed -i '/patron_inexistente/s/foo/bar/' Makefile
# Si el patrón no existe, sed retorna código 1
# set -e mata el script inmediatamente
```

**Fix aplicado**: Todos los `sed` tienen una de estas protecciones:

```bash
# Opción 1 (recomendada para parches importantes): Warning visible
sed -i 's/foo/bar/' archivo || echo "Warning: no se pudo aplicar parche X" >&2

# Opción 2 (para parches cosméticos o tentativos): Silencioso
sed -i 's/foo/bar/' archivo 2>/dev/null || true
```

**⚠️ Regla**: TODO `sed` en `build.sh` debe tener una de estas dos protecciones. Nunca uses `sed -i` solo.

---

### Bug #4 (🔴 Crítico — condicional)

**Problema**: `./configure` de libuv ignora `--host` si no se especifica `--build`

En `deps/libuv.mk`, el `./configure` de libuv necesita tanto `--host` como `--build` para cross-compilar correctamente. Si solo se pasa `--host`, libuv detecta automáticamente el build system como `x86_64-pc-linux-gnu` y **asume que no hay cross-compilación**, ignorando `--host`.

**Fix aplicado** (línea 23 de `build.sh`):
```bash
sed -i 's|--with-pic.*|--with-pic --disable-shared \
    --host=aarch64-linux-android --build=x86_64-pc-linux-gnu \
    $(CONFIGURE_COMMON) $(UV_FLAGS)|' deps/libuv.mk
```

Se añaden explícitamente `--host` y `--build` con valores hardcodeados.

**⚠️ Si cambias de versión de Julia**: Verifica que la línea de `./configure` en `deps/libuv.mk` no haya cambiado de formato.

---

### Bug #5 (🟡 Importante)

**Problema**: El `sed` de LMDB puede fallar si el formato de `deps/lmdb.mk` cambia

```bash
# build.sh línea 19:
sed -i '/CPPFLAGS.*MDB_USE_ROBUST/d' deps/lmdb.mk
```

Si Julia cambia la sintaxis de cómo se define `CPPFLAGS` para LMDB, este `sed` no encontrará el patrón y fallará silenciosamente (protegido por `|| echo "Warning"`, pero el parche no se aplica).

**Síntoma**: El build falla con errores relacionados a `pthread_mutexattr_setrobust` no encontrado.

**Verificación**: Si ves errores de LMDB, verifica manualmente:
```bash
grep -n "MDB_USE_ROBUST" deps/lmdb.mk
# Si existe, el parche no se aplicó correctamente
```

---

## Arquitectura del Build System de Julia

### Make.inc: El corazón del build

`Make.inc` es el archivo de configuración principal de Julia. Es generado por `Make.inc.in` durante la configuración y define:

- **`CROSS_COMPILE`**: Prefijo de cross-compilación (ej: `aarch64-linux-android-`)
- **`XC_HOST`**: Target triple de cross-compilación
- **`OSLIBS`**: Librerías del sistema para el target
- **`HOST_OSLIBS`**: Librerías del sistema para el host
- **`CC`, `CXX`, `AR`, `RANLIB`**: Compiladores y herramientas
- **`BUILDING_HOST_TOOLS`**: Flag para distinguir host vs target
- **`FC`**: Fortran compiler (para LAPACK/BLAS)

**Jerarquía de Makefiles**:
```
Makefile (top-level)
├── Make.inc           ← Configuración global
├── Make.user          ← Configuración del usuario (generado en build.sh)
├── Make.host.user     ← Configuración del host tools (generado en build.sh)
├── base/Makefile      ← System image (sysimg.so)
├── src/Makefile       ← Compilador Julia (libjulia)
├── cli/Makefile       ← CLI (julia executable)
├── deps/Makefile      ← Dependencias (libuv, openlibm, etc.)
├── sysimage.mk        ← System image build (reemplazado por versión parcheada H11)
└── ui/Makefile        ← Interfaz de usuario (REPL, etc.)
```

### Make.user: Configuración del usuario

El `Make.user` generado en `termux_step_pre_configure()` (líneas 201-264 de `build.sh`) es el archivo más importante para la cross-compilación. Contiene 3 secciones:

**Sección 1: Cross-compilación**
```makefile
XC_HOST = aarch64-linux-android
OS = Linux
JULIA_CPU_TARGET = generic
AR = llvm-ar
RANLIB = llvm-ranlib
OBJCOPY = llvm-objcopy
```

**Sección 2: LLVM y USE_SYSTEM_* flags**
```makefile
USE_SYSTEM_LLVM=0        # ← BUNDLED LLVM (no del sistema)
USE_LLVM_SHLIB=1
override RT_LLVM_LINK_ARGS=$(CURDIR)/../usr/lib/libLLVMTargetParser.a ...
USE_PERF_JITEVENTS=0     # No disponible en Android
USE_SYSTEM_PCRE=1
# ... 18+ flags USE_SYSTEM_* en total
```

**⚠️ IMPORTANTE**: `USE_SYSTEM_LLVM=0` porque se usa LLVM bundled. Las librerías LLVM del sistema se crean como symlinks en `usr/lib/` para satisfacer el linker.

**Sección 3: Opciones de compilación**
```makefile
USE_BINARYBUILDER=0      # No usar BinaryBuilder (no funciona en Android)
DISABLE_LIBUNWIND=1      # libunwind no compatible
JULIA_THREADS=4
USE_CROSS_FLISP=1        # Usar flisp cross-compilado
FC = flang               # Compilador Fortran
F77 = flang
HEAPLIM := --heap-size-hint=4000M    # Limitar heap a 4GB (evita OOM)
JULIA_PRECOMPILE=0       # Saltar precompilación (evita OOM)
override FC_VERSION=dummy
override CXXFLAGS += -Wno-deprecated-declarations
override CFLAGS += -Wno-deprecated-declarations
```

**Fallback**: Si `Make.user` está vacío o falta durante `--continue`, `termux_step_make()` lo regenera automáticamente (líneas 270-336).

### Flujo de decisión USE_SYSTEM_*

Cuando Julia encuentra `USE_SYSTEM_LLVM=1`:

1. Busca `llvm-config` en el PATH
2. Ejecuta `llvm-config --cflags`, `--libdir`, `--ldflags`
3. Usa esas rutas para linker y compilador en lugar de compilar LLVM desde source
4. Si `llvm-config` no existe o falla: **el build falla**

Este patrón se repite para cada `USE_SYSTEM_*=1`. Las dependencias con `=0` se compilan desde el source incluido en el tarball de Julia.

**Regla de oro**: En Termux, usa `USE_SYSTEM_*=1` para TODO lo que sea un paquete de Termux. Usa `=0` solo para lo que Julia necesita parcheado (libuv, openlibm, utf8proc, DSFMT, libblastrampoline, mbedtls) o cuando LLVM bundled es necesario.

---

## Estrategia de Bootstrapping

### ¿Por qué flisp host manual?

Julia usa **flisp** (un dialecto de Lisp) como parte de su bootstrapping. El compilador de Julia está escrito en Julia mismo, pero para la primera compilación (bootstrap), necesita un intérprete de Lisp que ejecute el código que genera el compilador Julia inicial.

**El problema**: flisp debe compilarse para la **máquina HOST** (x86_64 en el contenedor Docker), no para el target (aarch64). Pero el build system de Julia, cuando detecta `CROSS_COMPILE`, intenta compilar flisp para el target.

### El problema del huevo y la gallina

```
Julia necesita flisp para compilar
flisp debe correr en la máquina HOST
Pero CROSS_COMPILE intenta compilar flisp para TARGET
```

**Solución actual** (en `termux_step_make()`):

1. Julia 1.12 genera el Makefile de flisp host desde `src/flisp/Makefile` y deja `BUILDDIR=./host`
2. Se parchea el Makefile de flisp para evitar duplicación de directorios (líneas 407-419)
3. Se crean symlinks para `usr/host/include/uv.h`, `usr/host/lib/libuv.a`, `usr/host/lib/libutf8proc.a` (líneas 416-427)
4. El build principal genera host tools automáticamente; no se necesita build manual separado

**⚠️ Si necesitas debuggear el host flisp**:
```bash
cd src/flisp/host
make -f "$PWD/src/flisp/Makefile" SRCDIR="$PWD/src/flisp" \
    BUILDING_HOST_TOOLS=1 XC_HOST="" CROSS_COMPILE="" \
    CC="gcc" CXX="g++" AR="ar" RANLIB="ranlib" \
    V=1 flisp 2>&1
```

---

## Trampas de Cross-Compilación

### MAKEOVERRIDES: El veneno silencioso

`MAKEOVERRIDES` es una variable especial de GNU Make que propaga variables marcadas con `override` a sub-makes. Es la causa del Bug #1.

**Mecanismo**:
```makefile
# Make.inc
override FOO=bar

# Cualquier sub-make (recursivo) heredará FOO=bar
# INCLUSO si invocas: make FOO=
```

**En Julia**: `override CROSS_COMPILE:=$(XC_HOST)-` hace que el host flisp herede CROSS_COMPILE aunque se pase `CROSS_COMPILE=""`.

### BUILDING_HOST_TOOLS: El escudo

Julia define `BUILDING_HOST_TOOLS` como una flag que los target-specific Makefiles pueden checkear. Nosotros la usamos en el guard:

```makefile
# En Make.inc (después de nuestros parches)
CROSS_COMPILE:=$(XC_HOST)-
ifeq ($(BUILDING_HOST_TOOLS),1)
override CROSS_COMPILE:=
XC_HOST:=
endif
```

Cuando compilamos host flisp con `BUILDING_HOST_TOOLS=1`, el guard resetea `CROSS_COMPILE` y `XC_HOST`.

### HOSTCC vs CC en Julia

Julia distingue entre:
- **`CC`**: Compilador para el **target** (cross-compilador, ej: `aarch64-linux-android-gcc`)
- **`HOSTCC`**: Compilador para el **host** (nativo, ej: `gcc`)

En `termux_step_make()`:
```bash
# Nota: termux_step_make() actualmente SALTÁ el make y solo toca timestamps
# (línea 435: echo "[build.sh] sysimage already built, skipping make")
# El build principal se ejecuta una sola vez y se cachea
```

**⚠️ Error común**: Olvidar `HOST_LDFLAGS=""` causa que las herramientas host se linken con librerías ARM64.

---

## Reglas para Añadir Nuevos Parches

### Formato correcto de sed

```bash
# ✅ Correcto (con protección):
sed -i 's/old/new/' archivo || echo "Warning: descripción del parche" >&2

# ✅ Correcto (para parches tentativos):
sed -i 's/old/new/' archivo 2>/dev/null || true

# ❌ Incorrecto (sin protección):
sed -i 's/old/new/' archivo
```

### Clasificación de parches

Cada nuevo parche debe:

1. **Tener un comentario** con letra/número y descripción:
   ```bash
   # H13: Fix [función] para bionic
   sed -i 's/.../.../' archivo || echo "Warning: H13 failed" >&2
   ```

2. **Usar la letra siguiente disponible**:
   - Dependencias: A-C
   - Linker flags: D-G, F1-F13
   - Configuración cross: H-K, L-P
   - Source code fixes: H0, H00-H12

3. **Parches externos** van en `packages/julia/patches/` y se copian en `termux_step_make()` (no en pre_configure)

### Orden de aplicación

Los parches se aplican en este orden en `termux_step_pre_configure()`:

1. **Dependencias de build** (A-C): LMDB, libuv cross, libuv pthread
2. **Linker flags** (D-G): -lpthread, -lrt, -latomic, -static-libstdc++
3. **Configuración** (H-K): ifunc, libc_nonshared, expmap, CROSS_COMPILE guard
4. **Libm/Android** (L-P): libm ALLOW_FAILURE
5. **Source code fixes** (H0-H12): bionic compat en archivos .c/.cpp
6. **Symlinks y configuración** (N-P): gmp, mpfr, LLVM, libpcre2, 7z, Make.user, Make.host.user

En `termux_step_make()`:
7. **Regeneración Make.user** (fallback si --continue)
8. **Symlinks de host** (libuv, libutf8proc)
9. **Copiar patches externos** (JLL files, sysimage.mk, bc2obj.sh)
10. **H10-H12**: sysimage -g0, julia-base-cache non-fatal, stringreplace fix

---

## Archivos del Repositorio

| Archivo | Propósito |
|---------|-----------|
| `packages/julia/build.sh` | Script de build principal (~462 líneas) |
| `packages/julia/patches/sysimage.mk` | sysimage.mk reescrito (H11: bc→obj pipeline) |
| `packages/julia/patches/bc2obj.sh` | Conversor bitcode→ELF object (H11) |
| `packages/julia/patches/jll/OpenBLAS_jll.jl` | JLL parcheado con try-catch (H09) |
| `packages/julia/patches/jll/libblastrampoline_jll.jl` | JLL parcheado con try-catch (H09) |
| `scripts/install-deps.sh` | Instala dependencias de Termux via pkg |
| `scripts/build-local.sh` | Build local sin Docker (usa tcr wrapper) |
| `scripts/make-pacman-pkg.sh` | Genera .pkg.tar.xz desde usr-staging de un build anterior |
| `.github/workflows/build-package.yml` | CI/CD principal (ubuntu-24.04, zram 16GB) |
| `.github/actions/zram/action.yml` | Acción composite para habilitar zram |
| `repo.json` | Configuración de repositorio Termux |

---

## Dependencias Problemáticas

### libuv: El caso especial

libuv es una dependencia especialmente problemática porque Julia usa un **fork propio** (rama `julia-uv2`) con parches específicos. No se puede usar la libuv del sistema.

**Problemas conocidos**:
1. **Cross-compilación**: `./configure` necesita `--host` y `--build` explícitos
2. **pthread_setcancelstate**: No disponible en bionic (parche C)
3. **MDB_USE_ROBUST**: No soportado en Android (parche A)

### LLVM: La dependencia más pesada

**⚠️ Actualmente se usa LLVM bundled** (`USE_SYSTEM_LLVM=0`). Las librerías LLVM del sistema se crean como symlinks en `usr/lib/` para que el linker las encuentre.

El build parchea `deps/llvm.mk` para deshabilitar `USE_PERF_JITEVENTS` (no disponible en Android).

### OpenBLAS

OpenBLAS requiere parches especiales:
- `deps/openblas.mk`: Se añade `CPPFLAGS=""` para que el sub-build Fortran no herede paths de C++ (H01ab)
- `deps/scratch/openblas-*/f_check`: Se parchea la detección de versión de GCC (puede no ser numérica en Termux)
- `patches/jll/OpenBLAS_jll.jl`: Se copia un JLL parcheado con try-catch alrededor de `dlopen` para evitar fallos si libgfortran no existe

---

## Diagnóstico de Fallos

### Patrones de error comunes

| Error | Causa más probable | Solución |
|-------|-------------------|----------|
| `flisp: cannot execute binary file` | CROSS_COMPILE leak (Bug #1) | Verificar guard BUILDING_HOST_TOOLS |
| `undefined reference to pthread_mutexattr_setrobust` | LMDB parche no aplicado | Verificar deps/lmdb.mk |
| `library not found for -lLLVM` | LLVM no instalado o llvm-config roto | Ejecutar install-deps.sh |
| `exec: "aarch64-linux-android-gcc": not found` | NDK no configurado | Verificar XC_HOST en Make.user |
| `relocation R_AARCH64_...` | Linker incorrecto | Usar LLD en vez de LD |
| `Error: could not load module libjulia` | sysimg.so no encontrado | Verificar install step |
| `Build error in deps/libuv.mk` | libuv configure falló | Verificar parches B y C |
| `Killed (OOM)` | RAM insuficiente | Reducir `-j`, habilitar zram |
| `stringreplace: offset is empty` | strings no encuentra patrón rpath | H12 stringreplace fix |

### Cómo leer un log de build de Julia

El log de build de Julia es enorme (~50,000+ líneas). Para encontrar el error real:

```bash
# 1. Buscar el primer error (no el último)
grep -n "error:" build.log | head -20

# 2. Buscar fallos en compilación
grep -n "make.*Error" build.log

# 3. Ver los últimos comandos antes del fallo
grep -n "make\[" build.log | tail -30

# 4. Buscar específicamente errores de linker
grep -n "undefined reference" build.log

# 5. Buscar errores de cross-compilación
grep -n "cannot execute binary" build.log
```

---

## Referencia Rápida

### Comandos de diagnóstico

```bash
# Verificar que los parches se aplicaron
grep "CROSS_COMPILE:" Make.inc
grep "BUILDING_HOST_TOOLS" Make.inc
grep "OSLIBS" Make.inc | head -5

# Verificar herramientas cross
which aarch64-linux-android-gcc || echo "No cross-compiler found"

# Verificar LLVM
llvm-config --version
llvm-config --libdir

# Verificar dependencias del sistema
ls $TERMUX_PREFIX/lib/libLLVM*
ls $TERMUX_PREFIX/lib/libopenblas*
ls $TERMUX_PREFIX/lib/libpcre2*

# Verificar workspace de build (TERMUX_TOPDIR)
du -sh ~/.termux-build/
du -sh ~/.termux-build/julia/src/deps/  # LLVM bundled + dependencias (~5-6 GB)
ls ~/.termux-build/julia/cache/          # Cache de descargas de Julia

# Cache de TMPDIR (build-local.sh usa /data/data/com.termux/files/usr/tmp)
du -sh ${TMPDIR:-/data/data/com.termux/files/usr/tmp}/
```

### Variables de entorno clave

| Variable | Propósito | Valor típico |
|----------|-----------|-------------|
| `TERMUX_PREFIX` | Prefijo de instalación Termux | `/data/data/com.termux/files/usr` |
| `TERMUX_TOPDIR` | Workspace de build de termux-packages | `$HOME/.termux-build` (contiene todo: src, deps, cache) |
| `TERMUX_PKG_MAKE_PROCESSES` | Paralelismo de make | `4` (default), `2` (si poca RAM) |
| `TERMUX_REPO_URL` | URL del repo Termux | `https://packages-cf.termux.dev/apt/termux-main` |
| `TERMUX_DOCKER_RUN_EXTRA_ARGS` | Args extra para Docker | `--volume /host/path:/container/path` |
| `XC_HOST` | Target triple | `aarch64-linux-android` |
| `CROSS_COMPILE` | Prefijo cross | `aarch64-linux-android-` |
| `TCR` | Wrapper para termux-packages | `~/.local/bin/tcr` |
| `TERMUX_PACKAGES_DIR` | Checkout de termux-packages | `~/.cache/julia-termux/termux-packages` |

---

## Resumen de Riesgos al Modificar

| Riesgo | Probabilidad | Impacto | Mitigación |
|--------|-------------|---------|------------|
| CROSS_COMPILE leak (Bug #1) | 85% | 🔴 Build completo falla | Siempre verificar guard |
| OOM durante compilación | 60% | 🔴 Build interrumpido | zram + -j reducido |
| sed falla silenciosa | 40% | 🟡 Parche no aplicado | Usar protecciones en sed |
| Versión de Julia cambia | 30% | 🟡 Patrones sed obsoletos | Verificar patrones al actualizar |
| LLVM no encontrado | 20% | 🔴 Link falla | Ejecutar install-deps.sh |
| libuv configure cambia | 15% | 🔴 libuv no compila | Verificar deps/libuv.mk |

---

> **Última actualización**: Agosto 2026 — Julia v1.12.6
>
> *Este archivo debe mantenerse actualizado cada vez que se modifique el build system. Cualquier agente AI que trabaje en este proyecto debe leer este archivo primero.*
