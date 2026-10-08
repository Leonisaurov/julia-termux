# PROGRESS.md — Estado del proyecto julia-termux

> Última actualización: 2026-10-08 ~16:55 UTC
>
> Este archivo es el **registro de evidencia**: qué se intentó, qué falló, por
> qué y qué gate local cerró ese fallo. Las decisiones de diseño viven en
> `ARCHITECTURE.md`, pero ese archivo y `AGENTS.md`/`README.md` siguen
> describiendo la arquitectura abandonada (ver Pendientes §3).

---

## Resumen

Port de **Julia v1.12.6** a Termux/Android aarch64 mediante el build system de
`termux-packages`, construido en **CI** y validado **en el dispositivo**.

**Estado**: la arquitectura de build está validada de punta a punta hasta el
minuto 43; el compilador ya llega a `src/`. Qedan por demostrarse la parte
final (`sysimg`, `base/`, empaquetado) y la verificación en dispositivo.

| Pieza | Estado |
|---|---|
| Receta declarativa `packages/julia/build.sh` | OK (22 parches aplican, `configure` genera un `Make.user` que `Make.inc` acepta) |
| Gates estáticos locales | OK y en el DAG de CI |
| Entorno de runner (`termux-builder`) | OK: materializa un prefijo Termux real en `ubuntu-24.04-arm` |
| LLVM 18.1.7-4 bundled compilado | OK (43 min) |
| `src/` de Julia | OK (flisp y el runtime se compilan); `julia-base` aborta al enlazar las system libs |
| Artefactos `.deb` + `.pkg.tar.xz` + bundle | sin producir todavía |
| Verificación en dispositivo (Fase 5) | pendiente |

---

## Arquitectura vigente (desde 2026-10-08)

Se abandonó la cross-compilación en Docker/x86_64: compilaba LLVM 60–76 min para
morir en `llvm-min-tblgen: Exec format error`. Hoy:

- **Modo on-device de termux-packages sobre un runner arm64.** `build-package.sh`
  activa su rama on-device porque existe `/system/bin/app_process`; con
  host == target, Termux `clang` es el compilador real y el LLVM **bundled**
  (`USE_SYSTEM_LLVM := 0`) es compilable. El empaquetado es
  `tar -N "$TERMUX_BUILD_TS_FILE"` sobre el prefijo vivo + `termux_step_pre_massage`.
- **`.github/actions/termux-builder`** materializa el prefijo: `/system` desde la
  rama `ci/probe-rootfs` (es un *asset* del build, borrarla rompe todo job), una
  única closure de paquetes `.deb` bajada con el `curl` del host, y un
  `dpkg/status` sembrado para que el `apt install -y termux-elf-cleaner` de
  `termux_step_start_build.sh:125` se resuelva sin red.
- **DAG**: `lint` (gate estático) → `build` (.deb) → `bundle` (.pkg.tar.xz +
  tar.gz) → `publish`. La publicación es *input explícito* del
  `workflow_dispatch` (`publish`); un run verde no mueve ningún puntero de
  release.
- **Contrato de caché del artefacto**:
  `julia-deb-v1-aarch64-${sha}-${repo_stamp}-${hashFiles('packages/julia/**')}`.
- **Salida triple** (el usuario gestiona Termux con pacman): `.deb`,
  `.pkg.tar.xz` y un bundle.

### Flags de la receta

`USE_SYSTEM_LLVM := 0` (LLVM 18.1.7-4 con los parches de Julia, symver
`JL_LLVM_18.1`) · `USE_SYSTEM_LLD := 1` · `USE_SYSTEM_PATCHELF/P7ZIP := 1` ·
libuv/utf8proc/dSFMT/libwhich/LBT bundled · `USE_BLAS64 := 0` ·
`DISABLE_LIBUNWIND := 1` · `JULIA_PRECOMPILE := 1` · `FC := $PREFIX/bin/clang`.

---

## Regla de trabajo aplicada en cada run

Ningún run de CI empieza sin pasar los gates locales, y cada run declara
**una** hipótesis. Gates:

- `scripts/lint-workflows.sh` — YAML parseable, cada `run:` pasa `bash -n`,
  rechaza `and/or/not` en expresiones de GitHub, resuelve `uses: ./ruta`.
