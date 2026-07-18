# Auditoría UI/UX — Paridad con Steam y Liquid Glass

Fecha: 18 de julio de 2026

Base actual: `9508b24` (`main`) + rama visual `codex/ui-liquid-glass-unification`

Rama de trabajo: `codex/ui-liquid-glass-unification`

## Resumen ejecutivo

Vessel ya tiene una base de producto considerablemente más avanzada de lo que su tamaño aparente
sugiere. La biblioteca común implementa la mayor parte del modelo mental de Steam: navegación de dos
paneles, portada, filtros rápidos, colecciones, favoritos, ocultos, ficha integrada, descargas activas,
notas, búsqueda rápida y navegación reversible. La dirección visual navy y Liquid Glass es coherente
y reconocible.

El mayor riesgo no era la falta de una identidad, sino su crecimiento sin una frontera clara. Esta
rama lo reduce: el coordinador, los componentes de portada y la ficha viven ahora en archivos
separados; además se retiraron las bibliotecas antiguas de Epic y GOG que ya no participaban en el
flujo. La única gramática visual ejecutable es la biblioteca común de las cuatro plataformas.

La recomendación es mantener la apariencia actual y evolucionar por capas: primero primitivas nativas
y accesibilidad, después estructura común, luego completar los patrones que Steam resuelve bien. La
paridad debe medirse por jerarquía, completitud y feedback; no por copiar la piel web de Steam.

## Evidencia revisada

- 134 observaciones de Engram asociadas a `vessel` y `vessel-mac`, incluidas las decisiones desde el
  cambio de bottles a una biblioteca de tiendas y los pases recientes de calidad.
- Todos los prompts históricos relevantes conservados en Engram.
- Historial Git hasta `9508b24`, ramas y worktrees existentes.
- Commit `9508b24` de Kimi, integrado mediante rebase antes de la segunda pasada visual.
- `CLAUDE.md`, `DESIGN.md`, `ROADMAP.md`, `README.md`, `docs/AUDITORIA-BUGS.md`, `Package.swift` y
  capturas actuales de la biblioteca.
- 28.954 líneas Swift de producto y 917 líneas de pruebas.
- Xcode 26.6 y Swift 6.3.3 efectivos en esta máquina.

## Integración del trabajo de Kimi

El trabajo de Kimi quedó consolidado en `9508b24` e incorporado a esta rama antes de continuar:

- `SteamCMDManager.swift`: watchdog por inactividad en lugar de un límite fijo de 45 minutos;
- `SteamLibraryImporter.swift`: validación de `StateFlags`, penalización de herramientas de Source y
  descarte de candidatos inválidos;
- `WineManager.swift`: selección del directorio de mod de Source por semejanza con el juego cuando
  existen varios `gameinfo.txt`;
- `BottleDetailView.swift`: persistencia y reanudación de descargas SteamCMD interrumpidas.

Los artefactos no versionados de Playwright siguen limitados al worktree principal. Esta rama trabaja
desde un worktree independiente y no los modifica.

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
tooltips y movimiento. `StoreLibraryView.swift` conserva coordinación y estado;
`StoreLibraryComponents.swift` reúne portada, filas, tarjetas y descargas; `GameDetailView.swift`
contiene la ficha común. La separación mantiene una única experiencia sin conservar el monolito.

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
| Descargas | Consolidado | Cola persistente con pausa, cancelación, prioridad, reintento y recuperación en los tres backends. |
| Actividad/noticias del juego | Consolidado local | Estantería común con operaciones reales; no se muestran noticias remotas sin una fuente fiable por tienda. |
| Gestión adaptativa | Mejorado en esta rama | Acciones directas amplias y menú nativo cuando falta ancho. |
| Estado de guardados | Parcial | Hay infraestructura de copias, pero no una señal global comparable a Steam Cloud. |
| Paridad visual entre plataformas | Consolidado | Una sola biblioteca y ficha para Steam, Epic, GOG y DRM‑free; código heredado retirado. |
| Preferencias de accesibilidad | Mejorado en esta rama | Reduce motion y reduce transparency pasan a las primitivas centrales. |

## Mapa de efectos de Steam adaptados a Vessel

| Efecto | Estado | Adaptación nativa propuesta |
|---|---|---|
| Contenido bajo cabecera | Consolidado | Scroll edge con Liquid Glass y hairline, común a toda la ventana. |
| Elevación de carátulas | Consolidado | Escala y sombra contenidas al hover, sin movimiento si el usuario lo reduce. |
| Preview rico al mantener hover | Consolidado | Capturas/vídeo, metadatos y apertura directa sin alterar la selección. |
| Parallax del hero | Implementado en esta rama | Ilustración y contenido en planos distintos dentro de `GameDetailView`. |
| Transición carátula → ficha | Implementado | Geometría compartida de carátula a hero; fallback estático con Reducir movimiento. |
| Barra de acciones contextual | Implementado | Toolbar flotante con título, estado, acción primaria y menú después del hero. |
| Carrusel de capturas | Implementado | Snapping, trackpad, hover, flechas, Intro y navegación completa del lightbox. |
| Atmósfera derivada del juego | Por evaluar | Velo de color muy tenue obtenido del hero, limitado por contraste y rendimiento. |
| Feedback de instalación | Consolidado | Cola manipulable, estado persistente y actividad posterior compartida entre Steam/Epic/GOG. |

