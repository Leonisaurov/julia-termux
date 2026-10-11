# Plan: plataforma bionic de punta a punta (patch de `Artifacts`, rebuild y publicación)

**Goal:** que un julia cuyo `HostPlatform()` reporta `libc="bionic"` consuma los JLLs sin que nadie
escriba a mano un `Overrides.toml`, con el artefacto equivocado imposible de colar: `Pkg.add("FFTW")`
y los 37 overrides en verde, y recién ahí publicar el paquete que ya está construido.

**Arquitectura:** el port tiene tres piezas. (1) El patch de plataforma en `Base.BinaryPlatforms`
(hecho, construido, **sin publicar**) hace que el host sea *verdadero*: bionic. (2) El fork de
`JLLWrappers` 1.8.2 (hecho, publicado en `TermuxRegistry`) hace que un host bionic elija el wrapper
`-gnu`, que es agnóstico de la plataforma. (3) **Falta** que `Artifacts` encuentre la entrada del
artefacto para bionic: hoy no matchea ninguna y el JLL muere *antes* de elegir wrapper. El patch de
(3) cae a la entrada `-gnu` del mismo `arch`/`os` **sólo si ese hash está overridden** — fail-closed:
sin override declarado, el error fuerte de hoy, que es lo seguro.

**Tech Stack:** Julia 1.12.6, Termux/bionic aarch64, el build de `julia-termux` (CI en runner arm64),
`Artifacts`/`Base.BinaryPlatforms` como stdlibs dentro del sysimage, el registro propio
`Leonisaurov/TermuxRegistry`.

---

## 0. Estado y evidencia ya medida (no re-descubrir nada de esto)

| Pieza | Estado | Evidencia |
| --- | --- | --- |
| `HostPlatform()` = bionic | construido, **sin publicar** | corrida 38168561427; `Base.BUILD_TRIPLET = aarch64-linux-android-cxx11` |
| `JLLWrappers` 1.8.2 (fork) | publicado y verificado | `Leonisaurov/JLLWrappers.jl`, árbol `cce6644f9d7c7ecddd9249abe7fbbfa326702295`; un env limpio resuelve 1.8.2 |
| Registro propio | publicado y verificado | `Leonisaurov/TermuxRegistry`; `Pkg.Registry.add(url=…)` |
| `Artifacts` con bionic | **falta** | error exacto abajo |

Con host bionic y el registro puesto, el fallo es:

```
Cannot locate artifact 'FFTW' for aarch64-linux-android-cxx11-julia_version+1.12.6
in '.../FFTW_jll/CnY1I/Artifacts.toml'
```

- Sale de `artifact_slash_lookup` → `artifact_meta(name, dict, toml; platform)` →
  `select_platform(dl_dict, platform)` devuelve `nothing` porque ninguna entrada matchea bionic.
- **El override uuid+name no puede salvarlo**: `Artifacts.process_overrides` traduce ese override a
  overrides **por hash**, y para eso primero hay que haber encontrado una entrada y su hash.
- El fallback del wrapper tampoco llega: el artefacto se resuelve **antes**.
- Con el host en glibc (estado actual del dispositivo y de `julia-latest`) todo esto da **37/37**,
  porque la entrada `-gnu` matchea directo y el override por hash redirige al artefacto del port.

**Archivos y líneas de referencia (v1.12.6):**
- `stdlib/Artifacts/src/Artifacts.jl:401-420` — `artifact_meta`, el punto de inserción (la línea
  `meta = select_platform(dl_dict, platform)` está en la 415).
- `stdlib/Artifacts/src/Artifacts.jl:206` — `query_override(hash)`; `:210` — `query_override(pkg_uuid, name)`.
- `stdlib/Artifacts/src/Artifacts.jl:12-13` — imports: `AbstractPlatform, Platform, HostPlatform` y
  `tags, triplet, select_platform`. **`libc` NO está importado**: el patch usa `tags(platform)`, que sí lo está.
- `stdlib/Pkg` es submódulo (el tarball trae sólo `Pkg.version`), **`stdlib/Artifacts` no**:
  es un directorio normal, así que el patch es un `*.patch` común al lado de la receta y lo aplica
  `termux_step_patch_package()` **antes** de configure, o sea que entra al sysimage.

---

## 1. La decisión de diseño (y por qué fail-closed)

Sin el patch, un host bionic no puede resolver artefactos: error duro. Con un fallback *ciego* a la
entrada gnu, un JLL sin override bajaría el artefacto **glibc** y fallaría en el `dlopen` (o peor).
Con el fallback **condicionado a que el hash esté en `Overrides.toml`**, la única forma de que un
artefacto glibc entre es que el port lo haya declarado, y en ese caso el override lo redirige a su
propio artefacto bionic. Es la misma palanca que el fallback del wrapper y la misma filosofía del
resto del port: **el default es fallar ruidosamente**.

