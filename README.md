# Julia para Termux

[![Build Julia for Termux](https://github.com/{owner}/julia-termux/actions/workflows/build-package.yml/badge.svg)](https://github.com/{owner}/julia-termux/actions/workflows/build-package.yml)
[![Julia Version](https://img.shields.io/badge/julia-1.12.6-purple?logo=julia)](https://julialang.org)
[![Termux Package](https://img.shields.io/badge/termux-aarch64-blue)](https://termux.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Cross-compilación de [Julia](https://julialang.org) para Termux/Android (aarch64) usando el build system oficial de termux-packages.**

Este proyecto adapta el build system de Julia —uno de los más complejos del ecosistema open source— para que funcione sobre la libc de Android (bionic) en lugar de glibc. Incluye ~22 parches inline para resolver diferencias entre bionic y glibc, un pipeline CI/CD optimizado con zram, y soporte completo para Julia v1.12.6 funcionando nativamente en Termux sin contenedores ni emulación.

---

## Tabla de Contenidos

- [Estado Actual](#estado-actual)
- [Prerrequisitos](#prerrequisitos)
- [Build local con tcr](#build-local-con-tcr)
- [CI/CD con GitHub Actions (Recomendado)](#cicd-con-github-actions-recomendado)
- [Instalación en Termux](#instalacin-en-termux)
- [Dependencias](#dependencias)
  - [System Dependencies](#system-dependencies)
  - [Built from Source](#built-from-source)
- [Arquitectura del Build](#arquitectura-del-build)
- [Parches para Android/bionic](#parches-para-androidbionic)
- [Solución de Problemas](#solucin-de-problemas)
- [Desarrollo](#desarrollo)
- [Agradecimientos](#agradecimientos)

---

## Estado Actual

| Componente | Estado |
|------------|--------|
| Cross-compilación aarch64 | ✅ Funcional |
| Parches para Android/bionic | ✅ 22 patches integrados en `build.sh` |
| CI/CD vía GitHub Actions | ✅ Con zram (16GB), caché y releases automáticos |
| Julia v1.12.6 (última estable) | ✅ Soportada |
| Host flisp bootstrapping | ✅ Manual para evitar cross-contamination |
| LMDB, libuv, libunwind | ✅ Parcheados para bionic |
| Instalación via pacman | ✅ Paquete `.pkg.tar.xz` |
| Instalación via dpkg | 🟡 En desarrollo |
| Soporte para x86_64 | ❌ Solo aarch64 por ahora |

---

## Prerrequisitos

### Para build local
- Termux aarch64 con `clang`, `make`, `cmake`, `perl`, `m4` y LLVM instalados
- El wrapper `~/.local/bin/tcr` (se puede indicar otra ruta con `TCR=...`)
- ~8 GB de RAM mínimo (16 GB recomendado para evitar OOM)
- ~10 GB de espacio libre y una red estable para descargar Julia/dependencias
- `git` para clonar el repositorio

### Para CI/CD
- Cuenta de GitHub
- GitHub Actions habilitado (por defecto en repos públicos)
- Opcional: `gh` CLI para descargar releases desde terminal

### Para instalación en Termux
- Dispositivo Android con **aarch64** (ARM64)
- [Termux](https://termux.com) instalado desde F-Droid (no desde Play Store)
- Gestor de paquetes `pacman` configurado en Termux

---

## Build local con tcr

El builder local usa el repositorio oficial `termux-packages`, descarga sus
dependencias con el mecanismo soportado por Termux y ejecuta todo el proceso
con `~/.local/bin/tcr`. El checkout se guarda en
`$HOME/.cache/julia-termux/termux-packages` y se reutiliza en builds siguientes:

```bash
cd julia-termux

# Instalar/actualizar dependencias del host (una vez)
./scripts/install-deps.sh

# Compilar Julia para aarch64; -j2 es prudente en un teléfono
./scripts/build-local.sh -j2 --format debian

# El paquete aparece en output/
ls output/
# julia-1.12.6-aarch64.deb
```

Para validar rutas y argumentos sin iniciar la compilación:

```bash
./scripts/build-local.sh --dry-run --jobs 2
```

### Build avanzado

```bash
# Elegir otro checkout y formato pacman
TERMUX_PACKAGES_DIR="$HOME/work/termux-packages" \
  ./scripts/build-local.sh --update -j2 --format pacman

# Usar espejo alternativo de Termux
export TERMUX_REPO_URL=https://packages-cf.termux.dev/apt/termux-main
./scripts/build-local.sh -j2 --format pacman
```

> **⚠️ Atención**: El build de Julia es extremadamente intensivo en memoria. Sin suficiente RAM, el compilador puede ser killado por OOM. En esos casos, reduce `TERMUX_PKG_MAKE_PROCESSES=2` o habilita swap.

---

## CI/CD con GitHub Actions (Recomendado)

Para evitar consumir recursos locales, usa el pipeline de CI/CD incluido:

```bash
# 1. Fork este repositorio en GitHub
# 2. Push a la rama main — el build comienza automáticamente
git push origin main

# 3. Monitorear el progreso en: Actions > "Build Julia for Termux"
# 4. Cuando termine, descargar desde Releases
gh release download julia-latest --repo {owner}/julia-termux
```

### ¿Qué hace el pipeline?

El workflow `build-package.yml` ejecuta estos pasos:

1. **Checkout** del repositorio
2. **Habilita zram** (16 GB comprimidos con zstd) — evita OOM durante la compilación
3. **Restaura caché** de `~/.termux-build` — acelera builds repetidos
4. **Instala dependencias** del sistema (docker, containerd) y de Termux (LLVM, OpenBLAS, etc.)
5. **Compila Julia** con `build-package.sh -a aarch64`
6. **Sube a GitHub Release** como `julia-latest`
7. **Guarda artefactos** por si el release falla

> 💡 El pipeline está configurado con `concurrency: cancel-in-progress`, así que si haces push mientras un build está corriendo, el anterior se cancela automáticamente.

---

## Instalación en Termux

```bash
# 1. Descargar el paquete
gh release download julia-latest --repo {owner}/julia-termux
# O descargar manualmente desde https://github.com/{owner}/julia-termux/releases/tag/julia-latest

# 2. Instalar con pacman
pacman -U julia-1.12.6-aarch64.pkg.tar.xz

# 3. Verificar instalación
julia --version
# Julia Version 1.12.6 (2026-02-10)
# Platform: Linux (aarch64-linux-gnu)

# 4. Probar un script simple
julia -e 'println("Hello from Julia on Termux!")'
```

### Verificación de dependencias

Julia requiere que ciertas bibliotecas estén disponibles en tiempo de ejecución:

```bash
# Verificar que las shared libraries se cargan correctamente
ldd $(which julia) | grep "not found"

# Verificar OpenBLAS
julia -e 'using LinearAlgebra; println(BLAS.get_config())'
```

> ❗ **Importante**: Si `julia` no encuentra librerías, asegúrate de que `ldconfig` tenga configurado el prefijo de Termux. El build.sh ya intenta hacer esto automáticamente:
> ```bash
> echo "/data/data/com.termux/files/usr/lib" | sudo tee /etc/ld.so.conf.d/termux-prefix.conf
> sudo ldconfig
> ```

---

## Dependencias

Julia tiene uno de los sistemas de dependencias más complejos entre los lenguajes de programación. Este proyecto distingue dos categorías:

### System Dependencies

Se instalan desde los repositorios oficiales de Termux (`packages.termux.dev`). Son bibliotecas del sistema que Julia usa en lugar de compilar las suyas propias:

| Dependencia | Propósito | Flag en Make.user |
|-------------|-----------|-------------------|
| `libllvm` + `libllvm-static` | Compilación JIT (LLVM 19+) | `USE_SYSTEM_LLVM=1` |
| `libopenblas` | Álgebra lineal optimizada | `USE_SYSTEM_OPENBLAS=1` |
| `blas-openblas` | BLAS (interfaz Fortran) | `USE_SYSTEM_BLAS=1` |
| `lapack` | LAPACK (descomposiciones matriciales) | `USE_SYSTEM_LAPACK=1` |
| `libgmp` | Aritmética de precisión arbitraria | `USE_SYSTEM_GMP=1` |
| `libmpfr` | Punto flotante de precisión arbitraria | `USE_SYSTEM_MPFR=1` |
| `suitesparse` | Álgebra lineal dispersa | `USE_SYSTEM_LIBSUITESPARSE=1` |
| `arpack-ng` | Eigenvalores dispersos | `USE_SYSTEM_ARPACK=1` |
| `libssh2` | SSH para descargas de paquetes | `USE_SYSTEM_LIBSSH2=1` |
| `curl` | Transferencias HTTP/HTTPS | `USE_SYSTEM_CURL=1` |
| `libgit2` | Integración con git (registro de paquetes) | `USE_SYSTEM_LIBGIT2=1` |
| `patchelf` | Manipulación de ELF en instalación | `USE_SYSTEM_PATCHELF=1` |
| `zlib` | Compresión | `USE_SYSTEM_ZLIB=1` |
| `openssl` | Criptografía TLS | `USE_SYSTEM_OPENSSL=1` |
| `libnghttp2` | HTTP/2 | `USE_SYSTEM_NGHTTP2=1` |
| `pcre2` | Expresiones regulares | `USE_SYSTEM_PCRE=1` |
| `libwhich` | Búsqueda de ejecutables (como `which`) | `USE_SYSTEM_LIBWHICH=1` |
| `p7zip` | Compresión 7z para descargas | `USE_SYSTEM_P7ZIP=1` |
| `lld` | Linker LLVM (necesario en Android) | `USE_SYSTEM_LLD=1` |
| `libandroid-support` | Soporte bionic para funciones POSIX | (implícita) |
| `cmake` | Build system para dependencias fuente | (build dep) |
| `perl` | Scripts de configuración | (build dep) |
| `m4` | Procesador de macros | (build dep) |

### Built from Source

Estas dependencias se **compilan desde el código fuente incluido en el tarball de Julia** porque:

- Requieren parches específicos de Julia (ej: libuv fork)
- No existen como paquetes de Termux (ej: openlibm, DSFMT)
- Necesitan configuración especial para Android (ej: libblastrampoline)

| Dependencia | Versión | Propósito | Make.user |
|-------------|---------|-----------|-----------|
| **libuv** | Fork julia-uv2 | I/O asíncrono (event loop) | `USE_SYSTEM_LIBUV=0` |
| **openlibm** | Integrada | Math library optimizada | `USE_SYSTEM_OPENLIBM=0` |
| **utf8proc** | Integrada | Procesamiento Unicode | `USE_SYSTEM_UTF8PROC=0` |
| **DSFMT** | Integrada | Generación de números aleatorios | `USE_SYSTEM_DSFMT=0` |
| **libblastrampoline** | Integrada | BLAS runtime dispatch | `USE_SYSTEM_LIBBLASTRAMPOLINE=0` |
| **mbedtls** | Integrada | TLS ligero (fallback) | `USE_SYSTEM_MBEDTLS=0` |
| **CSL** | Integrada | Common System Image (sysimg.so) | `USE_SYSTEM_CSL=0` |
| **libunwind** | Integrada | Stack unwinding (deshabilitado) | `DISABLE_LIBUNWIND=1` |

> 💡 La configuración se realiza en `Make.user`, que se genera dinámicamente en `termux_step_pre_configure()`.

---

## Arquitectura del Build

```
┌──────────────────────────────────────────────────────────────────────┐
│                    GitHub Actions (ubuntu-24.04)                      │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │              Docker Container (package-builder)                │  │
│  │  ┌─────────────────────────────────────────────────────────┐  │  │
│  │  │  termux-packages build environment                      │  │  │
│  │  │  ghcr.io/termux/package-builder:latest                  │  │  │
│  │  │                                                         │  │  │
│  │  │  ┌──────────────────────────────────────────────────┐   │  │  │
│  │  │  │  termux_step_pre_configure() ← 22 patches para   │   │  │  │
│  │  │  │  Android/bionic (seds inline en build.sh:16-176)  │   │  │  │
│  │  │  │  • A) LMDB: remove MDB_USE_ROBUST                │   │  │  │
│  │  │  │  • B-C) libuv: cross-compile + pthread           │   │  │  │
│  │  │  │  • D-F) Linker flags: -lpthread, -lrt, -latomic  │   │  │  │
│  │  │  │  • G-K) Static libs, ifunc, versioning           │   │  │  │
│  │  │  │  • H0-H07) Source code fixes para bionic          │   │  │  │
│  │  │  │  • L-P) Symlinks, ldconfig, Make.user            │   │  │  │
│  │  │  └──────────────────────────────────────────────────┘   │  │  │
│  │  │                                                         │  │  │
│  │  │  ┌──────────────────────────────────────────────────┐   │  │  │
│  │  │  │  termux_step_make() (build.sh:179-203)            │   │  │  │
│  │  │  │  ┌────────────────────────────────────────────┐   │   │  │  │
│  │  │  │  │  Paso 1: Host flisp manual build            │   │   │  │  │
│  │  │  │  │  make -C src/flisp/host BUILDING_HOST_TOOLS │   │   │  │  │
│  │  │  │  └────────────────────────────────────────────┘   │   │  │  │
│  │  │  │  ┌────────────────────────────────────────────┐   │   │  │  │
│  │  │  │  │  Paso 2: Cross-compilación principal        │   │   │  │  │
│  │  │  │  │  make release HOSTCC=gcc HOSTCXX=g++       │   │   │  │  │
│  │  │  │  │  Con XC_HOST=aarch64-linux-android          │   │   │  │  │
│  │  │  │  └────────────────────────────────────────────┘   │   │  │  │
│  │  │  └──────────────────────────────────────────────────┘   │  │  │
│  │  │                                                         │  │  │
│  │  │  ┌──────────────────────────────────────────────────┐   │  │  │
│  │  │  │  termux_step_make_install() (build.sh:205-209)    │   │  │  │
│  │  │  │  make install PREFIX=$TERMUX_PREFIX              │   │  │  │
│  │  │  └──────────────────────────────────────────────────┘   │  │  │
│  │  └─────────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  Resultado: output/julia-1.12.6-aarch64.pkg.tar.xz                    │
└──────────────────────────────────────────────────────────────────────┘
```

### Pipeline de Build — 10 Pasos Detallados

| Paso | Descripción | Archivo | Líneas |
|------|-------------|---------|--------|
| 1 | Configurar cross-compilación (`XC_HOST`, flags, `Make.user`) | `build.sh` | 16-176 |
| 2 | Aplicar 22 parches para Android/bionic via `sed` | `build.sh` | 17-96 |
| 3 | Crear symlinks de utilidad (7z, LLVM, libpcre2) | `build.sh` | 98-122 |
| 4 | Configurar `ldconfig` para el prefijo Termux | `build.sh` | 116-117 |
| 5 | Generar `Make.host.user` con `CC=gcc`, `CXX=g++` | `build.sh` | 124-128 |
| 6 | Generar `Make.user` con 24+ flags de compilación | `build.sh` | 130-176 |
| 7 | **Build host flisp** manual (bootstrapping) | `build.sh` | 182-192 |
| 8 | **Build principal cruzado** (`make release`) | `build.sh` | 194-202 |
| 9 | Instalar en `$TERMUX_PREFIX` | `build.sh` | 205-209 |
| 10 | Empaquetar como `.pkg.tar.xz` | `build-package.sh` | (automático) |

---

## Parches para Android/bionic

Android usa **bionic** como libc, que difiere significativamente de **glibc** (usada en Linux desktop). Julia está diseñado para glibc, por lo que se requieren adaptaciones.

### ¿Qué es bionic vs glibc?

| Característica | glibc | bionic (Android) |
|---------------|-------|-------------------|
| `pthreads` | Librería separada (`-lpthread`) | Integrada en libc |
| `librt` | Separada (`-lrt`) | Integrada en libc |
| `libatomic` | Separada | No necesaria en ARM64 |
| `ifunc` | Soportado | No soportado |
| `mallinfo()` / `malloc_stats()` | Disponibles | No existen |
| `TCP_QUICKACK` | Disponible | No disponible |
| `dl_iterate_phdr()` | gnu libc | Versión limitada |
| `pthread_getattr_np()` | Disponible | No existe |
| `libc_nonshared.a` | Existe | No existe |
| `__register_frame()` | En libgcc_s | No disponible |
| `sysinfo()` | Disponible | No existe |
| `MDB_USE_ROBUST` pthread mutex | Soportado | No soportado |

### Listado Completo de Parches

Los parches se aplican como operaciones `sed` inline dentro de `termux_step_pre_configure()` en `build.sh`. Están organizados por categoría:

#### Linker Flags (F1-F6)

| # | Fix | Archivo | Línea en build.sh |
|---|-----|---------|-------------------|
| **F1** | Remove `-lpthread` (bionic en libc) | `Make.inc`, `cli/Makefile`, `src/flisp/Makefile` | 27-29 |
| **F2** | Remove `-lrt` (bionic en libc) | `Make.inc` | 32 |
| **F3** | Remove `-latomic` (no necesario en ARM64) | `Make.inc` | 35 |
| **F4** | Remove `-static-libstdc++` (Android usa libc++) | `src/Makefile` | 38 |
| **F5** | Remove `libc_nonshared.a` (glibc-specific) | `Makefile`, `deps/csl.mk` | 44-45 |
| **F6** | Deshabilitar `ifunc` (no soportado en bionic) | `Make.inc` | 41 |

#### Cross-Compilación (F7-F9)

| # | Fix | Archivo | Propósito |
|---|-----|---------|-----------|
| **F7** | LLVM→Julia symver en `julia.expmap.in` | `src/julia.expmap.in` | Compatibilidad con lld |
| **F8** | Quitar `override` de `CROSS_COMPILE` | `Make.inc` | Evitar que se herede a host tools vía MAKEOVERRIDES |
| **F9** | Guard `BUILDING_HOST_TOOLS` resetea `CROSS_COMPILE` | `Make.inc` | Host tools deben compilarse para x86_64 |

#### Dependencias (F10-F12)

| # | Fix | Archivo | Propósito |
|---|-----|---------|-----------|
| **F10** | libm ALLOW_FAILURE en Android | `base/Makefile` | bionic libm no necesita symlink |
| **F11** | LMDB robust mutex deshabilitado | `deps/lmdb.mk` | `pthread_mutexattr_setrobust` no soportado |
| **F12** | TCP_QUICKACK guard | `src/jl_uv.c` | No disponible en Android |
| **F13** | mallinfo/malloc_stats guard | `src/gc-debug.c` | glibc-specific |

#### Source Code Fixes (H0-H07)

| # | Fix | Archivo | Propósito |
|---|-----|---------|-----------|
| **H0** | `#error` de libunwind en Android | `src/task.c` | libunwind no es compatible |
| **H00** | Excluir `sys/sysinfo.h` | `src/codegen.cpp` | sysinfo() no existe en bionic |
| **H01** | Guard `__register_frame`/`__deregister_frame` | `src/debuginfo.cpp` | libgcc_s no disponible en Android |
| **H02** | Reemplazar `pthread_getattr_np` | `src/init.c` | No existe en bionic (usar `pthread_get_stackaddr_np`) |
| **H03** | Stub para `libstdcxxprobe()` | `cli/loader_lib.c` | Android usa libc++ en vez de libstdc++ |
| **H04** | Definir `_OS_ANDROID_` | `src/support/platform.h` | Detectar plataforma Android en código fuente |
| **H05** | Incluir `<link.h>` en bionic | `src/dlload.c` | bionic necesita include explícito |
| **H06** | endian.h y uint_t compat | `src/support/dtypes.h` | bionic endianness y tipos |
| **H07** | `dl_iterate_phdr` fallback | `src/sys.c` | Usar ruta OpenBSD como fallback |

---

## Solución de Problemas

### Error: "OOM killer terminated the build"

El build de Julia consume mucha RAM. Soluciones:

```bash
# Reducir paralelismo
export TERMUX_PKG_MAKE_PROCESSES=2
./scripts/run-docker.sh ./build-package.sh -I -a aarch64 --format pacman julia

# O habilitar swap
sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

### Error: "flisp: command not found" durante el build

El host flisp no se compiló correctamente. Verificar:

```bash
# Revisar si el binario existe
ls -la src/flisp/host/flisp

# Forzar rebuild del host flisp manualmente
make -C src/flisp/host -f "$PWD/src/flisp/Makefile" \
    SRCDIR="$PWD/src/flisp" \
    BUILDDIR="$PWD/src/flisp/host" \
    BUILDING_HOST_TOOLS=1 \
    XC_HOST="" CROSS_COMPILE="" \
    CC="gcc" CXX="g++" \
    AR="ar" RANLIB="ranlib" \
    clean flisp
```

### Error: "Library not found: libLLVM-19.so"

Julia no encuentra las librerías LLVM del sistema:

```bash
# Verificar que LLVM está instalado en el contenedor
ls -la $TERMUX_PREFIX/lib/libLLVM*

# Configurar ldconfig
echo "/data/data/com.termux/files/usr/lib" | sudo tee /etc/ld.so.conf.d/termux-prefix.conf
sudo ldconfig
```

### Error: "CROSS_COMPILE leaked into host tools"

Si ves errores de cross-compilación en herramientas del host (como `flisp`), el fix F8-F9 no se aplicó correctamente:

```bash
# Verificar Make.inc
grep "CROSS_COMPILE" Make.inc
# Debe mostrar: "CROSS_COMPILE:=$(XC_HOST)-" (sin "override")
# Y el guard de BUILDING_HOST_TOOLS debe estar presente
```

### Error: "pacman: command not found"

Termux no tiene `pacman` instalado:

```bash
# Instalar pacman en Termux
pkg update && pkg install pacman
# O usar dpkg directamente (si el paquete está en formato .deb)
dpkg -i julia-1.12.6-aarch64.deb
```

### Error: "Segmentation fault" al ejecutar Julia

Posiblemente un problema con libunwind o alguna librería mal vinculada:

```bash
# Verificar linking
ldd $(which julia)

# Ejecutar con más diagnóstico
julia --debug-infos -e 'println("test")'

# Reinstalar
pacman -R julia && pacman -U julia-1.12.6-aarch64.pkg.tar.xz
```

### Debug: Ver logs de build

```bash
# Durante el build (CI/CD)
# Ir a: GitHub > Actions > "Build Julia for Termux" > job > step "Debug - Show build log on failure"

# Localmente
cat ~/.termux-build/julia/config.log
find ~/.termux-build -name "*.log" -exec tail -50 {} \;
```

---

## Desarrollo

### Estructura del Repositorio

```
julia-termux/
├── .github/
│   ├── actions/
│   │   └── zram/
│   │       └── action.yml          # Acción composite para zram
│   └── workflows/
│       └── build-package.yml        # Imagen Docker + Julia + release
├── ndk-patches/
│   └── 29/
│       └── .gitkeep                 # Parches NDK (futuro)
├── output/                          # Paquetes compilados
├── packages/
│   └── julia/
│       ├── build.sh                 # ★ Script de build principal
│       └── patches/
│           └── .gitkeep             # Parches externos (futuro)
├── scripts/
│   └── install-deps.sh              # Instalación de dependencias en contenedor
├── AGENTS.md                        # Documentación para agentes AI
├── ARCHITECTURE.md                  # Diseño técnico detallado
└── README.md                        # Este archivo
```

### Cómo Contribuir

1. **Reporta bugs**: Abre un issue describiendo el problema, el dispositivo Android, y la versión de Termux.
2. **Propón parches**: Haz fork, crea una rama, y abre un Pull Request.
3. **Prueba nuevos parches**: Modifica `build.sh`, corre el build local con Docker, y verifica que Julia funciona.

### Convenciones de Código

- Todos los parches van en `termux_step_pre_configure()` como operaciones `sed`
- Cada `sed` debe tener un `|| echo "Warning: ..." >&2` para evitar `set -e` silencioso
- Los parches de código fuente (H0-H07) usan `2>/dev/null || true` porque pueden fallar si el archivo no existe
- Los parches de linker flags (F1-F6) usan `|| echo "Warning: ..." >&2` para visibilidad
- Cada grupo de parches tiene un comentario con letra (A, B, C...) para referencia

---

## Agradecimientos

- **[Leonisaurov](https://github.com/Leonisaurov/julia-termux)** — Trabajo base de parches para Android/bionic y adaptación inicial del build system de Julia
- **[Termux](https://termux.dev)** — Entorno Linux para Android, sin el cual esto no sería posible
- **[JuliaLang](https://julialang.org)** — El lenguaje y su increíble equipo de compiladores
- **[termux-packages](https://github.com/termux/termux-packages)** — Build system que hace posible la cross-compilación
- **Contribuidores** — Todos los que han reportado bugs, propuesto parches y mejorado este proyecto

---

## Licencia

MIT License — Ver [LICENSE](LICENSE) para detalles.

---

<div align="center">
  <sub>Hecho con ❤️ para la comunidad Termux</sub>
</div>
