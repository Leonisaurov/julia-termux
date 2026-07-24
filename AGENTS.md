# Julia para Termux — Build System

Repositorio para compilar Julia nativamente para Termux/Android (aarch64) usando la infraestructura de termux-packages en GitHub Actions CI.

## Estado Actual

**Julia compila exitosamente en CI.** El proceso de empaquetado en formato pacman (.pkg.tar.xz) está pendiente de ajuste fino.

## Versión

- **Julia:** master (1.14.0-DEV)
- **LLVM:** 21.1.8 (sistema, vía Termux package)
- **Objetivo:** aarch64-linux-android (API 24)
- **Toolchain:** Android NDK r29 (vía ghcr.io/termux/package-builder)

## Estructura del Repositorio

```
.github/workflows/build-julia.yml   ← CI workflow
packages/julia/
├── build.sh                          ← Receta de build
├── 0001-platform-define-android-os.patch
├── 0002-dtypes-bionic-endian-compat.patch
├── 0003-sys-dl-iterate-phdr-fallback.patch
├── 0004-dlload-link-h-bionic-include.patch
├── 0005-loader-lib-stdcxxprobe-stub.patch
├── 0007-init-pthread-getattr-np.patch
├── 0008-debuginfo-register-frame.patch
├── 0009-codegen-sysinfo.patch
├── 0010-task-linux-error.patch
├── 0011-gc-debug-mallinfo.patch
└── 0012-jl-uv-tcp-quickack.patch
scripts/         ← Infraestructura de build de termux-packages
build-package.sh ← Entry point de build
ndk-patches/     ← Parches para headers del NDK
```

## Parches Aplicados

### Parches de plataforma (0001-0005)
Estos parches modifican el código fuente de Julia para detectar y soportar Android/bionic:

1. **0001** (`platform.h`): Define `_OS_ANDROID_` cuando se detecta `__ANDROID__`
2. **0002** (`dtypes.h`): Compatibilidad de endianness con bionic
3. **0003** (`sys.c`): Implementa `dl_iterate_phdr` como fallback de `dlinfo` para bionic
4. **0004** (`dlload.c`): Incluye `<link.h>` para bionic
5. **0005** (`loader_lib.c`): Stub para `libstdcxxprobe()` en Android (usa libc++)

### Parches de compatibilidad bionic (0007-0012)
6. **0007** (`init.c`): Usa `pthread_get_stackaddr_np`/`pthread_get_stacksize_np` en vez de `pthread_getattr_np` (no existe en bionic)
7. **0008** (`debuginfo.cpp`): Excluye bionic de `__register_frame`/`__deregister_frame` (glibc-specific)
8. **0009** (`codegen.cpp`): Excluye bionic de `sysinfo()` (no existe en bionic)
9. **0010** (`task.c`): Excluye Android del `#error` de libunwind (LLVM libunwind sí soporta `unw_set_reg`)
10. **0011** (`gc-debug.c`): Excluye bionic de `mallinfo`/`malloc_stats` (solo debug)
11. **0012** (`jl_uv.c`): Usa `#ifdef TCP_QUICKACK` en vez de `_OS_LINUX_`

### Fixes vía sed en build.sh
Además de los parches, `termux_step_pre_configure()` aplica estos fixes vía sed:

- **LMDB**: Elimina `-DMDB_USE_ROBUST=1` (bionic no tiene robust mutex)
- **libuv**: Agrega `--host=aarch64-linux-android --build=x86_64-pc-linux-gnu` para cross-compilation
- **libuv pthread**: Parchea `pthread_setcancelstate` para Android
- **-lpthread**: Elimina de `Make.inc`, `cli/Makefile`, `src/flisp/Makefile`
- **-lrt**: Elimina de `Make.inc` (bionic tiene librt en libc)
- **-latomic**: Elimina de `Make.inc` (bionic tiene atomic en libc)
- **-static-libstdc++**: Elimina de `src/Makefile` (Android usa libc++)
- **ifunc detection**: Deshabilita (no soportado en bionic)
- **CRT objects**: Elimina `libc_nonshared.a` de `Makefile` y `deps/csl.mk`
- **julia.expmap**: Reemplaza bloque LLVM version con Julia version (ld.lld no soporta múltiples version blocks)
- **p7zip**: Crea symlink al sistema 7z en `usr/libexec/julia/`
- **gfortran**: Pasa `FC_VERSION=dummy` para evitar error de fortran faltante

## CI Workflow

El workflow `.github/workflows/build-julia.yml`:
1. Checkout del repositorio
2. Habilita zram (16GB comprimido)
3. Restaura cache de `.termux-build`
4. Corre Docker container `ghcr.io/termux/package-builder`
5. Instala dependencias vía pacman en el contenedor
6. Ejecuta `build-package.sh -s -a aarch64 --format pacman julia`
7. Sube artifact `.pkg.tar.xz` a GitHub Releases

## Cómo construir localmente

```bash
# Requisitos: Docker, git
git clone https://github.com/Leonisaurov/julia-termux.git
cd julia-termux
./scripts/run-docker.sh ./build-package.sh -s -a aarch64 --format pacman julia
```

El `.pkg.tar.xz` resultante estará en `output/`.

## Pendientes

- [ ] **Empaquetado pacman**: El build de Julia compila exitosamente pero el paso de empaquetado (generación del .pkg.tar.xz) no se completa. Posible causa: `build-package.sh -s` omite pasos de empaquetado. Revisar `termux_step_create_pacman_package()`.
- [ ] **Verificación del binario**: Probar que el binario compilado funciona correctamente en Termux (ejecutar `julia -e 'println("hello")'`)
- [ ] **LLVM en cache**: La primera compilación es lenta porque LLVM 21 debe descargarse. El cache de GitHub Actions acelera compilaciones subsecuentes.
- [ ] **Actualización automática**: Configurar Dependabot o similar para mantener Julia al día con master.

## Notas Técnicas

### Diferencias clave entre Linux glibc y Android bionic

| Aspecto | Linux (glibc) | Android (bionic) |
|---------|---------------|-------------------|
| librt | Biblioteca separada | En libc |
| libpthread | Biblioteca separada | En libc |
| libdl | Biblioteca separada | En libc (symlink) |
| libatomic | Biblioteca separada | En libc (compiler_rt) |
| libstdc++ | GCC | libc++ de LLVM |
| libunwind | GNU libunwind | LLVM libunwind |
| ifunc | Soportado | No soportado |
| pthread_getattr_np | Disponible | No existe |
| __register_frame | En libgcc_s | No existe |
| sysinfo() | Disponible | No existe |
| mallinfo() | Disponible | No existe |
| robust mutex | Soportado | No soportado |
| Linker version script | GNU ld | lld (restrictivo) |

### OS detection
Android ejecuta `uname` que reporta "Linux". Julia's build system no distingue Android de Linux glibc. Todos los fixes se hacen a través de parches y seds en `termux_step_pre_configure()`.
