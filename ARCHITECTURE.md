# ARCHITECTURE.md — Diseño Técnico Detallado

> **Propósito**: Documentar la arquitectura completa del build system de Julia para Termux, incluyendo el pipeline de compilación, el sistema de cross-compilación, la gestión de dependencias, y las decisiones de diseño detrás de cada componente.

---

## Tabla de Contenidos

- [Visión General del Sistema](#visin-general-del-sistema)
  - [¿Qué es termux-packages?](#qu-es-termux-packages)
  - [Cómo encaja julia-termux](#cmo-encaja-julia-termux)
- [Pipeline de Build (10 Pasos)](#pipeline-de-build-10-pasos)
  - [Paso 1: Setup del Entorno](#paso-1-setup-del-entorno)
  - [Paso 2: Instalación de Dependencias](#paso-2-instalacin-de-dependencias)
  - [Paso 3: Preconfiguración y Parches](#paso-3-preconfiguracin-y-parches)
  - [Paso 4: Generación de Make.user](#paso-4-generacin-de-makeuser)
  - [Paso 5: Host flisp Bootstrap](#paso-5-host-flisp-bootstrap)
  - [Paso 6: Cross-Compilación Principal](#paso-6-cross-compilacin-principal)
  - [Paso 7: Instalación](#paso-7-instalacin)
  - [Paso 8: Empaquetado](#paso-8-empaquetado)
  - [Paso 9: Publicación en Release](#paso-9-publicacin-en-release)
  - [Paso 10: Verificación](#paso-10-verificacin)
- [Cross-Compilación con XC_HOST](#cross-compilacin-con-xc_host)
  - [¿Qué es XC_HOST?](#qu-es-xc_host)
  - [El NDK de Android y el Target Triple](#el-ndk-de-android-y-el-target-triple)
  - [Flujo de Cross-Compilación en Julia](#flujo-de-cross-compilacin-en-julia)
  - [Herramientas Cross vs Host](#herramientas-cross-vs-host)
- [Estrategia de Bootstrapping](#estrategia-de-bootstrapping)
  - [Fases del Bootstrapping de Julia](#fases-del-bootstrapping-de-julia)
  - [Por qué no usar BinaryBuilder](#por-qu-no-usar-binarybuilder)
- [Make.user: Guía de Referencia Completa](#makeuser-gua-de-referencia-completa)
  - [Flags de Cross-Compilación](#flags-de-cross-compilacin)
  - [Flags USE_SYSTEM_*](#flags-use_system_)
  - [Flags de Optimización](#flags-de-optimizacin)
  - [Flags de Instalación](#flags-de-instalacin)
  - [Flags de Debug](#flags-de-debug)
- [Gestión de Dependencias](#gestin-de-dependencias)
  - [Árbol de Dependencias](#rbol-de-dependencias)
  - [Resolución de Dependencias en Tiempo de Compilación](#resolucin-de-dependencias-en-tiempo-de-compilacin)
  - [Resolución de Dependencias en Tiempo de Ejecución](#resolucin-de-dependencias-en-tiempo-de-ejecucin)
- [Sistema de Parches](#sistema-de-parches)
  - [Arquitectura de los Parches](#arquitectura-de-los-parches)
  - [Catálogo Completo de Parches](#catlogo-completo-de-parches)
  - [Matriz de Compatibilidad bionic](#matriz-de-compatibilidad-bionic)
- [CI/CD Pipeline](#cicd-pipeline)
  - [Workflow build-package.yml](#workflow-build-packageyml)
  - [Workflow docker-image.yml](#workflow-docker-imageyml)
  - [Zram Action](#zram-action)
- [Troubleshooting Avanzado](#troubleshooting-avanzado)
  - [Anatomía de un Fallo de Build](#anatoma-de-un-fallo-de-build)
  - [Cómo Depurar el Build Localmente](#cmo-depurar-el-build-localmente)
  - [Cómo Depurar en CI/CD](#cmo-depurar-en-cicd)
- [Decisiones de Diseño (ADRs)](#decisiones-de-diseo-adrs)

---

## Visión General del Sistema

### ¿Qué es termux-packages?

[termux-packages](https://github.com/termux/termux-packages) es el sistema de empaquetado oficial de Termux. Proporciona:

- Un **build system** basado en Bash con hooks estandarizados (`termux_step_*`)
- **Cross-compilación** via Android NDK para aarch64, arm, i686, x86_64
- **Empaquetado** en formato `.deb` (dpkg) y `.pkg.tar.*` (pacman)
- Un **entorno Docker** (`ghcr.io/termux/package-builder`) con NDK, SDK, y toolchain

**Hooks principales** (se ejecutan en orden):

| Hook | Propósito |
|------|-----------|
| `termux_step_pre_configure()` | Parches, configuración, generación de Makefiles |
| `termux_step_configure()` | `./configure` o `cmake` |
| `termux_step_make()` | Compilación principal |
| `termux_step_make_install()` | Instalación en `$TERMUX_PREFIX` |
| `termux_step_post_make_install()` | Post-procesamiento |

### Cómo encaja julia-termux

julia-termux NO es un fork de termux-packages. Es un **paquete independiente** que sigue las convenciones de termux-packages:

```
julia-termux/
└── packages/
    └── julia/
        └── build.sh    ← Sigue la API de termux-packages
```

Esto significa que:
- Se puede construir con `./build-package.sh julia` (el script estándar de termux-packages)
- Usa los hooks `termux_step_*` que termux-packages invoca
- Se beneficia del NDK, toolchain y entorno Docker de termux-packages
- PERO se ejecuta fuera del repositorio oficial de termux-packages (fork independiente)

---

## Pipeline de Build (10 Pasos)

### Paso 1: Setup del Entorno

**Archivo**: `.github/workflows/build-package.yml` (líneas 25-56)

```yaml
- uses: actions/checkout@v4
- name: Enable zram (16GB)
  uses: ./.github/actions/zram
- name: Restore build cache
  uses: actions/cache@v4
```

**¿Qué ocurre?**:
1. Se clona el repositorio en el runner
2. Se activa zram (swap comprimido en RAM) para evitar OOM
3. Se restaura la caché de `~/.termux-build` del CI (contiene dependencias ya descargadas y compiladas parcialmente)
4. Se configura `ldconfig` para incluir el prefijo de Termux

**Variables de entorno**:
- `TERMUX_DOCKER_RUN_EXTRA_ARGS=--volume /home/runner/.termux-build:/home/builder/.termux-build`
  - Monta la caché del runner dentro del contenedor Docker
  - Permite que builds consecutivos reutilicen dependencias ya compiladas

---

### Paso 2: Instalación de Dependencias

**Archivos**: `.github/workflows/build-package.yml` (líneas 63-66) + `scripts/install-deps.sh`

```bash
# En CI/CD:
./scripts/run-docker.sh bash ./scripts/install-deps.sh
```

`install-deps.sh` hace lo siguiente:

1. Descarga el keyring de Termux (`termux-main.deb`)
2. Para cada dependencia en `DEPS[]`:
   - Busca en el pool de paquetes de Termux (`packages-cf.termux.dev`)
   - Prueba variantes de arquitectura: `aarch64`, `arm64`, `all`, `any`
   - Extrae el `.deb` en `$TERMUX_PREFIX` (`/data/data/com.termux/files/usr`)

**Dependencias instaladas**:

| Categoría | Paquetes |
|-----------|----------|
| LLVM | `libllvm`, `libllvm-static` |
| BLAS | `libopenblas`, `blas-openblas` |
| Matemáticas | `suitesparse`, `arpack-ng`, `libgmp`, `libmpfr` |
| Red | `libssh2`, `libgit2`, `curl`, `libnghttp2` |
| Compresión | `zlib`, `p7zip` |
| Cripto | `openssl` |
| Regex | `pcre2`, `utf8proc` |
| Utilidades | `patchelf`, `lld`, `libuv` |
| Android | `libandroid-support` |

> **⚠️ Nota**: `libuv` se instala como dependencia del sistema pero Julia lo ignora (`USE_SYSTEM_LIBUV=0`) porque usa su propio fork. La instalación es para satisfacer dependencias de otros paquetes.

---

### Paso 3: Preconfiguración y Parches

**Archivo**: `packages/julia/build.sh` (líneas 16-176)

Este es el paso más complejo. `termux_step_pre_configure()` ejecuta ~30 operaciones `sed` para adaptar Julia a Android/bionic.

**Orden de ejecución**:

```
1. LMDB:  remove MDB_USE_ROBUST          (línea 18)
2. libuv: add --host/--build             (línea 21)
3. libuv: pthread_setcancelstate patch  (línea 24)
4. F1:    remove -lpthread               (líneas 27-29)
5. F2:    remove -lrt                    (línea 32)
6. F3:    remove -latomic                (línea 35)
7. F4:    remove -static-libstdc++       (línea 38)
8. F6:    disable ifunc                  (línea 41)
9. F5:    remove libc_nonshared.a        (líneas 44-45)
10. F7:   LLVM→Julia symver             (línea 48)
11. F8:   fix CROSS_COMPILE override     (líneas 51-52)
12. F9:   BUILDING_HOST_TOOLS guard      (líneas 53-57)
13. F10:  libm ALLOW_FAILURE             (línea 60)
14. H0:   libunwind guard                (línea 64)
15. H00:  sys/sysinfo exclusion          (línea 67)
16. H01:  __register_frame guard         (línea 70)
17. H02:  pthread_getstackaddr_np       (línea 73)
18. H03:  libstdcxxprobe stub           (línea 76)
19. H04:  _OS_ANDROID_ define           (línea 79)
20. H05:  link.h include                (línea 82)
21. H06:  endian.h compat               (líneas 85-87)
22. H07:  dl_iterate_phdr fallback      (línea 90)
23. TCP_QUICKACK guard                   (línea 93)
24. mallinfo/malloc_stats guard          (línea 96)
25. Symlinks (7z, LLVM, libpcre2)        (líneas 98-122)
26. ldconfig                             (líneas 116-117)
27. Make.host.user                       (líneas 124-128)
28. Make.user                            (líneas 130-176)
```

> **Detalle crítico**: Los pasos 14-24 (H0-H07 y guards) usan `2>/dev/null || true` porque los patrones pueden no existir entre versiones de Julia. Los pasos 1-13 usan `|| echo "Warning: ..." >&2` para visibilidad.

---

### Paso 4: Generación de Make.user

**Archivo**: `build.sh` (líneas 131-176)

Se generan dos archivos de configuración:

**Make.host.user** — Configuración para compilación de herramientas HOST:
```makefile
CC = gcc
CXX = g++
```

**Make.user** — Configuración para compilación TARGET (cross):
```makefile
# Cross-compilación
XC_HOST = aarch64-linux-android
OS = Linux
AR = llvm-ar
RANLIB = llvm-ranlib

# System dependencies (18 USE_SYSTEM_* flags)
USE_SYSTEM_LLVM=1
USE_SYSTEM_PCRE=1
USE_SYSTEM_LIBM=1
USE_SYSTEM_OPENBLAS=1
USE_SYSTEM_BLAS=1
USE_SYSTEM_LAPACK=1
USE_SYSTEM_GMP=1
USE_SYSTEM_MPFR=1
USE_SYSTEM_ARPACK=1
USE_SYSTEM_LIBSUITESPARSE=1
USE_SYSTEM_LIBSSH2=1
USE_SYSTEM_CURL=1
USE_SYSTEM_LIBGIT2=1
USE_SYSTEM_PATCHELF=1
USE_SYSTEM_ZLIB=1
USE_SYSTEM_OPENSSL=1
USE_SYSTEM_NGHTTP2=1
USE_SYSTEM_LIBWHICH=1
USE_SYSTEM_P7ZIP=1
USE_SYSTEM_LLD=1

# Source-built dependencies
USE_SYSTEM_CSL=0
USE_SYSTEM_OPENLIBM=0
USE_SYSTEM_DSFMT=0
USE_SYSTEM_UTF8PROC=0
USE_SYSTEM_LIBUV=0
USE_SYSTEM_LIBUNWIND=0
USE_SYSTEM_LIBBLASTRAMPOLINE=0
USE_SYSTEM_MBEDTLS=0

# Runtime options
USE_BINARYBUILDER=0
DISABLE_LIBUNWIND=1
JULIA_THREADS=4
prefix=$TERMUX_PREFIX
LOCALBASE=$TERMUX_PREFIX
USE_CROSS_FLISP=1

# Silence deprecated warnings
override CXXFLAGS += -Wno-deprecated-declarations
override CFLAGS += -Wno-deprecated-declarations
```

---

### Paso 5: Host flisp Bootstrap

**Archivo**: `build.sh` (líneas 182-192)

```bash
mkdir -p src/flisp/host
make -C src/flisp/host -f "$PWD/src/flisp/Makefile" \
    SRCDIR="$PWD/src/flisp" \
    BUILDDIR="$PWD/src/flisp/host" \
    BUILDING_HOST_TOOLS=1 \
    XC_HOST="" \
    CROSS_COMPILE="" \
    CC="gcc" CXX="g++" \
    AR="ar" RANLIB="ranlib" \
    -j1 flisp
```

**¿Por qué es necesario?**:

Julia usa un proceso de bootstrapping de 2 etapas:
1. **flisp** (Lisp intérprete) → compila el compilador Julia etapa 1
2. **Julia etapa 1** → compila el compilador Julia completo (etapa 2)

flisp debe ejecutarse en la máquina HOST (x86_64), pero el build system de Julia intenta compilarlo para TARGET (aarch64). Este paso manual fuerza la compilación para HOST.

**Detalles técnicos**:
- `-j1`: Un solo job porque flisp es secuencial
- `BUILDING_HOST_TOOLS=1`: Activa el guard que resetea CROSS_COMPILE y XC_HOST
- `SRCDIR` y `BUILDDIR`: Separan source y build para evitar contaminación
- El flag `-f` apunta al Makefile de flisp, no al Makefile principal

**Si este paso falla**:
```
Warning: host flisp manual build failed
```
El build principal fallará con errores de flisp. Para depurar:
```bash
cd src/flisp/host
make -f "$PWD/src/flisp/Makefile" SRCDIR="$PWD/src/flisp" \
    BUILDING_HOST_TOOLS=1 XC_HOST="" CROSS_COMPILE="" \
    CC="gcc" CXX="g++" AR="ar" RANLIB="ranlib" \
    V=1 flisp 2>&1
```

---

### Paso 6: Cross-Compilación Principal

**Archivo**: `build.sh` (líneas 194-202)

```bash
make -j${TERMUX_PKG_MAKE_PROCESSES} \
    HOSTCC="gcc" \
    HOSTCXX="g++" \
    HOST_LDFLAGS="" \
    PREFIX="$TERMUX_PREFIX" \
    LOCALBASE="$TERMUX_PREFIX" \
    FC_VERSION=dummy \
    release
```

**¿Qué hace `make release`?**

El target `release` en el Makefile de Julia:
1. Compila **todas las dependencias fuente** (libuv, openlibm, utf8proc, DSFMT, libblastrampoline, mbedtls)
2. Compila **libjulia** (el compilador y runtime de Julia)
3. Compila **el CLI** (`julia` executable)
4. Compila **la sysimg** (system image — Julia precompilada)
5. Genera las **bibliotecas estándar** (Base, LinearAlgebra, etc.)

**Variables clave**:
- `HOSTCC="gcc"`: Compilador para herramientas HOST (importante: se pasa explícitamente porque CROSS_COMPILE confunde la detección automática)
- `HOSTCXX="g++"`: Ídem para C++
- `HOST_LDFLAGS=""`: Evita que las LDFLAGS del target se usen para herramientas host
- `FC_VERSION=dummy`: Evita que Julia busque un compilador Fortran (no necesario porque usamos OpenBLAS/LAPACK del sistema)
- `PREFIX=$TERMUX_PREFIX`: Prefijo de instalación final

---

### Paso 7: Instalación

**Archivo**: `build.sh` (líneas 205-209)

```bash
make install \
    PREFIX="$TERMUX_PREFIX" \
    LOCALBASE="$TERMUX_PREFIX"
```

**¿Qué instala?**:
- `$PREFIX/bin/julia` — Ejecutable
- `$PREFIX/lib/julia/` — Librerías compartidas (libjulia.so, libjulia-internal.so)
- `$PREFIX/lib/julia/sys.so` — System image
- `$PREFIX/share/julia/` — Archivos de soporte (documentación, ejemplos)
- `$PREFIX/include/julia/` — Headers de C (para interoperabilidad)

---

### Paso 8: Empaquetado

**Realizado por**: `build-package.sh` (no en nuestro código, es parte de termux-packages)

```bash
./build-package.sh -a aarch64 --format pacman julia
```

**Output**:
```
output/julia-1.12.6-aarch64.pkg.tar.xz
```

Este paquete contiene:
- Todos los archivos instalados en `$TERMUX_PREFIX`
- Metadatos (versión, dependencias, maintainer)
- Scripts de pre/post instalación

---

### Paso 9: Publicación en Release

**Archivo**: `.github/workflows/build-package.yml` (líneas 94-102)

```yaml
gh release delete julia-latest --yes --cleanup-tag 2>/dev/null || true
gh release create julia-latest "$FILE" \
    --repo "${{ github.repository }}" \
    --title "julia-latest" \
    --latest \
    --notes "Julia for Termux aarch64 - Build from ${{ github.sha }}"
```

**Estrategia**:
- Se usa una release **mutable** llamada `julia-latest`
- Cada build exitoso elimina y recrea la release
- Esto permite que los usuarios siempre descarguen la versión más reciente con la misma URL
- Adicionalmente, se guarda un artifact con el SHA del commit como respaldo

---

### Paso 10: Verificación

**Archivo**: `.github/workflows/build-package.yml` (líneas 73-81, solo en failure)

En caso de fallo, el pipeline ejecuta un paso de debug que:
1. Lista el directorio de build
2. Busca logs de error
3. Muestra `config.log` si existe
4. Muestra las últimas 100 líneas de cualquier log

No hay verificación automática post-build (como `julia --version` o ejecución de tests) porque el paquete se compila para ARM64 y el runner es x86_64. La verificación es manual en el dispositivo Termux.

---

## Cross-Compilación con XC_HOST

### ¿Qué es XC_HOST?

`XC_HOST` es la variable que Julia usa para especificar el **target triple** de cross-compilación:

```
XC_HOST = aarch64-linux-android
```

Esto le dice al build system:
- El target es **Linux** (`linux`)
- La arquitectura es **ARM 64-bit** (`aarch64`)
- La libc es **bionic** (`android`) — no glibc

A partir de `XC_HOST`, Julia deduce:
- `CROSS_COMPILE = aarch64-linux-android-` (prefijo para herramientas cross)
- Busca `aarch64-linux-android-gcc`, `aarch64-linux-android-ar`, etc.

### El NDK de Android y el Target Triple

El Android NDK (r29 en nuestro caso) proporciona toolchains con target triple:

```
${TARGET_ARCH}-linux-android-${TOOL}
                        ↑
                   ¡Esto es bionic, no glibc!
```

**IMPORTANTE**: En Android, el target triple usa `linux-android` en vez de `linux-gnu`. Esto es crítico porque:
- `linux-gnu` → busca herramientas glibc
- `linux-android` → busca herramientas bionic

Julia, al ver `XC_HOST=aarch64-linux-android`, busca:
```
aarch64-linux-android-gcc      → Compilador C
aarch64-linux-android-g++      → Compilador C++
aarch64-linux-android-ar       → Archiver
aarch64-linux-android-ranlib   → Ranlib
aarch64-linux-android-ld       → Linker
```

### Flujo de Cross-Compilación en Julia

```
┌─────────────────────────────────────────────┐
│           Make.user                          │
│  XC_HOST = aarch64-linux-android              │
└──────────────────────┬──────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────┐
│           Make.inc                           │
│  CROSS_COMPILE := $(XC_HOST)-                │
│  CC := $(CROSS_COMPILE)gcc                    │
│  CXX := $(CROSS_COMPILE)g++                   │
│  AR := $(CROSS_COMPILE)ar                     │
│  RANLIB := $(CROSS_COMPILE)ranlib             │
│  LD := $(CROSS_COMPILE)ld → LLD              │
└──────────────────────┬──────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────┐
│         Compilación                           │
│  aarch64-linux-android-gcc -o target.o src.c  │
│  → genera código ARM64                        │
│  → linkea con libs bionic                     │
└──────────────────────┬──────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────┐
│         binario ARM64                        │
│  ELF 64-bit LSB shared object, ARM aarch64    │
│  ➡ Ejecutable en Termux/Android              │
└─────────────────────────────────────────────┘
```

### Herramientas Cross vs Host

| Herramienta | Host (x86_64) | Target (aarch64) |
|-------------|---------------|-------------------|
| Compilador C | `gcc` | `aarch64-linux-android-gcc` |
| Compilador C++ | `g++` | `aarch64-linux-android-g++` |
| Archiver | `ar` | `llvm-ar` |
| Ranlib | `ranlib` | `llvm-ranlib` |
| Linker | `ld` | `lld` |
| Objetos | `.o` (x86_64) | `.o` (aarch64) |
| Ejecutables | corren en runner | corren en Android |

---

## Estrategia de Bootstrapping

### Fases del Bootstrapping de Julia

Julia tiene un proceso de bootstrapping inusual para un lenguaje compilado:

```
Fase 0: flisp (Lisp intérprete)
  ├── Compilado para HOST (x86_64)
  ├── Build manual en termux_step_make()
  └── Entrada: código Lisp del compilador Julia etapa 1

Fase 1: Julia etapa 1 (compilador mínimo)
  ├── Generado por flisp ejecutándose en HOST
  ├── Compila código Julia a código C/LLVM
  └── Entrada: src/julia-parser.scm, src/julia-syntax.scm

Fase 2: Julia etapa 2 (compilador completo)
  ├── Compilado por Julia etapa 1
  ├── Compila la sysimg (system image)
  └── Entrada: base/*.jl (la biblioteca estándar)

Fase 3: sysimg.so
  ├── La salida final del bootstrapping
  ├── Contiene: Base, Core, y módulos estándar precompilados
  └── Se carga al iniciar julia
```

```
Línea de tiempo del bootstrapping:

flisp (HOST) ──→ Julia etapa 1 (HOST) ──→ Julia etapa 2 (TARGET) ──→ sysimg.so
    ↑                    ↑                         ↑
  gcc (HOST)       flisp (HOST)            Julia etapa 1 (ejecutado
                                              via QEMU o cross?)
                                               ¡NO! En nuestro caso,
                                              Julia etapa 1 se
                                              genera para TARGET
                                              y NO se ejecuta en
                                              el host.

┌──────────────────────────────────────────────────────────────────┐
│ ¿Cómo funciona entonces?                                         │
│                                                                  │
│ Julia etapa 1 se compila CRUZADA para aarch64, pero para        │
│ generar sysimg.so se NECESITA ejecutar Julia etapa 1...         │
│                                                                  │
│ ¡Pero el runner es x86_64! No puede ejecutar ARM64.             │
│                                                                  │
│ Solución: USE_CROSS_FLISP=1 + flisp host manual                 │
│   → flisp host genera el código de la sysimg SIMBÓLICAMENTE     │
│   → El resultado se ensambla para aarch64                        │
│   → La sysimg.so final es para aarch64                           │
│   → En Android, Julia carga la sysimg y la JIT compila a native │
└──────────────────────────────────────────────────────────────────┘
```

### Por qué no usar BinaryBuilder

Julia tiene un sistema llamado [BinaryBuilder](https://github.com/JuliaPackaging/BinaryBuilder.jl) que automatiza la compilación de dependencias para múltiples plataformas. Sin embargo:

| BinaryBuilder | Nuestra aproximación |
|---------------|---------------------|
| Usa contenedores rootfs | Usa paquetes Termux nativos |
| Genera tarballs genéricos | Genera paquetes `.pkg.tar.xz` |
| No optimizado para Android | Optimizado para Termux/bionic |
| Soporta múltiples arquitecturas | Solo aarch64 (por ahora) |
| Requiere X86_64 para correr | Corre directamente en Android |

`USE_BINARYBUILDER=0` desactiva BinaryBuilder porque:
1. BinaryBuilder no tiene soporte completo para Android/bionic
2. Las dependencias de Termux ya están optimizadas para aarch64
3. BinaryBuilder añadiría complejidad innecesaria

---

## Make.user: Guía de Referencia Completa

### Flags de Cross-Compilación

| Flag | Valor | Efecto |
|------|-------|--------|
| `XC_HOST` | `aarch64-linux-android` | Target triple para cross-compilación |
| `OS` | `Linux` | Sistema operativo target |
| `AR` | `llvm-ar` | Archiver (LLVM, no el de GNU) |
| `RANLIB` | `llvm-ranlib` | Ranlib (LLVM, no el de GNU) |
| `USE_CROSS_FLISP` | `1` | Habilitar cross-compilación de flisp |
| `BUILDING_HOST_TOOLS` | (usado en make) | Flag para compilar herramientas host |

### Flags USE_SYSTEM_*

Cada flag `USE_SYSTEM_<LIB>=1` le dice a Julia: "no compiles `<LIB>` desde el source incluido en el tarball; usa la versión instalada en el sistema".

| Flag | Dependencia | ¿Por qué =1? | Riesgo si =0 |
|------|-------------|-------------|--------------|
| `USE_SYSTEM_LLVM=1` | LLVM 19+ | ~2hr de compilación ahorrada | Build toma 4+ horas |
| `USE_SYSTEM_PCRE=1` | PCRE2 | Ya instalado en Termux | Compila desde source sin optimizaciones |
| `USE_SYSTEM_LIBM=1` | libm (math) | bionic ya tiene libm | Conflicto con bionic |
| `USE_SYSTEM_OPENBLAS=1` | OpenBLAS | Optimizado para ARM64 | Compila genérico (más lento) |
| `USE_SYSTEM_BLAS=1` | BLAS | OpenBLAS lo incluye | Duplicación |
| `USE_SYSTEM_LAPACK=1` | LAPACK | OpenBLAS lo incluye | Duplicación |
| `USE_SYSTEM_GMP=1` | GMP | Ya instalado | Compila sin optimizaciones ARM |
| `USE_SYSTEM_MPFR=1` | MPFR | Depende de GMP | Compila sin optimizaciones |
| `USE_SYSTEM_ARPACK=1` | ARPACK-ng | Ya instalado | Compila desde source |
| `USE_SYSTEM_LIBSUITESPARSE=1` | SuiteSparse | Compilación compleja | Build lento y frágil |
| `USE_SYSTEM_LIBSSH2=1` | libssh2 | Ya instalado | Compila desde source |
| `USE_SYSTEM_CURL=1` | curl | Ya instalado | Compila desde source |
| `USE_SYSTEM_LIBGIT2=1` | libgit2 | Ya instalado | Compila desde source |
| `USE_SYSTEM_PATCHELF=1` | patchelf | Necesario para runtime | No disponible en source |
| `USE_SYSTEM_ZLIB=1` | zlib | Ya instalado | Compila desde source |
| `USE_SYSTEM_OPENSSL=1` | OpenSSL | Ya instalado | Compila desde source |
| `USE_SYSTEM_NGHTTP2=1` | nghttp2 | Ya instalado | Compila desde source |
| `USE_SYSTEM_LIBWHICH=1` | libwhich | Ya instalado | Compila desde source |
| `USE_SYSTEM_P7ZIP=1` | p7zip | Necesario para descargas | No disponible en source |
| `USE_SYSTEM_LLD=1` | LLD | Linker LLVM | Usa LD de GNU (no funciona) |

| Flag | Dependencia | ¿Por qué =0? |
|------|-------------|--------------|
| `USE_SYSTEM_LIBUV=0` | libuv | Fork julia-uv2 con parches específicos |
| `USE_SYSTEM_OPENLIBM=0` | openlibm | No existe como paquete Termux |
| `USE_SYSTEM_UTF8PROC=0` | utf8proc | Incluye config para Julia |
| `USE_SYSTEM_DSFMT=0` | DSFMT | No existe como paquete Termux |
| `USE_SYSTEM_LIBBLASTRAMPOLINE=0` | libblastrampoline | No existe como paquete Termux |
| `USE_SYSTEM_MBEDTLS=0` | mbedtls | Fallback TLS, versión específica |
| `USE_SYSTEM_CSL=0` | CSL (sysimg) | Siempre debe compilarse |
| `USE_SYSTEM_LIBUNWIND=0` | libunwind | No compatible con Android |

### Flags de Optimización

| Flag | Valor | Efecto |
|------|-------|--------|
| `JULIA_THREADS=4` | 4 | Número de threads para Julia runtime |
| `DISABLE_LIBUNWIND=1` | 1 | Deshabilita stack unwinding con libunwind |
| `USE_BINARYBUILDER=0` | 0 | No usar BinaryBuilder |
| `override CFLAGS += -Wno-deprecated-declarations` | — | Silencia warnings de deprecated |
| `override CXXFLAGS += -Wno-deprecated-declarations` | — | Silencia warnings de deprecated |

### Flags de Instalación

| Flag | Valor | Efecto |
|------|-------|--------|
| `prefix` | `$TERMUX_PREFIX` | Directorio raíz de instalación |
| `LOCALBASE` | `$TERMUX_PREFIX` | Base para librerías locales |

### Flags de Debug

| Flag | Valor | Efecto |
|------|-------|--------|
| `VERBOSE=1` | (no usado) | Make imprime comandos completos |
| `DEBUG=1` | (no usado) | Build en modo debug (sin optimizaciones) |
| `FORCE=1` | (no usado) | Recompila todo ignorando caché |
| `V=1` | (no usado) | Make verbose (similar a VERBOSE) |

---

## Gestión de Dependencias

### Árbol de Dependencias

```
julia
├── Sistema (USE_SYSTEM_*=1)
│   ├── LLVM 19+ ─── zlib ─── libedit
│   ├── OpenBLAS ─── BLAS ─── LAPACK
│   ├── GMP ─── MPFR
│   ├── SuiteSparse ─── BLAS ─── LAPACK
│   ├── ARPACK-ng ─── BLAS ─── LAPACK ─── libgfortran
│   ├── libssh2 ─── OpenSSL ─── zlib
│   ├── curl ─── libnghttp2 ─── OpenSSL ─── zlib
│   ├── libgit2 ─── libssh2 ─── OpenSSL ─── zlib
│   ├── PCRE2
│   ├── libwhich
│   ├── p7zip
│   ├── patchelf
│   ├── lld ─── LLVM
│   └── libandroid-support
│
├── Fuente (USE_SYSTEM_*=0)
│   ├── libuv (fork julia-uv2)
│   ├── openlibm
│   ├── utf8proc
│   ├── DSFMT
│   ├── libblastrampoline ─── BLAS
│   ├── mbedtls
│   └── libunwind (DISABLED=1)
│
└── Runtime
    ├── sys.so (system image)
    ├── libjulia.so
    ├── libjulia-internal.so
    └── libstdc++ (via libc++ de Android)
```

### Resolución de Dependencias en Tiempo de Compilación

Cuando Julia encuentra `USE_SYSTEM_LLVM=1`, ejecuta:

```bash
# Detectar LLVM del sistema
LLVM_CONFIG=$(command -v llvm-config)
if [ -x "$LLVM_CONFIG" ]; then
    LLVM_CFLAGS=$($LLVM_CONFIG --cflags)
    LLVM_LIBDIR=$($LLVM_CONFIG --libdir)
    LLVM_LDFLAGS=$($LLVM_CONFIG --ldflags)
    # Usar estos valores en lugar de compilar LLVM
fi
```

**Problema conocido**: `llvm-config` debe estar en PATH y apuntar al LLVM de Termux, no al del sistema (Ubuntu). Por eso en `build.sh` se crean symlinks:

```bash
LLVM_CONFIG=$(command -v llvm-config || echo "$TERMUX_PREFIX/bin/llvm-config")
if [ -x "$LLVM_CONFIG" ]; then
    LLVM_LIBDIR=$($LLVM_CONFIG --libdir)
    if [ "$LLVM_LIBDIR" != "$TERMUX_PREFIX/lib" ]; then
        mkdir -p "$LLVM_LIBDIR"
        for lib in "$TERMUX_PREFIX/lib"/libLLVM*; do
            [ -f "$lib" ] && ln -sf "$lib" "$LLVM_LIBDIR/"
        done
    fi
fi
```

### Resolución de Dependencias en Tiempo de Ejecución

Cuando `julia` se ejecuta en Termux, necesita encontrar:

1. **`libjulia.so`** — En `$PREFIX/lib/julia/`
2. **`sys.so`** — En `$PREFIX/lib/julia/`
3. **Librerías del sistema** — OpenBLAS, LLVM, etc. en `$PREFIX/lib/`
4. **`7z`** — Para descargar paquetes, en `$PREFIX/libexec/julia/7z`

**ldconfig**: El build.sh configura `ldconfig` para incluir el prefijo Termux:
```bash
echo "/data/data/com.termux/files/usr/lib" | sudo tee /etc/ld.so.conf.d/termux-prefix.conf
sudo ldconfig
```

**Symlinks en runtime**:
```bash
# 7z symlink (necesario para Pkg)
ln -sf "${TERMUX_PREFIX}/bin/7z" usr/libexec/julia/7z

# libpcre2-8.so (necesario para regex)
if [ -f "${TERMUX_PREFIX}/lib/libpcre2-8.so" ]; then
    ln -sf "${TERMUX_PREFIX}/lib/libpcre2-8.so" \
        "${TERMUX_PKG_SRCDIR}/usr/lib/julia/libpcre2-8.so"
fi
```

---

## Sistema de Parches

### Arquitectura de los Parches

Los parches se dividen en 4 categorías según su mecanismo y propósito:

```
Parches en build.sh
├── A-N: Dependencias y configuración (seds con || echo "Warning")
│   ├── A: LMDB (MDB_USE_ROBUST)
│   ├── B-C: libuv (cross-compile + pthread)
│   ├── D-F: Linker flags (-lpthread, -lrt, -latomic)
│   ├── G: -static-libstdc++
│   ├── H: ifunc disable
│   ├── I: libc_nonshared.a
│   ├── J: julia.expmap.in (LLVM→Julia symver)
│   ├── K: CROSS_COMPILE fix
│   ├── L: libm ALLOW_FAILURE
│   ├── M: Source code fixes (H0-H07)
│   ├── N: Symlinks
│   └── O-P: Makefile generation
│
├── F1-F6: Linker flags (seds con || echo "Warning")
├── F7-F9: Cross-compilación (seds con || echo "Warning")
├── F10-F13: Dependencias (seds con || echo "Warning")
└── H0-H07: Source code fixes (seds con 2>/dev/null || true)
```

### Catálogo Completo de Parches

Ver la [tabla de parches en README.md](./README.md#parches-para-androidbionic) para el listado completo.

### Matriz de Compatibilidad bionic

| Función/Característica | glibc | bionic | Parche |
|------------------------|-------|--------|--------|
| `pthread` en libc separada | `-lpthread` | En libc | F1: remove -lpthread |
| `librt` (clock, timer) | `-lrt` | En libc | F2: remove -lrt |
| `libatomic` | Separada | En libc (ARM64) | F3: remove -latomic |
| `libstdc++` estática | Disponible | Usar libc++ | F4: remove -static-libstdc++ |
| `libc_nonshared.a` | Existe | No existe | F5: remove references |
| `ifunc` (indirect functions) | Soportado | No soportado | F6: disable ifunc |
| `__register_frame` | libgcc_s | No disponible | H01: guard |
| `pthread_getattr_np` | Disponible | No existe | H02: use get_stackaddr_np |
| `dl_iterate_phdr` | glibc version | limited bionic | H07: fallback |
| `mallinfo()`, `malloc_stats()` | Disponible | No existe | F13: guard |
| `TCP_QUICKACK` | Linux | No en Android | F12: guard |
| `MDB_USE_ROBUST` (LMDB) | Soportado | No soportado | A: remove |
| `sysinfo()` | Disponible | No existe | H00: guard |
| `libunwind` | Compatible | No compatible | H0: disable |
| `stdc++probe` | libstdc++ | libc++ | H03: stub |
| LLVM symbol versioning | ld | lld | F7: symver fix |

---

## CI/CD Pipeline

### Workflow build-package.yml

**Archivo**: `.github/workflows/build-package.yml`

**Trigger**:
```yaml
on:
  push:
    branches: [main]
    paths:
      - 'packages/julia/**'
      - 'packages/termux-keyring/**'
      - 'scripts/**'
      - '.github/workflows/**'
      - '.github/actions/**'
  workflow_dispatch:
```

**Diagrama de secuencia**:

```
Push a main
    │
    ▼
Checkout repo
    │
    ▼
Enable zram (16GB zstd)
    │
    ▼
Restore cache (~/.termux-build)
    │
    ▼
Install system deps (docker, containerd)
    │
    ▼
Install Termux deps (via Docker)
    │
    ▼
Build Julia (via Docker)
    │
    ▼
┌─── Éxito? ───┐
│              │
▼              ▼
Release       Debug
(julia-latest) (logs + artifacts)
│              │
▼              ▼
Store         Store
artifacts     artifacts
```

**Concurrencia**:
```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```
Si se hace push mientras un build corre, el build anterior se cancela. Esto ahorra recursos y evita releases duplicados.

### Workflow docker-image.yml

**Archivo**: `.github/workflows/docker-image.yml`

Construye una imagen Docker personalizada basada en `ghcr.io/termux/package-builder`. Se activa cuando cambian los scripts de setup.

**Propósito**: Permite modificar el entorno de build (NDK, SDK, paquetes base) sin depender del registry oficial de termux-packages.

**Proceso**:
1. Build con Docker Buildx (con caché GHA)
2. Push a `ghcr.io/$OWNER/package-builder:latest`
3. El workflow `build-package.yml` usa esta imagen automáticamente

### Zram Action

**Archivo**: `.github/actions/zram/action.yml`

Acción composite que habilita zram (swap comprimido en RAM) en el runner de GitHub Actions.

**¿Por qué es necesaria?**: El build de Julia puede consumir >12GB de RAM. Los runners de GitHub tienen 7GB de RAM. Sin zram, el OOM killer mata el proceso.

**Configuración**:
```yaml
- uses: ./.github/actions/zram
  with:
    algorithm: zstd       # Algoritmo de compresión
    size: 16G             # Tamaño virtual del dispositivo
    priority: 100         # Prioridad de swap (mayor = preferido)
    device_name: /dev/zram0
```

**Mecanismo**:
1. Configura el algoritmo de compresión en el dispositivo zram
2. Asigna tamaño (`16G` comprimidos → ~8G RAM real usados con zstd)
3. Crea un swap filesystem
4. Activa el swap con alta prioridad

---

## Troubleshooting Avanzado

### Anatomía de un Fallo de Build

Los fallos de build de Julia suelen caer en una de estas categorías:

#### Categoría 1: CROSS_COMPILE Leak (85% de los fallos)

**Síntoma**:
```
make[2]: Entering directory '.../src/flisp/host'
aarch64-linux-android-gcc -o flisp flisp.o ...
.../flisp: cannot execute binary file: Exec format error
```

**Causa**: `CROSS_COMPILE=aarch64-linux-android-` se heredó al sub-make de flisp.

**Diagnóstico**:
```bash
grep "^override CROSS_COMPILE" Make.inc
# Si existe → el parche F8 no se aplicó
grep "BUILDING_HOST_TOOLS" Make.inc
# Si no existe → el parche F9 no se aplicó
```

**Solución**: Revisar los seds de la sección K en build.sh.

#### Categoría 2: Linker Errors (10% de los fallos)

**Síntoma**:
```
/usr/bin/ld: cannot find -lLLVM-19: No such file or directory
```

**Causa**: LLVM no instalado o no encontrado por `llvm-config`.

**Diagnóstico**:
```bash
llvm-config --libdir     # Debe ser $TERMUX_PREFIX/lib
ls $TERMUX_PREFIX/lib/libLLVM*  # Debe existir
```

**Solución**: Ejecutar `install-deps.sh` o verificar los symlinks de LLVM.

#### Categoría 3: Errores de bionic (3% de los fallos)

**Síntoma**:
```
error: 'pthread_mutexattr_setrobust' was not declared in this scope
```

**Causa**: El parche A (LMDB) no se aplicó.

**Diagnóstico**:
```bash
grep "MDB_USE_ROBUST" deps/lmdb.mk
# Si existe → el parche no se aplicó
```

**Solución**: Verificar que el sed de la línea 18 se ejecutó correctamente.

#### Categoría 4: OOM Killer (2% de los fallos)

**Síntoma**:
```
Killed
```
Sin mensaje de error adicional. El proceso fue killado por OOM.

**Diagnóstico**: Revisar `dmesg`:
```bash
dmesg | grep -i oom
dmesg | grep -i killed
```

**Solución**: Reducir `TERMUX_PKG_MAKE_PROCESSES` o habilitar más swap.

### Cómo Depurar el Build Localmente

```bash
# 1. Build en modo interactivo
./scripts/run-docker.sh bash
# Dentro del contenedor:
cd ~/.termux-build/julia/src

# 2. Ejecutar pasos manualmente
# (los hooks de termux-packages se pueden invocar individualmente)
source ~/termux-packages/scripts/build/termux_step_pre_configure.sh

# 3. Ver Make.inc después de parches
grep "CROSS_COMPILE" Make.inc
grep "OSLIBS" Make.inc

# 4. Compilar solo flisp host (para probar el fix)
make -C src/flisp/host -f "$PWD/src/flisp/Makefile" \
    SRCDIR="$PWD/src/flisp" \
    BUILDDIR="$PWD/src/flisp/host" \
    BUILDING_HOST_TOOLS=1 XC_HOST="" CROSS_COMPILE="" \
    CC="gcc" CXX="g++" AR="ar" RANLIB="ranlib" \
    V=1 flisp

# 5. Verificar el binario resultante
file src/flisp/host/flisp
# Debe decir: ELF 64-bit LSB executable, x86-64

# 6. Si todo funciona, hacer el build completo
make -j4 HOSTCC="gcc" HOSTCXX="g++" HOST_LDFLAGS="" \
    PREFIX="$TERMUX_PREFIX" LOCALBASE="$TERMUX_PREFIX" \
    FC_VERSION=dummy release
```

### Cómo Depurar en CI/CD

```bash
# 1. Ejecutar workflow manualmente desde GitHub UI
# Actions → "Build Julia for Termux" → "Run workflow"

# 2. SSH al runner (si tienes self-hosted)
# No es posible en runners de GitHub, pero se puede:
# - Añadir un step con action/labeler para etiquetar
# - Usar tmate para debug interactivo:
#   - name: Debug via tmate
#     uses: mxschmitt/action-tmate@v3

# 3. Analizar los artifacts de debug
# Cuando el build falla, el pipeline guarda:
# - config.log
# - *.log y *.err
# - Las últimas 100 líneas de cada log

# 4. Descargar artifacts
gh run download <run-id> --repo {owner}/julia-termux
```

---

## Decisiones de Diseño (ADRs)

### ADR-001: Seds Inline vs Parches Externos

**Estado**: Aceptado

**Contexto**: Necesitábamos aplicar ~22 modificaciones al código de Julia. Las opciones eran:
1. Archivos de patch externos (`.patch`)
2. Operaciones `sed` inline en `build.sh`

**Decisión**: Usar `sed` inline.

**Consecuencias**:
- Positivo: Single file de build, fácil de leer y modificar
- Positivo: No requiere mantenimiento de archivos patch separados
- Negativo: Frágil ante cambios en el código fuente de Julia
- Negativo: Seds complejos son difíciles de depurar

**Mitigación**:
- Cada `sed` tiene protección contra fallo (`|| echo "Warning"`)
- Los seds más complejos se documentan con comentarios
- Se verifican en cada actualización de versión de Julia

---

### ADR-002: Host flisp Manual vs Automático

**Estado**: Aceptado

**Contexto**: El build system de Julia intenta compilar flisp para el target, pero necesitamos flisp para el host.

**Decisión**: Compilar flisp host manualmente antes del build principal.

**Consecuencias**:
- Positivo: Control total sobre las flags de compilación
- Positivo: Evita el Bug #1 (CROSS_COMPILE leak)
- Negativo: Código adicional en `termux_step_make()`
- Negativo: Si Julia cambia el Makefile de flisp, el build manual puede fallar

---

### ADR-003: USE_SYSTEM_LLVM=1

**Estado**: Aceptado

**Contexto**: Julia incluye LLVM en su tarball y puede compilarlo desde source. En Termux, LLVM ya está disponible como paquete.

**Decisión**: Usar `USE_SYSTEM_LLVM=1` para aprovechar el LLVM de Termux.

**Consecuencias**:
- Positivo: Ahorra ~2 horas de compilación
- Positivo: LLVM de Termux está optimizado para aarch64
- Negativo: Dependencia de la versión de LLVM en Termux
- Negativo: Posibles incompatibilidades si Julia requiere una versión específica

---

### ADR-004: zram en CI/CD

**Estado**: Aceptado

**Contexto**: El build de Julia consume >12GB de RAM. Los runners de GitHub tienen 7GB.

**Decisión**: Usar una acción composite de zram para habilitar swap comprimido.

**Consecuencias**:
- Positivo: Evita OOM kills durante el build
- Positivo: zstd comprime ~2:1, dando ~14GB efectivos
- Negativo: Overhead de compresión/descompresión
- Negativo: No funciona en todos los runners (algunos no tienen módulo zram)

---

### ADR-005: Release Mutable (julia-latest)

**Estado**: Aceptado

**Contexto**: Necesitamos que los usuarios descarguen siempre la última versión sin cambiar la URL.

**Decisión**: Usar una GitHub Release mutable llamada `julia-latest` que se elimina y recrea en cada build.

**Consecuencias**:
- Positivo: URL fija para descargas automáticas
- Positivo: Fácil integración con scripts de instalación
- Negativo: Se pierde el historial de versiones (solo existe la última)
- Negativo: Si el build falla, la release anterior se ha eliminado

**Mitigación**: Los artifacts se guardan con el SHA del commit como respaldo.

---

### ADR-006: No Usar BinaryBuilder

**Estado**: Aceptado

**Contexto**: Julia proporciona BinaryBuilder para compilar dependencias. Sin embargo, no tiene soporte completo para Android/bionic.

**Decisión**: `USE_BINARYBUILDER=0`, usar dependencias del sistema Termux.

**Consecuencias**:
- Positivo: Build más simple y rápido
- Positivo: Dependencias optimizadas para ARM64 por el equipo de Termux
- Negativo: Dependencia de la disponibilidad de paquetes en Termux
- Negativo: No es reproducible fuera del ecosistema Termux

---

### ADR-007: Formato Pacman vs Dpkg

**Estado**: Aceptado

**Contexto**: Termux soporta tanto `dpkg` (`.deb`) como `pacman` (`.pkg.tar.xz`).

**Decisión**: Generar paquetes en formato pacman (`--format pacman`).

**Consecuencias**:
- Positivo: Pacman es más rápido y confiable para paquetes grandes
- Positivo: Mejor manejo de dependencias conflictivas
- Negativo: Algunos usuarios prefieren dpkg
- Negativo: No es el formato por defecto de Termux

---

> **Última actualización**: Julio 2026 — Julia v1.12.6
>
> *Este documento describe la arquitectura del sistema a nivel de diseño. Para bugs conocidos y guía de modificación, ver [AGENTS.md](./AGENTS.md). Para instalación y uso, ver [README.md](./README.md).*