- `scripts/rehearse-recipe.sh` — replay del stage de parches contra el tarball
  real, decisión de endianness del árbol parcheado, `termux_step_pre_configure`
  + `termux_step_configure`, `Make.inc` acepta el `Make.user` generado,
  cada `USE_SYSTEM_* := 1` respaldado por una librería/binario real, los
  `patches/deps/*.patch` aplican al commit que `deps/*.mk` descarga, y cada
  paquete declarado existe en el repo de Termux.
- `.github/scripts/termux-closure-resolver.py` — cierre de dependencias del
  índice de Termux (roots = bootstrap recortado + Tier 1 de
  `scripts/setup-termux.sh` + `termux-elf-cleaner` + `TERMUX_PKG_*DEPENDS` de la
  receta).

---

## Cadena de modos de fallo (evidencia fechada, todos 2026-10-08)

El mismo entorno falló de ocho maneras distintas; cada una se cerró con un run y
se convirtió en gate local cuando era reproducible fuera del runner.

| Run | UTC | Síntoma | Causa raíz | Cierre |
|---|---|---|---|---|
| 37716844030 | — | nada bionic ejecuta | ELFs PT_INTERP `/system/bin/linker64` | `ci/probe-rootfs` + action lo descomprime (checksum fijado) |
| 37782123436 | 13:09 | `No address associated with hostname` | el resolver bionic no tiene DNS en el runner; el `curl` del host sí | toda la closure se baja con el host y `apt update` desaparece (`bcd822b`) |
| 37784767638 | 13:29 | el job muere en un *diagnóstico* | `set -e` sobre un reporte (`du` de un directorio que el build fallido nunca creó) | los reportes van con `|| true`; solo las aserciones fallan (`bb2f0e0`) |
| 37786844653 | 13:45 | `/usr/bin/curl` "no existe" | `libtermux-exec` reescribe `/bin`, `/etc`, `/lib`, `/usr`, `/var` en `execve`/`open` | herramientas del host copiadas a `~/.termux-builder-hostbin` (ruta no aliasada, `d5e227a`) |
| 37788134488 | 13:54 | `invalid ELF header` | `LD_PRELOAD` de una librería bionic dentro de una herramienta glibc (`df`) | `unset LD_PRELOAD` en el hijo y `LD_PRELOAD` fuera de `GITHUB_ENV` (`53b8a49`) |
| 37789690789 | 14:06 | rc 127 a los 12 ms, sin una línea | `build-package.sh` empieza con `#!/bin/bash`: el kernel ejecuta el bash glibc del runner con el preload bionic en el entorno y su loader aborta | el build se arranca con un script cuyo shebang es el del prefijo (`2915554`) |
| 37790992541 | 14:15 | `build-package.sh:64: /usr/bin/jq: cannot execute` | el aliasado vuelve inalcanzable el `jq` del runner y faltaban las herramientas del Tier 1 de `setup-termux.sh` en la closure | `jq`, `unzip`, `lzip` en los roots + shim `$PREFIX/bin/curl` que ejecuta el `curl` del host (`12f31be`, `bd781c6`) |
| 37795904301 | 14:51 | `Make.inc:1434 … without a functioning fortran compiler!` | `Make.inc:541` fija `FC := gfortran`; Termux no trae `gfortran` y OpenBLAS usa `-DC_LAPACK=ON` | `FC := $PREFIX/bin/clang` en `Make.user` + sonda `-dM -E/__GNUC__` (`755fab0`) |
| 37801929253 | 15:34 | CMake: `/usr/bin/gmake: no such file or directory` | CMake ancla `CMAKE_MAKE_PROGRAM` a la ruta del host; `make` de Termux no provee `gmake` | `$PREFIX/bin/gmake -> make` + sonda que configura **y compila** un proyecto (`e2802de`) |
| 37803324627 | 15:45 | 4 errores en `src/flisp/flisp.c:991` | ciclo de macros: `BYTE_ORDER → __BYTE_ORDER` (dtypes.h) y `__BYTE_ORDER → BYTE_ORDER` (`sys/endian.h`); el preprocessor corta la recursión, ambos valen 0 y `#if BYTE_ORDER == BIG_ENDIAN` es `0 == 0`, así que se compila la rama big-endian, cuyo `#define` en `flisp.c:990` carece de barra de continuación (bug latente de upstream) | `#ifndef` alrededor de los tres `#define` de dtypes.h + sección "endianness macros" en el gate (`f1f9638`) |
| 37811196090 | 16:44 | `System library symlink failure: Unable to locate libpcre2-8.so on your system!` → `Makefile:93: julia-base` a los ~47 min; flisp y LLVM ya estaban compilados | en medición: `base/Makefile:166` hace `libwhich -p <soname> 2>/dev/null` y se queda con `[ -e "$REALPATH" ]`; el `2>/dev/null` descarta el motivo y en todo el log no hay ni un `ln -sf`, o sea que el sondeo no resolvió nada. En el dispositivo el mismo binario resuelve los 18 sonames solo por el RUNPATH que inyecta clang; el runner no tiene `/linkerconfig/ld.config.txt` | sonda `scripts/probe-library-resolution.sh`: compila el `libwhich` parcheado y corre la cadena de shell exacta sobre cada soname; entra como sección "library resolution" del gate del job lint y como precondición del build, así la pregunta se responde en minutos y no a los 47 |

