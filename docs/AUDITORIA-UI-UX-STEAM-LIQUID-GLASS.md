# Auditoría UI/UX — Paridad con Steam y Liquid Glass

Fecha: 18 de julio de 2026

Base auditada: `3bbf566` (`main` / `origin/main`)

Rama de trabajo: `codex/ui-liquid-glass-unification`

## Resumen ejecutivo

Vessel ya tiene una base de producto considerablemente más avanzada de lo que su tamaño aparente
sugiere. La biblioteca común implementa la mayor parte del modelo mental de Steam: navegación de dos
paneles, portada, filtros rápidos, colecciones, favoritos, ocultos, ficha integrada, descargas activas,
notas, búsqueda rápida y navegación reversible. La dirección visual navy y Liquid Glass es coherente
y reconocible.

El mayor riesgo no es la falta de una identidad, sino su crecimiento sin una frontera clara. La vista
principal de biblioteca concentra coordinación, estado, navegación, grid, filas, ficha y varios
overlays en un único archivo de más de 3.300 líneas. Además, permanecen implementaciones antiguas de
las bibliotecas de Epic y GOG que ya no participan en el flujo principal. Esa duplicación facilita que
una plataforma reciba un arreglo visual y otra conserve un comportamiento anterior.

La recomendación es mantener la apariencia actual y evolucionar por capas: primero primitivas nativas
y accesibilidad, después estructura común, luego completar los patrones que Steam resuelve bien. La
paridad debe medirse por jerarquía, completitud y feedback; no por copiar la piel web de Steam.

## Evidencia revisada

- 134 observaciones de Engram asociadas a `vessel` y `vessel-mac`, incluidas las decisiones desde el
  cambio de bottles a una biblioteca de tiendas y los pases recientes de calidad.
- Todos los prompts históricos relevantes conservados en Engram.
- Historial Git hasta `3bbf566`, ramas y worktrees existentes.
- Cambios locales actuales de Kimi, sin modificarlos ni incorporarlos a esta rama.
- `CLAUDE.md`, `DESIGN.md`, `ROADMAP.md`, `README.md`, `docs/AUDITORIA-BUGS.md`, `Package.swift` y
  capturas actuales de la biblioteca.
- 28.954 líneas Swift de producto y 917 líneas de pruebas.
- Xcode 26.6 y Swift 6.3.3 efectivos en esta máquina.

## Estado paralelo de Kimi

El árbol principal contiene trabajo no confirmado de Kimi en:

- `SteamCMDManager.swift`: watchdog por inactividad en lugar de un límite fijo de 45 minutos;
- `SteamLibraryImporter.swift`: validación de `StateFlags`, penalización de herramientas de Source y
  descarte de candidatos inválidos;
- `WineManager.swift`: selección del directorio de mod de Source por semejanza con el juego cuando
  existen varios `gameinfo.txt`;
- `BottleDetailView.swift`: persistencia y reanudación de descargas SteamCMD interrumpidas.

También existen artefactos no versionados de Playwright. Esta auditoría trabaja desde un worktree
independiente y no toca ninguno de esos archivos. No se debe fusionar la rama de UI hasta reconciliar
la base con el commit que finalmente produzca Kimi.

## Arquitectura visual actual

```text
ContentView
├── header nativo + StoreSwitcher
├── SteamStoreView ─┐
├── EpicStoreView  ─┼─ adaptadores de plataforma
├── GogStoreView   ─┤
└── LocalGamesView ─┘
                     └── StoreLibraryView
                         ├── lista lateral + búsqueda/filtros
                         ├── portada + estanterías + grid
                         ├── colecciones/favoritos/ocultos
                         ├── transfer center + undo + quick open
                         └── GameDetailView
                             ├── hero y acción primaria
                             ├── actividad, capturas y metadatos
                             ├── logros y DLC
                             └── compatibilidad y ajustes
```

`Theme.swift` es la fuente ejecutable correcta para colores, radios, fondo, botones, tarjetas,
tooltips y movimiento. `StoreLibraryView.swift` es a la vez la principal fortaleza —la paridad entre
plataformas nace ahí— y el principal punto de deuda por concentración de responsabilidades.

