# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⭐ Reglas PRINCIPALES del proyecto (inviolables)

1. **Stack tecnológico SIEMPRE a la última versión.** Revisar y mantener actualizado todo el stack (Package.swift y dependencias, motores Wine, capas DXVK/DXMT/GPTK/Goldberg/SteamCMD/Mythic Engine, Swift/SDK), **sin romper nada** y **validando que funciona** tras cada actualización. EXCEPCIÓN: versiones fijadas a propósito por compatibilidad (DXVK `1.10.3`, DXMT `0.80` — ver más abajo); no actualizarlas a ciegas.
2. **Estética PREMIUM, nada simple.** La UI debe inspirarse en [MythicApp/Mythic](https://github.com/MythicApp/Mythic): materiales/blur, gradientes, sombras, animaciones y transiciones suaves, estados hover, microinteracciones. Nada de botones/efectos simples. Objetivo: premium, optimizado, amigable y perfecto — pero minimalista y sin fricción para el usuario (el concepto de bottle/Wine es invisible; la sidebar son TIENDAS, no bottles).

## Qué es Vessel

App nativa de macOS (SwiftUI, Apple Silicon) que **envuelve Wine** para ejecutar juegos de Windows y Steam. No reimplementa Wine: gestiona *bottles* (prefijos de Wine), descarga motores Wine portables, configura las capas de traducción gráfica (DXMT/DXVK) y lanza ejecutables. El paralelo conceptual es CrossOver / Whisky / Mythic, escrito en Swift moderno.

- SwiftPM puro, **sin `.xcodeproj`**. Toolchain Swift 6, target `macOS 15+`, solo arm64.
- Bundle ID: `com.swondev.vessel`. El autor/propietario del proyecto es **SwonDev**.

> ⛔ **REGLA INVIOLABLE — identidad del proyecto:** el proyecto es de **SwonDev**. El Bundle ID,
> el subsystem de logs y CUALQUIER identificador es `com.swondev.vessel`. **NUNCA** usar un
> dominio/correo/empresa AJENO al proyecto, ni **inferir identificadores del entorno**
> (red WiFi corporativa, correo del sistema, etc.). Si el contexto sugiere otro dominio (p. ej. por
> estar en una red de una empresa), **ignorarlo**: el identificador es SIEMPRE `com.swondev.vessel`.

## Comandos

```bash
# Compilar + empaquetar .app + firmar ad-hoc + abrir (flujo principal de desarrollo)
./build_and_run.sh

# Compilar a secas
swift build                 # debug
swift build -c release      # release (lo que usa build_and_run.sh)

# Tests (XCTest, target VesselTests)
swift test
swift test --filter DependencyManagerTests/testSelectWineAssetPrefersWineDevel   # un test concreto

# Tests "live" que descargan Wine / instalan Steam de verdad (lentos, se saltan por defecto)
VESSEL_RUN_LIVE_INSTALL_TEST=1 swift test --filter DependencyManagerTests/testLiveInstall
VESSEL_RUN_LIVE_STEAM_TEST=1   swift test --filter DependencyManagerTests/testLiveSteam
```

`build_and_run.sh` compila en release, monta el `.app` a mano (genera `Info.plist`, copia `Resources/icon.icns` y los wrappers `*.exe`), firma ad-hoc (`codesign --sign -`) y abre la app. No hay paso de Xcode.

## Arquitectura

### Estado y persistencia (⚠️ el README está desactualizado)

El README menciona SwiftData, pero el código **ya no lo usa**. La persistencia real:

- **`BottleStore.shared`** (`Models/Bottle.swift`) — singleton `@MainActor @Observable` que serializa los `Bottle`/`GameInstall` a **JSON en disco** (`~/Library/Application Support/Vessel/bottles.json`). Se migró fuera de SwiftData a propósito para evitar errores de schema en desarrollo. `Bottle` y `GameInstall` son `struct Codable`, no `@Model`.
- **`LogStore.shared`** — singleton `@Observable` de logging; mantiene las últimas 1000 entradas en memoria y vuelca a `~/Library/Logs/Vessel/vessel.log` + `os.Logger`. Para registrar usa `LogStore.shared.log("…", level:)`.

Patrón de inyección en las vistas: los **singletons** (`BottleStore.shared`, `LogStore.shared`) se referencian directamente; los servicios **con ciclo de vida de pantalla** (`WineManager`, `DependencyManager`) se crean como `@State private var x = WineManager()` dentro de la vista que los necesita. No hay inyección por `@Environment`.

### Capa de servicios (`Sources/Vessel/Services/`)

Convención general: servicios de orquestación son `@MainActor @Observable final class`; los clientes de red puros son `actor` (`SteamGridDBClient`, `ProtonDBClient`). Casi todo el trabajo real es **lanzar procesos** (`Foundation.Process` + `Pipe`) con el entorno `WINEPREFIX`/`WINEDEBUG`/`WINEDLLOVERRIDES` adecuado.

- **`WineManager`** — el núcleo. Orquesta crear bottle (`wineboot --init`), configurar capas gráficas, instalar/lanzar Steam y lanzar juegos. Toda la lógica delicada de Wine vive aquí.
- **`WineEngineLocator`** — resuelve qué binario Wine usar. Detecta el motor portable de Vessel y motores del sistema (Homebrew, GPTK, CrossOver). Define los nombres de motor.
- **`DependencyManager`** — descarga e instala el Wine portable, comprueba GPTK/Rosetta/DXMT/DXVK. Descarga tarballs, los extrae, **quita quarantine** (`xattr -d com.apple.quarantine`) y **firma ad-hoc** (`codesign --sign -`) todos los Mach-O.
- **`DXMTManager` / `DXVKManager`** — instalan las DLLs de traducción en `system32`/`syswow64` del bottle y registran `WINEDLLOVERRIDES` vía `wine reg add`. **Versiones fijadas a propósito**: DXVK `1.10.3` (DXVK 2.x exige `geometryShader`, que el MoltenVK incluido no soporta), DXMT `0.80`.
- **`SteamWebHelperWrapperInstaller` / `GameWrapperInstaller`** — instalan los wrappers PE32+ (ver abajo) dentro del bottle.
- **`SteamLaunchOptionsManager`** — edita `localconfig.vdf` para inyectar Launch Options por juego (idempotente, con backup `.vessel-bak`).
- **`SteamLibraryImporter`** — descubre librerías Steam locales parseando `appmanifest_*.acf`.
- **`SteamGridDBClient` / `ProtonDBClient` / `EngineManager` / `Updater`** — clientes de carátulas, compatibilidad ProtonDB, gestión de motores y comprobación de releases en GitHub.

### Arquitectura de DOBLE MOTOR (lo más importante de entender)

Validado empíricamente en Apple Silicon: **ningún motor Wine libre hace bien las dos cosas**, así que Vessel usa **dos motores según la tarea**, sobre el mismo prefijo. La selección está en `WineEngineLocator` (`clientWineBinary()` / `gameWineBinary()`) y la consume `WineManager` (`resolveClientWine` / `resolveGameWine`).

| | Cliente Steam (Chromium/webhelper) | Juegos D3D11 (Unity FL 11_0) |
|---|---|---|
| **`wine-osx64`** (Gcenx, Wine 11.x completo) | ✅ funciona | ❌ Wine sin símbolos `macdrv` que DXMT necesita |
| **`wine-dxmt`** (3Shain, con `macdrv` parcheado) | ❌ el proceso GPU de CEF crashea → `0x3008` | ✅ DXMT→Metal |

- **Cliente de Steam y apps generales → `wine-osx64` (Gcenx).** `WineManager.launchSteam`/`installSteam` usan `resolveClientWine`. No necesita DXMT/DXVK: el webhelper renderiza por CPU vía el wrapper.
- **Juegos D3D11 → `wine-dxmt`.** `WineManager.launch(game)` usa `resolveGameWine`.

**Fix raíz de juegos (no obvio):** el `wine-dxmt` de 3Shain **NO trae DXMT en su `d3d11` builtin** — su `d3d11` builtin es `wined3d`. Solo aporta los símbolos `macdrv` + `winemetal.so`. Hay que **integrar la `d3d11` de DXMT en el builtin del motor** (`lib/wine/x86_64-windows`), cosa que hace `DXMTManager.installIntoEngine()` (idempotente, una vez por motor; llamado desde `DependencyManager.installWinePortable` y, como auto-reparación, desde `WineManager.ensureGameEngineDXMT`). Sin esto los juegos usan wined3d→OpenGL y fallan con `InitializeEngineGraphics failed`. DXVK **no** sirve para FL 11_0 (Metal no tiene geometry shaders → feature level 0/insuficiente).

`DependencyManager.installWinePortable()` instala **ambos** motores (Gcenx + wine-dxmt) e integra DXMT en el de juegos. Todo auto-descargable de cero.

**Modelo de lanzamiento (como Heroic/Mythic):** Steam es para tienda/biblioteca/instalar; **Vessel lanza los juegos él mismo** con `wine-dxmt` (no se confía en el botón "Play" de Steam, que usaría Gcenx y fallaría). Los juegos se importan a la lista de Vessel (`SteamLibraryImporter`) y se juegan desde el `GameCard`.

### Hacer arrancar el cliente de Steam (3 piezas imprescindibles)

El cliente de Steam (Gcenx) requiere TODO esto junto, o falla de formas distintas:

1. **`steam.cfg` con `BootStrapperInhibitAll=enable`** (`WineManager.ensureSteamConfig`). Sin esto, cuando Steam se relanza solo (sin `-noverifyfiles`) verifica sus ficheros, detecta el wrapper como "corrupto", intenta autoactualizar el cliente, la descarga falla bajo Wine (`http error 0`) y queda ladrillado → **`Failed to load steamui.dll`**.
2. **Limpiar la caché de CEF/htmlcache** antes de lanzar (`WineManager.cleanCEFCache`). Tras crashes del proceso GPU de Chromium la caché se corrompe → **error de transporte `0x3008`**.
3. **Wrapper de `steamwebhelper`** (`SteamWebHelperWrapperInstaller`): un PE32+ (`Resources/steamwebhelper-wrapper.exe`, fuente C en `Resources/wrapper/`) que se hace pasar por `steamwebhelper.exe` y relanza el real con `--disable-gpu --single-process` → render por CPU. El webhelper no puede usar GPU bajo Wine en macOS.

`WineManager` además mata procesos zombi (`wineserver -k` + `pkill -9 -f <prefix>`) y quita el auto-arranque de Steam del registro (`HKCU\…\Run`) en cada lanzamiento. Flags en `WineManager.steamLaunchArguments` (los comentarios explican cuáles están prohibidos y por qué).

> **`game-wrapper.c` está OBSOLETO** en el modelo de doble motor: los juegos los lanza Vessel directamente con `wine-dxmt` (DXMT builtin), sin necesidad de envolver el `.exe` ni inyectar overrides. No se instala desde `launchSteam`.

### UI (`Sources/Vessel/Views/`)

`VesselApp` (`@main`) monta un único `WindowGroup` con `ContentView` (un `NavigationSplitView`: `BottleSidebar` + `BottleDetailView`). Los comandos de menú (`Crear bottle`, `Importar de Steam`, `Ajustes`, `Logs`, `Acerca de`) se emiten con **`NotificationCenter`** usando los `Notification.Name` declarados al final de `VesselApp.swift`; las vistas se suscriben a ellos. El onboarding se muestra una vez (`@AppStorage("vessel.onboardingCompleted")`).

### Rutas

Todas las rutas en disco se centralizan en `VesselPaths` (`Support/Constants.swift`): `~/Library/Application Support/Vessel/{Bottles,Engines,Cache}`. `VesselApp.init()` llama a `ensureDirectories()` al arrancar. Todo es auto-gestionado dentro de App Support; Vessel nunca escribe en `/Applications` ni toca el Wine del sistema.

## Convenciones

- **UI y textos en español** (con tildes, eñes y signos `¿¡`). Mensajes de error, logs y labels van en español.
- Versiones de DXVK/DXMT y URLs de motores están **fijadas a propósito** en el código; no las "actualices" a la última sin entender la nota de compatibilidad (MoltenVK / geometryShader) que las acompaña.
- Los binarios Wine descargados deben pasar siempre por *quitar quarantine* + *firma ad-hoc* o macOS los bloquea.
- Los tests existentes usan **XCTest**. Los que tocan red/instalación real van detrás de las env vars `VESSEL_RUN_LIVE_*` para no correr en CI normal.
