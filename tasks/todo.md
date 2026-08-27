# Tareas: builds incrementales de Julia en CI

- [x] Estabilizar y versionar las cachés de build y ccache.
- [x] Activar ccache dentro del contenedor Docker.
- [x] Eliminar el force-refresh del build de Julia.
- [x] Separar compilación y publicación por permisos.
- [x] Revisar el log y corregir la expansión incorrecta de ZLIB en CMake.
- [x] Corregir la generación host de `llvm-min-tblgen` y añadir `Dockerfile`.
- [ ] Validar, publicar y confirmar el nuevo workflow de CI.
