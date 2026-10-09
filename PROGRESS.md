# PROGRESS.md — Estado del proyecto julia-termux

> Última actualización: 2026-10-08 ~22:10 UTC
>
> Este archivo es el **registro de evidencia**: qué se intentó, qué falló, por
> qué y qué gate local cerró ese fallo. Las decisiones de diseño viven en
> `ARCHITECTURE.md`, pero ese archivo y `AGENTS.md`/`README.md` siguen
> describiendo la arquitectura abandonada (ver Pendientes §3).

---

## Resumen

Port de **Julia v1.12.6** a Termux/Android aarch64 mediante el build system de
`termux-packages`, construido en **CI** y validado **en el dispositivo**.

**Estado** (2026-10-09): la arquitectura de build está validada de punta a punta
hasta el minuto ~50; el compilador llega a `src/`, enlaza `julia-base` con los 19
symlinks, arranca `julia` y muere en el bootstrap de la imagen por los nombres
versionados que el fuente pide al loader.  Esa causa quedó cerrada con dos runs: el
primero falsificó la hipótesis de *presencia* (37862103015 creó los 8 alias y el
loader siguió respondiendo `not found`) y la causa real es de **directorio** —el
`dlopen` sale de `libjulia-internal.so`, cuyo RUNPATH es solo `$ORIGIN`, y ese
`$ORIGIN` (`usr/lib`) no era donde los poníamos—, reproducida y discriminada en el
teléfono antes del siguiente run.  Quedan por demostrarse `sys-o.a` + precompile,
empaquetado y la verificación en dispositivo.  El run `37870492832`
(2026-10-09 01:35 UTC) mide ahora esa consecuencia.

| Pieza | Estado |
|---|---|
| Receta declarativa `packages/julia/build.sh` | OK (22 parches aplican, `configure` genera un `Make.user` que `Make.inc` acepta) |
| Gates estáticos locales | OK y en el DAG de CI |
| Entorno de runner (`termux-builder`) | OK: materializa un prefijo Termux real en `ubuntu-24.04-arm` |
| LLVM 18.1.7-4 bundled compilado | OK (43 min) |
| `src/` de Julia y `julia-base` | OK (flisp, runtime y los 19 symlinks de system libs, `libblas.so`/`liblapack.so` incluidos) |
| Sysimage (`sysimg`/`base/`) | aborta en `sysimage.mk:129` (`sysbase-o.a`): el triplet quedó cerrado y **confirmado en CI** (37851961397); de los sonames versionados se falsificó la hipótesis de presencia (37862103015) y la causa real —el directorio del alias frente al `RUNPATH=$ORIGIN` de `libjulia-internal`— está medida en el teléfono, con el fix y su gate pendientes de CI |
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
- `scripts/embedded-triplet.sh` — le pide a `make` el valor que `base/Makefile:85`
  va a empotrar como `const BUILD_TRIPLET` (`$(BB_TRIPLET_LIBGFORTRAN_CXXABI)`,
  salida de `Make.inc:1380`) y exige que ese valor sobreviva un round-trip por
  `contrib/normalize_triplet.py` invocado con el propio `$(PYTHON)`/`invoke_python`
  de Make.inc.  No se compara contra una expectativa escrita: la pregunta es si la
  cadena que se empotra es expresable en la gramática que
  `base/binaryplatforms.jl` tiene que parsear, y eso lo responde el mismo script
  que la produce.
- `packages/julia/soname-aliases.sh` — lee los literales de librería que el propio
  fuente pide al loader (`base/*.jl`, `stdlib/*/src/*.jl`) y veredicta cada nombre
  contra el prefijo como `native`/`alias`/`built`/`absent`.  Lo consume
  `termux_link_soname_aliases` en la receta (antes de `make` y tras `install`) y la
  sección `dlopen'ed versioned sonames` del gate, que cruza los `absent` con la
  lista REQUIRED de `symlinked-libraries.sh`.
- `scripts/runtime-library-dir.sh` — le pide a `make` el **directorio** donde el
  loader va a buscar esos alias: `$(build_shlibdir)` (donde `src/Makefile` enlaza
  `libjulia-internal.so`, el objeto que emite el `dlopen`) y `$(private_libdir)`
  (donde `make install` lo mueve), y aborta si `$(RPATH_LIB)` deja de mencionar
  `$ORIGIN`, porque esa es la premisa de todo el razonamiento.  El gate confronta
  la respuesta con los destinos de cada `termux_link_soname_aliases` de la receta.
- `.github/scripts/termux-closure-resolver.py` — cierre de dependencias del
  índice de Termux (roots = bootstrap recortado + Tier 1 de
  `scripts/setup-termux.sh` + `termux-elf-cleaner` + `TERMUX_PKG_*DEPENDS` de la
  receta).

