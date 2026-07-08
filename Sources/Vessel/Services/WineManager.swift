import Foundation
import CoreGraphics

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

    /// Candado GLOBAL de los flujos de preparación/arranque de Steam. Es `static`
    /// porque las vistas crean instancias SEPARADAS de WineManager (SteamStoreView,
    /// BottleDetailView…) y dos flujos concurrentes (menú "Abrir Steam" + "Iniciar
    /// sesión" de la vista) se MATAN los procesos entre sí — visto in-vivo: uno
    /// lanza Steam y el otro lo tumba al "limpiar procesos previos", en bucle.
    private static var steamFlowActive = false

    /// Toma el turno del flujo Steam. Devuelve `true` si somos el dueño (liberar
    /// poniendo `Self.steamFlowActive = false` al salir); `false` si otro flujo ya
    /// estaba preparando Steam — en ese caso se ESPERA a que termine y el llamador
    /// NO debe repetir el trabajo pesado (solo reutilizar el Steam ya arrancado).
    private func acquireSteamFlowTurn() async -> Bool {
        if Self.steamFlowActive {
            for _ in 0..<1200 where Self.steamFlowActive {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return false
        }
        Self.steamFlowActive = true
        return true
    }

    /// Resuelve el binario de Wine: prefiere el portable descargado por Vessel,
    /// si no está usa GPTK de Apple. Nunca toca /Applications.
    func resolveWineBinary() -> String? {
        detectWineInstallations().first?.path
    }

    // MARK: - Doble motor (cliente Steam vs juegos D3D11)

    /// Motor para el CLIENTE de Steam (tienda/biblioteca/jugar desde Steam): el
    /// **motor unificado** propio (DXMT/WineHQ 11.10) si está instalado — corre el CEF
    /// completo (login+teclado+QR) con el wrapper SwiftShader y `WINEMSYNC=0`, y además
    /// los juegos por DXMT/Metal en el MISMO wineserver. Si no está: Gcenx wine-osx64
    /// (solo tienda; su webhelper es estable pero sus juegos van por wined3d).
    /// Fallback final: `bottle.winePath`.
    func resolveClientWine(for bottle: Bottle) -> String {
        WineEngineLocator.clientWineBinary() ?? bottle.winePath
    }

    /// Motor para JUEGOS D3D11: wine-dxmt (DXMT builtin → Metal nativo, FL 11_0).
    /// Fallback: motor cliente o bottle.winePath.
    /// EXCEPCIÓN por juego: los juegos con **Epic Online Services (EOS)** CRASHEAN al inicializar su
    /// SDK bajo el motor unificado (WineHQ 11.10) — el crash cae en `UnityPlayer.dll` justo en la init
    /// de la plataforma (visto en AK-xolotl y Dragon Is Dead). En `wine-dxmt-mousefix` (Wine 9.9)
    /// arrancan bien (es donde funcionaban antes de que el unificado pasara a ser el motor por defecto).
    /// Por eso, si el ejecutable trae EOS, se ruta a mousefix. Aethermancer (sin EOS) sigue en el unificado.
    func resolveGameWine(for bottle: Bottle, executable: String? = nil) -> String {
        if let exe = executable, usesEpicOnlineServices(exe),
           let mousefix = WineEngineLocator.wineBinary(in: WineEngineLocator.mousefixEngineName) {
            log.log("Juego con Epic Online Services (EOS): se usa wine-dxmt-mousefix (el motor unificado crashea su SDK).", level: .info)
            return mousefix
        }
        // Juegos OpenGL (motor GL propio, p. ej. Heroes of Hammerwatch II): motor ESPECÍFICO
        // `wine-unified-opengl` (clon con `winemac.so` parcheado, CW Hack 24834) para NO tocar el
        // `wine-unified` compartido. Si aún no está creado, cae al unificado normal (que fallará el
        // contexto GL 3.2 → el auto-instalador debería haberlo creado antes de jugar).
        if let exe = executable, detectGraphicsAPI(forExecutable: exe) == .opengl,
           let opengl = WineEngineLocator.openglGameWineBinary() {
            log.log("Juego OpenGL: se usa el motor específico wine-unified-opengl (winemac.so con forward-compat GL).", level: .info)
            return opengl
        }
        return WineEngineLocator.gameWineBinary()
            ?? WineEngineLocator.clientWineBinary()
            ?? bottle.winePath
    }

    /// `true` si el juego integra **Epic Online Services (EOS)**: trae `EOSSDK-Win64-Shipping.dll`
    /// (junto al exe o en `<exe>_Data/Plugins/x86_64/`). Su init crashea bajo el motor unificado.
    func usesEpicOnlineServices(_ executable: String) -> Bool {
        let dir = (executable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(dir)/EOSSDK-Win64-Shipping.dll") { return true }
        let exeName = ((executable as NSString).lastPathComponent as NSString).deletingPathExtension
        return fm.fileExists(atPath: "\(dir)/\(exeName)_Data/Plugins/x86_64/EOSSDK-Win64-Shipping.dll")
    }

    /// Importa en el prefijo los **root CAs + intermedios de DigiCert** que la cadena de
    /// certificados de los servidores de Steam necesita para validar (login/CM/tienda).
    /// Imprescindible: el cert de Steam es **EV ECDSA** firmado por *DigiCert Global Root G3*,
    /// y macOS NO expone ese root por la vía que el `crypt32` de Wine auto-importa (su
    /// `SystemRootCertificates.keychain` no lo trae). Sin esto → `Crypto API failed certificate
    /// check` (root no confiable) → el logon se cuelga en el spinner. El `.reg` bundleado
    /// (`Resources/steam-certs.reg`) trae los roots de Mozilla + los intermedios ECC/RSA de
    /// Steam y se importa con `wine reg import` (el `certutil` de Wine NO persiste). Idempotente
    /// (marcador `.vessel-steam-certs`). Requiere además el `bcrypt` con gnutls del motor
    /// unificado (verifica firmas ECDSA); el motor publicado ya lo trae.
    func ensureSteamRootCertificates(prefix: String, wine: String) async {
        let marker = "\(prefix)/.vessel-steam-certs"
        if FileManager.default.fileExists(atPath: marker) { return }
        guard let regURL = Bundle.main.url(forResource: "steam-certs", withExtension: "reg")
            ?? VesselPaths.bundledResource("steam-certs.reg") else { return }
        guard FileManager.default.fileExists(atPath: regURL.path) else { return }
        // Copiar el .reg al drive_c del prefijo (ruta Windows accesible) e importarlo.
        let dest = "\(prefix)/drive_c/vessel-steam-certs.reg"
        do { try? FileManager.default.removeItem(atPath: dest)
             try FileManager.default.copyItem(atPath: regURL.path, toPath: dest) }
        catch { log.log("No se pudo copiar el .reg de certificados: \(error.localizedDescription)", level: .warn); return }
        log.log("Importando certificados raíz de Steam (DigiCert)…", level: .info)
        _ = try? await runWine(
            winePath: wine,
            arguments: ["reg", "import", #"C:\vessel-steam-certs.reg"#],
            prefix: prefix,
            environment: ["WINEPREFIX": prefix, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "winedbg.exe=d"],
            allowNonZeroExit: true
        )
        try? "ok".write(toFile: marker, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: dest)
    }

    /// Aplica al prefijo el bloque GLOBAL de `DllOverrides` que CrossOver pone de base en TODO bottle de
    /// Steam (extraído de `~/Library/Application Support/CrossOver/Bottles/Steam/user.reg` →
    /// `Resources/crossover-compat-overrides.reg`, ~58 entradas: quartz/devenum/amstream/mscoree/… en
    /// `native,builtin`). Es la MITAD estática del "clon de CrossOver": la otra mitad (los hacks por-juego)
    /// la aporta el motor `cxcompatdb` en tiempo de ejecución vía `CX_ROOT`. Juntas hacen que los juegos
    /// lanzados DESDE el cliente Steam en Wine funcionen igual que en CrossOver, sin ir juego a juego.
    /// El `.reg` es v5 en UTF-8 y se importa con `regedit /S` (verificado: aplica las 58 entradas). Es
    /// idempotente (marcador `.vessel-cx-overrides`) y debe correr con Steam parado (antes de lanzarlo).
    func ensureCrossOverCompatOverrides(prefix: String, wine: String) async {
        let marker = "\(prefix)/.vessel-cx-overrides"
        if FileManager.default.fileExists(atPath: marker) { return }
        guard let regURL = Bundle.main.url(forResource: "crossover-compat-overrides", withExtension: "reg")
            ?? VesselPaths.bundledResource("crossover-compat-overrides.reg") else { return }
        guard FileManager.default.fileExists(atPath: regURL.path) else { return }
        let dest = "\(prefix)/drive_c/vessel-cx-overrides.reg"
        do { try? FileManager.default.removeItem(atPath: dest)
             try FileManager.default.copyItem(atPath: regURL.path, toPath: dest) }
        catch { log.log("No se pudo copiar el .reg de overrides de CrossOver: \(error.localizedDescription)", level: .warn); return }
        log.log("Aplicando overrides de compatibilidad de CrossOver (base de todos los juegos desde Steam)…", level: .info)
        _ = try? await runWine(
            winePath: wine,
            arguments: ["regedit", "/S", #"C:\vessel-cx-overrides.reg"#],
            prefix: prefix,
            environment: ["WINEPREFIX": prefix, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "winedbg.exe=d"],
            allowNonZeroExit: true
        )
        try? "ok".write(toFile: marker, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: dest)
    }

    /// Escribe en el REGISTRO del bottle la config POR-JUEGO en `HKCU\Software\Wine\AppDefaults\<exe>`
    /// que Wine aplica por NOMBRE DE EJECUTABLE **lo lance quien lo lance — incluido Steam** (a
    /// diferencia de `WINEDLLOVERRIDES` en el entorno, que Steam NO hereda al lanzar el juego como hijo).
    /// Es exactamente lo que hace CrossOver (`crossover.tie`: `AppDefaults\<exe>\DllOverrides
    /// winegstreamer=disable`). Cubre el crash de vídeo Unity/Media Foundation: `winegstreamer` builtin
    /// CRASHEA al decodificar vídeo por MF en macOS (wine-steam no trae GStreamer); desactivarlo como
    /// builtin del juego omite el vídeo LIMPIO (no crashea) y el audio sigue por mfplat/XAudio2 (que NO
    /// se toca). Solo afecta a cada exe listado. Idempotente (reimporta). Llamar con Steam parado.
    func applySteamGameRegistry(in bottle: Bottle, wine: String) async {
        var reg = "Windows Registry Editor Version 5.00\r\n\r\n"
        // El webhelper moderno recomienda LargeAddressAware (CrossOver lo pone en el bottle de Steam).
        reg += "[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\steamwebhelper.exe]\r\n"
        reg += "\"LargeAddressAware\"=dword:00000001\r\n\r\n"
        var seen = Set<String>()
        for game in bottle.games {
            let exe = (game.executablePath as NSString).lastPathComponent
            let key = exe.lowercased()
            guard key.hasSuffix(".exe"), seen.insert(key).inserted else { continue }
            let escaped = exe.replacingOccurrences(of: "\\", with: "\\\\")
            reg += "[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\\(escaped)\\DllOverrides]\r\n"
            reg += "\"winegstreamer\"=\"disable\"\r\n\r\n"
        }
        let dest = "\(bottle.prefixPath)/drive_c/vessel-steam-appdefaults.reg"
        // .reg v5: UTF-16 LE con BOM (lo que `wine reg import` espera con certeza).
        var data = Data([0xFF, 0xFE])
        data.append(reg.data(using: .utf16LittleEndian) ?? Data())
        try? data.write(to: URL(fileURLWithPath: dest))
        _ = try? await runWine(
            winePath: wine,
            arguments: ["reg", "import", #"C:\vessel-steam-appdefaults.reg"#],
            prefix: bottle.prefixPath,
            environment: ["WINEPREFIX": bottle.prefixPath, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "winedbg.exe=d"],
            allowNonZeroExit: true
        )
        try? FileManager.default.removeItem(atPath: dest)
        log.log("Config por-juego aplicada en el registro (AppDefaults): los juegos se lanzan desde Steam sin el crash de vídeo (winegstreamer).", level: .info)
    }

    /// Escribe `steam.cfg` con `BootStrapperInhibitAll` para que Steam NO se
    /// autoactualice/verifique. Sin esto, cuando Steam se relanza sin
    /// `-noverifyfiles` detecta el wrapper como corrupto, intenta actualizar el
    /// cliente, la descarga falla bajo Wine (http error 0) y queda ladrillado
    /// con "Failed to load steamui.dll". Idempotente.
    func ensureSteamConfig(in bottle: Bottle) {
        let steamDir = bottle.steamDirectory
        guard FileManager.default.fileExists(atPath: steamDir) else { return }
        let cfg = "\(steamDir)/steam.cfg"
        let contents = "BootStrapperInhibitAll=enable\nBootStrapperForceSelfUpdate=disable\n"
        try? contents.write(toFile: cfg, atomically: true, encoding: .utf8)
    }

    /// Borra `steam.cfg` para PERMITIR que Steam verifique y se actualice a sí mismo
    /// (modo actualización, ver `launchSteam`). Contrapartida de `ensureSteamConfig`.
    func removeSteamConfig(in bottle: Bottle) {
        try? FileManager.default.removeItem(atPath: "\(bottle.steamDirectory)/steam.cfg")
    }

    /// True si el cliente de Steam instalado en el bottle es el MODERNO (usa
    /// `bin/cef/cef.win64/`). El cliente de la era Gcenx solo tiene `cef.win7x64` y su
    /// actualización estaba INHIBIDA a propósito (el updater fallaba en Gcenx con
    /// "http error 0"). Con el motor unificado el updater SÍ funciona (WINEMSYNC=0),
    /// así que un cliente antiguo se deja auto-actualizar una única vez.
    func isSteamClientModern(in bottle: Bottle) -> Bool {
        FileManager.default.fileExists(
            atPath: "\(bottle.steamDirectory)/bin/cef/cef.win64/steamwebhelper.exe"
        )
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
        let cfgCache = "\(bottle.steamDirectory)/config/htmlcache"
        if fm.fileExists(atPath: cfgCache) { try? fm.removeItem(atPath: cfgCache) }
        // Estado de crashes/GPU de la CEF: tras varios crashes del proceso GPU (SwiftShader), el
        // contador en "Local State" (+ GPUCache/Crashpad) hace que Chromium NO vuelva a arrancar el
        // webhelper del todo y el auto-login se CUELGA (verificado in-vivo tras muchos relanzamientos).
        // Se borran para arrancar SIEMPRE en frío. No se toca `steamapps` (juegos) ni `userdata`.
        let steamDir = bottle.steamDirectory
        // Estado volátil del CEF/Chromium que corrompe el arranque tras relanzamientos: además de
        // la caché GPU y el contador de crashes, el "Service Worker"/"Session Storage"/"databases"
        // mantienen sesiones a medio escribir que pueden dejar el webhelper vivo pero SIN pintar
        // ventana (verificado). Todo es recreable por Steam; nunca se toca `steamapps`/`userdata`.
        let cefState: Set<String> = ["gpucache", "crashpad", "shadercache", "code cache",
                                     "blob_storage", "local state", "service worker",
                                     "session storage", "databases", "dawncache"]
        if let top = try? fm.contentsOfDirectory(atPath: steamDir) {
            for entry in top where entry.lowercased() != "steamapps" && entry.lowercased() != "userdata" {
                let path = "\(steamDir)/\(entry)"
                if cefState.contains(entry.lowercased()) { try? fm.removeItem(atPath: path); continue }
                if let e = fm.enumerator(atPath: path) {
                    for case let rel as String in e where cefState.contains(((rel as NSString).lastPathComponent).lowercased()) {
                        try? fm.removeItem(atPath: "\(path)/\(rel)")
                    }
                }
            }
        }
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
    enum GameGraphicsAPI { case d3d9, d3d11, d3d12, opengl, other }

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
        // **Unreal Engine** (el exe real vive en `Binaries/Win64|Win32|WinGDK`): UE5 importa d3d12
        // (su RHI por defecto en Windows) Y d3d11.
        //  - UE5 que importa **d3d12** (AAA con Agility SDK: Palworld, etc.) → **D3D12 / D3DMetal de
        //    Apple**. D3DMetal es el traductor D3D12→Metal COMPLETO de Apple (GPTK): renderiza el juego
        //    entero — HUD, WebViews internos (notas del parche), efectos avanzados — y el audio va fino.
        //    Por **DXMT (D3D11)**, en cambio, UE5 AAA renderiza INCOMPLETO: paneles web en BLANCO,
        //    gráficos que no aparecen y **audio que PETARDEA**. Validado con Palworld: PERFECTO por
        //    D3DMetal, defectuoso por DXMT. (Antes «funcionaba» solo porque DXMT moría y el fallback
        //    caía a D3DMetal; al arreglar el arranque de DXMT se quedaba en él, defectuoso.)
        //  - UE sin d3d12 (solo D3D11, títulos más simples) → DXMT, que arranca limpio y le basta.
        let dirLower = dir.lowercased()
        let isUnreal = dirLower.contains("/binaries/win64")
            || dirLower.contains("/binaries/win32")
            || dirLower.contains("/binaries/wingdk")
        if isUnreal, exeImports(executable, anyOf: ["d3d11.dll", "dxgi.dll"]) {
            if exeImports(executable, anyOf: ["d3d12.dll"]) { return .d3d12 }
            return .d3d11
        }
        // **Vulkan NATIVO** (el exe importa `vulkan-1.dll` directamente: Godot 4, id Tech, etc.).
        // El motor UNIFICADO trae MoltenVK (Vulkan→Metal), así que estos juegos renderizan por su
        // Vulkan nativo. Se enrutan como .d3d11 (usan el motor unificado y `ensureGameDXMTDLLs` copia
        // `dxgi.dll`, que Godot IMPORTA para enumerar salidas/VSync aunque pinte por Vulkan — sin
        // ella el juego ni arranca: c0000135). NO se fuerza D3D11: el juego usa su Vulkan por defecto.
        // Va ANTES del check de d3d12 porque Godot tambien importa d3d12/opengl32. Validado con Godot
        // 4.3 (Project Manager renderiza por Vulkan en el motor unificado). Un juego DXVK NO importa
        // `vulkan-1` directamente (DXVK lo usa por dentro), asi que no cae aqui por error.
        if exeImports(executable, anyOf: ["vulkan-1.dll"]) {
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
        // Juegos con motor **OpenGL puro** (importan `opengl32.dll` y NINGÚN Direct3D): p. ej. Heroes
        // of Hammerwatch II (bgfx GL 3.2). En Apple Silicon bajo Wine el contexto GL 3.2 core se crea
        // por `winemac.so` (OpenGL→Metal de Apple) SOLO si es forward-compatible; muchos motores (bgfx)
        // piden 3.2 core sin ese bit → Wine lo rechaza (`ERROR_INVALID_VERSION_ARB`). El motor UNIFICADO
        // trae un `winemac.so` parcheado (CW Hack 24834) que, con `CX_FWD_COMPAT_GL_CTX=1`, inyecta el
        // bit y el contexto se crea. Se enruta como `.opengl` → motor unificado (ver `launch`).
        if exeImports(executable, anyOf: ["opengl32.dll"]) { return .opengl }
        // Juegos **.NET Core self-contained** (traen `coreclr.dll`) que renderizan por D3D en runtime
        // (helper `D3DCompiler_*`/`cimgui`/`Vortice` junto al exe, cargado desde código managed): NO
        // importan d3d en el PE → sin esto caerían a `.other` → Gcenx, cuyo wined3d NO da device D3D11
        // en el M5 ("A device supporting DirectX 11 is required"). Van a **D3D11→Metal por DXMT sobre
        // el motor UNIFICADO** (WineHQ 11.10): ese Wine 11.10 ejecuta el runtime .NET 8 (con los knobs
        // de `launchWineProcess`: ReadyToRun/TieredPGO/gcServer/W^X off) Y DXMT da D3D11 FL 11.1.
        // ✅ VALIDADO renderizando (Romestead, intro cinemático). La CLAVE fue el resync COMPLETO del
        // prefijo (`resyncGamePrefix` espera a `wineboot`); crashes previos eran resyncs a medias.
        let dirFiles = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        let low = dirFiles.map { $0.lowercased() }
        if low.contains("coreclr.dll"),
           low.contains(where: { $0.hasPrefix("d3dcompiler_") || $0 == "cimgui.dll" || $0.hasPrefix("vortice.") }) {
            return .d3d11
        }
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

    /// Lista ORDENADA de capas gráficas que tiene SENTIDO probar para este juego, empezando por la
    /// de arranque. La usa el fallback automático (`LaunchDiagnostics`) para NO enrutar un juego a
    /// una capa arquitectónicamente incompatible con su tipo — el bug que dejaba a un Unity D3D11
    /// probando GPTK (D3D12) y Gcenx (D3D9), fallando las tres y sin arrancar. Reglas:
    ///  - Override de usuario/perfil (`.gptk`/`.dxmt`/`.gcenx`) → SOLO esa capa (respeta su elección; nada de ciclo ciego).
    ///  - D3D12 real (FFT/AAA) → solo GPTK/D3DMetal (si falla es DRM, no capa).
    ///  - D3D9 → solo Gcenx (wine-dxmt no resuelve d3d9).
    ///  - Unity D3D11 → solo DXMT (GPTK mata el ratón de Unity; Gcenx es D3D9). Si DXMT falla, es cosa del motor, no de la capa.
    ///  - D3D11 64-bit no-Unity → DXMT y, como respaldo, Gcenx (juegos que importan d3d11 pero renderizan por d3d9, p. ej. Grim Dawn).
    ///  - 32-bit no-D3D9 → CrossOver/Gcenx y, como respaldo, DXMT.
    ///  - Carga dinámica (`.other`) → Gcenx primero, DXMT de respaldo (el gate ya existente para M-series nuevos).
    func fallbackLayers(forExecutable executable: String, effective eff: EffectiveLaunchConfig = EffectiveLaunchConfig()) -> [GameConfig.GraphicsLayer] {
        switch eff.graphicsOverride {
        case .gptk:  return [.gptk]
        case .dxmt:  return [.dxmt]
        case .gcenx: return [.gcenx]
        case .auto:  break
        }
        // Juegos .NET Core self-contained: DXMT sobre el motor UNIFICADO (WineHQ 11.10) ejecuta el
        // runtime .NET 8 Y da D3D11→Metal (validado: Romestead renderiza). Gcenx de respaldo (corre
        // .NET pero sin D3D11 en el M5). NUNCA gptk (Wine 9.0, viejo, rompe el loader de .NET 8).
        if isDotNetCoreGame(executable) { return [.dxmt, .gcenx] }
        // Juegos 32-bit: SIEMPRE van a CrossOver/gptk (launch32BitGame ignora la capa) y
        // `resolvedGraphicsLayer` devuelve `.gcenx` fijo → una lista de UN elemento evita el BUCLE de
        // reintentos (la capa nunca cambia, así que ciclar es inútil). Si falla, el auto-repair pasa a
        // Steam-real (juegos como CaveBlazers) o avisa; no gira en vano.
        if isExecutable32Bit(executable) { return [.gcenx] }
        let api = detectGraphicsAPI(forExecutable: executable)
        switch api {
        case .d3d12: return [.gptk]
        case .d3d9:  return [.gcenx]
        case .other: return [.gcenx, .dxmt]
        case .opengl: return [.dxmt]   // motor unificado (winemac.so parcheado); no ciclar motores
        case .d3d11:
            // Unity 6.x (6000.x+): SOLO D3DMetal de Apple (gptk). DXMT/mousefix cuelgan su init
            // gráfica, así que NUNCA se reintenta en DXMT (sería un cuelgue asegurado).
            if isUnity6OrNewer(executable) { return [.gptk] }
            if isUnityGame(executable) { return [.dxmt] }
            if isExecutable32Bit(executable) { return [.gcenx, .dxmt] }
            // D3D11 64-bit no-Unity (Unreal Engine: Palworld, etc.): DXMT→Metal, con D3DMetal de
            // Apple (gptk) como respaldo REAL. **NUNCA Gcenx**: para D3D11 64-bit moderno wined3d→
            // Vulkan→MoltenVK falla feature level en el M5 (inútil) Y `cleanExeAdjacentDXMTDLLs`
            // BORRARÍA las d3d11/dxgi locales de DXMT del juego → lo dejaría roto en el siguiente
            // lanzamiento (`__wine_unix_call unimplemented`). Regresión que rompió Palworld.
            return [.dxmt, .gptk]
        }
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
        var eff = effective ?? EffectiveLaunchConfig(graphicsOverride: graphicsOverride ?? .auto, esync: true, fsync: true)
        // Juegos **.NET Core**: msync/esync/fsync (las primitivas de sincronización RÁPIDA de Wine)
        // ROMPEN el threading/async de coreclr (thread pool + async I/O). Con ellas el runtime .NET
        // arranca pero la init gráfica falla → "An error has occurred" y NO se crea ventana (validado
        // aislando la variable: con msync=1 falla, con msync=0 RENDERIZA). Se apagan, igual que hace
        // el cliente Steam (que también usa async complejo). Sin msync, Romestead renderiza su intro.
        if isDotNetCoreGame(executable) {
            eff.msync = false; eff.esync = false; eff.fsync = false
        }
        let go = eff.graphicsOverride
        let allArgs = arguments + eff.launchArgs
        if eff.fromProfile, let r = eff.rating {
            log.log("Perfil de compatibilidad aplicado: \(r.label)\(eff.verified ? " ✓ verificado" : " (sin verificar)")", level: .info)
        }
        // MODO "STEAM REAL" (DRM real, como CrossOver): algunos juegos NO arrancan standalone
        // ni con Goldberg — se cierran en la init de su propio engine antes de tocar D3D
        // (p. ej. Grim Dawn, AppID 219990: exit 53 en la init de Engine.dll, sin llegar a los
        // gráficos, en TODOS los motores). Para ellos, en vez de emular la API, se arranca el
        // cliente Steam REAL conectado en el motor unificado y se lanza el juego en el MISMO
        // wineserver con su `steam_api` original → `SteamAPI_Init` habla con el cliente vivo y
        // el juego renderiza por DXMT→Metal. Es exactamente lo que hace CrossOver con su Wine
        // propietario. Se activa por perfil de compatibilidad (`useRealSteam`). Requiere sesión
        // iniciada en el Steam de Vessel; si no conecta, `launchViaRealSteam` lo avisa e intenta igual.
        // Steam real (DRM real con el cliente conectado). Aplica también a juegos cuyo lanzador es de
        // 32-bit pero arrancan un proceso de 64-bit (p. ej. Grim Dawn: `Grim Dawn.exe` de 32-bit lanza
        // `x64/Grim Dawn.exe`): NO filtrar por bitness aquí — se rompería. La decisión de usar Steam
        // real la marca el perfil (`useRealSteam`); si es un perfil obsoleto para un 32-bit puro que
        // ahora funciona con Goldberg, se limpia ese perfil, no se filtra por bitness a ciegas.
        // El modo Steam real se activa por el toggle del JUEGO (`useRealSteam`) o por el ajuste GLOBAL
        // "Modo Steam real para todos los juegos de Steam" (Ajustes). El global da la nube de Steam +
        // updates + DLC + logros nativos a toda la biblioteca de Steam, como CrossOver; el toggle por
        // juego permite anularlo (p. ej. Palworld, mejor en modo Vessel por D3DMetal).
        let steamRealGlobal = UserDefaults.standard.bool(forKey: "vessel.steamRealGlobal")
        if (eff.useRealSteam || steamRealGlobal), let appId = steamAppId, !appId.isEmpty {
            log.log("Modo Steam real para este juego (cliente Steam conectado: nube/updates/DLC/logros nativos)\(steamRealGlobal && !eff.useRealSteam ? " [global]" : "").", level: .info)
            return try await launchViaRealSteam(executable: executable, in: bottle, appId: appId, effective: eff)
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
                // Goldberg = jugar SIN Steam. Un cliente Steam REAL corriendo en el prefijo (residual de
                // un intento previo de Steam-real) ROMPE el `SteamAPI_Init` de Goldberg: el juego detecta
                // el Steam vivo, intenta usarlo y falla con "Steam must be running". Validado con HoH2 y
                // Cross Blitz: con Steam apagado + Goldberg arrancan; con Steam vivo, no. Matamos aquí el
                // cliente Steam del prefijo para garantizar que Goldberg emule limpio.
                try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
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
            // `forceGPTK`: usar el **GPTK/D3DMetal de Apple** (gptk-mythic), NO el motor propio
            // `wine-d3dmetal`. Este último MUERE al arrancar desde el botón de Vessel (~1 s) por el
            // contexto de spawn de la `.app` (identidad de bundle GUI que rompe la creación del device
            // Metal), mientras que el GPTK de Apple renderiza el juego COMPLETO desde la app (validado
            // con Dragon Is Dead, y con Palworld: menú, WebViews internos y audio correctos). El
            // wine-d3dmetal queda para el modo Steam-real (que ya se gestiona arriba y comparte
            // wineserver con el cliente Steam).
            return try await launchD3D12Game(executable: executable, in: bottle, steamAppId: steamAppId, effective: eff, forceGPTK: true)
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
        // Unity 6.x (6000.x+) de 64-bit → **D3DMetal de APPLE (gptk-mythic)**, NO DXMT. Su init
        // gráfica se CUELGA con DXMT (bucle de creación de IOSurfaces: falta el `d3d11` real sobre
        // Metal), y con wine-dxmt-mousefix (la ruta EOS) igual. El `d3d11` builtin de gptk-mythic ES
        // el D3DMetal de Apple → renderiza (validado con Dragon Is Dead, Unity 6000.3.9f1 + EOS,
        // hasta el menú). Es exactamente lo que hace CrossOver con Unity 6 + EOS. Se IGNORA un
        // override DXMT (colgaría igual), igual que en las ramas D3D9/32-bit. Unity ≤2023 (p. ej.
        // AK-xolotl 2022.3) NO entra aquí: va por DXMT/mousefix abajo, donde funciona.
        if isUnity6OrNewer(executable) {
            if go == .dxmt {
                log.log("Override DXMT ignorado en Unity 6.x: se usa D3DMetal de Apple (gptk-mythic), lo único que corre su init gráfica.", level: .info)
            }
            log.log("Unity 6.x (6000.x+) detectado → D3DMetal de Apple (gptk-mythic); DXMT cuelga su init gráfica.", level: .info)
            return try await launchD3D12Game(executable: executable, in: bottle, steamAppId: steamAppId, effective: eff, forceGPTK: true)
        }
        // D3D11 → wine-dxmt (DXMT→Metal). Aseguramos DXMT en el builtin del motor; si
        // no, los juegos usarían wined3d y fallarían con "InitializeEngineGraphics".
        let gameWine = resolveGameWine(for: bottle, executable: executable)
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
        cleanPrefixNativeGraphicsDLLs(prefixPath: bottle.prefixPath)
        // Modo Retina: sin él, DXMT/Metal renderiza a 1× y el juego ocupa un cuarto de la
        // pantalla (esquina superior izquierda) en pantallas Retina. Con él, resolución
        // física completa a pantalla completa. Respeta el flag del perfil (por defecto ON).
        await setMacDriverRetinaMode(prefix: bottle.prefixPath, wine: gameWine, enabled: eff.retina)

        // Para juegos de Steam: `steam_appid.txt` + `SteamAppId` permiten que la
        // Steamworks API arranque en modo standalone (sin el cliente Steam abierto,
        // que además correría en otro motor). Sin esto algunos juegos no arrancan.
        var env = gameLaunchEnvironment(prefix: bottle.prefixPath)
        // Motor UNIFICADO (WineHQ 11.10): (a) desactivar SOLO `winegstreamer` — el motor no trae backend
        // GStreamer, así que `winegstreamer.dll` (el backend de Media Foundation) CRASHEA al decodificar
        // vídeo por MF y tira el proceso (validado con Cross Blitz: crashea en el vídeo de intro tras
        // crear el device). ⚠️ NO desactivar el resto de la pila MF (`mfplat`/`mf`/`mfreadwrite`): el
        // builtin de **XAudio2** (que muchos juegos usan, p. ej. Palworld con `XAudio2_9Redist`) DEPENDE
        // de `mfplat`+`mfreadwrite` para decodificar audio — con ellos desactivados el audio degrada y
        // PETARDEA (validado con Palworld). Con solo `winegstreamer=d`, el decode de vídeo falla LIMPIO
        // (sin backend) pero XAudio2 conserva su MF → audio correcto Y sin el crash de Cross Blitz.
        // (b) Para juegos OpenGL, activar `CX_FWD_COMPAT_GL_CTX=1`: el `winemac.so` del unificado trae el
        // CW Hack 24834 que inyecta el bit forward-compatible que bgfx omite en su contexto GL 3.2 core
        // (sin él, Wine-macOS lo rechaza con ERROR_INVALID_VERSION_ARB → HoH2 no arranca).
        if WineEngineLocator.isUnifiedEngine(gameWine) {
            let base = env["WINEDLLOVERRIDES"] ?? ""
            let mfOff = "winegstreamer=d"
            env["WINEDLLOVERRIDES"] = base.isEmpty ? mfOff : "\(base);\(mfOff)"
            // Sync SERVER-SIDE (msync/esync/fsync=0) en el unificado: msync rompe el async socket
            // completion → Goldberg (que usa red local) falla `SteamAPI_Init` → el juego se cierra con
            // "Steam must be running". Validado: HoH2 con Goldberg + msync=0 llega al menú; con msync on,
            // no. Es el mismo motivo por el que el cliente Steam del unificado corre con sync off.
            env["WINEMSYNC"] = "0"; env["WINEESYNC"] = "0"; env["WINEFSYNC"] = "0"
        }
        if detectGraphicsAPI(forExecutable: executable) == .opengl {
            env["CX_FWD_COMPAT_GL_CTX"] = "1"
        }
        // Juegos **.NET Core**: NO deshabilitar `mscoree`. Aunque .NET Core usa `coreclr` (no el Mono
        // de Wine), el loader de Wine necesita `mscoree` PRESENTE para mapear los assemblies managed
        // (`System.Runtime.dll`, etc.); con `mscoree=d` el CLR aborta con "Could not load … Module not
        // found". VALIDADO aislando la variable: era el último eslabón para que Romestead renderice.
        if isDotNetCoreGame(executable), let ov = env["WINEDLLOVERRIDES"] {
            env["WINEDLLOVERRIDES"] = ov.replacingOccurrences(of: "mscoree,mshtml=d", with: "mshtml=d")
                                       .replacingOccurrences(of: "mscoree=d", with: "")
        }
        if let appId = steamAppId, !appId.isEmpty {
            let gameDir = (executable as NSString).deletingLastPathComponent
            try? appId.write(toFile: "\(gameDir)/steam_appid.txt", atomically: true, encoding: .utf8)
            env["SteamAppId"] = appId
            env["SteamGameId"] = appId
        }

        // Flags de motor: Unity (borderless fullscreen) o Unreal (`-d3d11`). Solo el que aplique.
        let engineArgs = unityLaunchArguments(forExecutable: executable)
            + unrealLaunchArguments(forExecutable: executable)
        let gameEngineLabel = WineEngineLocator.isUnifiedEngine(gameWine)
            ? "motor unificado" : "wine-dxmt"
        log.log("Lanzando juego con \(gameEngineLabel) (DXMT→Metal): \((executable as NSString).lastPathComponent)", level: .info)
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
    // MARK: - Prefijos AISLADOS por motor (nada se solapa)

    /// Prefijo AISLADO para un motor concreto, hermano del prefijo base (`<base>__<motor>`).
    /// Tiene su PROPIO `drive_c/windows` (DLLs de sistema del motor) y su propio registro, pero
    /// COMPARTE por symlink `Program Files (x86)`, `Program Files` y `users` con el prefijo base
    /// (mismos juegos y partidas, sin duplicar). Así dos motores de DISTINTA versión de Wine
    /// (p. ej. gptk = Wine 9 y el unificado = Wine 11) nunca se pisan las DLLs ni la sincronización
    /// del otro — la causa raíz de que reparar un juego rompiera otro. Idempotente.
    ///
    /// El motor unificado (que hospeda el cliente de Steam y el login) usa SIEMPRE el prefijo base;
    /// por eso este scoping se aplica solo a los demás motores (gptk, etc.), preservando Steam.
    private func engineScopedPrefix(base: String, engineTag: String, engineWine: String) async -> String {
        let fm = FileManager.default
        let scoped = "\(base)__\(engineTag)"
        let marker = "\(scoped)/.vessel-scoped-ready"
        if !fm.fileExists(atPath: marker) {
            try? fm.createDirectory(atPath: "\(scoped)/drive_c", withIntermediateDirectories: true)
            // Inicializa windows/ + registro PROPIOS del motor (wineboot en un prefijo limpio).
            await resyncGamePrefix(gameWine: engineWine, prefix: scoped)
            try? "ready".write(toFile: marker, atomically: true, encoding: .utf8)
        }
        linkSharedPrefixData(scoped: scoped, base: base)   // (re)enlaza juegos + partidas (idempotente)
        return scoped
    }

    /// Reemplaza en el prefijo scoped las carpetas de datos compartidos por symlinks al prefijo base,
    /// para que ambos vean los MISMOS juegos y partidas (sin duplicar disco) manteniendo `windows/`
    /// separado. Quita el directorio real que `wineboot` hubiera creado antes de enlazar.
    private func linkSharedPrefixData(scoped: String, base: String) {
        let fm = FileManager.default
        for rel in ["Program Files (x86)", "Program Files", "users"] {
            let link = "\(scoped)/drive_c/\(rel)"
            let target = "\(base)/drive_c/\(rel)"
            guard fm.fileExists(atPath: target) else { continue }
            if (try? fm.destinationOfSymbolicLink(atPath: link)) == target { continue } // ya enlazado
            try? fm.removeItem(atPath: link)
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        }
    }

    /// Traduce una ruta bajo el prefijo base a su equivalente bajo el prefijo scoped (mismo archivo
    /// vía symlink, pero con la unidad C: consistente DENTRO del prefijo del motor).
    private func scopedPath(_ path: String, base: String, scoped: String) -> String {
        guard path.hasPrefix("\(base)/") else { return path }
        return scoped + String(path.dropFirst(base.count))
    }

    private func launch32BitGame(executable rawExecutable: String, in bottle: Bottle, arguments: [String], steamAppId: String?, effective: EffectiveLaunchConfig = EffectiveLaunchConfig()) async throws -> Process {
        try await gptkManager.ensureInstalled { msg, pct in
            Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
        }
        guard let gptkWine = gptkManager.wineBinaryPath else {
            throw WineError.launchFailed("No se encontró el motor CrossOver (gptk-mythic) para juegos de 32-bit.")
        }
        // Prefijo AISLADO de gptk: nunca toca el prefijo unificado (Wine 11) de Steam/Grim Dawn.
        let prefix = await engineScopedPrefix(base: bottle.prefixPath, engineTag: "gptk", engineWine: gptkWine)
        let executable = scopedPath(rawExecutable, base: bottle.prefixPath, scoped: prefix)
        let isUnity = isUnityGame(executable)
        // Elección del backend de wined3d según el motor del juego (ver `setWined3dRenderer`):
        //  - Unity 32-bit → `vulkan` (MoltenVK; el GL legacy sale negro). Validado: A Short Hike.
        //  - Resto (GameMaker, etc.) → `gl` (Apple GLD→Metal). MoltenVK aborta con `vkCreateBufferView`
        //    en sus texel buffers. Validado: CaveBlazers renderiza con `gl` y muere con `vulkan`.
        let renderer = isUnity ? "vulkan" : "gl"
        log.log(isUnity
            ? "Capa gráfica: wined3d → Vulkan/MoltenVK → Metal (Unity 32-bit, render monohilo) con CrossOver"
            : "Capa gráfica: wined3d → OpenGL de Apple (GLD→Metal) (juego 32-bit) con CrossOver", level: .info)
        log.log("Preparando prefijo para el juego…", level: .info)
        try? await terminateWineProcesses(winePath: gptkWine, prefix: prefix)
        try? await killOrphanWineProcesses(prefix: prefix)
        await resyncGamePrefix(gameWine: gptkWine, prefix: prefix)
        // Quitar DLLs de traducción gráfica de OTROS motores (DXMT/vkd3d) del prefijo AISLADO Y de la
        // carpeta del juego (una DXMT local pisaría wined3d y forzaría MoltenVK → `vkCreateBufferView`).
        cleanPrefixNativeGraphicsDLLs(prefixPath: prefix, subdirs: ["syswow64"])
        cleanGameFolderGraphicsDLLs(forExecutable: executable)
        // Instalar el d3d11/dxgi/wined3d de gptk como archivos NATIVOS en el prefijo. El builtin de
        // 32-bit no carga solo en el WoW64 experimental de gptk (c0000135), como en la ruta D3D9.
        ensureD3D11NativeDLLs(prefixPath: prefix, engineWine: gptkWine)
        await setWined3dRenderer(prefix: prefix, wine: gptkWine, renderer: renderer)
        // Modo Retina en el prefijo AISLADO (el base lo tiene, el scoped se crea sin él): sin esto el
        // display de algunos juegos (GameMaker) falla al crear el swapchain (`DXGI_ERROR_UNSUPPORTED
        // 0x887a0004`) o renderiza a 1×. Idempotente. Respeta el flag del perfil (por defecto ON).
        await setMacDriverRetinaMode(prefix: prefix, wine: gptkWine, enabled: effective.retina)

        var env: [String: String] = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "MVK_CONFIG_LOG_LEVEL": "0",
            // d3d10*/d3d11/dxgi/wined3d como nativos (los que instaló `ensureD3D11NativeDLLs`).
            "WINEDLLOVERRIDES": "d3d11,d3d10,d3d10core,d3d10_1,dxgi,wined3d=n,b;mscoree,mshtml=d;winemenubuilder.exe=d"
        ]
        // Sincronización: Unity → msync/esync (validado con A Short Hike). Resto (GameMaker, etc.) →
        // sync server-side (msync/esync/fsync = 0), validado con CaveBlazers; msync le da problemas.
        if isUnity {
            env["WINEMSYNC"] = "1"; env["WINEESYNC"] = "1"
        } else {
            env["WINEMSYNC"] = "0"; env["WINEESYNC"] = "0"; env["WINEFSYNC"] = "0"
        }
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
            prefix: prefix,
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

    /// Fuerza el backend de wined3d (`HKCU\Software\Wine\Direct3D` → `renderer`).
    ///  - `vulkan`: wined3d → MoltenVK → Metal (Unity 32-bit; sin él cae al GL legacy roto → negro).
    ///  - `gl`: wined3d → OpenGL de Apple (GLD → Metal). IMPRESCINDIBLE para juegos D3D11 de 32-bit
    ///    cuyo uso de *texel buffers* MoltenVK no soporta (GameMaker: `vkCreateBufferView` aborta el
    ///    juego). En gptk-mythic el GL de Apple SÍ funciona (validado con CaveBlazers).
    private func setWined3dRenderer(prefix: String, wine: String, renderer: String) async {
        _ = try? await runWine(
            winePath: wine,
            arguments: ["reg", "add", #"HKCU\Software\Wine\Direct3D"#, "/v", "renderer",
                        "/t", "REG_SZ", "/d", renderer, "/f"],
            prefix: prefix,
            environment: ["WINEPREFIX": prefix, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "winedbg.exe=d"],
            allowNonZeroExit: true
        )
    }

    /// Atajo histórico: `renderer=vulkan` (usado por la ruta D3D9 de 32-bit en Gcenx).
    private func setWined3dRendererVulkan(prefix: String, wine: String) async {
        await setWined3dRenderer(prefix: prefix, wine: wine, renderer: "vulkan")
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

    /// Prepara el prefijo para juegos **D3D11 de 32-bit** en gptk (ver `launch32BitGame`): copia
    /// `d3d10*`/`d3d11`/`dxgi`/`wined3d` *builtin* del motor como **archivos nativos** en **syswow64**
    /// (SOLO 32-bit). Es el mismo problema que en D3D9: el override `=b` por sí solo NO carga el d3d11
    /// builtin de 32-bit en el WoW64 experimental de gptk (`c0000135 "d3d11.dll not found"`, sobre todo
    /// tras sincronizar el prefijo con otro motor). Con los archivos presentes, wined3d renderiza por
    /// el backend elegido (`gl` para GameMaker, `vulkan` para Unity). Idempotente.
    ///
    /// ⚠️ NUNCA toca `system32` (64-bit): el bottle es COMPARTIDO por todos los juegos de la tienda, y
    /// un juego de 64-bit (p. ej. Grim Dawn por DXMT) tiene ahí su propio d3d11 — pisarlo lo rompería.
    /// Un juego de 32-bit solo carga DLLs de syswow64, así que con eso basta.
    private func ensureD3D11NativeDLLs(prefixPath: String, engineWine: String) {
        let binDir = (engineWine as NSString).deletingLastPathComponent
        let engineRoot = (binDir as NSString).deletingLastPathComponent
        let i386 = "\(engineRoot)/lib/wine/i386-windows"
        let syswow = "\(prefixPath)/drive_c/windows/syswow64"
        try? FileManager.default.createDirectory(atPath: syswow, withIntermediateDirectories: true)
        for dll in ["wined3d.dll", "dxgi.dll", "d3d10.dll", "d3d10_1.dll", "d3d10core.dll", "d3d11.dll"] {
            copyDLLOverwrite(from: "\(i386)/\(dll)", to: "\(syswow)/\(dll)")
        }
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

    /// Siembra los `d3dcompiler_43`/`d3dx9_43`/`d3dx9_42` **NATIVOS de Microsoft**
    /// (Resources/redist) en el prefijo. IMPRESCINDIBLE para juegos **DX11 en el motor
    /// unificado**: DXMT aporta el `d3d11` builtin, pero muchos juegos (p. ej. Grim Dawn)
    /// compilan sus shaders con `d3dcompiler_43`, y el builtin de Wine **importa
    /// `wined3d.dll`**, que el motor unificado NO tiene (lo reemplazó DXMT) → el
    /// `d3dcompiler` builtin no carga → "Couldn't initialize graphics engine" / pantalla
    /// negra (verificado in-vivo con Grim Dawn). El de Microsoft es autocontenido (compila
    /// HLSL sin GPU) y va perfecto bajo DXMT. Debe acompañarse del override `native` (ver
    /// `shaderCompilerOverrides`) o Wine seguiría prefiriendo su builtin. Idempotente.
    private func ensureNativeShaderCompiler(in bottle: Bottle) {
        guard let redist = Self.d3dx9RedistDirectory() else {
            log.log("d3dcompiler nativo no encontrado en Resources/redist; algunos juegos DX11 podrían no iniciar.", level: .warn)
            return
        }
        let syswow = "\(bottle.prefixPath)/drive_c/windows/syswow64"
        let system32 = "\(bottle.prefixPath)/drive_c/windows/system32"
        try? FileManager.default.createDirectory(atPath: syswow, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: system32, withIntermediateDirectories: true)
        for dll in ["d3dcompiler_43.dll", "d3dx9_43.dll", "d3dx9_42.dll"] {
            copyDLLOverwrite(from: "\(redist)/x32/\(dll)", to: "\(syswow)/\(dll)")
            copyDLLOverwrite(from: "\(redist)/x64/\(dll)", to: "\(system32)/\(dll)")
        }
    }

    /// Lanza un juego **D3D12** con **GPTK / D3DMetal** (D3D12→Metal nativo de
    /// Apple), la misma vía que CrossOver/Whisky/Mythic. Es lo único que ejecuta de
    /// forma fiable juegos D3D12 AAA con DirectX 12 Agility SDK (como FF Tactics):
    /// el `d3d12.dll` builtin de D3DMetal ignora por diseño el `D3D12Core.dll` de
    /// Microsoft que el juego trae en su subcarpeta `D3D12/` — cargar ese core real
    /// de Microsoft (lo que hacía vkd3d) es lo que provocaba el crash con puntero
    /// corrupto dentro del juego. El cliente de Steam se lanza EN el mismo wine de
    /// GPTK (mismo wineserver) para que el DRM de Steamworks funcione.
    private func launchD3D12Game(executable: String, in bottle: Bottle, steamAppId: String?, effective: EffectiveLaunchConfig = EffectiveLaunchConfig(), forceGPTK: Bool = false) async throws -> Process {
        let gameDir = (executable as NSString).deletingLastPathComponent
        let fm = FileManager.default

        // 1) Motor: por defecto el motor D3DMetal propio (`wine-d3dmetal`, WineHQ 11.10 + D3DMetal
        //    de Apple), que corre D3D12→Metal en Wine MODERNO. EXCEPCIÓN: **Unity 6.x (6000.x+)
        //    que renderiza por D3D11** (no D3D12), o `forceGPTK` → GPTK/D3DMetal (gptk-mythic): su
        //    `d3d11` builtin ES el D3DMetal de Apple, mientras que en wine-d3dmetal el `d3d11` es
        //    DXMT y se CUELGA en la init gráfica de Unity 6 (bucle de IOSurfaces). Es la receta con
        //    la que CrossOver corre Unity 6 + EOS (Dragon Is Dead). Si wine-d3dmetal no está, GPTK
        //    como fallback auto-descargable igualmente.
        let unity6NeedsAppleD3D11 = isUnity6OrNewer(executable)
            && detectGraphicsAPI(forExecutable: executable) != .d3d12
        let preferGPTK = forceGPTK || unity6NeedsAppleD3D11
        let useD3DMetalEngine = !preferGPTK && WineEngineLocator.isD3DMetalEngineInstalled()
        let d3d12Wine: String
        if useD3DMetalEngine, let w = WineEngineLocator.d3dmetalWineBinary() {
            log.log("Preparando el motor D3DMetal propio (WineHQ 11.10) para juego D3D12…", level: .info)
            d3d12Wine = w
        } else {
            if preferGPTK {
                log.log("Unity 6.x (D3D11) → GPTK/D3DMetal (gptk-mythic): usa el d3d11 REAL de Apple, no DXMT (que cuelga la init).", level: .info)
            } else {
                log.log("Preparando GPTK/D3DMetal para juego D3D12…", level: .info)
            }
            try await gptkManager.ensureInstalled { msg, pct in
                Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
            }
            guard let gptkWine = gptkManager.wineBinaryPath else {
                throw WineError.launchFailed("No se pudo localizar el wine de GPTK/D3DMetal.")
            }
            d3d12Wine = gptkWine
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

        // 4) Re-sincronizar el prefijo al motor D3D12 elegido y cerrar cualquier wine previo
        //    (p.ej. el cliente Steam en otro motor). El juego corre solo en D3DMetal.
        log.log("Preparando el prefijo para el motor D3D12…", level: .info)
        try? await terminateWineProcesses(winePath: d3d12Wine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
        await resyncGamePrefix(gameWine: d3d12Wine, prefix: bottle.prefixPath)

        // 5) Lanzar el juego con el entorno de D3DMetal (del motor propio o de GPTK).
        var env = useD3DMetalEngine
            ? d3dMetalUnifiedEnvironment(prefix: bottle.prefixPath)
            : gptkManager.d3dMetalEnvironment(prefix: bottle.prefixPath)
        if let appId = steamAppId, !appId.isEmpty {
            env["SteamAppId"] = appId
            env["SteamGameId"] = appId
        }
        // Unity sobre GPTK/D3DMetal: fullscreen borderless + render MONOHILO (`-force-gfx-direct`),
        // igual que el resto de paths Unity — el fullscreen EXCLUSIVO revienta el swapchain y el
        // multihilo casca en Unity 6 + EOS (Dragon Is Dead). Para D3D12 no-Unity (FFT), vacío.
        let unityArgs = preferGPTK ? unityLaunchArguments(forExecutable: executable, singleThreaded: true) : []
        let engineLbl = useD3DMetalEngine ? "motor D3DMetal Vessel (WineHQ 11.10)" : "GPTK/D3DMetal + Goldberg"
        log.log("Lanzando juego D3D12 con \(engineLbl): \((executable as NSString).lastPathComponent)", level: .info)
        return try await launchWineProcess(
            winePath: d3d12Wine,
            prefix: bottle.prefixPath,
            arguments: [executable] + unityArgs + effective.launchArgs,
            environment: env,
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective,
            d3dMetalGame: useD3DMetalEngine
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
        // Un "Logged On" del connection_log es HISTÓRICO: persiste en disco aunque Steam se
        // haya cerrado/crasheado sin escribir "Logged Off". Sin comprobar que steam.exe sigue
        // vivo, un log viejo hacía que "Abrir Steam" cortocircuitara ("Steam abierto y conectado ✓"
        // sin lanzar ninguna ventana → "no abre nada"). Si no hay proceso, NO está conectado.
        guard isWineProcessRunning(matching: "steam.exe") else { return false }
        let logPath = "\(bottle.steamDirectory)/logs/connection_log.txt"
        guard let data = FileManager.default.contents(atPath: logPath),
              let text = String(data: data, encoding: .utf8) else { return false }
        // Estado real = el ÚLTIMO evento relevante del log COMPLETO. El `connection_log` ACUMULA
        // entre arranques, así que un "Logged On" de una sesión previa daba un FALSO POSITIVO
        // (isSteamConnected=true con el cliente recién arrancado aún SIN sesión). Se corrige
        // tomando el último evento y tratando "Client version" (arranque del cliente) como
        // "aún sin sesión": si lo último es un arranque o un "Logged Off"/desconexión → NO
        // conectado; solo un "Logged On," posterior cuenta como conectado.
        var connected = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("Logged On,") {
                connected = true
            } else if line.contains("Client version") || line.contains("Logged Off,") || line.contains("ConnectionDisconnected") {
                connected = false
            }
        }
        return connected
    }

    /// ¿Está en pantalla el diálogo de Wine **"Steamwebhelper no responde"**? Señala que el
    /// webhelper (la UI de Steam) se colgó (caché CEF corrupta): `launchSteam` reusaría ese
    /// cliente roto y el login no llegaría nunca. Detectado por el título de la ventana, permite
    /// auto-repararlo AL INSTANTE (reinicio limpio) en vez de esperar la ventana de gracia — y de
    /// paso el propio reinicio CIERRA el diálogo, para que el usuario no se quede mirándolo.
    private func isSteamWebHelperHung() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            let name = (w[kCGWindowName as String] as? String ?? "").lowercased()
            if name.contains("no responde") || name.contains("not responding") { return true }
        }
        return false
    }

    /// True si el cliente de Steam tiene realmente una VENTANA en pantalla (no solo el backend
    /// conectado). El CEF puede quedar colgado —proceso vivo, login por JWT hecho— pero SIN crear
    /// su ventana Cocoa (verificado in-vivo: 3 `steamwebhelper` vivos, 0 ventanas, tras degradar la
    /// caché CEF con muchos relanzamientos). `isSteamConnected` da true igual, así que el cliente
    /// "abre y conecta" sin que el usuario vea nada. Se detecta por el TAMAÑO de la ventana:
    /// `kCGWindowBounds` NO exige permiso de grabación de pantalla (el título `kCGWindowName` sí),
    /// así que es fiable siempre. Incluye ventanas tapadas por otras (siguen `onScreen`), de modo
    /// que NO reinicia si la ventana existe pero está detrás de Vessel; solo si no hay ninguna.
    private func steamClientWindowVisible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            guard owner.contains("wine") || owner.contains("steam") else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
            let width = (b["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (b["Height"] as? NSNumber)?.doubleValue ?? 0
            // La ventana del cliente Steam es grande; ignora tooltips / sub-superficies pequeñas del CEF.
            if width >= 640, height >= 400 { return true }
        }
        return false
    }

    /// Asegura que el cliente Steam está CORRIENDO y **conectado** en `clientWine` (mismo
    /// motor que usará el juego, para compartir wineserver → DRM). Lo arranca si hace falta y
    /// espera hasta `timeoutSeconds` a que el `connection_log` confirme el logon. Devuelve si
    /// llegó a conectar. Con `-tcp` la conexión al CM es estable bajo Wine (el UDP se caía).
    func ensureSteamConnected(in bottle: Bottle, clientWine: String, timeoutSeconds: Int = 90, background: Bool = false) async -> Bool {
        // No basta con la conexión (login por JWT / backend vivo): para el cliente VISIBLE hay que
        // confirmar además que el CEF creó su ventana. Si no, "conecta" pero el usuario no ve nada.
        // En modo background (DRM) NO se exige ventana (Steam corre sin UI a propósito, `-silent`).
        if isSteamConnected(in: bottle), background || steamClientWindowVisible() { return true }
        // Estado EN VIVO para el usuario (banner no bloqueante): que SIEMPRE sepa qué pasa.
        NotificationService.shared.status("Abriendo el cliente de Steam…")
        // Arrancar Steam SIEMPRE que no esté conectado: `launchSteam` ya es idempotente (si
        // `steam.exe` corre, se reutiliza). NO gatear en `steamwebhelper` — pgrep lista zombies
        // que `pkill` no puede reapear, y eso hacía que se SALTARA el arranque (Steam nunca abría).
        do { _ = try await launchSteam(in: bottle, using: clientWine, background: background) }
        catch { log.log("No se pudo arrancar el cliente Steam: \(error.localizedDescription)", level: .error) }
        NotificationService.shared.status("Esperando a que Steam inicie sesión (la primera vez puede tardar un poco)…")
        // Espera al login. AUTO-REPARACIÓN: si Steam sigue vivo pero SIN iniciar sesión tras una
        // ventana de gracia, el webhelper puede estar colgado/con la caché CEF corrupta (ventana
        // "Steamwebhelper no responde"). `launchSteam` por sí solo REUSA ese Steam roto sin
        // arreglarlo (idempotencia por `steam.exe` vivo), así que el login no llega nunca. Aquí
        // forzamos reinicios limpios (matar + limpiar caché CEF + relanzar, que reinstala el
        // wrapper `--single-process`) para que el webhelper renderice y el login complete.
        let graceSeconds = 30
        var restarts = 0
        var lastRestartElapsed = -100
        for elapsed in 0..<timeoutSeconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if isSteamConnected(in: bottle), background || steamClientWindowVisible() { NotificationService.shared.status(nil); return true }
            // MODO BACKGROUND (DRM): NO reiniciar. El multiproceso muestra "Steamwebhelper no
            // responde" (su subproceso GPU crashea) pero el cliente LOGUEA por JWT igualmente;
            // reiniciar solo reinicia el reloj del login y nunca converge. Solo esperamos.
            if background { continue }
            // Reinicio limpio del cliente (máx 2 veces): AL INSTANTE si aparece el diálogo
            // "Steamwebhelper no responde" (webhelper colgado → el reinicio lo CIERRA y da caché
            // CEF limpia), o si simplemente tarda demasiado (cada `graceSeconds`). `settled` deja
            // ~15 s tras cada reinicio para que el nuevo cliente arranque antes de re-evaluar.
            let settled = elapsed - lastRestartElapsed >= 15
            let hung = settled && isSteamWebHelperHung()
            let connected = isSteamConnected(in: bottle)
            // Conectado (JWT) pero el CEF NO ha creado su ventana tras un margen AMPLIO (el CEF sano
            // tarda ~40-60 s en pintar por DXMT/SwiftShader; margen mayor que `settled` para no
            // reiniciar un arranque legítimo en curso) → cuelgue invisible: reiniciar limpio.
            // El CEF NATIVO del motor completo (wine-full) tarda más en pintar (multiproceso, sin
            // wrapper single-process); margen mayor para no reiniciar un arranque legítimo en curso.
            let noWindowGrace = WineEngineLocator.isFullEngine(clientWine) ? 70 : 45
            let connectedNoWindow = !background && connected && !steamClientWindowVisible()
                && (elapsed - lastRestartElapsed >= noWindowGrace)
            // "Demasiado lento" SOLO si aún NO conecta. Si ya conectó, el problema es la ventana, que
            // gobierna `connectedNoWindow` con su propio margen → no reiniciamos prematuramente un CEF
            // que está pintando.
            let tooSlow = !connected && elapsed > 0 && elapsed % graceSeconds == 0
            // El motor completo (wine-full) lanza el cliente como app INDEPENDIENTE (open/launcher):
            // Vessel NO debe reiniciarlo/matarlo (rompería el proceso desacoplado y duplicaría). Solo
            // se espera a que el CEF pinte (la launcher lo crea de forma fiable). Sin auto-reparación.
            if restarts < 2, !WineEngineLocator.isFullEngine(clientWine),
               hung || connectedNoWindow || tooSlow, isWineProcessRunning(matching: "steam.exe") {
                restarts += 1
                lastRestartElapsed = elapsed
                NotificationService.shared.status("Steam no responde; reiniciándolo automáticamente…")
                log.log("Reinicio limpio del cliente Steam (intento \(restarts); \(hung ? "webhelper colgado" : connectedNoWindow ? "conectado sin ventana (CEF colgado)" : "sin login en \(elapsed)s"))…", level: .warn)
                try? await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
                try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
                cleanCEFCache(in: bottle)
                do { _ = try await launchSteam(in: bottle, using: clientWine) }
                catch { log.log("No se pudo relanzar el cliente Steam: \(error.localizedDescription)", level: .error) }
                NotificationService.shared.status("Esperando a que Steam inicie sesión…")
            }
        }
        // Al rendirnos, si el webhelper sigue colgado, cerramos ese Steam roto: dejar el diálogo
        // "no responde" abierto no sirve de nada y solo confunde. El aviso lo da el llamante.
        // EXCEPCIÓN: en modo background NO se cierra — el "no responde" es cosmético (multiproceso)
        // y el cliente puede estar ya logueado/logueándose por JWT; matarlo tumbaría el DRM.
        if !background, isSteamWebHelperHung() {
            log.log("Steam no llegó a iniciar sesión y su webhelper sigue colgado; se cierra el cliente roto.", level: .warn)
            try? await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
        }
        NotificationService.shared.status(nil)
        return isSteamConnected(in: bottle)
    }

    /// El modo Steam real no pudo confirmar la sesión del cliente Steam (login no completado:
    /// primera vez, Steam Guard, o límite temporal de Steam tras muchos arranques). En vez de
    /// lanzar el juego —que moriría sin DRM y sin feedback ("no abre nada")— AVISAMOS al usuario
    /// y dejamos el cliente de Steam ABIERTO (ya lo arrancó `ensureSteamConnected`) para que
    /// inicie sesión y lance el juego desde su biblioteca de Steam. Cero fricción, acción clara.
    private func steamRealNotConnected(gameExecutable: String, in bottle: Bottle) -> WineError {
        let name = ((gameExecutable as NSString).lastPathComponent as NSString).deletingPathExtension
        // El juego SE LANZA SOLO desde Vessel (el usuario ya no abre Steam ni lo lanza desde su
        // biblioteca — Steam corre invisible en segundo plano solo para el DRM). El mensaje depende
        // de si ya hay una sesión de Steam guardada:
        //  · CON sesión → fue transitorio (Steam aún arrancaba): reintentar, sin tocar nada.
        //  · SIN sesión → PRIMERA vez: iniciar sesión UNA vez con el login propio de Vessel.
        let hasSession = hasSteamSession(in: bottle)
        if hasSession {
            NotificationService.shared.alert(
                title: "\(name): reintenta en un momento",
                body: "Steam se estaba abriendo en segundo plano y aún no había iniciado sesión. Vuelve a pulsar Jugar en unos segundos — se lanza solo, no tienes que abrir nada.")
            log.log("Steam no confirmó sesión a tiempo (sesión presente); se pide reintentar.", level: .warn)
            return WineError.launchFailed("\(name): Steam estaba arrancando. Reintenta en unos segundos; se lanza solo.")
        } else {
            NotificationService.shared.alert(
                title: "\(name): inicia sesión en Steam",
                body: "Este juego usa el DRM de Steam. La PRIMERA vez, inicia sesión en Steam desde Vessel (botón de Steam, arriba → Iniciar sesión) una sola vez; después se lanzará automáticamente en segundo plano, sin abrir nada.")
            log.log("Steam sin sesión guardada; se guía al usuario al login propio de Vessel.", level: .warn)
            return WineError.launchFailed("\(name) necesita tu sesión de Steam. Inicia sesión en Steam desde Vessel la primera vez; luego se lanza solo.")
        }
    }

    /// ¿Hay una sesión de Steam disponible para auto-login por JWT? True si el cliente tiene una
    /// cuenta recordada (`loginusers.vdf` con `MostRecent`/`RememberPassword`) o si el login propio
    /// de Vessel guardó un `refresh_token`. Distingue "primera vez" (guiar al login) de un fallo
    /// transitorio (Steam aún arrancando → reintentar).
    private func hasSteamSession(in bottle: Bottle) -> Bool {
        let loginusers = "\(bottle.steamDirectory)/config/loginusers.vdf"
        if let s = try? String(contentsOfFile: loginusers, encoding: .utf8),
           s.contains("\"MostRecent\"") || s.contains("\"RememberPassword\"") {
            return true
        }
        return !(UserDefaults.standard.string(forKey: "steam.refreshToken") ?? "").isEmpty
    }

    /// Siembra la sesión del cliente de Steam desde el login NATIVO de Vessel (`SteamAuthService`)
    /// cuando el cliente NO tiene sesión guardada pero Vessel SÍ tiene un `refresh_token` (de tipo
    /// SteamClient, `platform_type=1`). Así un usuario NUEVO puede jugar títulos con DRM que exigen
    /// Steam abierto SIN tener que iniciar sesión en el CEF (que en el M5 no renderiza para meter
    /// credenciales). Idempotente y best-effort: si ya hay sesión, no toca nada.
    private func maybeSeedSteamSession(in bottle: Bottle, wine: String) async {
        if SteamClientSeeder.shared.hasSeededSession(in: bottle) { return }
        let d = UserDefaults.standard
        let login = d.string(forKey: "steam.accountName") ?? ""
        let token = d.string(forKey: "steam.refreshToken") ?? ""
        let sid = UInt64(d.string(forKey: "steam.steamID64") ?? "") ?? 0
        guard !login.isEmpty, !token.isEmpty, sid > 0 else { return }
        log.log("Usuario sin sesión en el cliente de Steam; sembrando el auto-login desde el login de Vessel…", level: .info)
        let ok = await SteamClientSeeder.shared.seed(login: login, steamID64: sid, personaName: login,
                                                     refreshToken: token, in: bottle, wine: wine)
        log.log(ok ? "Sesión de Steam sembrada ✓ (auto-login sin CEF)." : "No se pudo sembrar la sesión de Steam (se abrirá el login).", level: ok ? .info : .warn)
    }

    /// MODO "STEAM REAL" (nuestro equivalente a CrossOver, invisible): lanza un juego DRM de
    /// Steam con el cliente Steam REAL corriendo y **conectado** en el MISMO motor/wineserver
    /// que el juego, para que `SteamAPI_Init` hable con él (DRM real, como en Windows).
    /// Usa el **motor unificado** (cliente CEF + juego DXMT/Metal en un solo wineserver,
    /// lo que hace CrossOver con su Wine propietario); si no está disponible, cae a
    /// GPTK/D3DMetal (el modelo anterior).
    func launchViaRealSteam(executable: String, in bottle: Bottle, appId: String,
                            effective: EffectiveLaunchConfig = EffectiveLaunchConfig()) async throws -> Process {
        // 1) DRM REAL: restaurar el steam_api ORIGINAL del juego (deshacer Goldberg) + appid.
        goldbergManager.restoreGame(gameExecutable: executable)
        let gameDir = (executable as NSString).deletingLastPathComponent
        try? appId.write(toFile: "\(gameDir)/steam_appid.txt", atomically: true, encoding: .utf8)

        // 2) Motor según la API gráfica del juego:
        //    · D3D11 (Unity/Unreal/…) → motor UNIFICADO (DXMT→Metal); cliente y juego en su
        //      wineserver. Es lo que valida Grim Dawn.
        //    · D3D12 (Agility SDK, p. ej. FFT: The Ivalice Chronicles, AppID 1004640) → el
        //      unificado NO lo corre (solo D3D11); va por GPTK/D3DMetal (D3D12→Metal), con el
        //      cliente Steam en el MISMO wineserver de GPTK para el DRM. Se salta la rama unificada.
        let isD3D12 = detectGraphicsAPI(forExecutable: executable) == .d3d12
        if !isD3D12 {
        try? await dependencyManager.ensureUnifiedEngine { msg, pct in
            Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
        }
        if let unifiedWine = WineEngineLocator.clientWineBinary(),
           WineEngineLocator.isUnifiedEngine(unifiedWine) {
            ensureSteamConfig(in: bottle)
            log.log("Modo Steam real (motor unificado): preparando el cliente Steam conectado…", level: .info)
            // Cliente en SEGUNDO PLANO (multiproceso `-silent`): loguea por JWT sin ventana ni
            // colgarse (a diferencia del wrapper single-process del CEF). Para el DRM basta con
            // Steam vivo + logueado; la UI no se necesita. Timeout amplio (el login tarda ~45-60s).
            let connected = await ensureSteamConnected(in: bottle, clientWine: unifiedWine, timeoutSeconds: 120, background: true)
            // Sin sesión en Steam no hay DRM: en vez de lanzar el juego (que moriría en
            // silencio → "no abre nada"), AVISAMOS al usuario y dejamos el cliente Steam
            // ABIERTO para que inicie sesión y lo lance desde su biblioteca de Steam (cero
            // fricción, acción clara — como haría CrossOver).
            if !connected { throw steamRealNotConnected(gameExecutable: executable, in: bottle) }
            log.log("Cliente Steam conectado; lanzando el juego con DRM real.", level: .info)

            // Juego en el MISMO wineserver que el cliente → la sincronización DEBE
            // coincidir (WINEMSYNC/ESYNC/FSYNC=0, como el cliente): mezclar esync entre
            // procesos del mismo wineserver aborta Wine. Por eso NO se pasa `effective`
            // a launchWineProcess (su overlay pisaría el sync); lo esencial del perfil
            // (args y entorno extra) se aplica a mano.
            await setMacDriverRetinaMode(prefix: bottle.prefixPath, wine: unifiedWine, enabled: effective.retina)
            // Juegos DX11 por DXMT: el `d3d11` builtin del motor ES DXMT, pero muchos juegos
            // compilan shaders con `d3dcompiler_43` (cuyo builtin de Wine importa `wined3d`,
            // ausente en el motor unificado → "Couldn't initialize graphics engine"). Sembramos
            // el d3dcompiler/d3dx9 NATIVO de Microsoft + lo forzamos por override. También
            // dejamos las DLLs de DXMT junto al exe (idempotente). Verificado con Grim Dawn.
            ensureNativeShaderCompiler(in: bottle)
            ensureGameDXMTDLLs(gameExecutable: executable, gameWine: unifiedWine)
            var env = steamClientEnvironment(prefix: bottle.prefixPath, wine: unifiedWine)
            env["SteamAppId"] = appId
            env["SteamGameId"] = appId
            let baseOverrides = env["WINEDLLOVERRIDES"]
            // El motor unificado NO trae backend GStreamer → `winegstreamer.dll` CRASHEA al decodificar
            // cualquier vídeo por Media Foundation (worker de rtworkq) y tira el proceso ENTERO, aunque
            // el juego ya haya creado el device y renderizado toda la init. Validado con Cross Blitz
            // (Unity reproduce un vídeo de intro por MF). Deshabilitar MF hace que el VideoPlayer falle
            // limpio y OMITA el vídeo (no es fatal; el audio va por FMOD, no por MF). Solo aquí: los
            // motores de juego (wine-dxmt*/gptk*) SÍ traen GStreamer y reproducen cutscenes legítimas.
            let mfOff = "winegstreamer=d;mfplat=d;mf=d;mfreadwrite=d;mfmp4srcsnk=d;winedmo=d"
            env["WINEDLLOVERRIDES"] = (baseOverrides?.isEmpty == false)
                ? "\(baseOverrides!);\(Self.shaderCompilerOverrides);\(mfOff)"
                : "\(Self.shaderCompilerOverrides);\(mfOff)"
            for (k, v) in effective.extraEnv { env[k] = v }
            log.log("Lanzando \((executable as NSString).lastPathComponent) vía Steam real (motor unificado, DXMT→Metal).", level: .info)
            NotificationService.shared.status("Steam conectado. Lanzando el juego…")
            let proc = try await launchWineProcess(
                winePath: unifiedWine,
                prefix: bottle.prefixPath,
                arguments: [executable] + effective.launchArgs,
                environment: env,
                workingDirectory: gameWorkingDirectory(forExecutable: executable)
            )
            NotificationService.shared.status(nil)
            return proc
        }
        }   // fin de `if !isD3D12` (rama motor unificado)

        // ── D3D12 + DRM real: PREFERIR el motor D3DMetal propio (`wine-d3dmetal`) ──
        // Es el UNIFICADO + D3DMetal de Apple: corre el CEF de Steam (login por JWT) Y el juego
        // D3D12 por D3DMetal en el MISMO wineserver — exactamente lo que hace CrossOver. GPTK
        // (abajo) NO corre el CEF moderno (loopback 0x3008/0x3009), así que con él el DRM no podía
        // conectar; por eso este motor es EL correcto para D3D12+Steam. Validado a mano: FFT
        // (AppID 1004640) supera el DRM, carga D3DMetal y renderiza (solo lo frena su anti-tamper
        // Denuvo); juegos D3D12 SIN Denuvo funcionan de principio a fin.
        if isD3D12, let d3dmWine = WineEngineLocator.d3dmetalWineBinary() {
            ensureSteamConfig(in: bottle)
            log.log("Modo Steam real (motor D3DMetal): preparando el cliente Steam conectado…", level: .info)
            // Cliente en 2º plano (multiproceso -silent → loguea por JWT sin ventana). El motor
            // D3DMetal corre el CEF igual que el unificado (WINEMSYNC=0, wrapper SwiftShader).
            let connected = await ensureSteamConnected(in: bottle, clientWine: d3dmWine, timeoutSeconds: 120, background: true)
            if !connected { throw steamRealNotConnected(gameExecutable: executable, in: bottle) }
            log.log("Cliente Steam conectado; lanzando el juego D3D12 con DRM real (D3DMetal).", level: .info)
            // Que mande el d3d12/dxgi builtin de D3DMetal: quitar del game dir las DLLs de DXMT que
            // un intento previo dejara junto al exe (chocan). NO se toca la subcarpeta D3D12/ (Agility SDK).
            cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
            // Modo Retina para render a resolución física completa en pantallas Retina.
            await setMacDriverRetinaMode(prefix: bottle.prefixPath, wine: d3dmWine, enabled: effective.retina)
            var env = d3dMetalUnifiedEnvironment(prefix: bottle.prefixPath)
            env["SteamAppId"] = appId
            env["SteamGameId"] = appId
            for (k, v) in effective.extraEnv { env[k] = v }
            log.log("Lanzando \((executable as NSString).lastPathComponent) vía Steam real (motor D3DMetal, D3D12→Metal).", level: .info)
            NotificationService.shared.status("Steam conectado. Lanzando el juego…")
            let proc = try await launchWineProcess(
                winePath: d3dmWine,
                prefix: bottle.prefixPath,
                arguments: [executable] + effective.launchArgs,
                environment: env,
                workingDirectory: gameWorkingDirectory(forExecutable: executable),
                effective: effective,    // ACTIVA el env -i (contexto LIMPIO): sin `__CFBundleIdentifier` y
                                         // con `DYLD_*`, D3DMetal SÍ crea el device Metal (como el modo Vessel).
                                         // Sin esto el juego se lanzaba con spawn directo de la `.app` y moría.
                forceSyncOn: true,       // msync=1: DEBE COINCIDIR con el cliente Steam D3DMetal (que corre en
                                         // msync ON). El `forceSyncOff` anterior ponía msync=0 → mismatch con el
                                         // wineserver del cliente → `exit(1)` ("Palworld en Steam-real no arrancaba").
                d3dMetalGame: true       // añade el DYLD a lib/external:lib (D3DMetal)
            )
            NotificationService.shared.status(nil)
            return proc
        }

        // GPTK/D3DMetal para cliente + juego (mismo wineserver): fallback si no está el motor
        // D3DMetal propio (o para D3D12 en equipos sin él). GPTK no corre el CEF moderno, así que
        // el DRM real solo conecta de forma fiable con el motor D3DMetal de arriba.
        try await gptkManager.ensureInstalled { msg, pct in
            Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
        }
        guard let gptkWine = gptkManager.wineBinaryPath else {
            throw WineError.launchFailed("No se encontró GPTK/D3DMetal para el modo Steam real.")
        }

        // 3) Cliente Steam corriendo y CONECTADO (para el DRM), en SEGUNDO PLANO (multiproceso
        //    -silent → loguea por JWT sin ventana ni colgarse). steam.cfg evita autoupdate.
        ensureSteamConfig(in: bottle)
        log.log("Modo Steam real (GPTK/D3DMetal): preparando el cliente Steam conectado…", level: .info)
        let connected = await ensureSteamConnected(in: bottle, clientWine: gptkWine, timeoutSeconds: 120, background: true)
        if !connected { throw steamRealNotConnected(gameExecutable: executable, in: bottle) }
        log.log("Cliente Steam conectado; lanzando el juego con DRM real.", level: .info)

        // 4) D3D12: que mande el `d3d12`/`dxgi` builtin de D3DMetal — quitar del game dir las DLLs
        //    de DXMT que un intento previo dejara junto al exe (chocan con D3DMetal). NO se toca la
        //    subcarpeta `D3D12/` del Agility SDK (D3DMetal la ignora por diseño).
        if isD3D12 { cleanExeAdjacentDXMTDLLs(gameExecutable: executable) }

        // 5) Lanzar el juego en GPTK, MISMO wineserver que Steam (NO se mata Steam ni se
        //    resincroniza el prefijo, que lo tumbaría). SteamAPI_Init encuentra el cliente vivo.
        var env = gptkManager.d3dMetalEnvironment(prefix: bottle.prefixPath)
        // La sincronización DEBE coincidir con la del cliente Steam del mismo wineserver
        // (sync=0, ver steamClientEnvironment): mezclar esync entre procesos del mismo
        // wineserver rompe el socket del cliente (→ conn:0) o aborta Wine. D3DMetal rinde
        // igual con el sync apagado (verificado), así que el juego también va a sync=0.
        env["WINEMSYNC"] = "0"
        env["WINEESYNC"] = "0"
        env["WINEFSYNC"] = "0"
        env["SteamAppId"] = appId
        env["SteamGameId"] = appId
        log.log("Lanzando \((executable as NSString).lastPathComponent) vía Steam real (GPTK/D3DMetal).", level: .info)
        NotificationService.shared.status("Steam conectado. Lanzando el juego…")
        let proc = try await launchWineProcess(
            winePath: gptkWine,
            prefix: bottle.prefixPath,
            arguments: [executable] + effective.launchArgs,
            environment: env,
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective,
            forceSyncOff: true   // mismo wineserver que el cliente Steam → sync=0 obligatorio
        )
        NotificationService.shared.status(nil)
        return proc
    }

    /// Abre el cliente Steam COMPLETO y conectado en el **motor unificado** propio
    /// (DXMT sobre WineHQ 11.10) — el único Wine libre que corre a la vez el CEF de
    /// Steam (login + teclado + QR + tienda, con el wrapper SwiftShader) Y los juegos
    /// por DXMT/Metal en el MISMO wineserver. Jugar DESDE Steam (su botón verde)
    /// funciona porque el `d3d11` builtin del motor ES DXMT. Todo AUTO-reparable:
    /// motor (auto-descarga), Steam (auto-instalación), deps del prefijo
    /// (corefonts + vcrun2022, idempotente), cliente antiguo (self-update una vez)
    /// y wrapper. Si el motor unificado no se puede instalar, cae a Gcenx (tienda).
    func openSteamClient(in bottle: Bottle) async {
        // Serialización: si otro flujo (p. ej. "Iniciar sesión" de la vista) ya está
        // preparando Steam, esperar y reutilizar en vez de pisarnos los procesos.
        let isOwner = await acquireSteamFlowTurn()
        defer { if isOwner { Self.steamFlowActive = false } }
        if !isOwner {
            let ok = await ensureSteamConnected(in: bottle, clientWine: resolveClientWine(for: bottle))
            log.log(ok ? "Steam abierto y conectado ✓" : "Steam abierto (la conexión se confirmará al iniciar sesión).", level: ok ? .info : .warn)
            return
        }

        // 1) Motor del CLIENTE de Steam: el UNIFICADO (o Gcenx si no está). El CEF de Steam SOLO
        //    renderiza de forma FIABLE en el motor unificado; el motor `wine-d3dmetal` (optimizado para
        //    juegos, con el `winemac.so` de client-surfaces DXMT) hace que el proceso GPU del webhelper
        //    CRASHEE EN BUCLE (verificado: ~87 steamwebhelper reintentando, ventana nunca pinta). Por eso
        //    el cliente va en el unificado (cliente + biblioteca + juegos D3D11 desde Steam, con la nube de
        //    Steam nativa). Los juegos D3D12 (p. ej. Palworld) se juegan en modo Vessel (GPTK/D3DMetal) +
        //    copia de partida local. Unificar CEF+D3D12 en un solo motor (modelo CrossOver puro) exige un
        //    `winemac.so` que componga las sub-superficies del CEF sin crashear (CW HACK 22435) — I+D abierto.
        // El motor COMPLETO (wine-full) es AUTÓNOMO y trae TODO (Wine + DXMT + D3DMetal + winemac +
        // redistribuibles): si está instalado, NO hace falta instalar/verificar el unificado ni el motor
        // dedicado del cliente → se salta (arranque MUCHO más rápido). Solo se preparan esos motores
        // cuando wine-full NO está (fallback).
        if WineEngineLocator.fullWineBinary() == nil {
            do {
                try await dependencyManager.ensureUnifiedEngine { msg, pct in
                    Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
                }
            } catch {
                log.log("No se pudo instalar el motor unificado: \(error.localizedDescription). Se usará el motor disponible.", level: .warn)
            }
            // Motor DEDICADO del cliente de Steam (`wine-steam`): clon del unificado + `winemac.so` con
            // el fix de la TIENDA (CW HACK 22435). Idempotente; fallback si wine-full no está.
            await dependencyManager.ensureSteamEngine { msg, pct in
                Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
            }
        }
        // Motor COMPLETO de Vessel (wine-full) si está instalado: UN solo motor corre el cliente Steam
        // (CEF nativo, sin wrapper), la tienda y TODOS los juegos (D3D11 y D3D12), compartiendo
        // wineserver para el DRM. Si no está, el motor dedicado del cliente (clon del unificado con el
        // fix de la tienda), o el unificado/Gcenx.
        let wine = WineEngineLocator.fullWineBinary()
            ?? WineEngineLocator.steamDedicatedWineBinary()
            ?? resolveClientWine(for: bottle)
        if WineEngineLocator.isFullEngine(wine) {
            log.log("Abriendo Steam con el motor completo de Vessel (cliente + tienda + juegos, CEF nativo).", level: .info)
        } else if wine.contains("/\(WineEngineLocator.steamEngineName)/") {
            log.log("Abriendo Steam en el motor dedicado del cliente (aparte de los juegos; con el fix de la tienda).", level: .info)
        }

        // 2) Steam: auto-instalar en el bottle si falta.
        if !FileManager.default.fileExists(atPath: bottle.steamPath) {
            log.log("Steam no está instalado en este bottle; instalándolo…", level: .info)
            do { try await installSteam(bottle: bottle) }
            catch {
                log.log("No se pudo instalar Steam: \(error.localizedDescription)", level: .error)
                return
            }
        }

        // 3) Deps del prefijo para el cliente moderno (lo que instala CrossOver):
        //    corefonts + VC++ v14. Idempotente (marker en el prefijo); se aplican con
        //    TODO el prefijo parado (incluidos zombis de otros motores, que colgarían
        //    winetricks/wineboot con "version mismatch") para evitar cuelgues.
        // Deps del prefijo (corefonts + VC++) + config por-juego SOLO para el unificado, que NO los
        // trae. El motor COMPLETO (wine-full) YA incluye todos los redistribuibles + GStreamer (reproduce
        // vídeo), así que se salta: ni `winetricks` (minutos) ni el override `winegstreamer=disable` (que
        // le quitaría el vídeo a los juegos). Arranque mucho más rápido.
        if WineEngineLocator.isModernSteamEngine(wine), !WineEngineLocator.isFullEngine(wine) {
            try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
            await applyWinetricksVerbs(["corefonts", "vcrun2022"], prefix: bottle.prefixPath, wine: wine)
            // Config POR-JUEGO en el registro (AppDefaults): evita el crash de vídeo (winegstreamer) de
            // los juegos Unity lanzados desde Steam en el unificado (que no trae GStreamer).
            await applySteamGameRegistry(in: bottle, wine: wine)
        }

        // 3.7) CLON de CrossOver — overrides GLOBALES de compatibilidad. Junto con `cxcompatdb`
        //       (CX_ROOT, hacks por-juego en runtime) es lo que hace que los juegos lanzados DESDE el
        //       cliente Steam en Wine vayan como en CrossOver, sin ir juego a juego. Idempotente; con
        //       Steam parado (antes de lanzarlo). Solo en motores modernos (wine-full / unificado).
        if WineEngineLocator.isModernSteamEngine(wine) {
            if !WineEngineLocator.isFullEngine(wine) {
                try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
                try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
            }
            await ensureCrossOverCompatOverrides(prefix: bottle.prefixPath, wine: wine)
        }

        // 4) Cliente antiguo (era Gcenx, sin cef.win64) → dejar que Steam se actualice
        //    a sí mismo bajo el motor moderno (unificado/D3DMetal, una única vez) y reconfigurar.
        if WineEngineLocator.isModernSteamEngine(wine),
           isSteamBootstrapped(in: bottle), !isSteamClientModern(in: bottle) {
            await updateSteamClient(in: bottle, clientWine: wine)
        }

        // 4.5) UNIÓN con el modo Vessel: marcar como INSTALADOS en Steam los juegos que Vessel ya
        //      instaló (genera los `appmanifest_<appid>.acf` que faltan). Así aparecen en la biblioteca
        //      de Steam y se pueden ejecutar DESDE Steam, con Steam Cloud/actualizaciones/DLC/logros
        //      nativos. Con Steam parado para que el cliente los lea al arrancar; si creó manifests
        //      nuevos y Steam ya corría, se reinicia para que los recoja.
        let newManifests = SteamAppManifestWriter.ensureManifests(in: bottle)
        if newManifests > 0 {
            log.log("Steam: \(newManifests) juego(s) de Vessel marcados como INSTALADOS en Steam (jugables desde Steam, con la nube).", level: .info)
        }
        if newManifests > 0, isWineProcessRunning(matching: "steam.exe") {
            log.log("Reiniciando Steam para que recoja los \(newManifests) juego(s) recién marcados como instalados…", level: .info)
            try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // 5) Arrancar y esperar conexión (idempotente si ya corre).
        log.log("Abriendo el cliente Steam completo. Desde él puedes instalar y jugar (DRM real).", level: .info)
        // El motor completo (wine-full) arranca el CEF nativo, que tarda más en pintar → más margen.
        let ok = await ensureSteamConnected(in: bottle, clientWine: wine,
                                            timeoutSeconds: WineEngineLocator.isFullEngine(wine) ? 150 : 90)
        log.log(ok ? "Steam abierto y conectado ✓" : "Steam abierto (la conexión se confirmará al iniciar sesión).", level: ok ? .info : .warn)
    }

    /// Orquesta el **self-update** del cliente de Steam bajo el motor unificado: lanza
    /// Steam en modo actualización (ver `launchSteam`: sin steam.cfg, sin wrapper, sin
    /// `-noverifyfiles`), espera a que el updater de Valve instale el cliente moderno
    /// (`bin/cef/cef.win64`) y lo deja configurado (wrapper SwiftShader + steam.cfg).
    /// El login y los juegos instalados (`steamapps/`) se conservan: el updater
    /// actualiza in-place, no borra datos de usuario.
    private func updateSteamClient(in bottle: Bottle, clientWine: String) async {
        do { _ = try await launchSteam(in: bottle, using: clientWine) }
        catch {
            log.log("No se pudo iniciar la actualización de Steam: \(error.localizedDescription)", level: .warn)
            return
        }
        log.log("Actualizando el cliente de Steam (descarga de Valve, una única vez)…", level: .info)
        // Actualizado de verdad = el paquete moderno está extraído (cef.win64) Y el
        // cliente nuevo llegó a arrancar su webhelper (la extracción terminó).
        var updated = false
        for _ in 0..<900 {   // hasta 15 min (descarga ~500 MB + extracción)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if isSteamClientModern(in: bottle), isWineProcessRunning(matching: "steamwebhelper") {
                updated = true
                break
            }
            // Si no queda ningún proceso de Steam vivo, el updater murió o terminó:
            // margen breve por si se está relanzando entre fases, y re-check.
            if !isWineProcessRunning(matching: "steam.exe"), !isWineProcessRunning(matching: "steamwebhelper") {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !isWineProcessRunning(matching: "steam.exe") {
                    updated = isSteamClientModern(in: bottle)
                    break
                }
            }
        }
        guard updated else {
            log.log("La actualización de Steam no terminó a tiempo; se intentará abrir igualmente.", level: .warn)
            return
        }
        // Margen para que el updater cierre sus escrituras, y reconfigurar en frío.
        log.log("Cliente de Steam actualizado ✓ — aplicando wrapper y configuración…", level: .info)
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        try? await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        ensureSteamConfig(in: bottle)
        try? await ensureWrapperInstalled(in: bottle)

        // PASADA DE ASENTAMIENTO: la primera vez que corre una build recién actualizada,
        // el cliente hace un self-check de integridad (independiente del bootstrapper e
        // inmune a -noverifyfiles) que puede RESTAURAR el steamwebhelper.exe original,
        // deshaciendo el wrapper → el CEF real intenta GPU → su proceso GPU crashea en
        // bucle y la ventana no llega a pintarse (visto in-vivo). Se arranca una vez, se
        // le deja hacer el self-check y, si se cargó el wrapper, se re-aplica en frío.
        do { _ = try await launchSteam(in: bottle, using: clientWine) } catch { return }
        try? await Task.sleep(nanoseconds: 45_000_000_000)
        if !wrapperInstaller.isInstalled(in: bottle) {
            log.log("El self-check del cliente nuevo deshizo el wrapper; re-aplicándolo…", level: .info)
            try? await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            cleanCEFCache(in: bottle)                  // los crashes del GPU corrompen la caché
            try? await ensureWrapperInstalled(in: bottle)
        }
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

    /// Versión MAYOR de Unity del juego (6000 para Unity 6, 2022 para Unity 2022…), o `nil` si no
    /// es Unity / no se puede leer. La cadena "6000.3.9f1" vive tanto al inicio de
    /// `<Juego>_Data/globalgamemanagers` (cadena limpia) como dentro de `UnityPlayer.dll`.
    func unityMajorVersion(forExecutable executable: String) -> Int? {
        let dir = (executable as NSString).deletingLastPathComponent
        let exeName = ((executable as NSString).lastPathComponent as NSString).deletingPathExtension
        let fm = FileManager.default
        // Patrón de versión Unity: AAAA.M.PfN (p. ej. 6000.3.9f1, 2022.3.58f1). `f/p/a/b` = fase.
        let regex = try? NSRegularExpression(pattern: "([0-9]{4,})\\.[0-9]+\\.[0-9]+[fpab][0-9]+")
        // El globalgamemanagers trae la versión en los primeros bytes (barato y fiable);
        // UnityPlayer.dll como respaldo (la versión está en su recurso, más adentro).
        let candidates: [(path: String, bytes: Int)] = [
            ("\(dir)/\(exeName)_Data/globalgamemanagers", 4096),
            ("\(dir)/UnityPlayer.dll", 3_000_000)
        ]
        for (path, bytes) in candidates {
            guard fm.fileExists(atPath: path),
                  let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: bytes),
                  // isoLatin1: cada byte → char, así el string ASCII de la versión se localiza en binario.
                  let text = String(data: data, encoding: .isoLatin1) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let m = regex?.firstMatch(in: text, range: range),
               let g = Range(m.range(at: 1), in: text),
               let major = Int(text[g]) {
                return major
            }
        }
        return nil
    }

    /// ¿Es **Unity 6 o superior** (versión 6000.x+)? Estos NO arrancan con DXMT ni con
    /// wine-dxmt-mousefix: su init gráfica se cuelga (bucle de IOSurfaces; falta el `d3d11` real
    /// sobre Metal). Necesitan el **D3DMetal de Apple (gptk-mythic)**, cuyo `d3d11` builtin sí es
    /// Metal nativo. Unity ≤2023 (año.x) va bien por DXMT. Validado: Dragon Is Dead (6000.3.9f1).
    func isUnity6OrNewer(_ executable: String) -> Bool {
        guard let major = unityMajorVersion(forExecutable: executable) else { return false }
        return major >= 6000
    }

    /// ¿Es un juego **.NET Core / .NET 5+ self-contained** (trae su propio runtime: `coreclr.dll` +
    /// `hostfxr.dll`)? Estos SOLO arrancan con un Wine ESTÁNDAR y completo (Gcenx/gptk); el motor
    /// DXMT/unificado propio (con parches Denuvo/gsbase y sin Vulkan) rompe la carga de assemblies de
    /// coreclr (`System.Runtime.dll … Module not found`). Se usa para elegir motor y cadena de fallback.
    func isDotNetCoreGame(_ executable: String) -> Bool {
        let dir = (executable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        return fm.fileExists(atPath: "\(dir)/coreclr.dll") && fm.fileExists(atPath: "\(dir)/hostfxr.dll")
    }

    /// ¿El juego usa la API de Steam (Steamworks)? Tiene `steam_api.dll`/`steam_api64.dll` (junto al
    /// exe o en subcarpetas — Unity los mete en `*_Data/Plugins/`). Lo usa el auto-repair para, si el
    /// juego falla, probar el modo Steam-real (algunos exigen el cliente Steam vivo / interfaces que
    /// la emulación no implementa: DRM, Steam Input). Búsqueda superficial y barata.
    func usesSteamworks(_ executable: String) -> Bool {
        let dir = (executable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(dir)/steam_api.dll") || fm.fileExists(atPath: "\(dir)/steam_api64.dll") { return true }
        // Unity: `<Juego>_Data/Plugins/x86_64/steam_api64.dll`.
        if let walker = fm.enumerator(atPath: dir) {
            var checked = 0
            for case let rel as String in walker {
                checked += 1; if checked > 4000 { break }   // tope de seguridad
                let low = (rel as NSString).lastPathComponent.lowercased()
                if low == "steam_api64.dll" || low == "steam_api.dll" { return true }
            }
        }
        return false
    }

    /// ¿Es un juego **Unreal Engine**? Su exe real vive en `…/Binaries/Win64|Win32|WinGDK/…-Shipping.exe`.
    /// UE se lanza por DXMT (d3d11) con el flag `-d3d11` (ver `detectGraphicsAPI` / `unrealLaunchArguments`).
    func isUnrealGame(_ executable: String) -> Bool {
        let d = (executable as NSString).deletingLastPathComponent.lowercased()
        return d.contains("/binaries/win64") || d.contains("/binaries/win32") || d.contains("/binaries/wingdk")
    }

    /// Flags para juegos Unreal Engine en el path DXMT: `-d3d11` fuerza el RHI D3D11 de UE (su default
    /// es D3D12, que en Mac via GPTK/D3DMetal se reporta como GPU AMD y provoca el aviso "AMD driver
    /// known issues"). Con DXMT+`-d3d11` arranca limpio. Para juegos no-UE, vacío.
    func unrealLaunchArguments(forExecutable executable: String) -> [String] {
        isUnrealGame(executable) ? ["-d3d11"] : []
    }

    /// Flags de motor Unity para el path **DXMT (64-bit)**. Para juegos no Unity, vacío.
    func unityLaunchArguments(forExecutable executable: String, singleThreaded: Bool = false) -> [String] {
        // Combinación validada para Unity + DXMT en Apple Silicon:
        //  - `-force-d3d11-no-singlethreaded`: estabilidad de DXMT (render MULTIHILO, rápido).
        //  - `-screen-fullscreen 1 -window-mode borderless`: pantalla completa SIN
        //    bordes. El fullscreen EXCLUSIVO (modo por defecto del juego) sí revienta
        //    el swapchain de DXMT (InitializeEngineGraphics failed); el borderless se
        //    ve a pantalla completa y funciona. Los avisos `unsupported swap effect`
        //    / `DeviceTexture` de DXMT son inofensivos (el juego renderiza igual).
        // MONOHILO (`singleThreaded`): `-force-gfx-direct` mantiene D3D11 pero corre el render en un
        // solo hilo → elimina los crashes por CARRERA del render multihilo sobre DXMT (p. ej. Unity 6.3
        // con EOS/plugins nativos, como Dragon Is Dead, que revientan en `UnityPlayer.dll` al arrancar).
        // Más lento pero estable; es el mismo fix raíz que ya usamos en Unity 32-bit (ver `unity32BitGLArguments`).
        guard isUnityGame(executable) else { return [] }
        let renderMode = singleThreaded ? "-force-gfx-direct" : "-force-d3d11-no-singlethreaded"
        return [renderMode, "-screen-fullscreen", "1", "-window-mode", "borderless"]
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
        var dlls = ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "d3d10.dll", "d3d10_1.dll", "winemetal.dll"]
        // Juegos que IMPORTAN d3d9 estáticamente aunque rendericen por D3D11 (muchos Unreal, p. ej.
        // Palworld): con el lanzamiento `env -i` (entorno limpio) los builtins wined3d-based NO se
        // resuelven → `d3d9.dll not found` / `wined3d.dll not found` (c0000135) y el juego no carga.
        // Se copian d3d9 + su dependencia wined3d LOCALES (native) → cargan y satisfacen el import
        // (wined3d solo importa opengl32/ucrtbase, que sí resuelven como builtin). Solo si el exe
        // los importa (wined3d pesa ~31 MB): no se copian a juegos que no usan d3d9.
        if exeImports(gameExecutable, anyOf: ["d3d9.dll"]) {
            dlls.append(contentsOf: ["d3d9.dll", "wined3d.dll"])
        }
        for dll in dlls {
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
        for dll in ["d3d9.dll", "wined3d.dll", "d3d11.dll", "dxgi.dll", "d3d10core.dll", "d3d10.dll", "d3d10_1.dll", "winemetal.dll"] {
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
        guard bin64.contains(last) else { return exeDir }
        // El exe vive en una subcarpeta de binarios (x64/Win64/…). Subir UN nivel es correcto cuando
        // esa subcarpeta cuelga DIRECTAMENTE de la raíz del juego (p. ej. Grim Dawn `x64/Grim Dawn.exe`
        // → raíz). PERO en el patrón **Unreal** `…/Binaries/Win64/Juego.exe`, subir un nivel da
        // `…/Binaries` — una carpeta INTERMEDIA sin los datos del juego → el juego arranca pero su
        // WebView interno (notas del parche) sale en BLANCO y el audio/recursos degradan (validado con
        // Palworld: con CWD=Win64 va bien, con CWD=Binaries no). En ese caso el CWD correcto es la
        // carpeta del exe (Win64), no la intermedia.
        let parent = (exeDir as NSString).deletingLastPathComponent
        if (parent as NSString).lastPathComponent.lowercased() == "binaries" { return exeDir }
        return parent
    }

    /// Elimina del prefix las DLLs gráficas nativas (DXVK/DXMT/wined3d) que un setup
    /// previo dejó en system32/syswow64, para que se usen los builtins del motor.
    /// Incluye `wined3d`/`vulkan-1`/`winevulkan`: como archivos NATIVOS en el prefix
    /// rompen el binding WoW64 de Vulkan (no enlazan con su `.so` unix de 64-bit), lo
    /// que impide cargar d3d11 y deja el prefijo en un estado mixto frágil.
    /// `subdirs` limita qué carpetas del prefijo se limpian. Por defecto ambas (juegos 64-bit por
    /// DXMT). Los juegos de 32-bit pasan SOLO `["syswow64"]`. Opera sobre `prefixPath` (no un Bottle)
    /// para poder actuar sobre el prefijo AISLADO del motor (ver `engineScopedPrefix`).
    func cleanPrefixNativeGraphicsDLLs(prefixPath: String, subdirs: [String] = ["system32", "syswow64"]) {
        let fm = FileManager.default
        let dlls = ["d3d8", "d3d9", "d3d10", "d3d10_1", "d3d10core", "d3d11",
                    "d3d12", "d3d12core", "dxgi", "winemetal", "nvapi64", "nvngx",
                    "wined3d", "vulkan-1", "winevulkan"]
        for sub in subdirs {
            let dir = "\(prefixPath)/drive_c/windows/\(sub)"
            for dll in dlls {
                let path = "\(dir)/\(dll).dll"
                // Solo borrar si es una DLL "real" (>20 KB); respetar las fake de Wine.
                if let size = try? fm.attributesOfItem(atPath: path)[.size] as? UInt64, size > 20_000 {
                    try? fm.removeItem(atPath: path)
                }
            }
        }
    }

    /// Aparta las DLLs de traducción gráfica (DXMT/wined3d/vulkan) que puedan estar **en la carpeta
    /// del juego** (nunca forman parte legítima de un juego). Si están, sobrescriben el builtin del
    /// motor por precedencia de búsqueda de DLLs de Windows: una DXMT local fuerza MoltenVK y aborta
    /// los juegos D3D11 de 32-bit en gptk (`vkCreateBufferView`). Se **mueven** a un backup (no se
    /// borran) para ser reversible. Idempotente.
    private func cleanGameFolderGraphicsDLLs(forExecutable executable: String) {
        let fm = FileManager.default
        let gameDir = (executable as NSString).deletingLastPathComponent
        let names = ["d3d10", "d3d10_1", "d3d10core", "d3d11", "d3d12", "d3d12core",
                     "dxgi", "winemetal", "wined3d", "vulkan-1", "winevulkan"]
        let bakDir = "\(gameDir)/_vessel_graphics_bak"
        for name in names {
            let path = "\(gameDir)/\(name).dll"
            // Solo apartar DLLs "reales" (>100 KB): las DXMT/wined3d pesan MB; nunca una fake de Wine.
            guard let size = try? fm.attributesOfItem(atPath: path)[.size] as? UInt64, size > 100_000 else { continue }
            try? fm.createDirectory(atPath: bakDir, withIntermediateDirectories: true)
            let dst = "\(bakDir)/\(name).dll"
            try? fm.removeItem(atPath: dst)
            try? fm.moveItem(atPath: path, toPath: dst)
            log.log("Apartada DLL gráfica local del juego que pisaba el builtin: \(name).dll", level: .info)
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
        // Motor COMPLETO (wine-full): el cliente Steam CEF corre NATIVO con WINEMSYNC=1 (msync ON,
        // como el Wine de referencia). Sin wrapper, sin steam.cfg; el CEF renderiza por su DXMT/winemac
        // de fábrica. Los juegos que Steam lance heredan los env globales del bottle (.NET + AVX).
        if WineEngineLocator.isFullEngine(wine) {
            var env = steamClientEnvironment(prefix: prefix)
            env["WINEMSYNC"] = "1"; env["WINEESYNC"] = "1"; env["WINEFSYNC"] = "1"
            env["MVK_CONFIG_LOG_LEVEL"] = "0"
            env["DOTNET_EnableWriteXorExecute"] = "0"
            if #available(macOS 15, *) { env["ROSETTA_ADVERTISE_AVX"] = "1" }
            return env
        }
        // GPTK/D3DMetal: entorno de D3DMetal (Steam en el mismo motor que un juego Metal).
        if wine.contains("/\(GPTKManager.engineName)/") {
            var env = gptkManager.d3dMetalEnvironment(prefix: prefix)
            // CLAVE (reconciliación Steam+D3DMetal en un solo wineserver GPTK): el cliente
            // necesita el DYLD de D3DMetal para no cerrarse al instante, PERO su async socket
            // (conexión al CM / updater) se ROMPE bajo msync/esync → connect 0xc00000a3 →
            // "http error 0" → `conn:0` (nunca loguea). D3DMetal, en cambio, funciona IGUAL con
            // TODO el sync apagado (verificado: D3D12CreateDevice+CommandQueue OK con
            // esync/msync/fsync=0). Por eso forzamos sync=0: es el terreno común que deja a
            // Steam conectar (login por JWT vía CM, que la red de GPTK SÍ alcanza) y al juego
            // D3D12 renderizar por Metal, ambos en el MISMO wineserver (necesario para el DRM).
            env["WINEMSYNC"] = "0"
            env["WINEESYNC"] = "0"
            env["WINEFSYNC"] = "0"
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
        // Motor D3DMetal (juegos D3D12+DRM tipo FFT): el cliente comparte wineserver con el JUEGO,
        // que EXIGE msync ON (su DirectStorage async no completa con sync=0 → pantalla negra). El
        // cliente Steam ya logueado funciona igual con msync ON (el sync=0 solo hacía falta para el
        // updater/bootstrap del cliente). Así cliente y juego van con el MISMO sync (ON).
        if WineEngineLocator.isD3DMetalEngine(wine) {
            var env = steamClientEnvironment(prefix: prefix)
            env["WINEMSYNC"] = "1"
            env["WINEESYNC"] = "1"
            env["WINEFSYNC"] = "1"
            env["MVK_CONFIG_LOG_LEVEL"] = "0"
            return env
        }
        if WineEngineLocator.isUnifiedEngine(wine) {
            // Motor UNIFICADO / wine-steam (cliente Steam CEF, juegos D3D11 por DXMT): WINEMSYNC=0 —
            // msync rompe el async socket del updater HTTP (→ "http error 0"). `launchWineProcess`
            // añade el DYLD del motor; el wrapper SwiftShader completa el CEF.
            var env = steamClientEnvironment(prefix: prefix)
            env["WINEMSYNC"] = "0"
            env["WINEESYNC"] = "0"
            env["WINEFSYNC"] = "0"
            // Silencia el log de MoltenVK (paridad con el lanzamiento manual que renderizó).
            // El CEF de la build moderna pinta por DXMT→Metal (D3D11 FL 11_1) con el wrapper
            // `--single-process`; no usa Vulkan/MoltenVK para su UI, así que esto es cosmético.
            env["MVK_CONFIG_LOG_LEVEL"] = "0"
            // Env GLOBALES del bottle que los JUEGOS lanzados por Steam HEREDAN (como el bottle de Steam
            // de CrossOver): fix .NET 7/8 bajo Rosetta (W^X) + exponer AVX a Rosetta. Inocuas para el
            // cliente; imprescindibles para que muchos juegos .NET/nativos arranquen desde Steam.
            env["DOTNET_EnableWriteXorExecute"] = "0"
            if #available(macOS 15, *) { env["ROSETTA_ADVERTISE_AVX"] = "1" }
            return env
        }
        // Gcenx (fallback): entorno normal.
        return steamClientEnvironment(prefix: prefix)
    }

    /// Entorno de JUEGO para el motor **D3DMetal** propio (`wine-d3dmetal`). El DYLD hacia
    /// `lib/external:lib` (D3DMetal.framework + libd3dshared) lo añade `launchWineProcess` con
    /// `d3dMetalGame: true`; aquí van el resto de variables.
    ///
    /// **Sync = ON (msync/esync/fsync = 1).** Validado in-vivo con FFT: The Ivalice Chronicles
    /// (Denuvo): con el sync APAGADO el juego arranca pero se queda en pantalla negra de carga y su
    /// I/O async de **DirectStorage** (dstorage.dll, que FFT exige) NO completa → ni crea la ventana.
    /// Con **msync ON** renderiza el splash y llega al menú. El cliente Steam de este motor LOGUEA
    /// igual con msync ON (el requisito sync=0 era solo del updater/bootstrap del cliente, no del
    /// cliente ya logueado que se usa para el DRM). Cliente y juego comparten wineserver, así que
    /// AMBOS van con el mismo sync (msync ON) — ver `steamClientEnvironment(prefix:wine:)`.
    private func d3dMetalUnifiedEnvironment(prefix: String) -> [String: String] {
        var env: [String: String] = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "WINEMSYNC": "1",
            "WINEESYNC": "1",
            "WINEFSYNC": "1",
            "MVK_CONFIG_LOG_LEVEL": "0",
            "MTL_HUD_ENABLED": "0",
            // Silencia el instalador de Mono/Gecko al re-sincronizar el prefijo. + Desactiva Media
            // Foundation: el motor unificado NO trae backend GStreamer → `winegstreamer.dll` CRASHEA al
            // decodificar cualquier vídeo por MF (worker de rtworkq) y tira el proceso entero, aunque
            // el juego ya haya creado el device y renderizado toda la init. Validado con Cross Blitz
            // (Unity reproduce un vídeo de intro por MF). Desactivarlo hace que el vídeo se OMITA limpio
            // (no es fatal; el audio suele ir por FMOD). Solo aquí (el unificado nunca reproduce vídeo);
            // los motores wine-dxmt*/gptk* SÍ traen GStreamer y reproducen cutscenes.
            "WINEDLLOVERRIDES": "mscoree,mshtml=d;winegstreamer=d;mfplat=d;mf=d;mfreadwrite=d;mfmp4srcsnk=d;winedmo=d"
        ]
        // Exponer AVX a Rosetta (algunos juegos comprueban CPUID y crashean sin él). macOS 15+.
        if #available(macOS 15, *) { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        return env
    }

    @discardableResult
    func launchSteam(in bottle: Bottle, using winePath: String? = nil, background: Bool = false) async throws -> Process {
        guard FileManager.default.fileExists(atPath: bottle.steamPath) else {
            throw WineError.launchFailed("Steam no está instalado en este bottle.")
        }

        // Por defecto el CLIENTE de Steam corre en el motor unificado (o Gcenx si no
        // está). Para el modo "Steam real" se puede pasar un wine explícito, de modo
        // que Steam y el juego compartan wineserver (necesario para el DRM).
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
        // SEMBRAR la sesión del cliente (auto-login por JWT) si es un usuario NUEVO —cliente sin
        // sesión guardada— pero Vessel tiene el refresh_token de su login nativo. Así el cliente
        // auto-loguea SIN pasar por el CEF (que en el M5 no renderiza para meter credenciales), y
        // los juegos con DRM que exigen Steam abierto funcionan. Idempotente: si ya hay sesión, no
        // toca nada. Solo tiene sentido con el cliente ya bootstrapeado (si no, Steam lo pisaría).
        if bootstrapped { await maybeSeedSteamSession(in: bottle, wine: clientWine) }
        // Cliente ANTIGUO (sin cef.win64) bajo el motor unificado → dejar que Steam se
        // auto-actualice UNA vez. En Gcenx el updater fallaba ("http error 0") y por eso
        // se inhibía con steam.cfg; en el unificado FUNCIONA (WINEMSYNC=0, validado). Se
        // quita el steam.cfg y se restauran los webhelper originales para que la
        // verificación de ficheros no vea el wrapper como "corrupto".
        let needsSelfUpdate = bootstrapped
            && !isSteamClientModern(in: bottle)
            && WineEngineLocator.isModernSteamEngine(clientWine)
        if WineEngineLocator.isFullEngine(clientWine), bootstrapped {
            // Motor COMPLETO de Vessel: el CEF se lanza en SINGLE-PROCESS (wrapper) porque, lanzado
            // desde la `.app`, el CEF NATIVO MULTIPROCESO no crea su ventana Cocoa: el proceso
            // "browser" de Chromium pierde el contexto al hacer fork/exec bajo la sesión de la app
            // (validado in-vivo: el cliente carga la UI —library.js, FriendsUI ReadyToRender— y loguea
            // por JWT, pero la ventana nunca aparece; desde un terminal el CEF nativo SÍ pinta). El
            // single-process crea la ventana igual que un juego (proceso único) y renderiza por el DXMT
            // maduro del motor. steam.cfg inhibe el auto-update para no ladrillar el wrapper.
            ensureSteamConfig(in: bottle)
            cleanCEFCache(in: bottle)
            try await ensureWrapperInstalled(in: bottle)
        } else if needsSelfUpdate {
            log.log("Cliente de Steam antiguo detectado: Steam se actualizará solo (una única vez, puede tardar unos minutos)…", level: .info)
            removeSteamConfig(in: bottle)
            wrapperInstaller.restoreRealWebHelpers(in: bottle)
            cleanCEFCache(in: bottle)
        } else if bootstrapped && background {
            // MODO BACKGROUND (DRM real, p. ej. Grim Dawn): solo hace falta Steam VIVO +
            // LOGUEADO (JWT), NO su UI. El wrapper single-process del CEF se CUELGA en el M5
            // (ni rinde ni loguea → "Steamwebhelper no responde"); en MULTIPROCESO (webhelper
            // real) el subproceso GPU crashea (UI negra) pero el cliente LOGUEA por JWT y el
            // DRM funciona (verificado: Grim Dawn cargó cuenta + personajes). `-silent` = sin
            // ventana negra, solo el icono en la barra.
            ensureSteamConfig(in: bottle)
            wrapperInstaller.restoreRealWebHelpers(in: bottle)
            cleanCEFCache(in: bottle)
        } else if bootstrapped {
            ensureSteamConfig(in: bottle)              // inhibe el auto-update que ladrilla
            cleanCEFCache(in: bottle)                  // evita el 0x3008
            try await ensureWrapperInstalled(in: bottle)
        } else {
            // Primer arranque: quitar cualquier steam.cfg restrictivo para permitir que
            // Steam descargue steamui.dll y el resto del cliente.
            removeSteamConfig(in: bottle)
            log.log("Primer arranque de Steam: descargando su cliente (deja que termine la ventana de actualización)…", level: .info)
        }
        try? await launchOptionsManager.injectLaunchOptions(in: bottle)

        // Matar procesos Wine/Steam zombi previos (steam.exe, steamwebhelper…).
        log.log("Terminando procesos Wine/Steam previos…", level: .info)
        try await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath)
        // Prefijo alineado con ESTE motor (solo re-sincroniza si cambió de motor).
        await ensurePrefixSyncedToEngine(clientWine, prefix: bottle.prefixPath)
        // Modo Retina OFF para el CLIENTE de Steam: su UI (CEF por software, `--single-process`)
        // NO se compone bien a 2× — con Retina ON la ventana del cliente no aparece (verificado:
        // login/biblioteca no pintan). Con OFF sí (así logueó el usuario). Los JUEGOS lanzados
        // por Vessel (`launch`) REACTIVAN Retina ON en su propia ruta para ir a pantalla completa.
        await setMacDriverRetinaMode(prefix: bottle.prefixPath, wine: clientWine, enabled: false)
        // Certificados: el cert de los servidores de Steam es EV **ECDSA** (DigiCert Global
        // Root G3). El prefijo necesita el intermedio + root en su store para validar la cadena
        // (macOS no expone DigiCert por la vía que Wine auto-importa). Idempotente.
        await ensureSteamRootCertificates(prefix: bottle.prefixPath, wine: clientWine)
        try? await disableSteamAutoStart(winePath: clientWine, prefix: bottle.prefixPath)

        let engineLabel = WineEngineLocator.isD3DMetalEngine(clientWine) ? "motor D3DMetal Vessel"
            : WineEngineLocator.isUnifiedEngine(clientWine) ? "motor unificado Vessel"
            : clientWine.contains("/\(GPTKManager.engineName)/") ? "GPTK/CrossOver" : "Gcenx"
        log.log("Lanzando cliente Steam (\(engineLabel)) en \(bottle.name)…", level: .info)
        // En fresh/actualización, argumentos mínimos: sin -noverifyfiles ni
        // -skipinitialbootstrap, para que el bootstrap/updater pueda completarse.
        let args: [String]
        if WineEngineLocator.isFullEngine(clientWine), bootstrapped {
            // Flags MÍNIMOS (como el Wine de referencia). ⚠️ NO usar `-skipinitialbootstrap`: el CEF NATIVO
            // necesita el bootstrap del cliente para crear su ventana — con él, steam.exe arranca pero el
            // CEF NO pinta (validado: con estos flags mínimos la ventana SÍ aparece, con los rápidos no).
            // `-noverifyfiles` acelera (no re-verifica ficheros) sin romper el CEF.
            args = ["-no-cef-sandbox", "-noverifyfiles", "-tcp"]
        } else if needsSelfUpdate {
            args = ["-no-cef-sandbox", "-tcp"]
        } else if bootstrapped {
            args = background ? Self.steamLaunchArguments + ["-silent"] : Self.steamLaunchArguments
        } else {
            args = ["-no-cef-sandbox"]
        }
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
        FileManager.default.fileExists(atPath: "\(bottle.steamDirectory)/steamui.dll")
    }

    /// Deja Steam LISTO para iniciar sesión (login visible, sin pantalla negra):
    ///  1. Si es una instalación fresh, hace el primer bootstrap (descarga del cliente)
    ///     en crudo y espera a que termine.
    ///  2. Cierra ese Steam y lo relanza ya CON el wrapper de steamwebhelper, que es lo
    ///     que evita la pantalla negra de CEF en el login.
    func ensureSteamReadyForLogin(in bottle: Bottle, progress: @escaping @Sendable (String) -> Void) async throws {
        // Serialización con el resto de flujos de Steam (ver `acquireSteamFlowTurn`).
        let isOwner = await acquireSteamFlowTurn()
        defer { if isOwner { Self.steamFlowActive = false } }
        if !isOwner {
            // Otro flujo ya dejó Steam preparado/arrancando; no repetir ni matarlo.
            progress("Abriendo Steam para iniciar sesión…")
            _ = try await launchSteam(in: bottle)   // idempotente si ya corre
            return
        }
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
        // Los procesos Wine CLIENTE (steam.exe, steamwebhelper…) TAMPOCO llevan el
        // prefix en su argv: Wine lo reescribe a la línea de comandos de Windows
        // ("C:\Program Files…\steam.exe"), así que `pkill -f <prefix>` tampoco los
        // alcanza y sobreviven entre sesiones. Un steam.exe zombi hace que
        // `launchSteam` crea que "Steam ya está en marcha" y no lo relance jamás.
        // Igual que con el wineserver: se localizan por `lsof` contra ESTE prefix.
        await killPrefixWineClients(prefix: prefix)
    }

    /// Mata por SIGKILL los procesos Wine CLIENTE (argv de Windows, con `.exe`) que
    /// tengan abierto algo bajo `prefix`. No toca CrossOver ni otros prefijos (su
    /// `lsof` no apunta a este prefix) ni procesos nativos de macOS (no casan `.exe`).
    private func killPrefixWineClients(prefix: String) async {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        let script = """
        for pid in $(/bin/ps -axo pid=,command= | /usr/bin/grep -F '.exe' | /usr/bin/grep -v grep | /usr/bin/awk '{print $1}'); do
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
            // Sin procesos o sin lsof: nada que hacer.
        }
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

    /// Nombre del motor (carpeta) al que pertenece un binario wine, para el marker.
    private func engineID(forWine wine: String) -> String {
        WineEngineLocator.engineRoot(forWineExecutable: URL(fileURLWithPath: wine))?
            .lastPathComponent ?? (wine as NSString).lastPathComponent
    }

    /// Re-sincroniza el prefijo al motor ACTUAL si el último que lo tocó era OTRO
    /// (marker `.vessel-prefix-engine`). Un prefijo creado/sincronizado por Gcenx y
    /// corriendo bajo el motor unificado queda con fake-DLLs/registro desalineados →
    /// el proceso GPU del CEF de Steam crashea en BUCLE (browser restarts) y la
    /// ventana nunca llega a pintarse (visto in-vivo; el `wineboot -u` lo arregló).
    /// Los juegos no lo sufrían porque su ruta re-sincroniza siempre; el cliente de
    /// Steam ahora también, pero solo cuando cambia el motor (idempotente y barato).
    private func ensurePrefixSyncedToEngine(_ wine: String, prefix: String) async {
        let id = engineID(forWine: wine)
        let marker = "\(prefix)/.vessel-prefix-engine"
        if (try? String(contentsOfFile: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == id { return }
        // Motor COMPLETO (wine-full): trae su propio Wine + DXMT + winemac completos y gestiona el
        // prefijo de fábrica (validado: cliente Steam y juegos corren sin un `wineboot -u` externo).
        // Además su `bin/wine` es un shim que exige su propio entorno, mientras `resyncGamePrefix`
        // lanza wineboot con el entorno REEMPLAZADO (sin HOME/PATH) → no encaja. Marcamos el prefijo
        // como sincronizado sin forzar el resync.
        if WineEngineLocator.isFullEngine(wine) {
            try? id.write(toFile: marker, atomically: true, encoding: .utf8)
            return
        }
        log.log("Sincronizando el prefijo al motor \(id)…", level: .info)
        await resyncGamePrefix(gameWine: wine, prefix: prefix)
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
        // Registrar el motor con el que quedó sincronizado el prefijo (lo consume
        // `ensurePrefixSyncedToEngine` para el camino del cliente de Steam).
        try? engineID(forWine: gameWine)
            .write(toFile: "\(prefix)/.vessel-prefix-engine", atomically: true, encoding: .utf8)
        log.log("Prefijo re-sincronizado para el juego", level: .debug)
    }

    @discardableResult
    /// Ejecuta `process` capturando stdout+stderr SIN congelar el MainActor y SIN el
    /// deadlock del pipe lleno: la salida se drena en un hilo aparte MIENTRAS el
    /// proceso corre, y la espera usa `terminationHandler` asignado ANTES de `run()`
    /// (el único patrón sin carrera). NUNCA usar `waitUntilExit()` + `Pipe` sin
    /// lector para procesos largos: congela la UI y con >64 KB de salida el hijo se
    /// bloquea escribiendo (deadlock que colgaba winetricks/instaladores).
    private func runCapturing(_ process: Process) async throws -> ProcessResult {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let readHandle = pipe.fileHandleForReading
        let reader = Task.detached { readHandle.readDataToEndOfFile() }
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
        let output = String(data: await reader.value, encoding: .utf8) ?? ""
        return ProcessResult(exitCode: status, output: output)
    }

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
        do {
            let result = try await runCapturing(process)
            if result.exitCode != 0, !allowNonZeroExit {
                throw WineError.launchFailed(result.output.isEmpty
                    ? "Wine terminó con código \(result.exitCode)" : result.output)
            }
            return result
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
            _ = try await runWine(winePath: winePath, arguments: fallbackArguments, prefix: prefix)
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
        do {
            let result = try await runCapturing(process)
            if result.exitCode != 0 {
                throw WineError.launchFailed(result.output.isEmpty
                    ? "wineboot terminó con código \(result.exitCode)" : result.output)
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

    /// Fuerza los `d3dcompiler_43`/`d3dx9_43`/`d3dx9_42` **NATIVOS** (los builtin de Wine
    /// importan `wined3d`, ausente en el motor unificado → fallan). Va SIEMPRE con
    /// `ensureNativeShaderCompiler`, que los siembra en el prefijo. No toca `d3d11`/`dxgi`
    /// (los provee DXMT como builtin del motor).
    nonisolated static let shaderCompilerOverrides =
        "d3dcompiler_47=n;d3dcompiler_43=n;d3dx9_43=n;d3dx9_42=n"

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

    /// Ruta al helper `vessel-spawn` (desacopla el subproceso de la identidad de la app con
    /// `responsibility_spawnattrs_setdisclaim`, como el cx_loader de CrossOver). En el `.app` está en
    /// `Contents/Resources`; en dev, junto al ejecutable. `nil` si no se encuentra (se cae a bash directo).
    static var vesselSpawnHelperPath: String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let res = Bundle.main.resourcePath { candidates.append("\(res)/vessel-spawn") }
        if let exec = Bundle.main.executablePath {
            let macOS = (exec as NSString).deletingLastPathComponent          // …/Contents/MacOS
            let contents = (macOS as NSString).deletingLastPathComponent      // …/Contents
            candidates.append("\(contents)/Resources/vessel-spawn")           // …/Contents/Resources
            candidates.append("\(macOS)/vessel-spawn")                        // junto al ejecutable
        }
        // Fallback DEV (swift run): junto al cwd del proyecto.
        candidates.append("\(fm.currentDirectoryPath)/Resources/vessel-spawn")
        for p in candidates where fm.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// Ruta a la mini-app launcher `SteamLauncher.app` (en `Contents/Resources`). Vessel la lanza con
    /// `open` para que el motor completo corra como app INDEPENDIENTE (LaunchServices, con su propia
    /// responsible process) — única forma validada de que el CEF de Steam cree su ventana desde la app.
    static var steamLauncherAppPath: String? {
        let fm = FileManager.default
        // Plantilla en el bundle (o en el proyecto en modo dev).
        var candidates: [String] = []
        if let res = Bundle.main.resourcePath { candidates.append("\(res)/SteamLauncher.app") }
        if let exec = Bundle.main.executablePath {
            let contents = ((exec as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            candidates.append("\(contents)/Resources/SteamLauncher.app")
        }
        candidates.append("\(fm.currentDirectoryPath)/Resources/SteamLauncher.app")
        guard let template = candidates.first(where: { fm.fileExists(atPath: $0) }) else { return nil }
        // ⚠️ LaunchServices NO lanza bien una `.app` ANIDADA dentro de otra `.app`
        // (Vessel.app/Contents/Resources/SteamLauncher.app) — `open` no hace nada. Se copia a un sitio
        // SUELTO (Application Support) y se lanza desde ahí (validado). Se re-copia si la plantilla es
        // más nueva, para propagar cambios de la launcher entre versiones de Vessel.
        let runRel = "Contents/MacOS/run"
        let dst = "\(NSHomeDirectory())/Library/Application Support/Vessel/SteamLauncher.app"
        let srcDate = (try? fm.attributesOfItem(atPath: "\(template)/\(runRel)")[.modificationDate]) as? Date
        let dstDate = (try? fm.attributesOfItem(atPath: "\(dst)/\(runRel)")[.modificationDate]) as? Date
        let needsCopy = !fm.fileExists(atPath: "\(dst)/\(runRel)")
            || (srcDate != nil && dstDate != nil && srcDate! > dstDate!)
        if needsCopy {
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: dst)
            try? fm.copyItem(atPath: template, toPath: dst)
        }
        return fm.isExecutableFile(atPath: "\(dst)/\(runRel)") ? dst : nil
    }

    /// Hints de SDL2 para MANDOS. El motor bundlea `libSDL2` (que `winebus.sys` usa), y SDL2 respeta
    /// estas variables de entorno: activan **HIDAPI + rumble/vibración** de DualShock 4 / DualSense
    /// (PS4/PS5) y Switch Pro por Bluetooth/USB, que Wine NO da de fábrica. Es el equivalente
    /// Swift-puro del CW HACK 19629 de CrossOver (`bus_sdl.c`), sin recompilar el motor. Inofensivo
    /// para teclado/ratón y mandos Xbox (no dependen de estos hints).
    static let gamepadEnvVars: [String: String] = [
        "SDL_JOYSTICK_HIDAPI": "1",
        "SDL_JOYSTICK_HIDAPI_PS4": "1",
        "SDL_JOYSTICK_HIDAPI_PS4_RUMBLE": "1",
        "SDL_JOYSTICK_HIDAPI_PS5": "1",
        "SDL_JOYSTICK_HIDAPI_PS5_RUMBLE": "1",
        "SDL_JOYSTICK_HIDAPI_SWITCH": "1"
    ]

    private func launchWineProcess(
        winePath: String,
        prefix: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        effective: EffectiveLaunchConfig? = nil,
        forceSyncOff: Bool = false,
        forceSyncOn: Bool = false,
        d3dMetalGame: Bool = false
    ) async throws -> Process {
        // Motor COMPLETO (wine-full): su `bin/wine` es un shim que traduce `wine <exe>` →
        // `wineloader winewrapper.exe --run -- <exe>` y fija WINELOADER/WINESERVER/WINEDLLPATH, así
        // que aquí se lanza como cualquier otro motor (sin casos especiales). El wineloader resuelve
        // sus libs por rpath (@loader_path/@rpath).
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
        // ⚠️ CRÍTICO — contexto GUI: al ser Vessel una app (.app), CoreFoundation le inyecta
        // `__CFBundleIdentifier` (= com.swondev.vessel) y `XPC_SERVICE_NAME`/`XPC_FLAGS` en su
        // entorno, que el subproceso Wine HEREDA. Bajo la IDENTIDAD DE BUNDLE de Vessel,
        // CoreGraphics/Metal asocia el proceso a la sesión GUI de la app y la creación del device
        // **D3D11 de DXMT FALLA** → el juego (.NET/MonoGame) muestra "An error has occurred" SIN
        // crear ventana. Lanzado desde un terminal —sin estas vars— DXMT crea el device y RENDERIZA
        // (aislado var a var: era `__CFBundleIdentifier`+XPC, no el env de Wine ni DYLD/msync). Las
        // BORRAMOS para que el juego corra en un contexto LIMPIO, como un lanzamiento directo. Esta
        // fue la última pieza para que Romestead (.NET 8 + DXMT) renderice desde el botón de Vessel.
        fullEnv["__CFBundleIdentifier"] = nil
        fullEnv["XPC_SERVICE_NAME"] = nil
        fullEnv["XPC_FLAGS"] = nil
        // ── Fix de RAÍZ y de CLASE para juegos .NET Core / .NET 5+ (Romestead y cualquier otro) ──
        // Estos crashean al arrancar en Wine/Rosetta por DOS motivos, ambos a nivel del runtime .NET:
        //  1) **ReadyToRun (R2R)**: los assemblies se publican con código NATIVO precompilado (AOT
        //     parcial). El loader PE de Wine NO carga bien esas secciones nativas → el CLR aborta con
        //     `System.IO.FileNotFoundException: … System.Runtime.dll. Module not found` +
        //     `Internal CLR error (0x80131506)`. `DOTNET_ReadyToRun=0` fuerza JIT puro desde el IL
        //     (que Wine sí ejecuta) → arranca. ESTE es el fix que hizo funcionar Romestead.
        //  2) **W^X (Write-Xor-Execute)** del JIT: permutar permisos RW↔RX crashea bajo Rosetta (el
        //     mismo problema que CrossOver parchea con CW Hack 24945/25719). Se desactiva a nivel .NET.
        // Todo esto es INOFENSIVO para juegos no-.NET (ignoran las variables) y para .NET que ya
        // funcionaban. No se sobrescribe si el propio entorno ya las trae.
        if fullEnv["DOTNET_ReadyToRun"] == nil { fullEnv["DOTNET_ReadyToRun"] = "0" }
        if fullEnv["DOTNET_TieredCompilation"] == nil { fullEnv["DOTNET_TieredCompilation"] = "0" }
        if fullEnv["DOTNET_TieredPGO"] == nil { fullEnv["DOTNET_TieredPGO"] = "0" }
        if fullEnv["DOTNET_gcServer"] == nil { fullEnv["DOTNET_gcServer"] = "0" }
        if fullEnv["DOTNET_EnableWriteXorExecute"] == nil { fullEnv["DOTNET_EnableWriteXorExecute"] = "0" }
        if fullEnv["COMPlus_EnableWriteXorExecute"] == nil { fullEnv["COMPlus_EnableWriteXorExecute"] = "0" }
        //  3) **ICU (globalización)**: .NET carga los datos Unicode de ICU al arrancar; bajo Wine el
        //     mapeo del `icudt*.dat` falla → `Unhandled exception. Could not load ICU data`. El modo
        //     **invariant globalization** salta ICU (usa cultura invariante) → arranca. Suficiente
        //     para juegos (no necesitan localización por cultura del SO).
        if fullEnv["DOTNET_SYSTEM_GLOBALIZATION_INVARIANT"] == nil { fullEnv["DOTNET_SYSTEM_GLOBALIZATION_INVARIANT"] = "1" }
        // MANDOS: rumble de PS4/PS5/Switch vía los hints de SDL2 (el motor bundlea libSDL2). Inofensivo
        // para teclado/ratón/Xbox. No pisa lo que ya venga en el entorno. Cubre el camino normal
        // (Gcenx / wine-dxmt-mousefix); las ramas `env -i` los reañaden por whitelist más abajo.
        for (k, v) in Self.gamepadEnvVars where fullEnv[k] == nil { fullEnv[k] = v }
        // El motor UNIFICADO propio (WineHQ 11.10) carga freetype/gnutls por `dlopen` desde su
        // `lib/` (SONAME sin ruta). Necesita `DYLD_FALLBACK_LIBRARY_PATH` a esa carpeta o Wine
        // no encuentra FreeType (texto del sistema / CEF de Steam) ni gnutls (TLS). Es
        // inofensivo para juegos que no las usan. `arch` borraría esta var (SIP), pero aquí el
        // binario x86_64 se lanza directo (Rosetta), así que se preserva.
        if WineEngineLocator.isModernSteamEngine(winePath),
           let root = WineEngineLocator.engineRoot(forWineExecutable: URL(fileURLWithPath: winePath)) {
            let libDir = root.appendingPathComponent("lib").path
            // El motor D3DMetal necesita su `lib/external` (D3DMetal.framework + libd3dshared.dylib,
            // a los que apuntan los symlinks d3d12.so/dxgi.so) por delante SOLO para el JUEGO D3D12.
            // El cliente Steam va con `lib/` a secas: su CEF renderiza por DXMT/CPU y meterle
            // `external` en el DYLD podría enredar la resolución de dxgi (validado: cliente=lib,
            // juego=external:lib). En el motor unificado siempre es `lib/`.
            let extDir = root.appendingPathComponent("lib/external").path
            let engineDyld = (d3dMetalGame
                              && WineEngineLocator.isD3DMetalEngine(winePath)
                              && FileManager.default.fileExists(atPath: extDir))
                ? "\(extDir):\(libDir)" : libDir
            let base = fullEnv["DYLD_FALLBACK_LIBRARY_PATH"]
            fullEnv["DYLD_FALLBACK_LIBRARY_PATH"] = (base?.isEmpty == false) ? "\(engineDyld):\(base!)" : engineDyld
        }
        // Overlay de la config EFECTIVA (perfil de compatibilidad + ajustes del usuario).
        // Solo para lanzamientos de JUEGO (effective != nil); Steam pasa nil → intacto.
        if let eff = effective {
            // Sincronización (cableada de verdad). msync implica esync para engañar a D3DMetal.
            // EXCEPCIÓN `forceSyncOff` (modo Steam real, GPTK): el juego comparte wineserver con
            // el cliente Steam, cuya sincronización DEBE ser 0 (msync/esync rompen su async socket
            // → conn:0 / "http error 0"). D3DMetal rinde igual con TODO el sync apagado (verificado:
            // D3D12CreateDevice+CommandQueue OK con esync/msync/fsync=0), así que forzamos sync=0 e
            // IGNORAMOS el sync del perfil — reconcilia cliente Steam + juego D3D12 en un wineserver.
            if forceSyncOff {
                fullEnv["WINEMSYNC"] = "0"
                fullEnv["WINEESYNC"] = "0"
                fullEnv["WINEFSYNC"] = "0"
            } else if forceSyncOn {
                // Modo Steam real en el motor D3DMetal: el juego comparte wineserver con el
                // cliente de Steam, que corre con msync ON (ver `steamClientEnvironment(:wine:)`
                // para isD3DMetalEngine). msync es POR-PROCESO y cacheado: si el juego arranca
                // con msync=0 y el wineserver ya está en msync=1 (o viceversa), Wine aborta con
                // `exit(1)` — de ahí que Palworld en Steam-real "se cerrara al arrancar". Forzamos
                // msync/esync/fsync = 1 para COINCIDIR con el cliente y evitar el mismatch.
                fullEnv["WINEMSYNC"] = "1"
                fullEnv["WINEESYNC"] = "1"
                fullEnv["WINEFSYNC"] = "1"
            } else {
                fullEnv["WINEMSYNC"] = eff.msync ? "1" : "0"
                fullEnv["WINEESYNC"] = (eff.esync || eff.msync) ? "1" : "0"
                fullEnv["WINEFSYNC"] = eff.fsync ? "1" : "0"
            }
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
        // Juegos **.NET Core**: lanzar vía `/usr/bin/env -i` con el entorno construido, para ROMPER
        // el contexto de la app GUI. Vessel es una `.app`: CoreFoundation inyecta en sus hijos
        // `__CFBundleIdentifier` (= com.swondev.vessel) + `XPC_*` (identidad de bundle), y macOS
        // **STRIPEA `DYLD_FALLBACK_LIBRARY_PATH`** de los hijos directos de la app. Con ese contexto,
        // DXMT NO crea el device D3D11 (el motor unificado tampoco encuentra FreeType sin DYLD) y el
        // juego .NET aborta con "An error has occurred" SIN ventana. `env -i` re-establece el entorno
        // LIMPIO desde cero: el DYLD va como ARGUMENTO de `env` (no heredado-y-stripeado) → SÍ llega a
        // Wine, y sin `__CFBundleIdentifier`/`XPC` el proceso corre como si se lanzara desde un
        // terminal, que es el ÚNICO contexto donde DXMT crea el device. ✅ VALIDADO end-to-end:
        // Romestead (.NET 8 + DXMT→Metal) muestra su menú a pantalla completa desde el botón de Vessel.
        if isDotNetCoreGame(arguments.first ?? "") {
            log.log("Juego .NET Core: lanzando con entorno LIMPIO (env -i) para evitar el contexto GUI que rompe DXMT.", level: .info)
            // Env MÍNIMO (replica EXACTAMENTE el lanzamiento desde terminal que renderiza): SOLO lo
            // esencial, nada del ruido del entorno de la app GUI. Pasar todo `fullEnv` (~50 vars) NO
            // funciona; este whitelist sí. msync SIEMPRE 0 (rompe el async de coreclr).
            // EXACTAMENTE las vars del lanzamiento por terminal que renderizó — ni una más. NO incluir
            // `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT` (Romestead usa cultura → invariant lo rompe),
            // ni MVK/MTL/COMPlus (ruido). Menos es más aquí: cada var extra reintroduce el fallo.
            var clean: [String: String] = [:]
            for k in ["HOME", "USER", "TMPDIR", "WINEPREFIX", "WINEDEBUG", "WINEDLLOVERRIDES",
                      "DYLD_FALLBACK_LIBRARY_PATH", "SteamAppId", "SteamGameId",
                      "DOTNET_ReadyToRun", "DOTNET_TieredCompilation", "DOTNET_TieredPGO",
                      "DOTNET_EnableWriteXorExecute", "DOTNET_gcServer"] {
                if let v = fullEnv[k] { clean[k] = v }
            }
            clean["WINEMSYNC"] = "0"; clean["WINEESYNC"] = "0"; clean["WINEFSYNC"] = "0"
            // CLAVE: se lanza vía `/bin/bash -c 'exec env -i … wine …'` (NO `env` directo). Validado
            // empíricamente que el intermediario bash es NECESARIO: `env -i` directo desde el `Process`
            // de la app GUI seguía fallando, pero a través de bash el juego RENDERIZA (bash rompe el
            // contexto de spawn de la .app que arrastra Metal/DXMT). Comillas simples para paths con
            // espacios. `exec` para no dejar bash colgado (el PID final es Wine, para el tracker).
            func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let assignments = clean.map { "\($0.key)=\(shq($0.value))" }.joined(separator: " ")
            let cmdline = ([winePath] + arguments).map { shq($0) }.joined(separator: " ")
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "exec /usr/bin/env -i \(assignments) \(cmdline)"]
            process.environment = fullEnv
        } else if (WineEngineLocator.isUnifiedEngine(winePath) && !forceSyncOff && !d3dMetalGame)
                    || WineEngineLocator.isD3DMetalEngine(winePath), effective != nil {
            // Juegos DXMT del motor UNIFICADO **y juegos D3D12 por D3DMetal (`wine-d3dmetal`)**: MISMO
            // problema de contexto que los .NET. Al ser Vessel una `.app`, el spawn del subproceso
            // arrastra la IDENTIDAD DE BUNDLE (`__CFBundleIdentifier`/`XPC_*`) y macOS stripea `DYLD_*`
            // de los hijos DIRECTOS → en ese contexto **DXMT/D3DMetal NO crean el device**: el juego
            // muere en ~1 s (`d3d11.dll not found` c0000135 / device Metal nulo). VALIDADO con Palworld:
            // a mano RENDERIZA, desde la app (hijo directo) MUERE. Se lanza vía `/bin/bash -c 'exec env
            // -i …'` con un env LIMPIO → corre como desde terminal, el ÚNICO contexto donde se crea el
            // device. ⚠️ ANTES esto excluía `wine-d3dmetal`/Steam-real por creer que env -i "aislaba"
            // del cliente Steam — FALSO: el wineserver es POR-PREFIJO y env -i conserva `WINEPREFIX`, así
            // que el juego sigue compartiendo wineserver con el cliente Steam (comparten el mismo
            // prefijo). Sin este env -i, **Palworld en modo Steam real muere** (D3DMetal no crea el
            // device por el contexto de bundle) aunque el cliente Steam esté conectado.
            log.log("Juego DXMT/D3DMetal: lanzando con entorno LIMPIO (env -i) para crear el device (Metal) sin el contexto de bundle de la app.", level: .info)
            var clean: [String: String] = [:]
            for k in ["HOME", "USER", "TMPDIR", "WINEPREFIX", "WINEDEBUG", "MVK_CONFIG_LOG_LEVEL",
                      "WINEDLLOVERRIDES", "DYLD_FALLBACK_LIBRARY_PATH", "SteamAppId", "SteamGameId",
                      "WINEMSYNC", "WINEESYNC", "WINEFSYNC", "CX_FWD_COMPAT_GL_CTX", "MTL_HUD_ENABLED",
                      "ROSETTA_ADVERTISE_AVX",
                      "SDL_JOYSTICK_HIDAPI", "SDL_JOYSTICK_HIDAPI_PS4", "SDL_JOYSTICK_HIDAPI_PS4_RUMBLE",
                      "SDL_JOYSTICK_HIDAPI_PS5", "SDL_JOYSTICK_HIDAPI_PS5_RUMBLE", "SDL_JOYSTICK_HIDAPI_SWITCH"] {
                if let v = fullEnv[k] { clean[k] = v }
            }
            func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let assignments = clean.map { "\($0.key)=\(shq($0.value))" }.joined(separator: " ")
            let cmdline = ([winePath] + arguments).map { shq($0) }.joined(separator: " ")
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "exec /usr/bin/env -i \(assignments) \(cmdline)"]
            process.environment = fullEnv
        } else if WineEngineLocator.isFullEngine(winePath) {
            // Motor COMPLETO (wine-full): el cliente Steam CEF **y** los juegos necesitan el contexto
            // LIMPIO (`env -i` vía bash). Desde la app (hijo directo), el bundle GUI
            // (`__CFBundleIdentifier`/`XPC_*` + DYLD stripped) rompe el CEF/DXMT: el proceso arranca
            // pero MUERE sin pintar (validado: lanzado desde terminal RENDERIZA la tienda; desde la app
            // muere). Igual que los juegos .NET/D3DMetal. El wineserver es por-prefijo, así que `env -i`
            // conserva `WINEPREFIX` y los juegos comparten wineserver con el cliente (mismo prefijo →
            // DRM). El shim `bin/wine` (sh) solo usa builtins + rutas absolutas, así que corre sin PATH.
            log.log("Motor completo: lanzando con entorno LIMPIO (env -i) para evitar el contexto GUI que rompe el CEF/DXMT.", level: .info)
            var clean: [String: String] = [:]
            for k in ["HOME", "USER", "TMPDIR", "WINEPREFIX", "WINEDEBUG", "WINEDLLOVERRIDES",
                      "DYLD_FALLBACK_LIBRARY_PATH", "SteamAppId", "SteamGameId",
                      "WINEMSYNC", "WINEESYNC", "WINEFSYNC", "MVK_CONFIG_LOG_LEVEL", "MTL_HUD_ENABLED",
                      "DOTNET_ReadyToRun", "DOTNET_TieredCompilation", "DOTNET_TieredPGO",
                      "DOTNET_EnableWriteXorExecute", "DOTNET_gcServer", "ROSETTA_ADVERTISE_AVX",
                      "SDL_JOYSTICK_HIDAPI", "SDL_JOYSTICK_HIDAPI_PS4", "SDL_JOYSTICK_HIDAPI_PS4_RUMBLE",
                      "SDL_JOYSTICK_HIDAPI_PS5", "SDL_JOYSTICK_HIDAPI_PS5_RUMBLE", "SDL_JOYSTICK_HIDAPI_SWITCH"] {
                if let v = fullEnv[k] { clean[k] = v }
            }
            // ⭐ CrossOver cxcompatdb — LA clave de que los juegos vayan PERFECTOS desde el Steam de
            // wine (como CrossOver; NO era D3DMetal, como se creyó al principio). `CX_ROOT` activa el
            // módulo `cxcompatdb.so`, que aplica los "hacks" de compatibilidad POR JUEGO (dll_overrides,
            // env_vars, cmdline…). Los juegos que el cliente Steam lanza HEREDAN estas vars → cxcompatdb
            // activo → render correcto SIN ir juego a juego. Validado in-vivo: Palworld (UE5/D3D12)
            // renderiza perfecto y el CEF del cliente NO se rompe (el webhelper va por CPU, ajeno a
            // CX_GRAPHICS_BACKEND). `WINEMSYNC=1` (ya en la whitelist) DEBE coincidir con el cliente.
            let cxRoot = WineEngineLocator.fullEngineDir()
            clean["CX_ROOT"] = cxRoot
            // ⚠️ NO forzar CX_GRAPHICS_BACKEND: CrossOver NO lo setea (su bottle Steam va sin él) y usa
            // su AUTO-DETECCIÓN por juego (D3D9→wined3d, D3D11/12→D3DMetal/vkd3d…). Forzarlo a "d3dmetal"
            // rompía los juegos que NO son D3D11/12 — p.ej. Cube World (D3D9) daba "Could not initialize
            // Direct3D". Sin forzarlo, cada juego usa su backend correcto, exactamente como CrossOver.
            // `CX_APPLEGPTK_LIBD3DSHARED_PATH` sí se exporta siempre (CrossOver hace igual): deja D3DMetal
            // DISPONIBLE para cuando la auto-detección lo elija (D3D11/12), sin imponerlo.
            let cxLibd3d = "\(cxRoot)/lib64/apple_gptk/external/libd3dshared.dylib"
            if FileManager.default.fileExists(atPath: cxLibd3d) { clean["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = cxLibd3d }
            if let cxHome = ensureCXCompatDB() { clean["CX_HOME"] = cxHome }
            func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let assignments = clean.map { "\($0.key)=\(shq($0.value))" }.joined(separator: " ")
            let cmdline = ([winePath] + arguments).map { shq($0) }.joined(separator: " ")
            let bashCmd = "exec /usr/bin/env -i \(assignments) \(cmdline)"
            // Lanzar vía un **LaunchAgent** que arranca **launchd** (`bootstrap` en el dominio GUI del
            // usuario, `gui/<uid>`): el proceso queda con PPID=1, sesión Aqua propia y su PROPIA
            // "responsible process" → el CEF de Steam del motor completo crea su ventana. Alternativas
            // descartadas (validado exhaustivamente in-vivo): como subproceso anidado de Vessel
            // (Foundation.Process, incluso con `env -i` o el disclaim de vessel-spawn) el CEF arranca,
            // carga la UI y loguea por JWT, pero NO pinta; `Process(open)` directo → Vessel es el
            // originador (hereda su responsible process) → el CEF no pinta; `launchctl asuser <uid>
            // open -n <app>` → funciona desde una shell EXTERNA pero NO desde Vessel, que YA vive en la
            // sesión `gui/<uid>` (el `open` ni llega a lanzar la launcher: steam.exe=0); `osascript tell
            // Finder` → -1743 (sin permiso de Automation). `bootstrap gui/<uid>` SÍ funciona desde
            // dentro de la sesión GUI (validado: ventana en ~5s). El comando real (cd + `exec env -i
            // wine`) se deja en un archivo que el LaunchAgent ejecuta con bash.
            let cwd = workingDirectory ?? (prefix as NSString).deletingLastPathComponent
            let script = "cd \(shq(cwd))\n\(bashCmd)\n"
            let cmdFile = "\(NSHomeDirectory())/Library/Application Support/Vessel/.steam-launch.sh"
            try? script.write(toFile: cmdFile, atomically: true, encoding: .utf8)
            let uid = getuid()
            let agentLabel = "com.swondev.vessel.steamlauncher"
            // ⚠️ El plist va en Application Support, NO en ~/Library/LaunchAgents: allí launchd lo
            // auto-cargaría en CADA inicio de sesión (RunAtLoad) → Steam arrancaría solo al login.
            // `bootstrap gui/<uid> <plist>` acepta cualquier ruta de plist para una carga puntual.
            let agentPlist = "\(NSHomeDirectory())/Library/Application Support/Vessel/steamlauncher.plist"
            let agentLog = "\(NSHomeDirectory())/Library/Logs/Vessel/steam-agent.log"
            let plistXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(agentLabel)</string>
                <key>ProgramArguments</key>
                <array><string>/bin/bash</string><string>\(cmdFile)</string></array>
                <key>RunAtLoad</key><true/>
                <key>LimitLoadToSessionType</key><string>Aqua</string>
                <key>ProcessType</key><string>Interactive</string>
                <key>StandardOutPath</key><string>\(agentLog)</string>
                <key>StandardErrorPath</key><string>\(agentLog)</string>
            </dict>
            </plist>
            """
            try? plistXML.write(toFile: agentPlist, atomically: true, encoding: .utf8)
            log.log("Motor completo: lanzando la launcher vía LaunchAgent (launchd bootstrap, independiente de la app).", level: .info)
            // bootout del anterior (idempotente; si Steam sigue vivo lo descarga) + bootstrap (RunAtLoad
            // arranca el script). Entorno MÍNIMO: `launchctl` no necesita el entorno de Wine (el script
            // lo aplica vía `env -i`), y heredar el del bundle GUI de Vessel es innecesario.
            // El bootstrap DEBE arrancar con el prefijo LIMPIO: Steam es single-instance, y si queda un
            // steam.exe a medio morir del lanzamiento anterior (race con `terminateWineProcesses`), el
            // nuevo lo detecta y sale SIN pintar. Por eso: bootout del agente previo (descarga su Steam
            // si lo gestionaba launchd) + mata residuos + ESPERA a que mueran + margen para el wineserver.
            // Además RunAtLoad puede fallar (`last exit code = 1`) si arranca demasiado pronto tras el
            // terminate (el wineserver anterior aún cerrándose): validado in-vivo (1er arranque falla,
            // pero un `kickstart` posterior arranca). Por eso se REINTENTA con kickstart hasta que
            // steam.exe viva. El agente (Steam) cuelga de launchd, no de este bash → queda desacoplado.
            let bootCmd =
                "/bin/launchctl bootout gui/\(uid)/\(agentLabel) 2>/dev/null; "
                + "/usr/bin/pkill -9 -f 'steam\\.exe' 2>/dev/null; /usr/bin/pkill -9 -f steamwebhelper 2>/dev/null; "
                + "for i in 1 2 3 4 5 6 7 8; do /usr/bin/pgrep -f 'steam\\.exe' >/dev/null 2>&1 || break; sleep 1; done; "
                + "sleep 2; "
                + "/bin/launchctl bootstrap gui/\(uid) '\(agentPlist)' 2>/dev/null; "
                + "for r in 1 2 3 4 5 6; do sleep 4; /usr/bin/pgrep -f 'steam\\.exe' >/dev/null 2>&1 && break; "
                + "/bin/launchctl kickstart gui/\(uid)/\(agentLabel) 2>/dev/null; done"
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", bootCmd]
            process.environment = ["HOME": NSHomeDirectory(), "USER": NSUserName(),
                                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        } else {
            process.environment = fullEnv
        }

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

    /// Asegura la base de datos de compatibilidad de CrossOver (`compatdb-<N>.dat`) que consume el
    /// módulo `cxcompatdb.so` del motor completo y devuelve el directorio que la contiene (para
    /// `CX_HOME`), o `nil` si no hay ninguna (entonces el cxcompatdb usa su base por defecto embebida,
    /// de menor cobertura). La EMPAQUETA en el motor la primera vez: si el motor no la trae y CrossOver
    /// está instalado en el sistema, copia su `compatdb-<N>.dat` (un dato firmado por CodeWeavers que
    /// se verifica con el `tie.pub` que el motor ya trae en `share/crossover/data`). Tras esa primera
    /// copia el equipo queda AUTÓNOMO (no vuelve a necesitar CrossOver). Es idempotente.
    private func ensureCXCompatDB() -> String? {
        let fm = FileManager.default
        let engineHome = "\(WineEngineLocator.fullEngineDir())/cxcompatdb-home"
        func firstDB(in dir: String) -> String? {
            (try? fm.contentsOfDirectory(atPath: dir))?
                .first { $0.hasPrefix("compatdb-") && $0.hasSuffix(".dat") }
        }
        if firstDB(in: engineHome) != nil { return engineHome }          // ya empaquetada
        let sysHome = "\(NSHomeDirectory())/Library/Application Support/CrossOver"
        if let dat = firstDB(in: sysHome) {                              // copiar del sistema (1 vez)
            try? fm.createDirectory(atPath: engineHome, withIntermediateDirectories: true)
            try? fm.copyItem(atPath: "\(sysHome)/\(dat)", toPath: "\(engineHome)/\(dat)")
            if firstDB(in: engineHome) != nil {
                log.log("cxcompatdb: base de compatibilidad empaquetada en el motor (\(dat)).", level: .info)
                return engineHome
            }
        }
        return nil                                                       // sin db → default embebida
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
        // Motor unificado: sus libs externas (freetype/gnutls) viven en `lib/` del motor
        // y se cargan por dlopen (SONAME sin ruta) → winetricks necesita el mismo
        // `DYLD_FALLBACK_LIBRARY_PATH` que usa `launchWineProcess`, y su `wineserver`.
        if WineEngineLocator.isUnifiedEngine(wine),
           let root = WineEngineLocator.engineRoot(forWineExecutable: URL(fileURLWithPath: wine)) {
            let libDir = root.appendingPathComponent("lib").path
            let base = env["DYLD_FALLBACK_LIBRARY_PATH"]
            env["DYLD_FALLBACK_LIBRARY_PATH"] = (base?.isEmpty == false) ? "\(libDir):\(base!)" : libDir
            env["WINESERVER"] = root.appendingPathComponent("bin/wineserver").path
        }
        process.environment = env
        // Salida a ARCHIVO, nunca a un Pipe sin lector: winetricks es muy verboso y con
        // el pipe lleno (64 KB) se queda BLOQUEADO escribiendo → cuelgue infinito.
        let logDir = "\(NSHomeDirectory())/Library/Logs/Vessel"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let outPath = "\(logDir)/winetricks.log"
        FileManager.default.createFile(atPath: outPath, contents: nil)
        if let handle = FileHandle(forWritingAtPath: outPath) {
            process.standardOutput = handle
            process.standardError = handle
        }
        // Espera ASÍNCRONA (terminationHandler), no `waitUntilExit()`: WineManager es
        // @MainActor y el wait bloqueante congelaba la UI entera durante minutos.
        let status: Int32? = await withCheckedContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch {
                process.terminationHandler = nil
                cont.resume(returning: nil)
            }
        }
        if status == 0 {
            let updated = already.union(pending).sorted().joined(separator: "\n")
            try? updated.write(toFile: marker, atomically: true, encoding: .utf8)
            log.log("✓ winetricks aplicado: \(pending.joined(separator: ", "))", level: .info)
        } else if let status {
            log.log("winetricks devolvió código \(status) aplicando [\(pending.joined(separator: ", "))]. Detalle: \(outPath)", level: .warn)
        } else {
            log.log("No se pudo ejecutar winetricks.", level: .warn)
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
