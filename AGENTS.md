# AGENTS.md — guía operativa para agentes

> Lee esto antes de tocar nada. Para el estado con evidencia (qué falló, qué
> corre, qué queda por demostrar), lee `PROGRESS.md`: es la fuente fechada y la
> única que dice dónde está realmente el build. Este archivo solo fija las
> reglas; `ARCHITECTURE.md` explica el por qué del sistema de build y sus gates.

## La arquitectura vigente (no la vuelvas a buscar en otro lado)

El build corre **on-device en modo nativo de termux-packages** sobre un runner
`ubuntu-24.04-arm`, orquestado por `.github/workflows/build-package.yml` y
materializado por `.github/actions/termux-builder/action.yml`.

- **Host == target.** `build-package.sh` activa su rama on-device porque el
  action crea `/system/bin/app_process` (`action.yml:51-52`). Con host == target,
  el `clang` de Termux es el compilador real y por eso el **LLVM bundled**
  (`USE_SYSTEM_LLVM := 0`, `packages/julia/build.sh:84`) es compilarable.
- **No existe `XC_HOST` ni cross-compilación ni `host-flisp`.** El builder Docker
  de x86_64 que los usaba fue **abandonado**: compilaba LLVM 60-76 min para morir
  en `llvm-min-tblgen: Exec format error`. Si ves `XC_HOST`, `HOSTCC`,
  `BUILDING_HOST_TOOLS`, `--host` o `host-flisp`, eso es la ruta muerta. Sus
  ficheros (`scripts/Dockerfile`, `scripts/run-docker.sh`,
  `scripts/build-deps-docker.sh`, `scripts/build-local.sh`,
  `scripts/setup-ccache-docker.sh`, `scripts/patch-fuse-overlayfs.sh`) se
  **borraron el 2026-10-09**: no hay que reconocerlos ni resucitarlos.
- `packages/llvm-julia` **no es la ruta**: es solo la contingencia cacheada si el
  LLVM bundled resultara no cacheable (PROGRESS "Pendientes" §4). Hoy la receta
  compila LLVM desde `deps/llvm.mk`.

## Termux/Android aarch64 (sin root, sin systemd, sin FHS)

- `PREFIX=/data/data/com.termux/files/usr`, `TMPDIR=$PREFIX/tmp`. **Nunca**
  `/tmp`, `/usr/bin`, `/etc`. Shebangs absolutos; `/usr/bin/env` no existe.
- El shell interactivo del usuario es **fish**: `VAR=val cmd` no es válido y
  `VAR=val tmux …` mata la sesión; envuelve en `sh -c '…'`.
- En el runner, `libtermux-exec` reescribe `/usr`, `/bin`, `/etc`, `/lib`, `/var`
  en `execve`/`open` (`action.yml` "Publish the prefix environment"). Las
  herramientas del host solo se invocan desde una ruta **no aliasada**
  (`~/.termux-builder-hostbin`, `action.yml:208`) y con `unset LD_PRELOAD`
  (`action.yml:241`): un `LD_PRELOAD` bionic dentro de una herramienta glibc la
  mata (`invalid ELF header`). El script que arranca el build usa el shebang del
  prefijo: `#!/data/data/com.termux/files/usr/bin/bash`
  (`build-package.yml:224`).

## Presupuesto de la sesión (la regla cara)

- **Ningún run de CI sin pasar antes el gate estático local.** Un run cuesta
  ~49-55 min; el gate responde en segundos.
- **Un run = una hipótesis.** Declara la hipótesis en el commit y no mezcles
  cambios.
- Ante un fallo: **diagnóstico completo antes de tocar código.** No recompiles a
  ciegas.
- El teléfono **no compila Julia**: solo baixa, instala y prueba. Un build pesa
  ~50 min y 11 GB de RAM no alcanzan.

### Gate local obligatorio

```bash
bash scripts/lint-workflows.sh   # YAML parseable + bash -n en cada run: + uses: locales
bash scripts/rehearse-recipe.sh  # el gate completo; replay de parches y configure + sondas
```