**Hipótesis del run cerrado (37851961397, 2026-10-08 22:12→23:05 UTC)** — el
bootstrap pasa de `binaryplatforms.jl`: **confirmada**.  `Unmatchable` aparece 0
veces en el log, `julia` arranca y `sysimage.mk` llega a invocar el bootstrap que
produce `sysbase-o.a`.

**Hipótesis del run cerrado (37862103015, 2026-10-08 23:55 → 2026-10-09 00:49 UTC,
~54 min)** — «los 8 alias existen antes de `make`, así que el bootstrap pasa de
`gmp.jl`: **FALSIFICADA**.  El run creó los ocho (`build.log:350`, 23:59:48) y no
tiene ni un `ln: failed` en 12 128 líneas; a las 00:49:48 murió en el mismo sitio
con el mismo texto: `LoadError("gmp.jl", 0, ErrorException("could not load library
\"libgmp.so.10\"\ndlopen failed: library \"libgmp.so.10\" not found"))` →
`sysimage.mk:129: usr/lib/julia/sysbase-o.a Error 1`.  Falló la premisa espacial, no
la temporal: el objeto que emite el `dlopen` de un nombre sin barra es
`src/dlload.c:376`, que vive dentro de `libjulia-internal.so`, y en el árbol de build
esa librería se enlaza en `$(build_shlibdir)` = `usr/lib` con `RPATH_LIB` =
`-rpath,'$ORIGIN'` (`Make.inc:1475,1472`; `src/Makefile:417`) — su conjunto de
búsqueda es **su propio directorio**, y `usr/lib/julia` no está en él.  El `RUNPATH`
del ejecutable (`$ORIGIN/../lib`, `$ORIGIN/../lib/julia`) no cubre ese `dlopen` porque
`--enable-new-dtags` hace RUNPATH, no RPATH, y quien busca es la librería.  Medido en
el teléfono dos veces: (a) con el paquete ya instalado, `readelf -d
$PREFIX/lib/julia/libjulia-internal.so` → `RUNPATH [$ORIGIN:$ORIGIN/..]`, por eso el
alias instalado en `lib/julia` **sí** es correcto (`make install` mueve el objeto a
`$(private_libdir)` y `Makefile:481` le fija ese RUNPATH); (b) reproduciendo el layout
del árbol de build (`$PREFIX/tmp/ororigin-probe`: librería en `usr/lib` con
`RUNPATH=$ORIGIN` que hace `dlopen("libgmp.so.10")`), alias en `usr/lib/julia` → el
mensaje exacto de CI, alias en `usr/lib` → resuelto.

**Hipótesis del próximo run** — con los alias en el directorio que el loader busca, el
bootstrap pasa de `gmp.jl` y `sysimage.mk:129` produce `sysbase-o.a`.  La receta enlaza
ahora en `usr/lib` antes de `make` (`build.sh:192`) y sigue enlazando en
`$PREFIX/lib/julia` tras install (`build.sh:219`); el directorio ya no es un literal,
lo deriva `scripts/runtime-library-dir.sh` preguntándole a `make` y el gate confronta
esa respuesta con los destinos de la receta (rojo→verde: `FAIL nothing links the
aliases into usr/lib (the build tree)` → `OK the aliases for the build tree go to
usr/lib, the directory make names`).  Lo que este run todavía no mide: `sys-o.a`
(`sysimage.mk:109-125` ejecutando `contrib/generate_precompile.jl` con
`--cpu-target=native` y precompile paralelo), `pkgimage.mk` y `make install`.