---

## Tarea 0 — Medir qué forma del override está visible en ese punto

**Objetivo:** saber si en `artifact_meta` alcanza con `query_override(hash)` o hace falta además la
forma uuid+name. `process_overrides` sólo corre si quien cargó el `Artifacts.toml` pasó `pkg_uuid`;
si el camino de `@artifact_str` no lo pasa, `overrides[:hash]` no tendrá el hash y la guarda
fail-closed rechazaría todo. **Esta tarea decide la condición del patch.**

**Archivos:** ninguno (medición).

**Paso 1:** con el dispositivo en el estado actual (glibc, JLLs instalados), correr:

```bash
JULIA_PROJECT="$TMPDIR/fftw-env.ZTHRoQ" julia --startup-file=no -e '
using FFTW_jll, Artifacts, Base.BinaryPlatforms
u = Base.UUID("f5851436-0d7a-5f13-b9de-f02708fd171a")   # FFTW_jll
toml = joinpath(pkgdir(FFTW_jll), "Artifacts.toml")
d = Artifacts.load_artifacts_toml(toml; pkg_uuid = u)
gnu = nothing
for e in d["FFTW"]
    get(Base.BinaryPlatforms.tags(Base.BinaryPlatforms.Platform(e)), "libc", nothing) == "glibc" && (gnu = e)
end
h = Artifacts.SHA1(gnu["git-tree-sha1"])
ov = Artifacts.load_overrides()
println("hash override visible  : ", haskey(ov[:hash], h))
println("uuid override visible  : ", haskey(ov[:UUID], u) && haskey(ov[:UUID][u], "FFTW"))
println("query_override(hash)   : ", repr(Artifacts.query_override(h)))
'
```

**Esperado:** `hash override visible : true` y `query_override(hash)` devolviendo la ruta del
artefacto del port. Si sale `false`, la condición del patch tiene que consultar también
`query_override(pkg_uuid, name)` — y entonces el patch se mueve al `artifact_meta` de 2 argumentos
(el que tiene `pkg_uuid`).

**Paso 2:** anotar el resultado en `PROGRESS.md` antes de escribir el patch.

---

## Tarea 1 — Escribir el patch de `Artifacts`

**Objetivo:** que `artifact_meta` caiga a la entrada gnu del mismo `arch`/`os` sólo si ese hash está
overridden.

**Archivos:**
- Crear: `packages/julia/stdlib-Artifacts-src-Artifacts.jl.patch`

**Paso 1 — generar el patch editando el archivo real y diffeando (no escribirlo a mano).** La
lección del patch de plataforma: un patch escrito a mano aplicó con *fuzz* y descartó una hunk en
silencio.

```bash
W="$TMPDIR/apatch"; rm -rf "$W"; mkdir -p "$W/a/stdlib/Artifacts/src" "$W/b/stdlib/Artifacts/src"
S="$PREFIX/share/julia/stdlib/v1.12/Artifacts/src/Artifacts.jl"   # upstream, sin parchear
cp "$S" "$W/a/stdlib/Artifacts/src/Artifacts.jl"
cp "$S" "$W/b/stdlib/Artifacts/src/Artifacts.jl"
```

**Paso 2 — editar `$W/b/stdlib/Artifacts/src/Artifacts.jl`**: insertar después de
`meta = select_platform(dl_dict, platform)` (línea 415) y antes de `# If it's NOT a dict, complain`:

```julia
        # Termux/bionic port: no entry matches a host that reports libc="bionic" (the JLLs in
        # the General registry ship -gnu and -musl only) and select_platform disqualifies a
        # different libc, so this returned nothing and the JLL died before it could even choose
        # a wrapper ("Cannot locate artifact 'FFTW' for aarch64-linux-android-cxx11-...").
        #
        # Fall back to the entry for the same arch and os with libc="glibc" - but only when that
        # entry's hash is overridden in Overrides.toml.  That keeps it fail-closed: without an
        # override the glibc artifact cannot be selected, downloaded or loaded by accident, and
        # the loud error above stays.  With an override, Artifacts.artifact_path redirects the
        # hash to the artifact this port built or to the library Termux already ships.
        if meta === nothing && get(tags(platform), "libc", nothing) == "bionic"
            glibc_platform = deepcopy(platform)
            glibc_platform["libc"] = "glibc"
            glibc_meta = select_platform(dl_dict, glibc_platform)
            if glibc_meta !== nothing &&
               query_override(SHA1(glibc_meta["git-tree-sha1"]::String)) !== nothing
                meta = glibc_meta
            end
        end
```

