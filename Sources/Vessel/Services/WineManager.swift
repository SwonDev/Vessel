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

        log.log("Ejecutando instalador de Steam en el bottle (Gcenx)…", level: .info)
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
        if fm.fileExists(atPath: "\(dir)/D3D12/D3D12Core.dll")
            || fm.fileExists(atPath: "\(dir)/D3D12Core.dll") {
            return .d3d12
        }
        // Imports del PE (prioridad: 12 > 11 > 9). Un juego moderno que importe d3d11
        // va a DXMT aunque traiga un d3d9 de respaldo; uno que SOLO importe d3d9 → Gcenx.
        if exeImports(executable, anyOf: ["d3d12.dll"]) { return .d3d12 }
        if exeImports(executable, anyOf: ["d3d11.dll", "dxgi.dll", "d3d10.dll", "d3d10core.dll"]) { return .d3d11 }
        if exeImports(executable, anyOf: ["d3d9.dll", "d3d8.dll", "ddraw.dll"]) { return .d3d9 }
        let exeName = ((executable as NSString).lastPathComponent as NSString).deletingPathExtension
        if fm.fileExists(atPath: "\(dir)/UnityPlayer.dll")
            || fm.fileExists(atPath: "\(dir)/\(exeName)_Data") {
            return .d3d11
        }
        return .other
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
    func launch(executable: String, in bottle: Bottle, arguments: [String] = [], steamAppId: String? = nil, graphicsOverride: GameConfig.GraphicsLayer? = nil) async throws -> Process {
        // Capa gráfica: override por juego (Ajustes) o auto-detección por API.
        // D3D12 (AAA, FF Tactics) → GPTK/D3DMetal (Metal nativo, ignora el Agility
        // SDK), con el cliente Steam en el mismo wineserver para el DRM.
        let useD3D12: Bool
        switch graphicsOverride {
        case .gptk: useD3D12 = true                                  // forzado por el usuario
        case .dxmt: useD3D12 = false                                 // forzado a DXMT
        case .auto, .none: useD3D12 = detectGraphicsAPI(forExecutable: executable) == .d3d12
        }
        if useD3D12 {
            log.log("Capa gráfica: GPTK/D3DMetal (D3D12→Metal)\(graphicsOverride == .gptk ? " [forzado]" : "")", level: .info)
            return try await launchD3D12Game(executable: executable, in: bottle, steamAppId: steamAppId)
        }
        // Juegos D3D9/D3D8/DDraw → Gcenx (wine-osx64, Wine 11 completo, wined3d→Metal).
        // wine-dxmt no resuelve el d3d9 de 32-bit (falla con c0000135 "d3d9.dll not
        // found"); Gcenx sí lo ejecuta. Solo en automático/DXMT-no-forzado.
        if graphicsOverride == nil || graphicsOverride == .auto,
           detectGraphicsAPI(forExecutable: executable) == .d3d9 {
            return try await launchD3D9Game(executable: executable, in: bottle,
                                            arguments: arguments, steamAppId: steamAppId)
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
            arguments: [executable] + engineArgs + arguments,
            environment: env,
            workingDirectory: (executable as NSString).deletingLastPathComponent
        )
    }

    /// Lanza un juego **D3D9/D3D8/DDraw** con **Gcenx (wine-osx64)**, que es un Wine 11
    /// completo cuyo `d3d9` builtin (wined3d→Vulkan/MoltenVK→Metal) sí funciona en
    /// 32-bit. wine-dxmt está especializado en DXMT (D3D11) y su d3d9 de 32-bit falla
    /// con c0000135. Mismo prefijo, distinto motor según la carga (filosofía de Vessel).
    private func launchD3D9Game(executable: String, in bottle: Bottle, arguments: [String], steamAppId: String?) async throws -> Process {
        let clientWine = resolveClientWine(for: bottle)
        log.log("Capa gráfica: wined3d→Metal (juego D3D9/D3D8) con Gcenx", level: .info)
        log.log("Preparando prefijo para el juego…", level: .info)
        try? await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
        // Re-sincronizar el prefix al motor Gcenx (tras el cliente Steam o un juego
        // D3D11 el prefix puede quedar en otro motor).
        await resyncGamePrefix(gameWine: clientWine, prefix: bottle.prefixPath)
        // Quitar DLLs nativas de gráficos del prefix para que mande el builtin (wined3d).
        cleanPrefixNativeGraphicsDLLs(in: bottle)

        var env = gameLaunchEnvironment(prefix: bottle.prefixPath)   // ya fija d3d9,d3d8,ddraw=b
        if let appId = steamAppId, !appId.isEmpty {
            let gameDir = (executable as NSString).deletingLastPathComponent
            try? appId.write(toFile: "\(gameDir)/steam_appid.txt", atomically: true, encoding: .utf8)
            env["SteamAppId"] = appId
            env["SteamGameId"] = appId
        }
        log.log("Lanzando juego D3D9 con Gcenx: \((executable as NSString).lastPathComponent)", level: .info)
        return try await launchWineProcess(
            winePath: clientWine,
            prefix: bottle.prefixPath,
            arguments: [executable] + arguments,
            environment: env,
            workingDirectory: (executable as NSString).deletingLastPathComponent
        )
    }

    /// Lanza un juego **D3D12** con **GPTK / D3DMetal** (D3D12→Metal nativo de
    /// Apple), la misma vía que CrossOver/Whisky/Mythic. Es lo único que ejecuta de
    /// forma fiable juegos D3D12 AAA con DirectX 12 Agility SDK (como FF Tactics):
    /// el `d3d12.dll` builtin de D3DMetal ignora por diseño el `D3D12Core.dll` de
    /// Microsoft que el juego trae en su subcarpeta `D3D12/` — cargar ese core real
    /// de Microsoft (lo que hacía vkd3d) es lo que provocaba el crash con puntero
    /// corrupto dentro del juego. El cliente de Steam se lanza EN el mismo wine de
    /// GPTK (mismo wineserver) para que el DRM de Steamworks funcione.
    private func launchD3D12Game(executable: String, in bottle: Bottle, steamAppId: String?) async throws -> Process {
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
            arguments: [executable],
            environment: env,
            workingDirectory: gameDir
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

    private func isWineProcessRunning(matching pattern: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return process.terminationStatus == 0 && !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    /// Detecta juegos Unity (tienen `UnityPlayer.dll` o carpeta `<exe>_Data` junto
    /// al ejecutable) y devuelve los flags que DXMT necesita: modo ventana
    /// (`-screen-fullscreen 0`) y `-force-d3d11-no-singlethreaded`. Para juegos no
    /// Unity devuelve vacío.
    func unityLaunchArguments(forExecutable executable: String) -> [String] {
        let dir = (executable as NSString).deletingLastPathComponent
        let exeName = ((executable as NSString).lastPathComponent as NSString).deletingPathExtension
        let fm = FileManager.default
        let isUnity = fm.fileExists(atPath: "\(dir)/UnityPlayer.dll")
            || fm.fileExists(atPath: "\(dir)/\(exeName)_Data")
        // Combinación validada para Unity + DXMT en Apple Silicon:
        //  - `-force-d3d11-no-singlethreaded`: estabilidad de DXMT.
        //  - `-screen-fullscreen 1 -window-mode borderless`: pantalla completa SIN
        //    bordes. El fullscreen EXCLUSIVO (modo por defecto del juego) sí revienta
        //    el swapchain de DXMT (InitializeEngineGraphics failed); el borderless se
        //    ve a pantalla completa y funciona. Los avisos `unsupported swap effect`
        //    / `DeviceTexture` de DXMT son inofensivos (el juego renderiza igual).
        return isUnity
            ? ["-force-d3d11-no-singlethreaded", "-screen-fullscreen", "1", "-window-mode", "borderless"]
            : []
    }

    /// Garantiza que el motor de JUEGOS (wine-dxmt) tiene la `d3d11` de DXMT en su
    /// builtin. Operación de motor, idempotente. Auto-repara motores ya instalados.
    func ensureGameEngineDXMT(gameWine: String) async throws {
        guard WineEngineLocator.isGameEngine(gameWine) else {
            // El motor de juegos no es wine-dxmt; no hay DXMT integrable.
            return
        }
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

    /// Elimina del prefix las DLLs gráficas nativas (DXVK/DXMT) que un setup previo
    /// dejó en system32/syswow64, para que se use el DXMT builtin del motor.
    func cleanPrefixNativeGraphicsDLLs(in bottle: Bottle) {
        let fm = FileManager.default
        let dlls = ["d3d8", "d3d9", "d3d10", "d3d10_1", "d3d10core", "d3d11",
                    "d3d12", "d3d12core", "dxgi", "winemetal", "nvapi64", "nvngx"]
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
            environment: steamClientEnvironment(prefix: bottle.prefixPath),
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
            environment: steamClientEnvironment(prefix: bottle.prefixPath),
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
    }

    /// Re-sincroniza el prefix al motor de JUEGOS (`wineboot -u`). Imprescindible:
    /// el cliente Steam corre en Gcenx (wine 11) y deja el prefix en su versión;
    /// al lanzar luego un juego con wine-dxmt (wine 9.9), DXMT no carga y el juego
    /// falla con "InitializeEngineGraphics failed". `wineboot -u` restaura el estado
    /// que DXMT necesita. Mono/Gecko silenciados para no mostrar su instalador.
    private func resyncGamePrefix(gameWine: String, prefix: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gameWine)
        process.arguments = ["wineboot", "-u"]
        process.environment = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "mscoree,mshtml=d;d3d9,d3d8,ddraw=b"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.log("No se pudo re-sincronizar el prefijo: \(error.localizedDescription)", level: .warn)
        }
        // CLAVE: matar el wineserver que deja `wineboot -u`, para que el juego
        // arranque uno LIMPIO con el prefijo ya actualizado. Si el juego corre
        // sobre el wineserver de wineboot, DXMT no engancha y falla con
        // "InitializeEngineGraphics failed" (esta es la diferencia que hacía que
        // funcionara lanzado a mano pero no desde Vessel).
        try? await terminateWineProcesses(winePath: gameWine, prefix: prefix)
        try? await killOrphanWineProcesses(prefix: prefix)
        log.log("Prefijo re-sincronizado a wine-dxmt para el juego", level: .debug)
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
    nonisolated static let steamLaunchArguments = [
        "-no-cef-sandbox",
        "-noverifyfiles",
        "-skipinitialbootstrap",
        "-skipstreamingdrivers",
        "-vrdisable",
        "-nobootstraperrorinprogress"
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
        workingDirectory: String? = nil
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
