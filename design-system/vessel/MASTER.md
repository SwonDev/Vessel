# Vessel — Design System (MASTER · fuente de verdad)

> La identidad de Vessel manda sobre cualquier recomendación automática. El motor de
> UI/UX Pro Max sugirió "retro-futurism/neón" para "gaming": **descartado** por chocar
> con esta identidad. De Pro Max se adoptan sus **principios profesionales de UX**.

## Identidad
- **Navy oceánico + Liquid Glass nativo + modo oscuro.** Conceptos: barco, océano, profundidad, confianza.
- Referencia de calidad: **MythicApp/Mythic**. Premium, minimalista, NADA recargado. Prohibido neón/scanlines/synthwave/glitch.
- Sistema central en código: `Sources/Vessel/Support/Theme.swift` (úsalo siempre; no hardcodear estilos).

## Color
- Fondo: navy `#0F1828` → `#06101A` (degradado) + resplandor superior tintado por sección.
- Acento: azul confianza `~#2A8FFF` (`Theme.accent`); gradiente a `#1A5CDB` (`Theme.gradient`).
- Acento por tienda (branding de sección): `StoreKind.tint`.
- Texto: blanco/`.primary` y `.secondary` sobre navy (modo oscuro forzado).
- Contraste mínimo 4.5:1 (verificar texto secundario sobre glass).

## Tipografía
- San Francisco del sistema (NO fuentes gaming tipo Russo One). Jerarquía: `.largeTitle.bold` (hero) → `.title2.bold` (sección) → `.headline` (tarjeta) → `.caption/.footnote` (metadatos). `monospacedDigit()` en contadores.

## Profundidad / materiales
- Esquinas continuas: `Theme.Radius` (cover 14, card 16, control 10, panel 20).
- `liquidGlass(in:tint:)` para superficies/paneles/campos; sombras suaves de color en iconos hero.
- Carátulas con degradado inferior + título superpuesto (estilo editorial Mythic).

## Microinteracciones (principios Pro Max)
- Transiciones **150–300ms**; animar `transform/opacity` (escala/opacidad), no tamaño.
- Hover con feedback claro **sin layout shift** (`hoverLift`/escala contenida + sombra).
- Animaciones **infinitas solo para carga/estado** (p. ej. pulso al conectar), no decorativas → respetar `accessibilityReduceMotion`.
- Espaciado entre controles ≥ 8pt; targets cómodos.

## Accesibilidad
- Focus states visibles en navegación por teclado.
- Iconos: **SVG/SF Symbols**, nunca emojis. Logos de marca **oficiales** (Simple Icons) — ya integrados (`StoreLogo`/`StoreLogoTile`).
- Color nunca como único indicador (acompañar con texto/símbolo).

## Componentes (Theme.swift)
- `vesselBackground(tint:)`, `liquidGlass(in:tint:interactive:)`, `.buttonStyle(.premium(tint:prominent:))`, `hoverLift(scale:)`, `vesselCard(...)`, `StoreLogoTile(store:size:)`.
