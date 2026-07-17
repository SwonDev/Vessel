# ROADMAP — Vessel

Hoja de ruta viva. Prioridad: **máximo catálogo de juegos compatibles** + **todas las
funcionalidades por tienda** (Steam/Epic/GOG), manteniendo la filosofía "abre y juega" (bottle
invisible) y la estética premium (DESIGN.md). Basado en auditoría de huecos frente a Mythic/Heroic.

## ✅ Hecho
- **Fix del ratón de Unity 6** (`EnableMouseInPointer`): motor `wine-dxmt-mousefix` (wine-dxmt real
  + win32u.so parcheado desde wine-9.9) + reroute Unity→DXMT + auto-creación. Validado in-game.
- Tiempo jugado + "recientes" + orden "Más jugado" (cross-tienda).
- Verificar/reparar integridad (las 3 tiendas).
- Actualizaciones: detección + badge + acción "Actualizar" (las 3).
- Cloud saves automáticos (Steam local + Epic + GOG; baja al jugar, sube al cerrar).
- DLCs: lectura en la ficha (Steam/Epic/GOG) — se instalan junto al juego.
- Metadata rica: descripción, capturas ampliables (lightbox), logros (totales), compat ProtonDB.
- **Desinstalar en Epic y GOG** (paridad con Steam, con regla de seguridad de rutas).
- **Diagnóstico post-lanzamiento** (`LaunchDiagnostics`): avisos accionables al fallar un juego.
- **Fallback automático de motor** (DXMT↔GPTK): si el arranque falla de forma recuperable
  (gráficos/crash/Vulkan), relanza con la otra capa una vez y avisa. Cableado en las 3 tiendas.
- **Provisión de dependencias de runtime** (`RuntimeDependencyProvisioner`): detecta imports PE y
  copia junto al `.exe` los helpers de DirectX 9 (d3dx9/d3dcompiler) que empaquetamos. VC++/.NET/
  XInput los cubre el builtin del motor; se registran para el diagnóstico.
- Permisos macOS: `NSNetworkVolumesUsageDescription` (prompt una sola vez).
- **UI premium**: scrollbars **Liquid Glass** en toda la app (NSScroller custom + swizzle global);
  **sidebar colapsable animada** + divisor arrastrable; **selector de tamaño de carátulas**
  (Compacta/Normal/Grande, estilo Steam); **buscador/filtro/orden en la cabecera** del grid al
  colapsar; fix del arrastre de ventana (solo desde el header).
- **Organización estilo Steam**: colecciones manuales persistentes por tienda, asignación desde el
  menú contextual, filtro discreto en la scope bar, navegación atrás/adelante y deshacer al ocultar.
- **Logros interactivos**: progreso real, desbloqueados/bloqueados, rareza e iconos cuando la sesión
  o la Web API de Steam lo permiten; degradación honesta si el perfil es privado.
- Ficha de compatibilidad con acceso directo a ProtonDB y enlace a la página del juego en Steam.

## 🔜 Pendiente (orden por impacto en catálogo/UX)

### Compatibilidad (más catálogo)
1. **Provisión automática de dependencias** (vcredist / .NET / d3dx9) — el mayor multiplicador
   (~40-60% de juegos legacy/Unity fallan sin ellas). Enfoque SEGURO (sin instaladores frágiles que
   cuelguen): bundlear/descargar los DLLs redistribuibles y copiarlos a `system32`/`syswow64` del
   prefijo según los imports PE del `.exe` (ampliar `detectRuntimeDependencies` + el sistema de
   `winetricksVerbs` de los perfiles). Requiere decidir de dónde se obtienen los DLLs.
2. ~~**Fallback automático de motor**~~ ✅ HECHO (ver arriba).
3. **Anti-cheat** (EAC/BattlEye/CodeFusion): investigar; muchos no tienen solución en Mac → marcar
   `rating: borked` con causa documentada.
4. Detección de arquitectura más robusta (launcher 32-bit → exe 64-bit interno) + override manual.

### Funcionalidad por tienda
5. **Instalar DLC individual** (botón en la ficha) — hoy los DLC son solo lectura.
6. Steam: distinguir "Actualizar" (sin `validate`) de "Verificar" (con `validate`).
7. "Actualizar todo" + cola de descargas/actualizaciones visible.

### UI premium (DESIGN.md)
8. Paridad visual Epic/GOG con Steam (Liquid Glass en las tarjetas).
9. Filtros avanzados (género, rating de compat, tamaño) + microinteracciones.

## Excluido por filosofía (solo bajo toggle "Avanzado")
winecfg · regedit · ejecutar .exe arbitrario · selector de motor en UI — el bottle es invisible.

## Reglas de UX para todo lo nuevo
- Sin pantallas de carga a pantalla completa al refrescar una biblioteca ya cargada (refresco orgánico).
- Estética Liquid Glass premium (DESIGN.md). Validar build tras cada cambio. Seguridad de rutas
  SIEMPRE antes de borrar (canonicalizar + subcarpeta estricta).