Ruido benigno conocido del runner: `linker: Warning: failed to find generated
linker configuration from "/linkerconfig/ld.config.txt"`,
`__bionic_open_tzdata: …`, `bionic-icu: couldn't open libicu.so`,
`expr: syntax error: unexpected argument 'Warning:'` (el anterior se cuela en
una sustitución de comando de `configure`; autoconf cae a su default y sigue),
y `Warning: git information unavailable`.

### Avance medible del build

`12 ms` (ni arrancaba) → `4 min` (parches + configure) → `4.5 min`
(deps/libuv/LBT) → `43 min` (LLVM 18.1.7-4 completo; flisp caía en endianness) →
`~47 min` (flisp compila, `src/` se construye, muere en `julia-base` al enlazar
las system libs).

---

## Pendientes

1. **Fase 4 (en curso)**: que un run llegue a producir el `.deb`. Mientras no
   exista artefacto, `bundle` y `publish` siguen `skipped`.
2. **Fase 5 — verificación en dispositivo**: instalar `.deb`/`.pkg.tar.xz`,
   correr `julia --version`, `versioninfo()`, `Pkg.test` de un paquete puro de
   Julia y la batería de smoke de `test/`; con evidencia fechada. "Compila" no
   es "funciona".
3. **Fase 6 — documentación**: `AGENTS.md`, `ARCHITECTURE.md` y `README.md`
   **todavía describen la arquitectura cross-compilar/Docker abandonada**
   (XC_HOST, host-flisp bootstrap, `scripts/build-deps-docker.sh`). Hay que
   reescribirlos al modo on-device o un agente futuro volverá a ese camino.
4. **Fase 2 (opcional)**: `packages/llvm-julia` solo si el LLVM bundled resulta
   no cacheable.
5. **Limpieza**: restos de sesiones en `$PREFIX/tmp` (`gate*.txt`,
   `watch-*.txt/.sh`, `rehearse-*.txt`, `julia-rehearse.*`, `tp-clone.55c0Aq`,
   `tp-path`, `julia-index-cache`, `julia-rehearse-cache`, logs de diagnóstico)
   al terminar los runs.

---

## Notas para el próximo agente

- **No empujar nada mientras un run esté en curso**: `concurrency.group` es
  `${{ github.workflow }}-${{ github.ref }}` con `cancel-in-progress: true`, así
  que un push cancela el build que se está validando.
- No cancelar un run "para limpiar la cola": mata el run en curso del mismo grupo.
- Tampoco compilar Julia en el teléfono: el build pesa horas y 11 GB de RAM no
  alcanzan; el teléfono solo baixa, instala y prueba.
- `TERMUX_SKIP_DEPCHECK=true` (`-s`) hace inalcanzables las ramas de `apt`/`gpg`
  de `build-package.sh`; por eso el prefijo se siembra, no se instala.
- Las herramientas del host solo se pueden invocar desde una ruta que
  `libtermux-exec` no reescriba **y** sin `LD_PRELOAD` en el entorno del hijo.
- El shebang de `scripts/run-build.sh` debe ser del prefijo
  (`#!/data/data/com.termux/files/usr/bin/bash`): con `#!/bin/bash` + LD_PRELOAD,
  glibc aborta.
- `~/.termux-build` del runner es cache de trabajo; `gh run view <id> --json
  status,conclusion` es la fuente de verdad, `gh run watch` devolvió 0 en runs
  fallidos.
