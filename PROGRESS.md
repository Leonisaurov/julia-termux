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

**Estado** (2026-10-08): la arquitectura de build está validada de punta a punta
hasta el minuto 49; el compilador llega a `src/`, enlaza `julia-base` con los 19
symlinks, arranca `julia` y muere en el bootstrap de la imagen por los nombres
versionados que el fuente pide al loader.  Quedan por demostrarse `sys-o.a` +
precompile, empaquetado y la verificación en dispositivo.

| Pieza | Estado |
|---|---|
| Receta declarativa `packages/julia/build.sh` | OK (22 parches aplican, `configure` genera un `Make.user` que `Make.inc` acepta) |
| Gates estáticos locales | OK y en el DAG de CI |
| Entorno de runner (`termux-builder`) | OK: materializa un prefijo Termux real en `ubuntu-24.04-arm` |
| LLVM 18.1.7-4 bundled compilado | OK (43 min) |
| `src/` de Julia y `julia-base` | OK (flisp, runtime y los 19 symlinks de system libs, `libblas.so`/`liblapack.so` incluidos) |
| Sysimage (`sysimg`/`base/`) | aborta en `sysimage.mk:129` (`sysbase-o.a`): el triplet quedó cerrado y **confirmado en CI** (37851961397); la causa nueva —sonames versionados— tiene fix y gate, sin medir todavía en CI |
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
- `.github/scripts/termux-closure-resolver.py` — cierre de dependencias del
  índice de Termux (roots = bootstrap recortado + Tier 1 de
  `scripts/setup-termux.sh` + `termux-elf-cleaner` + `TERMUX_PKG_*DEPENDS` de la
  receta).

**Hipótesis del run cerrado (37851961397, 2026-10-08 22:12→23:05 UTC)** — el
bootstrap pasa de `binaryplatforms.jl`: **confirmada**.  `Unmatchable` aparece 0
veces en el log, `julia` arranca y `sysimage.mk` llega a invocar el bootstrap que
produce `sysbase-o.a`.

**Hipótesis del próximo run** — el bootstrap pasa de `gmp.jl` y `sysimage.mk:129`
produce `sysbase-o.a`.  La cadena está medida en sus dos extremos: `base/gmp.jl:32`
pide `"libgmp.so.10"` y `base/mpfr.jl:40` `"libmpfr.so.6"` como literales (son los
únicos versionados de `base/*.jl`), ningún SONAME del prefijo lleva versión
(`readelf -d`) y el `dlopen` de Android empareja nombres de fichero, así que el
loader respondió `library "libgmp.so.10" not found` a pesar de que
`$PREFIX/lib/libgmp.so` estaba instalado.  Los 8 alias que la derivación detecta se
crean ahora en `usr/lib/julia` **antes** de `make`; que ese directorio esté en la
búsqueda es medible en el paquete instalado: `readelf -d libjulia-internal.so` da
`RUNPATH [$ORIGIN:$ORIGIN/..]` y `base/Makefile` ya enlaza ahí sus 19 nombres.  Lo
que este run todavía no mide: `sys-o.a` (`sysimage.mk:109-125` ejecutando
`contrib/generate_precompile.jl` con `--cpu-target=native` y precompile paralelo),
`pkgimage.mk` y `make install`.

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

- **Los 8 `alias` se crean ahora antes de `make`.** El tramo que sigue a
  `sysbase-o.a` tampoco está medido en Android: `sysimage.mk:109-125` produce
  `sys-o.a` ejecutando `contrib/generate_precompile.jl`, que spawnea
  `$(julia_exepath()) -O0 --trace-compile=… --cpu-target=native` con
  `PARALLEL_PRECOMPILE` y luego `pkgimage.mk` (`stdlibs-cache-%`) y
  `make install`.  Cada una de esas etapas abre un `julia` nuevo, así que los
  nombres versionados que los `_jll` del árbol vendido piden (`libcurl.so.4`,
  `libgit2.so.1.9`, `libssh2.so.1`, `libnghttp2.so.14`, `libgmpxx.so.4`,
  `libpcre2-8.so.0`) tienen que existir ya en `usr/lib/julia`; por eso el fix se
  puso en `termux_step_make` y no solo tras install.  `--cpu-target=native` es
  el siguiente candidato a problema si `sys-o.a` falla: aún no hay evidencia.

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
versionado `libgmp.so.10`, que la receta resolvía después de `make`).

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