## Matriz de paridad con Steam

| Capacidad | Estado | Evaluación |
|---|---|---|
| Cambio de plataforma en header | Consolidado | Nativo, compacto y con atajos `⌘1…⌘4`. |
| Lista lateral buscable | Consolidado | Juegos, instalación, selección, orden y ancho persistente. |
| Portada de biblioteca | Consolidado | Grid adaptable y estantería de jugados recientemente. |
| Filtros rápidos | Consolidado | Listos, actualizaciones, sin jugar, favoritos y ocultos. |
| Colecciones | Consolidado | Crear, renombrar, eliminar y arrastrar juegos. |
| Favoritos y juegos ocultos | Consolidado | Persistentes, reversibles y accesibles. |
| Ficha integrada | Consolidado | Hero, Jugar/Instalar, tiempo, última sesión y ajustes. |
| Parallax y profundidad de ficha | Mejorado en esta rama | Hero compartido con dos planos y alternativa sin movimiento. |
| Capturas, DLC y metadatos | Consolidado | Fuente común y enriquecimiento tolerante por plataforma. |
| Logros | Parcial | Muy completos en Steam; la disponibilidad depende de credenciales y backend. |
| Descargas | Parcial | Progreso y persistencia visibles; faltan pausa, reordenación y prioridades. |
| Actividad/noticias del juego | Pendiente | No existe una estantería equivalente a «Novedades» o feed por juego. |
| Gestión adaptativa | Mejorado en esta rama | Acciones directas amplias y menú nativo cuando falta ancho. |
| Estado de guardados | Parcial | Hay infraestructura de copias, pero no una señal global comparable a Steam Cloud. |
| Paridad visual entre plataformas | Parcial | El flujo común es coherente; quedan vistas antiguas duplicadas de Epic/GOG. |
| Preferencias de accesibilidad | Mejorado en esta rama | Reduce motion y reduce transparency pasan a las primitivas centrales. |

## Mapa de efectos de Steam adaptados a Vessel

| Efecto | Estado | Adaptación nativa propuesta |
|---|---|---|
| Contenido bajo cabecera | Consolidado | Scroll edge con Liquid Glass y hairline, común a toda la ventana. |
| Elevación de carátulas | Consolidado | Escala y sombra contenidas al hover, sin movimiento si el usuario lo reduce. |
| Preview rico al mantener hover | Consolidado | Capturas/vídeo, metadatos y apertura directa sin alterar la selección. |
| Parallax del hero | Implementado en esta rama | Ilustración y contenido en planos distintos dentro de `GameDetailView`. |
| Transición carátula → ficha | Siguiente | Continuidad espacial sutil mediante geometría compartida; sin zoom agresivo. |
| Barra de acciones contextual | Parcial | Acciones adaptativas ya implementadas; estudiar persistencia al bajar por la ficha. |
| Carrusel de capturas | Parcial | Añadir snapping, navegación por teclado y respuesta de hover sin autocarrusel invasivo. |
| Atmósfera derivada del juego | Por evaluar | Velo de color muy tenue obtenido del hero, limitado por contraste y rendimiento. |
| Feedback de instalación | Parcial | Evolucionar progreso a una cola manipulable con transiciones de estado compartidas. |

El orden recomendado es continuidad carátula→ficha, barra contextual y carrusel. La atmósfera de
color solo debe añadirse si una prueba en ventana real confirma que no rompe el navy de Vessel ni
reduce la legibilidad del Liquid Glass.

## Hallazgos priorizados

### P1 — Mantener una única biblioteca real

`StoreLibraryView` es el camino actual, pero `EpicStoreView.swift` y `GogStoreView.swift` conservan
grids y tarjetas de biblioteca anteriores sin invocaciones en el flujo principal. Aunque hoy sean
código muerto, pueden confundir futuras correcciones y añaden estilos hardcodeados que contradicen
`Theme`. Conviene retirarlos en un cambio separado, con compilación y pruebas antes y después.

### P1 — Dividir el coordinador sin dividir el diseño

El archivo común supera las 3.300 líneas. Debe separarse por responsabilidad, manteniendo estado y
comandos en un único coordinador:

