# PROGRESS.md — Estado del proyecto julia-termux

> Última actualización: 2026-10-08 ~20:45 UTC
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
  `patches/deps/*.patch` aplican al commit que `deps/*.mk` descarga, cada
  paquete declarado existe en el repo de Termux, y la sonda de resolución corre
  sobre **la lista que `base/Makefile` va a pedir**, no sobre una lista propia.
- `scripts/symlinked-libraries.sh` — le pide a `make` los nombres que
  `base/Makefile` resolverá vía `libwhich`: extrae el bloque de symlinks del
  árbol **parcheado** (condicionales incluidos), lo incluye sobre `Make.inc` con
  el `Make.user` generado y reemplaza `symlink_system_library` por una grabadora,
  de modo que `versioned_libname`, `LIBMNAME`/`LIBBLASNAME`/`LIBLAPACKNAME`,
  los guardas `USE_SYSTEM_*` y los `ALLOW_FAILURE` se resuelven como en el build.
  `scripts/probe-library-resolution.sh` solo trabaja con esa lista (el job lint
  se la pasa al job build por output del job); un nombre ausente del prefijo es
  `FAIL`, porque `julia-base` aborta justo ahí.
- `.github/scripts/termux-closure-resolver.py` — cierre de dependencias del
  índice de Termux (roots = bootstrap recortado + Tier 1 de
  `scripts/setup-termux.sh` + `termux-elf-cleaner` + `TERMUX_PKG_*DEPENDS` de la
  receta).

**Hipótesis del próximo run** — sigue siendo la de `libblas.so`, porque el run
anterior no llegó a ponerla a prueba: `julia-base` abortaba en `Makefile:250`
porque el prefijo del runner no tenía `libblas.so`; con `USE_SYSTEM_BLAS := 1`
Make.inc fija `LIBBLASNAME := libblas` y ese alias lo aporta el paquete split
`blas-openblas`, que la receta no declaraba (ahora está en
`TERMUX_PKG_BUILD_DEPENDS`; el symlink resultante es absoluto a
`$PREFIX/lib/libopenblas.so`, que ya cubre el runtime). La lista que se sonda es
la que derivan `make` + `base/Makefile` — 19 nombres, dos más que los 18
inventados que el gate verificaba contra la librería equivocada. Ya está medido
en **ambos** entornos: teléfono (`resolution=0`, `libblas.so → libopenblas.so`,
gate12 19:35 UTC) y prefijo del runner (`19 name(s) must resolve`,
`-- 19 soname(s) probed, 0 failure(s) --`, `PROBE: PASS` en 37833826111), y la
closure del action lo resuelve (`blas-openblas_0.3.34`, 115 paquetes,
`unresolved=0`). Lo que falta es `make -C base`: si `libblas.so` y
`liblapack.so` se enlazan y el build avanza, el siguiente punto de dolor está
después de los symlinks. Ese run se cayó en un paso propio del traspaso de la
lista al job build (`tr '\n' ' '` dejaba un espacio final y la validación anclada
del mismo paso lo rechazó, con razón); reproducido en el teléfono en 1 s y
corregido con `paste -sd' '`. Como `packages/**` entra en la clave de caché y
todavía no hay artefacto cacheado, el próximo run paga la compilación completa
(~45 min).

---

## Cadena de modos de fallo (evidencia fechada, todos 2026-10-08)

