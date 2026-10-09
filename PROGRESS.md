# PROGRESS.md — Estado del proyecto julia-termux

> Última actualización: 2026-10-09 ~10:30 UTC
>
> Este archivo es el **registro de evidencia**: qué se intentó, qué falló, por
> qué y qué gate local cerró ese fallo. Las decisiones de diseño viven en
> `ARCHITECTURE.md`, pero ese archivo y `AGENTS.md`/`README.md` siguen
> describiendo la arquitectura abandonada (ver Pendientes §3).

---

## Resumen

Port de **Julia v1.12.6** a Termux/Android aarch64 mediante el build system de
`termux-packages`, construido en **CI** y validado **en el dispositivo**.

**Estado** (2026-10-09 ~10:30 UTC): la arquitectura de build está validada de punta
a punta hasta **el final de `make install`** (`37904805726`), y el tramo que mataba el
build en `37870492832` —la memoria— quedó **falsificada con medición**: `37876520515`
tomó 186 muestras cada 20 s y el `MemAvailable` **mínimo** fue 8 458 692 kB, y con el
`vm.max_map_count` del runner elevado de 262 144 a 1 048 576 el build **emitió**
`usr/lib/julia/sysbase-o.a` (03:46:37Z) y `usr/lib/julia/sys-o.a` (03:50:51Z) sin
un solo `std::bad_alloc`.  Los 68 avisos `scudo: Can't populate more pages` siguen
en el log pero ya no matan nada: son **crónicos** (34 en el run que murió por otra
causa) y hay que leerlos como ruido.

El muro del precompile **quedó cerrado por `37891178350`**: tras `JULIA
stdlib/release.image` (06:59:13Z) las stdlibs se precompilaron con sus dos
configuraciones —`✓ OpenLibm_jll`, `✓ CompilerSupportLibraries_jll`, `✓ Pkg`,
`✓ Test`— con `Failed to precompile`, `FieldError` y `dlpath(::Nothing)` a **cero**.
Esas tres firmas eran exactamente las del stub *dummy* de upstream
`stdlib/CompilerSupportLibraries_jll/src/CompilerSupportLibraries_jll.jl`, que da
por existente un **runtime GCC** que Termux no tiene: desreferenciaba
`libgfortran_version(HostPlatform()).major`, documentada como nullable
(`base/binaryplatforms.jl:454`), y hacía `dlopen` **sin guarda** de
`libgcc_s.so.1`/`libstdc++.so.6`/`libgomp.so.1` (líneas 57/61/63); las 330 líneas de
`MethodError: no method matching dlpath(::Nothing)` eran de **mis** parches `_jll`,
que usaban la centinela equivocada (`dlopen(…; throw_error = false)` devuelve
`nothing`, no `C_NULL` —`base/libdl.jl:119-125`—).

El fallo de ese run ya no es del port: `make install` se cayó en la **documentación
HTML**, que el propio Makefile de Julia pone como prerequisito de `install` y que se
construye instanciando un entorno contra el registro General —red, y no la que este
runner resuelve dentro de bionic para hosts con AAAA—.  **Ese muro está cerrado y
medido**: `37904805726` recorrió `make -j1 install` entero por primera vez.

Y ese run enseñó además que el abort final no era del build sino de **nuestra
aserción**: `build-package.sh:21` es `set -euo pipefail`, y en ese shell
`readelf -V f | grep -q PAT` deja de ser una prueba sobre `f` para ser una carrera
con él —`grep -q` sale en el primer match mientras `readelf` sigue escribiendo sus
35 056 entradas de versión, recibe SIGPIPE y el pipeline devuelve **141**, que `||`
lee como "sin match"—.  Medido en el teléfono contra la `libLLVM-18jl.so`
**publicada** (la que sí lleva `JL_LLVM_18.1`): la tubería vieja da 141 y la
corrección con la salida capturada da 0.  Quedan por demostrarse el empaquetado
(`.deb`) y la verificación en dispositivo.

El mismo cruce (`scripts/unguarded-dlopen.sh`) encontró después **otros dos stubs
con la misma forma de muro**, uno por día: `LibUnwind_jll` (`libunwind.so.8`, que
`DISABLE_LIBUNWIND := 1` no instala) y `OpenLibm_jll` (`libopenlibm.so.4`, que
`USE_SYSTEM_LIBM := 1` no instala), y los tres están declarados opcionales con
guarda `throw_error = false`.  Este último costó un run de 2 min 24 s **porque el
gate local no podía verlo**: el veredicto `native` se lo preguntaba al prefijo del
teléfono, donde ese fichero lo dejó el `julia` publicado que este port reconstruye.
Desde 2026-10-09 el gate pregunta a una copia del prefijo **sin los ficheros que
posee el paquete que se construye**, así que un `GATE: PASS` local y el del runner
responden a la misma pregunta.

| Pieza | Estado |
|---|---|
| Receta declarativa `packages/julia/build.sh` | OK (26 parches aplican, `configure` genera un `Make.user` que `Make.inc` acepta) |
| Gates estáticos locales | OK y en el DAG de CI; desde 2026-10-09 el veredicto de los sonames se pregunta al sysroot del build (prefijo sin los ficheros del paquete que se construye), no al prefijo del teléfono, y desde el mismo día la sección `goals and their prerequisites` exige que ningún objetivo que la recipe entrega a make dependa de `make docs` |
| Entorno de runner (`termux-builder`) | OK: materializa un prefijo Termux real en `ubuntu-24.04-arm` |
| LLVM 18.1.7-4 bundled compilado | OK (43 min) |
| `src/` de Julia y `julia-base` | OK (flisp, runtime y los 19 symlinks de system libs, `libblas.so`/`liblapack.so` incluidos) |
| Sysimage (`sysimg`/`base/`) | **emitida en CI**: `37876520515` produce `sysbase-o.a` **y** `sys-o.a`; la memoria quedó descartada como causa |
| Precompile de stdlibs (`pkgimage.mk:28`) | **muro actual**: tres stubs *dummy* cargan librerías que este build no produce (`CompilerSupportLibraries_jll`, `LibUnwind_jll`, `OpenLibm_jll`); los tres con guarda y validados en el gate local, sin correr en CI todavía |
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
  contra el prefijo como `native`/`alias`/`built`/`absent`.  El `built` ya no sale
  de una lista: filtra `deps/*.mk` con la respuesta de
  `make -C deps --eval='print-deplibs: ; @echo "DEPLIBS=$(DEP_LIBS)"' print-deplibs`
  sobre el árbol **configurado** (exige `Make.user` y aborta si make no responde),
  así que un dep apagado por `USE_SYSTEM_*`/`DISABLE_LIBUNWIND` no puede acreditar
  un nombre.  Lo consume `termux_link_soname_aliases` en la receta (antes de `make`
  y tras `install`) y la sección `dlopen'ed versioned sonames` del gate, que cruza
  los `absent` con la lista REQUIRED de `symlinked-libraries.sh`.
- `scripts/unguarded-dlopen.sh` — para cada nombre que nada responde, busca sus
  sitios de `dlopen` en los mismos ficheros que lee el helper anterior y veredicta
  `guarded`/`unguarded`.  Es la pieza que faltaba: un `absent` cargado sin
  `throw_error = false` aborta el precompile dentro de `make`
  (`pkgimage.mk:28`, run 37876520515) y el gate lo llamaba `note`.
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

**Hipótesis del run cerrado (37870492832, 2026-10-09 01:35 → 02:34 UTC, ~59 min)**
— con los alias en el directorio que el loader busca, el bootstrap pasa de `gmp.jl`:
**confirmada**.  `could not load library` aparece **0** veces en 13 394 líneas y el
propio bootstrap imprime su timing de carga (`Stdlibs total ─ 14,48 s`,
`Total ─ 54,34 s`): Base y las 14 stdlibs se cargaron con los 8 alias versionados
resueltos desde `usr/lib`.  El directorio ya no es un literal: lo deriva
`scripts/runtime-library-dir.sh` preguntándole a `make` y el gate confronta esa
respuesta con los destinos de la receta (rojo→verde: `FAIL nothing links the
aliases into usr/lib (the build tree)` → `OK the aliases for the build tree go to
usr/lib, the directory make names`).