`rehearse-recipe.sh` es el que importa: reimprime el stage de parches y el
`configure` contra el tarball real, y deriva y verifica los sonames y el triplet
**preguntándole a `make` y al propio fuente**, no a una lista a mano. Su salida
`GATE: PASS` / `GATE: FAIL` es el semáforo; `exit 5` en FAIL. Cada gate existe
por un fallo medido (ver `ARCHITECTURE.md` "Gates" y el "Cadena de modos de
fallo" de `PROGRESS.md`).

## Concurrency y caché (léelas antes de empujar)

- `concurrency.group = ${{ github.workflow }}-${{ github.ref }}` con
  `cancel-in-progress: true` (`build-package.yml:35-37`). **Empujar con un run en
  curso lo cancela.** No canceles "para limpiar la cola": mata el run que estás
  validando.
- La clave de caché del artefacto es
  `julia-deb-v1-aarch64-<tp_sha>-<repo_stamp>-<hashFiles('packages/julia/**')>`
  (`build-package.yml:182,336`). **Tocar la receta o cualquier `*.patch` paga
  ~45-52 min de reconstrucción.** Mientras un run esté midiendo una hipótesis, no
  modifiques `packages/**`.

## Publicación y salida

- La salida esperada es **triple**: `.deb` y `.pkg.tar.xz` (el usuario gestiona
  Termux con pacman; ver `repo.json`) más un bundle `.tar.gz` + `SHA256SUMS.txt`.
- **Publicar es explícito**: solo `workflow_dispatch` con input `publish=true`
  (`build-package.yml:444`). **Un build verde no publica nada ni mueve el puntero
  `julia-latest`.**
- Inspección de un run: `gh run view <id> --json status,conclusion` es la fuente
  de verdad; `gh run watch` devolvió 0 en runs fallidos (PROGRESS "Notas").
- Definición de hecho está en `scripts/device-smoke.sh` (se corre **en el
  dispositivo**, nunca en CI): "compila" no es "funciona".

## Reglas del árbol de paquetes

- `packages/<pkg>/build.sh` es la receta declarativa (API de termux-packages:
  `termux_step_pre_configure`, `termux_step_configure`, `termux_step_make`,
  `termux_step_make_install`, `termux_step_post_make_install`,
  `termux_step_pre_massage`). No tiene vocabulario de cross.
- Los parches viven como ficheros `packages/julia/*.patch` (22) y contenido de
  deps en `packages/julia/patches/deps/*.patch` (2); `termux_step_patch_package`
  los aplica antes de configure. La receta los revalida en cada gate contra el
  tarball real.
- **Un gate nunca mantiene su propia copia de lo que el build hace.** Si necesita
  una lista (sonames que `base/Makefile` pedirá, el triplet que se empotra, los
  nombres versionados que el fuente dlopen'ea, **el directorio que el loader
  busca** para esos nombres), la **deriva** con `make`/`grep` sobre el árbol
  parcheado: `scripts/symlinked-libraries.sh`,
  `scripts/embedded-triplet.sh`, `packages/julia/soname-aliases.sh`,
  `scripts/runtime-library-dir.sh`. Una lista a
  mano ya costó un run de 44 min mirando `libopenblas.so` mientras el build moría
  por `libblas.so` (run 37823556050), y un directorio escrito a mano otro de 54 min
  con los 8 alias creados en un sitio que `libjulia-internal.so` no lee (run
  37862103015).
- **Un parche arregla la capa que produce el valor, no la que lo consume.** El
  `base-binaryplatforms.jl.patch` viejo reescribía el mensaje de error de
  `contrib/normalize_triplet.py` una capa demasiado abajo; hoy lo canoniza
  `packages/julia/contrib-normalize_triplet.py.patch` y
  `scripts/embedded-triplet.sh` lo verifica por round-trip.
- Cada `sed` en un script va protegido (`|| echo "Warning: …" >&2` o
  `2>/dev/null || true`); un `sed -i` pelado bajo `set -e` aborta sin huella.

## Commits

`<type>(<scope>): <summary>` — tipos: `fix|feat|docs|refactor|chore|ci|test|vendor`.
Ejemplos reales del repo: `fix(julia): link the versioned sonames before make
starts`, `test(gate): demand an answer for every versioned soname the source
dlopens`.

## Estado honesto (2026-10-08)

La cadena está medida hasta el minuto 49: LLVM bundled, flisp, `src/`,
`julia-base` con sus symlinks derivados, arranque de `julia` y el bootstrap de la
sysimage arrancando. **No** hay todavía `.deb`/`.pkg.tar.xz` producido, y
`sys-o.a` + precompile, empaquetado y la verificación en dispositivo (Fase 5)
están **sin demostrar**. Donde `PROGRESS.md` dice "compila", no escribas
"funciona". El detalle, con run IDs y minutos, está en `PROGRESS.md`.

## Dónde mirar

| Quiero saber… | Archivo |
|---|---|
| qué falló, en qué minuto, qué gate lo cerró, qué queda | `PROGRESS.md` |
| por qué el build es así y qué hace cada gate | `ARCHITECTURE.md` |
| la receta y sus flags reales | `packages/julia/build.sh` |
| el DAG real (lint → build → bundle → publish) | `.github/workflows/build-package.yml` |
| cómo se materializa el prefijo en el runner | `.github/actions/termux-builder/action.yml` |
| el gate local completo | `scripts/rehearse-recipe.sh` |
| derivación de sonames / triplet / alias versionados / directorio buscado por el loader | `scripts/symlinked-libraries.sh`, `scripts/embedded-triplet.sh`, `packages/julia/soname-aliases.sh`, `scripts/runtime-library-dir.sh` |
