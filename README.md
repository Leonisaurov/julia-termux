# Julia para Termux (aarch64)

Port de **Julia v1.12.6** a Termux/Android aarch64 usando el build system de
`termux-packages`. El build corre en **CI sobre un runner arm64**
(`ubuntu-24.04-arm`) que materializa un prefijo Termux real: es el modo
**on-device** de termux-packages, con **host == target** y el `clang` de Termux
como compilador. **No es cross-compilación.**

Remoto: `https://github.com/Leonisaurov/julia-termux` (rama `main`).

> **Lee primero**: `AGENTS.md` (reglas operativas vigentes) y `PROGRESS.md`
> (estado con evidencia, run IDs y minutos: la única fuente que dice dónde está
> realmente el build). `ARCHITECTURE.md` explica el por qué del sistema de build
> y sus gates.

## Qué es y qué no es

- Receta declarativa de termux-packages en `packages/julia/build.sh`
  (`TERMUX_PKG_VERSION=1.12.6`, `packages/julia/build.sh:6`), con 22 parches
  `*.patch` junto a la receta y 2 en `packages/julia/patches/deps/`.
- Build nativo bionic: `build-package.sh` se ejecuta en su rama on-device porque
  el action crea `/system/bin/app_process`
  (`.github/actions/termux-builder/action.yml:51-52`), y con host == target el
  **LLVM bundled** (`USE_SYSTEM_LLVM := 0`, `packages/julia/build.sh:84`) es
  compilarable.
- **Ruta muerta, no la uses**: `XC_HOST`, `HOSTCC`, `BUILDING_HOST_TOOLS`,
  `host-flisp`, `scripts/Dockerfile`, `scripts/run-docker.sh`,
  `scripts/build-deps-docker.sh`, `scripts/build-local.sh`. Era el builder Docker
  de x86_64: compilaba LLVM 60-76 min para morir en
  `llvm-min-tblgen: Exec format error`. Algunos de esos ficheros siguen en el
  árbol como restos. Tampoco existe `packages/llvm-julia`: hoy LLVM se compila
  desde `deps/llvm.mk`.

## Estado (2026-10-09)

La cadena está medida hasta el **minuto ~50** y hay un run en curso
(`37870492832`, 01:35 UTC) midiendo la causa de directorio. Todavía **no existe ningún
`.deb` ni `.pkg.tar.xz` producido**: no hay artefacto que instalar.

| Pieza | Estado |
|---|---|
| Receta `packages/julia/build.sh` + 22 parches + `Make.user` | OK |
| Gates estáticos locales y en el job `lint` | OK |
| Runner con prefijo Termux (`termux-builder`) | OK |
| LLVM 18.1.7 bundled (symver `JL_LLVM_18.1`) | OK (~43 min) |
| `src/`, flisp y `julia-base` con sus symlinks derivados | OK |
| Arranque de `julia` y bootstrap de la sysimage | en curso: aborta en `sysimage.mk:129`; la causa (el **directorio** de los alias, no su existencia) está medida en el teléfono y el fix ya se deriva de make — falta medirlo en CI |
| `sys-o.a` + precompile, `pkgimage.mk`, `make install` | **sin demostrar** |
| `.deb` / `.pkg.tar.xz` / bundle | **sin producir** |
| Verificación en dispositivo | **pendiente** |

Donde `PROGRESS.md` dice "compila", no leas "funciona". El detalle con run IDs
está en `PROGRESS.md` ("Resumen", "Avance medible del build", "Pendientes").

## Cómo se construye

### 1. Gate local (obligatorio antes de cualquier run)

Un run de CI cuesta ~49-55 min; el gate responde en segundos.

```bash
bash scripts/lint-workflows.sh    # YAML parseable + bash -n en cada run: + uses: locales
bash scripts/rehearse-recipe.sh   # el gate completo: replay de parches y configure + sondas
```

`scripts/rehearse-recipe.sh` reimprime el stage de parches y el `configure`
contra el tarball real pineado y deriva/verifica sonames y triplet
**preguntándole a `make` y al propio fuente** (`scripts/symlinked-libraries.sh`,
`scripts/embedded-triplet.sh`, `packages/julia/soname-aliases.sh`). Su veredicto
es `GATE: PASS` / `GATE: FAIL` (`exit 5` en FAIL).

