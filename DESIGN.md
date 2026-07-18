---
version: alpha
name: Vessel — Steam parity, native macOS
description: Sistema visual navy y Liquid Glass nativo para una biblioteca unificada de juegos de Windows en macOS.
colors:
  primary: "#298CFF"
  primary-deep: "#1A5CDB"
  background-top: "#0F1828"
  background-deep: "#050A16"
  surface: "#1A2539"
  on-surface: "#FFFFFF"
  on-surface-secondary: "#B3BAC7"
  play: "#57B85C"
  destructive: "#D96652"
  steam: "#1A8CD9"
  epic: "#8C8C8C"
  gog: "#9940BF"
  drm-free: "#CC2B2E"
typography:
  title-lg:
    fontFamily: SF Pro
    fontSize: 36px
    fontWeight: 800
    lineHeight: 1.1
    letterSpacing: -0.02em
  title-md:
    fontFamily: SF Pro
    fontSize: 24px
    fontWeight: 700
    lineHeight: 1.2
  headline:
    fontFamily: SF Pro
    fontSize: 17px
    fontWeight: 600
    lineHeight: 1.25
  body:
    fontFamily: SF Pro
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.45
  label:
    fontFamily: SF Pro
    fontSize: 12px
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: 0.02em
  metadata:
    fontFamily: SF Mono
    fontSize: 11px
    fontWeight: 500
    lineHeight: 1.2
rounded:
  control: 10px
  cover: 14px
  card: 16px
  panel: 20px
  full: 9999px
spacing:
  xs: 4px
  sm: 8px
  md: 12px
  card-gap: 18px
  section: 24px
  page: 32px
components:
  app-background:
    backgroundColor: "{colors.background-deep}"
  header-background:
    backgroundColor: "{colors.background-top}"
  accent-depth:
    backgroundColor: "{colors.primary-deep}"
  glass-surface:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.card}"
    padding: "{spacing.md}"
  button-primary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.label}"
    rounded: "{rounded.full}"
    padding: 10px
  game-cover:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.cover}"
  sidebar-row:
    backgroundColor: "{colors.background-deep}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "{spacing.sm}"
  metadata-secondary:
    textColor: "{colors.on-surface-secondary}"
  state-playing:
    textColor: "{colors.play}"
  state-destructive:
    textColor: "{colors.destructive}"
  platform-steam:
    backgroundColor: "{colors.steam}"
  platform-epic:
    backgroundColor: "{colors.epic}"
  platform-gog:
    backgroundColor: "{colors.gog}"
  platform-drm-free:
    backgroundColor: "{colors.drm-free}"
---

# DESIGN.md — Sistema de diseño de Vessel

## Overview

Vessel es una biblioteca unificada que permite instalar y ejecutar juegos de Windows en Apple
Silicon sin exponer Wine, prefijos, motores ni capas gráficas en la experiencia principal. Debe
sentirse como una aplicación macOS premium, rápida y confiable: navy oceánico, Liquid Glass nativo,
tipografía del sistema y una densidad informativa controlada.

**Steam es el patrón de referencia para la arquitectura de información, la jerarquía, los estados y
la fluidez de una biblioteca de juegos. No es una plantilla que deba copiarse literalmente.** Cada
patrón se adapta al propósito de Vessel y a las convenciones nativas de macOS:

- cambio de plataforma en la cabecera;
- lista compacta y buscable de juegos en la barra lateral;
- portada con estanterías, filtros rápidos y carátulas;
- ficha integrada con hero, acción primaria, actividad, logros, DLC y compatibilidad;
- descargas visibles y estados persistentes, sin llenar la interfaz de controles técnicos.

La personalidad es minimalista pero no vacía. La complejidad aparece de forma progresiva cuando el
usuario la necesita. La aplicación tiene tres tiendas —Steam, Epic Games y GOG— más una biblioteca
DRM‑free de primera clase. Las cuatro comparten la misma gramática visual y funcional.

Este documento tiene precedencia sobre recomendaciones externas. Los tokens ejecutables viven en
`Sources/Vessel/Support/Theme.swift`. Toda la UI y el contenido se escriben en español UTF-8.

