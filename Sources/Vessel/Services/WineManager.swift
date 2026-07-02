import Foundation

@MainActor
@Observable
final class WineManager {
    struct ProcessResult {
        let exitCode: Int32
        let output: String
    }

    enum WineError: LocalizedError {
        case noEngine
        case launchFailed(String)
        case installationFailed(String)
        case dxvkFailed(String)

        var errorDescription: String? {
            switch self {
            case .noEngine: return "Wine no instalado. Vessel lo descargará automáticamente."
            case .launchFailed(let msg): return "Error al lanzar: \(msg)"
            case .installationFailed(let msg): return "Error en la instalación: \(msg)"
            case .dxvkFailed(let msg): return "Error instalando DXVK: \(msg)"
            }
        }
    }

    private let dependencyManager = DependencyManager()
    private let dxvkManager = DXVKManager()
    private let dxmtManager = DXMTManager()
    private let gptkManager = GPTKManager()
    private let goldbergManager = GoldbergManager()
    private let wrapperInstaller = SteamWebHelperWrapperInstaller()
    private let gameWrapperInstaller = GameWrapperInstaller()
    private let launchOptionsManager = SteamLaunchOptionsManager()
    private let steamInstallerURL = URL(string: SteamConstants.setupURL)!
    private let log = LogStore.shared

