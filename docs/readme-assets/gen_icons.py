#!/usr/bin/env python3
# Generador del set de iconos "Liquid Glass" de Vessel para el README.
# Teselas de cristal navy (mismo lenguaje que la app) + glifo de acento estilo SF Symbols.
# Salida: docs/readme-assets/icons/*.svg  (vectoriales, se referencian directos en el README).

import os

OUT = os.path.join(os.path.dirname(__file__), "icons")
os.makedirs(OUT, exist_ok=True)

# --- Base de la tesela de cristal (coherente con Theme.swift / DESIGN.md) ---
def tile(name, glyph, accent_a="#5AA6FF", accent_b="#2E7BE6", glow="#2E7BE6"):
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96" role="img" aria-label="{name}">
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#17263F"/>
      <stop offset="1" stop-color="#0A1524"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.14"/>
      <stop offset="0.5" stop-color="#ffffff" stop-opacity="0.03"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.44" r="0.55">
      <stop offset="0" stop-color="{glow}" stop-opacity="0.42"/>
      <stop offset="1" stop-color="{glow}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="ink" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{accent_a}"/>
      <stop offset="1" stop-color="{accent_b}"/>
    </linearGradient>
  </defs>
  <rect x="4" y="4" width="88" height="88" rx="23" fill="url(#tile)"/>
  <rect x="4" y="4" width="88" height="88" rx="23" fill="url(#glow)"/>
  <rect x="4.75" y="4.75" width="86.5" height="86.5" rx="22.25" fill="none" stroke="#8FB6FF" stroke-opacity="0.20" stroke-width="1.5"/>
  <rect x="6" y="6" width="84" height="42" rx="20" fill="url(#sheen)"/>
  <g fill="none" stroke="url(#ink)" stroke-width="4.2" stroke-linecap="round" stroke-linejoin="round">
{glyph}
  </g>
