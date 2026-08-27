# Plan: builds incrementales de Julia en CI

## Objetivo

Hacer que las ejecuciones de GitHub Actions reutilicen el árbol de trabajo,
objetos compilados y descargas de Julia/LLVM entre commits, manteniendo una
ejecución limpia reproducible cuando no exista caché.

## Decisiones

- Usar claves de caché estables basadas en inputs del build, no en `run_id`.
- Mantener el estado de `~/.termux-build` separado de la caché de ccache.
- Montar ccache dentro del contenedor y activar wrappers para compiladores C/C++.
- Quitar `-f` del build incremental de Julia; la invalidación queda a cargo de
  las dependencias normales de `make` y de la nueva clave de caché.
- Mantener publicación con permisos de escritura en un job posterior y dejar
  el job de compilación con permisos mínimos.
- Pasar rutas absolutas al zlib target en `deps/llvm.mk`; las variables `${...}`
  dentro de una variable de Make no llegan al shell como se esperaba.
- Invalidar únicamente `CMakeCache.txt`/`CMakeFiles` de LLVM cuando contienen
  el zlib host incorrecto, conservando los objetos LLVM ya compilados.
- Mantener el contenedor en la arquitectura nativa del runner y configurar
  explícitamente `HOSTCC/HOSTCXX` para las herramientas LLVM ejecutables.
- Mantener un Dockerfile derivado de `ghcr.io/termux/package-builder` para que
  el workflow de imagen tenga una fuente real y reproducible.

## Verificación

- `bash -n` para scripts ejecutados por CI.
- Validación YAML/actionlint si están disponibles.
- Comprobación de claves, artefactos, permisos y dependencias del workflow.
- Búsqueda de rutas temporales prohibidas en los scripts afectados.
- Revisión del log de CI para confirmar que CMake usa el zlib target y no
  `/lib/libz.so`.
- Confirmar que `llvm-min-tblgen` se genera como herramienta host y que el
  workflow Docker encuentra `scripts/Dockerfile`.