- shell y navegación de biblioteca;
- sidebar y filtros;
- portada, estanterías y grid;
- transfer center, quick open y overlays;
- ficha del juego y sus secciones.

La división es estructural: no debe crear implementaciones específicas por tienda.

### P1 — Completar gestión de descargas

El centro actual informa bien, pero todavía es un observador. Para alcanzar el estándar de Steam debe
permitir, cuando el backend lo soporte, pausar/reanudar, cancelar con confirmación, priorizar y explicar
por qué una operación espera. Los estados deben sobrevivir a la navegación y al reinicio.

### P2 — Añadir actividad útil, no ruido

La siguiente estantería con mayor valor es «Novedades»: actualizaciones instaladas, notas de versión o
actividad local relevante. Debe ser opcional y breve; no un feed social. En la ficha, la actividad
reciente puede complementar última sesión, logros y capturas.

### P2 — Convertir estilos locales en tokens semánticos

Todavía existen radios, opacidades, sombras y colores puntuales fuera de `Theme`. Algunos son
geometría inherente a imágenes, pero otros son deriva visual. La migración debe hacerse por componente,
no mediante una sustitución masiva que borre jerarquía.

### P2 — Validación visual reproducible

Las pruebas lógicas son amplias, pero no existe una red de seguridad perceptual. `ImageRenderer` no
reproduce de forma fiable Liquid Glass, listas ni ColorfulX. La comprobación válida es una ventana real
en macOS 26, con capturas de referencia para:

- biblioteca amplia y estrecha;
- ficha con y sin instalación;
- descargas activas;
- búsqueda sin resultados y error de autenticación;
- reducir movimiento y reducir transparencia.

## Primera mejora aplicada en esta rama

- `DESIGN.md` migrado al formato de Google Labs, con tokens, reglas canónicas y cero warnings de lint.
- Paridad con Steam formalizada como referencia de producto, no como copia literal.
- Tres tiendas más DRM‑free documentadas sin contradicciones.
- `GlassEffectContainer` encapsulado para grupos de cristal en macOS 26.
- Fallback opaco y legible cuando el usuario activa «Reducir transparencia».
- Botones, hover, selector de plataforma y pantallas de conexión respetan «Reducir movimiento».
- Scopes, controles de la ficha y visor de capturas comparten contenedores de cristal nativos.
- La barra de acciones de la ficha se adapta: controles directos con espacio suficiente y menú nativo
  de gestión en anchos reducidos.
- El hero compartido incorpora parallax contenido entre ilustración y contenido; llega a Steam, Epic,
  GOG y DRM‑free sin duplicar implementación y se desactiva con «Reducir movimiento».

## Secuencia recomendada

1. Integrar esta base visual después de que Kimi cierre sus cambios y rebasar la rama sobre ese commit.
2. Extraer la biblioteca común por componentes sin cambiar comportamiento ni aspecto.
3. Eliminar las bibliotecas heredadas de Epic/GOG y verificar que todos los flujos usan la común.
4. Unificar estados de autenticación, errores, vacíos y ajustes con las mismas primitivas.
5. Completar el lenguaje dinámico común: transición portada→ficha, previews de vídeo/capturas y
   respuesta del hero a hover/scroll, siempre con presupuesto de rendimiento y reduce motion.
6. Evolucionar el centro de descargas hacia una cola gestionable.
7. Añadir actividad/novedades y estado de guardados solo cuando exista una fuente confiable.
8. Cerrar cada fase con build Release, pruebas y revisión de ventana real en macOS 26.

## Criterios de aceptación visual

- La jerarquía se entiende sin depender del color.
- Jugar/Instalar es siempre la acción dominante de una ficha.
- Ningún ancho razonable recorta o solapa acciones.
- Las cuatro plataformas comparten layout, estados y comportamiento.
- El cristal aparece en capas funcionales y nunca se apila.
- Reducir movimiento elimina escalas y transiciones; reducir transparencia conserva contraste.
- El usuario nunca necesita entender qué motor de compatibilidad se ha elegido para poder jugar.

## Referencias nativas

- Apple, *Applying Liquid Glass to custom views*: <https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views>
- Apple, *Adopting Liquid Glass*: <https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass>