### 2. El workflow

`.github/workflows/build-package.yml`, disparado por `push` a `main` (solo sobre
`packages/**`, `scripts/**`, `.github/**`) o por `workflow_dispatch`. DAG:

```
lint (gate estático, ubuntu-24.04-arm)
  └─ build (julia .deb, ubuntu-24.04-arm)
       └─ bundle (.pkg.tar.xz + julia-termux-aarch64.tar.gz + SHA256SUMS.txt)
            └─ publish (solo con input publish=true)
```

- El job `build` clona `termux-packages`, copia `packages/julia` encima y ejecuta
  `./build-package.sh -s --format debian -j "$(nproc)" -o "$GITHUB_WORKSPACE/output" julia`
  desde un script generado en `$RUNNER_TEMP/run-build.sh`, con shebang del prefijo
  (`build-package.yml:224-231`).
- `bundle` convierte el `.deb` con `scripts/make-pacman-pkg.sh` y verifica que
  ambos formatos lleven los mismos bytes.
- **Publicar es explícito**: `workflow_dispatch` con `publish=true`
  (`build-package.yml:444`; **off por defecto**). Un build verde no publica nada
  ni mueve el puntero `julia-latest`.

### 3. Inspeccionar un run

```bash
gh run list --limit 3 --json databaseId,status,conclusion,createdAt
gh run view <id> --json status,conclusion          # fuente de verdad
gh run view <id> --json jobs -q '.jobs[] | {name, conclusion}'
```

Ejemplo real (leído el 2026-10-08):

```json
[{"conclusion":"failure","createdAt":"2026-10-08T23:55:41Z","databaseId":37862103015,"status":"completed"},
 {"conclusion":"failure","createdAt":"2026-10-08T23:30:44Z","databaseId":37859841658,"status":"completed"},
 {"conclusion":"failure","createdAt":"2026-10-08T22:12:16Z","databaseId":37851961397,"status":"completed"}]
```

Los tres murieron en el mismo mensaje (`could not load library "libgmp.so.10"`)
por causas distintas y cada uno falsificó la hipótesis del anterior:
37851961397 pidió los sonames versionados que no existían, 37859841658 los creó
demasiado tarde (después de `make`, que es donde arranca la sysimage) y
37862103015 los creó ocho, antes de `make`, pero en `usr/lib/julia` — el
directorio que el loader no mira. El detalle con marcas de tiempo está en
`PROGRESS.md`. No uses `gh run watch`: devolvió 0 en runs fallidos
(`PROGRESS.md` "Notas").

### 4. Por qué nunca se compila Julia en el teléfono

El build pesa ~50 min de runner y con 11 GB de RAM del dispositivo no alcanza.
El teléfono **solo baixa, instala y prueba**.

## Cómo se instala (una vez exista el artefacto)

Hoy no hay artefacto; estos comandos son los que habrá que poder ejecutar.

```bash
sha256sum -c SHA256SUMS.txt
dpkg -i julia_*_aarch64.deb          # Termux basado en apt
pacman -U julia-*.pkg.tar.xz         # Termux basado en pacman (repo: repo.json)
```

Dependencias de runtime declaradas en la receta (`packages/julia/build.sh:17`):
`7zip, curl, libc++, libgit2, libgmp, libmpfr, libnghttp2, libopenblas, libssh2,
openssl, pcre2, suitesparse, zlib`. La lista de build
(`packages/julia/build.sh:31`) añade `clang`, `cmake`, `llvm`, `lld`, `python`,
`patchelf`, `blas-openblas` y otras herramientas; `blas-openblas` es solo
dependencia de build (el symlink que crea `julia-base` apunta en runtime a
`$PREFIX/lib/libopenblas.so`, ya cubierto).

## Cómo se prueba en el dispositivo

```bash
bash scripts/device-smoke.sh <ruta-o-URL-del-bundle>              # instala y asserts
bash scripts/device-smoke.sh <bundle> --network --runtests        # + descargas Pkg + test/
bash scripts/device-diag.sh                                       # diagnóstico de lo ya instalado
```