Riesgo residual declarado: después de `sysimage.mk:129` vienen `julia-sysimg-*`,
el `stdlib` y `JULIA_PRECOMPILE := 1`, territorio que todavía no corrió en
Android; si el run cae ahí, la nueva línea de `make` y el `LoadError` dicen desde
dónde ampliar el gate. Como `packages/**` y `scripts/**` cambian, la clave de
caché no hit y el run vuelve a pagar la compilación completa (~45-47 min).

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
| 37841320064 | 21:33 | `GATE: PASS` + `PROBE: PASS` y **la hipótesis de `libblas.so` confirmada en el build real**: `System library symlink failure` aparece 0 veces en el log y se crean 19 `ln -sf /data…`, entre ellos `libblas.so → $PREFIX/lib/libopenblas.so` y `liblapack.so → …`; `julia-base` termina y el run muere ~47 min después en `sysimage.mk:129: usr/lib/julia/sysbase-o.a Error 1` → `Makefile:114: julia-sysimg-release Error 2`, con `LoadError("binaryplatforms.jl", 0, ArgumentError("Platform \`ERROR: Unmatchable platform string 'aarch64-unknown-linux-gnu24'!-julia_version+1.12.6\` is not an officially supported platform"))` | `base/Makefile:85` empotra `$(BB_TRIPLET_LIBGFORTRAN_CXXABI)` como `const BUILD_TRIPLET`, y esa variable es el stdout de `contrib/normalize_triplet.py $(BUILD_MACHINE)` invocado en `Make.inc:1380` **sin mirar el rc**. `clang -dumpmachine` en Termux es `aarch64-unknown-linux-android24` (medido en el teléfono; en el runner: `checking host system type... aarch64-unknown-linux-android24`, línea 4306 del log) y las tablas del script no conocen android, así que el script imprimió su queja y **ese texto se convirtió en la constante**; `binaryplatforms.jl:958` le añade `-julia_version+1.12.6` y `parse` (línea 769) aborta el bootstrap. El parche que había (`base-binaryplatforms.jl.patch`, `replace("-android" => "-gnu")` dentro de `parse`) actuaba una capa más abajo: reescribía el mensaje de error — de ahí la `24` escrita como `gnu` — y no podía arreglar nada. Verificado con el `triplet_regex` de `base/binaryplatforms.jl:678-695` transcrito a Python: ni la cadena cruda, ni la reescrita, ni el triple crudo matchean; `aarch64-linux-gnu-cxx11(-julia_version+1.12.6)` sí | `packages/julia/contrib-normalize_triplet.py.patch` en dos hunks: canoniza `-android<api>` → `-gnu` donde nace la cadena y deja de reclamar `-libgfortran5` (con el triple arreglado el default "sin versión → libgfortran5" habría añadido la etiqueta, `Make.inc:1385` la convierte en `LIBGFORTRAN_VERSION=5` y `base/Makefile:239` pide `libgfortran.so.5` **sin** `ALLOW_FAILURE`: la lista derivada pasó de 19 a 20 nombres y la sonda lo marcó como `MISS` antes de gastar un run); se elimina `base-binaryplatforms.jl.patch`; `USE_BINARYBUILDER := 0` de `Make.user` sigue ganando al `?=` de `Make.inc:1366`, así que arreglar el script no activa las descargas de BinaryBuilder. Gate nuevo `scripts/embedded-triplet.sh` + sección `embedded platform triplet` en `rehearse-recipe.sh`: pregunta a `make` el valor que se va a empotrar y exige que sobreviva un round-trip por el propio `contrib/normalize_triplet.py` con el `$(PYTHON)`/`invoke_python` de Make.inc. Rojo→verde en el teléfono: gate13 `triplet=1` (FAIL), gate14 `triplet=0 resolution=1` (libgfortran), gate15 `triplet=0 resolution=0`, 19 nombres, `PROBE: PASS` |

| 37851961397 | 22:12→23:05 | **hipótesis del triplet confirmada en el build real**: `Unmatchable` aparece 0 veces en el log y `julia-base` termina; ~49 min después el run aborta otra vez en `sysimage.mk:129: usr/lib/julia/sysbase-o.a Error 1`, ahora con `LoadError("sysimg.jl", 0, LoadError("Base.jl", 0, LoadError("gmp.jl", 0, ErrorException("could not load library \"libgmp.so.10\"\ndlopen failed: library \"libgmp.so.10\" not found"))))` (líneas 15842-15847 del log, 23:05:03Z) | causa distinta, una capa más abajo: `base/gmp.jl:32` y `base/mpfr.jl:40` piden al loader nombres versionados estilo glibc como **literales** (upstream no lo nota porque compila su propio GMP, cuyo SONAME sí lleva la versión) y `dlopen` de Android empareja el **nombre de fichero**, así que `$PREFIX/lib/libgmp.so` no responde `libgmp.so.10` — medido con `readelf -d` sobre el prefijo: ningún SONAME de Termux lleva versión. El alias de `base/Makefile` (`symlink_system_library`, línea 162) no puede ayudar: crea el nombre **sin** versión en `usr/lib/julia` y `libwhich -p libgmp.so.10` no resuelve. Y la receta creaba los symlinks en `termux_step_post_make_install`, **después** de `make`: por eso `pacman -Qo` atribuye `libgmp.so.10`/`libmpfr.so.6` al paquete julia instalado mientras el build nunca los vio | `packages/julia/soname-aliases.sh` lee los nombres pedidos del fuente (`base/*.jl`, `stdlib/*/src/*.jl`) y veredicta cada uno `native`/`alias`/`built`/`absent` contra el prefijo; `termux_link_soname_aliases` en la receta los enlaza en `usr/lib/julia` **antes** de `make` y de nuevo en `$PREFIX/lib/julia` tras install, borrando la lista a mano de tres pares. Sección `dlopen'ed versioned sonames` en `rehearse-recipe.sh`: cruza los `absent` con la lista REQUIRED de `symlinked-libraries.sh` (un nombre letal para `julia-base` y sin respuesta = FAIL) y exige que `termux_step_make` invoque la derivación antes de su `make`. Rojo→verde: gate16 `sonames=1` (`FAIL build.sh never creates the aliases the source demands`, rc=5) → gate17 `sonames=0`, 8 alias (`libcurl.so.4`, `libgit2.so.1.9`, `libgmp.so.10`, `libgmpxx.so.4`, `libmpfr.so.6`, `libnghttp2.so.14`, `libpcre2-8.so.0`, `libssh2.so.1`), 21 `native`, `libblastrampoline.so.5` `built` y 8 `absent` inocuos |