**Hipótesis del run cerrado (37876520515, 2026-10-09 02:52 → 03:56 UTC, ~62 min)**
— «el abort de `sysbase-o.a` es un muro de memoria del runner»: **FALSIFICADA**, y
por el instrumento que se añadió para medirla.  Con `vm.max_map_count` en 1 048 576 y
186 muestras del watchdog, el peor `MemAvailable` del run fue **8 458 692 kB** (≈8 GB
libres de los 15 947 del runner), no hubo `St9bad_alloc` ni `signal 6`, y el build
llegó a emitir **`sysbase-o.a` y `sys-o.a`**.  Las tres candidatas (pico de RSS, VMAs,
overcommit) quedan descartadas como *causa del abort*: los 68 avisos `scudo` siguen
ahí, pero cruzados con el run anterior (34 avisos muriendo por otra causa) son ruido
crónico de LLVM, no el fallo.  El zram, además, **no** aportó swap: `modprobe zram`
respondió `Exec format error` y el job siguió con el `/swapfile` de 3 G.  Lo que sí
mató el run es el siguiente tramo, y no era memoria: `pkgimage.mk:28 stdlib/release.image`
con `FieldError: type Nothing has no field major` dentro del precompile de
`CompilerSupportLibraries_jll`.

**Hipótesis del próximo run** — el muro es que **el stub de `CompilerSupportLibraries_jll`
da por existente un runtime GCC**: con el parche que lo hace opcional (`libgfortran`
queda `""` si `libgfortran_version()` responde `nothing`, y los cuatro `dlopen` se
vuelven tolerantes vía `load_runtime_library`) y con la centinela `nothing` corregida
en los otros dos `_jll`, `pkgimage.mk` precompila esa stdlib y el precompile de las
stdlibs avanza.  Es **una** hipótesis y medible en dos sentidos: si el run llega más
lejos, el tramo nuevo queda abierto; si vuelve a caer en `pkgimage.mk:28`, el `LoadError`
dirá qué stdlib sigue pidiendo algo que Android no tiene.  Riesgo declarado: los
nombres que el stub arma por interpolación (`libgfortran.so.<major>`) no los ve
ningún gate porque no son literales —los descarta el mismo parche—, y `dSFMT_jll`
carga sin guarda pero su nombre sí lo produce `deps` en `$(build_shlibdir)`
(`deps/dsfmt.mk:32,45,51`, y `dsfmt` está en el `$(DEP_LIBS)` que contesta make), así
que no es el muro.  `LibUnwind_jll` **sí** lo era: la derivación filtrada por
`$(DEP_LIBS)` lo deja `absent` y `scripts/unguarded-dlopen.sh` lo marcó
`unguarded …LibUnwind_jll.jl:25`, así que el parche de guarda entró en el mismo run
(una hipótesis, dos sitios de la misma clase: `dlopen` sin guarda de un nombre que
nada responde).  Como `packages/**` y
`.github/**` cambian, la clave de caché no hit y el run vuelve a pagar la compilación
completa (~45-50 min hasta LLVM, ~62 min hasta el tramo nuevo).

Riesgo residual declarado: después de `pkgimage.mk:28` vienen el resto de
`julia-sysimg-*`, `make install` y el empaquetado, territorio que todavía no corrió en
Android; si el run cae ahí, la nueva línea de `make` y el `LoadError` dicen desde
dónde ampliar el gate.

---

## Cadena de modos de fallo (evidencia fechada, 2026-10-08 → 2026-10-09)

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

| 37859841658 | 23:30→23:35 | `GATE: PASS` en el runner (`sonames=0`) y **la hipótesis de `libgmp.so.10` no llegó a medirse**: el job build murió a los 4 min 21 s, antes de entrar a `make`, con `ln: failed to create symbolic link 'usr/lib/julia/libcurl.so.4': No such file or directory` (línea 1478 del log, 23:35:01Z) y `build rc=1`.  La tabla de veredictos sí se imprimió completa en el runner: los mismos 8 `aliased` que en el teléfono | el fix estaba roto, no la hipótesis: `termux_link_soname_aliases` enlazaba en `usr/lib/julia` **antes** de `make`, y ese directorio lo crea `make`; con `set -e` del harness el primer `ln` abortó el build.  El gate verde no lo veía porque su chequeo nuevo era estático (¿`termux_step_make` llega a la derivación antes de su `make`?) y no preguntaba si el destino existe.  Detalle honesto adicional: en el prefijo del runner `libopenlibm.so.4` sale `left absent` (en el teléfono es `native` porque el julia instalado lo dejó ahí) y no es un fallo — `USE_SYSTEM_OPENLIBM` no está en 1, así que `make` no pide ese nombre; el veredicto del helper describe el prefijo, no el árbol de build **(Corrección 2026-10-09: el veredicto era el bueno y la exculpación no.  Quien apaga openlibm es `USE_SYSTEM_LIBM := 1`, porque `deps/Makefile:89-91` lo añade a `DEP_LIBS` sólo si *ambas* flags valen 0, y el nombre sí se pide: `stdlib/OpenLibm_jll/src/OpenLibm_jll.jl:28` lo `dlopen`ea sin guarda en el precompile.  Ese `note` del gate era un muro mal llamado inocuo y costó el run 37886407453; ver su fila.)** | `mkdir -p "${_dir}"` en la función, demostrado en el teléfono: la misma invocación contra un directorio inexistente ahora devuelve `rc=0` con 8 enlaces.  Gate: el chequeo de wiring pasó a exigir también que **quien enlaza antes de `make` cree el directorio de destino** (`FAIL  %s links into a directory it never creates`); discrimina — con la receta corregida `OK`, con la misma receta sin la línea de `mkdir` `FAIL` |

| 37862103015 | 23:55→00:49 (~54 min) | **hipótesis de los sonames FALSIFICADA**: la tabla del helper se imprimió completa con los 8 `aliased` (línea 350, 23:59:48.5715505Z) y no hay ni un `ln: failed` entre las 12 128 líneas del log, así que los enlaces existieron durante todo el build; y aun así el bootstrap aborta idéntico — `LoadError("gmp.jl", 0, ErrorException("could not load library \"libgmp.so.10\"\ndlopen failed: library \"libgmp.so.10\" not found"))` (línea 12121, 00:49:48.7302374Z) → `sysimage.mk:129: usr/lib/julia/sysbase-o.a Error 1`, `build rc=2`. Marcadores: `could not load library`=1, `sysbase-o.a`=2, `sys-o.a`=0, `generate_precompile`=0, `Killed`=0 | el fichero no faltaba: **estaba donde el loader no mira**. El `dlopen` de un nombre sin barra lo emite `src/dlload.c:376`, dentro de `libjulia-internal.so`, y esa librería se enlaza en `$(build_shlibdir)` = `usr/lib` (`src/Makefile:417`; `Make.inc:729,328,320`) con `RPATH_LIB := RPATH_ORIGIN = -Wl,-rpath,'$ORIGIN'` (`Make.inc:1475,1472`): su conjunto de búsqueda es **su propio directorio** y nada más. `usr/lib/julia` —donde `julia-base` deja sus symlinks sin versión y donde la receta puso los alias— no figura en ese RUNPATH, y en todo el log no aparece un solo `LD_LIBRARY_PATH`, así que tampoco entró por la variable de entorno. Nota de capa: `base/gmp.jl:35` no usa `Libdl.dlopen`, usa `cglobal` a nivel top-level, que es exactamente la ruta de `jl_load_library` | Reproducido y discriminado en el teléfono con el mismo layout (`$PREFIX/tmp/ororigin-probe`: una librería en `usr/lib` con `RUNPATH=$ORIGIN` que hace `dlopen("libgmp.so.10")`): alias en `usr/lib/julia` → `dlopen failed: library "libgmp.so.10" not found`, el mismo mensaje que CI; el mismo alias en `usr/lib` → resuelto. Fix: el call site del árbol de build pasa a `usr/lib`. El instalado se queda en `$PREFIX/lib/julia` porque `make install` **mueve** `libjulia-internal` ahí y le reescribe el RUNPATH a `$ORIGIN:$ORIGIN/../` (`Makefile:468-481`) — el mismo dato confirma que la aserción `lib/julia/libblastrampoline.so.5` es correcta, porque `Makefile:223` la clasifica de librería privada con `USE_SYSTEM_LIBBLASTRAMPOLINE := 0`. Para que un directorio escrito a mano no vuelva a costar un run: `scripts/runtime-library-dir.sh` le pregunta a make `$(build_shlibdir)`, `$(private_libdir)`, `$(RPATH_LIB)` y `$(reverse_private_libdir_rel)` (rechaza el resultado si `RPATH_LIB` ya no menciona `$ORIGIN`) y la sección `dlopen'ed versioned sonames` del gate exige que los destinos de `termux_link_soname_aliases` sean exactamente esa respuesta |