Los tres efectos prioritarios ya comparten implementación. La atmósfera de color permanece descartada
por ahora: el fondo ya deriva de la plataforma y añadir un segundo tinte por juego puede romper el
navy, el contraste y el presupuesto de GPU sin aportar información funcional.

## Hallazgos priorizados

### Resuelto — Mantener una única biblioteca real

`EpicStoreView.swift` y `GogStoreView.swift` ya no conservan grids ni tarjetas antiguas. Ambos adaptan
datos y callbacks a `StoreLibraryView`, igual que Steam y DRM‑free.

### Resuelto — Dividir el coordinador sin dividir el diseño

La separación se completó por responsabilidad, manteniendo estado y comandos en un único coordinador:

- `StoreLibraryView.swift`: shell, navegación, sidebar, filtros y coordinación;
- `StoreLibraryComponents.swift`: portada, estanterías, tarjetas, filas y transfer center;
- `GameDetailView.swift`: hero, acciones y secciones de la ficha.

La división sigue siendo estructural y no crea implementaciones específicas por tienda.

### Resuelto — Completar gestión de descargas

El centro permite pausar/reanudar, cancelar, priorizar y reintentar sobre SteamCMD, Legendary y gogdl.
Los procesos se cancelan de verdad y los estados seguros sobreviven a la navegación y al reinicio.

### Resuelto — Añadir actividad útil, no ruido

La portada incorpora «Actividad reciente» con instalaciones, actualizaciones, verificaciones,
desinstalaciones, DLC, fallos y cancelaciones observados por Vessel. Es breve, persistente y abre la
ficha del juego cuando sigue presente. Las notas de versión remotas se omiten deliberadamente hasta
que las tres tiendas ofrezcan una fuente verificable y homogénea.

### P2 — Convertir estilos locales en tokens semánticos

Todavía existen radios, opacidades, sombras y colores puntuales fuera de `Theme`. Algunos son
geometría inherente a imágenes, pero otros son deriva visual. La migración debe hacerse por componente,
no mediante una sustitución masiva que borre jerarquía.

### Mejorado — Validación visual reproducible

`VesselUIReviewView` ofrece ahora una biblioteca de muestra activable solo en Debug, sin autenticar
tiendas ni ejecutar operaciones. Permite revisar una ventana real en macOS 26 porque `ImageRenderer`
no reproduce de forma fiable Liquid Glass, listas ni ColorfulX. Siguen siendo necesarios escenarios
manuales para preferencias globales del sistema y estados que dependen de backends reales:

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

## Segunda mejora aplicada en esta rama

- La rama se rebasó sobre `9508b24`, por lo que incluye las correcciones de descargas e importación
  realizadas en paralelo por Kimi sin duplicar ni sobrescribir su trabajo.
- La carátula y el hero comparten geometría al abrir una ficha; Reducir movimiento conserva un cambio
  de opacidad inmediato y evita el desplazamiento espacial.
- Tras desplazar hero y acciones aparece una toolbar contextual de Liquid Glass con título, estado,
  Jugar/Instalar/Detener y menú de gestión.
- El carrusel de capturas usa snapping, flechas, trackpad, foco, teclado e indicador de posición; el
  lightbox consume Escape y las flechas con controles accesibles.
- La estantería de jugados recientemente también alinea tarjetas y admite flechas de teclado.
- La biblioteca se separó en coordinador, componentes y ficha sin bifurcar comportamiento por tienda.
- Se eliminaron 405 líneas de grids y tarjetas antiguas de Epic/GOG que ya no tenían invocaciones.
- La revisión de ventana real descubrió y corrigió una particularidad de composición de macOS 26:
  los cristales aplicados a un `Color.clear` dentro de `GlassEffectContainer` podían elevarse sobre
  su etiqueta y difuminar scopes o botones. El cristal se aplica ahora al control completo.

## Tercera mejora aplicada en esta rama

- `LibraryActivityStore` conserva una ventana acotada de actividad real y separada por tienda.
- `LibraryOperationQueue` registra resultados completados, fallidos y cancelados sin duplicar el
  fallo cuando el usuario descarta su fila.
- La portada común presenta la estantería en Steam, Epic y GOG con carátula, estado, fecha relativa,
  navegación a ficha, hover estable y descripción completa para VoiceOver.
- El escenario `VESSEL_UI_REVIEW=1` incluye éxitos y fallos deterministas para revisar esta capa sin
  autenticar cuentas ni alterar una instalación.
- Los colores de juego y destrucción ya consumen literalmente `colors.play` y
  `colors.destructive` de `DESIGN.md` mediante `Theme.play` y `Theme.destructive`.
- Se retiró el método muerto `LegendaryManager.launchGame`, que prometía «próximamente» aunque el
  lanzamiento real de Epic ya usa desde hace tiempo `EpicStore.play` y `WineManager`.

## Secuencia recomendada

1. ~~Rebasar la rama visual sobre el commit de Kimi.~~ Completado.
2. ~~Separar coordinador, componentes y ficha.~~ Completado.
3. ~~Retirar bibliotecas heredadas Epic/GOG.~~ Completado.
4. ~~Completar transición portada→ficha, acción contextual y carruseles.~~ Completado.
5. ~~Evolucionar el centro de descargas con controles fiables y cancelación segura.~~ Completado.
6. ~~Añadir actividad útil cuando exista una fuente confiable.~~ Completado con hechos locales de los
   backends; los feeds remotos siguen fuera mientras no exista paridad de fuentes.
7. ~~Incorporar filtros por metadatos sin penalizar bibliotecas grandes.~~ Completado con índice local.

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
