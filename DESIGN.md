# DESIGN.md — Sistema de diseño de Vessel

> Fuente de verdad del diseño de Vessel. **Tiene precedencia absoluta** sobre cualquier
> recomendación externa. Antes de tocar UI: leer esto. Los tokens viven en código en
> `Sources/Vessel/Support/Theme.swift` — este documento los explica y fija las reglas de uso.
> Toda la UI y los textos en **español con tildes/ñ/¿¡**, en UTF-8.

---

## 1. Identidad

Vessel es un launcher de juegos de Windows para macOS (Apple Silicon). Estética **premium,
nada simple**, inspirada en [Mythic](https://github.com/MythicApp/Mythic) y en la biblioteca
de **Steam**: materiales/blur, gradientes, sombras, animaciones suaves, hover y microinteracciones.

- **Concepto cromático**: azul profundo / **navy** — barco, océano, profundidad, confianza.
- **Material protagonista**: **Liquid Glass nativo** de SwiftUI (`glassEffect`, macOS 26), con
  degradado a `.ultraThinMaterial` en macOS 15.
- **Minimalismo sin fricción**: el usuario **abre y juega**. Todo lo técnico (Wine, bottles,
  capas gráficas, motores) es **invisible y automático**. Nunca se expone en la vista principal.
  La sidebar son **juegos**, no bottles ni conceptos de Wine.

---

## 2. Paleta (Theme)

| Token | Valor (RGB 0–1) | Uso |
|---|---|---|
| `Theme.accent` | (0.16, 0.55, 1.0) | Acciones primarias, selección, iconos vivos |
| `Theme.accentDeep` | (0.10, 0.36, 0.86) | Fondo de gradientes de acento |
| `Theme.navyTop` | (0.058, 0.094, 0.156) | Navy superior del fondo |
| `Theme.navyDeep` | (0.020, 0.040, 0.086) | Navy inferior (océano profundo) |
| `Theme.surface` | (0.10, 0.145, 0.225) | Superficie de tarjeta sin glass (fallback) |

- **Fondo de la app**: `vesselBackground(tint:)` → degradado `navyTop → navyDeep` + resplandor
  radial superior con el color de la **sección/tienda activa** (branding por tienda).
- **Gradiente de marca**: `Theme.gradient(base)` → `base.opacity(0.98) → accentDeep.opacity(0.92)`.
- **Modo oscuro siempre** (`.preferredColorScheme(.dark)`).
- **Verde "Jugar"** (estilo Steam): `Color(red: 0.34, green: 0.72, blue: 0.36)` — SOLO el botón Jugar.

### Color por tienda (branding del resplandor y acentos)
| Tienda | `tint` |
|---|---|
| Steam | (0.10, 0.55, 0.85) |
| Epic | (0.55 gris claro) |
| GOG | (0.60, 0.25, 0.75) |

---

## 3. Escalas

**Radios** (`Theme.Radius`): `cover 14` (carátulas) · `card 16` (tarjetas) · `control 10`
(botones/campos) · `panel 20` (paneles/hero). Siempre `style: .continuous`.

**Espaciado** (`Theme.Space`): `gameGrid 18` · `section 24` · `page 32`.

---

## 4. Materiales y componentes (usar SIEMPRE estos, no estilos sueltos)

| Necesidad | API canónica | Notas |
|---|---|---|
| Fondo de pantalla | `.vesselBackground(tint:)` | tint = color de la tienda |
| Cristal (paneles, campos, chips) | `.liquidGlass(in:tint:interactive:)` | glassEffect / material |
| Tarjeta premium | `.vesselCard(padding:cornerRadius:tint:)` | envoltura de `liquidGlass` |
| Botón | `.vesselButton(_ prominent:tint:)` | `.glassProminent`/`.glass` (26) o `PremiumButtonStyle` |
| Elevación hover | `.hoverLift(scale:)` | escala + sombra con muelle |

**Reglas:** nunca `.borderedProminent`/`.bordered` sueltos → `vesselButton`. Nunca hardcodear
colores/sombras/blur en una vista → usar Theme y los modificadores. Botón Jugar = `vesselButton(tint: steamGreen)`.

---

## 5. Movimiento

- Transiciones de contenido: `.smooth(duration: 0.32)`; grids: `.snappy(0.28)`; hover:
  `.spring(response: 0.3, dampingFraction: 0.72)`.
- **Respetar `accessibilityReduceMotion`**: si está activo, `animation(nil)` y sin transiciones.
- Microinteracciones: hover en tarjetas (lift), iconos que escalan, cristal interactivo.

---

## 6. Accesibilidad

- Todo elemento pulsable es un `Button` con `accessibilityLabel`.
- `@State`/`@FocusState` privados; `ForEach` con identidad estable (nunca índices).
- Texto legible sobre imágenes: gradiente inferior + sombra.
- Soporte Dynamic Type y reduce-motion.

---

## 7. Arquitectura de navegación (LAYOUT — estilo Steam) ★

Vessel se organiza **como la biblioteca de Steam**. Tres zonas:

```
┌───────────────────────────────────────────────────────────────────────┐
│ TOOLBAR/HEADER:  [◉ Steam] [◉ Epic] [◉ GOG]  ················  [• Más] │  ← cambio de TIENDA
├──────────────────────┬────────────────────────────────────────────────┤
│ SIDEBAR (lista)      │  DETALLE (principal)                            │
│  ┌────────────────┐  │                                                 │
│  │ 🔍 Buscar…  ⤓ ▾ │  │   • Si hay juego seleccionado → ficha (hero +   │
│  └────────────────┘  │     botón JUGAR + última sesión/tiempo + compat)│
│  ▸ Juego A (instal.) │   • Si no → "home": grid de carátulas           │
│  ▸ Juego B           │     (INSTALADOS PRIMERO, como Steam)            │
│  ▸ Juego C           │                                                 │
│  …lista buscable     │                                                 │
└──────────────────────┴────────────────────────────────────────────────┘
```

**Reglas del layout:**
1. **El cambio de tienda vive en el HEADER** (no en la sidebar): iconos con el **logo oficial**
   de cada tienda (Steam/Epic/GOG), con estado seleccionado (cristal tintado con `tint` de la tienda).
2. **La sidebar izquierda es la LISTA DE JUEGOS** de la tienda activa, con **búsqueda** y
   **filtro** (Todos/Instalados/Por instalar) + favoritos. Filas compactas: mini-carátula +
   título + estado. **Instalados primero**, luego orden por nombre/recientes.
3. **El panel principal** muestra la **ficha del juego** seleccionado (banner hero integrado,
   botón **Jugar** grande verde, ÚLTIMA SESIÓN / TIEMPO DE JUEGO con iconos, badge de
   compatibilidad, ajustes) o, si no hay selección, el **grid "home"** de carátulas verticales.
4. **Solo 3 tiendas**: Steam, Epic, GOG. (Amazon y Battle.net retiradas.)
5. La ficha NO es un `.sheet` modal flotante: es una **vista integrada** en el panel principal.

**Componentes (en `Views/StoreLibraryView.swift`, reutilizados por las 3 tiendas):**
- `StoreGame` — modelo genérico de juego (id, title, coverURL, heroURL, steamAppId, installed,
  lastPlayed, playtimeMinutes, installPath).
- `StoreLibraryView` — **coordinador de dos paneles** (lista + detalle/grid). Posee búsqueda,
  orden, filtro, favoritos y selección. Recibe `(store, games, callbacks)`; cada tienda mapea sus
  datos a `[StoreGame]`. **Instalados primero** en `filtered`.
- `StoreGameRow` — fila de la lista lateral (mini-carátula 2:3 + título + chip de estado).
- `StoreGameCard` — carátula vertical 2:3 para el grid "home".
- `GameDetailView` — ficha estilo Steam (hero + Jugar + stats + compat badge + ajustes).
- `StoreSwitcher` — control del header con los logos de tienda (en `ContentView`).

**Estado / datos:**
- `ContentView` posee `selectedStore: StoreKind` y monta la tienda activa + el `StoreSwitcher`.
- Cada `XxxStoreView` (`SteamStoreView`/`EpicStoreView`/`GogStoreView`) posee su servicio
  (login + biblioteca) y renderiza `StoreLibraryView` con sus juegos y callbacks. Si no hay sesión,
  muestra su pantalla de conexión.
- Selección de juego: `@State selectedGame` dentro de `StoreLibraryView` (lista ↔ detalle).
- Singletons (`BottleStore.shared`, `LogStore.shared`, `CompatService.shared`) por referencia
  directa; servicios con ciclo de pantalla (`WineManager`, `DependencyManager`) como `@State`.

---

## 8. Compatibilidad (badges)

Rating estilo ProtonDB en la ficha (de `CompatProfile.Rating`): Platino (azul claro),
Oro (dorado), Plata (gris), Bronce (cobre), No funciona (rojo). `verified` muestra sello;
no verificado muestra chip "sin verificar". Ver `vessel-sistema-compatibilidad`.

**Privacidad (valor de producto, no negociable):** los reportes de compatibilidad son
**anónimos** (solo juego + sistema técnico + notas; nunca usuario/correo/equipo). En Ajustes
del juego: botones "Reportar en GitHub" y "Copiar (anónimo)" + nota con `lock.shield`. En
Ajustes → Privacidad: toggle para desactivar la auto-actualización y funcionar 100% local.
Vessel no envía telemetría; nada se sube automáticamente.

---

## 9. Logos de tienda

PNG oficiales en `Resources/StoreLogos/store-{steam,epic,gog}.png`, cacheados por `StoreLogo`.
`StoreLogoTile` = insignia hero (logo sobre gradiente del `tint` + borde + sombra de color).
Fallback a SF Symbol si falta el PNG.

---

## 10. No hacer

- ❌ Exponer Wine/bottles/motores/capas en la UI principal.
- ❌ Botones/efectos planos o `.bordered*` sueltos.
- ❌ Hardcodear color/blur/sombra fuera de Theme.
- ❌ Fichas como modales flotantes desbordados.
- ❌ Romper reduce-motion. ❌ Texto sin tildes/ASCII.
