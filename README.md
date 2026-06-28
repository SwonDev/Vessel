# Vessel

> Wrapper nativo de macOS para ejecutar juegos de Windows (incluido Steam) en Apple Silicon.
> Hecho en Swift 6 + SwiftUI + SwiftData, sin dependencias externas en runtime.

## Estado actual

**MVP funcional** — Crea bottles (prefijos de Wine), instala Steam dentro, lanza ejecutables `.exe` y los organiza en una biblioteca.

## Características

- 🇪🇸 **SwiftUI nativo** con `NavigationSplitView`, SwiftData, `@Observable` y `@Bindable`
- 🍷 **Detección automática** de Wine Stable (Homebrew), CrossOver, Game Porting Toolkit
- 📦 **Bottles** (prefijos de Wine) aislados por juego/configuración
- 🎮 **Instalador de Steam** integrado (descarga `SteamSetup.exe` desde el CDN de Valve)
- 🖼️ **DXVK / DXMT / GPTK** configurables por bottle
- 📂 **Selector de `.exe`** para añadir juegos manualmente
- 🪟 **Apertura de bottle en Finder** con un click
- 🔒 **Sandbox-friendly** — todo se guarda en `~/Library/Application Support/Vessel`

## Requisitos

- macOS 15.0+ (Sequoia) o macOS 26 (Tahoe)
- Chip Apple Silicon (M1 o superior)
- Homebrew con Wine: `brew install --cask wine-stable`
- ~3 GB de espacio por bottle

## Compilar y ejecutar

```bash
cd ~/Documents/vessel-mac
chmod +x build_and_run.sh
./build_and_run.sh
```

El script compila con `swift build -c release`, empaqueta como `.app`, firma ad-hoc y abre la app.

## Estructura

```
vessel-mac/
├── Package.swift                 # SwiftPM, target único
├── build_and_run.sh              # Build + package + launch
├── README.md
└── Sources/Vessel/
    ├── VesselApp.swift           # @main, ModelContainer, Commands
    ├── Models/
    │   └── Bottle.swift          # @Model SwiftData (Bottle, GameInstall)
    ├── Services/
    │   └── WineManager.swift     # @Observable, detección + creación + launch
    ├── Support/
    │   └── Constants.swift       # Rutas, URLs
    └── Views/
        ├── ContentView.swift     # NavigationSplitView raíz
        ├── BottleSidebar.swift   # Sidebar con lista de bottles
        ├── BottleDetailView.swift # Detalle + acciones + juegos
        ├── CreateBottleView.swift # Sheet de creación
        └── SteamInstallerView.swift # Sheet instalador Steam
```

## Próximos pasos

- [ ] Mostrar `ProtonDB` por juego
- [ ] Instalar Epic Games, GOG, Battle.net
- [ ] Modo Game Porting Toolkit real (descarga oficial)
- [ ] Integración con `SteamGridDB` para portadas
- [ ] Auto-update via Sparkle
- [ ] Firma con Developer ID y notarización

## Filosofía

Vessel no reinventa Wine: lo envuelve. Toda la compatibilidad real la pone Wine/GPTK, nosotros ponemos la UI nativa y la gestión de bottles. Es el mismo enfoque que CrossOver, Mythic y Whisky, pero escrito en Swift moderno y sin las complicaciones de mantener un fork privado de Wine.

## Licencia

GPL-3.0. Basado en el trabajo de Wine, CrossOver, DXVK y DXMT — todos open source.