</svg>
'''
    with open(os.path.join(OUT, f"{name}.svg"), "w") as f:
        f.write(svg)

# ---------------- GLIFOS (centrados en 48,48, área ~26..70) ----------------

# Biblioteca unificada: rejilla 2x2 (colección de apps/tiendas)
G_LIBRARY = '''    <rect x="27" y="27" width="18" height="18" rx="4.5"/>
    <rect x="51" y="27" width="18" height="18" rx="4.5"/>
    <rect x="27" y="51" width="18" height="18" rx="4.5"/>
    <rect x="51" y="51" width="18" height="18" rx="4.5"/>'''

# Motor óptimo: engranaje real (anillo + dientes en la corona + buje)
G_ENGINE = '''    <circle cx="48" cy="48" r="11"/>
    <circle cx="48" cy="48" r="3.4" fill="url(#ink)" stroke="none"/>
    <path d="M59.5 48 L64.5 48 M56.13 56.13 L59.67 59.67 M48 59.5 L48 64.5 M39.87 56.13 L36.33 59.67 M36.5 48 L31.5 48 M39.87 39.87 L36.33 36.33 M48 36.5 L48 31.5 M56.13 39.87 L59.67 36.33"/>'''

# UX invisible: varita mágica + chispas (abre y juega)
G_MAGIC = '''    <path d="M33 65 L58 40"/>
    <path d="M62 30 l1.6 4.4 4.4 1.6 -4.4 1.6 -1.6 4.4 -1.6 -4.4 -4.4 -1.6 4.4 -1.6 Z" stroke-width="3"/>
    <path d="M40 30 l0.9 2.6 2.6 0.9 -2.6 0.9 -0.9 2.6 -0.9 -2.6 -2.6 -0.9 2.6 -0.9 Z" stroke-width="2.6"/>'''

# UI premium: destello de 4 puntas (brillo/estética)
G_PREMIUM = '''    <path d="M48 26 C50 40 52 44 66 48 C52 52 50 56 48 70 C46 56 44 52 30 48 C44 44 46 40 48 26 Z"/>
    <path d="M69 27 l0.9 3 3 0.9 -3 0.9 -0.9 3 -0.9 -3 -3 -0.9 3 -0.9 Z" stroke-width="2.6"/>'''

# Partidas a salvo: nube + check
G_SAVES = '''    <path d="M34 58 a10 10 0 0 1 1.5 -19.9 a13 13 0 0 1 24.6 3.2 a9 9 0 0 1 -1.1 17.7 Z"/>
    <path d="M40 48 l5 5 10 -11" stroke-width="3.6"/>'''

# Auto-actualización: dos flechas circulares
G_UPDATE = '''    <path d="M64 42 a17 17 0 1 0 2.4 12"/>
    <path d="M64 28 v14 h-14"/>'''

# Carátulas: tres pósters verticales 2:3 + estrella
G_COVERS = '''    <rect x="26" y="31" width="13" height="34" rx="3"/>
    <rect x="42" y="31" width="13" height="34" rx="3"/>
    <rect x="58" y="31" width="13" height="34" rx="3"/>'''

# Apple Silicon: chip SoC (cuadrado + pines + núcleo)
G_CHIP = '''    <rect x="32" y="32" width="32" height="32" rx="7"/>
    <rect x="41" y="41" width="14" height="14" rx="3"/>
    <path d="M40 26 v6 M56 26 v6 M40 64 v6 M56 64 v6 M26 40 h6 M26 56 h6 M64 40 h6 M64 56 h6"/>'''

# ---- Iconos de sección ----

# Velero (qué es Vessel) — vela + casco (mismo motivo que el logo)
G_SAIL = '''    <path d="M49 26 L49 60 L31 60 Z"/>
    <path d="M53 36 L67 60 L53 60"/>
    <path d="M27 63 Q48 74 69 63" stroke-width="4.2"/>'''

# Mando (tiendas / jugar)
G_GAMEPAD = '''    <path d="M39 40 h18 a13 13 0 0 1 13 13 a7 7 0 0 1 -13 3.5 h-18 a7 7 0 0 1 -13 -3.5 a13 13 0 0 1 13 -13 Z"/>
    <path d="M33 49 v8 M29 53 h8" stroke-width="3.4"/>
    <circle cx="60" cy="50" r="2.4" fill="url(#ink)" stroke="none"/>
    <circle cx="64" cy="55" r="2.4" fill="url(#ink)" stroke="none"/>'''

# Foto / capturas
G_PHOTO = '''    <rect x="27" y="31" width="42" height="34" rx="5"/>
    <circle cx="38" cy="42" r="3.6"/>
    <path d="M29 60 l12 -12 8 8 6 -6 10 10" stroke-width="3.6"/>'''

# Terminal / instalación
G_TERMINAL = '''    <rect x="26" y="30" width="44" height="36" rx="6"/>
    <path d="M34 44 l6 5 -6 5" stroke-width="3.4"/>
    <path d="M46 54 h12" stroke-width="3.4"/>'''

# Flujo / cómo funciona (nodos + ruta)
G_FLOW = '''    <circle cx="33" cy="34" r="5"/>
    <circle cx="63" cy="48" r="5"/>
    <circle cx="33" cy="62" r="5"/>
    <path d="M38 36 Q54 40 58 45 M38 60 Q54 56 58 51" stroke-width="3.4"/>'''

# Checklist / requisitos
G_CHECKLIST = '''    <path d="M29 35 l4 4 6 -7" stroke-width="3.4"/>
    <path d="M29 51 l4 4 6 -7" stroke-width="3.4"/>
    <path d="M48 36 h20 M48 52 h20" stroke-width="3.6"/>'''

# Capas / stack
G_LAYERS = '''    <path d="M48 26 L69 38 L48 50 L27 38 Z"/>
    <path d="M27 48 L48 60 L69 48" stroke-width="3.6"/>'''

# Balanza / licencia
G_SCALE = '''    <path d="M48 28 v40 M34 68 h28" stroke-width="3.6"/>
    <path d="M30 38 h36" stroke-width="3.6"/>
    <path d="M24 52 a6 6 0 0 0 12 0 Z M60 52 a6 6 0 0 0 12 0 Z"/>
    <path d="M30 38 L24 52 M66 38 L72 52" stroke-width="2.8"/>'''

# Corazón (créditos) — línea
G_HEART = '''    <path d="M48 66 C30 54 27 43 34 37 C39 32 46 34 48 40 C50 34 57 32 62 37 C69 43 66 54 48 66 Z"/>'''

icons = {
    "library": G_LIBRARY,
    "engine": G_ENGINE,
    "magic": G_MAGIC,
    "premium": G_PREMIUM,
    "saves": G_SAVES,
    "update": G_UPDATE,
    "covers": G_COVERS,
    "chip": G_CHIP,
    "sail": G_SAIL,
    "gamepad": G_GAMEPAD,
    "photo": G_PHOTO,
    "terminal": G_TERMINAL,
    "flow": G_FLOW,
    "checklist": G_CHECKLIST,
    "layers": G_LAYERS,
    "scale": G_SCALE,
    "heart": G_HEART,
}

for name, glyph in icons.items():
    tile(name, glyph)

print(f"Generados {len(icons)} iconos en {OUT}")
for n in icons:
    print(" -", n + ".svg")