| 37859841658 | 23:30→23:35 | `GATE: PASS` en el runner (`sonames=0`) y **la hipótesis de `libgmp.so.10` no llegó a medirse**: el job build murió a los 4 min 21 s, antes de entrar a `make`, con `ln: failed to create symbolic link 'usr/lib/julia/libcurl.so.4': No such file or directory` (línea 1478 del log, 23:35:01Z) y `build rc=1`.  La tabla de veredictos sí se imprimió completa en el runner: los mismos 8 `aliased` que en el teléfono | el fix estaba roto, no la hipótesis: `termux_link_soname_aliases` enlazaba en `usr/lib/julia` **antes** de `make`, y ese directorio lo crea `make`; con `set -e` del harness el primer `ln` abortó el build.  El gate verde no lo veía porque su chequeo nuevo era estático (¿`termux_step_make` llega a la derivación antes de su `make`?) y no preguntaba si el destino existe.  Detalle honesto adicional: en el prefijo del runner `libopenlibm.so.4` sale `left absent` (en el teléfono es `native` porque el julia instalado lo dejó ahí) y no es un fallo — `USE_SYSTEM_OPENLIBM` no está en 1, así que `make` no pide ese nombre; el veredicto del helper describe el prefijo, no el árbol de build | `mkdir -p "${_dir}"` en la función, demostrado en el teléfono: la misma invocación contra un directorio inexistente ahora devuelve `rc=0` con 8 enlaces.  Gate: el chequeo de wiring pasó a exigir también que **quien enlaza antes de `make` cree el directorio de destino** (`FAIL  %s links into a directory it never creates`); discrimina — con la receta corregida `OK`, con la misma receta sin la línea de `mkdir` `FAIL` |

| 37862103015 | 23:55→00:49 (~54 min) | **hipótesis de los sonames FALSIFICADA**: la tabla del helper se imprimió completa con los 8 `aliased` (línea 350, 23:59:48.5715505Z) y no hay ni un `ln: failed` entre las 12 128 líneas del log, así que los enlaces existieron durante todo el build; y aun así el bootstrap aborta idéntico — `LoadError("gmp.jl", 0, ErrorException("could not load library \"libgmp.so.10\"\ndlopen failed: library \"libgmp.so.10\" not found"))` (línea 12121, 00:49:48.7302374Z) → `sysimage.mk:129: usr/lib/julia/sysbase-o.a Error 1`, `build rc=2`. Marcadores: `could not load library`=1, `sysbase-o.a`=2, `sys-o.a`=0, `generate_precompile`=0, `Killed`=0 | el fichero no faltaba: **estaba donde el loader no mira**. El `dlopen` de un nombre sin barra lo emite `src/dlload.c:376`, dentro de `libjulia-internal.so`, y esa librería se enlaza en `$(build_shlibdir)` = `usr/lib` (`src/Makefile:417`; `Make.inc:729,328,320`) con `RPATH_LIB := RPATH_ORIGIN = -Wl,-rpath,'$ORIGIN'` (`Make.inc:1475,1472`): su conjunto de búsqueda es **su propio directorio** y nada más. `usr/lib/julia` —donde `julia-base` deja sus symlinks sin versión y donde la receta puso los alias— no figura en ese RUNPATH, y en todo el log no aparece un solo `LD_LIBRARY_PATH`, así que tampoco entró por la variable de entorno. Nota de capa: `base/gmp.jl:35` no usa `Libdl.dlopen`, usa `cglobal` a nivel top-level, que es exactamente la ruta de `jl_load_library` | Reproducido y discriminado en el teléfono con el mismo layout (`$PREFIX/tmp/ororigin-probe`: una librería en `usr/lib` con `RUNPATH=$ORIGIN` que hace `dlopen("libgmp.so.10")`): alias en `usr/lib/julia` → `dlopen failed: library "libgmp.so.10" not found`, el mismo mensaje que CI; el mismo alias en `usr/lib` → resuelto. Fix: el call site del árbol de build pasa a `usr/lib`. El instalado se queda en `$PREFIX/lib/julia` porque `make install` **mueve** `libjulia-internal` ahí y le reescribe el RUNPATH a `$ORIGIN:$ORIGIN/../` (`Makefile:468-481`) — el mismo dato confirma que la aserción `lib/julia/libblastrampoline.so.5` es correcta, porque `Makefile:223` la clasifica de librería privada con `USE_SYSTEM_LIBBLASTRAMPOLINE := 0`. Para que un directorio escrito a mano no vuelva a costar un run: `scripts/runtime-library-dir.sh` le pregunta a make `$(build_shlibdir)`, `$(private_libdir)`, `$(RPATH_LIB)` y `$(reverse_private_libdir_rel)` (rechaza el resultado si `RPATH_LIB` ya no menciona `$ORIGIN`) y la sección `dlopen'ed versioned sonames` del gate exige que los destinos de `termux_link_soname_aliases` sean exactamente esa respuesta |