Ambos se corren **en Termux, nunca en CI**: CI construye, el dispositivo prueba.
`scripts/device-smoke.sh` instala el paquete, comprueba checksums y ejecuta
`--version`, `hello`, `dlpath` de los sonames versionados, BLAS/LinearAlgebra,
SparseArrays/SuiteSparse/ARPACK, LibGit2, `Pkg.status()`, PCRE2 JIT, threads,
codegen LLVM y, con `--runtests`, partes de la batería propia de Julia
(`Base.runtests`) vía `tcr`. Su salida `SMOKE: PASS` es la definición de hecho:
"compila" no es "funciona".

## Limitaciones y terreno minado

- **Termux no tiene FHS**: `PREFIX=/data/data/com.termux/files/usr`,
  `TMPDIR=$PREFIX/tmp`; nunca `/tmp`, `/usr/bin`, `/etc`; shebangs absolutos y no
  existe `/usr/bin/env`.
- El shell interactivo del usuario es **fish**: envuelve `VAR=val cmd` en
  `sh -c '…'`.
- **`concurrency` con `cancel-in-progress: true`** (`build-package.yml:35-37`):
  empujar con un run en curso **lo cancela**.
- **Caché**: la clave del artefacto incluye `hashFiles('packages/julia/**')`
  (`build-package.yml:182,336`). Tocar la receta o cualquier `*.patch` paga
  ~45-52 min de reconstrucción.
- **SONAMEs**: Termux publica librerías sin versión en el SONAME, mientras el
  fuente de Julia pide nombres glibc-style como literales (`base/gmp.jl:32` →
  `"libgmp.so.10"`) y `dlopen` de Android empareja el nombre de fichero. Lo
  resuelve `packages/julia/soname-aliases.sh`, enlazado **antes** de `make`
  (`termux_link_soname_aliases`, `packages/julia/build.sh:157-174`, llamado en
  `build.sh:192` dentro de `termux_step_make`). El **directorio** también se
  deriva, no se escribe a mano: es el `$(build_shlibdir)` de make (donde vive
  `libjulia-internal.so`, cuyo `RUNPATH` es solo `$ORIGIN`) en el árbol de build y
  `$(private_libdir)` en el instalado — `scripts/runtime-library-dir.sh` se lo
  pregunta a make y `rehearse-recipe.sh` confronta la respuesta con la receta.
- Salida del teléfono: no hay `libgcc_s`/`libgfortran`/`libstdc++` (Termux usa
  clang + libc++), así que `JULIA_PRECOMPILE := 1` y el precompile paralelo son
  terreno todavía no medido en Android.
- Solo **aarch64**.

## Índice del repo

```
packages/julia/          receta + 22 parches + patches/deps/ + soname-aliases.sh
scripts/                 gates locales (lint-workflows.sh, rehearse-recipe.sh),
                         derivaciones (symlinked-libraries.sh, embedded-triplet.sh,
                         runtime-library-dir.sh),
                         make-pacman-pkg.sh, device-smoke.sh, device-diag.sh
.github/workflows/       build-package.yml (lint → build → bundle → publish)
.github/actions/         termux-builder/ (materializa el prefijo en el runner)
.github/scripts/         termux-closure-resolver.py (cierre de dependencias)
repo.json                formato de paquete publicado (pacman/termux-main)
PROGRESS.md              fuente fechada del estado con evidencia
AGENTS.md                reglas operativas para agentes
ARCHITECTURE.md          por qué del build system y sus gates
```

Restos de la ruta abandonada que conviene no seguir: `scripts/Dockerfile`,
`scripts/run-docker.sh`, `scripts/build-deps-docker.sh`, `scripts/build-local.sh`,
`.github/actions/zram/` (el workflow no lo usa), `ndk-patches/`, `trace-dl/`,
`tasks/`.

## Licencia y créditos

Este repo es una **fork de trabajo de `termux-packages`**
(https://github.com/termux/termux-packages), cuyo build system se usa tal cual.
Julia es software **MIT** (`packages/julia/build.sh:4`); este repo **no incluye
ningún fichero `LICENSE` propio** y no se afirma lo contrario. Gracias a
Termux (https://termux.dev) y a JuliaLang (https://julialang.org).