Notas: `tags` y `select_platform` ya están importados; `SHA1` viene de `Base` (`import Base: get,
SHA1`); `query_override` está definido arriba en el mismo archivo. **No** hace falta tocar los imports.

**Paso 3 — generar y verificar.** Los directorios se llaman `a` y `b` a propósito: `diff -ru a b`
emite `--- a/stdlib/…` y `+++ b/stdlib/…`, que es exactamente lo que espera `patch -p1`.

```bash
Y=/data/data/com.termux/files/home/Develop/Patch/Julia/julia-termux
cd "$W" && diff -ru a b > "$Y/packages/julia/stdlib-Artifacts-src-Artifacts.jl.patch"
head -4 "$Y/packages/julia/stdlib-Artifacts-src-Artifacts.jl.patch"
```

**Esperado:** las dos primeras líneas son `--- a/stdlib/Artifacts/src/Artifacts.jl` y
`+++ b/stdlib/Artifacts/src/Artifacts.jl`, y hay **una sola** hunk (`@@ …`).

La verificación de verdad no es el `diff`, es la guarda del repo, que replica
`termux_step_patch_package()` (misma selección maxdepth 1, mismo `patch -p1`, y **nombra** el patch
que falla en vez de dejar un `.rej` silencioso):

```bash
cd "$Y" && bash scripts/rehearse-recipe.sh
```

**Esperado:** el reporte del *patch stage* nombra `stdlib-Artifacts-src-Artifacts.jl.patch` sin
`.rej` ni fallo. `scripts/rehearse-recipe.sh` ya recorre los `*.patch` con la misma selección
(maxdepth 1) y el mismo `patch -p1`, así que un patch que no aplique no llega a CI.

**Paso 4 — commit:**

```bash
git add packages/julia/stdlib-Artifacts-src-Artifacts.jl.patch
git commit -m "fix(artifacts): fall back to the -gnu artifact entry on a bionic host, fail-closed"
```

---

## Tarea 2 — Prueba local de la tabla de decisión (antes de gastar el rebuild)

**Objetivo:** verificar las llamadas riesgosas del patch (`deepcopy` + `setindex!` sobre un
`Platform`, que `select_platform` con la plataforma glibc elija la entrada gnu, y que
`query_override(hash)` vea el override) usando las funciones **reales** de la stdlib y un fixture.

**Archivos:**
- Crear: `scripts/probe-artifacts-bionic.jl`

**Paso 1 — el fixture.** Un `Artifacts.toml` con dos entradas (gnu y musl) para el mismo arch/os,
y dos depots: uno con el `Overrides.toml` del hash gnu y otro sin él.

**Paso 2 — el script** (llama a `select_platform`, `query_override` y `load_artifacts_toml` reales;
la única lógica propia son las 6 líneas del fallback, que en el rebuild se ejercitan *de verdad*
vía la Tarea 4):

```
caso 1  host bionic, override presente   -> elige la entrada gnu
caso 2  host bionic, override ausente    -> nothing   (fail-closed)
caso 3  host glibc,  override presente   -> elige la entrada gnu (camino de hoy, sin cambios)
caso 4  host bionic, entrada bionic real -> la elige (no toca el fallback)
```

**Paso 3 — correr:**

```bash
julia --startup-file=no scripts/probe-artifacts-bionic.jl
```

**Esperado:** `4/4` y rc=0. Si el caso 1 falla por `setindex!` no soportado, usar
`Platform(arch(platform), os(platform), Dict{String,Any}("libc" => "glibc"))` y anotarlo.

**Paso 4 — commit.**

---

## Tarea 3 — Rebuild en CI, sin publicar

**Objetivo:** construir el paquete con el patch y dejarlo como artefacto de la corrida.

**Paso 1 — la guarda estática completa, local, antes de dispatchar:**

```bash
for f in scripts/*.sh packages/*/*.sh; do bash -n "$f" || echo "FAIL $f"; done
bash scripts/lint-workflows.sh
bash scripts/rehearse-recipe.sh
```

**Esperado:** todo OK. (Ojo: el lint de CI corre `shellcheck -S error` y la guarda local no lo hacía:
una asignación con sintaxis de Makefile pasó local y murió en CI, corrida 38167513434.)

**Paso 2 — dispatch sin publicar** (el default es `publish=false`, y una corrida verde no es una
razón para mover la release):

