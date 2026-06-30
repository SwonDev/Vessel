# ROADMAP — Vessel

Hoja de ruta de features pendientes (lo ya hecho está en el historial de git). Basado en el
análisis de huecos frente a Mythic/Heroic, filtrado por la filosofía de Vessel ("abre y juega",
bottle invisible, premium). Comandos exactos de los backends verificados y guardados en memoria.

## Hecho (sesión jun 2026)
- ✅ Tiempo jugado + "jugados recientemente" + orden "Más jugado" (cross-tienda).
- ✅ Verificar / reparar integridad (Steam/Epic/GOG).
- ✅ Actualizaciones: detección Epic (`--check-updates`) + badge + acción "Actualizar" en las 3.
- ✅ Notificaciones del sistema (instalación completada).
- ✅ Cloud saves de Epic automáticos (baja al jugar, sube al cerrar; hook `onExit` en el tracker).

## Pendiente (orden sugerido)
1. **Cloud saves GOG** — `gogdl save-sync <path> <id> --ts <ts> --os windows`. Exige resolver la
   ruta de guardado del `goggame-<id>.info` (config cloudStorage) y persistir el timestamp por
   juego (como Heroic). No implementar a ciegas: riesgo de perder partidas.
2. **DLCs (Epic/GOG)** — listar e instalar DLCs por juego (`gogdl info` / `--with-dlcs` /
   `--dlc-only`; legendary). UI en la ficha del juego.
3. **Mover instalación** — mover la carpeta del juego a otra ubicación + actualizar
   `installPath`/manifest sin reinstalar.
4. **Logros · Discord RPC · Metal HUD**:
   - Logros: visor (Goldberg los emite local; GOG/Epic vía API).
   - Discord Rich Presence (juego actual + carátula).
   - Toggle **Metal Performance HUD** (`MTL_HUD_ENABLED=1`) por juego. ⚠️ Antes hay que hacer
     `GameConfig` tolerante al decodificar (`decodeIfPresent`) para NO resetear ajustes guardados
     al añadir el campo nuevo.

## Excluido por filosofía (no construir salvo petición explícita, tras un toggle "Avanzado")
winecfg · regedit · "ejecutar .exe arbitrario" · selector de motor en UI — contradicen "el bottle
es invisible".

## Reglas de UX para todo lo nuevo
- **Sin pantallas de carga a pantalla completa** al refrescar una biblioteca ya cargada: el
  refresco es ORGÁNICO (la lista se actualiza en su sitio; los instalados suben arriba).
- Estética Liquid Glass premium (ver DESIGN.md). Validar build + tests tras cada cambio.