El mismo entorno falló de maneras distintas; cada una se cerró con un run y se
convirtió en gate local cuando era reproducible fuera del runner.

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
| 37811196090 | 16:44 | `System library symlink failure: Unable to locate libpcre2-8.so on your system!` → `Makefile:93: julia-base` a los ~47 min; flisp y LLVM ya estaban compilados | el `libwhich` parcheado **moría al responder**, no era el `dlopen` del soname: su rama sin `dlinfo` re-`dlopen`ea cada imagen que `dl_iterate_phdr` reporta para comparar el handle, y la primera es `/system/bin/linker64`. En el teléfono ese pedido se rechaza por namespace y devuelve `NULL` inofensivamente; en el runner, sin `/linkerconfig/ld.config.txt`, `/system/bin` sí es ruta de búsqueda y bionic se niega a cargarse a sí mismo (`error: linker cannot load itself`) matando el proceso **con stdout sin flush** → `libwhich -p` respondió `""` con rc=1 y el `2>/dev/null` de `base/Makefile:166` se llevó la única pista | `RTLD_LAZY \| RTLD_NOLOAD` al sondear el mapa (la rama Apple de libwhich ya lo usa) + saltar las entradas sin `/` inicial, en `patches/deps/termux-libwhich-dlinfo-android.patch`; verificado con el tool real en el gate: 18/18 `loader bound …` y 18 `TOOL` |
| 37820685855 | 18:00 | `GATE: FAIL` con `resolution=1` en el job lint: el build ni empezó | la sonda nueva heredaba el algoritmo fatal de libwhich, así que reproducía el síntoma sin poder explicarlo: `FAIL  libpcre2-8.so` con el detalle vacío, porque el proceso moría antes de imprimir | la sonda reporta por etapas (`CTRL` de arranque, `LOAD <soname> ok` con `flush`, `NEEDED` del binario, stderr completo): un stdout vacío ahora significa "no llegó a `main()`" y un `LOAD … ok` prueba que el loader encontró la librería |
| 37823556050 | 18:20 | `GATE: PASS` y `PROBE: PASS` (`18 soname(s) probed, 0 failure(s)`) en el runner, pero a los ~44 min `System library symlink failure: Unable to locate libblas.so on your system!` → `Makefile:250` → `Makefile:93: julia-base`; el fix de libwhich sí había funcionado (`ln -sf $PREFIX/lib/libpcre2-8.so usr/lib/julia/libpcre2-8.so` en el build real) | el nombre que faltaba no era el que se verificaba: con `USE_SYSTEM_BLAS := 1`, Make.inc fija `LIBBLASNAME := libblas` / `LIBLAPACKNAME := liblapack` y `base/Makefile` pregunta por **esos alias**, que en Termux pertenecen al paquete split `blas-openblas` (dueño de `libblas.so`, `libblas.so.3`, `liblapack.so*`) — la receta solo declaraba `libopenblas`. Y tanto el gate como la sonda llevaban la lista escrita a mano con `libopenblas.so`, así que `resolution=0` mediía otra cosa | `blas-openblas` en `TERMUX_PKG_BUILD_DEPENDS` (el symlink que crea `julia-base` es absoluto a `$PREFIX/lib/libopenblas.so`, ya cubierto en runtime); `scripts/symlinked-libraries.sh` deriva los 19 nombres con `make` sobre el árbol parcheado y `rehearse-recipe.sh`/el job build los consumen (`PROBE_LIBS` del output `lint.probe_libs`); `MISS` pasó a ser `FAIL`: un nombre que el prefijo no tiene es exactamente el abort de `julia-base` |
| 37833826111 | 19:41 | el job build **nunca arrancó**: `GATE: PASS` con la lista derivada (`19 name(s) must resolve`, `-- 19 soname(s) probed, 0 failure(s) --`, `PROBE: PASS` sobre el prefijo del runner) y en cambio falló el paso nuevo que le pasa esa lista al job build | `tr '\n' ' '` convierte el último salto de línea en un espacio **final**, y la validación anclada `^[A-Za-z0-9_.+-]+( [A-Za-z0-9_.+-]+)*$` del propio paso lo rechaza — el guard era correcto; quien normalizaba mal era el join | `paste -sd' '` (sin separador colante). Reproducido en el teléfono antes de tocar nada: `old join: REJECTED`, `paste join: VALID (19 names)`. La hipótesis de `libblas.so` sigue sin medir en el build: este run es el primero que llega a `make` con la lista buena |

Ruido benigno conocido del runner: `linker: Warning: failed to find generated
linker configuration from "/linkerconfig/ld.config.txt"`,
`__bionic_open_tzdata: …`, `bionic-icu: couldn't open libicu.so`,
`expr: syntax error: unexpected argument 'Warning:'` (el anterior se cuela en
una sustitución de comando de `configure`; autoconf cae a su default y sigue),
y `Warning: git information unavailable`.  NO es ruido `error: linker cannot load
itself`: ese era la causa de 37811196090, y aparecerá igual en todo proceso que
pida `dlopen` del linker del runner.

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