```bash
gh workflow run build-package.yml -R Leonisaurov/julia-termux
gita notify build-package.yml        # bloquea hasta terminar; nunca `gh run view` en loop
```

**Esperado:** ~80 min, `build rc=0`, artefactos `julia-deb` y `julia-termux-bundle` en la corrida.

**Paso 3 — anotar el número de corrida en `PROGRESS.md`.**

---

## Tarea 4 — Verificación en el dispositivo

**Objetivo:** probar la pieza nueva donde importa, con la guarda que impide el falso positivo.

**Archivos:** ninguno (verificación). Se usan `tools/validate-overrides.jl` y los envs
`$TMPDIR/{fftw-env.*,sqlite-env,stack-env}` de `Yggdrasil-termux`.

**Paso 1 — bajar los dos paquetes y anotar sus sha256** (la vez pasada un glob que no matcheó hizo
correr la prueba contra el paquete viejo y un `rc=0` mentiroso; `gh release download` **no
sobrescribe** sin `--clobber`):

```bash
K="$TMPDIR/pkgs"; rm -rf "$K"; mkdir -p "$K/working" "$K/bionic"
gh release download julia-latest -R Leonisaurov/julia-termux -p 'julia-1.12.6-0-aarch64.pkg.tar.xz' -D "$K/working"
gh run download <RUN_ID> -R Leonisaurov/julia-termux -n julia-termux-bundle -D "$K/bionic"
find "$K" -name '*.pkg.tar.xz' | while read -r f; do echo "$(sha256sum "$f" | cut -c1-16) $(stat -c %s "$f") $f"; done
```

**Paso 2 — instalar el nuevo y **guardar** sobre el `libc`** (sin esto, cualquier resultado es humo):

```bash
PKG=$(find "$K/bionic" -name '*.pkg.tar.xz' | head -1)
pacman -U --noconfirm "$PKG"
LIBC=$(julia --startup-file=no -e 'using Base.BinaryPlatforms; print(Base.BinaryPlatforms.HostPlatform().tags["libc"])')
[ "$LIBC" = bionic ] || { echo "ABORTADO: no se aplicó la instalación"; exit 1; }
```

**Paso 3 — la tabla de decisión contra la función real** (mismo script de la Tarea 2, ahora sin
mirror: `Artifacts.artifact_meta` del sysimage parcheado, con `platform=` bionic explícito y con el
`Overrides.toml` real del port): casos 1-4 en verde.

**Paso 4 — la evidencia directa del wrapper:**

```bash
JULIA_PROJECT="$TMPDIR/probe" julia --startup-file=no -e '
using Pkg; Pkg.add("FFTW_jll"; io=devnull)
using FFTW_jll, JLLWrappers
println("JLLWrappers   = ", pkgversion(JLLWrappers))
println("best_wrapper  = ", FFTW_jll.best_wrapper)
println("libfftw3_path = ", isdefined(FFTW_jll, :libfftw3_path) ? FFTW_jll.libfftw3_path : "NO DEFINIDO")
println("is_available  = ", FFTW_jll.is_available())'
```

**Esperado:** `JLLWrappers = 1.8.2`, `best_wrapper = .../wrappers/aarch64-linux-gnu.jl`,
`libfftw3_path = /data/data/com.termux/files/home/.local/opt/fftw-bionic/lib/libfftw3.so`,
`is_available = true`.

**Paso 5 — los 37 y los consumidores:**

```bash
cd /data/data/com.termux/files/home/Develop/Patch/Yggdrasil-termux
julia tools/validate-overrides.jl --list tools/jlls-overrides.txt     # esperado: validated: 37 / 37
for e in "$TMPDIR/fftw-env.ZTHRoQ" "$TMPDIR/sqlite-env" "$TMPDIR/stack-env"; do
  JULIA_PROJECT="$e" julia --startup-file=no -e 'using Pkg; Pkg.update("JLLWrappers"; io=devnull)' >/dev/null
done
# FFTW (fft/ifft true), SQLite (INSERT parametrizado + SELECT -> [42]), EzXML (42), Cairo (carga)
```

**Paso 6 — si algo falla:** volver al paquete publicado y decirlo.

```bash
pacman -U --noconfirm "$K/working"/*.pkg.tar.xz
julia --startup-file=no -e 'using Base.BinaryPlatforms; println(Base.BinaryPlatforms.HostPlatform())'
```

---

## Tarea 5 — Publicar y verificar desde la release

**Objetivo:** mover `julia-latest` sólo después de la verificación, y comprobar que lo publicado es
lo verificado.

**Paso 1:** `gh workflow run build-package.yml -f publish=true` + `gita notify build-package.yml`
(~80 min).