| 37870492832 | 01:35→02:34 (~59 min) | **hipótesis del directorio CONFIRMADA**: `could not load library` aparece **0 veces** en 13 394 líneas, el bootstrap llega hasta el final de la carga —`Stdlibs total ─ 14.479918 seconds`, `Total ─ 54.337887 seconds` (líneas 13267-13271, 02:33:40Z), `Allocations: 338327679 (Pool: 338324218; Big: 3461); GC: 68`— y aborta un paso más allá, al **emitir** el fichero: 49× `scudo: Can't populate more pages for size class N` (primera línea 3163 a 01:45:11Z, última 13300 a 02:33:40Z), 2× `libc++abi: terminating due to uncaught exception of type St9bad_alloc: std::bad_alloc` (13302-13303), `[23944] signal 6 (-1): Aborted` (13305) → `sysimage.mk:129: …/usr/lib/julia/sysbase-o.a Error 1`, `Makefile:114: julia-sysimg-release Error 2`, `build rc=2`. El OOM-killer **no** intervino: el único `Killed` del log (13333) es el patrón `grep` que el paso *Where the time went* se imprime a sí mismo | causa abierta, y no es "falta de RAM en reposo": a 01:39:32Z el action reportó `Mem: 15947 total / 12528 free / 14621 available` y `Swap: 3071 0 3071` (líneas 706-707). Tampoco es un síntoma del tramo final: los avisos scudo son **crónicos** —34 en 37862103015, que murió por otra causa— y aquí se agrupan en 01:45-01:46 (33 avisos, LLVM compilando con `-j4`) y 02:33 (16, el abort). Tres candidatas sin discriminar: pico real de RSS (4 × `cc1plus`/`as` + el `julia` del precompile sobre 15,9 GB), agotamiento de VMAs (scudo fragmenta su arena en muchos mappings y el límite del runner aún no está medido —`/proc/sys/vm/max_map_count` no es legible en el teléfono, así que lo imprime el propio run—), o `overcommit_memory=2`/heurística que rechaza el `mmap` grande haciendo que `malloc` devuelva NULL → `operator new` lance → `abort()`. El log no permite elegirlas porque **no contiene ninguna medición durante el build** | Este run no cierra una causa: **instrumenta**. El job build recibe red y medidor a la vez — `.github/actions/zram` (swap comprimido) y `sudo sysctl -w vm.max_map_count=1048576`, ambos con `continue-on-error` porque son mejora, no requisito; un watchdog que cada 20 s anota `MemAvailable/Committed_AS/CommitLimit/SwapTotal/Writeback`, los 3 procesos de mayor RSS y los `vmas`+`VmRSS` de cada `julia`; y un paso `if: always()` que reporta nº de muestras, mínimo de `MemAvailable`, el `vm.max_map_count` y `ulimit -v` vigentes y el `dmesg` filtrado por `oom|mmap|vmalloc`. La hipótesis declarada del próximo run es la memoria, y su salida debe **clasificarla**, no solo sobrevivir a ella |

| 37876520515 | 02:52→03:56 (~62 min de build: 02:54:51→03:56:49Z) | **la hipótesis de la memoria queda FALSIFICADA por el propio instrumento**: el watchdog tomó 186 muestras y el `MemAvailable` **mínimo** fue 8 458 692 kB (líneas 22129-22130), `vm.max_map_count` pasó de 262 144 a 1 048 576 (3816-3818) y aun así el build **emitió** los dos objetos —`JULIA usr/lib/julia/sysbase-o.a` (16389, 03:46:37Z) y `JULIA usr/lib/julia/sys-o.a` (16608, 03:50:51Z)—.  Los `scudo: Can't populate more pages` siguen (68) pero con **cero** `St9bad_alloc` y cero `signal 6`.  El run muere un tramo más allá: `Failed to precompile CompilerSupportLibraries_jll [e66e0078-…]` (21999, 22047) con `ERROR: LoadError: FieldError: type Nothing has no field major` (22042, 22090) → `pkgimage.mk:28: stdlib/release.image Error 1` (22093), `Makefile:120: stdlibs-cache-release Error 2`, `build rc=2` (22095) | el stub *dummy* de upstream `stdlib/CompilerSupportLibraries_jll/src/CompilerSupportLibraries_jll.jl` **da por existente un runtime GCC que Termux no tiene**: `libgfortran_version(HostPlatform()).major` (`base/binaryplatforms.jl:454` es `VNorNothing(tags(p), …)` y está documentada como nullable) desreferencia `nothing` porque el triple ya no lleva la etiqueta, y `__init__` hace `dlopen` **sin guarda** de `libgcc_s.so.1` (57), `libstdc++.so.6` (61) y `libgomp.so.1` (63).  Medido en el teléfono: `$PREFIX/lib` no tiene `libgfortran*`, `libgcc_s*`, `libstdc++*`, `libgomp*`, `libssp*` y `pacman -Qo` responde `No package owns`.  La capa que *debería* producirlos es `deps/csl.mk:49-101`, que las copia de `$(FC) -print-search-dirs` con `[ -n "$SRC_LIB" ] && cp`: con `clang` como `FC` esa copia es un no-op **silencioso**.  Segundo defecto, este propio: 330 líneas de `MethodError: no method matching dlpath(::Nothing)` vienen de **mis** parches `_jll`, que comprobaron `handle === C_NULL` cuando `dlopen(…; throw_error = false)` devuelve `nothing` (`base/libdl.jl:119-125`; `C_NULL` es `dlopen_e`, línea 160) | Parche nuevo `packages/julia/stdlib-CompilerSupportLibraries_jll.jl.patch`: el nombre queda `""` si la versión es `nothing`, un helper `load_runtime_library` convierte la centinela `nothing` → `C_NULL`, envuelve `dlpath` en `try` y deja `LIBPATH` en `dirname(Sys.BINDIR)/lib` si nada cargó.  Centinela corregida a `nothing` en `stdlib-libblastrampoline_jll.jl.patch` y `stdlib-OpenBLAS_jll.jl.patch`.  **Brecha de gate cerrada** (es lo que permitió que esto costara un run): `scripts/unguarded-dlopen.sh` lee los *call sites* de cada nombre `absent` —dos saltos: `dlopen(ident)` y `helper(ident)`, y al helper lo juzgan sus propios `dlopen`— y `rehearse-recipe.sh` vuelve **FAIL** todo `absent` cargado sin guarda, lo exija `julia-base` o no; `soname-aliases.sh` ya no mantiene la lista a mano de `built` sino que la deriva de `deps/*.mk` (`libX.$(SHLIB_EXT)` y el paquete `$(SRCCACHE)/libX-*`), así que `libdSFMT.so`/`libunwind.so.8` pasan a `built` y no son falsos positivos.  **(Corrección del mismo día: la derivación sin más era generosa —acreditaba todo lo que un `deps/*.mk` menciona, incluidas las deps apagadas— y con ella `libunwind.so.8` pasaba a `built`, tapando un muro real.  Filtrada por `$(DEP_LIBS)` de make, `libdSFMT.so` sigue `built` y `libunwind.so.8` vuelve a `absent`, donde el cruce con `unguarded-dlopen.sh` lo nombra; ver el bullet de `Tramo siguiente`.)**  Rojo→verde en el teléfono: sin el parche `GATE: FAIL` rc=5 con tres FAIL nombrando las líneas 57/61/63; con él rc=0, los cuatro `guarded` (dos `via load_runtime_library()`) y `patches_applied=23`.  Dos notas honestas: el zram **no** tuvo efecto (`modprobe zram` → `Exec format error`, 3798, rc=1 tolerado; el swap siguió siendo el `/swapfile` de 3 G del runner) y el paso `Report what stopped the build` se cayó a sí mismo (rc=1: `grep -h '^julia pid='` sin coincidencias bajo el `-e` del runner —el medidor nunca vio un proceso `julia`—), ya corregido con `|| true` y respuesta explícita |