Ruido benigno conocido del runner: `linker: Warning: failed to find generated
linker configuration from "/linkerconfig/ld.config.txt"`,
`__bionic_open_tzdata: …`, `bionic-icu: couldn't open libicu.so`,
`expr: syntax error: unexpected argument 'Warning:'` (el anterior se cuela en
una sustitución de comando de `configure`; autoconf cae a su default y sigue),
y `Warning: git information unavailable`.  NO es ruido `error: linker cannot load
itself`: ese era la causa de 37811196090, y aparecerá igual en todo proceso que
pida `dlopen` del linker del runner.

### Tramo siguiente (`sys-o.a` + precompile): riesgos ya medidos

- **`RTLD_DEEPBIND` no rompe nada.** `contrib/generate_precompile.jl:231` hace
  `dlopen("libjulia", RTLD_LAZY | RTLD_DEEPBIND)` y `base/libdl.jl:30` define
  `RTLD_DEEPBIND = 0x40` como constante hardcodeada, así que parecía un abort
  seguro: medido en el teléfono (2026-10-08 ~22:20 UTC), `dlopen("libz.so",
  RTLD_LAZY|0x40)` sobre la libc devuelve `invalid flags to dlopen: 41`. Pero el
  `dlopen` de Julia no pasa la bandera cruda: `src/dlload.c:210` la envuelve en
  `#if defined(RTLD_DEEPBIND)` y bionic **no** la define (probe con
  `#ifdef`: `RTLD_NODELETE` sí, `RTLD_DEEPBIND`/`RTLD_FIRST` no), así que
  `jl_dlopen` la descarta y `default_rtld_flags = RTLD_LAZY|RTLD_DEEPBIND`
  (`base/libdl.jl:49`) es inofensivo en Android. La falla solo aparece al
  llamar a la libc directamente, que es lo que sondeé primero.
- **Las stdlibs externas ya se bajaron bien en CI.** 15 de las 66 entradas de
  `stdlib/` son ficheros `*.version` (`Pkg`, `LinearAlgebra`, `SparseArrays`,
  `Distributed`, `LibCURL`, `StyledStrings`, …) que `deps/tools/stdlib-external.mk`
  descarga de `api.github.com/repos/…/tarball/$SHA`. En 37841320064 el log no
  tiene ni una línea de `Pkg` (GitHub omitió la ventana 21:25→21:33), pero
  `Makefile:113` hace a `julia-stdlib` prerequisito de `julia-sysimg-release` y
  el recipe de ese target fue el que corrió `sysimage.mk`, así que la descarga
  terminó con éxito: el límite de tasa anónimo de `api.github.com` no es un
  bloqueo observado.

- **`left absent  libdSFMT.so` en la tabla del helper no es un riesgo: es su
  límite.** `soname-aliases.sh` decide `built` con una lista a mano
  (`built_by_us="libblastrampoline libLLVM"`), así que todo lo que el build
  produce pero **sin versión en el nombre** cae en `absent` aunque vaya a existir
  en el árbol.  Medido sobre el tarball pineado: `deps/dsfmt.mk:45` copia
  `libdSFMT.$(SHLIB_EXT)` a `$(build_shlibdir)` y `Make.inc:45` fija
  `USE_SYSTEM_DSFMT:=0` (no es un flag de la receta), o sea `usr/lib/libdSFMT.so`
  existe durante el precompile y `stdlib/dSFMT_jll/src/dSFMT_jll.jl:29` lo
  `dlopen` (con throw por defecto), encontrándolo por el `RUNPATH`
  `$ORIGIN:$ORIGIN/..` de `libjulia-internal.so`.  La derivación que reemplaza la lista son las líneas
  `$(INSTALL_NAME_CMD)libNAME.$(SHLIB_EXT) $(build_shlibdir)/…` de `deps/*.mk`,
  verificadas contra el `USE_SYSTEM_*` efectivo.  **No se toca ahora**: es
  comentario sobre el artefacto de caché (`hashFiles('packages/julia/**')`) y
  pagar ~49 min por un veredicto que hoy no cambia ningún enlace sería comprar
  ruido con runs.  Queda como primer cambio a plegar en el próximo fix real.

