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
- DLCs: lectura en la ficha (Steam/Epic/GOG) + instalación individual en Epic/GOG cuando el
  backend publica un paquete independiente; Steam conserva el modelo nativo de SteamCMD.
- Metadata rica: descripción, capturas ampliables (lightbox), logros (totales), compat ProtonDB.
- **Desinstalar en Epic y GOG** (paridad con Steam, con regla de seguridad de rutas).
- **Diagnóstico post-lanzamiento** (`LaunchDiagnostics`): avisos accionables al fallar un juego.
- **Fallback automático de motor** (DXMT↔GPTK): si el arranque falla de forma recuperable
  (gráficos/crash/Vulkan), relanza con la otra capa una vez y avisa. Cableado en las 3 tiendas.
- **Provisión y autorreparación de runtimes** (`RuntimeDependencyProvisioner`): inspecciona de forma
  acotada el ejecutable, DLLs y configuraciones del juego; distingue generaciones VC++ 6–2022,
  .NET Framework/.NET Desktop 6–9, XNA, helpers DirectX, XInput/XAudio/XACT, OpenAL, PhysX, GDI+ y
  DirectShow. Copia los helpers D3DX empaquetados y, solo ante un fallo real, aplica el plan exacto
  con winetricks fijado y verificado por SHA-256. La reparación forzada recompone también prefijos
  dañados aunque el runtime figurase como instalado, sin depender de Homebrew ni de Steam macOS.
- **Anti-cheat honesto**: cruza la ficha con MacAnticheatData y marca «No funciona» con la causa
  solo para estados `Denied`/`Broken`; `Unknown` no se degrada. Los perfiles declaran también la
  protección en Epic/GOG y nunca se intenta desactivar ni eludirla.
- **Arquitectura y ejecutable robustos**: el resolver prioriza clientes Win64/Unity/Unreal frente a
  launchers auxiliares y Ajustes → Avanzado permite elegir un `.exe` interno alternativo. La ruta
  se canonicaliza, debe permanecer dentro de la instalación y vuelve al automático si queda rota.
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
- **Acceso rápido y notas**: buscador de apertura con `⌘K` para bibliotecas grandes y notas privadas
  por juego, con guardado automático local y acceso desde la ficha, menús contextuales y menú Juego.
- **Paridad visual común con Steam**: una sola biblioteca para Steam, Epic, GOG y DRM‑free; hero con
  parallax, continuidad carátula→ficha, acciones adaptativas y persistentes, previews enriquecidos y
  carruseles con snapping y teclado. Liquid Glass respeta Reducir movimiento/transparencia.
- **Centro de descargas persistente**: cola serial visible en las tres tiendas, actualizar todo,
  pausa/reanudación, cancelación real, prioridad, reintento y recuperación tras reiniciar.
- **Actividad reciente estilo Steam**: historial local persistente de instalaciones, actualizaciones,
  verificaciones, desinstalaciones, DLC, fallos y cancelaciones reales de Steam/Epic/GOG. La portada
  común lo presenta sin depender de feeds remotos desiguales ni inventar notas de parche.
- **Filtros avanzados**: género con índice local persistente bajo petición, compatibilidad offline y
  tamaño instalado, compartidos por Steam/Epic/GOG/DRM‑free sin bloquear la biblioteca.

## 🔜 Pendiente (orden por impacto en catálogo/UX)

### Funcionalidad por tienda
5. ~~**Instalar DLC individual**~~ ✅ HECHO en Epic/GOG cuando existe paquete instalable; SteamCMD
   gestiona los DLC poseídos con el juego base.
6. ~~Steam: distinguir "Actualizar" de "Verificar"~~ ✅ HECHO.
7. ~~"Actualizar todo" + cola visible~~ ✅ HECHO, persistente y cancelable.

### UI premium (DESIGN.md)
8. ~~Paridad visual Epic/GOG con Steam y Liquid Glass común~~ ✅ HECHO.
9. ~~Filtros avanzados (género, rating de compatibilidad y tamaño)~~ ✅ HECHO con caché local
   indexable y preparación explícita para evitar tráfico remoto al filtrar.

## 🧪 Validación manual pendiente

- Recorrer en una cuenta real un ciclo corto de instalar → pausar → reanudar → cancelar en cada
  backend y comprobar el resultado de disco. Estas pruebas alteran descargas y bibliotecas reales,
  por lo que no se ejecutan automáticamente ni sin un juego objetivo aprobado.
- Confirmar con VoiceOver y los ajustes globales «Reducir movimiento», «Reducir transparencia» y
  «Aumentar contraste» en una sesión interactiva. La implementación y los escenarios Debug están
  preparados, pero estas preferencias pertenecen al sistema, no a una prueba unitaria.

## Excluido por filosofía (solo bajo toggle "Avanzado")
winecfg · regedit · ejecutar .exe arbitrario · selector de motor en UI — el bottle es invisible.

## Reglas de UX para todo lo nuevo
- Sin pantallas de carga a pantalla completa al refrescar una biblioteca ya cargada (refresco orgánico).
- Estética Liquid Glass premium (DESIGN.md). Validar build tras cada cambio. Seguridad de rutas
  SIEMPRE antes de borrar (canonicalizar + subcarpeta estricta).