| 37886407453 | 04:59→05:01 (2 min 24 s, **sin tocar `make`**) | el gate pasó 24 parches y **falló en el runner**: `left absent libopenlibm.so.4` (1744), `unguarded libopenlibm.so.4 stdlib/OpenLibm_jll/src/OpenLibm_jll.jl:28` (1967), `FAIL … is loaded without a guard` (2106), `patches_applied=24 … sonames=1`, `GATE: FAIL` (2420-2421) → `build` y `bundle`/`publish` `skipped`.  En el teléfono el mismo gate estaba `GATE: PASS` con `native libopenlibm.so.4` | dos cosas a la vez, y la segunda es la que costó el run.  (a) El muro es real: la receta fija `USE_SYSTEM_LIBM := 1` y `deps/Makefile:89-91` sólo construye openlibm si **ambas** `USE_SYSTEM_OPENLIBM` y `USE_SYSTEM_LIBM` valen 0, así que `DEPLIBS` no lo incluye (medido idéntico en los dos árboles) y `Make.inc:1321-1324` enlaza contra `-lm`; el stub *dummy* de upstream pide `libopenlibm.so.4` (`OpenLibm_jll.jl:24`) y lo `dlopen`ea sin guarda en `__init__` (`:28`), y el módulo está en `INDEPENDENT_STDLIBS` (`stdlib/stdlib.mk:12`) → habría abortado el precompile de `pkgimage.mk:28`, igual que `LibUnwind_jll`.  (b) El **gate local no podía verlo**: `native`/`absent` se pregunta al prefijo del host que ejecuta `soname-aliases.sh`, y en el teléfono `libopenlibm.so.4` es un fichero dejado por el `julia 1.12.6-1` publicado (`pacman -Qo`), o sea por el paquete que este build reconstruye.  La nota de 37859841658 había llamado inocua esa divergencia con un razonamiento equivocado (`USE_SYSTEM_OPENLIBM` no es la flag que manda) | (a) `packages/julia/stdlib-OpenLibm_jll.jl.patch`: guarda `throw_error = false` + `return` si responde `nothing`, misma forma que `stdlib-LibUnwind_jll.jl.patch`; descartado `USE_SYSTEM_LIBM := 0` (compilar openlibm para bionic por un módulo que nadie usa) y descartado enlazar el nombre a `$PREFIX/lib/libm.so` (otra librería respondiendo por un nombre ajeno).  (b) `rehearse-recipe.sh` pregunta ahora a una copia de `$PREFIX/lib` **sin los ficheros que posee el paquete que se construye** (`pacman -Ql`/`dpkg -L` + `cp -as`; si el paquete no está instalado o no hay gestor, no quita nada y lo dice).  Rojo→verde medido aquí con el prefijo modelado: sin el parche `absent` + `unguarded …:28`; con él `guarded …:33`, `patches_applied=25`, `sonames=0`, `GATE: PASS` (`rehearse-openlibm2.log`).  Único `native` local de dueño `julia`: ver el bullet de `Tramo siguiente` |