- **`libunwind.so.8` sí es ausencia real, y hoy no la pide nadie.** Mismo nombre
  `left absent` en la tabla del helper, clase distinta: `deps/Makefile:61` solo
  añade `unwind` a `DEPS_LIBS` si `DISABLE_LIBUNWIND` es `0`, y la receta lo fija
  en `1` (`packages/julia/build.sh:126`, "aarch64 uses Julia's own assembly task
  switching"), así que el `.so` **no se produce tampoco en el árbol** (a diferencia
  de `libdSFMT.so`, que `deps/dsfmt.mk:45` sí instala en `usr/lib`).  El demandante
  es `stdlib/LibUnwind_jll/src/LibUnwind_jll.jl:20` (el literal) y su `dlopen` con
  throw en `__init__` (`:21-25`), guardado por
  `@static if Sys.islinux() || Sys.isfreebsd()`: se compila **dentro** si
  `Sys.islinux()` es cierto en Android, que es lo esperable porque `Sys.KERNEL`
  sale de `uname` y Android reporta `Linux` — medido todavía no.  Buscado en todo el árbol
  (`*.toml`, `*.jl`, `Makefile`, `*.mk`),
  ningún otro stdlib ni `base/` depende de ese módulo — solo aparece en
  `stdlib/Project.toml:25` y `stdlib/stdlib.mk:10`, que lo **instalan** pero no lo
  cargan.  `__init__` corre al cargar, y evaluar/precompilar un módulo no lo
  ejecuta, así que tampoco es bloqueo demostrado.  Condición para que lo sea: un
  `LoadError("…libunwind.so.8…")` en el log.  El fix entonces es `DISABLE_LIBUNWIND := 0`
  (dejar que `deps/unwind.mk` lo compile, cuyo SONAME de GNU ya lleva el `.8`),
  **no** un alias hacia nada: en bionic no existe un `libunwind.so` al que apuntar.

- **Los 8 `alias` se crean ahora antes de `make`, y en el directorio que lee el
  loader.** El tramo que sigue a `sysbase-o.a` tampoco está medido en Android:
  `sysimage.mk:109-125` produce `sys-o.a` ejecutando `contrib/generate_precompile.jl`,
  que spawnea `$(julia_exepath()) -O0 --trace-compile=… --cpu-target=native` con
  `PARALLEL_PRECOMPILE` y luego `pkgimage.mk` (`stdlibs-cache-%`) y `make install`.
  Cada una de esas etapas abre un `julia` nuevo, así que los nombres versionados que
  los `_jll` del árbol vendido piden (`libcurl.so.4`, `libgit2.so.1.9`,
  `libssh2.so.1`, `libnghttp2.so.14`, `libgmpxx.so.4`, `libpcre2-8.so.0`) tienen que
  existir ya **en `usr/lib` durante el build** (es el `$ORIGIN` de
  `libjulia-internal.so`, §3.7) y en `$PREFIX/lib/julia` una vez instalado; por eso
  el fix se puso en `termux_step_make` y no solo tras install.  `--cpu-target=native`
  es el siguiente candidato a problema si `sys-o.a` falla: es un **literal** de
  `contrib/generate_precompile.jl:360` (medido: `JULIA_CPU_TARGET` no aparece en el
  script, así que el `generic` de la receta solo gobierna la invocación externa de
  `sysimage.mk:118`), y **no se puede medir en este teléfono**: el `julia` de
  referencia aborta antes de evaluar nada (bullet siguiente), así que ningún `-e`
  sobrevive a `--cpu-target`.

- **El propio paquete de Termux corrobora el directorio del árbol instalado.**
  `ls -l $PREFIX/lib/julia` muestra `libgmp.so.10 -> libgmp.so` y
  `libmpfr.so.6 -> libmpfr.so` con la fecha de instalación (08-18 17:43), y
  `pacman -Qo` responde que **los posee `julia 1.12.6-1`**: upstream hace exactamente
  lo que la receta repite tras `make install`, en `$(private_libdir)`, porque allí el
  `RUNPATH` de `libjulia-internal.so` es `$ORIGIN:$ORIGIN/..`.  Lo que **no** trae es
  `libcurl.so.4` (`pacman -Qo`: *no package owns*), así que la asimetría entre los dos
  árboles no es una excentricidad nuestra: es la diferencia entre `$ORIGIN` de build y
  `$ORIGIN` de instalado.

