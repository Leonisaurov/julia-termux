# ARCHITECTURE.md — por qué el build de Julia para Termux es así

> Última actualización: 2026-10-09 ~10:45 UTC.
>
> Este documento explica el **por qué**: qué decisión sostiene el sistema de
> build, qué mecanismo del entorno produce cada modo de fallo y qué principio
> motivó cada gate. Las **reglas operativas** (qué está permitido, qué cuesta
> dinero) están en `AGENTS.md`; el **estado con evidencia** (run IDs, minutos,
> hipótesis en curso) está en `PROGRESS.md` y es la única fuente fechada. El
> uso práctico (instalar, probar, inspeccionar) está en `README.md`. Si este
> archivo y `PROGRESS.md` discrepan, gana `PROGRESS.md`.

---

## 0. Índice

1. [La decisión que sostiene todo: host == target](#1)
2. [El entorno del runner como fuente de modos de fallo](#2)
3. [Gates: uno por fallo medido](#3)
4. [La regla de capa](#4)
5. [La receta: flags y parches, y por qué cada uno](#5)
6. [DAG, caché y presupuesto](#6)
7. [Artefactos y su inspección](#7)
8. [Verificación en el dispositivo](#8)
9. [Límites conocidos y estado honesto](#9)
10. [Restos de la ruta abandonada](#10)

---

<a name="1"></a>
## 1. La decisión que sostiene todo: host == target

### 1.1 Qué se abandonó, y por qué no era una cuestión de gusto

La arquitectura anterior cross-compilaba en Docker sobre un runner x86_64 con
`XC_HOST=aarch64-linux-android`, `HOSTCC=gcc`, un bootstrap manual de `flisp`
para el host y `scripts/build-deps-docker.sh`. Fue **abandonada**, no
"postergada", por una razón mecánica: el build system de Julia necesita
**ejecutar** herramientas que él mismo acaba de compilar (el generador de
tablas `llvm-min-tblgen`, `flisp`, y después el propio `julia` para producir la
sysimage). En cross-compilación pura, sobre un host que no puede ejecutar el
target, eso obliga o a compilar dos veces cada herramienta o a emular aarch64;
el builder Docker hacía lo primero y moría **60–76 minutos después** de cada
run en `llvm-min-tblgen: Exec format error` (`PROGRESS.md` "Arquitectura
vigente", `AGENTS.md` "La arquitectura vigente").

No era un bug con arreglo: era la geometría del problema. Julia no soporta
cross-compilar su sysimage sin ejecutar código del target.

### 1.2 La cadena de sondas que legitima la arquitectura actual

La decisión no se tomó por intuición; hay tres workflows de viabilidad, cada
uno con la pregunta y la respuesta medidas, y **son la prueba de que el modo
on-device sobre `ubuntu-24.04-arm` funciona**:

| Workflow | Pregunta | Resultado |
|---|---|---|
| `.github/workflows/probe-bionic-exec.yml` | ¿ejecuta un ELF bionic/aarch64 (el `linker64` de Android + userland Termux) en un runner de GitHub? | sí — eso decidió la arquitectura; el fixture vive en la rama huérfana `ci/probe-rootfs` |
| `.github/workflows/probe-native-termux.yml` | ¿también funciona el *toolchain* de Termux cuando su prefijo se materializa en la ruta absoluta que va quemada en los binarios? | sí — clang de Termux compila y enlaza ahí |
| `.github/workflows/probe-ondevice-builder.yml` | ¿el propio `build-package.sh` de termux-packages, en su rama on-device, construye un paquete real dentro de un rootfs Termux en el runner? | sí — el sujeto de prueba fue un paquete pequeño real, no Julia |

Consecuencia: **el CI usa exactamente el camino que ya funciona en el
teléfono**. Esto no es una optimización, es una propiedad de seguridad: la
hipótesis "esto compila" se mide con el mismo ejecutor, el mismo loader y el
mismo prefijo que tendrá el usuario.

### 1.3 Cómo se activa el modo on-device

`termux-packages` decide su modo por la presencia de un fichero:

```sh
# build-package.sh:38 (clonado de termux-packages en el runner)
if [[ "$(uname -o)" == "Android" || -e "/system/bin/app_process" ]]; then
```

El runner no es Android, así que `.github/actions/termux-builder/action.yml`
le da esa señal:

```yaml
# action.yml:51-52
sudo mkdir -p /system/bin
sudo touch /system/bin/app_process
```

Con esa rama activa, `build-package.sh` exige además que el target coincida
con el entorno ("For on device builds cross compiling is not supported",
`build-package.sh:443-446`) y toma la arquitectura de `dpkg
--print-architecture` (`action.yml:50`), y se niega a correr como root
(`build-package.sh:39-42`), por lo que el action `chown` del prefijo al usuario
del runner (`action.yml:133-136`).

### 1.4 Consecuencia directa: el LLVM bundled es compilable

Si host == target, el compilador real es el `clang` de Termux y todo binario
generado se puede ejecutar en el mismo sitio donde se genera. Por eso la
receta puede permitirse **compilar LLVM desde `deps/llvm.mk`**:

- `USE_SYSTEM_LLVM := 0` (`packages/julia/build.sh:84`). Julia 1.12 pinea LLVM
  18.1.7 con sus propios parches y una versión de símbolos `JL_LLVM_18.1`, y
  Termux solo ofrece LLVM 21: usar el del sistema no es una opción, es otra
  ruta de fallo.
- El corolario se verifica en el artefacto, no en la fe: `build-package.yml:408-427`
  rechaza un `libjulia-codegen.so` enlazado contra `libLLVM-21` y exige el
  symver `JL_LLVM_18.1`; la receta ya lo comprueba tras install
  (`build.sh:239-257`).
- Medido: LLVM 18.1.7-4 completo en ~43 min (`PROGRESS.md` "Avance medible").

`packages/llvm-julia` **no es la ruta**: es la contingencia cacheada de la
Fase 2 de `PROGRESS.md` para el caso de que el LLVM bundled resultara no
cacheable. Hoy no existe en el árbol (`packages/` solo contiene `julia`), y
nada en el DAG lo invoca.

### 1.5 El empaquetado es una consecuencia, no un paso aparte

En modo on-device, termux-packages empaqueta **todo lo más reciente que el
stamp de build** dentro del prefijo vivo:

```sh
# scripts/build/termux_step_copy_into_massagedir.sh:5
tar -C "$TERMUX_PREFIX_CLASSICAL" -N "$TERMUX_BUILD_TS_FILE" --exclude='tmp' --exclude='__pycache__' -cf - . | ...
```

Eso es correcto en un teléfono y peligroso en un runner compartido: un proceso
ajeno que escriba durante la compilación entra en el payload (el documento
cita el caso real de un `.deb` que salió con `var/log/...` y `opt/flutter/**`).
Por eso existen **dos mitades de la misma defensa**:

- `termux_step_pre_massage()` en la receta poda lo que no es Julia y **imprime
  cada ruta podada**, para que una suposición equivocada se vea en el log en
  lugar de manifestarse como un fichero que falta (`build.sh:268-307`).
- `build-package.yml:347-392` hace la mitad contraria: desmonta el `.deb` y
  exige que **no haya nada fuera del footprint de Julia**, con la lista de
  nombres permitidos copiada de `termux_step_pre_massage()`. La duplicación es
  deliberada y está declarada: si cambias el hook sin cambiar la comprobación,
  esta se pone roja (`build-package.yml:351-355`).

---

<a name="2"></a>
## 2. El entorno del runner como fuente de modos de fallo

Un prefijo Termux materializado dentro de un Linux glibc no es un entorno
neutro: es **dos sistemas de nombres y dos loaders conviviendo**. Casi todos
los fallos de la cadena no son de Julia ni de Termux, son de esa convivencia.
Los cinco mecanismos, cada uno con su run medido (`PROGRESS.md` "Cadena de
modos de fallo"):

| Mecanismo | Efecto | Cierre en el action |
|---|---|---|
| `libtermux-exec` (`LD_PRELOAD=$PREFIX/lib/libtermux-exec.so`, `action.yml:220`) reescribe `/bin`, `/etc`, `/lib`, `/usr`, `/var` en `execve`/`open` | las herramientas del runner son **inalcanzables** desde una shell con ese entorno, sin importar cómo las escribas: `/usr/bin/curl` se convierte en el `curl` bionic del prefijo (run 37786844653) | copias del host en `~/.termux-builder-hostbin`, una ruta que no está bajo ningún prefijo aliasado (`action.yml:208-213`) |
| Un `LD_PRELOAD` bionic heredado a una herramienta glibc | el loader de glibc toma `libtermux-exec.so` como ELF, resuelve su `DT_NEEDED "libc.so"` contra el linker script de Debian y aborta con `invalid ELF header` (run 37788134488) | `LD_PRELOAD` **nunca** va a `GITHUB_ENV`; solo al fichero de entorno que sourcean los pasos que necesitan Termux (`action.yml:214-228`), y `unset LD_PRELOAD` en el hijo (`action.yml:241`) |
| El shebang del script que arranca el build | `build-package.sh` empieza con `#!/bin/bash`; el kernel ejecuta el bash glibc del runner con el preload bionic en el entorno y su loader muere **sin imprimir una línea** (rc 127 a los 12 ms, run 37789690789) | el build se lanza desde un script generado con shebang del prefijo: `#!/data/data/com.termux/files/usr/bin/bash` (`build-package.yml:260`) |
| El resolver DNS de bionic en estos runners | `No address associated with hostname` para **cualquier** nombre; el `curl` del host resuelve el mismo nombre sin problema (run 37782123436) | toda la closure se baja con el `curl` del host (`action.yml:85-88,106-109`) y `apt update` **desaparece del pipeline** |
| Herramientas del Tier 1 de termux-packages | `build-package.sh:64` ejecuta `jq` sobre `repo.json` **antes** de leer ninguna receta; el aliasado convierte esa llamada en `/usr/bin/jq` → `jq` del prefijo, donde no estaba (run 37790992541) | `jq`, `unzip`, `lzip` en los roots de la closure (`termux-closure-resolver.py:51`) |

### 2.1 El shim de `curl`, o cómo se baja un tarball sin resolver DNS

`termux_download.sh:55` y todos los `deps/*.mk` de Julia descargan con `curl`.
En el entorno del prefijo eso es bionic, que aquí no resuelve nada. El action
no parchea termux-packages ni la receta: **sustituye el binario**, dejando el
original como fallback (`action.yml:264-294`):

```sh
mv "$ROOT/bin/curl" "$ROOT/bin/curl.bionic"     # conservado, no borrado
# $ROOT/bin/curl = shim con shebang del prefijo que hace:
#   unset LD_PRELOAD; exec "$TERMUX_BUILDER_HOSTBIN/curl" "$@"
```

Y lo demuestra en el job de dos minutos, no una hora dentro de una compilación:
el propio paso hace un `--range 0-0` de la URL del tarball de Julia 1.12.6 que
figura en la receta (`action.yml:292-294`).

### 2.2 Cómo se siembra el prefijo (y por qué no se instala)

1. **Runtime Android**: se baixa la rama `ci/probe-rootfs` del propio repo, se
   verifica su SHA-256 fijado y se descomprime `/system` (`action.yml:44-53`).
   Los ELFs bionic piden `PT_INTERP /system/bin/linker64`: sin ese árbol no
   ejecuta **nada** del prefijo (run 37716844030). La rama es un **asset del
   build**: borrarla rompe todos los jobs que usan el action.
2. **Closure de paquetes**: un único paso resuelve el cierre transitivo sobre
   el índice `Packages.gz` de Termux y extrae cada `.deb` con `dpkg-deb -x`
   contra `/` (`action.yml:98-112`).
3. **Base de datos sembrada**: se anexa a `$PREFIX/var/lib/dpkg/status` un
   `Status: install ok installed` por paquete (`action.yml:113-131`). Esto
   existe porque `termux_step_start_build.sh:125` ejecuta
   `apt install -y termux-elf-cleaner` **incondicionalmente** en toda build
   bionic on-device; con el paquete sembrado, apt responde "already the newest
   version" sin tocar la red, y el job `lint`/`build` lo comprueba llamando a
   ese `apt install` exacto (`action.yml:161-171`).
4. **Formato y paquete manager**: `repo.json` declara `pkg_format`, y
   `build-package.sh:438-441` sourcea (línea 441) `$PREFIX/bin/termux-setup-package-manager`
   para aprender el gestor; un runner no tiene la app Termux que lo traiga, así
   que el action lo crea (`action.yml:147-153`).
5. **Cobertura verificada**: el paso "Check that the closure really covers the
   recipe" lee la receta (`TERMUX_PKG_DEPENDS`/`TERMUX_PKG_BUILD_DEPENDS`) y
   exige `dpkg -s` para cada root; si falta uno, el mensaje es "fix the
   resolver, not the build" (`action.yml:173-194`).
6. **Tabla de herramientas**: el action exige en PATH las que el build realmente
   ejecuta (incluidas `ar`, `ranlib`, `objcopy`, `readelf`, `dsymutil`, que en
   Termux vienen de `llvm`, no de `binutils`) (`action.yml:244-262`).

`TERMUX_SKIP_DEPCHECK=true` (`-s` en `build-package.yml:263`) hace inalcanzables
las ramas de `apt`/`gpg` de `build-package.sh`: por eso el prefijo se **siembra**
en lugar de instalarse, y por eso gnupg está deliberadamente fuera de la closure
(`termux-closure-resolver.py:46-51`).

### 2.3 El paso `gmake`: un fallo del entorno, arreglado en una sola capa

CMake sondea `gmake` antes que `make` y guarda el resultado como **ruta
absoluta**. En un teléfono el sondeo no encuentra nada y usa `$PREFIX/bin/make`;
en el runner contesta el `/usr/bin/gmake` del host, y ejecutar esa ruta desde un
proceso bionic vuelve a caer en el aliasado, donde no hay `gmake` (run
37801929253, perdido en el configure de LLVM). El cierre es `ln -s make
$PREFIX/bin/gmake` (`action.yml:296-317`), es decir, **la capa que produce el
valor**, y por eso arregla todos los deps basados en CMake a la vez (LLVM,
utf8proc, dSFMT) en lugar de un `-DCMAKE_MAKE_PROGRAM` por dep. La prueba no es
que `gmake --version` funcione: es configurar **y compilar** un proyecto CMake
real (`action.yml:319-343`).

### 2.4 Ruido benigno conocido

Aparece en todo log de estos runners y no debe leerse como fallo: `linker:
Warning: failed to find generated linker configuration from
"/linkerconfig/ld.config.txt"`, `__bionic_open_tzdata: …`, `bionic-icu: couldn't
open libicu.so`, `expr: syntax error: unexpected argument 'Warning:'` (se cuela
en una sustitución de comando de `configure`; autoconf cae a su default), y
`Warning: git information unavailable`. El build filtra el primero
(`build-package.yml:293,467`). **No** es ruido `error: linker cannot load itself`:
ese fue la causa del run 37811196090 (§3.4).

---

<a name="3"></a>
## 3. Gates: uno por fallo medido

### 3.0 El principio común

Tres invariantes recorren todos los gates; ninguna es estética:

1. **Un gate nunca mantiene su propia copia de lo que el build hace.** Si
   necesita una lista (qué sonames va a pedir `base/Makefile`, qué triplet se va
   a empotrar, qué nombres versionados pide el fuente), la **deriva**
   preguntándole a `make` o al propio fuente. Una lista escrita a mano costó un
   run de ~44 min mirando `libopenblas.so` mientras el build moría por
   `libblas.so` (run 37823556050).
2. **Un stdout vacío nunca es "nada que comprobar".** Cada script de gate
   distingue `exit 2` (no se pudo derivar, el árbol no está configurado, `make`
   se negó a parsear) de `exit 1` (derivado, y el valor es inválido) y de `exit
   0`. Los reportes corren con `|| true`; solo las aserciones fallan. Esto viene
   de un job que murió en un *diagnóstico*: un `du` sobre un directorio que el
   build fallido nunca había creado bajo `set -e` (run 37784767638).
3. **Nada caro empieza sin el gate.** Un run de CI cuesta ~49-55 min y responde
   una sola hipótesis; el gate responde en segundos y el job `lint` es
   prerequisito duro de `build` (`build-package.yml:136`).
4. **Una aserción decide sobre salida capturada, nunca sobre una tubería.**
   `build-package.sh:21` ejecuta los hooks de la receta y los pasos del workflow
   con `set -euo pipefail`; ahí `productor | grep -q PAT` deja de probar la salida
   del productor y pasa a **competir** con él: `grep -q` sale en el primer match
   mientras `readelf -V` aún imprime sus ~35 000 entradas de `.gnu.version`, el
   productor recibe SIGPIPE, pipefail propaga **141** y el `||`/`if` lo lee como
   "ausente". Medido aquí contra una librería **correcta**: la forma vieja da
   `rc=141`. El patrón cuesta un run cuando el falso negativo aborta un build
   bueno (run 37904805726, ~63 min, el primer `make install` completo del port) y
   cuesta cero diagnósticos cuando lo que tapa es un defecto real (TEXTREL,
   `libLLVM-21`). Forma correcta: `_out=$(productor … 2>&1 || true)` y `case
   "${_out}" in *PAT*) …`, lo que además permite distinguir "no existe" de
   "existe y no cumple". El gate `pipes into grep -q` (§3.3) lo impide
   estáticamente.

Medición del avance (de `PROGRESS.md` "Avance medible"): `12 ms` → `4 min` →
`4.5 min` → `43 min` → `44 min` → `47 min` → `49 min`. Cada salto corresponde a
un gate nuevo.

### 3.1 La cadena de modos de fallo (el corazón del documento)

La cadena va del 2026-10-08 al 2026-10-09; la evidencia completa, con más detalle, está
en `PROGRESS.md` "Cadena de modos de fallo".

| Run | UTC | Síntoma | Causa raíz | Cierre |
|---|---|---|---|---|
| 37716844030 | — | nada bionic ejecuta | ELFs con `PT_INTERP /system/bin/linker64` | rama `ci/probe-rootfs` + el action la descomprime, con checksum fijado |
| 37782123436 | 13:09 | `No address associated with hostname` | el resolver bionic no tiene DNS en el runner; el `curl` del host sí | toda la closure se baja con el host y `apt update` desaparece (`bcd822b`) |
| 37784767638 | 13:29 | el job muere en un *diagnóstico* | `set -e` sobre un reporte (`du` de un directorio que el build fallido no creó) | los reportes con `|| true`; solo las aserciones fallan (`bb2f0e0`) |
| 37786844653 | 13:45 | `/usr/bin/curl` "no existe" | `libtermux-exec` reescribe `/bin`, `/etc`, `/lib`, `/usr`, `/var` en `execve`/`open` | herramientas del host copiadas a `~/.termux-builder-hostbin`, ruta no aliasada (`d5e227a`) |
| 37788134488 | 13:54 | `invalid ELF header` | `LD_PRELOAD` bionic dentro de una herramienta glibc (`df`) | `unset LD_PRELOAD` en el hijo y `LD_PRELOAD` fuera de `GITHUB_ENV` (`53b8a49`) |
| 37789690789 | 14:06 | rc 127 a los 12 ms, sin una línea | shebang `#!/bin/bash` de `build-package.sh` ejecutado por el kernel con el preload bionic en el entorno | el build se arranca con un script cuyo shebang es el del prefijo (`2915554`) |
| 37790992541 | 14:15 | `build-package.sh:64: /usr/bin/jq: cannot execute` | el aliasado vuelve inalcanzable el `jq` del runner y faltaba el Tier 1 de `setup-termux.sh` en la closure | `jq`, `unzip`, `lzip` en los roots + shim `$PREFIX/bin/curl` (`12f31be`, `bd781c6`) |
| 37795904301 | 14:51 | `Make.inc:1434 … without a functioning fortran compiler!` | `Make.inc:541` fija `FC := gfortran`; Termux no trae `gfortran` y OpenBLAS se construyó con `-DC_LAPACK=ON` | `FC := $PREFIX/bin/clang` en `Make.user` + sonda `-dM -E`/`__GNUC__` (`755fab0`) |
| 37801929253 | 15:34 | CMake: `/usr/bin/gmake: no such file or directory` | CMake ancla `CMAKE_MAKE_PROGRAM` a la ruta del host; `make` de Termux no provee `gmake` | `$PREFIX/bin/gmake -> make` + sonda que configura **y compila** (`e2802de`) |
| 37803324627 | 15:45 | 4 errores en `src/flisp/flisp.c:991` | ciclo de macros `BYTE_ORDER ↔ __BYTE_ORDER` entre `dtypes.h` y el `<sys/endian.h>` de bionic: el preprocessor corta la recursión, ambos valen 0 y `#if BYTE_ORDER == BIG_ENDIAN` se vuelve `0 == 0`; se compila la rama big-endian, cuyo `#define` en `flisp.c:990` carece de barra de continuación (bug latente de upstream) | `#ifndef` en los tres `#define` de `dtypes.h` + sección "endianness macros" en el gate (`f1f9638`) |
| 37811196090 | 16:44 | `Unable to locate libpcre2-8.so` → `Makefile:93: julia-base`, ~47 min, con LLVM y flisp ya compilados | el `libwhich` parcheado **moría al responder**: su rama sin `dlinfo` re-`dlopen`ea cada imagen que `dl_iterate_phdr` reporta para comparar el handle, y la primera es `/system/bin/linker64`. En el teléfono ese pedido se rechaza por namespace y devuelve `NULL` sin consecuencias; en el runner, sin `/linkerconfig/ld.config.txt`, `/system/bin` sí es ruta de búsqueda y bionic se niega a cargarse a sí mismo (`error: linker cannot load itself`), matando el proceso **con stdout sin flush** → `libwhich -p` respondió `""` con rc=1 y el `2>/dev/null` de `base/Makefile:166` se llevó la única pista | `RTLD_LAZY \| RTLD_NOLOAD` al sondear el mapa (la rama Apple de libwhich ya lo usa) + saltar entradas sin `/` inicial, en `patches/deps/termux-libwhich-dlinfo-android.patch`; verificado con el tool real en el gate |
| 37820685855 | 18:00 | `GATE: FAIL` con `resolution=1` en `lint`; el build ni empezó | la sonda nueva heredaba el algoritmo fatal de libwhich: `FAIL libpcre2-8.so` con el detalle vacío, porque el proceso moría antes de imprimir | la sonda reporta **por etapas** (`CTRL` de arranque, `LOAD <soname> ok` con `flush`, `NEEDED` del binario, stderr completo): un stdout vacío ahora significa "no llegó a `main()`" |
| 37823556050 | 18:20 | `GATE: PASS` y `PROBE: PASS` en el runner, pero ~44 min después `Unable to locate libblas.so` → `Makefile:250` → `Makefile:93: julia-base`; el fix de libwhich **sí** había funcionado | el nombre que faltaba no era el que se verificaba: con `USE_SYSTEM_BLAS := 1`, `Make.inc` fija `LIBBLASNAME := libblas`/`LIBLAPACKNAME := liblapack` y `base/Makefile` pregunta por **esos alias**, que en Termux pertenecen al paquete split `blas-openblas`; la receta solo declaraba `libopenblas`, y gate y sonda llevaban la lista a mano | `blas-openblas` en `TERMUX_PKG_BUILD_DEPENDS`; `scripts/symlinked-libraries.sh` deriva los 19 nombres con `make` sobre el árbol parcheado; `MISS` pasó a ser `FAIL` |
| 37833826111 | 19:41 | el job `build` **nunca arrancó**: el gate pasó con la lista derivada (19 nombres, `PROBE: PASS`) y falló el paso nuevo que se la pasa al job build | `tr '\n' ' '` convierte el último salto de línea en un **espacio final**, y la validación anclada `^[A-Za-z0-9_.+-]+( [A-Za-z0-9_.+-]+)*$` del propio paso lo rechaza; el guard era correcto, quien normalizaba mal era el join | `paste -sd' '`. Reproducido en el teléfono antes de tocar nada (`build-package.yml:116-119`) |
| 37841320064 | 21:33 | hipótesis de `libblas.so` **confirmada** en el build (0 apariciones de `System library symlink failure`, 19 `ln -sf` incluidos `libblas.so` y `liblapack.so`); ~47 min después muere en `sysimage.mk:129: usr/lib/julia/sysbase-o.a Error 1` con `ArgumentError("Platform \`ERROR: Unmatchable platform string 'aarch64-unknown-linux-gnu24'!-julia_version+1.12.6\` …")` | `base/Makefile:85` empotra `$(BB_TRIPLET_LIBGFORTRAN_CXXABI)` como `const BUILD_TRIPLET`, y esa variable es el stdout de `contrib/normalize_triplet.py $(BUILD_MACHINE)` invocado en `Make.inc:1380` **sin mirar el rc**. `BUILD_MACHINE` sale de `$(HOSTCC) -dumpmachine` (`Make.inc:917`) y en Termux es `aarch64-unknown-linux-android24`; las tablas del script no conocen android, así que imprimió su queja y **ese texto se convirtió en la constante**. El parche que había (`base-binaryplatforms.jl.patch`) reescribía `-android`→`-gnu` dentro de `parse`: una capa más abajo, arreglando el mensaje de error | `contrib-normalize_triplet.py.patch` (dos hunks) + eliminación del parche en `binaryplatforms.jl`; gate nuevo `scripts/embedded-triplet.sh`. Rojo→verde en el teléfono: `triplet=1` → `triplet=0 resolution=1` (descubierto el `libgfortran.so.5`, 19→20 nombres) → `triplet=0 resolution=0` con 19 nombres |
| 37851961397 | 22:12→23:05 | hipótesis del triplet **confirmada** (`Unmatchable` 0 veces, `julia` arranca, `sysimage.mk` invoca el bootstrap); ~49 min después aborta otra vez en `sysimage.mk:129`, ahora con `LoadError("gmp.jl", 0, ErrorException("could not load library \"libgmp.so.10\""))` | causa distinta, una capa más abajo: `base/gmp.jl:32` pide `"libgmp.so.10"` y `base/mpfr.jl:40` `"libmpfr.so.6"` como **literales** (upstream no lo nota porque compila su propio GMP, cuyo SONAME sí lleva versión) y el `dlopen` de Android empareja **nombres de fichero**; ningún SONAME del prefijo lleva versión (medido con `readelf -d`). El alias de `base/Makefile:162` no puede ayudar: crea el nombre **sin** versión. Y la receta creaba los symlinks en `termux_step_post_make_install`, **después** de `make` | `packages/julia/soname-aliases.sh` deriva los nombres del fuente y veredicta `native`/`alias`/`built`/`absent`; `termux_link_soname_aliases` los enlaza **antes** de `make` (hoy `build.sh:192`) y de nuevo tras install, en ambos casos en `usr/lib/julia` — el directorio que falsifica la fila siguiente; sección `dlopen'ed versioned sonames` en el gate. Rojo→verde: `sonames=1` (`build.sh never creates the aliases the source demands`, rc=5) → `sonames=0`, 8 alias, 21 `native`, `libblastrampoline.so.5` `built`, 8 `absent` inocuos *(el "inocuo" era el gate equivocado: preguntaba si `julia-base` exige el nombre, no si alguien lo carga sin guarda —véase la fila de 37876520515 y §3.7)* |
| 37859841658 | 23:30→23:35 | `GATE: PASS` en el runner y **la hipótesis no llegó a medirse**: 4 min 21 s, `ln: failed to create symbolic link 'usr/lib/julia/libcurl.so.4': No such file or directory`, `build rc=1` | el fix estaba roto, no la premisa: se enlazaba antes de `make` en un directorio que crea `make`; el gate nuevo era estático (¿se invoca la derivación antes del `make`?) y no preguntaba si el destino existe |
| 37862103015 | 23:55→00:49 (~54 min) | `mkdir -p` devolvió la cadena a su punto más lejano: los 8 alias creados, ni un `ln: failed` en 12 128 líneas, y `sysimage.mk:129` muere con el mismo `dlopen failed: library "libgmp.so.10" not found` | hipótesis de **presencia** falsificada; la causa es de **directorio**: el objeto que emite el `dlopen` es `libjulia-internal.so`, en `usr/lib`, con `RUNPATH` solo `$ORIGIN` (`Make.inc:1475,1472`; `src/Makefile:417`) |
| 37870492832 | 01:35→02:34 (~59 min) | hipótesis del directorio **confirmada** (cero `could not load library`, el bootstrap completa la carga de todos los stdlibs) y el abort se traslada a **emitir** el sysimage: 49× `scudo: Can't populate more pages`, 2× `St9bad_alloc`, `signal 6` → `sysimage.mk:129` | **causa abierta**, y no era RAM en reposo: el action reportó 14 621 MB disponibles al empezar y el log no medía nada durante el build | el run no cierra, **instrumenta**: zram + `vm.max_map_count` + watchdog de 20 s + paso `if: always()` (§3.7) |
| 37876520515 | 02:52→03:56 (~62 min) | la hipótesis de la memoria queda **falsificada por el propio instrumento** (186 muestras, `MemAvailable` mínimo 8 458 692 kB, los dos `.o.a` emitidos) y el muro se mueve al precompile: `FieldError: type Nothing has no field major` en `CompilerSupportLibraries_jll` | el stub *dummy* de upstream da por existente un runtime GCC que Termux no tiene y hace `dlopen` **sin guarda** de `libgcc_s`/`libstdc++`/`libgomp`; segundo defecto propio: mis parches `_jll` comprobaron `C_NULL` donde `dlopen(…; throw_error=false)` devuelve `nothing` | `stdlib-CompilerSupportLibraries_jll.jl.patch`, centinela `nothing` corregida, y gate nuevo `scripts/unguarded-dlopen.sh` (§3.7) |
| 37886407453 | 04:59→05:01 (2 min 24 s, **sin tocar `make`**) | `GATE: FAIL` en el runner: `unguarded libopenlibm.so.4 stdlib/OpenLibm_jll/src/OpenLibm_jll.jl:28` | `USE_SYSTEM_LIBM := 1` apaga `deps/Makefile:89-91`, nada bundlea openlibm, y la stdlib lo carga sin guarda | el gate **funcionó**: 2 min 24 s en vez de ~1 h; `stdlib-OpenLibm_jll.jl.patch` (§3.7) |
| 37891178350 | 05:59→07:02 (~1 h 3 min) | el precompile de stdlibs sale entero (cero `Failed to precompile`, `✓ Pkg`, `✓ Test`) y el muro se mueve a `make install`, que aborta en `Makefile:66 …/doc/_build/html/en/index.html` con `Could not resolve host: pkg.julialang.org` | los **docs HTML son prerequisito de `install`** en el Makefile de Julia y `doc/make.jl` instancia un entorno contra el registro General: red y versiones que la receta no fija. No era "el runner sin red": el mismo paso había bajado 2 124 kB dos minutos antes | `Makefile.patch`: `install` deja de pedir los docs y la copia pasa a ser tolerante; gate `goals and their prerequisites` (§3.3). Consecuencia declarada: el `.deb` no trae docs |
| 37904805726 | 08:24:57→09:28:25 (~63 min) | **primer `make install` completo del port** y el job muere cinco segundos después: `libLLVM-18jl.so lacks the JL_LLVM_18.1 symbol version`, `build rc=1`, `total 0` — **no hay `.deb`** | ni la LLVM ni el build: la aserción era un falso negativo. `readelf -V f \| grep -q PAT` bajo el `set -euo pipefail` de `build-package.sh:21` compite con `readelf`, que recibe SIGPIPE y propaga 141 (§3.0, invariante 4); medido aquí contra una librería correcta | salida capturada + `case` en la receta y en `Inspect the artifact`; gate `pipes into grep -q` (§3.3) |

Las secciones siguientes explican el **por qué** de cada cierre, no el qué.

### 3.2 `scripts/lint-workflows.sh` — el gate del gate

**Fallo que lo motivó**: GitHub ejecuta cada bloque `run:` como `bash -e {0}`.
Un error de sintaxis o un comando no protegido que devuelve distinto de cero
cuesta un arranque de runner completo y no dice nada de la hipótesis que se
quería medir. Pasó al menos una vez por categoría (`lint-workflows.sh:6-9`).

Qué hace y por qué cada pieza: parsear el YAML con PyYAML y **rechazar el fichero
si no parsea** (informando la posición real, no `<unicode string>`); rechazar las
palabras `and`/`or`/`not` dentro de `${{ }}` —PyYAML las acepta y GitHub rechaza
el fichero entero antes de crear un job, así que ese fallo consume una cola sin
producir log (`lint-workflows.sh:30-38,62-66`); extraer cada `run:` y pasarlo por
`bash -n` (incluidos los `run:` de las composite actions, que se ejecutan en
**todos** los jobs que las usan); advertir, no fallar, ante un fichero sin
bloques `run:` (la última vez que pasó era un `run:` mal indentado); y resolver
cada `uses: ./ruta` contra el disco.

### 3.3 `scripts/rehearse-recipe.sh` — el replay, no una simulación

**Fallo que lo motivó**: colectivamente, los modos de fallo que ocurrían dentro
del runner pero eran **deterministas y baratos de detectar fuera**: un `*.patch`
que deja de casar con upstream produce un `.rej` y un árbol medio parcheado; un
`USE_SYSTEM_* := 1` apuntando a una librería que Termux no shippea falla ~70 min
después; un soname que el loader no resuelve falla dentro de `julia-base` cuando
LLVM ya está compilado (`rehearse-recipe.sh:7-12`).

Es un **replay**, no una reimplementación: reimprime la selección de ficheros,
la sustitución de tokens `@TERMUX_…@` y el `patch -p1` de
`termux_step_patch_package()` (comparado con `termux-packages`), y ejecuta los
hooks reales de la receta (`termux_step_pre_configure`, `termux_step_configure`)
sobre el tarball pineado por SHA-256 (`rehearse-recipe.sh:63-72`). Las secciones,
con su motivo:

| Sección | Qué responde | Coste si se descubre en CI |
|---|---|---|
| `patch stage report` (`:80-128`) | los 26 parches aplican al árbol real, dry-run **y** aplicación real | árbol medio parcheado, fallo tardío |
| `goals and their prerequisites` (`:130-185`) | qué objetivos pasa la receta a `make` y —en el Makefile **ya parcheado**— de qué dependen: un objetivo que depende de los docs HTML depende de la red, y la copia de esos docs tiene que tolerar que no existan | run 37891178350, ~63 min |
| `pipes into grep -q` (`:187-223`) | si alguna aserción de la receta o de un workflow decide por `productor \| grep -q PAT`: bajo el `set -euo pipefail` real de `build-package.sh:21` eso no prueba el fichero, compite con él (§3.0, invariante 4). Une las continuaciones con barra invertida e ignora los comentarios que citan el patrón —el primer intento del gate se pilló a sí mismo: `pipes=2` y FAIL | run 37904805726, ~63 min |
| `endianness macros` (`:225-248`) | si el árbol parcheado settlea `BYTE_ORDER`; preprocesar un header, no compilar flisp | run 37803324627 |
| `recipe hooks` (`:250-291`) | rc de los hooks de la receta | — |
| `Make.user` (`:293-314`) | el generado **no resucita vocabulario de cross**: veta `XC_HOST`, `HOSTCC`, `HOST_CMAKEFLAGS`, `BUILDOFFLINE`, `flang`, `F77=`, `USE_SYSTEM_LLVM:=1`, `JULIA_PRECOMPILE:=0`, `usr-staging`, `@TERMUX_` | silenciar la ruta muerta por convención no basta; se comprueba |
| `Make.inc parse` (`:316-352`) | `Make.inc` acepta el `Make.user` **y** `FC_VERSION` no es vacío | run 37795904301, ~1 h |
| `system dependency reality check` (`:354-408`) | cada `USE_SYSTEM_* := 1` respaldado por un fichero o binario real del prefijo | ~70 min |
| `bundled-dep patches` (`:410-441`) | los ficheros que referencian `deps/*.mk` existen | fallo en `make -C deps` |
| `bundled-dep patch application` (`:443-492`) | cada `patches/deps/termux-*.patch` aplica **al commit que `deps/*.mk` descarga** (SHA de `deps/*.version`) | idem |
| `library resolution` (`:494-527`) | ver §3.4/§3.5 | run 37811196090, ~47 min |
| `embedded platform triplet` (`:529-550`) | ver §3.6 | run 37841320064, ~47 min |
| `dlopen'ed versioned sonames` (`:552-734`) | ver §3.7 | run 37851961397, ~49 min |
| `declared packages` (`:736-753`) | todo `TERMUX_PKG_*DEPENDS` existe en el repo de Termux | closure incompleta en el runner |

El veredicto es una línea machine-readable con todas las banderas
(`:755-757`) y `GATE: FAIL` con `exit 5` (`:758-764`). La línea de summary es
intencionadamente un registro: los gates rojo→verde citados en la tabla de arriba
se leen de ahí.

**Por qué el gate veta vocabulario de cross** y no simplemente no lo usa: porque
`termux_step_configure` genera el `Make.user` con un heredoc. Un flag residual
sobrevive ediciones y reescrituras de la receta indefinidamente; vetarlo en el
gate lo convierte en un hecho verificable en segundos.

### 3.4 `scripts/symlinked-libraries.sh` — derivar la lista preguntándole a `make`

**Fallo que lo motivó**: run 37823556050. Gate y sonda llevaban una lista escrita
a mano con `libopenblas.so`; el build murió 44 min después pidiendo `libblas.so`.
El nombre que faltaba no era el que se verificaba, y ni el gate ni la sonda podían
descubrirlo por construcción.

El mecanismo: el macro `symlink_system_library` de `base/Makefile:162` corre
`libwhich -p` por cada library del sistema y convierte una respuesta vacía en
`System library symlink failure` dentro del target `julia-base`. **Qué** nombres
son esos, y cuáles pueden fallar, es el producto de los `$(eval $(call …))` bajo
condicionales de OS/ARCH, de `LIBMNAME`/`LIBBLASNAME`/`LIBLAPACKNAME`/`SHLIB_EXT`
de `Make.inc` y de los flags `USE_SYSTEM_*` de la receta (`symlinked-libraries.sh:5-14`).

La derivación es una **grabadora**: se corta el bloque del árbol *parcheado* desde
el condicional que lo abre (`'WINNT emscripten'`) hasta el target que lo consume
(`symlink_system_libraries:`), se reemplaza el `define symlink_system_library`
por un `$(info CALL …)`, y se incluye el resultado sobre `Make.inc` con el
`Make.user` generado. Así expanden el mismo `versioned_libname` y `SHLIB_EXT`, y
los guardas `USE_SYSTEM_*` y los `ALLOW_FAILURE` se resuelven como en el build.
Detalles que son decisiones:

- Se busca por **contenido**, no por número de línea, porque la receta parchea
  ese mismo fichero (`base-Makefile.patch`); si el bloque cambia de forma, el
  gate falla en lugar de derivar una lista vacía (`:39-45`).
- `libLLVM` es una regla propia fuera del macro, bajo dos guardas, y se añade a
  mano en el mismo sitio que el resto (`:60-65`).
- stdout son **solo** los nombres cuya respuesta vacía aborta el build (guarda
  activa, sin `ALLOW_FAILURE`); stderr es la tabla completa, incluido lo que se
  saltó y por qué (`:84-95`). Una salida vacía es `FAIL`, nunca "nada que
  comprobar".
- Hoy: **19 nombres**, de los cuales `libblas.so` y `liblapack.so` son los que
  la lista a mano nunca vio.

### 3.5 `scripts/probe-library-resolution.sh` — la sonda por etapas

**Fallo que lo motivó**: run 37811196090 (`libwhich` matándose al responder, §3.1)
y luego run 37820685855, donde la sonda **heredó el mismo algoritmo fatal**:
reportaba `FAIL libpcre2-8.so` con el detalle vacío porque el proceso moría antes
de imprimir. Un fallo de diagnóstico es peor que un fallo de build: consume el
mismo run y no enseña nada.

Por eso el protocolo exige una línea por etapa, cada una flushada antes de la
siguiente (`probe-library-resolution.sh:14-18,103-107`):

- `CTRL` — ¿un binario recién compilado aquí alcanza `main()`? Si no, **todas**
  las librerías parecerían irresolubles; se comprueba antes de culpar a `dlopen`.
- `LOAD <soname> ok` — el loader encontró la librería. Lo que venga después ya
  es otro problema.
- `NEEDED`/`RUNPATH`/`interp` del propio binario de la sonda (`:154-162`) — la
  sonda lleva el mismo `PT_INTERP` y la misma cadena de loaders que la
  herramienta real, porque se compila con el clang de este entorno.
- stderr **completo** en cada fallo; el `2>/dev/null` de `base/Makefile:166` es
  exactamente lo que ocultó la pista original.
- `TOOL` — cuando se le pasa `--src-dir`, se compila el `libwhich` pinned y
  parcheado y se le aplica **la misma cadena de shell** que `base/Makefile:166`
  aplica a su respuesta (`:218-238`). No se imita el consumo: se reproduce.

La sonda no tiene lista propia: o `--tree` (y entonces llama a
`symlinked-libraries.sh`) o `PROBE_LIBS` con la lista que el job `lint` derivó.
Un nombre ausente del prefijo es `FAIL`, no `MISS`, porque `julia-base` aborta
justo ahí (`:181-190`).

**Por qué el `lint` pasa su lista al `build` por output del job**: el job build no
tiene árbol fuente en el momento de la sonda (`build-package.yml:47-51,105-125`);
inventar una segunda lista ahí es lo que dejó pasar `libblas.so` hasta un build.
Este handoff motivó además el run 37833826111: el join con `tr '\n' ' '` deja un
espacio final que la validación anclada del propio paso rechaza, y el guard era
correcto. Se usa `paste -sd' '` (`build-package.yml:116-119`).

### 3.6 `scripts/embedded-triplet.sh` — round-trip contra el productor, no contra una expectativa

**Fallo que lo motivó**: run 37841320064, 47 min, `sysbase-o.a` con `ERROR:
Unmatchable platform string 'aarch64-unknown-linux-gnu24'!` dentro de la
constante.

La cadena de causalidad, toda ella verificada en el fuente de Julia 1.12.6:
`Make.inc:917` pone `BUILD_MACHINE := $(shell $(HOSTCC) -dumpmachine)`; en
Termux eso es `aarch64-unknown-linux-android24`. `Make.inc:1380` calcula
`BB_TRIPLET_LIBGFORTRAN_CXXABI` como `$(shell …contrib/normalize_triplet.py…)`
**sin inspeccionar el rc**; cuando el script no reconoce el triple, imprime su
queja a stdout. `base/Makefile:85` escribe ese stdout en `build_h.jl` como `const
BUILD_TRIPLET`. `base/binaryplatforms.jl:958` le añade `-julia_version+1.12.6`,
`parse` no casa nada y lanza en `:769`, abortando el bootstrap en `sysimage.mk:129`.

La pregunta que hace el gate **no** es "¿se parece esto a un triplet linux": una
expectativa escrita a mano es justo lo que permitió que la respuesta anterior
fuera errónea. La pregunta es: ¿sobrevive el valor que se va a empotrar a un
**round-trip por la misma gramática** que `base/binaryplatforms.jl` parsea? Y eso
lo responde el mismo script que lo produce, invocado con el `$(PYTHON)` y el
`invoke_python` de `Make.inc` (`embedded-triplet.sh:40-52`). La verificación
cruzada adicional —transcribir el `triplet_regex` de `binaryplatforms.jl:678-695`
y comprobar que ni la cadena cruda ni la reescrita casan, mientras
`aarch64-linux-gnu-cxx11` sí casa— es lo que cerró el caso.

Un efecto de segunda capa que la sonda cazó antes de gastar un run: arreglado el
triple, el default "sin versión de compilador → `libgfortran5`" del propio script
añadía la etiqueta; `Make.inc:1385` la convierte en `LIBGFORTRAN_VERSION=5` y
`base/Makefile:239` pide `libgfortran.so.5` **sin** `ALLOW_FAILURE`. La lista
derivada pasó de 19 a 20 nombres y la sonda lo marcó como fallo. Por eso el
segundo hunk de `contrib-normalize_triplet.py.patch` no es cosmético (§4).

### 3.7 `packages/julia/soname-aliases.sh` — leer los literales del fuente

**Fallo que lo motivó**: run 37851961397, 49 min, `could not load library
"libgmp.so.10"` durante el bootstrap de la sysimage, con `$PREFIX/lib/libgmp.so`
instalado y correcto.

`dlopen` en Android empareja **nombres de fichero**. `base/gmp.jl:32` y
`base/mpfr.jl:40` piden nombres versionados estilo glibc como literales, porque
upstream compila su propio GMP, cuyo SONAME sí lleva la versión. Un `readelf -d`
sobre el prefijo muestra que ningún SONAME de Termux lleva versión. Y el alias de
`base/Makefile:162` no puede ayudar: `symlink_system_library` crea el nombre **sin**
versión en `usr/lib/julia`, y `libwhich -p libgmp.so.10` no resuelve.

La derivación es un `grep` de literales `"lib…so[.N…]"` sobre `base/*.jl` y
`stdlib/*/src/*.jl` (`soname-aliases.sh:43-48`) y un veredicto por nombre contra
el prefijo: `native`, `alias <nombre> <sin-versión>`, `built` (esta receta lo
compila) o `absent`.  `built` tampoco es una lista: son dos grafías leídas de
`deps/*.mk` (`libNAME.$(SHLIB_EXT)` en una regla; `$(SRCCACHE)/NAME-$(VER)` cuando
el install es el `make install` de upstream) **filtradas por la respuesta de
`make -C deps … print-deplibs`**, que en este árbol configura
`DEP_LIBS=JuliaSyntax blastrampoline libuv dsfmt llvm utf8proc terminfo libwhich`.
Sin ese filtro la derivación acreditaba `libunwind.so.8` como `built` —`unwind` está
apagado por `DISABLE_LIBUNWIND := 1` (`build.sh:126`)— y tapaba un muro; con él,
22 ficheros quedan fuera y el nombre vuelve a `absent`.

La **frontera de cobertura está declarada, no adivinada** (`:15-19`): esto lee
literales. Un nombre construido por interpolación (`"libgfortran.so." * major`,
`"libopenblas$(libsuffix).so"`) no es un literal y **no** aparece aquí; esos
sitios pertenecen a los parches de stdlib que resuelven o saltan su propio
`dlopen`, y `PROGRESS.md` los nombra como candidatos del tramo de precompile. Un
gate que pretende cubrir lo que no puede ver miente en verde.

La segunda parte del cierre es una **cuestión de capa temporal**: la receta creaba
los symlinks en `termux_step_post_make_install`, es decir **después** de `make`,
mientras el sysimage se bootstrapa **dentro** de `make`. Por eso
`termux_link_soname_aliases` se llama en `termux_step_make` antes de `make`
(`build.sh:176-192`) y se repite en `$PREFIX/lib/julia` tras install
(`build.sh:207-219`). El gate exige esa evidencia, no la asume: localiza el cuerpo
de `termux_step_make`, encuentra la línea de su `make` y reclama que la derivación
aparezca **antes** (`rehearse-recipe.sh:658-679`).

La tercera parte fue **una cuestión de capa espacial**, y costó un run entero:
37862103015 creó los 8 alias donde se los pedía y el bootstrap murió igual, con
`dlopen failed: library "libgmp.so.10" not found`. El nombre estaba, el
**directorio** no era el que el loader lee. El `dlopen` de un nombre sin barra lo
emite `src/dlload.c:376`, dentro de `libjulia-internal.so`; esa librería se enlaza
en `$(build_shlibdir)` = `usr/lib` (`src/Makefile:417`, `Make.inc:729,328,320`) con
`RPATH_LIB := RPATH_ORIGIN = -Wl,-rpath,'$ORIGIN'` (`Make.inc:1475,1472`), así que
su conjunto de búsqueda es su propio directorio, y `usr/lib/julia` —donde
`base/Makefile` deja sus 19 nombres sin versión, y donde la receta había puesto los
alias— no está en él. En el árbol instalado cambia todo: `make install` mueve el
objeto a `$(private_libdir)` y le fija `RUNPATH '$ORIGIN:$ORIGIN/../'`
(`Makefile:468-481`), por lo que `$PREFIX/lib/julia` sí es correcto allí. Medido en
el teléfono con ese layout (`$PREFIX/tmp/ororigin-probe`): una librería en `usr/lib`
con `RUNPATH=$ORIGIN` que hace `dlopen("libgmp.so.10")` devuelve el mensaje exacto
de CI con el alias en `usr/lib/julia`, y resuelve con el alias en `usr/lib`.

Como un literal escrito a mano ya había costado 50 minutos, el directorio se
deriva: `scripts/runtime-library-dir.sh` le pregunta a `make` por
`$(build_shlibdir)`, `$(private_libdir)`, `$(RPATH_LIB)` y
`$(reverse_private_libdir_rel)`, y **rechaza** el resultado si `RPATH_LIB` deja de
mencionar `$ORIGIN` (la premisa entera se cae con eso). La sección
`dlopen'ed versioned sonames` del gate compara esa respuesta con los destinos de
cada `termux_link_soname_aliases` de la receta (`rehearse-recipe.sh:680-710`):
`OK the aliases for the build tree go to usr/lib, the directory make names`, y
`FAIL nothing links the aliases into usr/lib (the build tree)` si alguien vuelve a
escribir otro. También cruza los `absent` con la lista REQUIRED de §3.4: un nombre
letal para `julia-base` y sin respuesta es `FAIL` (`:572-585`).

La cuarta parte fue **el `absent` que el gate llamaba nota**. Run 37876520515:
`stdlib/CompilerSupportLibraries_jll/src/CompilerSupportLibraries_jll.jl` hace
`dlopen(libgcc_s)` sin `throw_error` en su `__init__`, el precompile de
`pkgimage.mk:28` lo ejecuta dentro de `make`, y el nombre no lo responde ni el
prefijo ni `deps` (`USE_SYSTEM_CSL := 1`). La tabla de veredictos lo veía y lo
anotaba como inocuo porque solo preguntaba "¿lo exige `julia-base`?".  Desde
2026-10-08 la pregunta es **"¿lo carga alguien sin guarda?"**:
`scripts/unguarded-dlopen.sh` recibe los nombres `absent` por stdin, busca sus
`dlopen`/`dlopen_e` en los **mismos** ficheros que lee `soname-aliases.sh`
(`base/*.jl`, `stdlib/*/src/*.jl`), sigue los dos saltos del patrón
(`dlopen(ident)` y `helper(ident)`, con el helper juzgado por sus propios `dlopen`)
y veredicta `guarded`/`unguarded` por sitio.  `rehearse-recipe.sh:624-657` vuelve
`FAIL` cualquier `unguarded`
(`FAIL  %s is loaded without a guard at %s`), y el cruce demostró servir tres veces:
nombró las líneas 57/61/63 del stub CSL y, con la derivación filtrada por
`$(DEP_LIBS)`, `stdlib/LibUnwind_jll/src/LibUnwind_jll.jl:25`; la tercera fue
`stdlib/OpenLibm_jll/src/OpenLibm_jll.jl:28`, y esta **en el runner, no en el
teléfono** — ver el párrafo siguiente, que es sobre el prefijo y no sobre la
pregunta.

Hoy: 8 alias (`libcurl.so.4`, `libgit2.so.1.9`, `libgmp.so.10`, `libgmpxx.so.4`,
`libmpfr.so.6`, `libnghttp2.so.14`, `libpcre2-8.so.0`, `libssh2.so.1`), 15
`native`, `libblastrampoline.so.5` y `libdSFMT.so` `built`, y 7 `absent` —`libbar.so`
(nadie lo carga) más los seis que solo se cargan detrás de una guarda: los cuatro
del stub CSL, `libunwind.so.8` (`guarded …LibUnwind_jll.jl:31`) y
`libopenlibm.so.4` (`guarded …OpenLibm_jll.jl:33`), ambos con el parche aplicado.

La quinta parte fue **el prefijo equivocado**. Run 37886407453 (2 min 24 s, sin
tocar `make`): el mismo árbol y las mismas 24 reglas dieron `GATE: FAIL` en el
runner y `GATE: PASS` en el teléfono, y la diferencia no era la receta ni
`$(DEP_LIBS)` —idénticos— sino a **qué `$PREFIX/lib` se ejecutó
`soname-aliases.sh`**.  En el teléfono `libopenlibm.so.4` es un fichero del
`julia 1.12.6-1` publicado (`pacman -Qo`), o sea del paquete que este build
reconstruye: un `native` dado por el propio objeto de la reconstrucción no es
evidencia de que el build lo produzca.  `rehearse-recipe.sh` (`:524-567`) pregunta
ahora a una copia de `$PREFIX/lib` **sin los ficheros que posee el paquete que se
construye**: la lista sale de `pacman -Ql $PKG` (o `dpkg -L $PKG`), la copia de
`cp -as` se filtra con ella, y si el paquete no está instalado o no hay gestor de
paquetes no se quita nada y el log lo dice, porque un filtro silencioso sería un
veredicto que nadie puede trazar.  Discriminación medida: el filtro cambió
exactamente **un** veredicto (`libopenlibm.so.4` de `native` a `left absent`,
16→15 `native`) y con él el gate local reproduce la fila del runner; sobre el
árbol sin parchear el cruce marca `unguarded …OpenLibm_jll.jl:28`, con el parche
`guarded …:33` y `GATE: PASS` (`rehearse-openlibm2.log`, 2026-10-09 ~05:19 UTC).

### 3.8 `.github/scripts/termux-closure-resolver.py` — la closure como gate

Sin red dentro del prefijo (§2), todo lo que el build necesita tiene que salir de
**una** lista cerrada. El resuelve el cierre transitivo sobre `Depends`/
`Pre-Depends` del índice de Termux; los roots son el bootstrap recortado + el
Tier 1 de `setup-termux.sh` de termux-packages + `termux-elf-cleaner` + los
`TERMUX_PKG_*DEPENDS` de la receta (`termux-closure-resolver.py:25-52`). Su
política de fallo es deliberada: **solo** aborta si falta un root; una hoja sin
resolver (un paquete virtual, un `Pre-Depends` que Termux expresa de otra forma)
se reporta en stderr sin matar la preparación del prefijo (`:5-7,100-106`).
Imprime su propio reporte `resolved=… unresolved=…` **tenga éxito o falle**,
porque ese reporte es el diagnóstico.

---

<a name="4"></a>
## 4. La regla de capa

> Un parche arregla la capa que **produce** el valor, no la que lo consume.

Es la lección cruzada de dos fallos y un cierre:

- **Mal**: `base-binaryplatforms.jl.patch` hacía `replace("-android" => "-gnu")`
  dentro de `parse`. Esa función ya está mirando un `ArgumentError` construido a
  partir de un texto que **el error** contiene: el parche reescribía el mensaje,
  no el valor. De ahí la bizarrez medida de un `24` escrito como `gnu` en el log
  del run 37841320064, y de ahí que no pudiera arreglar nada.
- **Bien**: `packages/julia/contrib-normalize_triplet.py.patch` canoniza
  `-android<api>` → `-gnu` **donde nace la cadena**, en el script que `Make.inc:1380`
  invoca. Un solo punto, todos los consumidores a la vez (el `BUILD_TRIPLET`
  empotrado, el `USE_BINARYBUILDER` autodetectado en `Make.inc:1365`, las
  etiquetas de libgfortran y cxxabi).
- **Prueba de que la regla funcionó**: la cadena de fallo avanzó de capa. Con el
  fix en `binaryplatforms.jl` el bootstrap moría en `binaryplatforms.jl`; con el
  fix en `normalize_triplet.py` pasó de `binaryplatforms.jl` a `gmp.jl` (run
  37851961397), es decir, el obstáculo real se movió al siguiente problema en vez
  de maquillarse el anterior.

Consecuencias no obvias de tocar la capa productora:

1. **Puede activar cosas**. Hacer que `normalize_triplet.py` reconozca el triple
   hace que el test de `Make.inc:1365` pase, y ahí `USE_BINARYBUILDER ?= 1`. La
   receta lo impide con `:=`, que gana al `?=` (`build.sh:79`). Un arreglo en la
   capa productora exige revisar qué más escucha esa señal.
2. **Arrastra la segunda etiqueta**. Con el triple arreglado, el default
   "sin versión de compilador → `libgfortran5`" del mismo script habría añadido
   la etiqueta, `Make.inc:1385` la habría convertido en `LIBGFORTRAN_VERSION=5` y
   `base/Makefile:239` habría exigido `libgfortran.so.5` sin `ALLOW_FAILURE`. El
   segundo hunk del parche (`:111-124` del fichero original) suprime ese default
   para android, igual que para musl: bionic no tiene libgfortran.
3. **Es la misma lógica que el `gmake` del action** (§2.3): un symlink en la capa
   que produce la ruta que CMake va a anclar, en lugar de un `-DCMAKE_MAKE_PROGRAM`
   por dep.

Regla práctica asociada: los parches llevan en su cabecera **el por qué y el run
que lo motivó** (todos los `packages/julia/*.patch` empiezan con `# Termux/Bionic
port: <ruta tocada>` y un párrafo de motivo). Un parche sin explicación de capa no
se puede revisar cuando upstream cambie.

---

<a name="5"></a>
## 5. La receta: flags y parches, y por qué cada uno

### 5.1 flags del `Make.user` generado

El `Make.user` lo escribe `termux_step_configure` con un heredoc
(`build.sh:76-135`); no es un fichero versionado. Cada decisión existe por un
motivo medido:

| Flag | Por qué |
|---|---|
| `prefix`/`LOCALBASE = $TERMUX_PREFIX` | on-device: instalar dentro del prefijo vivo |
| `USE_BINARYBUILDER := 0` | `USE_BINARYBUILDER=0` es lo que impide que los deps se descarguen de ArtifactHub; hay que ganarle al `?=` de `Make.inc:1366`, que ahora **sí** querría activarse (§4.1) |
| `JULIA_CPU_TARGET := generic` | el target de CPU que `sysimage.mk:104,118` pasa como `-C` al bootstrap. La receta lo fija explícitamente; `Make.inc:1175` tiene `?= native` |
| `USE_SYSTEM_LLVM := 0` | Julia 1.12 pinea LLVM 18.1.7 + symver `JL_LLVM_18.1`; Termux solo da LLVM 21. Compilarlo es posible **porque host == target** (§1.4) |
| `USE_SYSTEM_LLD := 1`, `USE_SYSTEM_PATCHELF := 1`, `USE_SYSTEM_P7ZIP := 1` | binarios que Termux shippea y Julia solo necesita encontrar en PATH |
| `USE_SYSTEM_{ZLIB,PCRE,GMP,MPFR,OPENSSL,LIBSSH2,NGHTTP2,CURL,LIBGIT2,LIBSUITESPARSE,BLAS,LAPACK} := 1` | cada uno respaldado por un fichero real del prefijo; el gate lo comprueba uno a uno (§3.3) |
| `USE_SYSTEM_LIBM := 1` | libm es de bionic, no del prefijo: el gate **no** busca un fichero (`rehearse-recipe.sh:393`).  Consecuencia medida en 37886407453: con esta flag `deps/Makefile:89-91` no construye openlibm y `OpenLibm_jll.jl:28` lo pedía igual -> `stdlib-OpenLibm_jll.jl.patch` |
| `USE_SYSTEM_CSL := 1` | no hay `libgcc_s`/`libstdc++`/`libgfortran` que bundlear en bionic; también inercializa `deps/csl.mk`, el otro consumidor de `$(FC)` en parse-time (`build.sh:62-64`) |
| `USE_SYSTEM_{LIBUV,UTF8PROC,DSFMT,LIBWHICH} := 0` | Julia pinea sus propios forks/commits; las versiones de Termux son otras release y el código de Julia asume las suyas. `libwhich` **además** se parchea aquí (§3.1) |
| `FC := $PREFIX/bin/clang` | `Make.inc:541` fija `FC := $(CROSS_COMPILE)gfortran` y `Make.inc:1375` deriva `FC_VERSION` de `$(FC) -dM -E`; el guarda de `Make.inc:1432-1434` aborta si `FC_VERSION` es vacío y OpenBLAS/SuiteSparse no vienen de BinaryBuilder. Termux no trae `gfortran`; flang arrastraría una segunda toolchain LLVM (mlir, libllvm, libandroid-complex-math-static) para satisfacer un sondeo. El override **debe** vivir en `Make.user`: `Make.inc` lo incluye una segunda vez en `:754`, después de la línea 541 |
| `USE_BLAS64 := 0` | el `libopenblas` de Termux exporta símbolos ILP32 (`dgemm_`), no los suffixed `64_` |
| `USE_SYSTEM_LIBBLASTRAMPOLINE := 0` | se compila el LBT de Julia, que redirige a `$PREFIX/lib/libopenblas.so`; su SONAME versionado es lo que hace `built` en §3.7 |
| `DISABLE_LIBUNWIND := 1` | aarch64 usa el cambio de pila en ensamblar propio de Julia (`JL_HAVE_ASM`); libunwind no hace falta ni es portable aquí. Su guard en `src/signals-unix.c` es un parche aparte |
| `USE_PERF_JITEVENTS := 0` | Android no expone la interfaz de muestreo `perf(1)` que LLVM engancha |
| `CLANG_RT_BUILTINS := $PREFIX/lib/clang/*/lib/linux/libclang_rt.builtins-aarch64-android.a` | bionic no tiene `libgcc_s`: los builtins de compiler-rt son los que aportan esos símbolos, y hay que enlazarlos `--whole-archive` en el loader (`cli-Makefile.patch`) y en runtime/codegen (`src-Makefile.patch`). La receta **aborta** si el .a no está (`build.sh:47-53`) |
| `JULIA_PRECOMPILE := 1` | los stdlibs precompilados son lo que hace que `Pkg`/`LinearAlgebra` se comporten como el paquete real; el runner tiene memoria para ello. En el teléfono, no |

No hay `CC` ni `CXX` a propósito: `Make.inc` detecta clang desde `cc --version` y
elige `USECLANG` solo, y el clang de Termux ya apunta al API level del dispositivo.

### 5.2 Las 26 + 2 parches, por capa

Convención de `termux-packages` (`termux_step_patch_package.sh:5-34`): los
`*.patch` se aplican con `patch -p1` en orden alfabético, con los tokens
`@TERMUX_*@` sustituidos; existen sufijos condicionales (`.patch32`/`.patch64`,
`.patch.debug`, `.patch.ondevice`) que aquí no se usan. El nombre del fichero es
documentación de la ruta tocada (`/` → `-`), no un mecanismo.

| Capa | Ficheros | Motivo común |
|---|---|---|
| Build system | `Make.inc.patch` (quita `libgcc_s` de las listas de deplibs del loader), `Makefile.patch` (`install` deja de pedir los docs HTML; ver la nota bajo la tabla), `base-Makefile.patch` (`ALLOW_FAILURE` en `libm`, `libgcc_s`, `libstdc++`: el mismo trato que Julia ya da a `libssp`/`libatomic`/`libgomp`), `cli-Makefile.patch` (Android rechaza `DT_TEXTREL`; compiler-rt en el loader), `src-Makefile.patch` (compiler-rt en runtime y codegen), `deps-llvm.mk.patch` (cmira al zlib de Termux, no al `deps/usr` vacío), `deps-libuv.mk.patch` y `deps-libwhich.mk.patch` (insertan un target `source-patched` en la cadena de rules de los deps) | la capa que **produce** valores de build |
| Runtime C/C++ | `src-support-platform.h.patch` (define `_OS_ANDROID_`; es el guard maestro de todo lo demás), `src-support-dtypes.h.patch` (ciclo de endianness + `uint_t` de bionic), `src-sys.c.patch` (`jl_pathname_for_handle` por `dl_iterate_phdr`: no hay `dlinfo`), `src-cgmemmgr.cpp.patch` (sin `shm_open` → fallback `tmpfile`), `src-debuginfo.cpp.patch` (sin `__register_frame` sin libgcc_s), `src-gc-debug.c.patch` (sin `malloc_stats`), `src-init.c.patch` (sin `pthread_get_stackaddr_np`), `src-jlapi.c.patch` y `src-scheduler.c.patch` (rr no existe; su syscall de probe 1008 lo bloquea seccomp), `src-runtime_ccall.cpp.patch` (sin `getdomainname`), `src-signals-unix.c.patch` (`signal_bt_*` referenciados fuera del guard de libunwind), `cli-loader_lib.c.patch` (saltar la sonda de `libstdc++`: hay libc++ y no hay ldconfig) | bionic ≠ glibc, y Julia solo conocía `_OS_LINUX_` |
| Configuración | `contrib-normalize_triplet.py.patch` (§4) | la capa que produce el triplet |
| Stdlib JLL | `stdlib-OpenBLAS_jll.jl.patch`, `stdlib-libblastrampoline_jll.jl.patch` | **no congelar rutas en la sysimage**: un `const` a nivel de módulo de un stdlib entra en `sys.so` con el prefijo de la máquina de build; todo se calcula dentro de `__init__()`. Y `dlpath()` no basta: en bionic respondía `NULL` para un handle cargado, dejando la ruta en `""` y matando a todo proceso en la init de BLAS |
| Stdlib JLL (carga tolerante) | `stdlib-CompilerSupportLibraries_jll.jl.patch`, `stdlib-LibUnwind_jll.jl.patch`, `stdlib-OpenLibm_jll.jl.patch` | el stub *dummy* de upstream hace `dlopen` **sin guarda** de librerías que este prefijo no tiene (`libgcc_s`/`libstdc++`/`libgomp`, `libunwind.so.8`, `libopenlibm.so.4`) y desreferencia un `VNorNothing` que responde `nothing`.  Los tres quedan opcionales: `return` si la carga responde `nothing`, con la centinela `nothing` (no `C_NULL`: `base/libdl.jl:119-125` contra `:160`).  Cada uno es un muro medido —`pkgimage.mk:28` abortaba el precompile— y el gate los nombra (`scripts/unguarded-dlopen.sh`, §3.3) |
| Contenido de deps | `patches/deps/termux-libuv-process-android.patch` (no hay `pthread_cancel`/`pthread_setcancelstate`), `patches/deps/termux-libwhich-dlinfo-android.patch` (rama `dlinfo` solo fuera de Android; `RTLD_NOLOAD` y saltar entradas sin `/` inicial, §3.1) | se instalans en `$SRCDIR/deps/patches/` desde `termux_step_pre_configure` (`build.sh:37-42`) porque `deps/Makefile` redefine `SRCDIR` a `deps/` |

`Makefile.patch` toca la regla `install:` de dos formas que hay que leer juntas:
quita `$(BUILDROOT)/doc/_build/html/en/index.html` de sus prerequisitos y pasa el
`cp -R -L $(BUILDROOT)/doc/_build/html $(DESTDIR)$(docdir)/` a `-cp`, tolerando
que el árbol no exista.  **Divergencia declarada respecto del paquete publicado
`julia 1.12.6-1`, que sí trae `share/doc/julia/html/`**: el `.deb` de este port no
lleva docs HTML.  El motivo no es estética del payload sino reproducibilidad —
`doc/Makefile:47 html:` ejecuta `doc/make.jl`, que instancia su entorno contra el
registro `General` (`Pkg` sin versiones fijadas) y por lo tanto necesita red en
**tiempo de instalación**, y `doc/Makefile:28-34 deps` baja `UnicodeData.txt` con
`$(JLDOWNLOAD)`.  Medido en 37891178350: dentro de bionic en este runner los hosts
que publican `AAAA` responden `Could not resolve host` (`pkg.julialang.org`,
`github.com`) y `make install` moría ahí, mientras el `curl` del mismo paso bajaba
UnicodeData.txt sin problema — el precedente del quirk ya está documentado en
`probe-ondevice-builder.yml:104` con `Acquire::ForceIPv4`.  Se descartó construir
los docs con IPv4 forzado (meter una dependencia de red y de versiones no fijadas
en el tramo que produce el artefacto) y se descartó `touch` del fichero stamp
(`install` también depende de ficheros recién construidos de `base/`, así que el
stamp falso volvía a correr la regla, y además empaquetaba un `index.html` vacío).
`make docs` sigue intacto para quien lo quiera correr a mano.

---

<a name="6"></a>
## 6. DAG, caché y presupuesto

### 6.1 El DAG

```
lint (Static gate, sin compilar)  ->  build (.deb)  ->  bundle (.pkg.tar.xz + tar.gz)  ->  publish (opt-in)
   ubuntu-24.04-arm, 40 min           ubuntu-24.04-arm, 300 min   ubuntu-24.04, 20 min       ubuntu-24.04, 15 min
```

- Nada caro empieza sin el gate: `build.needs: lint`. El gate está **dentro** del
  DAG (job `lint` sobre el mismo action) además de ser obligatorio localmente,
  porque el gate deriva conclusiones del prefijo real del runner: un gate solo
  local validaría contra un prefijo distinto del que compila.
- `lint` exporta `probe_libs` (`build-package.yml:50-51`) y `build` la consume
  (§3.5). Esta arista de datos es la razón por la que el gate y el build no
  pueden divergir en la lista de nombres.
- El disparador es `push` a `main` **filtrado por paths** (`packages/**`,
  `scripts/**`, `.github/actions/**`, `.github/scripts/**`, el workflow) y
  `workflow_dispatch` con el input `publish` (`build-package.yml:16-30`). El
  filtro existe porque un commit de documentación no debe gastar un run, y el
  dispatch existe porque publicar es una decisión aparte (§6.3).
- `publish` está condicionado a `workflow_dispatch` **y** `publish == 'true'`
  (`build-package.yml:545-547`); usa `github.event.inputs` en lugar de `inputs`
  porque el job también se evalúa en eventos `push`, donde los inputs no existen.

### 6.2 Caché: el contrato es sobre el artefacto, no sobre el árbol

```
julia-deb-v1-aarch64-<tp_sha>-<repo_stamp>-<hashFiles('packages/julia/**')>
                                                       (build-package.yml:218,439)
```

Los tres componentes son las tres cosas que cambian el binario resultante:

1. `tp_sha`: el commit de `termux-packages` clonado en `--depth 1`
   (`build-package.yml:189-191`). No se pinea: un bump del framework de build
   cambia el paquete.
2. `repo_stamp`: los primeros 16 hex del SHA-256 del índice `Packages` descargado
   por el action (`build-package.yml:199-202`). Cualquier librería movida en el
   repo de Termux cambia lo que se produce.
3. `hashFiles('packages/julia/**')`: la receta **y cada uno de sus 26 parches**.

Y el árbol de trabajo **deliberadamente no se cachea** (`build-package.yml:204-212`):
termux-packages borra `$TERMUX_PKG_SRCDIR` al empezar toda build
(`termux_step_setup_build_folders.sh:20`, alcanzado desde `termux_step_start_build`
porque solo `-c` lo salta), y con `-c` el empaquetado barrería solo los ficheros
más recientes que su nuevo timestamp. Cachear un árbol que el framework destruye
produce un artefacto deshonesto. Un artefacto reconstruido es el resultado
honesto; la caché de artefacto es lo que hace gratis repetir una receta sin
cambios.

Consecuencia económica: **tocar la receta o cualquier `*.patch` paga ~45-52 min de
reconstrucción** (`PROGRESS.md`). Mientras un run mide una hipótesis, `packages/**`
no se toca. Y `concurrency.group = <workflow>-<ref>` con
`cancel-in-progress: true` (`build-package.yml:35-37`) convierte un push en la
cancelación del run en curso.

### 6.3 Publicación

Un build verde **no publica nada ni mueve ningún puntero**. La release `julia-latest`
se destruye y se recrea (`build-package.yml:581-587`), así que publicar un artefacto
sin verificación en dispositivo sería publicar una mentira: la nota que genera el
propio job dice en claro que un run verde significa "build e inspección", no
"funciona en un teléfono" (`build-package.yml:578-579`).

### 6.4 Paso de informe: reportar nunca es sentenciar

El paso `Where the time went` (`build-package.yml:441-469`) empieza con `set +e`.
No es decorativo: fue la causa de un job rojo (run 37784767638) por un `du` sobre
un directorio que el build fallido nunca creó. La regla general del repo: los
reportes van con `|| true` o con guardas; **solo las aserciones pueden fallar**.
Análogamente, `Inspect the artifact` informa también lo que no es un fallo duro
(`WARN libLLVM-18jl.so not in the package`) porque una build que enlace LLVM
estáticamente no es una regresión.

---

<a name="7"></a>
## 7. Artefactos y su inspección

Salida **triple**, porque el usuario gestiona Termux con pacman (`repo.json`
declara `pkg_format: pacman`):

- `.deb` — lo produce `build-package.sh --format debian` en el job `build`; es el
  artefacto que se cachea (`output/julia_*_aarch64.deb`).
- `.pkg.tar.xz` — lo deriva el job `bundle` con `scripts/make-pacman-pkg.sh` **a
  partir del `.deb`**, no de un árbol de build: así es imposible que los dos
  formatos contengan bytes distintos, y la lista de dependencias se lee del member
  `control` del `.deb`, o sea, de la receta (`make-pacman-pkg.sh:1-13`, replicando
  el layout de `termux_step_create_pacman_package.sh`).
- `julia-termux-aarch64.tar.gz` + `SHA256SUMS.txt` — el paquete descargable.

La coherencia se comprueba, no se afirma (`build-package.yml:520-534`): `sha256sum
-c` y un `diff` de las listas de ficheros del `.deb` desmontado contra las del
`.pkg.tar.xz`, excluyendo los metadatos de pacman (`.PKGINFO`, `.BUILDINFO`,
`.MTREE`).

**Inspección del `.deb`** (`build-package.yml:331-433`), con su motivo:

| Comprobación | Por qué |
|---|---|
| presencia de `bin/julia`, `lib/julia/sys.so`, `lib/julia/libblastrampoline.so*` | una julia sin sysimage o sin codegen **instala limpio y luego no corre**; la receta ya lo exige en `termux_step_post_make_install` (`build.sh:223-227`) |
| nada fuera del footprint de Julia | la otra mitad de `termux_step_pre_massage` (§1.5) |
| `readelf -d` exige `RUNPATH` y rechaza `DT_TEXTREL` | sin `RUNPATH` los stdlibs no encuentran `$PREFIX/lib/julia`; Android **rechaza** `DT_TEXTREL` (por eso `cli-Makefile.patch` quita `-Wl,-z,notext`… y por eso hace falta el `--whole-archive` de compiler-rt). La salida se **captura** antes de decidir (§3.0, invariante 4) |
| `NEEDED` de `libjulia-codegen.so` y rechazo explícito de `libLLVM-21` | demuestra que el LLVM es el bundled de Julia, no el de Termux (§1.4); capturado, no tubería |
| `readelf -V` del symver `JL_LLVM_18.1` | si falta, las referencias versionadas de codegen no resuelven en tiempo de carga. `readelf -V` imprime ~35 000 líneas: **es exactamente el productor que no puede ir por tubería a un `grep -q`** (§3.0) |
| `du` del payload y recuento de `*.so*` | presupuesto y señal de contaminación del prefijo |

El `build.log` se sube siempre (`if: always()`), con el filtro del ruido
`linkerconfig|ld.config.txt` aplicado, y la summary del job extrae los primeros
errores y las últimas 60 líneas: la fuente de verdad de un run sigue siendo
`gh run view <id> --json status,conclusion` (`PROGRESS.md` "Notas": `gh run watch`
devolvió 0 en runs fallidos).

---

<a name="8"></a>
## 8. Verificación en el dispositivo

**"Compila" no es "funciona"**, y la diferencia no es retórica: hasta el minuto 49
el build compila y la sysimage aborta. La definición de hecho vive en
`scripts/device-smoke.sh`, que se corre **en el teléfono y nunca en CI**: CI
construye, el dispositivo prueba (`device-smoke.sh:1-5`).

Estructura y por qué:

- Guarda de espacio (600 MB libres en `$PREFIX`, `:45-49`) antes de tocar nada, y
  `JULIA_DEPOT_PATH`/`JULIA_COMPILED_CACHE_PATH`/`TMPDIR` apuntando a un workdir
  desechable (`:51-54`): la smoke no puede ensuciar ni depender del depot real.
- Verifica `SHA256SUMS` si el bundle los trae (`:73-80`).
- Instala con `pacman -U` si hay `.pkg.tar.xz`, si no `dpkg -i`, y en ese caso
  ordenando inversamente para que `llvm-julia` aterrice antes de `julia` si la
  receta llegara a partirse (`:94-103`) — es decir, instala en el formato que el
  dispositivo use realmente, que es exactamente por qué la salida es triple.
- Cada aserción es un proceso `julia --startup=no` con `timeout` (`:112-124`) y
  **stdout/stderr capturados por aserción**; un FAIL imprime 15 líneas. No hay
  aserción "el paquete está instalado".
- Las aserciones escogen los mecanismos que el port toca: `dlpath_regression`
  pide exactamente `"libgmp.so.10"`/`"libmpfr.so.6"`/`"libblastrampoline.so.5"`
  y exige que `dlpath` devuelva una ruta existente (`:128-139`) — es la prueba en
  dispositivo de §3.7 y del `jl_pathname_for_handle` de `src-sys.c.patch`;
  `pcre_jit` ejercita SLJIT escribiendo en memoria ejecutable, que es lo que
  rompen los entornos emulados (`:214-229`); `gemm_threads` y `threads_spawn`
  cubren BLAS y las tasks de aarch64; `codegen_llvm` emite IR, o sea usa
  `libjulia-codegen` y su LLVM 18 (§1.4); `libgit2`/`suitesparse`/`arpack`/`fft`
  cubren los deps de sistema cuyos nombres revisa §3.3.
- Con `--network` añade la batería de `Pkg` (add/instantiate/download, MbedTLS);
  con `--runtests` corre subconjuntos de la suite propia de Julia (`linalg
  sparsearrays libdl sockets errors` por defecto) **a través de `tcr`**, que es el
  envoltorio de límites de CPU/memoria del dispositivo (`:272-299`).
- `scripts/device-diag.sh` es el hermano read-mostly: diagnostica el `julia`
  **ya instalado** sin reinstalar nada, con las mismas aserciones básicas y los
  mismos `dlpath` de nombres versionados (`device-diag.sh:99-111`). Es la
  herramienta para distinguir "este paquete no funciona" de "me falta algo en el
  entorno".

Nada de esto está todavía ejecutado: la Fase 5 de `PROGRESS.md` está **pendiente**
porque no existe artefacto que instalar (§9).

---

<a name="9"></a>
## 9. Límites conocidos y estado honesto (2026-10-09)

Copiado de `PROGRESS.md`, sin relajar:

- La cadena está medida hasta el **final de `make install`**. Compilan y están
  validados en CI: la receta y sus 26 parches, el `configure` con un `Make.user`
  que `Make.inc` acepta, los gates, el entorno del runner, LLVM 18.1.7-4 bundled,
  `src/`, flisp, `julia-base` con sus 19 symlinks derivados, el arranque de
  `julia`, el bootstrap de la sysimage entero (`sysbase-o.a` y `sys-o.a` se emiten,
  37876520515), el precompile de las stdlibs de `pkgimage.mk:28`
  (`stdlib/release.image` con `✓ Pkg`, sin `Failed to precompile` ni `FieldError`
  ni `dlpath(::Nothing)`, 37891178350) y —`37904805726`— `make -j1 install` por
  completo: el bucle de libs privadas, el patchelf de `libjulia-internal.so`,
  `libjulia-codegen.so` y `libLLVM.so`, y el `stringreplace` de
  `libjulia.so.1.12.6`.  Ese run **no** falló en Julia: falló cinco segundos
  después, en la aserción del symver de la receta, falsa por decidir por tubería
  (§3.0, invariante 4).
- **No hay ningún `.deb` o `.pkg.tar.xz` producido.** Consecuencia: `bundle` y
  `publish` quedan `skipped` mientras no exista artefacto, y la Fase 5
  (verificación en dispositivo) está pendiente.
- Sin demostrar: el tramo que ningún run ha recorrido —la creación del `.deb`
  (empaquetado a partir del prefijo copiado) y el paso `Inspect the artifact`—,
  ya que `install` y sus `stringreplace` sí se recorrieron en `37904805726`.
- Divergencia aceptada: el `.deb` no trae docs HTML, a diferencia del paquete
  publicado, porque `install` no debe depender de la red (§5.2).
- Riesgo residual **confirmado donde se predijo**: el muro siguiente estaba en los
  hooks propios del empaquetado, no en Julia —`termux_step_post_make_install` abortó
  con un `ERROR` propio sobre un artefacto correcto—.  Como `packages/**` y
  `scripts/**` cambian, la clave de caché no hita y el run vuelve a pagar la
  compilación completa.

Candidatos del tramo siguiente, ya medidos y descartados/afirmados
(`PROGRESS.md` "Tramo siguiente"):

> Los dos candidatos que hablaban de `sys-o.a` ya no son predicción: con
> `37876520515` la imagen se emite y con `37891178350` el precompile de las
> stdlibs pasa.  `CompilerSupportLibraries_jll` **sí** abortaba el tramo (el
> `FieldError` de `libgfortran_version(...).major` sobre `nothing`) y se arregló
> en la capa productora; el `--cpu-target=native` interno de
> `generate_precompile.jl:360` no produjo ni `SIGILL` ni `Illegal instruction` en
> el runner.  Quedan aquí como están escritos porque son la evidencia de *por qué*
> cada uno se cerró así, y el segundo sigue siendo riesgo real **para el
> dispositivo**: los `.ji` llevan machine code de la CPU del runner.

- **`RTLD_DEEPBIND` no rompe nada.** `contrib/generate_precompile.jl:231` hace
  `dlopen("libjulia", RTLD_LAZY | RTLD_DEEPBIND)` y `base/libdl.jl:30` define
  `RTLD_DEEPBIND = 0x40` como constante escrita a mano, así que parecía un abort
  seguro. Pero `src/dlload.c:210` envuelve la bandera en `#if defined(RTLD_DEEPBIND)`
  y bionic **no** la define (probe con `#ifdef`: `RTLD_NODELETE` sí;
  `RTLD_DEEPBIND`/`RTLD_FIRST` no), así que `jl_dlopen` la descarta y
  `default_rtld_flags` (`base/libdl.jl:49`) es inofensivo. La falla solo aparece
  llamando a la libc directamente.
- **Las stdlibs externas ya se bajaron bien.** 15 de las 66 entradas de `stdlib/`
  son ficheros `*.version` que `deps/tools/stdlib-external.mk` descarga de
  `api.github.com`. En 37841320064 el log no tiene una línea de `Pkg` (GitHub
  omitió la ventana), pero `Makefile:113` hace `julia-stdlib` prerequisito de
  `julia-sysimg-release` y el recipe de ese target fue el que corrió `sysimage.mk`:
  la descarga terminó. El límite de tasa anónimo **no** es un bloqueo observado.
- **El runtime GNU no existe en el prefijo; `CompilerSupportLibraries_jll` es el
  candidato nombrado para `sys-o.a`.** Medido en el teléfono: no hay `libgcc_s*`,
  `libgfortran*`, `libstdc++*`, `libgomp*` ni `libssp*` en `$PREFIX/lib` ni en
  `$PREFIX/lib/julia` (Termux usa clang + libc++), y
  `stdlib/CompilerSupportLibraries_jll/src/…:57-64` los dlopen **con throw**. Sus
  únicas aristas de dependencia son `OpenBLAS_jll` y `p7zip_jll`, y el propio
  `OpenBLAS_jll` upstream tiene comentado el `using CompilerSupportLibraries_jll`
  (nuestro `stdlib-OpenBLAS_jll.jl.patch` ya salta el `dlopen(_libgfortran)`).
  instantiate ≠ init: un módulo congelado en la imagen no ejecuta `__init__` si
  nadie lo carga, así que **no está demostrado como bloqueo**. Si `sys-o.a` muere
  con `could not load library "libgcc_s.so.1"`, el parche es ese archivo (o bajar
  `JULIA_PRECOMPILE` a 0), **no otro alias**.
- **`--cpu-target=native` literal dentro del precompile, sin evidencia de fallo.**
  Medido sobre el tarball pineado hay **dos** invocaciones y solo una controlable:
  la externa (`sysimage.mk:118`, `-C "$(JULIA_CPU_TARGET)"`, que la receta fija en
  `generic` en `build.sh:80`) y la interna — `contrib/generate_precompile.jl:360`
  spawnea `$(julia_exepath()) -O0 --trace-compile=… --cpu-target=native` para
  precompilar cada paquete, con **native como literal**; `JULIA_CPU_TARGET` no
  aparece en el script (buscado) y ningún parche de la receta toca esa línea. El
  machine code de los `.ji` se genera entonces para la CPU del runner, no para la
  del teléfono. Como no hay todavía un log que lo señale, no se parchea: si
  `sys-o.a` muere con `Illegal instruction`/`SIGILL`, o si la imagen arranca en el
  runner y revienta en el dispositivo, el fix es esa línea 360 (regla de capa: el
  valor se produce ahí), no una bandera más en la receta.
- Los 8 alias se crean ahora **antes** de `make`, porque cada etapa de precompile
  abre un `julia` nuevo y los `_jll` del árbol vendido piden `libcurl.so.4`,
  `libgit2.so.1.9`, `libssh2.so.1`, `libnghttp2.so.14`, `libgmpxx.so.4`,
  `libpcre2-8.so.0`. **Dónde** se crean no es simétrico entre los dos árboles, y
  es medible: en el de build el objeto que emite el `dlopen` vive en `usr/lib` con
  `RUNPATH $ORIGIN` (por eso `usr/lib/julia`, donde `base/Makefile` enlaza sus 19
  nombres, no lo resuelve — run 37862103015); en el instalado `make install` lo
  mueve y le fija `RUNPATH $ORIGIN:$ORIGIN/..`, así que allí `$PREFIX/lib/julia`
  sí está en la búsqueda. Verificado en un `julia` ya instalado en el teléfono:
  `readelf -d $PREFIX/lib/julia/libjulia-internal.so` → `RUNPATH
  [$ORIGIN:$ORIGIN/..]`, mientras `bin/julia` lleva `$ORIGIN/../lib` y
  `$ORIGIN/../lib/julia` — que no se consultan, porque con `--enable-new-dtags`
  el RUNPATH del ejecutable no cubre el `dlopen` que hace una librería.

Límites estructurales que no van a desaparecer:

- Los runners no son Android: `/system` es un asset y `libtermux-exec` aliasa
  FHS. Cualquier herramienta nueva que el build invoque tiene que cumplir las dos
  reglas de §2 (ruta no aliasada **y** sin `LD_PRELOAD`).
- La línea de tiempo de termux-packages no es fixeada: el job clona `--depth 1`
  del HEAD y su sha entra en la clave de caché; una regresión upstream se manifiesta
  como misses de caché completos y un run de ~45-52 min. Los números de línea de
  termux-packages citados aquí son del clon actual del repo upstream.
- La rama `ci/probe-rootfs` es un asset del build: borrarla rompe todos los jobs
  que usan el action.
- El teléfono no compila Julia: solo baixa, instala y prueba.

---

<a name="10"></a>
## 10. Restos de la ruta abandonada

Los ficheros del builder Docker de la ruta cross **ya no están en el árbol**:
`scripts/Dockerfile`, `scripts/run-docker.sh`, `scripts/build-deps-docker.sh`,
`scripts/setup-ccache-docker.sh`, `scripts/patch-fuse-overlayfs.sh` y
`scripts/build-local.sh` se borraron el 2026-10-09 (ninguno los referenciaba;
verificado con grep antes de borrar). Queda lo que sí sigue viviendo:

| Fichero | Estado |
|---|---|
| `scripts/install-deps.sh` | instala deps a mano con patrones HTTP de la época cross; `device-smoke.sh:56-57` reserva su ruta pero **no la invoca** |
| `.github/actions/zram/` | swap comprimido del runner; en uso desde 2026-10-09 como red de memoria del job `build`, con `continue-on-error` para que nunca cueste el build |
| `ndk-patches/29/` | directorio vacío del NDK cross |
| `tasks/`, `trace-dl/` | notas y trazas de sesiones anteriores |

`scripts/build-local.sh` no se echa de menos: hacía compilar Julia en el teléfono,
que es exactamente lo que prohíbe `AGENTS.md` (el teléfono baixa, instala y prueba).

El vocabulario prohibido —`XC_HOST`, `HOSTCC`, `BUILDING_HOST_TOOLS`, `--host`,
`host-flisp`— no solo está desaconsejado: el gate lo **rechaza** si aparece en el
`Make.user` generado (`rehearse-recipe.sh:304-310`).

---

## 11. Dónde mirar

| Quiero saber… | Archivo |
|---|---|
| qué falló, en qué minuto, qué gate lo cerró, qué queda | `PROGRESS.md` |
| reglas operativas, presupuesto, qué está prohibido | `AGENTS.md` |
| la receta y sus flags reales | `packages/julia/build.sh` |
| el DAG real (lint → build → bundle → publish) | `.github/workflows/build-package.yml` |
| cómo se materializa el prefijo en el runner | `.github/actions/termux-builder/action.yml` |
| el gate local completo | `scripts/rehearse-recipe.sh` |
| derivación de sonames / triplet / alias versionados / directorio buscado por el loader / guardas de `dlopen` | `scripts/symlinked-libraries.sh`, `scripts/embedded-triplet.sh`, `packages/julia/soname-aliases.sh`, `scripts/unguarded-dlopen.sh`, `scripts/runtime-library-dir.sh` |
| la sonda del loader por etapas | `scripts/probe-library-resolution.sh` |
| la closure del prefijo | `.github/scripts/termux-closure-resolver.py` |
| cómo se prueba que funciona | `scripts/device-smoke.sh`, `scripts/device-diag.sh` |
| las tres sondas que legitimaron host == target | `.github/workflows/probe-*.yml` |