    /// Entorno COMPLETO de un login shell del usuario, capturado una sola vez. La app
    /// la lanza launchd con un entorno MÍNIMO; con él, Wine no maneja bien las
    /// excepciones y Steam crashea (NtRaiseException) y se cierra solo. Al lanzar los
    /// procesos Wine con este entorno (como si fuera desde la terminal), Steam arranca
    /// estable — igual que cuando se lanza a mano.
    nonisolated static let userShellEnvironment: [String: String] = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "env"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var result: [String: String] = [:]
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                result[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        } catch {
            result = [:]
        }
        return result
    }()

    /// Evita que dos lanzamientos de Steam concurrentes (p.ej. "Lanzar Steam" y
    /// "Jugar" a la vez) se maten entre sí mientras el cliente aún carga.
    private var steamStarting = false

    /// Resuelve el binario de Wine: prefiere el portable descargado por Vessel,
    /// si no está usa GPTK de Apple. Nunca toca /Applications.
    func resolveWineBinary() -> String? {
        detectWineInstallations().first?.path
    }

    // MARK: - Doble motor (cliente Steam vs juegos D3D11)

    /// Motor para el CLIENTE de Steam (tienda/biblioteca): **Gcenx wine-osx64**,
    /// el único donde el Chromium/webhelper de Steam es estable. En GPTK/CrossOver
    /// pelado el cliente da 0x3008 (error de transporte de CEF). Los juegos NO usan
    /// el cliente: el DRM de Steamworks lo emula Goldberg (ver `launchD3D12Game`),
    /// así que Steam solo sirve para tienda/instalación. Fallback: `bottle.winePath`.
    func resolveClientWine(for bottle: Bottle) -> String {
        WineEngineLocator.clientWineBinary() ?? bottle.winePath
    }

    /// Motor para JUEGOS D3D11: wine-dxmt (DXMT builtin → Metal nativo, FL 11_0).
    /// Fallback: motor cliente o bottle.winePath.
    func resolveGameWine(for bottle: Bottle) -> String {
        WineEngineLocator.gameWineBinary()
            ?? WineEngineLocator.clientWineBinary()
            ?? bottle.winePath
    }

    /// Escribe `steam.cfg` con `BootStrapperInhibitAll` para que Steam NO se
    /// autoactualice/verifique. Sin esto, cuando Steam se relanza sin
    /// `-noverifyfiles` detecta el wrapper como corrupto, intenta actualizar el
    /// cliente, la descarga falla bajo Wine (http error 0) y queda ladrillado
    /// con "Failed to load steamui.dll". Idempotente.
    func ensureSteamConfig(in bottle: Bottle) {
        let steamDir = "\(bottle.prefixPath)/drive_c/Program Files (x86)/Steam"
        guard FileManager.default.fileExists(atPath: steamDir) else { return }
        let cfg = "\(steamDir)/steam.cfg"
        let contents = "BootStrapperInhibitAll=enable\nBootStrapperForceSelfUpdate=disable\n"
        try? contents.write(toFile: cfg, atomically: true, encoding: .utf8)
    }

    /// Borra la caché de CEF/htmlcache del prefijo. Tras los crashes del proceso
    /// GPU de Chromium la caché se corrompe y provoca el error de transporte
    /// 0x3008. Limpiarla antes de lanzar el cliente evita ese estado.
    func cleanCEFCache(in bottle: Bottle) {
        let fm = FileManager.default
        let usersDir = "\(bottle.prefixPath)/drive_c/users"
        let users = (try? fm.contentsOfDirectory(atPath: usersDir)) ?? []
        for user in users {
            for sub in ["AppData/Local/Steam/htmlcache", "AppData/Local/CEF"] {
                let path = "\(usersDir)/\(user)/\(sub)"
                if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
            }
        }
        let cfgCache = "\(bottle.prefixPath)/drive_c/Program Files (x86)/Steam/config/htmlcache"
        if fm.fileExists(atPath: cfgCache) { try? fm.removeItem(atPath: cfgCache) }
    }

    func detectWineInstallations() -> [(name: String, path: String, version: String)] {
        WineEngineLocator.detectWineInstallations()
    }

    func createBottle(at path: String, winePath: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: winePath) else {
            throw WineError.noEngine
        }

        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        log.log("Inicializando prefix Wine en \(path)", level: .info)
        try await runWineTool(
            winePath: winePath,
            toolName: "wineboot",
            fallbackArguments: ["wineboot", "--init"],
            toolArguments: ["--init"],
            prefix: path
        )
        log.log("Prefix inicializado", level: .info)
    }

    /// Configura un bottle recién creado. Con wine-dxmt (3Shain), DXMT+DXVK
    /// ya están integrados en los builtin y no necesitan instalación externa.
    /// Con wine-osx64 (Gcenx), instala DXMT y DXVK externos.
    func configureBottle(_ bottle: Bottle) async throws {
        if isUsingDXMTEngine() {
            log.log("Usando wine-dxmt (3Shain): DXMT+DXVK integrados en builtin, sin instalación externa", level: .info)
            return
        }

        // DXMT para D3D11/D3D10/DXGI (Metal nativo) — juegos modernos
        if !dxmtManager.isInstalled(in: bottle) {
            log.log("Instalando DXMT en \(bottle.name)…", level: .info)
            do {
                try await dxmtManager.install(in: bottle) { msg, pct in
                    Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct*100))%)", level: .debug) }
                }
                log.log("DXMT instalado correctamente", level: .info)
            } catch let error as DXMTManager.DXMTError {
                log.log("Fallo DXMT: \(error.localizedDescription)", level: .error)
                throw WineError.dxvkFailed("DXMT: \(error.localizedDescription)")
            }
        } else {
            log.log("DXMT ya instalado en \(bottle.name)", level: .debug)
        }

        // DXVK para D3D8/D3D9 (Vulkan → MoltenVK) — juegos legacy
        if bottle.dxvkEnabled, !dxvkManager.isInstalled(in: bottle) {
            log.log("Instalando DXVK en \(bottle.name)…", level: .info)
            do {
                try await dxvkManager.install(in: bottle) { msg, pct in
                    Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct*100))%)", level: .debug) }
                }
                log.log("DXVK instalado correctamente", level: .info)
            } catch let error as DXVKManager.DXVKError {
                log.log("Fallo DXVK: \(error.localizedDescription)", level: .error)
                throw WineError.dxvkFailed(error.localizedDescription)
            }
        } else if bottle.dxvkEnabled {
            log.log("DXVK ya instalado en \(bottle.name)", level: .debug)
        }
    }

    /// Reinstala DXMT en un bottle existente (botón de la UI).
    func reinstallDXMT(in bottle: Bottle) async throws {
        log.log("Reinstalando DXMT en \(bottle.name)…", level: .info)
        do {
            try await dxmtManager.install(in: bottle) { msg, _ in
                Task { @MainActor in LogStore.shared.log(msg, level: .debug) }
            }
            log.log("DXMT reinstalado", level: .info)
        } catch let error as DXMTManager.DXMTError {
            log.log("Fallo reinstalando DXMT: \(error.localizedDescription)", level: .error)
            throw WineError.dxvkFailed("DXMT: \(error.localizedDescription)")
        }
    }

    /// Asegura que DXMT está presente. Si no, lo instala. Idempotente.
    /// Con wine-dxmt (3Shain), DXMT ya está integrado en los builtin.
    func ensureDXMTInstalled(in bottle: Bottle) async throws {
        if isUsingDXMTEngine() { return }
        if dxmtManager.isInstalled(in: bottle) { return }
        try await reinstallDXMT(in: bottle)
    }

    func isDXMTInstalled(in bottle: Bottle) -> Bool {
        if isUsingDXMTEngine() { return true }
        return dxmtManager.isInstalled(in: bottle)
    }

    /// Reinstala DXVK en un bottle existente (botón de la UI).
    func reinstallDXVK(in bottle: Bottle) async throws {
        log.log("Reinstalando DXVK en \(bottle.name)…", level: .info)
        do {
            try await dxvkManager.install(in: bottle) { msg, _ in
                Task { @MainActor in LogStore.shared.log(msg, level: .debug) }
            }
            log.log("DXVK reinstalado", level: .info)
        } catch let error as DXVKManager.DXVKError {
            log.log("Fallo reinstalando DXVK: \(error.localizedDescription)", level: .error)
            throw WineError.dxvkFailed(error.localizedDescription)
        }
    }

    /// Asegura que DXVK está presente. Si no, lo instala. Idempotente.
    /// Con wine-dxmt (3Shain), DXVK/DXMT ya están integrados en los builtin,
    /// así que no hace nada.
    func ensureDXVKInstalled(in bottle: Bottle) async throws {
        if isUsingDXMTEngine() {
            // wine-dxmt tiene DXMT+DXVK integrado en sus DLLs builtin.
            // No necesita instalación externa.
            return
        }
        if dxvkManager.isInstalled(in: bottle) { return }
        try await reinstallDXVK(in: bottle)
    }

    func isDXVKInstalled(in bottle: Bottle) -> Bool {
        // Con wine-dxmt, DXVK/DXMT están integrados en los builtin.
        if isUsingDXMTEngine() { return true }
        return dxvkManager.isInstalled(in: bottle)
    }

    func installSteam(bottle: Bottle) async throws {
        let clientWine = resolveClientWine(for: bottle)

        if FileManager.default.fileExists(atPath: bottle.steamPath) {
            try await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
            ensureSteamConfig(in: bottle)
            try await ensureWrapperInstalled(in: bottle)
            try? await launchOptionsManager.injectLaunchOptions(in: bottle)
            try? await disableSteamAutoStart(winePath: clientWine, prefix: bottle.prefixPath)
            return
        }

        let downloadPath = "\(bottle.prefixPath)/drive_c/users/crossover/Downloads/SteamSetup.exe"
        try FileManager.default.createDirectory(
            atPath: "\(bottle.prefixPath)/drive_c/users/crossover/Downloads",
            withIntermediateDirectories: true
        )

        log.log("Descargando SteamSetup.exe…", level: .info)
        let (tempURL, response) = try await URLSession.shared.download(from: steamInstallerURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw WineError.installationFailed("Descarga de Steam falló con HTTP \(http.statusCode)")
        }

        let installerURL = URL(fileURLWithPath: downloadPath)
        try? FileManager.default.removeItem(at: installerURL)
        try FileManager.default.moveItem(at: tempURL, to: installerURL)

        // Para el motor UNIFICADO propio (que corre el CEF de Steam): instalar las MISMAS deps
        // que CrossOver instala antes de Steam — corefonts (Impact + fuentes de Windows) y
        // vcrun2022 (VC++ v14 x86/x64). Además esto inicializa el prefijo (wineboot), lo que
        // ARRANCA los servicios (RpcSs); sin ellos el instalador silent `/S` falla con COM/OLE
        // ("start_rpcss Failed to open RpcSs service"). Best-effort (si falta winetricks, sigue).
        if WineEngineLocator.isUnifiedEngine(clientWine) {
            log.log("Preparando dependencias de Steam (corefonts + VC++ v14)…", level: .info)
            await applyWinetricksVerbs(["corefonts", "vcrun2022"], prefix: bottle.prefixPath, wine: clientWine)
        }

        log.log("Ejecutando instalador de Steam en el bottle…", level: .info)
        let result = try await runWine(
            winePath: clientWine,
            arguments: [downloadPath, "/S"],
            prefix: bottle.prefixPath,
            environment: steamInstallEnvironment(prefix: bottle.prefixPath),
            allowNonZeroExit: true
        )
        try await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)

        if FileManager.default.fileExists(atPath: bottle.steamPath) {
            log.log("Steam instalado; configurando steam.cfg, wrapper y auto-start…", level: .info)
            ensureSteamConfig(in: bottle)
            try await ensureWrapperInstalled(in: bottle)
            try? await launchOptionsManager.injectLaunchOptions(in: bottle)
            // Steam se auto-registra en HKCU\...\Run para arrancar en silencio
            // cada vez que Wine inicia cualquier proceso en el prefix. Lo eliminamos.
            try? await disableSteamAutoStart(winePath: clientWine, prefix: bottle.prefixPath)
            return
        }

        let detail = Self.summarizeWineOutput(result.output)
        if Self.isRecoverableSteamServiceCrash(result.output) {
            throw WineError.installationFailed(
                "SteamService falló, pero Steam.exe no apareció en el bottle. \(detail)"
            )
        }

        throw WineError.installationFailed(
            "Steam no terminó de instalarse. Código \(result.exitCode). \(detail)"
        )
    }

    /// Instala el wrapper de steamwebhelper si no está instalado.
    /// El wrapper inyecta `--disable-gpu --single-process` en CEF para evitar
    /// la pantalla negra causada por ANGLE/DXVK y el cross-process swapchain bug.
    func ensureWrapperInstalled(in bottle: Bottle) async throws {
        if wrapperInstaller.isInstalled(in: bottle) {
            log.log("Wrapper steamwebhelper ya instalado", level: .debug)
            return
        }
        log.log("Instalando wrapper steamwebhelper…", level: .info)
        do {
            try await wrapperInstaller.install(in: bottle)
            log.log("Wrapper steamwebhelper instalado correctamente", level: .info)
        } catch let error as SteamWebHelperWrapperInstaller.WrapperError {
            log.log("Fallo instalando wrapper: \(error.localizedDescription)", level: .error)
            // No abortar: Steam puede funcionar sin wrapper en algunos casos.
            // El usuario verá el error en logs pero la app sigue.
        }
    }

    /// Elimina la entrada `Steam` de `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
    /// Sin esto, Steam se auto-arranca cada vez que Wine ejecuta cualquier proceso en
    /// el prefix (incluyendo las herramientas de DXVK), causando reaperturas incontrolables.
    private func disableSteamAutoStart(winePath: String, prefix: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = [
            "reg", "delete",
            #"HKCU\Software\Microsoft\Windows\CurrentVersion\Run"#,
            "/v", "Steam",
            "/f"
        ]
        process.environment = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "winedbg.exe=d"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            log.log("Auto-start de Steam deshabilitado en el registro", level: .info)
        } catch {
            log.log("No se pudo quitar auto-start de Steam: \(error.localizedDescription)", level: .warn)
        }
    }

    /// API gráfica detectada de un juego, para enrutar a la capa correcta.
    enum GameGraphicsAPI { case d3d9, d3d11, d3d12, other }

    /// Auto-detecta la API gráfica del juego. Lo más fiable es mirar las DLL que
    /// **importa el propio .exe** (tabla de imports del PE), con respaldo en la
    /// estructura de carpetas:
    ///  - `D3D12/` o `D3D12Core.dll` junto al exe, o importa `d3d12.dll` → D3D12 (GPTK).
    ///  - importa `d3d11.dll`/`dxgi.dll`, o Unity (`UnityPlayer.dll`/`<exe>_Data`) → D3D11 (DXMT).
    ///  - importa `d3d9.dll`/`d3d8.dll`/`ddraw.dll` → D3D9 (Gcenx, wined3d→Metal). wine-dxmt
    ///    NO resuelve bien el d3d9 de 32-bit (c0000135 "d3d9.dll not found"); Gcenx sí.
    func detectGraphicsAPI(forExecutable executable: String) -> GameGraphicsAPI {
        let dir = (executable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        let exeName = ((executable as NSString).lastPathComponent as NSString).deletingPathExtension
        let isUnity = fm.fileExists(atPath: "\(dir)/UnityPlayer.dll")
            || fm.fileExists(atPath: "\(dir)/\(exeName)_Data")
        // Juegos Unity: por defecto renderizan en D3D11 AUNQUE incluyan la Agility SDK
        // (carpeta `D3D12/`) — Unity solo usa D3D12 si se le fuerza, y la vía DXMT ya
        // añade `-force-d3d11`. Los enrutamos a DXMT (wine-dxmt-mousefix): rinde por
        // Metal Y aplica el fix del ratón de Unity 6 (EnableMouseInPointer→WM_POINTER).
        // GPTK/D3D12 NO tiene ese fix → el ratón queda muerto (validado con Ancient
        // Kingdoms: trae carpeta D3D12 pero inicializa "Direct3D 11.0 [level 11.1]" y
        // con GPTK el ratón no responde; con DXMT+mousefix sí).
        if isUnity {
            // Solo lo tratamos como D3D12 si el exe importa d3d12 directamente y NO d3d11.
            if exeImports(executable, anyOf: ["d3d12.dll"])
                && !exeImports(executable, anyOf: ["d3d11.dll", "dxgi.dll"]) {
                return .d3d12
            }
            return .d3d11
        }
        if fm.fileExists(atPath: "\(dir)/D3D12/D3D12Core.dll")
            || fm.fileExists(atPath: "\(dir)/D3D12Core.dll") {
            return .d3d12
        }
        // Imports del PE (prioridad: 12 > 11 > 9). Un juego moderno que importe d3d11
        // va a DXMT aunque traiga un d3d9 de respaldo; uno que SOLO importe d3d9 → Gcenx.
        if exeImports(executable, anyOf: ["d3d12.dll"]) { return .d3d12 }
        if exeImports(executable, anyOf: ["d3d11.dll", "dxgi.dll", "d3d10.dll", "d3d10core.dll"]) { return .d3d11 }
        if exeImports(executable, anyOf: ["d3d9.dll", "d3d8.dll", "ddraw.dll"]) { return .d3d9 }
        return .other
    }

    /// Motor gráfico REAL que usará `launch()` para este ejecutable + override. Se usa para
    /// pasar la capa correcta al **fallback automático**: si se pasara `.auto`, la cadena
    /// `nextLayer` supondría que se arrancó en DXMT y saltaría motores (p. ej. un juego
    /// `.other` arranca en Gcenx pero el fallback probaría gptk→gcenx, sin tocar DXMT).
    /// DEBE reflejar EXACTAMENTE el enrutado de `launch()`. Juegos de 32-bit (CrossOver) y
    /// D3D9 se reportan como `.gcenx`: launch() los re-fuerza a su motor pase lo que pase,
    /// así que el valor solo sirve para arrancar el ciclo de fallback.
    func resolvedGraphicsLayer(forExecutable executable: String, effective eff: EffectiveLaunchConfig = EffectiveLaunchConfig()) -> GameConfig.GraphicsLayer {
        let go = eff.graphicsOverride
        if go == .gcenx { return .gcenx }
        let api = detectGraphicsAPI(forExecutable: executable)
        if go == .gptk || (go == .auto && api == .d3d12) { return .gptk }
        if api == .d3d9 { return .gcenx }
        if isExecutable32Bit(executable) { return .gcenx }   // CrossOver; launch() lo re-fuerza
        if api == .other { return .gcenx }                   // carga dinámica de D3D → Gcenx
        return .dxmt                                          // D3D11 → wine-dxmt
    }

    /// ¿El .exe importa alguna de estas DLL? Escanea el binario (mapeado en memoria)
    /// buscando los nombres en la tabla de imports. Heurístico pero fiable: los nombres
    /// de import aparecen como ASCII terminado en nulo. Comprueba minúsculas y mayúsculas.
    private func exeImports(_ executable: String, anyOf names: [String]) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe)
        else { return false }
        for name in names {
            if let lower = name.lowercased().data(using: .ascii), data.range(of: lower) != nil { return true }
            if let upper = name.uppercased().data(using: .ascii), data.range(of: upper) != nil { return true }
        }
        return false
    }

    @discardableResult
    func launch(executable: String, in bottle: Bottle, arguments: [String] = [], steamAppId: String? = nil, graphicsOverride: GameConfig.GraphicsLayer? = nil, effective: EffectiveLaunchConfig? = nil) async throws -> Process {
        // Config EFECTIVA: defaults base → perfil de compatibilidad → overrides del
        // usuario. Si no se pasa (compat hacia atrás), se construye desde graphicsOverride.
        // Aporta: capa gráfica, env extra, overrides de DLL, args, sync y versión Windows.
        let eff = effective ?? EffectiveLaunchConfig(graphicsOverride: graphicsOverride ?? .auto, esync: true, fsync: true)
        let go = eff.graphicsOverride
        let allArgs = arguments + eff.launchArgs
        if eff.fromProfile, let r = eff.rating {
            log.log("Perfil de compatibilidad aplicado: \(r.label)\(eff.verified ? " ✓ verificado" : " (sin verificar)")", level: .info)
        }
        // DRM Steamworks AUTO: muchos juegos de Steam exigen que Steam esté corriendo (SteamAPI_Init)
        // y, si no, se cierran o intentan RELANZARSE por Steam (el "abre Steam y se cierra" clásico).
        // Como Vessel NO abre el cliente Steam para jugar, EMULAMOS la Steamworks API con Goldberg,
        // automáticamente y sin que el usuario toque nada (filosofía "abre y juega"). Un juego sin DRM
        // estricto funciona IGUAL con Goldberg (le da la API); solo lo evitan anti-tamper de terceros
        // (p. ej. CodeFusion), que de todos modos ya no arrancan. Idempotente (no re-copia si ya está).
        if let appId = steamAppId, !appId.isEmpty {
            try? await goldbergManager.ensureInstalled { _, _ in }
            if goldbergManager.applyToGame(gameExecutable: executable, appId: appId) {
                log.log("DRM Steamworks emulado con Goldberg (jugar sin abrir Steam).", level: .info)
            }
        }
        // Capa gráfica: override por juego (Ajustes/perfil) o auto-detección por API.
        // D3D12 (AAA, FF Tactics) → GPTK/D3DMetal (Metal nativo, ignora el Agility
        // SDK), con el cliente Steam en el mismo wineserver para el DRM.
        // Forzar Gcenx/D3D9 (usuario/perfil, o fallback tras fallo de DXMT): para juegos D3D9 o que
        // importan D3D11 pero renderizan por D3D9 (p. ej. Grim Dawn). Va por wined3d→Vulkan→Metal.
        if go == .gcenx {
            log.log("Capa gráfica: Gcenx (wined3d→Vulkan→Metal) [forzado]", level: .info)
            return try await launchD3D9Game(executable: executable, in: bottle,
                                            arguments: allArgs, steamAppId: steamAppId, effective: eff)
        }
        let useD3D12: Bool
        switch go {
        case .gptk: useD3D12 = true                                  // forzado por usuario/perfil
        case .dxmt: useD3D12 = false                                 // forzado a DXMT
        case .gcenx: useD3D12 = false                                // (ya gestionado arriba)
        case .auto: useD3D12 = detectGraphicsAPI(forExecutable: executable) == .d3d12
        }
        if useD3D12 {
            log.log("Capa gráfica: GPTK/D3DMetal (D3D12→Metal)\(go == .gptk ? " [forzado]" : "")", level: .info)
            return try await launchD3D12Game(executable: executable, in: bottle, steamAppId: steamAppId, effective: eff)
        }
        // Juegos D3D9/D3D8/DDraw → Gcenx (wine-osx64, Wine 11 completo, wined3d→Metal).
        // wine-dxmt no resuelve el d3d9 (falla con c0000135 "d3d9.dll not found"); Gcenx sí.
        // Se aplica SIEMPRE que la API sea D3D9 — también si un perfil/usuario forzó `.dxmt`:
        // forzar wine-dxmt aquí rompería el juego, así que el override `.dxmt` solo decide el
        // motor de los D3D11 (`.gptk` ya salió arriba por la rama D3D12).
        if detectGraphicsAPI(forExecutable: executable) == .d3d9 {
            if go == .dxmt { log.log("Override DXMT ignorado en juego D3D9: se usa Gcenx (wined3d→Vulkan), que es lo que funciona.", level: .info) }
            return try await launchD3D9Game(executable: executable, in: bottle,
                                            arguments: allArgs, steamAppId: steamAppId, effective: eff)
        }
        // Juegos de 32-bit que NO son D3D9 (típicamente Unity D3D11): el new-WoW64 de
        // Gcenx/wine-dxmt CRASHEA su runtime (p.ej. el Mono de Unity → "Crash!!!" nada más
        // arrancar). El Wine de CrossOver (gptk-mythic) sí los ejecuta; Unity cae a su
        // OpenGL (Apple GLD→Metal) con render monohilo (ver `launch32BitGame`).
        // Validado con "A Short Hike" (Unity 2019.4, 32-bit). Se aplica también con override
        // `.dxmt` (forzar wine-dxmt en 32-bit crashea Mono igualmente).
        if isExecutable32Bit(executable) {
            if go == .dxmt { log.log("Override DXMT ignorado en juego de 32-bit: se usa CrossOver (gptk-mythic).", level: .info) }
            return try await launch32BitGame(executable: executable, in: bottle,
                                             arguments: allArgs, steamAppId: steamAppId, effective: eff)
        }
        // Juegos de 64-bit que NO importan NINGUNA DLL de Direct3D en su tabla PE: cargan la
        // API gráfica DINÁMICAMENTE en runtime (LoadLibrary), así que no sabemos si usan D3D9,
        // D3D10 u D3D11. Muchos (p. ej. Grim Dawn, AppID 219990) son juegos de era D3D9 con un
        // renderer D3D11 opcional y arrancan en D3D9 por defecto. Gcenx (wined3d→Vulkan→Metal)
        // maneja D3D8/9/10/11 con un solo motor → es el default MÁS compatible; wine-dxmt (solo
        // D3D11→Metal) se cerraría al instante y SIN log si el juego elige D3D9. Verificado
        // empíricamente: Grim Dawn inicializa MoltenVK en Gcenx y muere silencioso en wine-dxmt.
        // (Unity queda excluido: `detectGraphicsAPI` lo clasifica como .d3d11, no .other.)
        // Solo en AUTO. Si el usuario o el FALLBACK fuerzan un motor concreto (.dxmt/.gptk),
        // se respeta: el fallback necesita poder probar DXMT/Metal y GPTK/D3DMetal, que en
        // Apple Silicon nuevo (M5) SÍ soportan la GPU cuando wined3d→Vulkan de Gcenx casca
        // (`__wine_unix_call` tras "Failed to retrieve GPU description Apple M5 Pro"). Sin este
        // gate, `.other` volvía siempre a Gcenx y el fallback quedaba en bucle sin tocar DXMT.
        if go == .auto && detectGraphicsAPI(forExecutable: executable) == .other {
            log.log("El juego carga Direct3D dinámicamente (sin imports PE) → Gcenx (wined3d), la capa más compatible.", level: .info)
            return try await launchD3D9Game(executable: executable, in: bottle,
                                            arguments: allArgs, steamAppId: steamAppId, effective: eff)
        }
        // D3D11 → wine-dxmt (DXMT→Metal). Aseguramos DXMT en el builtin del motor; si
        // no, los juegos usarían wined3d y fallarían con "InitializeEngineGraphics".
        let gameWine = resolveGameWine(for: bottle)
        try await ensureGameEngineDXMT(gameWine: gameWine)
        // GARANTÍA de carga de DXMT: copiar las DLLs de DXMT JUNTO al ejecutable.
        // Wine busca DLLs primero en la carpeta del exe; el builtin del motor NO se
        // resuelve de forma fiable desde el contexto de la app (Wine da c0000135
        // "DLL not found" al no encontrar d3d11). Con las DLLs junto al exe, siempre
        // cargan.
        ensureGameDXMTDLLs(gameExecutable: executable, gameWine: gameWine)
        // Dependencias de runtime: detecta lo que el juego importa y provisiona los DirectX helper
        // que empaquetamos (d3dx9/d3dcompiler, cuyo builtin de Wine es incompleto). El resto
        // (Visual C++, .NET, XInput) lo cubre el builtin del motor; se registra para el diagnóstico.
        RuntimeDependencyProvisioner.provision(executable: executable)
        // Cerrar procesos previos (el cliente Steam corre en Gcenx y deja el prefix
        // en su versión; hay que liberarlo antes de re-sincronizar a wine-dxmt).
        log.log("Preparando prefijo para el juego…", level: .info)
        try? await terminateWineProcesses(winePath: gameWine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
        // Re-sincronizar el prefix al motor de juegos. Imprescindible: tras lanzar
        // el cliente Steam (Gcenx) el prefix queda desincronizado y DXMT no carga
        // (el juego falla con InitializeEngineGraphics). `wineboot -u` lo restaura.
        await resyncGamePrefix(gameWine: gameWine, prefix: bottle.prefixPath)
        // Quitar DLLs nativas del prefix para que mande el DXMT builtin del motor.
        cleanPrefixNativeGraphicsDLLs(in: bottle)
        // Modo Retina: sin él, DXMT/Metal renderiza a 1× y el juego ocupa un cuarto de la
        // pantalla (esquina superior izquierda) en pantallas Retina. Con él, resolución
        // física completa a pantalla completa. Respeta el flag del perfil (por defecto ON).
        await setMacDriverRetinaMode(prefix: bottle.prefixPath, wine: gameWine, enabled: eff.retina)

        // Para juegos de Steam: `steam_appid.txt` + `SteamAppId` permiten que la
        // Steamworks API arranque en modo standalone (sin el cliente Steam abierto,
        // que además correría en otro motor). Sin esto algunos juegos no arrancan.
        var env = gameLaunchEnvironment(prefix: bottle.prefixPath)
        if let appId = steamAppId, !appId.isEmpty {
            let gameDir = (executable as NSString).deletingLastPathComponent
            try? appId.write(toFile: "\(gameDir)/steam_appid.txt", atomically: true, encoding: .utf8)
            env["SteamAppId"] = appId
            env["SteamGameId"] = appId
        }

        // Flags Unity (modo borderless fullscreen + DXMT). Solo se añaden a Unity.
        let engineArgs = unityLaunchArguments(forExecutable: executable)
        log.log("Lanzando juego con wine-dxmt (DXMT→Metal): \((executable as NSString).lastPathComponent)", level: .info)
        return try await launchWineProcess(
            winePath: gameWine,
            prefix: bottle.prefixPath,
            arguments: [executable] + engineArgs + allArgs,
            environment: env,
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: eff
        )
    }

    /// Lanza un juego **D3D9/D3D8 de 32-bit** con **Gcenx (wine-osx64)** vía
    /// **wined3d → Vulkan → MoltenVK → Metal** + **d3dx9 nativo de Microsoft**.
    ///
    /// Validado empíricamente (20XX) tras descartar varias vías:
    ///  - El `d3d9` builtin con su renderer por defecto cae al **OpenGL legacy** de
    ///    Apple (`GL_VENDOR "Apple"` no reconocido) y crashea al crear el device
    ///    (`d3d->createDevice failed`). Por eso forzamos `renderer=vulkan` en wined3d.
    ///  - **DXVK d3d9 NO sirve aquí**: el MoltenVK 0.2.2209 del motor Gcenx es viejo y le
    ///    faltan features que el DXVK d3d9 exige (`DxvkAdapter: Failed to create device`,
    ///    `VK_ERROR_FEATURE_NOT_PRESENT`); además el repack DXVK-macOS de Gcenx ni siquiera
    ///    incluye `d3d9`. wine-dxmt tampoco (DXMT solo trae d3d10/d3d11/dxgi → c0000135).
    ///  - El `d3dx9` builtin de Wine **no compila los efectos `.fx` (fx_2_0)** que usan
    ///    muchos juegos (`D3DXCreateEffectFromFile` → `E5017 not yet implemented`). Hay
    ///    que usar el **`d3dx9_43`/`d3dcompiler_43` nativos de Microsoft** (igual que
    ///    `winetricks d3dx9`).
    ///
    /// Todo lo prepara `ensureD3D9Support`. Mismo prefijo, distinto motor según la carga.
    private func launchD3D9Game(executable: String, in bottle: Bottle, arguments: [String], steamAppId: String?, effective: EffectiveLaunchConfig = EffectiveLaunchConfig()) async throws -> Process {
        let clientWine = resolveClientWine(for: bottle)
        log.log("Capa gráfica: wined3d → Vulkan → Metal (juego D3D9/D3D8) con Gcenx", level: .info)
        log.log("Preparando prefijo para el juego…", level: .info)
        // Si venimos de un intento con DXMT (fallback), sus DLLs (d3d11/dxgi/winemetal) quedaron
        // JUNTO al exe y usan la capa unix de wine-dxmt → con Gcenx dan
        // "ntdll.__wine_unix_call unimplemented" y el juego ABORTA. Las quitamos para que Gcenx use
        // sus propias d3d9/wined3d.
        cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
        try? await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
        // Re-sincronizar el prefix al motor Gcenx (tras el cliente Steam o un juego
        // D3D11 el prefix puede quedar en otro motor).
        await resyncGamePrefix(gameWine: clientWine, prefix: bottle.prefixPath)
        // Preparar d3d9/wined3d builtin (native files) + d3dx9 nativo de MS + renderer=vulkan.
        await ensureD3D9Support(in: bottle, engineWine: clientWine)

        var env = gameLaunchEnvironmentD3D9(prefix: bottle.prefixPath)
        if let appId = steamAppId, !appId.isEmpty {
            let gameDir = (executable as NSString).deletingLastPathComponent
            try? appId.write(toFile: "\(gameDir)/steam_appid.txt", atomically: true, encoding: .utf8)
            env["SteamAppId"] = appId
            env["SteamGameId"] = appId
        }
        log.log("Lanzando juego D3D9 con Gcenx (wined3d+Vulkan): \((executable as NSString).lastPathComponent)", level: .info)
        return try await launchWineProcess(
            winePath: clientWine,
            prefix: bottle.prefixPath,
            arguments: [executable] + arguments,
            environment: env,
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective
        )
    }

    /// Lanza un juego de **32-bit que NO es D3D9** (típicamente Unity D3D11) con el Wine de
    /// **CrossOver (gptk-mythic)** + `renderer=vulkan`.
    ///
    /// Validado con "A Short Hike" (Unity 2019.4, 32-bit): con Gcenx/wine-dxmt (new-WoW64)
    /// el juego CRASHEA nada más cargar Mono (`Crash!!!` en Player.log, antes de gráficos).
    /// El Wine de CrossOver sí ejecuta su runtime de 32-bit. La ventana abría en NEGRO
    /// hasta forzar `renderer=vulkan` (sin él wined3d usa el OpenGL legacy roto de Apple
    /// Silicon); con Vulkan va por el MoltenVK de CrossOver → Metal y renderiza.
    /// D3DMetal (GPTK) NO se usa: es de 64-bit. Se dejan los builtins de CrossOver
    /// (`cleanPrefixNativeGraphicsDLLs` quita DLLs nativas de otros motores).
    private func launch32BitGame(executable: String, in bottle: Bottle, arguments: [String], steamAppId: String?, effective: EffectiveLaunchConfig = EffectiveLaunchConfig()) async throws -> Process {
        try await gptkManager.ensureInstalled { msg, pct in
            Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
        }
        guard let gptkWine = gptkManager.wineBinaryPath else {
            throw WineError.launchFailed("No se encontró el motor CrossOver (gptk-mythic) para juegos de 32-bit.")
        }
        let isUnity = isUnityGame(executable)
        log.log(isUnity
            ? "Capa gráfica: OpenGL → Metal (juego Unity 32-bit, render monohilo) con CrossOver"
            : "Capa gráfica: wined3d → Metal (juego 32-bit) con CrossOver", level: .info)
        log.log("Preparando prefijo para el juego…", level: .info)
        try? await terminateWineProcesses(winePath: gptkWine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
        await resyncGamePrefix(gameWine: gptkWine, prefix: bottle.prefixPath)
        // Que CrossOver use SUS builtins (d3d11/wined3d): quitar DLLs nativas de otros motores.
        cleanPrefixNativeGraphicsDLLs(in: bottle)
        await setWined3dRendererVulkan(prefix: bottle.prefixPath, wine: gptkWine)

        var env: [String: String] = [
            "WINEPREFIX": bottle.prefixPath,
            "WINEDEBUG": "-all",
            "WINEMSYNC": "1",
            "WINEESYNC": "1",
            "MVK_CONFIG_LOG_LEVEL": "0",
            "WINEDLLOVERRIDES": "mscoree,mshtml=d;winemenubuilder.exe=d"
        ]
        if #available(macOS 15, *) { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        if let appId = steamAppId, !appId.isEmpty {
            let gameDir = (executable as NSString).deletingLastPathComponent
            try? appId.write(toFile: "\(gameDir)/steam_appid.txt", atomically: true, encoding: .utf8)
            env["SteamAppId"] = appId
            env["SteamGameId"] = appId
        }
        // Juegos Unity de 32-bit: forzar render MONOHILO en OpenGL (el multihilo sobre
        // el GL legacy de Apple bajo Wine corrompe memoria → crash). Ver `unity32BitGLArguments`.
        let extraArgs = unity32BitGLArguments(forExecutable: executable)
        log.log("Lanzando juego de 32-bit con CrossOver: \((executable as NSString).lastPathComponent)", level: .info)
        return try await launchWineProcess(
            winePath: gptkWine,
            prefix: bottle.prefixPath,
            arguments: [executable] + arguments + extraArgs,
            environment: env,
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective
        )
    }

    /// `true` si el `.exe` es un PE de **32-bit** (campo machine = `0x14c`, IMAGE_FILE_MACHINE_I386).
    /// Los juegos de 32-bit van por `launch32BitGame` (CrossOver), no por DXMT/GPTK (64-bit).
    func isExecutable32Bit(_ executable: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: executable) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 0x40), head.count >= 0x40 else { return false }
        let peOff = Int(head[0x3c]) | (Int(head[0x3d]) << 8) | (Int(head[0x3e]) << 16) | (Int(head[0x3f]) << 24)
        guard peOff > 0, peOff < 0x1_000_000 else { return false }
        try? fh.seek(toOffset: UInt64(peOff))
        guard let pe = try? fh.read(upToCount: 6), pe.count >= 6, pe[0] == 0x50, pe[1] == 0x45 else { return false } // "PE\0\0"
        let machine = Int(pe[4]) | (Int(pe[5]) << 8)
        return machine == 0x14c
    }

    /// Fuerza `renderer=vulkan` en wined3d (HKCU\Software\Wine\Direct3D). Sin esto wined3d
    /// cae al backend OpenGL legacy de Apple Silicon (roto → pantalla negra o crash al crear
    /// el device); con Vulkan va por MoltenVK→Metal. Inocuo para DXMT/GPTK/Steam (no usan wined3d).
    private func setWined3dRendererVulkan(prefix: String, wine: String) async {
        _ = try? await runWine(
            winePath: wine,
            arguments: ["reg", "add", #"HKCU\Software\Wine\Direct3D"#, "/v", "renderer",
                        "/t", "REG_SZ", "/d", "vulkan", "/f"],
            prefix: prefix,
            environment: ["WINEPREFIX": prefix, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "winedbg.exe=d"],
            allowNonZeroExit: true
        )
    }

    /// Activa/desactiva el modo Retina de Wine (`HKCU\Software\Wine\Mac Driver\RetinaMode`).
    /// IMPRESCINDIBLE en pantallas Retina: el `CAMetalLayer` de winemac.drv usa
    /// `contentsScale = 2.0` SOLO con RetinaMode activo. Sin él, DXMT/Metal renderiza a 1×
    /// y el juego ocupa un cuarto de la pantalla (esquina superior izquierda) con el resto
    /// en gris. Con RetinaMode el juego elige la resolución física completa (p. ej.
    /// 3024×1964) y se ve a pantalla completa nítida. Idempotente. Es la propiedad que
    /// `CompatProfile.retina` (por defecto `true`) declaraba pero nunca se aplicaba.
    private func setMacDriverRetinaMode(prefix: String, wine: String, enabled: Bool) async {
        _ = try? await runWine(
            winePath: wine,
            arguments: ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode",
                        "/t", "REG_SZ", "/d", enabled ? "y" : "n", "/f"],
            prefix: prefix,
            environment: ["WINEPREFIX": prefix, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "winedbg.exe=d"],
            allowNonZeroExit: true
        )
    }

    /// Prepara el prefijo para juegos **D3D9 de 32-bit** (ver `launchD3D9Game`):
    ///  1. Copia `d3d9`/`d3d8`/`wined3d` *builtin* del motor como **archivos nativos** en
    ///     syswow64/system32 (el override `=b` por sí solo no carga el d3d9 builtin de
    ///     32-bit en el WoW64 de Gcenx → c0000135 "d3d9.dll not found").
    ///  2. Instala `d3dx9_43`/`d3dx9_42`/`d3dcompiler_43` **nativos de Microsoft**
    ///     (Resources/redist) para que compilen los efectos `.fx`.
    ///  3. Fuerza `renderer=vulkan` en wined3d (el backend OpenGL legacy crashea en Apple
    ///     Silicon; con Vulkan va por MoltenVK→Metal). Es inocuo para el resto: DXMT y el
    ///     cliente Steam no usan wined3d.
    /// Idempotente: sobrescribe siempre (barato) para auto-reparar prefijos previos.
    private func ensureD3D9Support(in bottle: Bottle, engineWine: String) async {
        let binDir = (engineWine as NSString).deletingLastPathComponent          // …/bin
        let engineRoot = (binDir as NSString).deletingLastPathComponent          // …/wine-osx64
        let i386 = "\(engineRoot)/lib/wine/i386-windows"
        let x64w = "\(engineRoot)/lib/wine/x86_64-windows"
        let syswow = "\(bottle.prefixPath)/drive_c/windows/syswow64"
        let system32 = "\(bottle.prefixPath)/drive_c/windows/system32"
        try? FileManager.default.createDirectory(atPath: syswow, withIntermediateDirectories: true)

        // 1) d3d9/d3d8/wined3d builtin del motor como archivos nativos.
        for dll in ["d3d9.dll", "d3d8.dll", "wined3d.dll"] {
            copyDLLOverwrite(from: "\(i386)/\(dll)", to: "\(syswow)/\(dll)")
            copyDLLOverwrite(from: "\(x64w)/\(dll)", to: "\(system32)/\(dll)")
        }
        // 2) d3dx9/d3dcompiler nativos de Microsoft (para efectos .fx).
        if let redist = Self.d3dx9RedistDirectory() {
            for dll in ["d3dx9_43.dll", "d3dx9_42.dll", "d3dcompiler_43.dll"] {
                copyDLLOverwrite(from: "\(redist)/x32/\(dll)", to: "\(syswow)/\(dll)")
                copyDLLOverwrite(from: "\(redist)/x64/\(dll)", to: "\(system32)/\(dll)")
            }
        } else {
            log.log("d3dx9 nativo no encontrado en Resources/redist; los efectos .fx podrían fallar.", level: .warn)
        }
        // 3) Forzar renderer=vulkan en wined3d.
        await setWined3dRendererVulkan(prefix: bottle.prefixPath, wine: engineWine)
    }

    /// Copia `src`→`dst` sobrescribiendo (si `src` existe). Para sembrar DLLs en el prefix.
    private func copyDLLOverwrite(from src: String, to dst: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src) else { return }
        try? fm.removeItem(atPath: dst)
        try? fm.copyItem(atPath: src, toPath: dst)
    }

    /// Directorio con los d3dx9/d3dcompiler nativos de Microsoft (subcarpetas `x32`/`x64`),
    /// empaquetados en el bundle (`Contents/Resources/redist/d3dx9`). Si no está presente
    /// devuelve `nil` y el llamante lo registra — sin rutas de desarrollo hardcodeadas.
    private static func d3dx9RedistDirectory() -> String? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("redist/d3dx9").path,
           fm.fileExists(atPath: res) {
            return res
        }
        return nil
    }

    /// Lanza un juego **D3D12** con **GPTK / D3DMetal** (D3D12→Metal nativo de
    /// Apple), la misma vía que CrossOver/Whisky/Mythic. Es lo único que ejecuta de
    /// forma fiable juegos D3D12 AAA con DirectX 12 Agility SDK (como FF Tactics):
    /// el `d3d12.dll` builtin de D3DMetal ignora por diseño el `D3D12Core.dll` de
    /// Microsoft que el juego trae en su subcarpeta `D3D12/` — cargar ese core real
    /// de Microsoft (lo que hacía vkd3d) es lo que provocaba el crash con puntero
    /// corrupto dentro del juego. El cliente de Steam se lanza EN el mismo wine de
    /// GPTK (mismo wineserver) para que el DRM de Steamworks funcione.
    private func launchD3D12Game(executable: String, in bottle: Bottle, steamAppId: String?, effective: EffectiveLaunchConfig = EffectiveLaunchConfig()) async throws -> Process {
        let gameDir = (executable as NSString).deletingLastPathComponent
        let fm = FileManager.default

        // 1) Asegurar GPTK/D3DMetal (auto-descarga del Mythic Engine si falta).
        log.log("Preparando GPTK/D3DMetal para juego D3D12…", level: .info)
        try await gptkManager.ensureInstalled { msg, pct in
            Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
        }
        guard let gptkWine = gptkManager.wineBinaryPath else {
            throw WineError.launchFailed("No se pudo localizar el wine de GPTK/D3DMetal.")
        }

        // 2) Limpiar el game dir de DLLs gráficas que un lanzamiento previo dejara
        //    (DXMT/vkd3d junto al exe), para que mande el d3d12/dxgi builtin de
        //    D3DMetal. NO se toca la subcarpeta `D3D12/` del Agility SDK: D3DMetal
        //    la ignora por sí mismo.
        for dll in ["d3d11.dll", "d3d12.dll", "d3d12core.dll", "dxgi.dll",
                    "d3d10.dll", "d3d10_1.dll", "d3d10core.dll", "winemetal.dll"] {
            let p = "\(gameDir)/\(dll)"
            if fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p) }
        }

        // 3) DRM: se DEJA el steam_api64.dll ORIGINAL del juego. Reemplazarlo por un
        //    emulador (Goldberg) dispara los anti-tamper de terceros —p.ej. CodeFusion
        //    en FF Tactics, que detecta la emulación y bloquea—. Solo escribimos
        //    steam_appid.txt para que la Steamworks API arranque en modo standalone en
        //    juegos sin DRM estricto. (GoldbergManager queda como infraestructura
        //    para juegos que sí lo admitan, pero NO se aplica automáticamente.)
        if let appId = steamAppId, !appId.isEmpty {
            try? appId.write(toFile: "\(gameDir)/steam_appid.txt", atomically: true, encoding: .utf8)
        }

        // 4) Re-sincronizar el prefijo al motor GPTK y cerrar cualquier wine previo
        //    (p.ej. el cliente Steam en Gcenx). El juego corre solo en GPTK/D3DMetal.
        log.log("Preparando el prefijo para GPTK…", level: .info)
        try? await terminateWineProcesses(winePath: gptkWine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
        await resyncGamePrefix(gameWine: gptkWine, prefix: bottle.prefixPath)

        // 5) Lanzar el juego con el entorno de D3DMetal.
        var env = gptkManager.d3dMetalEnvironment(prefix: bottle.prefixPath)
        if let appId = steamAppId, !appId.isEmpty {
            env["SteamAppId"] = appId
            env["SteamGameId"] = appId
        }
        log.log("Lanzando juego D3D12 con GPTK/D3DMetal + Goldberg: \((executable as NSString).lastPathComponent)", level: .info)
        return try await launchWineProcess(
            winePath: gptkWine,
            prefix: bottle.prefixPath,
            arguments: [executable] + effective.launchArgs,
            environment: env,
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective
        )
    }

    /// Asegura que el cliente de Steam (Gcenx) está corriendo, necesario para el
    /// DRM de juegos Steamworks. Si no lo está, lo lanza y espera (sin bloquear UI).
    private func ensureSteamRunning(in bottle: Bottle, clientWine: String) async throws {
        // Señal de "cliente listo para DRM": steamwebhelper cargado. `steam.exe`
        // aparece mucho antes de que el cliente esté operativo y, al matar/relanzar,
        // daba falsos positivos (veía el viejo agonizando y no relanzaba). No se mata
        // Steam: si ya corre en GPTK, se reutiliza tal cual.
        if isWineProcessRunning(matching: "steamwebhelper") { return }
        log.log("Steam no está listo; lo lanzo en GPTK para el DRM del juego…", level: .info)
        _ = try? await launchSteam(in: bottle, using: clientWine)
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if isWineProcessRunning(matching: "steamwebhelper") { break }
        }
        // Margen para que la Steamworks API quede lista (el cliente de CrossOver
        // tarda algo más en conectar/loguear antes de servir el DRM).
        try? await Task.sleep(nanoseconds: 10_000_000_000)
    }

    /// ¿El cliente Steam está CONECTADO al CM (logueado), no solo arrancado? Lee el
    /// `connection_log.txt` del bottle: hay conexión si el último evento relevante es
    /// "Logged On" y no hay un "Logged Off"/"ConnectionDisconnected" posterior.
    func isSteamConnected(in bottle: Bottle) -> Bool {
        let logPath = "\(bottle.prefixPath)/drive_c/Program Files (x86)/Steam/logs/connection_log.txt"
        guard let data = FileManager.default.contents(atPath: logPath),
              let text = String(data: data, encoding: .utf8) else { return false }
        var connected = false
        for line in text.split(separator: "\n").suffix(80) {
            if line.contains("Logged On,") { connected = true }
            else if line.contains("Logged Off,") || line.contains("ConnectionDisconnected") { connected = false }
        }
        return connected
    }

    /// Asegura que el cliente Steam está CORRIENDO y **conectado** en `clientWine` (mismo
    /// motor que usará el juego, para compartir wineserver → DRM). Lo arranca si hace falta y
    /// espera hasta `timeoutSeconds` a que el `connection_log` confirme el logon. Devuelve si
    /// llegó a conectar. Con `-tcp` la conexión al CM es estable bajo Wine (el UDP se caía).
    func ensureSteamConnected(in bottle: Bottle, clientWine: String, timeoutSeconds: Int = 90) async -> Bool {
        if isSteamConnected(in: bottle) { return true }
        // Arrancar Steam SIEMPRE que no esté conectado: `launchSteam` ya es idempotente (si
        // `steam.exe` corre, se reutiliza). NO gatear en `steamwebhelper` — pgrep lista zombies
        // que `pkill` no puede reapear, y eso hacía que se SALTARA el arranque (Steam nunca abría).
        do { _ = try await launchSteam(in: bottle, using: clientWine) }
        catch { log.log("No se pudo arrancar el cliente Steam: \(error.localizedDescription)", level: .error) }
        for _ in 0..<timeoutSeconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if isSteamConnected(in: bottle) { return true }
        }
        return isSteamConnected(in: bottle)
    }

    /// MODO "STEAM REAL" (nuestro equivalente a CrossOver, invisible): lanza un juego DRM de
    /// Steam con el cliente Steam REAL corriendo y **conectado** en el MISMO motor/wineserver
    /// que el juego, para que `SteamAPI_Init` hable con él (DRM real, como en Windows). Es la
    /// única vía que arranca juegos como Grim Dawn en Apple Silicon nuevo (M5): el lanzamiento
    /// "suelto" (Goldberg) no basta para su DRM+entorno. Usa **GPTK/D3DMetal** (D3D11/12 →
    /// Metal nativo, rinde en M5) tanto para el cliente como para el juego.
    func launchViaRealSteam(executable: String, in bottle: Bottle, appId: String,
                            effective: EffectiveLaunchConfig = EffectiveLaunchConfig()) async throws -> Process {
        // 1) DRM REAL: restaurar el steam_api ORIGINAL del juego (deshacer Goldberg) + appid.
        goldbergManager.restoreGame(gameExecutable: executable)
        let gameDir = (executable as NSString).deletingLastPathComponent
        try? appId.write(toFile: "\(gameDir)/steam_appid.txt", atomically: true, encoding: .utf8)

        // 2) Motor GPTK/D3DMetal para cliente + juego (mismo wineserver).
        try await gptkManager.ensureInstalled { msg, pct in
            Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
        }
        guard let gptkWine = gptkManager.wineBinaryPath else {
            throw WineError.launchFailed("No se encontró GPTK/D3DMetal para el modo Steam real.")
        }

        // 3) Cliente Steam corriendo y CONECTADO (para el DRM). steam.cfg evita autoupdate.
        ensureSteamConfig(in: bottle)
        log.log("Modo Steam real: preparando el cliente Steam (conectado) para el DRM…", level: .info)
        let connected = await ensureSteamConnected(in: bottle, clientWine: gptkWine)
        log.log(connected
            ? "Cliente Steam conectado; lanzando el juego con DRM real."
            : "El cliente Steam no confirmó conexión a tiempo; se intenta lanzar igualmente.",
            level: connected ? .info : .warn)

        // 4) Lanzar el juego en GPTK, MISMO wineserver que Steam (NO se mata Steam ni se
        //    resincroniza el prefijo, que lo tumbaría). SteamAPI_Init encuentra el cliente vivo.
        var env = gptkManager.d3dMetalEnvironment(prefix: bottle.prefixPath)
        env["SteamAppId"] = appId
        env["SteamGameId"] = appId
        log.log("Lanzando \((executable as NSString).lastPathComponent) vía Steam real (GPTK/D3DMetal).", level: .info)
        return try await launchWineProcess(
            winePath: gptkWine,
            prefix: bottle.prefixPath,
            arguments: [executable] + effective.launchArgs,
            environment: env,
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective
        )
    }

    /// Abre el cliente Steam COMPLETO y conectado en **GPTK/D3DMetal** — para poder jugar
    /// DESDE Steam (DRM real, como en Windows) con render por Metal, que funciona en Apple
    /// Silicon nuevo (M5). Opción manual del menú "…"; también sirve para verificar la conexión.
    func openSteamClient(in bottle: Bottle) async {
        ensureSteamConfig(in: bottle)
        do {
            try await gptkManager.ensureInstalled { msg, pct in
                Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
            }
        } catch {
            log.log("No se pudo preparar GPTK para Steam: \(error.localizedDescription)", level: .warn)
        }
        let wine = gptkManager.wineBinaryPath ?? resolveClientWine(for: bottle)
        log.log("Abriendo el cliente Steam completo (GPTK/D3DMetal). Desde él puedes lanzar juegos con DRM real.", level: .info)
        let ok = await ensureSteamConnected(in: bottle, clientWine: wine)
        log.log(ok ? "Steam abierto y conectado ✓" : "Steam abierto (conexión aún no confirmada).", level: ok ? .info : .warn)
    }

    private func isWineProcessRunning(matching pattern: String) -> Bool {
        // Vía `ps | grep` (no `pgrep -f`) para EXCLUIR zombies: un proceso killed queda
        // `<defunct>`/STAT `Z` hasta que su padre lo reapea, y `pgrep` lo sigue listando →
        // hacía creer que Steam seguía vivo y se SALTABA su arranque. Se canaliza por `grep`
        // para que la salida sea MÍNIMA: leer `ps -axo` completo tras `waitUntilExit()` llena
        // el pipe y DEADLOCKEA (colgaba launchSteam). `awk` descarta STAT con Z (zombies).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `grep -v grep` es IMPRESCINDIBLE: si no, el propio proceso `grep -F <pattern>` aparece
        // en la lista de `ps` y casa el patrón → el check SIEMPRE daba true (Steam "ya en marcha")
        // y nunca se arrancaba. También se excluye el `sh -c` del script y los zombies.
        let script = "/bin/ps -axo stat=,command= | /usr/bin/grep -F '\(pattern)' | /usr/bin/grep -v grep | /usr/bin/grep -v '<defunct>' | /usr/bin/awk '$1 !~ /Z/'"
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try process.run()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    /// `true` si el ejecutable es un juego **Unity** (tiene `UnityPlayer.dll` o la
    /// carpeta `<exe>_Data` junto al `.exe`). Sirve para aplicar los flags de motor
    /// Unity correctos según la capa gráfica (DXMT en 64-bit, OpenGL en 32-bit).
    func isUnityGame(_ executable: String) -> Bool {
        let dir = (executable as NSString).deletingLastPathComponent
        let exeName = ((executable as NSString).lastPathComponent as NSString).deletingPathExtension
        let fm = FileManager.default
        return fm.fileExists(atPath: "\(dir)/UnityPlayer.dll")
            || fm.fileExists(atPath: "\(dir)/\(exeName)_Data")
    }

    /// Flags de motor Unity para el path **DXMT (64-bit)**. Para juegos no Unity, vacío.
    func unityLaunchArguments(forExecutable executable: String) -> [String] {
        // Combinación validada para Unity + DXMT en Apple Silicon:
        //  - `-force-d3d11-no-singlethreaded`: estabilidad de DXMT.
        //  - `-screen-fullscreen 1 -window-mode borderless`: pantalla completa SIN
        //    bordes. El fullscreen EXCLUSIVO (modo por defecto del juego) sí revienta
        //    el swapchain de DXMT (InitializeEngineGraphics failed); el borderless se
        //    ve a pantalla completa y funciona. Los avisos `unsupported swap effect`
        //    / `DeviceTexture` de DXMT son inofensivos (el juego renderiza igual).
        return isUnityGame(executable)
            ? ["-force-d3d11-no-singlethreaded", "-screen-fullscreen", "1", "-window-mode", "borderless"]
            : []
    }

    /// Flags de motor Unity para el path **OpenGL de 32-bit** (CrossOver). En Apple
    /// Silicon NO hay D3D11 para procesos de 32-bit: DXMT/D3DMetal son de 64-bit y los
    /// builtins d3d11/dxgi de CrossOver no cargan en 32-bit (`c000007b`); wined3d-vulkan
    /// choca con el MoltenVK sin `geometryShader`. Por eso Unity cae a SU renderer
    /// OpenGL (Apple GLD→Metal), que SÍ renderiza. El problema: el render **MULTIHILO**
    /// de Unity (`GfxDevice … threaded=1`) sobre ese GL legacy bajo Wine corrompe
    /// memoria → page fault de escritura en `UnityPlayer.dll` (`Crash!!!` justo al
    /// cargar el primer nivel, tras `Kinematic body …`). Validado con A Short Hike:
    ///  - `-force-gfx-direct`: render MONOHILO → elimina el crash (el fix raíz).
    ///  - `-force-glcore`: usa OpenGL Core directamente, evita el sondeo fallido de D3D11.
    ///  - `-screen-fullscreen 1 -window-mode borderless`: fullscreen sin bordes (no
    ///    exclusivo, seguro bajo Wine GL).
    func unity32BitGLArguments(forExecutable executable: String) -> [String] {
        return isUnityGame(executable)
            ? ["-force-gfx-direct", "-force-glcore", "-screen-fullscreen", "1", "-window-mode", "borderless"]
            : []
    }

    /// Garantiza que el motor de JUEGOS (wine-dxmt) tiene la `d3d11` de DXMT en su
    /// builtin. Operación de motor, idempotente. Auto-repara motores ya instalados.
    func ensureGameEngineDXMT(gameWine: String) async throws {
        guard WineEngineLocator.isGameEngine(gameWine) else {
            // El motor de juegos no es wine-dxmt; no hay DXMT integrable.
            return
        }
        // El motor UNIFICADO propio (WineHQ 11.10) trae SU PROPIO DXMT compilado a medida
        // en el builtin (winemetal.so 11.10 + d3d11/dxgi acordes). NO reinstalar encima el
        // DXMT 0.80 externo: mezclaría ABIs de winemetal de versiones distintas → pantalla
        // negra o crash. Su render ya está validado; se deja intacto.
        if WineEngineLocator.isUnifiedEngine(gameWine) { return }
        if dxmtManager.isInstalledInEngine(engineWinePath: gameWine) { return }
        log.log("Integrando DXMT en el motor wine-dxmt (fix gráfico D3D11)…", level: .info)
        do {
            try await dxmtManager.installIntoEngine(engineWinePath: gameWine) { msg, pct in
                Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct*100))%)", level: .debug) }
            }
            log.log("DXMT integrado en el motor", level: .info)
        } catch let error as DXMTManager.DXMTError {
            log.log("Fallo integrando DXMT en el motor: \(error.localizedDescription)", level: .error)
            throw WineError.dxvkFailed("DXMT (motor): \(error.localizedDescription)")
        }
    }

    /// Copia las DLLs de DXMT (d3d11/dxgi/d3d10*/winemetal) JUNTO al ejecutable del
    /// juego, tomándolas del builtin del motor (donde `installIntoEngine` las puso).
    /// Wine busca DLLs primero en la carpeta del exe, así que esto GARANTIZA que el
    /// juego cargue DXMT sin depender de la resolución de builtin del prefijo (que
    /// falla desde la app con c0000135). El `winemetal.so` (unix) se resuelve desde
    /// el motor, no hace falta copiarlo.
    func ensureGameDXMTDLLs(gameExecutable: String, gameWine: String) {
        guard let engineRoot = WineEngineLocator.engineRoot(forWineExecutable: URL(fileURLWithPath: gameWine)) else { return }
        let srcDir = engineRoot.appendingPathComponent("lib/wine/x86_64-windows").path
        let gameDir = (gameExecutable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        for dll in ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "d3d10.dll", "d3d10_1.dll", "winemetal.dll"] {
            let src = "\(srcDir)/\(dll)"
            let dst = "\(gameDir)/\(dll)"
            guard fm.fileExists(atPath: src) else { continue }
            let srcSize = (try? fm.attributesOfItem(atPath: src)[.size] as? UInt64) ?? 0
            let dstSize = (try? fm.attributesOfItem(atPath: dst)[.size] as? UInt64) ?? 0
            if srcSize != dstSize {
                try? fm.removeItem(atPath: dst)
                try? fm.copyItem(atPath: src, toPath: dst)
            }
        }
    }

    /// Quita las DLLs de DXMT (d3d11/dxgi/d3d10/winemetal) que `ensureGameDXMTDLLs` dejó JUNTO al
    /// exe, para que un lanzamiento con **Gcenx** (D3D9/wined3d) no las cargue: esas DLLs esperan la
    /// capa unix de wine-dxmt y con Gcenx dan `ntdll.__wine_unix_call unimplemented` (aborta). Un
    /// juego D3D9 no necesita d3d11/dxgi, así que es seguro retirarlas del lado del exe.
    func cleanExeAdjacentDXMTDLLs(gameExecutable: String) {
        let gameDir = (gameExecutable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        for dll in ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "d3d10.dll", "d3d10_1.dll", "winemetal.dll"] {
            try? fm.removeItem(atPath: "\(gameDir)/\(dll)")
        }
    }

    /// Directorio de trabajo del juego. Normalmente la carpeta del exe; PERO si el exe vive en una
    /// subcarpeta de binarios de 64 bits (x64/win64/bin64/…), muchos juegos con doble build esperan
    /// como CWD la RAÍZ del juego (donde están sus datos/BD), no la subcarpeta — p. ej. Grim Dawn
    /// (`x64/Grim Dawn.exe`) sale al instante con CWD=`x64/` porque no encuentra sus datos.
    private func gameWorkingDirectory(forExecutable executable: String) -> String {
        let exeDir = (executable as NSString).deletingLastPathComponent
        let last = (exeDir as NSString).lastPathComponent.lowercased()
        let bin64: Set<String> = ["x64", "win64", "bin64", "binaries64", "x86_64", "amd64"]
        return bin64.contains(last) ? (exeDir as NSString).deletingLastPathComponent : exeDir
    }

    /// Elimina del prefix las DLLs gráficas nativas (DXVK/DXMT/wined3d) que un setup
    /// previo dejó en system32/syswow64, para que se usen los builtins del motor.
    /// Incluye `wined3d`/`vulkan-1`/`winevulkan`: como archivos NATIVOS en el prefix
    /// rompen el binding WoW64 de Vulkan (no enlazan con su `.so` unix de 64-bit), lo
    /// que impide cargar d3d11 y deja el prefijo en un estado mixto frágil.
    func cleanPrefixNativeGraphicsDLLs(in bottle: Bottle) {
        let fm = FileManager.default
        let dlls = ["d3d8", "d3d9", "d3d10", "d3d10_1", "d3d10core", "d3d11",
                    "d3d12", "d3d12core", "dxgi", "winemetal", "nvapi64", "nvngx",
                    "wined3d", "vulkan-1", "winevulkan"]
        for sub in ["system32", "syswow64"] {
            let dir = "\(bottle.prefixPath)/drive_c/windows/\(sub)"
            for dll in dlls {
                let path = "\(dir)/\(dll).dll"
                // Solo borrar si es una DLL "real" (>20 KB); respetar las fake de Wine.
                if let size = try? fm.attributesOfItem(atPath: path)[.size] as? UInt64, size > 20_000 {
                    try? fm.removeItem(atPath: path)
                }
            }
        }
    }

    /// Entorno para JUEGOS en wine-dxmt: DXMT builtin (sin overrides d3d, así Wine
    /// usa su d3d11→Metal builtin) + silenciar el instalador de Mono/Gecko que
    /// aparece al actualizar el prefix con otro motor.
    private func gameLaunchEnvironment(prefix: String) -> [String: String] {
        [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "MVK_CONFIG_LOG_LEVEL": "0",
            "WINEESYNC": "1",
            "WINEFSYNC": "1",
            "WINEDLLOVERRIDES": "mscoree,mshtml=d;d3d9,d3d8,ddraw=b"
        ]
    }

    /// Entorno para juegos **D3D9 de 32-bit** en Gcenx (ver `ensureD3D9Support`):
    /// `d3d9`/`d3d8`/`wined3d` se cargan como archivos nativos (el builtin del motor,
    /// copiado al prefix) y renderizan por **Vulkan→MoltenVK→Metal** (renderer forzado en
    /// el registro); `d3dx9_43`/`d3dx9_42`/`d3dcompiler_43` son los **nativos de Microsoft**
    /// (efectos `.fx`). No se tocan d3d11/dxgi para no pisar el DXMT del builtin del motor.
    private func gameLaunchEnvironmentD3D9(prefix: String) -> [String: String] {
        [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "MVK_CONFIG_LOG_LEVEL": "0",
            "WINEESYNC": "1",
            "WINEFSYNC": "1",
            "WINEDLLOVERRIDES": "mscoree,mshtml=d;d3d9=n,b;d3d8=n,b;wined3d=n,b;d3dx9_43=n;d3dx9_42=n;d3dcompiler_43=n"
        ]
    }

    /// Entorno para el CLIENTE de Steam en Gcenx. El render del webhelper lo hace
    /// el wrapper (--disable-gpu, CPU), así que NO se pasan overrides d3d.
    private func steamClientEnvironment(prefix: String) -> [String: String] {
        [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "WINEESYNC": "1",
            "WINEFSYNC": "1",
            "SteamAppId": "753",
            "SteamGameId": "753"
        ]
    }

    /// Entorno del cliente Steam según el motor. En **GPTK/D3DMetal** (cuando Steam corre en
    /// el mismo motor que un juego que rinde por Metal, para el DRM) hace falta el entorno de
    /// D3DMetal (`DYLD_FALLBACK_LIBRARY_PATH` a sus libs externas + WINEMSYNC); sin él, Steam
    /// arranca y se cierra al instante en GPTK. Verificado: con este entorno steam.exe +
    /// steamwebhelper se mantienen vivos en GPTK. En Gcenx, el entorno normal.
    private func steamClientEnvironment(prefix: String, wine: String) -> [String: String] {
        // GPTK/D3DMetal: entorno de D3DMetal (Steam en el mismo motor que un juego Metal).
        if wine.contains("/\(GPTKManager.engineName)/") {
            var env = gptkManager.d3dMetalEnvironment(prefix: prefix)
            env["SteamAppId"] = "753"
            env["SteamGameId"] = "753"
            return env
        }
        // Motor UNIFICADO propio: el cliente de Steam CEF funciona con **WINEMSYNC=0** — msync
        // ROMPE el async socket completion (ConnectEx/overlapped) del updater HTTP → el connect
        // falla con 0xc00000a3 → "http error 0" y Steam no se actualiza. Con msync/esync/fsync a
        // 0 el updater descarga bien y el cliente carga. El wrapper SwiftShader (ver
        // SteamWebHelperWrapperInstaller) + `DYLD_FALLBACK_LIBRARY_PATH` (lo añade
        // launchWineProcess para isUnifiedEngine) completan el flujo. VALIDADO in-vivo.
        if WineEngineLocator.isUnifiedEngine(wine) {
            var env = steamClientEnvironment(prefix: prefix)
            env["WINEMSYNC"] = "0"
            env["WINEESYNC"] = "0"
            env["WINEFSYNC"] = "0"
            return env
        }
        // Gcenx (fallback): entorno normal.
        return steamClientEnvironment(prefix: prefix)
    }

    @discardableResult
    func launchSteam(in bottle: Bottle, using winePath: String? = nil) async throws -> Process {
        guard FileManager.default.fileExists(atPath: bottle.steamPath) else {
            throw WineError.launchFailed("Steam no está instalado en este bottle.")
        }

        // Por defecto el CLIENTE de Steam corre en Gcenx (Wine completo); su
        // Chromium/webhelper funciona ahí (en wine-dxmt crashea el proceso GPU de
        // CEF → 0x3008). Para juegos D3D12 se pasa el wine de GPTK explícitamente,
        // de modo que Steam y el juego compartan wineserver (necesario para el DRM).
        let clientWine = winePath ?? resolveClientWine(for: bottle)

        // 0) Idempotencia: si Steam ya está arrancando o cargado (steam.exe vivo),
        //    NO lo matamos ni relanzamos. Matar un cliente a medio cargar —al pulsar
        //    "Lanzar Steam" y "Jugar" a la vez, o varias veces seguidas— era justo lo
        //    que impedía que el webhelper terminara de cargar (se relanzaba en bucle).
        if isWineProcessRunning(matching: "steam.exe") {
            log.log("Steam ya está en marcha; se reutiliza sin relanzar.", level: .info)
            return Process()
        }

        // ¿Steam ya descargó su cliente completo (steamui.dll)? En una instalación
        // FRESH hay que DEJAR el primer bootstrap: sin steam.cfg restrictivo, sin el
        // flag -skipinitialbootstrap y sin wrapper. Si no, Steam no descarga
        // steamui.dll y da "Failed to load steamui.dll".
        let bootstrapped = isSteamBootstrapped(in: bottle)
        if bootstrapped {
            ensureSteamConfig(in: bottle)              // inhibe el auto-update que ladrilla
            cleanCEFCache(in: bottle)                  // evita el 0x3008
            try await ensureWrapperInstalled(in: bottle)
        } else {
            // Primer arranque: quitar cualquier steam.cfg restrictivo para permitir que
            // Steam descargue steamui.dll y el resto del cliente.
            let steamDir = "\(bottle.prefixPath)/drive_c/Program Files (x86)/Steam"
            try? FileManager.default.removeItem(atPath: "\(steamDir)/steam.cfg")
            log.log("Primer arranque de Steam: descargando su cliente (deja que termine la ventana de actualización)…", level: .info)
        }
        try? await launchOptionsManager.injectLaunchOptions(in: bottle)

        // Matar procesos Wine/Steam zombi previos (steam.exe, steamwebhelper…).
        log.log("Terminando procesos Wine/Steam previos…", level: .info)
        try await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
        try? await disableSteamAutoStart(winePath: clientWine, prefix: bottle.prefixPath)

        let engineLabel = clientWine.contains("/\(GPTKManager.engineName)/") ? "GPTK/CrossOver" : "Gcenx"
        log.log("Lanzando cliente Steam (\(engineLabel)) en \(bottle.name)…", level: .info)
        // En fresh, argumentos mínimos para no impedir el bootstrap inicial.
        let args = bootstrapped ? Self.steamLaunchArguments : ["-no-cef-sandbox"]
        // CLAVE: cwd = carpeta de Steam (escribible). Con cwd en "/" (lo que hereda la
        // app GUI) CEF no puede crear su caché y Steam se abre y se cierra solo.
        return try await launchWineProcess(
            winePath: clientWine,
            prefix: bottle.prefixPath,
            arguments: [bottle.steamPath] + args,
            environment: steamClientEnvironment(prefix: bottle.prefixPath, wine: clientWine),
            workingDirectory: (bottle.steamPath as NSString).deletingLastPathComponent
        )
    }

    /// True si Steam ya descargó su cliente completo (existe `steamui.dll`). En una
    /// instalación nueva no existe hasta que Steam hace su primer bootstrap.
    func isSteamBootstrapped(in bottle: Bottle) -> Bool {
        let steamDir = "\(bottle.prefixPath)/drive_c/Program Files (x86)/Steam"
        return FileManager.default.fileExists(atPath: "\(steamDir)/steamui.dll")
    }

    /// Deja Steam LISTO para iniciar sesión (login visible, sin pantalla negra):
    ///  1. Si es una instalación fresh, hace el primer bootstrap (descarga del cliente)
    ///     en crudo y espera a que termine.
    ///  2. Cierra ese Steam y lo relanza ya CON el wrapper de steamwebhelper, que es lo
    ///     que evita la pantalla negra de CEF en el login.
    func ensureSteamReadyForLogin(in bottle: Bottle, progress: @escaping @Sendable (String) -> Void) async throws {
        let clientWine = resolveClientWine(for: bottle)
        if !isSteamBootstrapped(in: bottle) {
            progress("Descargando el cliente de Steam…")
            _ = try await launchSteam(in: bottle)         // bootstrap en crudo
            for _ in 0..<150 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if isSteamBootstrapped(in: bottle) { break }
            }
            // Cerrar el Steam del bootstrap para relanzarlo limpio con el wrapper.
            try? await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        // Ya bootstrapped → este lanzamiento aplica wrapper + steam.cfg + caché limpia,
        // así el login se ve (no pantalla negra).
        progress("Abriendo Steam para iniciar sesión…")
        _ = try await launchSteam(in: bottle)
    }

    /// Instala un juego de la biblioteca **desde Vessel**: asegura el cliente Steam
    /// corriendo y le pasa `steam://install/<appid>` para que Steam lo descargue. El
    /// watcher en tiempo real lo añadirá a la lista cuando termine la instalación.
    func installSteamGame(appId: String, in bottle: Bottle) async throws {
        guard FileManager.default.fileExists(atPath: bottle.steamPath) else {
            throw WineError.launchFailed("Steam no está instalado en este bottle.")
        }
        let clientWine = resolveClientWine(for: bottle)
        if !isWineProcessRunning(matching: "steamwebhelper") {
            log.log("Abriendo Steam para instalar el juego…", level: .info)
            _ = try? await launchSteam(in: bottle)
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if isWineProcessRunning(matching: "steamwebhelper") { break }
            }
        }
        log.log("Solicitando a Steam la instalación del juego \(appId)…", level: .info)
        _ = try await launchWineProcess(
            winePath: clientWine,
            prefix: bottle.prefixPath,
            arguments: [bottle.steamPath, "steam://install/\(appId)"],
            environment: steamClientEnvironment(prefix: bottle.prefixPath, wine: clientWine),
            workingDirectory: (bottle.steamPath as NSString).deletingLastPathComponent
        )
    }

    /// Mata procesos Wine huérfanos asociados a este prefix usando `pkill -f`
    /// con la ruta del prefix. Más agresivo que `wineserver -k` cuando hay
    /// procesos zombi de Steam CEF.
    private func killOrphanWineProcesses(prefix: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-9", "-f", prefix]
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // pkill devuelve non-zero si no hay procesos que matar: esperado.
        }
        // El WINESERVER NO lleva el prefix en su argv (lo lee de la env `WINEPREFIX`),
        // así que `pkill -f <prefix>` NO lo alcanza y queda ZOMBI. Al cambiar de motor
        // (fallback DXMT→GPTK→Gcenx, o cliente Steam→juego) el nuevo wine —de otra
        // versión— choca con ese server zombi: «wine client error: version mismatch» y
        // el juego MUERE nada más arrancar (el clásico "se ejecuta y se cierra"). Lo
        // matamos por SEÑAL (independiente de versión): localizamos los `wineserver`
        // cuyos descriptores abiertos apuntan a ESTE prefix vía `lsof` y les mandamos
        // SIGKILL. `wineserver -k` no vale aquí porque también dialoga por protocolo y
        // falla igual con el mismatch de versión.
        await killPrefixWineservers(prefix: prefix)
    }

    /// Mata por SIGKILL cualquier `wineserver` ligado a `prefix`, sea cual sea el motor
    /// (versión) que lo arrancó. Evita el "version mismatch" que deja colgado al juego
    /// tras un cambio de motor. Silencioso e idempotente.
    private func killPrefixWineservers(prefix: String) async {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Para cada wineserver vivo, si tiene ABIERTO algo bajo el prefix → SIGKILL.
        let script = """
        for pid in $(/usr/bin/pgrep -x wineserver 2>/dev/null); do
          if /usr/sbin/lsof -p "$pid" 2>/dev/null | /usr/bin/grep -qF '\(prefix)'; then
            /bin/kill -9 "$pid" 2>/dev/null
          fi
        done
        """
        shell.arguments = ["-c", script]
        shell.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        shell.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try shell.run()
            shell.waitUntilExit()
        } catch {
            // Sin wineservers o sin lsof: nada que hacer.
        }
    }

    /// Re-sincroniza el prefix al motor de JUEGOS (`wineboot -u`). Imprescindible:
    /// el cliente Steam corre en Gcenx (wine 11) y deja el prefix en su versión;
    /// al lanzar luego un juego con wine-dxmt (wine 9.9), DXMT no carga y el juego
    /// falla con "InitializeEngineGraphics failed". `wineboot -u` restaura el estado
    /// que DXMT necesita. Mono/Gecko silenciados para no mostrar su instalador.
    private func resyncGamePrefix(gameWine: String, prefix: String) async {
        // SEGURIDAD: matar wineservers zombis del prefix ANTES de `wineboot`. Si queda uno de
        // OTRO motor/versión (p. ej. tras un crash del intento anterior en el fallback), el
        // `wineboot -u` choca con él y se queda COLGADO esperando —dejando el árbol de
        // servicios a medias y disparando el clásico cuelgue/fork-bomba—. Limpiarlo antes lo evita.
        await killPrefixWineservers(prefix: prefix)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gameWine)
        process.arguments = ["wineboot", "-u"]
        process.environment = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "mscoree,mshtml=d;d3d9,d3d8,ddraw=b"
        ]
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try process.run()
            // TIMEOUT: `wineboot -u` tarda <15s en condiciones normales. Si supera 45s está
            // COLGADO (wineserver malo, servicio que no arranca): lo cancelamos y seguimos, para
            // que un lanzamiento NUNCA quede bloqueado indefinidamente ni acumule procesos.
            let deadline = Date().addingTimeInterval(45)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if process.isRunning {
                log.log("wineboot -u tardó demasiado (prefijo en mal estado); se cancela y se continúa.", level: .warn)
                process.terminate()
            }
        } catch {
            log.log("No se pudo re-sincronizar el prefijo: \(error.localizedDescription)", level: .warn)
        }
        // CLAVE: matar el wineserver que deja `wineboot -u`, para que el juego arranque uno
        // LIMPIO con el prefijo ya actualizado. Si el juego corre sobre el wineserver de
        // wineboot, DXMT no engancha y falla con "InitializeEngineGraphics failed".
        try? await terminateWineProcesses(winePath: gameWine, prefix: prefix)
        try? await killOrphanWineProcesses(prefix: prefix)
        log.log("Prefijo re-sincronizado para el juego", level: .debug)
    }

    @discardableResult
    private func runWine(
        winePath: String,
        arguments: [String],
        prefix: String,
        environment: [String: String]? = nil,
        allowNonZeroExit: Bool = false
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = arguments
        process.environment = environment ?? [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                if allowNonZeroExit {
                    return ProcessResult(exitCode: process.terminationStatus, output: output)
                }

                throw WineError.launchFailed(output.isEmpty ? "Wine terminó con código \(process.terminationStatus)" : output)
            }
            return ProcessResult(exitCode: process.terminationStatus, output: output)
        } catch let error as WineError {
            throw error
        } catch {
            throw WineError.launchFailed(error.localizedDescription)
        }
    }

    private func runWineTool(
        winePath: String,
        toolName: String,
        fallbackArguments: [String],
        toolArguments: [String],
        prefix: String
    ) async throws {
        if let toolPath = siblingTool(named: toolName, forWinePath: winePath) {
            try await runExecutable(path: toolPath, arguments: toolArguments, prefix: prefix)
        } else {
            try await runWine(winePath: winePath, arguments: fallbackArguments, prefix: prefix)
        }
    }

    private func siblingTool(named toolName: String, forWinePath winePath: String) -> String? {
        let wineURL = URL(fileURLWithPath: winePath)
        let toolURL = wineURL.deletingLastPathComponent().appendingPathComponent(toolName)
        return FileManager.default.isExecutableFile(atPath: toolURL.path) ? toolURL.path : nil
    }

    private func runExecutable(path: String, arguments: [String], prefix: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw WineError.launchFailed(output.isEmpty ? "wineboot terminó con código \(process.terminationStatus)" : output)
            }
        } catch let error as WineError {
            throw error
        } catch {
            throw WineError.launchFailed(error.localizedDescription)
        }
    }

    private func steamInstallEnvironment(prefix: String) -> [String: String] {
        [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "winedbg.exe=d",
            "MVK_CONFIG_LOG_LEVEL": "0"
        ]
    }

    /// Para juegos lanzados directamente desde Vessel: si usa wine-dxmt (3Shain),
    /// NO pasar WINEDLLOVERRIDES (sus builtin ya tienen DXMT). Si usa wine-osx64,
    /// pasar DXMT+DXVK overrides.
    private func defaultLaunchEnvironment(prefix: String, dxvkEnabled: Bool) -> [String: String] {
        let isDXMTEngine = isUsingDXMTEngine()
        var env: [String: String] = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "MVK_CONFIG_LOG_LEVEL": "0",
            "WINEESYNC": "1",
            "WINEFSYNC": "1"
        ]
        if !isDXMTEngine {
            env["WINEDLLOVERRIDES"] = Self.dxmtDllOverrides
            env["DXVK_ASYNC"] = "1"
        }
        return env
    }

    /// Para Steam: si usa wine-dxmt (3Shain), NO pasar WINEDLLOVERRIDES porque
    /// sus DLLs builtin ya tienen DXMT integrado. Forzar overrides nativos rompe.
    /// Si usa wine-osx64 (Gcenx), pasar DXMT+DXVK overrides.
    private func steamLaunchEnvironment(prefix: String, dxvkEnabled: Bool) -> [String: String] {
        _ = dxvkEnabled
        let isDXMTEngine = isUsingDXMTEngine()
        var env: [String: String] = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "MVK_CONFIG_LOG_LEVEL": "0",
            "WINEESYNC": "1",
            "WINEFSYNC": "1",
            "SteamAppId": "753",
            "SteamGameId": "753"
        ]
        if !isDXMTEngine {
            env["WINEDLLOVERRIDES"] = Self.dxmtDllOverrides
            env["DXVK_ASYNC"] = "1"
        }
        return env
    }

    /// Override de DLLs para forzar DXMT (D3D11→Metal) + DXVK (D3D8/D3D9→Vulkan).
    /// `n` = native, `b` = builtin.
    /// - D3D11/D3D10/DXGI/winemetal: DXMT (Metal nativo) — juegos modernos D3D11
    /// - D3D8/D3D9: DXVK 1.10.3 (Vulkan → MoltenVK) — juegos legacy
    /// - D3D12: builtin (VKD3D no configurado)
    /// - nvapi64/nvngx: DXMT (NVIDIA API shim para que Unity no fallé)
    nonisolated static let dxmtDllOverrides =
        "d3d8=n,b; d3d9=n,b; d3d10=n,b; d3d10_1=n,b; d3d10core=n,b; d3d11=n,b; d3d12=b; d3d12core=b; dxgi=n,b; winemetal=n,b; nvapi64=n,b; nvngx=n,b; winedbg.exe=d"

    /// Override de DLLs legacy (solo DXVK, sin DXMT). Se usa cuando el bottle
    /// tiene DXVK pero no DXMT activado.
    nonisolated static let dxvkDllOverrides =
        "d3d8=n,b; d3d9=n,b; d3d10=n,b; d3d10_1=n,b; d3d10core=n,b; d3d11=n,b; d3d12=b; d3d12core=b; dxgi=n,b; winedbg.exe=d"

    /// Flags de lanzamiento de Steam optimizados para Wine + DXVK en macOS.
    /// NO usar `-cef-disable-gpu` ni `-noreactlogin`: producen pantalla negra
    /// al forzar software compositing que Wine no hace bien en macOS.
    /// `-no-cef-sandbox` es imprescindible para que CEF funcione en Wine.
    /// `-skipinitialbootstrap` evita que Steam reinstale componentes al arrancar.
    /// `-tcp`: fuerza la conexión al CM de Steam por TCP en vez de UDP. Bajo nuestro Wine
    /// en macOS 26.5 la conexión UDP (puerto 27017) se cae con `ConnectionDisconnected
    /// ('I/O Operation Failed')` a los ~46s y el cliente se queda en "Esperando a la red…"
    /// (verificado en connection_log.txt); TCP se mantiene estable. Además el IPv6 no
    /// resuelve bajo Wine, así que TCP/IPv4 es la vía fiable.
    nonisolated static let steamLaunchArguments = [
        "-no-cef-sandbox",
        "-noverifyfiles",
        "-skipinitialbootstrap",
        "-skipstreamingdrivers",
        "-vrdisable",
        "-nobootstraperrorinprogress",
        "-tcp"
    ]

    /// Detecta si el motor Wine actual es wine-dxmt (3Shain) con DXMT integrado.
    /// wine-dxmt tiene sus propios DLLs builtin con D3D11→Metal, por lo que NO
    /// hay que pasar WINEDLLOVERRIDES (forzar native rompe la integración).
    private func isUsingDXMTEngine() -> Bool {
        let engineDir = WineEngineLocator.portableEngineDirectory()
        return engineDir.lastPathComponent == WineEngineLocator.dxmtEngineName
    }

    private func terminateWineProcesses(winePath: String, prefix: String) async throws {
        guard let wineserverPath = siblingTool(named: "wineserver", forWinePath: winePath) else {
            return
        }

        _ = try? await runExecutableAllowingFailure(
            path: wineserverPath,
            arguments: ["-k"],
            prefix: prefix
        )
    }

    private func runExecutableAllowingFailure(path: String, arguments: [String], prefix: String) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, output: output)
    }

    private func launchWineProcess(
        winePath: String,
        prefix: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        effective: EffectiveLaunchConfig? = nil
    ) async throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = arguments
        // Directorio de trabajo = carpeta del juego (como hace Steam). CLAVE: con
        // cwd en "/" (no escribible, que es lo que hereda un proceso lanzado por la
        // app GUI) DXMT no puede crear su caché Metal y la carga de d3d11 falla
        // (80029c4a → "failed to load directx dlls" → InitializeEngineGraphics).
        if let wd = workingDirectory, FileManager.default.fileExists(atPath: wd) {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        }
        // HEREDAR el entorno base (HOME, PATH, TMPDIR, USER, DYLD_*…) y sobreponer
        // las variables de Wine/DXMT. CLAVE: si se reemplaza el entorno entero (sin
        // HOME/PATH), la inicialización de Metal/DXMT del juego falla con
        // "InitializeEngineGraphics failed" — por eso funcionaba lanzado a mano
        // (que hereda el entorno del shell) pero no desde la app.
        var fullEnv = ProcessInfo.processInfo.environment
        for (key, value) in Self.userShellEnvironment { fullEnv[key] = value }
        for (key, value) in environment { fullEnv[key] = value }
        // El motor UNIFICADO propio (WineHQ 11.10) carga freetype/gnutls por `dlopen` desde su
        // `lib/` (SONAME sin ruta). Necesita `DYLD_FALLBACK_LIBRARY_PATH` a esa carpeta o Wine
        // no encuentra FreeType (texto del sistema / CEF de Steam) ni gnutls (TLS). Es
        // inofensivo para juegos que no las usan. `arch` borraría esta var (SIP), pero aquí el
        // binario x86_64 se lanza directo (Rosetta), así que se preserva.
        if WineEngineLocator.isUnifiedEngine(winePath),
           let root = WineEngineLocator.engineRoot(forWineExecutable: URL(fileURLWithPath: winePath)) {
            let libDir = root.appendingPathComponent("lib").path
            let base = fullEnv["DYLD_FALLBACK_LIBRARY_PATH"]
            fullEnv["DYLD_FALLBACK_LIBRARY_PATH"] = (base?.isEmpty == false) ? "\(libDir):\(base!)" : libDir
        }
        // Overlay de la config EFECTIVA (perfil de compatibilidad + ajustes del usuario).
        // Solo para lanzamientos de JUEGO (effective != nil); Steam pasa nil → intacto.
        if let eff = effective {
            // Sincronización (cableada de verdad). msync implica esync para engañar a D3DMetal.
            fullEnv["WINEMSYNC"] = eff.msync ? "1" : "0"
            fullEnv["WINEESYNC"] = (eff.esync || eff.msync) ? "1" : "0"
            fullEnv["WINEFSYNC"] = eff.fsync ? "1" : "0"
            // HUD de rendimiento de Metal (ajuste del usuario). Se aplica AQUÍ, en el overlay
            // efectivo, para que pise el `MTL_HUD_ENABLED=0` que fija el entorno base de D3DMetal
            // (GPTKManager) — así el toggle también funciona en juegos D3D12.
            fullEnv["MTL_HUD_ENABLED"] = eff.metalHUD ? "1" : "0"
            // Overrides de DLL del perfil: se AÑADEN a los que ya trae el entorno base.
            let extra = eff.dllOverridesString
            if !extra.isEmpty {
                let base = fullEnv["WINEDLLOVERRIDES"]
                fullEnv["WINEDLLOVERRIDES"] = (base?.isEmpty == false) ? "\(base!);\(extra)" : extra
            }
            // Variables de entorno del perfil: ganan sobre todo (pueden ajustar DXVK, etc.).
            for (k, v) in eff.extraEnv { fullEnv[k] = v }
            // Preparación DECLARATIVA del perfil (idempotente), ANTES de arrancar el exe — aquí
            // ya sabemos el motor (`winePath`) que ejecutará el juego. Antes el perfil rellenaba
            // estos campos pero nadie los consumía (no tenían efecto real).
            if let ver = eff.windowsVersion, !ver.isEmpty {
                await applyWindowsVersion(ver, prefix: prefix, wine: winePath)
            }
            if !eff.winetricksVerbs.isEmpty {
                await applyWinetricksVerbs(eff.winetricksVerbs, prefix: prefix, wine: winePath)
            }
        }
        process.environment = fullEnv

        // Capturar la salida del proceso a un log para diagnóstico real.
        let logDir = "\(NSHomeDirectory())/Library/Logs/Vessel"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let outPath = "\(logDir)/game-launch.log"
        FileManager.default.createFile(atPath: outPath, contents: nil)
        if let handle = FileHandle(forWritingAtPath: outPath) {
            process.standardOutput = handle
            process.standardError = handle
        }

        log.log("CMD: \((winePath as NSString).lastPathComponent) \(arguments.map { ($0 as NSString).lastPathComponent }.joined(separator: " "))", level: .debug)
        do {
            try process.run()
            log.log("Proceso Wine lanzado (pid=\(process.processIdentifier))", level: .info)
            return process
        } catch {
            try? await terminateWineProcesses(winePath: winePath, prefix: prefix)
            throw WineError.launchFailed(error.localizedDescription)
        }
    }

    /// Fija la versión de Windows del prefijo (`HKCU\Software\Wine\Version`) que pide el perfil
    /// de compatibilidad — lo mismo que hace `winecfg`. Es un `reg add` puro (no necesita
    /// winetricks), idempotente (`/f`) e inocuo si ya estaba puesto. Valores Wine: win11,
    /// win10, win81, win8, win7, winxp…
    private func applyWindowsVersion(_ version: String, prefix: String, wine: String) async {
        log.log("Fijando versión de Windows del prefijo (perfil): \(version)", level: .info)
        _ = try? await runWine(
            winePath: wine,
            arguments: ["reg", "add", #"HKCU\Software\Wine"#, "/v", "Version",
                        "/t", "REG_SZ", "/d", version, "/f"],
            prefix: prefix,
            environment: ["WINEPREFIX": prefix, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "winedbg.exe=d"],
            allowNonZeroExit: true
        )
    }

    /// Aplica los verbos de winetricks que pide el perfil (vcrun, d3dx9…) de forma IDEMPOTENTE:
    /// lleva un registro en `<prefix>/.vessel-winetricks-applied` y solo aplica los que falten.
    ///
    /// NO descarga winetricks en el camino de lanzamiento (sería lento/bloqueante y rompería el
    /// "sin fricciones"): si no hay un `winetricks` instalado en el sistema, avisa en el log
    /// nombrando los verbos pendientes y sigue. Así el juego arranca igual y el usuario sabe qué
    /// runtime podría faltarle. (`winetricks` se instala con `brew install winetricks`.)
    private func applyWinetricksVerbs(_ verbs: [String], prefix: String, wine: String) async {
        let marker = "\(prefix)/.vessel-winetricks-applied"
        let already = Set(((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init))
        let pending = verbs.filter { !already.contains($0) }
        guard !pending.isEmpty else { return }

        // winetricks NO se empaqueta: resolverlo del sistema. Sin él, no bloqueamos el lanzamiento.
        let candidates = ["/opt/homebrew/bin/winetricks", "/usr/local/bin/winetricks"]
        guard let winetricks = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            log.log("El perfil pide winetricks [\(pending.joined(separator: ", "))] pero winetricks no está instalado; el juego podría faltarle ese runtime. Instálalo con `brew install winetricks`.", level: .warn)
            return
        }

        log.log("Aplicando winetricks (perfil): \(pending.joined(separator: ", "))…", level: .info)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winetricks)
        process.arguments = ["--unattended"] + pending
        var env = ProcessInfo.processInfo.environment
        env["WINE"] = wine
        env["WINEPREFIX"] = prefix
        env["WINEDEBUG"] = "-all"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let updated = already.union(pending).sorted().joined(separator: "\n")
                try? updated.write(toFile: marker, atomically: true, encoding: .utf8)
                log.log("✓ winetricks aplicado: \(pending.joined(separator: ", "))", level: .info)
            } else {
                log.log("winetricks devolvió código \(process.terminationStatus) aplicando [\(pending.joined(separator: ", "))].", level: .warn)
            }
        } catch {
            log.log("No se pudo ejecutar winetricks: \(error.localizedDescription)", level: .warn)
        }
    }

    nonisolated static func isRecoverableSteamServiceCrash(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        return lowercased.contains("steamservice")
            && lowercased.contains("unhandled page fault")
    }

    nonisolated static func summarizeWineOutput(_ output: String) -> String {
        let relevantLines = output
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                let lowercased = line.lowercased()
                return lowercased.contains("error")
                    || lowercased.contains("fail")
                    || lowercased.contains("unhandled")
                    || lowercased.contains("steamservice")
            }
            .prefix(4)

        guard !relevantLines.isEmpty else { return "" }
        return relevantLines.joined(separator: " ")
    }
}