| 37891178350 | 05:59→07:02 (~1 h 3 min de build: 06:01→07:02:14Z) | **el precompile de stdlibs sale entero y el muro se mueve a `make install`**: `JULIA stdlib/release.image` (13049, 06:59:13Z) y tras él las stdlibs con sus dos configuraciones —`✓ OpenLibm_jll`, `✓ CompilerSupportLibraries_jll`, `✓ Pkg` en 117 537 ms, `✓ Test`— sin un solo `Failed to precompile`; `FieldError` 0 veces, `dlpath(::Nothing)` 0 veces.  El abort es `make[2]: *** [Makefile:47: html] Error 1` ← `make[1]: *** [Makefile:125: docs] Error 2` ← `make: *** [Makefile:66: …/doc/_build/html/en/index.html] Error 2` (14282-14285) con `RequestError: Could not resolve host: pkg.julialang.org` (14272) y `GitError(… failed to resolve address for github.com)` (14278), `build rc=2` | la hipótesis declarada —los tres stubs que cargan librerías inexistentes— **se confirmó y se cerró**: esto ya no es la recipe fallando en el port sino en lo que la recipe le pide a make.  `install:` (línea 312 del `Makefile` de Julia) tiene por prerequisito `$(BUILDROOT)/doc/_build/html/en/index.html`, y la regla de ese fichero (línea 65, *"Build the HTML docs (skipped if already exists, notably in tarballs)"*) recursiona a `docs` → `doc/Makefile:47 html` → `doc/make.jl`, que instancia un entorno suyo contra el registro General: red y versiones que esta recipe no fija.  Y no es "el runner no tiene red": **dos minutos antes** ese mismo paso bajó 2 124 kB con `curl` (UnicodeData.txt, el `deps` de `doc/Makefile`, 14258-14265).  Lo que falla es la resolución de nombres dentro de bionic para hosts que publican AAAA, el síntoma exacto que `probe-ondevice-builder.yml:104` ya documentó para `apt` ("No address associated with hostname") y que allí se cerró con `Acquire::ForceIPv4` | Parche nuevo `packages/julia/Makefile.patch`: `install` deja de pedir los docs y su `cp -R -L $(BUILDROOT)/doc/_build/html` pasa a ser tolerante (`-`), que es la forma en que el propio Makefile ya soporta "docs no construidos" y deja `make docs` intacto para quien sí los quiera.  **Gate nuevo, discrimina**: la sección `goals and their prerequisites` lee de la recipe los objetivos que entrega a make (derivado: `goals      install`), pregunta al Makefile **ya parcheado** qué prerequisitos tienen y qué regla los construye, y vuelve FAIL si alguno sale de `$(MAKE) docs`; exige además que toda copia de `doc/_build` dentro de una receta esté tolerada.  Rojo→verde medido aquí: sin el parche `FAIL  $(BUILDROOT)/doc/_build/html/en/index.html is built by \`make docs\`, so install would need the network`, `goals=1`, `GATE: FAIL` rc=5 (`rehearse-docs-red.log`); con él `OK    Makefile:413 copies the docs tree tolerantly`, `patches_applied=26`, `goals=0`, `GATE: PASS` (`rehearse-docs-green2.log`).  Gate entero sobre el árbol ya commiteado, 2026-10-09 ~08:20 UTC: `patches_applied=26 patch_failures=0 goals=0 … sonames=0`, `GATE: PASS` (`$PREFIX/tmp/rehearse-final-20261009.log`).  Consecuencia declarada: **el `.deb` no traerá HTML docs**, a diferencia del `julia 1.12.6-1` publicado (`pacman -Ql julia` → `share/doc/julia/html/en/…`) |
| 37904805726 | 08:24:57→09:28:25Z (~63 min) | **`make -j1 install` termina por primera vez en la historia del port** y el job muere cinco segundos después con `ERROR: libLLVM-18jl.so lacks the JL_LLVM_18.1 symbol version` (19192), `build rc=1` (19195), `total 0` (19196) y Publish/bundle `skipped`: **no hay `.deb`**.  Del install: patchelf de `libjulia-internal.so`, `libjulia-codegen.so` y `libLLVM.so` (19117-19128) y el `stringreplace` de `libjulia.so.1.12.6` (19130) ejecutados; el bucle de libs privadas (18970) solo reportó `cp: cannot stat` en `libunwind` (18997), o sea `libLLVM-18jl.so` **sí** pasó a `$PREFIX/lib/julia`.  Gate en el runner: `patches_applied=26 goals=0 … GATE: PASS`; la hipótesis declarada (install sin docs) **confirmada** | Ni la LLVM ni el build: **la aserción de la receta, falsa por la forma del shell**.  `build-package.sh:21` es `set -euo pipefail` y el hook corre en ese shell, así que `readelf -V f 2>/dev/null` \| `grep -q PAT` no prueba nada sobre `f`, compite con él: `grep -q` sale en el primer match (línea 85 de la salida), `readelf` aún está escribiendo sus 35 056 entradas de `.gnu.version` y recibe SIGPIPE, pipefail propaga **141** y el `||` lo lee como "ausente".  Medido aquí contra la `libLLVM-18jl.so` del paquete publicado (`→ libLLVM.so.18.1jl`, con su `Name: JL_LLVM_18.1`): la tubería vieja da `rc=141`; sin pipefail el mismo patrón matchea.  Y el `2>/dev/null` era justo lo que impedía distinguir "no llegó el fichero" de "llegó sin symver" | `packages/julia/build.sh`: capturar (`_vers=$(readelf -V … 2>&1 \|\| true)`) y decidir con `case`; las tres ramas verificadas aquí bajo `set -euo pipefail` —buena: pasa; sin symver: aborta; ausente: aborta nombrando el fichero— (`$PREFIX/tmp/pipetest.sh`).  La misma forma estaba en **Inspect the artifact** (`set -euo pipefail`): un `grep -q` alimentado por tubería se lee como "ausente" cuando le da SIGPIPE, o sea un TEXTREL o un `libLLVM-21` reales habrían pasado **en silencio**, y `readelf -V` \| `grep -c` \| `sed` abortaba el reporte con recuento 0; los tres pasaron a output capturado + `case`.  Gate nuevo `pipes into grep -q` (`rehearse-recipe.sh:187-223`): une continuaciones `\`, ignora líneas de comentario (el gate se pilló a sí mismo citando el patrón —primer intento `pipes=2` FAIL, corregido `pipes=0` PASS—) y vuelve FAIL ante cualquier grep -q alimentado por tubería en la receta o en un workflow.  Rojo→verde del detector: sobre `git show HEAD:packages/julia/build.sh` señala la línea 234 (el bug real); sobre los ficheros corregidos, limpio |
| 37919869465 | 10:48:39→11:52:55Z (~62 min de build: 10:52:26→11:52:51Z) | **`make -j1 install` sin docs sale entero y el empaquetado arranca por primera vez**: `pre_massage` poda el árbol al footprint de Julia y `termux-elf-cleaner` reemplaza los `DF_1_*` en `bin/julia`, `libexec/julia/{lld,dsymutil}`, `lib/libjulia.so.1.12.6` y los dos `libjulia-*` (19448-19453).  El run muere en el chequeo NDK#1614 de `termux_step_massage`: `ERROR: ./share/julia/compiled/v1.12/<Mod>/<hash>.so contains undefined symbols:` con `NOTYPE  GLOBAL DEFAULT   UND memset/memcpy/memmove/sigsetjmp` (32 ficheros, 19620-19690), `INFO: Found 32 ELF files with undefined symbols after exclusion` (19690), `ERROR: Refer above` (19692), `build rc=1` (19693), `total 0` (19694) → sin `.deb`; `bundle`/`publish` `skipped`.  Gate en el runner: `patches_applied=26 goals=0 pipes=0 … GATE: PASS` | **falso positivo del chequeo, no del port**: los 32 son **pkgimages** (`share/julia/compiled/v1.12/*/*.so`) que emite el **JIT de Julia**, no el toolchain C, y por eso sus llamadas a libc quedan `NOTYPE ... UND` en vez de `FUNC ... UND memset@LIBC`; `termux_step_massage` las lee como irresolubles (`termux/termux-packages#9944`) aunque el proceso Julia las resuelve al `dlopen`ear cada pkgimage (el ámbito global incluye libc).  Medido en el dispositivo: `lib/julia/sys.so`, `libjulia-internal.so` y `lib/libjulia.so.1.12.6` traen `memset@LIBC` y/o tipo `FUNC`, así que el patrón `NOTYPE ... UND` no las toca — la lista flagueada es **solo** el cache compilado, ningún `lib/julia/**` ni `bin/julia` | `packages/julia/build.sh`: `TERMUX_PKG_UNDEF_SYMBOLS_FILES` declara `./share/julia/compiled/*/*/*.so` como "puede tener indefinidos", el mismo mecanismo que usa `termux-user-repository/tur-on-device/julia`, y acotado a lo medido en vez del superconjunto de TUR (añadir `sys.so`/`libjulia-*` taparía un indefinido real de esas capas).  Match de `termux_step_massage` reproducido localmente (`[[ "$file" == $pattern ]]`): excluye los pkgimages y deja pasar `bin/julia`, `libexec/julia/lld`, `lib/julia/sys.so` y `libjulia-internal.so`.  Gate local: `patches_applied=26 patch_failures=0 … sonames=0`, `GATE: PASS` |
| 37930497581 | 12:30:35→13:44:07Z (~62 min) | **el job `build` da `success` por primera vez: el `.deb` se produce y `Inspect the artifact` lo acepta** (artefacto `julia-deb`, 84 648 115 B, `Upload the artifact` success).  El run falla en el job **Repackage for pacman and bundle**: `make-pacman-pkg.sh` corre, imprime `[make-pacman-pkg] incoming/julia_1.12.6_aarch64.deb -> bundle/julia-1.12.6-0-aarch64.pkg.tar.xz` y su `ls -lh` ve 81M, pero el paso siguiente muere con `tar: julia-*.pkg.tar.xz: Cannot stat: No such file or directory`, `##[error]Process completed with exit code 2` (20246-20248).  `Publish` `skipped` | **bug de ruta relativa en el conversor, no del build**: `scripts/make-pacman-pkg.sh` resolvía `$OUTPUT_DIR` **después** de `cd "$PAYLOAD"`, así que el `bundle` relativo del workflow se creaba y escribía dentro de `$WORK` (el temp de `dpkg-deb -x`), y el `trap 'rm -rf "$WORK"' EXIT` borraba el `.pkg.tar.xz` al salir: el script salía rc=0 y el fichero que `ls` listaba ya no existía cuando el `tar` del paso siguiente corría.  Reproducido en el teléfono con un `.deb` sintético (`dpkg-deb -b`): con `OUTPUT_DIR=bundle` el `.pkg` aparece bajo `$WORK/pkg/bundle/` y el `bundle/` del cwd solo tiene el `.deb` | `scripts/make-pacman-pkg.sh`: `mkdir -p "$OUTPUT_DIR"` + `OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"` antes de cualquier `cd`, y se quita el `mkdir -p "$OUTPUT_DIR"` tardío.  Rojo→verde local con el escenario exacto del job: sin el fix el `bundle/` no recibe el `.pkg`; con él el `.deb` **real** de este run (84 622 276 B, descargado del artefacto) produce `julia-1.12.6-0-aarch64.pkg.tar.xz` (82M) y el `tar.gz` del bundle (163M), `sha256sum -c SHA256SUMS.txt` OK, y el payload del `.deb` y del `.pkg.tar.xz` es idéntico (diff de `find` excluyendo `.PKGINFO`/`.BUILDINFO`/`.MTREE`), con `.PKGINFO` correcto (`pkgver = 1.12.6-0`, `size = 550268348`, las 13 dependencias) |

Hallazgo estático que no costó un run (medido antes de pushear, 2026-10-09
~03:10 UTC): el parche `_jll` de libblastrampoline pedía la librería **solo** en
`$PREFIX/lib/julia` con `error()` duro, y en el árbol de build esa ruta no existe.
`deps/blastrampoline.mk` instala con `DESTDIR=` en un staging que `staged-install`
(`deps/tools/common.mk:159`) untarrea sobre `$(build_prefix)`, así que durante el
build la librería vive en `$(build_shlibdir)` = `usr/lib` (`usr/lib/libblastrampoline.so{,.5,.5.15.0}`);
`make install` la copia después a `$(private_libdir)` porque `Makefile:223`
(`JL_PRIVATE_LIBS-$(USE_SYSTEM_LIBBLASTRAMPOLINE) += libblastrampoline`) la
clasifica de privada y la receta fija `USE_SYSTEM_LIBBLASTRAMPOLINE := 0`
(`build.sh:122`).  Y `base/Makefile:249` (`symlink_system_library,…,libblastrampoline`)
**solo** se añade cuando `USE_SYSTEM_$1 != 0`, así que tampoco existía
`usr/lib/julia/libblastrampoline.so.5` que buscar.  Habría matado el precompile en
el primer `__init__` de una stdlib, justo el tramo que este port necesita medir.
Fix: `stdlib-libblastrampoline_jll.jl.patch` intenta los tres candidatos (privada
del árbol, privada instalada, nombre desnudo para que decida el `RUNPATH`) y solo
`error()` si ninguno carga; el mismo motivo cualificó `Base.@warn` ahí y en
`stdlib-OpenBLAS_jll.jl.patch`, porque esos stubs son `baremodule` y `@warn` no
está importado sin `using Base`.  `soname-aliases.sh` llevaba un comentario que
afirmaba que las librerías construidas por uno mismo "aparecen en `usr/lib/julia`":
eso es falso en el árbol de build y se corrigió para que el helper no vuelva a
inducir a error a nadie.


Ruido conocido, presente en todo log de este runner: `WARNING: linker: Warning: failed to find generated
linker configuration from "/linkerconfig/ld.config.txt"`,
`__bionic_open_tzdata: …`, `bionic-icu: couldn't open libicu.so`,
`expr: syntax error: unexpected argument 'Warning:'` (el anterior se cuela en
una sustitución de comando de `configure`; autoconf cae a su default y sigue),
y `Warning: git information unavailable`.  NO es ruido `error: linker cannot load
itself`: ese era la causa de 37811196090, y aparecerá igual en todo proceso que
pida `dlopen` del linker del runner.

### Tramo siguiente (`sys-o.a` + precompile): riesgos ya medidos

> **Cerrado el 2026-10-09.**  `sysbase-o.a` y `sys-o.a` se emiten (37876520515,
> líneas 16389 y 16608) y el precompile de `pkgimage.mk:28` pasa de las tres
> stdlibs que cargaban librerías inexistentes (37891178350: `stdlib/release.image`
> + `✓ Pkg`, sin `Failed to precompile`, `FieldError` ni `dlpath(::Nothing)`).  El
> frontier se movió a `make install` y el empaquetado; el muro medido allí fue la
> construcción de los docs HTML (fila 37891178350 arriba) y lo levanta
> `packages/julia/Makefile.patch`.  Los bullets siguientes se quedan como están
> porque son la evidencia de riesgos ya resueltos, no una predicción.

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

- **La derivación de `built` pregunta a make desde 2026-10-08 ~22:40 UTC.**  La
  lista a mano que decidía `built` (`built_by_us="libblastrampoline libLLVM"`) ya no
  existe: `soname-aliases.sh` lee dos grafías de `deps/*.mk`
  (`libNAME.$(SHLIB_EXT)` en una regla, `$(SRCCACHE)/NAME-$(VER)` para un dep cuyo
  install es el `make install` de upstream) y descarta el fichero entero cuando su
  `stem` es un dep que `$(DEP_LIBS)` no incluye.  Medido sobre el árbol configurado:
  `DEPLIBS=JuliaSyntax blastrampoline libuv dsfmt llvm utf8proc terminfo libwhich`,
  y la tabla del gate lista 22 `dep off` (entre ellos `csl` y `unwind`) y
  `built names = libblastrampoline libdsfmt libuv`.  Efecto sobre los veredictos:
  `libdSFMT.so` pasó de `absent` a `built here` — confirmando lo que esa nota
  describía como límite del helper — y `libunwind.so.8` pasó de `built here` a
  `absent`, que es el punto del bullet siguiente.  Boundary que queda: un nombre que
  un dep recibe de un tarball con paquete de nombre distinto sigue cayendo en
  `absent`; lo decide el cruce con `scripts/unguarded-dlopen.sh`.

- **`libunwind.so.8` era un muro que el gate tapaba; ahora lo nombra y está
  guardado.**  Con la derivación corregida el nombre cae en `absent` y el cruce marca
  `unguarded libunwind.so.8 stdlib/LibUnwind_jll/src/LibUnwind_jll.jl:25` — el
  `dlopen(libunwind)` sin `throw_error`, dentro de
  `@static if Sys.islinux() || Sys.isfreebsd()`, rama que se compila aquí porque el
  triplet que empotramos es `aarch64-linux-gnu…`.  El fix es la guarda en la capa
  productora: `packages/julia/stdlib-LibUnwind_jll.jl.patch`
  (`dlopen(…; throw_error = false)` + `return` si responde `nothing`, dejando
  `libunwind_handle`/`libunwind_path` en los defaults que el propio stub declara).
  Descartado el `DISABLE_LIBUNWIND := 0` que proponía la nota anterior: compilar
  libunwind para bionic es un cambio de alcance mayor, la receta lo apaga a
  propósito porque aarch64 usa el cambio de pila propio de Julia
  (`build.sh:124-126`), y nada depende del módulo — medido: `LibUnwind` solo aparece
  en su propio `Project.toml`, en `stdlib/Project.toml:25` y `stdlib/stdlib.mk:10`,
  que lo instalan pero no lo cargan.  Corrección a lo afirmado sobre
  `LLVMLibUnwind_jll`: su `dlopen` está bajo `@static if Sys.isapple()` (`:24`), así
  que en Linux nunca corre y **no** es muro; su literal `"libunwind"` además no
  lleva extensión y cae fuera de la derivación (boundary declarado en
  `soname-aliases.sh:15-19`).  Rojo→verde demostrado en el gate: sin el parche
  `patches_applied=23 … sonames=1` con
  `FAIL  libunwind.so.8 is loaded without a guard at stdlib/LibUnwind_jll/src/LibUnwind_jll.jl:25`
  y `GATE: FAIL` (`rehearse-unwind-red.log`); con él `patches_applied=24`,
  `sonames=0`, `guarded libunwind.so.8 …:31` y `GATE: PASS`
  (`rehearse-unwind.log`, 2026-10-08 ~22:55 UTC).

- **`libopenlibm.so.4`: el muro que el teléfono no podía ver.**  El run
  `37886407453` (creado 04:59:04Z, `GATE: FAIL` a las 05:01:25Z, 2 min 24 s, job
  `build` `skipped`) falló en el runner con
  `FAIL  libopenlibm.so.4 is loaded without a guard at stdlib/OpenLibm_jll/src/OpenLibm_jll.jl:28`
  y `sonames=1`, mientras el mismo gate con los mismos 24 parches daba `GATE: PASS`
  aquí.  La diferencia no estaba en la receta ni en la respuesta de make —los dos
  árboles contestaron el mismo `DEPLIBS=JuliaSyntax blastrampoline libuv dsfmt llvm
  utf8proc terminfo libwhich` y las mismas 22 filas `dep off`—: estaba en **el
  prefijo donde corre el helper**.  `$PREFIX/lib/libopenlibm.so.4` existe en el
  teléfono y `pacman -Qo` lo atribuye a `julia 1.12.6-1`, el paquete publicado que
  este port reconstruye, así que el veredicto local (`native`) respondía a una
  pregunta que el build real no tiene quién le conteste.  Y la pregunta correcta la
  dicen las tres capas: la receta fija `USE_SYSTEM_LIBM := 1` (`build.sh:102`, en
  Termux el `libm` es el de bionic), `deps/Makefile:89-91` sólo añade `openlibm` a
  `DEP_LIBS` cuando **ambas** `USE_SYSTEM_OPENLIBM` y `USE_SYSTEM_LIBM` valen 0
  (medido: `dep off openlibm`), `Make.inc:1321-1324` enlaza Julia contra `-lm`, y
  `stdlib/OpenLibm_jll/src/OpenLibm_jll.jl:24` escribe `libopenlibm.so.4` para la
  rama linux que `:28` `dlopen`ea **sin guarda** en `__init__` — un módulo que está
  en `INDEPENDENT_STDLIBS` (`stdlib/stdlib.mk:12`), o sea que se precompila bajo
  `pkgimage.mk:28`.  Nada lo usa: medido, `OpenLibm_jll` sólo aparece en su propio
  `Project.toml`, en `stdlib/Project.toml:35` y en esa lista de instalación.
- Fix en la capa productora, con la misma forma que libunwind:
  `packages/julia/stdlib-OpenLibm_jll.jl.patch` (`dlopen(…; throw_error = false)` +
  `return` si responde `nothing`, dejando `libopenlibm_handle`/`libopenlibm_path` en
  los defaults que el propio stub declara).  Descartado `USE_SYSTEM_LIBM := 0`:
  pondría a compilar openlibm para bionic —otro `unit` de build cuya portabilidad
  aquí no está medida— para dar de comer a un módulo que nadie carga, y contradice el
  motivo por el que la receta eligió el `libm` del sistema.  Descartado enlazar el
  nombre a `$PREFIX/lib/libm.so` (existe: symlink a `/system/lib64/libm.so`), porque
  haría que una librería distinta responda por un nombre que no es el suyo.
- **Fidelidad del gate, que es lo que había que cerrar de verdad.**  Un `native`
  dado por el paquete que se está reconstruyendo no es evidencia de nada, así que
  `rehearse-recipe.sh` ya no pregunta al prefijo del dispositivo sino a una copia de
  él **sin los ficheros que posee el paquete que se construye**: `pacman -Ql $PKG`
  (o `dpkg -L`) → `cp -as "$PREFIX/lib"` → se quitan los poseídos.  Si el paquete no
  está instalado, o no hay gestor de paquetes, no se quita nada y el log lo dice,
  porque un filtro silencioso sería un veredicto que nadie puede trazar.
  Discriminación medida: con el filtro el gate local imprime la misma fila que el
  runner (`sysroot … 12 file(s) removed because package julia owns them`,
  `left absent libopenlibm.so.4 … in …/sysroot`) y sobre el árbol **sin** el parche
  el cruce da `unguarded … OpenLibm_jll.jl:28` (rojo, reproducido con un prefijo
  sintético que carece de `libopenlibm*`); con él, `guarded … :33`,
  `patches_applied=25`, `sonames=0`, `GATE: PASS` (`rehearse-openlibm2.log`,
  2026-10-09 ~05:19 UTC).  Comprobado además que este nombre era el **único**
  `native` local cuyo dueño es el paquete reconstruido: los otros ocho (`libklu.so.2`,
  `libldl.so.3`, `librbio.so.4`, `libspqr.so.4`, `libumfpack.so.6`,
  `libsuitesparseconfig.so.7` de `suitesparse`, `libssl.so.3` de `openssl`,
  `libz.so.1` de `zlib`) los tiene también el sysroot del runner, así que no queda
  otra divergencia teléfono/runner de esta clase pendiente.

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
teléfono) → `~59 min` (37870492832: el directorio correcto cierra la cadena —0
`could not load library`, Base + stdlibs cargadas— y por primera vez el fallo **no
es del port**: el `malloc` de scudo se rinde al emitir `sysbase-o.a`) → `~62 min`
(37876520515: con `max_map_count` alzado y el watchdog midiendo, **los dos objetos
salen** —`sysbase-o.a` 03:46:37Z, `sys-o.a` 03:50:51Z— y el muro se movió al
precompile de stdlibs: `pkgimage.mk:28` aborta en
`FieldError: type Nothing has no field major`, o sea el runtime GCC que Termux no
tiene; la memoria queda **falsificada** como causa) → `~63 min`
(37891178350: **el precompile sale entero** —`Failed to precompile`, `FieldError` y
`dlpath(::Nothing)` a cero, con `✓ Pkg` en 117 s tras `stdlib/release.image`— y el
fallo se mueve un tramo más allá, a `make install`, cuyo prerequisito de docs HTML
necesita red dentro de bionic; el instalador y el empaquetado siguen sin medir) →
`~62 min` (37919869465: `make install` sin docs **sale entero** —`pre_massage` poda
el árbol y `termux-elf-cleaner` reescribe los `DF_1_*`— y el muro se mueve al
**empaquetado**: el chequeo de símbolos indefinidos de termux-packages marca 32
`pkgimages` con `NOTYPE UND memset`) → `~62 min` (37930497581: el fix de exclusión
cierra el empaquetado y **el job `build` da `success` y sube el `.deb`** —84,6 MB,
`Inspect the artifact` OK—; el run muere en el job `bundle` por un `OUTPUT_DIR`
relativo resuelto dentro del temp de `dpkg-deb -x`, que el `trap EXIT` borraba antes
del `tar`).

### Fase 5 — primera corrida del artefacto en el dispositivo (2026-10-09)

El `.deb` de `37930497581` se convirtió a pacman con el mismo
`scripts/make-pacman-pkg.sh` y se instaló con `pacman -U --overwrite '*'` (nuestro
`julia 1.12.6-0` reemplaza al `1.12.6-1` del repo; `pacman -Ql julia` quedó guardado en
`$PREFIX/tmp/julia-files-before.txt` y `pacman -S julia` lo restaura).  **Resultado: el
port funciona.**  `julia --version` responde y `-e` evalúa: `println(1+1)`,
`Sys.MACHINE = aarch64-unknown-linux-android24`, `LinearAlgebra` con `rand(64,64)` y
`A*A` (BLAS LP64 vía libopenblas), `Dates`, `SparseArrays`, `Printf`, `Random`,
`Statistics`, `Pkg`, `CompilerSupportLibraries_jll`, `Downloads`, `LibGit2` — todas rc=0.

El único bloqueo fue **`libz.so.1`**: `libLLVM.so.18.1jl` trae RUNPATH `$ORIGIN`
**solo**, así que cada nombre de su `DT_NEEDED` tiene que existir en `lib/julia` (el
loader no cae a `$PREFIX/lib`).  `libz.so.1` existe en `$PREFIX/lib` (lo provee `zlib`)
pero ningún fuente de Julia lo escribe, así que `soname-aliases.sh` —que lee
**literales**— no lo reclamaba y no había alias.  Síntoma exacto: `dlopen failed:
library "libz.so.1" not found: needed by .../libLLVM.so.18.1jl`.  Un `ln -sfn` a mano
en `lib/julia` lo cierra y el árbol entero arranca (probe medido).  Fix:
`packages/julia/needed-library-aliases.sh` deriva los nombres del `DT_NEEDED` de los ELF
**instalados** en la carpeta (excluyendo lo que ya responde `/system/lib{,64}`),
`termux_link_needed_aliases` crea los links en `post_make_install`, y una aserción
fail-closed vuelve a correr la derivación y exige que salga **vacía**, así el build falla
en vez de que falle el primer `julia -e`.  Sobre el árbol instalado el helper emite
exactamente tres: `libz.so.1`, `libc++_shared.so`, `libjulia.so.1.12` (los tres al mismo
fichero que el loader ya habría resuelto o necesita).  Rojo→verde en el teléfono: sin el
link, todo `-e` muere con el `dlopen failed`; con el link, la batería entera pasa y el
re-check del helper sale vacío.

Nota de método: la primera prueba en el dispositivo fue **inválida** —extraje el `.deb` a
un prefijo temporal— porque `Sys.STDLIB` y los `_jll` se resuelven contra el prefijo de
build (`/data/data/com.termux/files/usr`), que en el teléfono es el `julia` de pacman:
los avisos `OpenBLAS_jll init failed` venían del julia del sistema (su `sys.so` no tiene
el patch; el nuestro sí: `load_openblas` ×2 contra ×0).  Un artefacto de Termux **solo**
se puede probar instalado en el prefijo real.

### Caché de CI: la clave no debe depender de lo que deriva solo

La clave era `julia-deb-v1-aarch64-<HEAD de termux-packages>-<hash del índice
Termux>-<hash de packages/julia/**>` y no había `restore-keys`.  Un cambio en `scripts/**`
(el fix de `make-pacman-pkg.sh`) pagó otro build completo porque las dos primeras
componentes se mueven solas en horas.  Ahora el hash de la receta va **primero**
(`julia-deb-v2-aarch64-<hash>-<...>-<...>`) con `restore-keys:
julia-deb-v2-aarch64-<hash>-`, así un cambio en `scripts/**`, `.github/**` o docs reusa el
último artefacto de la misma receta; la clave estricta sigue siendo la que se **guarda**
(con el entorno en que se construyó) y un hit por `restore-keys` **no** se re-guarda bajo
otra.  `cache-hit` solo distingue el match exacto, así que las condiciones de "Probe",
"Build" y "Save" pasaron a `steps.cache.outputs.cache-matched-key == ''`.  Compromiso
declarado: un artefacto restaurado puede venir enlazado contra libs de Termux de horas
antes — es el precio de no pagar 60 min por tocar un script.

---

## Pendientes

1. **Fase 4 (en curso)**: que un run llegue a producir el `.deb`.  Cadena de
   cierres: `37870492832` cerró la hipótesis del directorio, `37876520515` falsificó
   la de memoria (`sysbase-o.a` y `sys-o.a` se emiten), `37886407453` **no llegó a
   `make`** (el gate lo paró en el runner por el stub `OpenLibm_jll`) y
   `37891178350` **cerró el precompile** —las stdlibs salen con las dos
   configuraciones y cero `Failed to precompile`— y `37919869465` **cerró el
   `make install`**: el `Makefile.patch` sin el prerequisito de docs HTML dejó que
   `make -j1 install` terminara —los `stringreplace` que reescriben las cadenas de
   dependencias del loader (`Makefile:468-481`), las copias de `base`/`test`/`stdlib`
   y `termux-elf-cleaner`— y el muro se movió al **chequeo de símbolos indefinidos de
   `termux_step_massage`** sobre 32 pkgimages (falso positivo: el JIT de Julia los
   emite `NOTYPE ... UND`, que el proceso resuelve al `dlopen`).  El fix ya está en la
   receta: `TERMUX_PKG_UNDEF_SYMBOLS_FILES` acota `./share/julia/compiled/*/*/*.so`.
   `37930497581` **produjo el `.deb`** (job `build` success, `Inspect the artifact`
   OK, artefacto `julia-deb` de 84,6 MB) y el muro se movió al job **`bundle`**: el
   conversor `scripts/make-pacman-pkg.sh` escribía el `.pkg.tar.xz` en un
   `$OUTPUT_DIR` relativo resuelto **después** de `cd "$PAYLOAD"`, o sea dentro del
   temp que su propio `trap EXIT` borraba.  El próximo run mide **una** hipótesis:
   que con `OUTPUT_DIR` canonizado antes de cualquier `cd` el job `bundle` completa
   (`julia-1.12.6-0-aarch64.pkg.tar.xz` + `julia-termux-aarch64.tar.gz` +
   `SHA256SUMS.txt`, con el payload idéntico al `.deb`) y `Publish` solo queda
   `skipped` porque no se pidió `publish=true`.  El `.deb` de este run ya está
   descargado en el teléfono (`$PREFIX/tmp/julia-deb-37930497581/`) para arrancar la
   Fase 5 sin esperar al próximo run, y su conversión a pacman + bundle ya se validó
   aquí sobre el artefacto real.
2. **Fase 5 — verificación en dispositivo**: instalar `.deb`/`.pkg.tar.xz`,
   correr `julia --version`, `versioninfo()`, `Pkg.test` de un paquete puro de
   Julia y la batería de smoke de `test/`; con evidencia fechada. "Compila" no
   es "funciona".  **Y sin baseline prestada**: el `julia` de referencia de este
   teléfono no evalúa código (bullet arriba), así que `device-smoke.sh` se
   afirma contra sus propios `assert`s, no contra "el otro julia sí anda".
   **Primera corrida hecha el 2026-10-09** (sección de Fase 5 arriba): el `.deb`
   de `37930497581` instalado por pacman arranca y evalúa la batería entera, con
   los tres alias derivados de `DT_NEEDED`.  Queda: repetir sobre el artefacto
   del próximo run (que ya trae los alias en la receta, no a mano), correr el
   `.pkg.tar.xz`/bundle publicado y el `Pkg.test` de un paquete puro.
3. **Foldar el resto de la derivación de `built`**: la lista a mano
   `built_by_us="libblastrampoline libLLVM"` ya no existe (plegada 2026-10-08, ver
   el bullet de `Tramo siguiente`).  Lo que queda es la boundary declarada: un dep
   cuyo `.so` llega de un tarball con nombre de paquete distinto al soname
   (`$(SRCCACHE)/otra-cosa-$(VER)` instalando `libX.so.N`) sigue cayendo en `absent`.
   Hoy eso es inocuo porque el gate no pregunta "existe?" sino "alguien lo carga sin
   guarda?", y esa pregunta la responde `scripts/unguarded-dlopen.sh` sobre los
   mismos ficheros.  Si un `absent` real bloquea un run, la derivación se aprieta
   contra `$(INSTALL_NAME_CMD)libNAME.$(SHLIB_EXT) $(build_shlibdir)/…`.
   Boundary **de prefijo**, declarada el 2026-10-09 tras `37886407453`: el gate
   excluye del sysroot los ficheros que posee el paquete que se construye
   (`pacman -Ql`/`dpkg -L`), y eso cubre el caso observado; un `native` dado por una
   librería que en el teléfono instaló *otro* paquete que en el runner no está, o
   por un fichero suelto sin dueño, seguiría leyendo distinto en cada lado.  El
   síntoma a vigilar es idéntico al de esta fila: `GATE: PASS` local + `left absent`
   en el runner.
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
   Añadido 2026-10-08 ~23:00 UTC, todo esto se borra al cerrar Fase 5:
   `jwork` (52 MB, árbol pristino del que se generan los parches), `green-csl`,
   `csl-check2`, `lu-patch-*`, `lu-apply-*`, `julia-rehearse.1xLPzx`,
   `julia-rehearse.H2UWEw` y los logs `rehearse-{green,red,unwind,unwind-red}.log`,
   `verdicts-*.txt`, `absent-new.txt`, `parse-out.txt`, `lu-workdir.txt`.
   Añadido 2026-10-09 ~05:25 UTC (el cierre de `OpenLibm_jll`): `jwork` sigue siendo
   el árbol pristino del que se generan los parches; se borran además
   `openlibm-patch.*`, `runner-sysroot.*` (el prefijo sintético con el que se
   reprodujo el veredicto del runner), `openlibm-demo.*` (árbol verde + tablas
   rojo/verde), `julia-rehearse.0eJq88`, `julia-rehearse.WWg9Gj` y los logs
   `rehearse-openlibm{,2}.log`.
6. **Restos de la ruta Docker** (`scripts/Dockerfile`, `run-docker.sh`,
   `build-deps-docker.sh`, `setup-ccache-docker.sh`, `build-local.sh`,
   `ndk-patches/`, `trace-dl/`, `tasks/`, `.hermes/`, `build.log` suelto): están
   declarados como ruta muerta en `README.md`, pero borrarlos es destructivo y
   necesita OK explícito del usuario.  `.github/actions/zram/` **no** belonge a
   esta lista: está conectado al job `build` con `continue-on-error`, y aunque en
   37876520515 no tuvo efecto (`modprobe zram` → `Exec format error`), deja la
   medición de swap en el log.

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