## Colors

La base es un océano navy continuo desde la barra de título hasta el borde inferior de la ventana.
El color de la plataforma activa aporta orientación, no superficies saturadas.

- **Primary (#298CFF):** acciones y selección globales de Vessel.
- **Primary Deep (#1A5CDB):** profundidad del gradiente de marca.
- **Background Top (#0F1828) / Deep (#050A16):** lienzo de la aplicación.
- **Surface (#1A2539):** respaldo opaco para accesibilidad y contextos sin cristal.
- **On Surface (#FFFFFF) / Secondary (#B3BAC7):** texto principal y metadatos.
- **Play (#57B85C):** reservado para la acción «Jugar» y estados equivalentes de ejecución.
- **Platform accents:** Steam `#1A8CD9`, Epic `#8C8C8C`, GOG `#9940BF`, DRM‑free `#CC2B2E`.

El cristal es siempre neutro. El color aparece como velo de baja opacidad, borde, icono o indicador.
No se aplica un tinte fuerte a `glassEffect`, porque convierte la refracción en un relleno visualmente
plano. El modo oscuro es la presentación canónica.

## Typography

Vessel usa las familias del sistema para integrarse con macOS y heredar sus métricas de accesibilidad.
Se prefieren los estilos semánticos de SwiftUI (`largeTitle`, `title2`, `headline`, `body`, `caption`)
frente a tamaños fijos; los tamaños del front matter documentan la jerarquía visual esperada.

- Los títulos de juego son el foco principal y usan peso alto solo sobre hero o cabeceras.
- El cuerpo mantiene una lectura calmada; no se emplean bloques enteros en mayúsculas.
- Etiquetas y metadatos son compactos. Cifras de progreso y tiempos pueden usar diseño monoespaciado.
- La jerarquía se consigue primero con tamaño, peso y espacio; el color nunca sustituye al texto.

## Layout

La ventana se organiza siguiendo el modelo mental de la biblioteca de Steam, adaptado a macOS:

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Header: [Steam] [Epic] [GOG] [DRM‑free]                 [Perfil] [Más]│
├──────────────────────┬───────────────────────────────────────────────┤
│ Lista de juegos      │ Ficha integrada o portada de biblioteca      │
│ Buscar · filtrar     │ Hero · Jugar · actividad · contenido         │
│ Colecciones          │ Estanterías · carátulas · estados            │
└──────────────────────┴───────────────────────────────────────────────┘
```

- La cabecera conserva el control de plataforma y las acciones globales; la barra lateral contiene
  juegos, búsqueda, orden, filtros y colecciones, nunca plataformas ni conceptos de Wine.
- El panel principal muestra la ficha integrada del juego seleccionado. Sin selección, funciona como
  portada con «Jugados recientemente», ámbitos rápidos y un grid adaptable.
- La ficha nunca es una sheet. Las sheets quedan para tareas breves y autocontenidas: autenticación,
  edición, confirmación o ajustes.
- El contenido se desplaza por debajo de la cabecera translúcida para crear el scroll edge nativo.
- El hero de cada ficha usa parallax sutil: la ilustración se desplaza más despacio que el título y
  el contenido. El mismo efecto se aplica a Steam, Epic, GOG y DRM‑free desde la ficha común.
- Radios, espaciados y densidad usan los tokens. Los valores locales solo se aceptan para geometrías
  inherentes a una carátula, logo o icono.
- Los controles secundarios deben reagruparse en menús nativos cuando el ancho no permita mantener
  la jerarquía, en vez de recortar etiquetas o desbordar una fila.

## Elevation & Depth

La profundidad procede de capas funcionales, no de acumular tarjetas:

1. fondo navy con resplandor muy sutil de la plataforma activa;
2. contenido y carátulas;
3. Liquid Glass para navegación, controles flotantes y superficies que realmente necesitan separar
   contexto;
4. popovers, sheets y overlays del sistema para tareas temporales.

En macOS 26 se usa `glassEffect(.regular)` y `GlassEffectContainer` para grupos de cristales próximos.
En macOS 15 se usa `.ultraThinMaterial`. Con «Reducir transparencia» se reemplazan ambos por una
superficie navy opaca con borde legible. Las sombras son negras, suaves y contenidas; no se usan auras
de color en controles. Nunca se coloca cristal sobre cristal.

## Shapes

Todas las esquinas rectangulares son continuas. La escala canónica es:

- 10 px para campos, filas y controles;
- 14 px para carátulas;
- 16 px para tarjetas;
- 20 px para paneles grandes y heroes;
- cápsula completa para scopes, botones principales y estados breves.

No se mezclan radios arbitrarios dentro de la misma familia de componentes. Los logos pueden conservar
su geometría de marca cuando sea necesaria para reconocer la plataforma.

## Components

### Primitivas canónicas

- `vesselBackground(tint:)`: fondo navy y orientación cromática por plataforma.
- `liquidGlass(in:interactive:)`: cristal neutro, fallback material y modo opaco accesible.
- `vesselGlassContainer(spacing:)`: agrupación nativa de efectos próximos en macOS 26.
- `vesselCard(padding:cornerRadius:)`: tarjeta de cristal coherente.
- `vesselButton(_:tint:)`: acción primaria o secundaria con cristal interactivo.
- `hoverLift(scale:)`: elevación de puntero que respeta «Reducir movimiento».

### Biblioteca y ficha

- `StoreSwitcher` cambia entre las tres tiendas y DRM‑free sin alterar la estructura de la ventana.
- `StoreLibraryView` es el coordinador común; las plataformas solo adaptan datos y callbacks.
- `StoreGameRow` prioriza título, instalación, actividad y selección con densidad similar a Steam.
- `StoreGameCard` usa carátula 2:3, estado legible y acciones progresivas.
- `GameDetailView` integra hero, Jugar/Instalar, última sesión, tiempo, logros, DLC, capturas,
  compatibilidad y ajustes. Su hero tiene profundidad parallax; la acción primaria domina y las
  secundarias no compiten con ella.
- El centro de descargas solo aparece durante operaciones activas y conserva el progreso al navegar.

### Estados y accesibilidad

Todas las vistas incluyen loading, vacío, error, deshabilitado, hover, focus y feedback de operación
cuando corresponda. Cada control usa `Button`, `Menu` o componente nativo con etiqueta accesible. Los
tooltips se reservan para controles y pueden desactivarse sin eliminar la pista de VoiceOver.

Las animaciones canónicas son `smooth(0.32)`, `snappy(0.28)` y spring de hover. Siempre se anulan con
`accessibilityReduceMotion`; se conserva como máximo un cambio instantáneo de sombra o luminosidad.

## Do's and Don'ts

- Haz que Steam guíe la completitud, la jerarquía y los flujos de biblioteca.
- Haz que macOS guíe los controles, menús, accesibilidad, teclado, foco y Liquid Glass.
- Mantén una única acción primaria inequívoca por contexto.
- Usa profundidad y movimiento para explicar capas —parallax del hero, scroll edge y previews—, no
  como decoración permanente; todos los efectos deben tener una alternativa estática.
- Reutiliza la biblioteca común para alcanzar paridad entre Steam, Epic, GOG y DRM‑free.
- Conserva la interfaz limpia mediante divulgación progresiva, estados efímeros y menús adaptables.
- Mantén contraste WCAG AA y prueba «Reducir movimiento» y «Reducir transparencia».
- No copies literalmente la piel web de Steam ni sus densidades que no encajen en macOS.
- No expongas Wine, prefijos, motores o capas gráficas en la biblioteca principal.
- No uses `.bordered*`, materiales o colores hardcodeados cuando exista una primitiva de Theme.
- No tintes el cristal con colores fuertes, no uses sombras de color y no apiles cristal sobre cristal.
- No conviertas cada bloque en una tarjeta; el cristal debe indicar una capa funcional.
- No recortes acciones o textos en ventanas estrechas: reordena, oculta metadatos o agrupa en un menú.
- No introduzcas animación que ignore las preferencias de accesibilidad.
