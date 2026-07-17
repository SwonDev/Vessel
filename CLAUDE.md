# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⭐ Reglas PRINCIPALES del proyecto (inviolables)

1. **Stack tecnológico SIEMPRE a la última versión.** Revisar y mantener actualizado todo el stack (Package.swift y dependencias, motores Wine, capas DXVK/DXMT/GPTK/Goldberg/SteamCMD/Mythic Engine, Swift/SDK), **sin romper nada** y **validando que funciona** tras cada actualización. EXCEPCIÓN: versiones fijadas a propósito por compatibilidad (DXVK `1.10.3`, DXMT `0.80` — ver más abajo); no actualizarlas a ciegas.
2. **Estética PREMIUM, nada simple.** La UI debe inspirarse en [MythicApp/Mythic](https://github.com/MythicApp/Mythic): materiales/blur, gradientes, sombras, animaciones y transiciones suaves, estados hover, microinteracciones. Nada de botones/efectos simples. Objetivo: premium, optimizado, amigable y perfecto — pero minimalista y sin fricción para el usuario (el concepto de bottle/Wine es invisible; la sidebar son TIENDAS, no bottles).
3. **Distribución de motores — dos vías, según licencia y tamaño.** Cuando toques un motor Wine (parche, DLL nueva, builtin), decide DÓNDE va y actualízalo:
   - **Motor base completo → `SwonDev/Vessel-Engines` (release nueva).** SOLO para motores **propios y redistribuibles**: `wine-unified` (WineHQ 11.10 limpio, LGPL) y `wine-full` (build propia de las **fuentes FOSS de CrossOver 26.2.0**, wine-11.0 + CW HACKs, LGPL — release `engine-full-v1`; ver `docs/ENGINE-SOURCE.md` §1b). Si cambias el motor base de forma que un drop-in NO puede parchear (recompilar Wine entero, nuevo builtin, subir de versión de WineHQ), publica una release nueva de Vessel-Engines (`engine-unified-vN`/`engine-full-vN`), sube el `.tar.zst`, y **actualiza la URL en el código** (`DependencyManager`/`WineEngineLocator`). **NUNCA** subas el Wine copiado de un CrossOver.app instalado (hoy `wine-full-crossover-bak`: contiene `winewrapper.exe`, `apple_gptk`, herramientas `cx*` — licencia CodeWeavers) ni `gptk-mythic`: el `.gitignore` los bloquea. La regla práctica para saber cuál es cuál: el `wine-full` redistribuible **no tiene** `lib/wine/x86_64-windows/winewrapper.exe` (ver `WineEngineLocator.isRealCrossOverFullEngine`).
   - **Fix puntual → drop-in en `Resources/engine-*fix/` (dentro del `.app`).** Para cualquier arreglo que se pueda aplicar en caliente sobre un motor ya instalado: `applyCryptoFix` (gnutls/freetype), `applyDDrawFix` (ddraw de War Wind), `applySteamRenderFix` (winemac/win32u), `repairFullEngineShim` (lanzador de wine-full). Van con marcador de versión (idempotentes) y evitan re-subir 540 MB por cada cambio. Es la vía por defecto y la ÚNICA posible para fixes de `wine-full`/CrossOver. Verificar SIEMPRE restaurando el original y dejando que Vessel se auto-repare.
   - **Regla práctica**: fix pequeño y aplicable en caliente → drop-in. Cambio grande del motor propio que un drop-in no cubre → release de Vessel-Engines + bump de URL. Ante la duda, drop-in.

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
- **`SteamGridDBClient` / `ProtonDBClient` / `EngineManager`** — carátulas (clave de SteamGridDB configurable en Ajustes), compatibilidad ProtonDB, gestión de motores.
- **`UpdaterManager`** — auto-update de la app con **Sparkle** (firma EdDSA + delta). Sustituye al `Updater` casero. Flujo de publicación en `docs/RELEASE-SPARKLE.md`; clave pública en el Info.plist (build_and_run.sh), privada en el llavero de SwonDev.
- **`LaunchDiagnostics`** — diagnóstico post-lanzamiento + **AUTO-REPARACIÓN** (mandato cero-intervención): sondea ~75 s, y si el arranque falla relanza con el siguiente motor del fallback, auto-activa "Steam real" (interfaces que Goldberg no da), auto-instala runtimes que faltan (VC++/.NET → `WineManager.installMissingRuntimes`), y **persiste la capa ganadora** en el `GameConfig`.
- **`DiscoveredFixesStore`** — ⭐ **loop de auto-aprendizaje** local→comunidad: cada arreglo que el fallback descubre se registra y el usuario puede **compartirlo** como perfil de compat para `SwonDev/Vessel_DB` (Ajustes › Compatibilidad). Escala la cobertura como el `cxcompatdb` propietario, pero abierto.
- **`SaveBackupManager`** — copias locales de partidas (manifiesto ludusavi, solo copia, restore-if-newer); red de seguridad SIEMPRE activa (backup al salir + restore al lanzar) en Steam/Epic/GOG.
- **`SteamCloudSyncService`** — ⚠️ LEGADO (ICloudService Web API es publisher-only → 401). La nube REAL en Modo Vessel se hace vía `WineManager.syncSteamCloud`: arranca el cliente Steam headless (`-silent`) → su **AutoCloud** sincroniza (validado por `cloud_log.txt`), manteniendo el motor gráfico óptimo. Opt-in por juego.

**Auto-reparación de runtimes (`WineManager`)**: `applyWinetricksVerbs`/`installMissingRuntimes` usan winetricks, que se **auto-descarga** si falta (release inmutable `20260125` + verificación **SHA-256** antes de ejecutar — nunca de `master`) y usa el `cabextract` del motor/sistema.

**Mandos**: `WineManager.gamepadEnvVars` activa HIDAPI + rumble de DualShock 4 / DualSense / Switch Pro vía hints de SDL2 (el motor bundlea `libSDL2`), inyectados en el entorno de lanzamiento del juego (equivalente Swift-puro del CW HACK 19629 de CrossOver).

**Compatibilidad (`CompatProfile`)**: campos `graphicsLayer`/`dllOverrides`/`envVars`/`winetricksVerbs`/`useRealSteam` + `thirdPartyAntiCheat` (EAC/BattlEye → fuerza Steam real + aviso honesto: los de modo kernel son imposibles en macOS). La detección heurística por-juego (`detectGraphicsAPI`, imports del PE + estructura) es el cerebro real del enrutado; la BD JSON complementa.

### MOTOR UNIFICADO propio (el modelo actual) + doble motor (fallback)

**Desde 2026-07 existe el motor unificado `wine-unified`** (DXMT compilado sobre WineHQ 11.10, build propio, publicado en el repo público `SwonDev/Vessel-Engines` release `engine-unified-v1`, ~540 MB): UN solo Wine libre que corre **a la vez** el cliente de Steam CEF completo (login + teclado + QR, con el wrapper SwiftShader y `WINEMSYNC=0`) **y** los juegos por DXMT/Metal — lo que CrossOver hace con su Wine propietario. Si está instalado, `WineEngineLocator` lo prefiere para TODO (`resolvedClientEngineName` y `resolvedGameEngineName`); "jugar desde Steam" (su botón verde) funciona porque el `d3d11` builtin del motor ES DXMT. Claves del cliente Steam en el unificado: `WINEMSYNC=0 WINEESYNC=0 WINEFSYNC=0` (msync rompe el async socket del updater → "http error 0"), `-tcp`, wrapper SwiftShader en `bin/cef/cef.win64`, deps `corefonts`+`vcrun2022` (winetricks, idempotente) y `DYLD_FALLBACK_LIBRARY_PATH` al `lib/` del motor (freetype/gnutls). `WineManager.openSteamClient` auto-repara toda la cadena: motor → Steam → deps → **self-update del cliente antiguo** (permitido SOLO en el unificado, ver `isSteamClientModern`/`updateSteamClient`) → wrapper. La ruta de Steam en el prefijo es dinámica: `Bottle.steamDirectory` (`Program Files (x86)/Steam` o `Program Files/Steam`).

#### Doble motor (fallback si el unificado no está)

Validado empíricamente en Apple Silicon: **ningún motor Wine libre estándar hace bien las dos cosas**, así que sin el unificado Vessel usa **dos motores según la tarea**, sobre el mismo prefijo. La selección está en `WineEngineLocator` (`clientWineBinary()` / `gameWineBinary()`) y la consume `WineManager` (`resolveClientWine` / `resolveGameWine`).

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

El cliente de Steam requiere TODO esto junto, o falla de formas distintas:

1. **`steam.cfg` con `BootStrapperInhibitAll=enable`** (`WineManager.ensureSteamConfig`). Sin esto, cuando Steam se relanza solo (sin `-noverifyfiles`) verifica sus ficheros, detecta el wrapper como "corrupto", intenta autoactualizar el cliente, la descarga falla bajo Gcenx (`http error 0`) y queda ladrillado → **`Failed to load steamui.dll`**. EXCEPCIÓN: bajo el motor unificado el updater SÍ funciona (`WINEMSYNC=0`), y `launchSteam` quita el steam.cfg a propósito (modo `needsSelfUpdate`) para actualizar un cliente antiguo una única vez.
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
