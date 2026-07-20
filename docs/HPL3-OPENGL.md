# HPL3 sobre OpenGL 4.1 core en macOS

Vessel incluye un adaptador aislado para las builds Windows de HPL3 que combinan OpenGL de
compatibilidad con GLSL moderno. No requiere parámetros, configuración ni instalación manual.

## Detección

La ruta solo se activa cuando coinciden todas estas señales estructurales:

- PE64 con imports reales de `opengl32`, GLEW, SDL2, Newton y FMOD Ex/Event.
- Marcadores internos de HPL, su inicialización GLEW y sus contextos OpenGL de trabajo.
- Contrato de recursos `hps_api.hps`, `materials.cfg` y `_shadersource/shadercache.xml`.

El título, nombre principal y AppID no intervienen. Si el depot incluye un hermano oficial
`*_NoSteam.exe`, Vessel lo elige únicamente cuando ambos PE tienen la misma firma HPL3, el principal
importa Steamworks y el hermano no. Esto evita el diálogo real «Steam API failed to initialize» que
presenta el principal fuera del cliente sin introducir binarios externos ni mocks.

## Aislamiento y autorreparación

`wine-unified-opengl-legacy` se crea bajo demanda como clon COW de `wine-unified` WineHQ 11.10. Solo
reemplaza `winemac.so` y `opengl32.so`, verifica ambos con SHA-256 y se reconstruye si cambia la base o
algún artefacto. Un prefijo hermano conserva registro y `drive_c/windows` propios, mientras enlaza los
juegos y partidas del prefijo base. `RetinaMode=n` queda limitado a ese prefijo.

Los cambios Wine permanecen inertes salvo que Vessel pase `VESSEL_FORCE_CORE_GL_CTX=1` al proceso
detectado. El adaptador:

- promueve solicitudes implícitas a OpenGL 4.1 core/forward-compatible;
- expone a GLEW las extensiones que en 4.1 ya pertenecen al núcleo;
- traduce bindings GLSL 4.20 a llamadas equivalentes de OpenGL 4.1;
- virtualiza el VAO 0 de compatibilidad;
- traduce grupos `GL_QUADS` a abanicos de cuatro vértices;
- convierte `GL_ALPHA`, `GL_LUMINANCE`, `GL_LUMINANCE_ALPHA` y `GL_INTENSITY` a RED/RG con swizzle.

## Artefactos reproducibles

- Fuente: WineHQ 11.10 + `docs/wine-patches/0005-opengl4-legacy-core-compat.patch`.
- `opengl32.so`: SHA-256
  `6e1ece49637bb5145e660e5bd619c939ff8525b74b80888ae61b64ac5f31ea94`.
- `winemac.so`: SHA-256
  `863e00bf8376439dfa8d95fb66cd9431fceb13b0935f8f92efbada63d0386230`.
- Arquitectura: Mach-O x86_64, símbolos de depuración eliminados y firma ad-hoc válida.

El parche aplica limpiamente sobre el tarball oficial Wine 11.10 y los dos targets recompilan sin
advertencias nuevas.

## Validación real

El 20 de julio de 2026 se validó Amnesia: Rebirth desde su ejecutable oficial sin Steam: pantalla de
gamma, menús, opciones, selección de partida, introducción y escena 3D `01_01_plane_wreckage`, con
guardado automático, texto correcto, ventana ajustada y entrada alineada. El ejecutable principal se
probó por separado y confirmó el diálogo de fallo de Steamworks que motiva la selección automática.