**Paso 2:** bajar el `.pkg.tar.xz` de la release con `--clobber` a un directorio limpio, instalar y
repetir los pasos 2-5 de la Tarea 4 **contra lo publicado** (no contra el artefacto de la corrida).

**Paso 3:** `git tag`/anotar la corrida que publicó en `PROGRESS.md`.

---

## Tarea 6 — Documentación y cierre

- `docs/13-distribucion-y-consumo.md`: §13.9 pasa de "falta" a "hecho", con la evidencia del
  dispositivo; el consumo queda en dos líneas (`Pkg.Registry.add(url=…)` y nada más).
- `docs/12-diseno-plataforma-bionic.md`: la tabla de las tres piezas, cerrada.
- `docs/15-mapa-de-jlls.md`: §15.7.4 con la medición de `Artifacts` (mismo formato que §15.7.1-3).
- `AGENTS.md` de Yggdrasil: el pitfall nuevo (el artefacto se resuelve antes que el wrapper, y el
  override uuid+name se aplica después de esa búsqueda).
- `PROGRESS.md` de los dos repos, y la fila de `PORTS.md` si cambia algún comando rápido.

---

## Archivos que cambian

| Archivo | Qué |
| --- | --- |
| `packages/julia/stdlib-Artifacts-src-Artifacts.jl.patch` | nuevo (Tarea 1) |
| `scripts/probe-artifacts-bionic.jl` | nuevo (Tarea 2) |
| `PROGRESS.md` | corridas, mediciones, publicación |
| `PLAN-plataforma-bionic.md` | este archivo: marcar tareas al cerrarlas |
| `../Yggdrasil-termux/docs/{12,13,15}`, `AGENTS.md`, `PROGRESS.md` | Tarea 6 |

## Verificación (resumen)

| Qué | Comando | Esperado |
| --- | --- | --- |
| El patch aplica | `bash scripts/rehearse-recipe.sh` | sin `.rej`, patch nombrado |
| Tabla de decisión | `julia scripts/probe-artifacts-bionic.jl` | 4/4 |
| Build | `gita notify build-package.yml` | rc=0 |
| Instalación aplicada | guarda sobre `HostPlatform().tags["libc"]` | `bionic` |
| Wrapper | probe de `best_wrapper` | `.../aarch64-linux-gnu.jl` |
| Artefacto | probe de `libfftw3_path` | `…/fftw-bionic/lib/libfftw3.so` |
| Overrides | `validate-overrides.jl --list` | 37/37, 0 artefactos nuevos |
| Consumidores | FFTW / SQLite / EzXML / Cairo | `true` / `[42]` / `42` / carga |
| Publicado = verificado | repetir contra la release | idem |

## Riesgos y preguntas abiertas

1. **La forma del override visible en `artifact_meta`** (Tarea 0). Si el camino de `@artifact_str` no
   pasa `pkg_uuid`, `overrides[:hash]` no tiene el hash y la guarda fail-closed rechaza todo. Se
   mide antes de escribir el patch; si hace falta, el patch se mueve al `artifact_meta` de 2
   argumentos.
2. **El camino de descarga de Pkg.** `Pkg.collect_artifacts` / `select_downloadable_artifacts` usan
   `HostPlatform()`. La expectativa es que no haya que tocarlos: `artifact_exists` consulta el
   override por hash y con el override presente el artefacto se considera instalado, así que no hay
   descarga. **A verificar** en la Tarea 4 (y si aparece una descarga, el patch va también ahí).
3. **`setindex!` sobre `Platform`.** Si no está soportado, el fallback se escribe con
   `Platform(arch(platform), os(platform), Dict{String,Any}("libc" => "glibc"))`. La Tarea 2 lo
   detecta localmente.
4. **El patch puede quedar sin uso.** Si el fallback fail-closed no alcanza (p. ej. el override no
   es visible y no hay forma de arreglarlo en `Artifacts`), el plan B es el caro: forks por JLL con
   una entrada bionic en cada `Artifacts.toml` — 37+ repos en vez de uno.
5. **No mover `julia-latest` ni publicar antes de la Tarea 4.** El paquete con el patch de
   plataforma **sin** el de `Artifacts` rompe todo (0/37), así que publicar por partes no es una
   opción: los tres patches viajan juntos.
6. **La ventana del dispositivo.** Mientras dure la verificación, el teléfono queda en bionic; el
   rollback es un `pacman -U` del paquete de `julia-latest` (bajarlo **con `--clobber`** a un
   directorio limpio y verificar el sha256 antes de instalar).