- **El `julia` de referencia instalado en el teléfono no evalúa código (medido
  2026-10-09 ~01:45 UTC).** El paquete `julia 1.12.6-1` de Termux (instalado
  2026-08-18 según `var/log/pacman.log`, `pacman -Qk julia` → 5805 archivos, 0
  faltantes) responde a `julia --version` pero muere en el arranque del resto:
  `julia -e 'exit(3)'` devuelve **rc=1** (el código del usuario nunca corre),
  `julia -e 'open("/…/eval.txt","w")'` no crea el fichero, `--banner=yes` no
  imprime el banner, y lo único que sale son
  `OpenBLAS_jll init failed` / `libblastrampoline_jll init failed` con
  `ArgumentError: cannot convert NULL to string`, más
  `Unable to autodetect symbol suffix of ""` y
  `No loaded BLAS libraries were built with LP64 support.`  No es el entorno de
  este shell: con `LD_LIBRARY_PATH=$PREFIX/lib` exportado el resultado es el mismo
  (`rc=1`), y en Termux el `LD_PRELOAD` de `libtermux-exec` está activo.  El
  mecanismo está identificado y **es el que nuestros parches ya cubren**:
  `libblastrampoline_jll.__init__` llama a `dlpath(handle)`, que va a
  `jl_pathname_for_handle` (`src/sys.c:655`); en la rama Linux esa función hace
  `dlinfo(handle, RTLD_DI_LINKMAP, &map)`, que en Bionic no resuelve, y devuelve
  `NULL` → `unsafe_string(NULL)` → exactamente el `cannot convert NULL to string`
  observado.  Upstream solo define `_OS_LINUX_` en Android
  (`src/support/platform.h:89`, medido sobre el tarball pineado: ni `__ANDROID__`
  en `sys.c` ni rama propia en `dlload.c`), y por eso la receta lleva
  `src-support-platform.h.patch` (define `_OS_ANDROID_`), `src-sys.c.patch` (esa
  rama pasa a `dl_iterate_phdr`, el mismo truco que `termux-libwhich-dlinfo-android.patch`)
  y `stdlib-libblastrampoline_jll.jl.patch` + `stdlib-OpenBLAS_jll.jl.patch` (la
  ruta se calcula desde `Sys.BINDIR` en `__init__`, no se pregunta al loader).  Lo
  que no cuadra del paquete de Termux es que sus `.jl` en disco **ya** traen ese
  fix (`libblastrampoline_jll.jl:35` dice "dlpath … returns NULL on Android/Bionic
  — skip it") mientras el `sys.so` instalado corre el código anterior: los avisos
  citan `:37` y `:53`, y en los ficheros de ahora ninguna de esas dos líneas es un
  `@warn` (el de `OpenBLAS_jll` está en `:46`; el de LBT ni siquiera usa `@warn`,
  imprime `LBT ACTUAL ERROR` en `:42`).  Consecuencias para el port: (a) **Fase 5 no puede usar "el paquete de referencia funciona" como baseline** —`device-smoke.sh` se afirma contra sus
  propios `assert`s, no contra una comparación que hoy no existe en este
  dispositivo—; (b) nada de esto es evidencia sobre nuestra receta: el `sys.so`
  roto es el de `julia 1.12.6-1`, y si el artefacto nuestro muestra los mismos
  avisos, entonces sí, el patch de `sys.c` no estuvo activo en ese build.

- **El runtime GNU no existe en el prefijo; `CompilerSupportLibraries_jll` es el
  candidato nombrado para `sys-o.a`.** Medido en el teléfono (2026-10-08 ~18:00
  local): no hay `libgcc_s*`, `libgfortran*`, `libstdc++*`, `libgomp*` ni `libssp*`
  ni en `$PREFIX/lib` ni en `$PREFIX/lib/julia` (Termux usa clang + libc++), y
  `stdlib/CompilerSupportLibraries_jll/src/…:57-64` los dlopen **con throw**.  Sus
  únicas aristas de dependencia son `OpenBLAS_jll/Project.toml` y
  `p7zip_jll/Project.toml`, y el propio `OpenBLAS_jll` upstream tiene comentado el
  `using CompilerSupportLibraries_jll` (nuestro `stdlib-OpenBLAS_jll.jl.patch` ya
  salta el `dlopen(_libgfortran)`).  instantiate ≠ init: un módulo congelado en la
  imagen no ejecuta `__init__` si nadie lo carga, así que esto **no** está
  demostrado como bloqueo; si `sys-o.a` muere con
  `could not load library "libgcc_s.so.1"`, el parche es ese archivo (o bajar
  `JULIA_PRECOMPILE` a 0), no otro alias.

### Avance medible del build

`12 ms` (ni arrancaba) → `4 min` (parches + configure) → `4.5 min`
(deps/libuv/LBT) → `43 min` (LLVM 18.1.7-4 completo; flisp caía en endianness) →
`44 min` (flisp compila, `src/` se construye, muere en `julia-base` al enlazar las
system libs) → `47 min` (`julia-base` termina con sus 19 symlinks; aborta
`sysimage.mk:129` por el `BUILD_TRIPLET` empotrado) → `49 min` (el triplet ya
parsea, `julia` arranca y el bootstrap de `sysbase-o.a` muere en el nombre
versionado `libgmp.so.10`, que la receta resolvía después de `make`) → `4.4 min`
**de regresión** (37859841658: el fix de sonames enlazaba en un `usr/lib/julia`
que todavía no existe; `make` no llegó a arrancar, así que la hipótesis sigue sin
medir) → `~50 min` (37862103015: el `mkdir -p` devolvió la cadena a su punto más
lejo, los 8 alias se crearon y aun así `sysbase-o.a` muere con el mismo
`not found`; la hipótesis de presencia queda **falsificada** y la causa real es de
directorio —`usr/lib`, el `$ORIGIN` de `libjulia-internal.so` —, medida en el
teléfono).

---

## Pendientes

1. **Fase 4 (en curso)**: que un run llegue a producir el `.deb`.  El run
   `37870492832` (`c5a575e`, 2026-10-09 01:35 UTC) mide la hipótesis del
   directorio; mientras no exista artefacto, `bundle` y `publish` siguen
   `skipped`.
2. **Fase 5 — verificación en dispositivo**: instalar `.deb`/`.pkg.tar.xz`,
   correr `julia --version`, `versioninfo()`, `Pkg.test` de un paquete puro de
   Julia y la batería de smoke de `test/`; con evidencia fechada. "Compila" no
   es "funciona".  **Y sin baseline prestada**: el `julia` de referencia de este
   teléfono no evalúa código (bullet arriba), así que `device-smoke.sh` se
   afirma contra sus propios `assert`s, no contra "el otro julia sí anda".
   Antes de fiarse de una comparación, abrir la causa raíz de ese arranque roto
   (es el paquete de Termux, no esta receta).
3. **Plegar la derivación de `built`**: `packages/julia/soname-aliases.sh` decide
   `built` con la lista a mano `built_by_us="libblastrampoline libLLVM"`.  La
   derivación que la reemplaza está nombrada arriba (`$(INSTALL_NAME_CMD)libNAME.$(SHLIB_EXT)
   $(build_shlibdir)/…` en `deps/*.mk`, cruzado con el `USE_SYSTEM_*` efectivo).
   **No se toca mientras haya un run en curso**: vive en `packages/**`, así que
   invalida la clave de caché y costaría ~50 min por un veredicto que hoy no
   cambia ningún enlace.
4. **Fase 2 (opcional)**: `packages/llvm-julia` solo si el LLVM bundled resulta
   no cacheable.
5. **Limpieza**: restos de sesiones en `$PREFIX/tmp` (`gate*.txt`,
   `watch-*.txt/.sh`, `rehearse-*.txt`, `julia-rehearse.*`, `tp-clone.55c0Aq`,
   `tp-path`, `julia-index-cache`, `julia-rehearse-cache`, logs de diagnóstico)
   al terminar los runs.  Hecho 2026-10-09: se borraron `julia-rehearse.CtINL5`,
   `julia-rehearse.i5mnhh`, `rtlib-test.tPVm63`, `dlload-read.zpiRpY` y
   `gate-red.7807` (~230 MB).  Quedan a propósito: `julia-rehearse-cache` (17 MB,
   es la caché del gate), `julia-run-u4kkcj` (el log con el que se compara este
   run) y `ororigin-probe` (la reproducción citada en `ARCHITECTURE.md` §3.7).
   Los `jpre.*`/`jdiag.*` de las mediciones de esta tarde se borran al cerrar
   Fase 5.
6. **Restos de la ruta Docker** (`scripts/Dockerfile`, `run-docker.sh`,
   `build-deps-docker.sh`, `setup-ccache-docker.sh`, `build-local.sh`,
   `ndk-patches/`, `trace-dl/`, `tasks/`, `.github/actions/zram/`): están
   declarados como ruta muerta en `README.md`, pero borrarlos es destructivo y
   necesita OK explícito del usuario.

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
