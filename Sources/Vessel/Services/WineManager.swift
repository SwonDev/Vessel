import Foundation
import CoreGraphics
import CryptoKit
import AppKit
import Darwin

@MainActor
@Observable
final class WineManager {
    struct ProcessResult {
        let exitCode: Int32
        let output: String
    }

    enum SteamClientRole: Sendable {
        /// Cliente visible: login, tienda, biblioteca y decisiones legales como EULA.
        case interactive
        /// Cliente invisible que comparte motor y wineserver con el juego para Steamworks/DRM.
        case backgroundDRM
    }

    enum RuntimePrefixPreparationDecision: Equatable, Sendable {
        case continueWithoutCleanup
        case prepareExclusively
        case deferForActiveDownloads
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
    private let unrealEngine1RendererManager = UnrealEngine1RendererManager()
    private let moltenVKManager = MoltenVKManager()
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

    /// Supervisa un único diálogo legal del Steam interno. Un nuevo intento cancela el anterior;
    /// así dos vistas no pueden reemitir simultáneamente el mismo `-applaunch`.
    private static var steamAuthorizationMonitor: Task<Void, Never>?

    /// Decide si un Steam vivo debe reiniciarse antes de cambiar de función. Una interfaz ya
    /// conectada puede servir como DRM si comparte motor; la inversa no es cierta: el cliente
    /// background usa el webhelper original y no ofrece una superficie interactiva válida.
    nonisolated static func shouldRestartSteamClient(
        steamRunning: Bool,
        currentEngineID: String?,
        targetEngineID: String,
        role: SteamClientRole,
        wrapperInstalled: Bool
    ) -> Bool {
        guard steamRunning else { return false }
        guard currentEngineID == targetEngineID else { return true }
        return role == .interactive && !wrapperInstalled
    }

    /// Decide si una instalación de runtimes puede tomar posesión exclusiva del prefijo. Los
    /// preflights de juegos protegidos cambian temporalmente a `wine-full`; reutilizar un
    /// `wineserver` vivo de otro motor provoca un choque de protocolo antes de que Winetricks
    /// pueda resolver `%AppData%`. Una descarga real de Steam siempre tiene prioridad y se difiere
    /// la preparación en vez de cortarla.
    nonisolated static func runtimePrefixPreparationDecision(
        exclusiveRequested: Bool,
        hasPendingRuntimes: Bool,
        hasActiveSteamDownloads: Bool
    ) -> RuntimePrefixPreparationDecision {
        guard hasPendingRuntimes, exclusiveRequested else { return .continueWithoutCleanup }
        return hasActiveSteamDownloads ? .deferForActiveDownloads : .prepareExclusively
    }

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
    /// EXCEPCIÓN por motor: los juegos **Unity** con Epic Online Services (EOS) CRASHEAN al inicializar
    /// el SDK bajo el motor unificado (WineHQ 11.10); la caída ocurre en `UnityPlayer.dll` (AK-xolotl,
    /// Dragon Is Dead). En `wine-dxmt-mousefix` (Wine 9.9) arrancan bien. EOS por sí solo no basta para
    /// aplicar esa excepción: motores nativos como el de Hades también empaquetan EOS, pero necesitan
    /// el DXMT del motor unificado y se cerraban al ser enviados al Wine antiguo de Unity.
    func resolveGameWine(for bottle: Bottle, executable: String? = nil) -> String {
        if let exe = executable, needsLegacyUnityEOSWine(exe),
           let mousefix = WineEngineLocator.wineBinary(in: WineEngineLocator.mousefixEngineName) {
            log.log("Unity con Epic Online Services (EOS): se usa wine-dxmt-mousefix para proteger la inicialización del SDK.", level: .info)
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

    func needsLegacyUnityEOSWine(_ executable: String) -> Bool {
        usesEpicOnlineServices(executable) && isUnityGame(executable)
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
            // Un D3D12 que importa Media Foundation necesita el backend real. El valor `-` borra
            // cualquier desactivación que una versión anterior de Vessel dejara en el prefijo.
            reg += requiresManagedD3D12MediaEngine(game.executablePath)
                ? "\"winegstreamer\"=-\r\n\r\n"
                : "\"winegstreamer\"=\"disable\"\r\n\r\n"
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
        log.log("Config multimedia por-juego aplicada en AppDefaults (backend real solo donde el ejecutable lo requiere).", level: .info)
    }

    /// Retira configuraciones antiguas que desactivaban Media Foundation para un ejecutable que ya
    /// dispone del perfil multimedia completo. Se ejecuta con el mismo motor/wineserver que Steam,
    /// por lo que el cambio queda visible antes de crear el proceso del juego.
    private func enableManagedMediaFoundation(
        for executable: String,
        prefix: String,
        wine: String
    ) async {
        let executableName = (executable as NSString).lastPathComponent
        let key = "HKCU\\Software\\Wine\\AppDefaults\\\(executableName)\\DllOverrides"
        let environment = D3DMetalMediaEngineProvisioner.mediaEnvironment(
            winePath: wine,
            prefix: prefix
        )
        for value in [
            "winegstreamer", "mfplat", "mf", "mfreadwrite", "mfmp4srcsnk", "winedmo"
        ] {
            _ = try? await runWine(
                winePath: wine,
                arguments: ["reg", "delete", key, "/v", value, "/f"],
                prefix: prefix,
                environment: environment,
                allowNonZeroExit: true
            )
        }
        log.log(
            "Media Foundation habilitada y autorreparada para \(executableName).",
            level: .info
        )
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

    /// Firma estructural del perfil D3D12 + Media Foundation. No usa títulos ni AppID: combina la
    /// API gráfica detectada con imports PE reales. `mfplat` aporta el pipeline y `mfreadwrite`/`mf`
    /// la lectura/decodificación; desactivar winegstreamer en este caso deja el juego en negro.
    nonisolated static func requiresManagedD3D12Media(
        importedLibraries: Set<String>,
        isD3D12: Bool
    ) -> Bool {
        guard isD3D12 else { return false }
        let imports = Set(importedLibraries.map { $0.lowercased() })
        return imports.contains("mfplat.dll")
            && (imports.contains("mfreadwrite.dll") || imports.contains("mf.dll"))
    }

    func requiresManagedD3D12MediaEngine(_ executable: String) -> Bool {
        Self.requiresManagedD3D12Media(
            importedLibraries: peImportedLibraries(forExecutable: executable),
            isD3D12: detectGraphicsAPI(forExecutable: executable) == .d3d12
        )
    }

    /// Firma del sondeo GPU mixto usado por algunos motores D3D12: un módulo auxiliar enumera el
    /// adaptador primero por D3D11/DXGI y después valida D3D12. El motor `wine-d3dmetal` combina su
    /// D3D11/winemetal con el DXGI de Apple y esa enumeración devuelve cero adaptadores, aunque
    /// D3D12 exponga FL12_2. El perfil D3DMetal aislado aporta el trío coherente de Apple
    /// (`d3d11` + `d3d12` + `dxgi`).
    ///
    /// Se reconoce por contrato PE real —nombre de módulo, export e imports—, nunca por título ni
    /// AppID. Así otros juegos D3D12 conservan su ruta validada y no se modifica el motor compartido.
    nonisolated static func requiresCoherentD3DMetalGPUProbe(
        moduleName: String,
        importedLibraries: Set<String>,
        exportedSymbols: Set<String>,
        isD3D12: Bool
    ) -> Bool {
        guard isD3D12, moduleName.lowercased() == "gpu_info.dll" else { return false }
        let imports = Set(importedLibraries.map { $0.lowercased() })
        let exports = Set(exportedSymbols.map { $0.lowercased() })
        return exports.contains("gpuinfo_getinterface")
            && imports.isSuperset(of: ["d3d11.dll", "d3d12.dll", "dxgi.dll"])
    }

    /// Determina cuándo un juego D3D12 necesita el runtime D3DMetal moderno y aislado.
    ///
    /// Además de los contratos de Media Foundation y del sondeo mixto de GPU, 4A Enhanced
    /// necesita el compositor de ventanas de Wine 11. El `winemac` de GPTK/Wine 9 vuelve a
    /// interpretar el fullscreen al recuperar el foco y puede convertir una superficie lógica
    /// de 1512×982 en una ventana 2× o dejar visible sólo un cuadrante. Mantener esta decisión
    /// como entrada explícita permite probar que un D3D12 genérico conserva su ruta anterior.
    nonisolated static func requiresIsolatedD3DMetalRuntime(
        managedMedia: Bool,
        coherentGPUProbe: Bool,
        stableMacFullscreen: Bool
    ) -> Bool {
        managedMedia || coherentGPUProbe || stableMacFullscreen
    }

    func requiresCoherentD3DMetalGPUProbeEngine(_ executable: String) -> Bool {
        guard detectGraphicsAPI(forExecutable: executable) == .d3d12 else { return false }
        let directory = (executable as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory),
              let moduleName = names.first(where: { $0.lowercased() == "gpu_info.dll" }) else {
            return false
        }
        let module = (directory as NSString).appendingPathComponent(moduleName)
        return Self.requiresCoherentD3DMetalGPUProbe(
            moduleName: moduleName,
            importedLibraries: PEImportScanner.importedLibraries(atPath: module),
            exportedSymbols: PEImportScanner.exportedSymbols(atPath: module),
            isD3D12: true
        )
    }

    /// Firma estructural de Void Engine cuando valida el controlador AMD antes de crear el primer
    /// frame D3D12. D3DMetal expone por DXGI `AMD Compatibility Mode` (vendor 0x1002), pero no una
    /// versión UMD consultable; Void interpreta ese contrato de traducción como un driver AMD real
    /// obsoleto y abre un `MessageBox` preventivo aunque el dispositivo FL12_0 ya sea válido.
    ///
    /// Se exige la combinación completa de imports y marcadores del sistema de cvars del motor para
    /// no afectar a otros ejecutables que simplemente usen AGS o D3D12. No intervienen título ni
    /// AppID, por lo que cubre otras compilaciones del mismo motor sin crear perfiles manuales.
    nonisolated static func requiresVoidEngineD3DMetalDriverCompatibility(
        importedLibraries: Set<String>,
        containsVoidEngineMarker: Bool,
        containsAMDDriverGate: Bool,
        isD3D12: Bool
    ) -> Bool {
        guard isD3D12, containsVoidEngineMarker, containsAMDDriverGate else { return false }
        let imports = Set(importedLibraries.map { $0.lowercased() })
        return imports.isSuperset(of: ["d3d12.dll", "dxgi.dll", "amd_ags_x64.dll"])
    }

    func requiresVoidEngineD3DMetalDriverCompatibility(_ executable: String) -> Bool {
        Self.requiresVoidEngineD3DMetalDriverCompatibility(
            importedLibraries: peImportedLibraries(forExecutable: executable),
            containsVoidEngineMarker: exeContains(executable, anyOf: ["VoidEngine"]),
            containsAMDDriverGate: exeContains(
                executable,
                anyOf: [
                    "r_minRecommendedAMDDriverMajorVersion",
                    "r_minAMDDriverMajorVersion"
                ]
            ),
            isD3D12: detectGraphicsAPI(forExecutable: executable) == .d3d12
        )
    }

    /// Alinea la identidad DXGI con el contrato de versión que D3DMetal publica. El framework de
    /// Apple incluye una versión UMD de estilo NVIDIA (30.0.15.1233 → 512.33), pero por defecto
    /// anuncia vendor AMD; Void combina ambas ramas y muestra un aviso preventivo falso. Las
    /// variables `D3DM_*` son capacidades nativas del propio traductor y no parámetros del juego.
    ///
    /// La emulación escogida (RTX 3070) satisface el mínimo D3D12/VRAM del motor sin habilitar ni
    /// deshabilitar features: D3D12CreateDevice y todos los feature checks siguen pasando por la GPU
    /// Apple real y por D3DMetal. Solo se corrige la etiqueta que usa el validador del driver.
    nonisolated static func environmentByApplyingVoidEngineD3DMetalIdentity(
        _ environment: [String: String],
        required: Bool
    ) -> [String: String] {
        guard required else { return environment }
        var resolved = environment
        resolved["D3DM_VENDOR_ID"] = "0x10de"
        resolved["D3DM_DEVICE_ID"] = "0x2484"
        resolved["D3DM_DEVICE_DESCRIPTION"] = "NVIDIA GeForce RTX 3070"
        return resolved
    }

    /// Auto-detecta la API gráfica del juego. Lo más fiable es mirar las DLL que
    /// **importa el propio .exe** (tabla de imports del PE), con respaldo en la
    /// estructura de carpetas:
    ///  - `D3D12/` o `D3D12Core.dll` junto al exe, o importa `d3d12.dll` → D3D12 (GPTK).
    ///  - importa `d3d11.dll`/`dxgi.dll`, o Unity (`UnityPlayer.dll`/`<exe>_Data`) → D3D11 (DXMT).
    ///  - importa `d3d9.dll`/`d3d8.dll`/`ddraw.dll` → D3D9 (Gcenx, wined3d→Metal). wine-dxmt
    ///    NO resuelve bien el d3d9 de 32-bit (c0000135 "d3d9.dll not found"); Gcenx sí.
    /// `true` si el ejecutable es un **envoltorio retro**: el DOSBox o el ScummVM con el que GOG
    /// (y otras tiendas) distribuyen su catálogo clásico. Lo que se lanza no es el juego, es el
    /// emulador — SDL puro, sin Direct3D, y con su configuración en el `.conf`/`.ini` que le pasa
    /// el propio playTask. Basta un Wine que ejecute 32-bit, sin capas de traducción.
    func isRetroWrapper(_ executable: String) -> Bool {
        isDOSBoxWrapper(executable) || isScummVMWrapper(executable)
    }

    /// `true` si es el **DOSBox de Windows** que envuelve un juego de DOS. Estos NO se lanzan con
    /// Wine: Vessel usa su DOSBox **nativo** (ver `DOSBoxManager`) — el 0.74-2 de GOG usa SDL 1.2 y
    /// bajo Wine en Apple Silicon no crea ventana con ninguna salida de vídeo.
    nonisolated func isDOSBoxWrapper(_ executable: String) -> Bool {
        let name = ((executable as NSString).lastPathComponent as NSString)
            .deletingPathExtension.lowercased()
        return name == "dosbox" || name.hasPrefix("dosbox_") || name.hasPrefix("dosbox-")
    }

    /// `true` si es el **ScummVM de Windows** de una aventura gráfica clásica. Este sí va por Wine
    /// (SDL2, y con `SDL_RENDER_DRIVER=software` renderiza bien — validado con Beneath a Steel Sky).
    nonisolated func isScummVMWrapper(_ executable: String) -> Bool {
        ((executable as NSString).lastPathComponent as NSString)
            .deletingPathExtension.lowercased() == "scummvm"
    }

    /// `true` si es un **juego de DirectDraw de la era VGA** (importa `ddraw.dll` y NINGÚN Direct3D
    /// moderno). Son juegos de 1995-1999 que piden modos de pantalla de **256 colores**, que macOS
    /// ya no ofrece: necesitan el escritorio virtual de Wine, que sí los emula. Verificado con
    /// War Wind (1996).
    func isLegacyDirectDrawGame(_ executable: String) -> Bool {
        exeImports(executable, anyOf: ["ddraw.dll"])
            && !exeImports(executable, anyOf: ["d3d9.dll", "d3d11.dll", "dxgi.dll", "d3d12.dll"])
    }

    /// `true` si el juego corre sobre **FNA o XNA** (el framework de juegos .NET de Microsoft y su
    /// reimplementación libre). Se reconoce por sus DLLs junto al `.exe`: nunca están en el sistema,
    /// el juego siempre las lleva consigo.
    ///
    /// Importa porque estos juegos necesitan el **.NET Framework de verdad**: con wine-mono arrancan
    /// a medias y se quedan en negro. Verificado con FEZ, que solo renderiza con `dotnet48` real.
    func isFNAOrXNAGame(_ executable: String) -> Bool {
        let dir = (executable as NSString).deletingLastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        return files.contains { f in
            f.caseInsensitiveCompare("FNA.dll") == .orderedSame
                || f.lowercased().hasPrefix("microsoft.xna.framework")
        }
    }

    /// Le da un **toque de foco** a la ventana del juego en cuanto aparece: activa Vessel y devuelve
    /// el foco al juego.
    ///
    /// Parece un truco tonto y no lo es. Wine crea la ventana ANTES de saber a qué escala dibuja la
    /// pantalla, así que el juego se queda con un lienzo a mitad de tamaño: se ve en un cuadradito
    /// arriba a la izquierda con el resto vacío. El usuario lo descubrió sin querer — *"cuando cambio
    /// de pantalla y vuelvo al juego se pone en pantalla completa"*: al recuperar el foco, el driver
    /// recalcula la escala y todo encaja. Esto hace ese viaje de ida y vuelta por él.
    ///
    /// No se le fuerza nada al juego, así que a uno que ya dibuje bien no le cambia nada. Espera a
    /// que la ventana exista de verdad (Unity y Source tardan lo suyo) y se rinde en 90 s.
    private func nudgeGameWindowFocus(exeName: String) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let apps = NSWorkspace.shared.runningApplications
                guard let juego = apps.first(where: { $0.localizedName == exeName }),
                      !juego.isTerminated else { continue }
                // Solo si el juego YA tiene una ventana en pantalla: si no, no hay nada que recalcular.
                let ventanas = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                           kCGNullWindowID) as? [[String: Any]]) ?? []
                let tieneVentana = ventanas.contains { info in
                    (info[kCGWindowOwnerName as String] as? String) == exeName
                        && ((info[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0) > 200
                }
                guard tieneVentana else { continue }
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(nanoseconds: 500_000_000)
                juego.activate(options: [.activateAllWindows])
                log.log("Ventana del juego reactivada para que ajuste su escala (bug de timing de Wine).", level: .debug)
                return
            }
        }
    }

    /// Responde «No» automáticamente al diálogo modal **«WARNING: Known issues with graphics
    /// driver»** que UE4/UE5 muestran cuando la GPU se reporta como AMD (es lo que hace el
    /// D3DMetal de GPTK: su dxgi/d3d11 dice "AMD Compatibility Mode" y la AGS de AMD salta).
    /// El diálogo BLOQUEA el arranque del juego: sin respuesta el watchdog lo mata por «no
    /// renderizar». «No» = seguir jugando sin abrir la web de AMD; es la respuesta correcta
    /// siempre (no cambia rutas ni afecta a juegos sin ese diálogo: solo actúa si aparece una
    /// ventana con ese título exacto). Verificado con Dwarven Realms (UE5): tras el «No»
    /// automático arranca hasta su menú. El botón «No» va anclado abajo-derecha a posición
    /// RELATIVA (~88,5 % del ancho, ~92,5 % del alto — medido a 464×289 y 232×159 pt, que
    /// tienen márgenes en puntos DISTINTOS: la relativa es la que se mantiene). Reintenta
    /// mientras el diálogo siga visible (un clic puede caer durante la animación de apertura).
    private func dismissAMDDriverWarningDialog() {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(240)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let ventanas = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                           kCGNullWindowID) as? [[String: Any]]) ?? []
                guard let dlg = ventanas.first(where: {
                    ($0[kCGWindowName as String] as? String) == "WARNING: Known issues with graphics driver"
                }), let b = dlg[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let w = b["Width"] as? Double, let h = b["Height"] as? Double else { continue }
                let punto = CGPoint(x: x + w * 0.885, y: y + h * 0.925)
                let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                   mouseCursorPosition: punto, mouseButton: .left)
                let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                 mouseCursorPosition: punto, mouseButton: .left)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
                log.log("Diálogo AMD «Known issues with graphics driver» respondido con «No» en \(Int(punto.x)),\(Int(punto.y)) (el juego sigue arrancando).", level: .info)
                // Sin `return`: si el clic no cuajó (animación, foco), el siguiente sondeo reintenta.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Carpeta del **mod de Source** que hay que arrancar (la que tiene el `gameinfo.txt`), o `nil`
    /// si no es un juego de este motor.
    ///
    /// Un juego de Source no se lanza solo: `hl2.exe` es un motor vacío al que hay que decirle QUÉ
    /// cargar con `-game <carpeta>`. Sin eso busca `hl2` y se planta: *"Setup file 'gameinfo.txt'
    /// doesn't exist in subdirectory 'hl2'"*. Steam se lo pasa por debajo; aquí hay que averiguarlo,
    /// y está a la vista: es la única subcarpeta con un `gameinfo.txt`. Sirve para todos (Portal →
    /// `portal`, Half-Life 2 → `hl2`, TF2 → `tf`…). Verificado con Portal.
    func sourceModDirectory(forExecutable executable: String) -> String? {
        let dir = (executable as NSString).deletingLastPathComponent
        // hl2.exe (Portal, Half-Life 2 y sus mods) o portal2.exe (Portal 2): juegos de Source cuyo
        // mod vive en un subdirectorio con gameinfo.txt.
        let exe = (executable as NSString).lastPathComponent.lowercased()
        guard exe.hasPrefix("hl2") || exe.hasPrefix("portal2"),
              let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let candidates = items.sorted().filter {
            FileManager.default.fileExists(atPath: "\(dir)/\($0)/gameinfo.txt")
        }
        guard !candidates.isEmpty else { return nil }
        // Con varios candidatos (el juego trae el mod base de regalo, p. ej. Portal Stories: Mel
        // incluye portal2 además de portal_stories), el bueno es el que se parece al nombre del
        // juego; sin pista, el primero alfabético (Portal → portal, Portal 2 → portal2).
        func norm(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let folderKey = norm((dir as NSString).lastPathComponent)
        if let match = candidates.first(where: { folderKey.contains(norm($0)) }) { return match }
        return candidates.first
    }

    /// `true` si el `.exe` contiene alguna de estas cadenas. Se mapea el fichero en memoria en vez
    /// de leerlo entero: los ejecutables de Godot pesan más de 100 MB.
    private nonisolated func exeContains(_ executable: String, anyOf needles: [String]) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe)
        else { return false }
        return needles.contains { data.range(of: Data($0.utf8)) != nil }
    }

    /// `true` si es un juego sobre el **motor KEX** de Nightdive (las remasterizaciones de DOOM,
    /// Quake, Blood, Turok…). Se reconoce por su DLL de UI, que siempre acompaña al `.exe`.
    func isKexEngineGame(_ executable: String) -> Bool {
        let dir = (executable as NSString).deletingLastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        return files.contains { $0.lowercased().hasPrefix("cohtml") || $0.caseInsensitiveCompare("kex.dll") == .orderedSame }
            || exeContains(executable, anyOf: ["kexengine", "KEX Engine"])
    }

    /// Motor propietario de Shining Rock: bootstrap dual PE32/PE64, runtime modular y backends
    /// DX9/DX11 paralelos sobre paquetes `WinData`. No es HiDPI-aware; con Retina activo su menú
    /// de 1024×650 ocupa solo 512×325 puntos y el cursor queda en otra escala.
    func isShiningRockDualRendererEngine(_ executable: String) -> Bool {
        let directory = (executable as NSString).deletingLastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        let names = Set(files.map { $0.lowercased() })
        let hasRuntime = names.contains("runtime-steam-x32.dll")
            || names.contains("runtime-steam-x64.dll")
        let hasDX9 = names.contains("videodx9-steam-x32.dll")
            || names.contains("videodx9-steam-x64.dll")
        let hasDX11 = names.contains("videodx11-steam-x32.dll")
            || names.contains("videodx11-steam-x64.dll")
        let dataDirectory = "\(directory)/WinData"
        let hasPackages = FileManager.default.fileExists(atPath: "\(dataDirectory)/data0.pkg")
            && FileManager.default.fileExists(atPath: "\(dataDirectory)/data1.pkg")
        return hasRuntime && hasDX9 && hasDX11 && hasPackages
    }

    /// Motor propietario de Almost Human: PE32 D3D9 con shaders HLSL embebidos, LuaJIT, XAudio2
    /// y FreeImage. Su creación de depth/stencil devuelve `D3DERR_INVALIDCALL` con el backend
    /// Vulkan de wined3d; el backend OpenGL de wine-full implementa esa ruta correctamente.
    func isAlmostHumanLuaJITD3D9Engine(_ executable: String) -> Bool {
        // D3D9 se carga dinámicamente: no aparece en la tabla de imports PE. La llamada real y los
        // shaders embebidos son la evidencia; exigir la tabla daba un falso negativo en el oficial.
        guard isExecutable32Bit(executable),
              exeContains(executable, anyOf: ["Direct3DCreate9"]) else { return false }
        let directory = (executable as NSString).deletingLastPathComponent
        let freeImage = (directory as NSString).appendingPathComponent("FreeImage.dll")
        guard FileManager.default.fileExists(atPath: freeImage) else { return false }
        return exeContains(executable, anyOf: ["LuaJIT 2.0.0"])
            && exeContains(executable, anyOf: ["shaders/d3d9/mesh.hlsl"])
            && exeContains(executable, anyOf: ["XAudio2Create"])
    }

    /// Runtime propietario clásico de Playdead: PE32 D3D9/D3DX9, entrada DirectInput/XInput,
    /// audio Wwise y dos paquetes de datos hermanos (`*_boot.pkg` + `*_runtime.pkg`). Su
    /// compositor de baja resolución no completa el framebuffer con wined3d/Vulkan en MoltenVK;
    /// wined3d/OpenGL sí renderiza la escena completa. Además trabaja en píxeles lógicos 1×, por
    /// lo que Retina duplica la superficie y deja el contenido encajonado en una esquina.
    ///
    /// La firma no usa título, AppID ni nombre del ejecutable. Combina imports, marcadores internos,
    /// contrato de paquetes y las claves de configuración propias del runtime para no ampliar la
    /// excepción a otros D3D9 de 32 bits.
    func isPlaydeadLegacyD3D9Engine(_ executable: String) -> Bool {
        guard isExecutable32Bit(executable) else { return false }
        let imports = peImportedLibraries(forExecutable: executable)
        guard ["d3d9.dll", "d3dx9_43.dll", "dinput8.dll", "xinput1_3.dll"]
            .allSatisfy(imports.contains) else { return false }
        guard exeContains(executable, anyOf: ["GetBackBufferSize():vector2i"]),
              exeContains(
                executable,
                anyOf: ["Background and foreground rendered in low resolution"]
              ),
              exeContains(
                executable,
                anyOf: ["AKSound::AKSound(): Could not create the Sound Engine."]
              ),
              exeContains(executable, anyOf: ["Custom backbuffer size: %s, %s"])
        else { return false }

        let directory = URL(fileURLWithPath: executable)
            .standardizedFileURL
            .deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        let names = entries.map { $0.lastPathComponent.lowercased() }
        let bootSuffix = "_boot.pkg"
        let runtimeSuffix = "_runtime.pkg"
        let bootStems = Set(names.compactMap { name -> String? in
            guard name.hasSuffix(bootSuffix) else { return nil }
            let stem = String(name.dropLast(bootSuffix.count))
            return stem.isEmpty ? nil : stem
        })
        let runtimeStems = Set(names.compactMap { name -> String? in
            guard name.hasSuffix(runtimeSuffix) else { return nil }
            let stem = String(name.dropLast(runtimeSuffix.count))
            return stem.isEmpty ? nil : stem
        })
        guard !bootStems.isDisjoint(with: runtimeStems),
              let settingsURL = entries.first(where: {
                $0.lastPathComponent.caseInsensitiveCompare("settings.txt") == .orderedSame
              }),
              let settings = try? String(contentsOf: settingsURL, encoding: .utf8).lowercased()
        else { return false }

        return ["backbufferheight", "windowedmode", "use8bitrender"]
            .allSatisfy(settings.contains)
    }

    /// Framework clásico SexyApp de PopCap distribuido mediante la API de Steam anterior a
    /// `steam_api.dll`. El juego carga `steam.dll` dinámicamente y necesita que el cliente lo
    /// arranque por AppID; ejecutarlo directamente muestra «Unable to load Steam.dll» antes de
    /// crear la superficie DirectDraw/D3D8.
    ///
    /// La firma no depende del título ni del AppID. Combina RTTI de SexyApp, el contrato DRM/IPC
    /// de PopCap, símbolos de la API Steam heredada y el layout firmado por `partner.xml`.
    func classicPopCapSteamProductName(_ executable: String) -> String? {
        guard isExecutable32Bit(executable),
              exeContains(executable, anyOf: ["?AVSexyAppBase@Sexy@@"]),
              exeContains(executable, anyOf: ["PopCapDRM_EnableLocking"]),
              exeContains(executable, anyOf: ["PopCapDrm_IPC_Response"]),
              exeContains(executable, anyOf: ["SteamStartup"]),
              exeContains(executable, anyOf: ["SteamBlockingCall"]),
              exeContains(executable, anyOf: ["SteamIsAppSubscribed"]),
              exeContains(executable, anyOf: ["Unable to load Steam.dll"]),
              exeContains(executable, anyOf: ["!popcapdrmprotect!"])
        else { return nil }

        let root = URL(fileURLWithPath: executable)
            .standardizedFileURL
            .deletingLastPathComponent()
        let fm = FileManager.default
        guard let rootEntries = try? fm.contentsOfDirectory(atPath: root.path) else {
            return nil
        }
        let rootNames = Set(rootEntries.map { $0.lowercased() })
        let requiredFiles = ["main.pak", "bass.dll", "j2k-codec.dll"]
        guard requiredFiles.allSatisfy({ rootNames.contains($0.lowercased()) }) else {
            return nil
        }

        let properties = root.appendingPathComponent("properties", isDirectory: true)
        guard let partnerName = (try? fm.contentsOfDirectory(atPath: properties.path))?
            .first(where: { $0.caseInsensitiveCompare("partner.xml") == .orderedSame }),
              let partnerXML = try? String(
                contentsOf: properties.appendingPathComponent(partnerName),
                encoding: .utf8
              )
        else { return nil }

        let partner = partnerXML.lowercased()
        guard [
            "<string id=\"partnername\">steam</string>",
            "<boolean id=\"noreg\">true</boolean>",
            "<boolean id=\"defaultwindowed\">",
            "<integer id=\"steamid\">",
            "<string id=\"prodname\">"
        ].allSatisfy(partner.contains) else { return nil }

        let pattern = #"(?is)<string\s+id\s*=\s*[\"']prodname[\"']\s*>\s*([^<]+?)\s*</string\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: partnerXML,
                range: NSRange(partnerXML.startIndex..., in: partnerXML)
              ),
              let valueRange = Range(match.range(at: 1), in: partnerXML)
        else { return nil }

        let productName = partnerXML[valueRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/\\:")
        guard !productName.isEmpty,
              productName != ".",
              productName != "..",
              productName.rangeOfCharacter(from: forbidden) == nil
        else { return nil }
        return productName
    }

    func isClassicPopCapSteamEngine(_ executable: String) -> Bool {
        classicPopCapSteamProductName(executable) != nil
    }

    /// Los ejecutables que deben ser creados por el cliente oficial de Steam no pueden lanzarse
    /// directamente ni repararse sustituyendo `steam_api`. La política se concentra aquí para que
    /// la UI, el seguimiento y la ruta de motor compartan exactamente la misma autodetección.
    func requiresSteamAppLaunch(_ executable: String) -> Bool {
        SteamDRMScanner.hasSteamStub(executable)
            || SteamDRMScanner.hasLegacyValveRunMeBootstrap(executable)
            || isClassicPopCapSteamEngine(executable)
    }

    /// Protecciones de espacio de usuario que deben conservar el `steam_api` original y hablar con
    /// el cliente oficial conectado. Sustituirlo por Goldberg altera una DLL que estos protectores
    /// pueden verificar antes de crear la primera ventana. La regla solo se activa si el mismo árbol
    /// contiene Steamworks; una build DRM-free de otra tienda con el mismo protector no abrirá Steam.
    func officialSteamClientProtection(_ executable: String) -> DRMAnalyzer.Protection? {
        let components = (executable as NSString).pathComponents
        let installRoot: String
        if let commonIndex = components.firstIndex(where: { $0.lowercased() == "common" }),
           commonIndex + 1 < components.count {
            installRoot = NSString.path(withComponents: Array(components[0...(commonIndex + 1)]))
        } else {
            installRoot = (executable as NSString).deletingLastPathComponent
        }
        let report = DRMAnalyzer.analyze(folder: installRoot, executable: executable)
        guard report.social.contains(.steamworks) else { return nil }
        let clientBound: Set<DRMAnalyzer.Protection> = [
            .publisherSteamTicket, .denuvo, .vmProtect, .themida, .enigma
        ]
        return report.protections.first { clientBound.contains($0) }
    }

    /// Algunos payloads protegidos pueden iniciarse directamente una vez que el cliente oficial ya
    /// está conectado en el mismo wineserver. Virtools clásico necesita precisamente esa variante:
    /// `-applaunch` selecciona el splash del depot y pierde el escritorio virtual, mientras el
    /// payload autorizado por el cliente vivo sí entra en CKEngine. La combinación SteamStub + firma
    /// Virtools mantiene esta excepción tan estrecha como el comportamiento comprobado.
    func usesProtectedDirectLaunchWithConnectedSteam(_ executable: String) -> Bool {
        SteamDRMScanner.hasSteamStub(executable)
            && isClassicVirtoolsDirectDrawEngine(executable)
    }

    /// Decide si el cliente oficial debe crear el proceso por AppID. Abrir Steam no basta para
    /// protecciones que validan su cadena de arranque: SteamStub y los protectores de terceros
    /// ligados a Steamworks necesitan `-applaunch`. La única excepción comprobada sigue siendo
    /// Virtools clásico, que se autoriza con el cliente conectado y después se ejecuta directamente.
    static func requiresOfficialSteamAppLaunch(
        builtInProtection: Bool,
        thirdPartyProtection: DRMAnalyzer.Protection?,
        directLaunchException: Bool
    ) -> Bool {
        (builtInProtection || thirdPartyProtection != nil) && !directLaunchException
    }

    /// Los AppID protegidos D3D12 deben conservar D3DMetal. El motor completo sigue siendo la ruta
    /// compartida para el resto de APIs, pero no puede adelantar a la rama D3D12 especializada.
    static func shouldUseFullWineForSteamAppLaunch(
        required: Bool,
        graphicsAPI: GameGraphicsAPI
    ) -> Bool {
        required && graphicsAPI != .d3d12
    }

    /// Unreal Engine 1 clásico: ejecutable PE32, núcleo modular en `System`, paquetes `.u` y
    /// renderizadores intercambiables declarados en el INI hermano. La combinación distingue esta
    /// generación de UE4/UE5 (que viven en `Binaries/Win*`) y no depende del título ni del AppID.
    func isUnrealEngine1Game(_ executable: String) -> Bool {
        guard isExecutable32Bit(executable) else { return false }
        let url = URL(fileURLWithPath: executable).standardizedFileURL
        let directory = url.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return false }
        let names = Set(entries.map { $0.lowercased() })
        let required = [
            "core.dll", "core.u", "engine.dll", "engine.u", "render.dll",
            "windrv.dll", "opengldrv.dll", "d3ddrv.dll", "softdrv.dll"
        ]
        guard required.allSatisfy(names.contains) else { return false }

        let stem = url.deletingPathExtension().lastPathComponent
        guard let iniName = entries.first(where: {
            $0.caseInsensitiveCompare("\(stem).ini") == .orderedSame
        }), let config = try? String(
            contentsOf: directory.appendingPathComponent(iniName),
            encoding: .utf8
        ) else { return false }
        let lower = config.lowercased()
        return [
            "[engine.engine]", "gamerenderdevice=", "windowedrenderdevice=",
            "viewportmanager=windrv.windowsclient", "[windrv.windowsclient]"
        ].allSatisfy(lower.contains)
    }

    /// El renderizador moderno fijado por Vessel mantiene el ABI concreto de Deus Ex 1.112fm;
    /// no debe copiarse a ciegas sobre Unreal Tournament, Rune u otros juegos de la misma
    /// generación. Esta segunda firma combina módulos y contrato INI propios de Ion Storm.
    func isDeusExUnrealEngine1Game(_ executable: String) -> Bool {
        guard isUnrealEngine1Game(executable) else { return false }
        let url = URL(fileURLWithPath: executable).standardizedFileURL
        let directory = url.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return false }
        let names = Set(entries.map { $0.lowercased() })
        guard [
            "deusex.dll", "deusex.u", "deusextext.dll", "extension.dll",
            "extension.u", "consys.dll", "consys.u"
        ].allSatisfy(names.contains) else { return false }

        let stem = url.deletingPathExtension().lastPathComponent
        guard let iniName = entries.first(where: {
            $0.caseInsensitiveCompare("\(stem).ini") == .orderedSame
        }), let config = try? String(
            contentsOf: directory.appendingPathComponent(iniName),
            encoding: .utf8
        ) else { return false }
        let lower = config.lowercased()
        return lower.contains("gameengine=deusex.deusexgameengine")
            && lower.contains("mapext=dx")
            && lower.contains("root=deusex.deusexrootwindow")
    }

    /// Repara solo valores de vídeo incompatibles o imposibles de un INI de Unreal Engine 1.
    /// Una configuración OpenGL/D3D válida elegida por el jugador se conserva en la ruta genérica.
    /// Los defaults Glide/Metal/SGL se migran al OpenGL incluido; los títulos con un backend moderno
    /// gestionado pueden forzarlo de forma explícita. Las geometrías ausentes, de fábrica o mayores
    /// que la pantalla se ajustan a puntos lógicos para alinear lienzo y ratón.
    nonisolated static func repairedUnrealEngine1Config(
        existing: String,
        screenSize: CGSize,
        windowedSize: CGSize? = nil,
        forceModernOpenGL: Bool = false,
        forceSafeWindowedMode: Bool = false
    ) -> String? {
        let lower = existing.lowercased()
        guard lower.contains("[engine.engine]"),
              lower.contains("[windrv.windowsclient]") else { return nil }
        let fullscreenWidth = max(800, Int(screenSize.width.rounded(.down)))
        let fullscreenHeight = max(600, Int(screenSize.height.rounded(.down)))
        let requestedWindow = windowedSize ?? screenSize
        let windowedWidth = max(800, min(
            fullscreenWidth,
            Int(requestedWindow.width.rounded(.down))
        ))
        let windowedHeight = max(600, min(
            fullscreenHeight,
            Int(requestedWindow.height.rounded(.down))
        ))

        func sectionRange(_ section: String, in source: String) -> Range<String.Index>? {
            let escaped = NSRegularExpression.escapedPattern(for: section)
            return source.range(
                of: #"(?ims)^\["# + escaped + #"\]\s*$.*?(?=^\[|\z)"#,
                options: .regularExpression
            )
        }

        func value(_ key: String, section: String) -> String? {
            guard let range = sectionRange(section, in: existing) else { return nil }
            let block = String(existing[range])
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = #"(?mi)^[\t ]*"# + escaped + #"[\t ]*=[\t ]*([^\r\n]*)"#
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                      in: block,
                      range: NSRange(block.startIndex..., in: block)
                  ),
                  let matchRange = Range(match.range(at: 1), in: block) else { return nil }
            return block[matchRange].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func setting(_ source: String, section: String, key: String, value: String) -> String {
            guard let range = sectionRange(section, in: source) else { return source }
            var block = String(source[range])
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = #"(?mi)^[\t ]*"# + escaped + #"[\t ]*=[^\r\n]*"#
            if let lineRange = block.range(of: pattern, options: .regularExpression) {
                block.replaceSubrange(lineRange, with: "\(key)=\(value)")
            } else {
                block += (block.hasSuffix("\n") ? "" : "\n") + "\(key)=\(value)\n"
            }
            var result = source
            result.replaceSubrange(range, with: block)
            return result
        }

        func settingEnsuringSection(
            _ source: String,
            section: String,
            key: String,
            value: String
        ) -> String {
            if sectionRange(section, in: source) != nil {
                return setting(source, section: section, key: key, value: value)
            }
            let newline = source.contains("\r\n") ? "\r\n" : "\n"
            let separator = source.hasSuffix(newline) ? newline : newline + newline
            return source + separator + "[\(section)]\(newline)\(key)=\(value)\(newline)"
        }

        let rendererKeys = ["GameRenderDevice", "WindowedRenderDevice", "RenderDevice"]
        let renderers = rendererKeys.compactMap { value($0, section: "Engine.Engine") }
        // SoftwareRenderDevice evita el crash, pero dibuja toda la escena 3D en CPU y el propio
        // motor vuelve a 640×480/16-bit. No es una preferencia gráfica utilizable cuando el depot
        // incluye OpenGLDrv; se trata igual que los backends históricos que Wine no puede presentar.
        let unsupportedRenderers = ["glidedrv.", "metaldrv.", "sgldrv.", "softdrv."]
        let rendererNeedsRepair = forceModernOpenGL
            || renderers.count != rendererKeys.count
            || renderers.contains { renderer in
                unsupportedRenderers.contains { renderer.lowercased().contains($0) }
            }

        let viewportKeys = [
            "WindowedViewportX", "WindowedViewportY",
            "FullscreenViewportX", "FullscreenViewportY"
        ]
        let viewports = viewportKeys.map { value($0, section: "WinDrv.WindowsClient").flatMap(Int.init) }
        let missingGeometry = viewports.contains(where: { $0 == nil })
        let oversized = (viewports[0] ?? 0) > windowedWidth
            || (viewports[1] ?? 0) > windowedHeight
            || (viewports[2] ?? 0) > fullscreenWidth
            || (viewports[3] ?? 0) > fullscreenHeight
        let factoryGeometry = viewports[0] == 640 && viewports[1] == 480
            && viewports[2] == 640 && viewports[3] == 480
        let forcedGeometryMismatch = forceSafeWindowedMode
            && (viewports[0] != windowedWidth || viewports[1] != windowedHeight
                || viewports[2] != fullscreenWidth || viewports[3] != fullscreenHeight)
        let geometryNeedsRepair = missingGeometry || oversized
            || (rendererNeedsRepair && factoryGeometry) || forcedGeometryMismatch
        let fullscreenNeedsRepair = forceSafeWindowedMode
            && value("StartupFullscreen", section: "WinDrv.WindowsClient")?.lowercased() != "false"
        let firstRunVersion = value("FirstRun", section: "FirstRun").flatMap(Int.init)
        let firstRunNeedsRepair = forceSafeWindowedMode
            && (firstRunVersion ?? 0) <= 0
        let modernSettings: [(String, String)] = [
            ("UsePalette", "False"),
            ("UseAlphaPalette", "False"),
            ("UseBGRATextures", "True"),
            ("UseMultiTexture", "True"),
            ("UseTrilinear", "True"),
            ("MaxAnisotropy", "8"),
            ("UseAA", "False"),
            ("SwapInterval", "1"),
            ("FrameRateLimit", "60"),
            ("UseVertexProgram", "False"),
            ("UseFragmentProgram", "False")
        ]
        let modernSettingsNeedRepair = forceModernOpenGL && modernSettings.contains {
            value($0.0, section: "OpenGLDrv.OpenGLRenderDevice")?.lowercased()
                != $0.1.lowercased()
        }
        guard rendererNeedsRepair || geometryNeedsRepair || fullscreenNeedsRepair
                || firstRunNeedsRepair || modernSettingsNeedRepair else { return nil }

        var repaired = existing
        if rendererNeedsRepair {
            for key in rendererKeys {
                repaired = setting(
                    repaired,
                    section: "Engine.Engine",
                    key: key,
                    value: "OpenGLDrv.OpenGLRenderDevice"
                )
            }
            repaired = setting(
                repaired,
                section: "WinDrv.WindowsClient",
                key: "UseDirectDraw",
                value: "False"
            )
            for key in ["WindowedColorBits", "FullscreenColorBits"] {
                repaired = setting(
                    repaired,
                    section: "WinDrv.WindowsClient",
                    key: key,
                    value: "32"
                )
            }
        }
        if geometryNeedsRepair {
            for (key, value) in [
                ("WindowedViewportX", windowedWidth),
                ("WindowedViewportY", windowedHeight),
                ("FullscreenViewportX", fullscreenWidth),
                ("FullscreenViewportY", fullscreenHeight)
            ] {
                repaired = setting(
                    repaired,
                    section: "WinDrv.WindowsClient",
                    key: key,
                    value: String(value)
                )
            }
        }
        if forceSafeWindowedMode {
            repaired = setting(
                repaired,
                section: "WinDrv.WindowsClient",
                key: "StartupFullscreen",
                value: "False"
            )
        }
        if forceModernOpenGL {
            for (key, value) in modernSettings {
                repaired = settingEnsuringSection(
                    repaired,
                    section: "OpenGLDrv.OpenGLRenderDevice",
                    key: key,
                    value: value
                )
            }
        }
        if firstRunNeedsRepair {
            // La distribución de Steam conserva el marcador de instalación a cero y abre un
            // asistente interactivo aunque el INI ya sea utilizable. 1100 es el marcador de la
            // configuración final de Deus Ex GOTY y no afecta a las preferencias posteriores.
            repaired = settingEnsuringSection(
                repaired,
                section: "FirstRun",
                key: "FirstRun",
                value: "1100"
            )
        }
        return repaired == existing ? nil : repaired
    }

    /// Deja margen para la barra de título y el Dock. UE1 no ajusta su superficie al cambiar el
    /// frame en macOS, por lo que una ventana igual al `visibleFrame` termina desbordándose y
    /// desplaza el mapa de clics. El redondeo a decenas evita modos fraccionarios poco fiables.
    nonisolated static func safeUnrealEngine1WindowSize(visibleSize: CGSize) -> CGSize {
        let widthMargin = min(72.0, max(40.0, visibleSize.width * 0.05))
        let heightMargin = min(60.0, max(48.0, visibleSize.height * 0.07))
        let width = max(800.0, ((visibleSize.width - widthMargin) / 10.0).rounded(.down) * 10.0)
        let height = max(600.0, ((visibleSize.height - heightMargin) / 10.0).rounded(.down) * 10.0)
        return CGSize(width: width, height: height)
    }

    /// UE1 crea `Running.ini` al arrancar y solo lo elimina durante un cierre limpio. «Detener» en
    /// Vessel finaliza el proceso deliberadamente, de modo que el marcador sobreviviría y abriría
    /// el asistente interactivo Recovery Mode en la siguiente sesión. Vessel ya diagnostica el
    /// arranque y conserva copias de seguridad, por lo que retirar exclusivamente este fichero vacío
    /// antes de jugar recupera el flujo automático sin tocar partidas ni preferencias.
    @discardableResult
    func clearUnrealEngine1RecoveryMarker(executable: String) -> Bool {
        guard isUnrealEngine1Game(executable) else { return false }
        let directory = URL(fileURLWithPath: executable).standardizedFileURL
            .deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              let markerName = entries.first(where: {
                  $0.caseInsensitiveCompare("Running.ini") == .orderedSame
              }) else { return false }
        do {
            try FileManager.default.removeItem(
                at: directory.appendingPathComponent(markerName)
            )
            return true
        } catch {
            return false
        }
    }

    private func ensureUnrealEngine1DisplaySettings(executable: String) async throws {
        guard isUnrealEngine1Game(executable) else { return }
        if clearUnrealEngine1RecoveryMarker(executable: executable) {
            log.log(
                "Unreal Engine 1: marcador de cierre forzado retirado; Recovery Mode omitido automáticamente.",
                level: .info
            )
        }
        let isDeusEx = isDeusExUnrealEngine1Game(executable)
        if isDeusEx {
            do {
                let renderer = try await unrealEngine1RendererManager
                    .installModernDeusExOpenGL(forExecutable: executable)
                switch renderer.status {
                case .installedPinned:
                    log.log(
                        "Deus Ex UE1: OpenGL moderno 2.1 descargado, verificado e instalado de forma aislada.",
                        level: .info
                    )
                case .alreadyPinned:
                    log.log("Deus Ex UE1: OpenGL moderno 2.1 verificado.", level: .debug)
                case .existingCustom:
                    log.log(
                        "Deus Ex UE1: renderizador personalizado existente conservado.",
                        level: .info
                    )
                }
            } catch {
                throw WineError.installationFailed(
                    "no se pudo preparar el renderizador moderno de Deus Ex: \(error.localizedDescription)"
                )
            }
        }
        let url = URL(fileURLWithPath: executable).standardizedFileURL
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              let iniName = entries.first(where: {
                  $0.caseInsensitiveCompare("\(stem).ini") == .orderedSame
              }) else { return }
        let ini = directory.appendingPathComponent(iniName)
        guard let existing = try? String(contentsOf: ini, encoding: .utf8) else { return }
        let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
        let screen = CGSize(width: mode?.width ?? 1512, height: mode?.height ?? 982)
        let visible = NSScreen.main?.visibleFrame.size ?? screen
        let safeWindow = Self.safeUnrealEngine1WindowSize(visibleSize: visible)
        guard let repaired = Self.repairedUnrealEngine1Config(
            existing: existing,
            screenSize: screen,
            windowedSize: isDeusEx ? safeWindow : screen,
            forceModernOpenGL: isDeusEx,
            forceSafeWindowedMode: isDeusEx
        ) else { return }

        let backup = ini.appendingPathExtension("vessel-original")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: ini, to: backup)
        }
        do {
            try repaired.write(to: ini, atomically: true, encoding: .utf8)
            if isDeusEx {
                log.log(
                    "Deus Ex UE1: OpenGL moderno y ventana \(Int(safeWindow.width))×\(Int(safeWindow.height)) ajustados automáticamente.",
                    level: .info
                )
            } else {
                log.log(
                    "Unreal Engine 1: OpenGL y viewport \(Int(screen.width))×\(Int(screen.height)) preparados automáticamente.",
                    level: .info
                )
            }
        } catch {
            throw WineError.installationFailed(
                "no se pudo autorreparar la configuración de Unreal Engine 1: \(error.localizedDescription)"
            )
        }
    }

    /// HPL3 de Frictional: combina un contexto OpenGL implícito de compatibilidad con GLSL
    /// moderno, VAO, bindings explícitos y primitivas/formato de textura retirados del perfil
    /// core de macOS. La firma exige arquitectura, imports, marcadores internos y el contrato de
    /// recursos del motor; no depende del título, AppID ni nombre del ejecutable.
    func isLegacyHPL3OpenGLEngine(_ executable: String) -> Bool {
        guard !isExecutable32Bit(executable) else { return false }
        let imports = peImportedLibraries(forExecutable: executable)
        guard [
            "opengl32.dll", "glew32.dll", "sdl2.dll", "newton.dll",
            "fmodex64.dll", "fmod_event64.dll"
        ].allSatisfy(imports.contains) else { return false }
        guard exeContains(executable, anyOf: ["-------- THE HPL ENGINE LOG ------------"]),
              exeContains(executable, anyOf: ["HPLJobThread_"]),
              exeContains(executable, anyOf: ["Failed to create OpenGL main thread context"]),
              exeContains(executable, anyOf: [" Init Glew..."])
        else { return false }

        let directory = (executable as NSString).deletingLastPathComponent
        return [
            "hps_api.hps",
            "materials.cfg",
            "_shadersource/shadercache.xml"
        ].allSatisfy {
            FileManager.default.fileExists(
                atPath: (directory as NSString).appendingPathComponent($0)
            )
        }
    }

    /// HPL3 distribuye un ejecutable oficial sin Steamworks junto al principal. El principal
    /// muestra un diálogo de fallo de Steam API incluso con una sustitución compatible; el hermano
    /// oficial llega al menú y a escena 3D. Solo se selecciona cuando ambos binarios tienen la misma
    /// firma HPL3, el actual importa Steamworks, el hermano no y sus nombres comparten raíz.
    func preferredLegacyHPL3Executable(for executable: String) -> String? {
        guard isLegacyHPL3OpenGLEngine(executable) else { return nil }
        let currentImports = peImportedLibraries(forExecutable: executable)
        guard currentImports.contains("steam_api64.dll") else { return nil }

        let url = URL(fileURLWithPath: executable).standardizedFileURL
        let directory = url.deletingLastPathComponent()
        let currentStem = Self.hpl3ExecutableStem(url)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for candidate in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = candidate.deletingPathExtension().lastPathComponent.lowercased()
            guard candidate.pathExtension.caseInsensitiveCompare("exe") == .orderedSame,
                  name.hasSuffix("_nosteam") || name.hasSuffix("-nosteam")
                    || name.hasSuffix(" nosteam"),
                  Self.hpl3ExecutableStem(candidate) == currentStem,
                  !peImportedLibraries(forExecutable: candidate.path).contains("steam_api64.dll"),
                  isLegacyHPL3OpenGLEngine(candidate.path)
            else { continue }
            return candidate.path
        }
        return nil
    }

    private nonisolated static func hpl3ExecutableStem(_ url: URL) -> String {
        var stem = url.deletingPathExtension().lastPathComponent.lowercased()
        for suffix in ["_nosteam", "-nosteam", " nosteam"] where stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            break
        }
        return String(stem.filter { $0.isLetter || $0.isNumber })
    }

    /// Ejecutable y prefijo que realmente deben observar/cerrar la UI y el diagnóstico. HPL3
    /// cambia ambos durante el lanzamiento (hermano oficial + prefijo aislado); devolver el target
    /// efectivo evita que «Detener», la detección de ventana y la recuperación tras reiniciar Vessel
    /// sigan buscando el ejecutable principal en el prefijo base.
    func launchTrackingTarget(
        for executable: String,
        basePrefix: String
    ) -> (executable: String, prefix: String) {
        let effectiveExecutable = preferredLegacyHPL3Executable(for: executable) ?? executable
        if let productName = classicPopCapSteamProductName(effectiveExecutable) {
            let payload = URL(fileURLWithPath: basePrefix, isDirectory: true)
                .appendingPathComponent("drive_c/ProgramData/PopCap Games", isDirectory: true)
                .appendingPathComponent(productName, isDirectory: true)
                .appendingPathComponent("popcapgame1.exe")
                .path
            return (payload, basePrefix)
        }
        guard isLegacyHPL3OpenGLEngine(effectiveExecutable) else {
            return (effectiveExecutable, basePrefix)
        }
        let suffix = "__opengl-legacy"
        let effectivePrefix = basePrefix.hasSuffix(suffix) ? basePrefix : basePrefix + suffix
        return (effectiveExecutable, effectivePrefix)
    }

    /// Runtime clásico de Nihon Falcom usado por Ys Origin: PE32, Direct3D 9 y paquetes
    /// propietarios `.nya`/`.ni`/`.na`. Estas builds dibujan a escala lógica 1×; con Retina
    /// Wine crea una superficie 2× y el juego solo rellena una esquina de la pantalla.
    ///
    /// La firma combina imports PE, nombres internos del subsistema y los tres contenedores de
    /// recursos. No depende del nombre del ejecutable ni del AppID y evita aplicar esta política
    /// a cualquier juego japonés o D3D9 genérico.
    func isNihonFalcomYsOriginD3D9Engine(_ executable: String) -> Bool {
        guard isExecutable32Bit(executable) else { return false }
        let imports = peImportedLibraries(forExecutable: executable)
        guard ["d3d9.dll", "d3dx9_43.dll", "dsound.dll", "dinput8.dll"]
            .allSatisfy(imports.contains) else { return false }
        guard exeContains(executable, anyOf: [#"SOFTWARE\Falcom\YSO_WIN"#]),
              exeContains(executable, anyOf: [#"Release\data.nya"#]),
              exeContains(executable, anyOf: ["failed: Subsys D3D::Initialize"])
        else { return false }

        let directory = (executable as NSString).deletingLastPathComponent
        let release = (directory as NSString).appendingPathComponent("release")
        return ["data.nya", "data.ni", "data.na"].allSatisfy {
            FileManager.default.fileExists(
                atPath: (release as NSString).appendingPathComponent($0)
            )
        }
    }

    /// Runtime clásico de Clickteam Multimedia Fusion 2. El ejecutable distribuido es un
    /// contenedor PE32 que extrae el runtime real (`stdrt.exe`, `mmfs2.dll` y extensiones `.mfx`)
    /// a `%TEMP%` al arrancar, así que la tabla de imports del cargador no revela DirectDraw.
    ///
    /// Estas builds escalan su lienzo de 320×240 mediante múltiplos enteros. Con Retina activo,
    /// Wine vuelve a dividir ese tamaño: el modo 3× de 960×720 termina en 480×360 puntos y la
    /// superficie DirectDraw puede separarse de las coordenadas del ratón. La firma combina el
    /// runtime embebido, extensiones estándar y el contenedor de datos hermano; no usa título,
    /// nombre del ejecutable ni AppID.
    func isClickteamMultimediaFusion2DirectDrawEngine(_ executable: String) -> Bool {
        guard isExecutable32Bit(executable),
              exeContains(executable, anyOf: ["mmfs2.dll"]),
              exeContains(executable, anyOf: ["kcmouse.mfx"]),
              exeContains(executable, anyOf: ["kcwctrl.mfx"])
        else { return false }

        let url = URL(fileURLWithPath: executable).standardizedFileURL
        let directory = url.deletingLastPathComponent()
        let expectedDataName = url.deletingPathExtension().lastPathComponent + ".wgm"
        guard let siblings = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return false }

        // Windows resuelve estos nombres sin distinguir mayúsculas; conserva esa semántica
        // también si el bottle vive en un volumen de macOS sensible a mayúsculas.
        return siblings.contains {
            $0.caseInsensitiveCompare(expectedDataName) == .orderedSame
        }
    }

    /// Runtime Virtools clásico con rasterizador DirectX 7 cargado dinámicamente. El ejecutable no
    /// importa `ddraw.dll`: delega el render a `CKDX7Rasterizer.dll`, por lo que una detección basada
    /// solo en la tabla PE lo clasifica como `.other` y lo lanza contra el modo de pantalla real.
    /// En macOS ese `ChangeDisplaySettings(800×600)` devuelve `BADMODE`; el mismo runtime funciona
    /// dentro de un escritorio virtual que emule el modo exclusivo.
    ///
    /// La firma combina el núcleo Virtools, sus marcadores internos, el rasterizador, el loader y
    /// ambos tipos de contenido compilado. No depende del título, del AppID ni del nombre del exe.
    func isClassicVirtoolsDirectDrawEngine(_ executable: String) -> Bool {
        guard isExecutable32Bit(executable) else { return false }
        let imports = peImportedLibraries(forExecutable: executable)
        guard imports.contains("ck2.dll"), imports.contains("vxmath.dll"),
              exeContains(executable, anyOf: ["SetVirtoolsVersion"]),
              exeContains(executable, anyOf: ["CKRenderContext"]),
              exeContains(executable, anyOf: ["Vx3D_D3DR"]),
              exeContains(executable, anyOf: ["Creating full-screen render context"])
        else { return false }

        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: executable).deletingLastPathComponent()
        func names(in directory: URL) -> Set<String> {
            Set(((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
                .map { $0.lowercased() })
        }

        let rootNames = names(in: root)
        let dllNames = names(in: root.appendingPathComponent("Dlls", isDirectory: true))
        let cmoNames = names(in: root.appendingPathComponent("Cmo", isDirectory: true))
        guard rootNames.contains("ck2.dll"), rootNames.contains("vxmath.dll"),
              dllNames.contains("ckdx7rasterizer.dll"),
              dllNames.contains("virtoolsloaderr.dll"),
              cmoNames.contains(where: { $0.hasSuffix(".cmo") })
        else { return false }

        guard let enumerator = fileManager.enumerator(
            at: root.appendingPathComponent("Data", isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        var inspected = 0
        for case let url as URL in enumerator {
            inspected += 1
            if inspected > 10_000 { break }
            if url.pathExtension.caseInsensitiveCompare("nmo") == .orderedSame { return true }
        }
        return false
    }

    /// Extrae el directorio de partidas que el propio runtime entrega a SHGetFolderPath. Se exige
    /// una cadena ASCII terminada en ` Saves` y delimitada por NUL; así se puede preparar el primer
    /// arranque sin codificar un nombre de juego ni asumir el usuario del prefijo.
    func classicVirtoolsSaveFolderName(_ executable: String) -> String? {
        guard isClassicVirtoolsDirectDrawEngine(executable),
              let data = try? Data(
                  contentsOf: URL(fileURLWithPath: executable),
                  options: .mappedIfSafe
              )
        else { return nil }
        let contents = String(decoding: data, as: UTF8.self)
        let pattern = #"(?:^|\x00)([A-Za-z0-9][A-Za-z0-9 ._'-]{1,63} Saves)\x00"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: contents,
                  range: NSRange(contents.startIndex..., in: contents)
              ),
              let range = Range(match.range(at: 1), in: contents)
        else { return nil }
        return String(contents[range])
    }

    /// Contrato binario del `Config.dat` de esta generación: siete UInt32 little-endian. Solo se
    /// cambia `bpp` de 16 a 32; volumen, música, subtítulos, detalle y FSAA permanecen intactos.
    /// Si aún no existe se genera el mismo estado por defecto del runtime, ya corregido a 32 bits.
    nonisolated static func repairedClassicVirtoolsConfig(existing: Data?) -> Data? {
        func uint32(_ data: Data, at offset: Int) -> UInt32 {
            (0..<4).reduce(0) { value, index in
                value | (UInt32(data[offset + index]) << UInt32(index * 8))
            }
        }
        func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
            for index in 0..<4 {
                data[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xff)
            }
        }

        guard let existing else {
            var created = Data(repeating: 0, count: 28)
            for (index, value) in [
                UInt32(0x5359_4232), 10, 5, 1, 32, 1, 0
            ].enumerated() {
                writeUInt32(value, to: &created, at: index * 4)
            }
            return created
        }
        guard existing.count == 28,
              uint32(existing, at: 0) == 0x5359_4232,
              uint32(existing, at: 16) == 16
        else { return nil }
        var repaired = existing
        writeUInt32(32, to: &repaired, at: 16)
        return repaired
    }

    /// Prepara o repara el vídeo del runtime antes de arrancar. Se conservan copias recuperables de
    /// configuraciones existentes y se prioriza el usuario `crossover`, que es el perfil efectivo
    /// del Wine completo; otros nombres siguen funcionando al reparar cualquier config ya creada.
    private func ensureClassicVirtoolsDisplaySettings(prefix: String, executable: String) {
        guard let saveFolder = classicVirtoolsSaveFolderName(executable),
              exeContains(executable, anyOf: ["No 'Config.dat' file. Creating the default one."]),
              exeContains(executable, anyOf: ["Wrong 'Config.dat' file version."])
        else { return }

        let fileManager = FileManager.default
        let usersDirectory = "\(prefix)/drive_c/users"
        let users = ((try? fileManager.contentsOfDirectory(atPath: usersDirectory)) ?? [])
            .filter { $0.caseInsensitiveCompare("Public") != .orderedSame }
            .sorted()
        var paths = users.map {
            "\(usersDirectory)/\($0)/Documents/\(saveFolder)/Config.dat"
        }.filter(fileManager.fileExists)
        if paths.isEmpty {
            let preferred = users.first(where: {
                $0.caseInsensitiveCompare("crossover") == .orderedSame
            }) ?? users.first
            guard let preferred else { return }
            paths = ["\(usersDirectory)/\(preferred)/Documents/\(saveFolder)/Config.dat"]
        }

        for path in paths {
            let existing = try? Data(contentsOf: URL(fileURLWithPath: path))
            guard let repaired = Self.repairedClassicVirtoolsConfig(existing: existing) else {
                continue
            }
            let backup = path + ".vessel-16bpp-backup"
            if existing != nil, !fileManager.fileExists(atPath: backup) {
                do {
                    try fileManager.copyItem(atPath: path, toPath: backup)
                } catch {
                    log.log(
                        "Virtools: no se tocó Config.dat porque no se pudo crear una copia recuperable.",
                        level: .warn
                    )
                    continue
                }
            }
            do {
                try fileManager.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try repaired.write(to: URL(fileURLWithPath: path), options: .atomic)
                log.log(
                    existing == nil
                        ? "Virtools clásico: vídeo inicial preparado automáticamente a 32 bits."
                        : "Virtools clásico: vídeo de 16 bits autorreparado a 32 bits; copia conservada.",
                    level: .info
                )
            } catch {
                log.log(
                    "No se pudo preparar el vídeo del runtime Virtools: \(error.localizedDescription)",
                    level: .warn
                )
            }
        }
    }

    /// Los runtimes PE32 no conscientes de HiDPI deben trabajar 1:1 en puntos. Mantener la
    /// decisión en una función comprobable impide ampliar la excepción a cualquier juego de
    /// 32 bits y permite restaurar Retina explícitamente para todos los demás.
    func usesLegacy32BitNativeScaling(_ executable: String) -> Bool {
        isClickteamMultimediaFusion2DirectDrawEngine(executable)
            || isUnrealEngine1Game(executable)
            || isClassicVirtoolsDirectDrawEngine(executable)
    }

    /// Genera la configuración oficial de primer arranque de Ys Origin o repara solamente su
    /// geometría de pantalla completa. Una ventana válida elegida por el jugador nunca se cambia.
    nonisolated static func repairedFalcomYsOriginConfig(
        existing: String?,
        screenSize: CGSize
    ) -> String? {
        let width = max(960, Int(screenSize.width.rounded(.down)))
        let height = max(600, Int(screenSize.height.rounded(.down)))
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return """
            IniVersion=0x100

            [kernel]
            ClampInternalFrameRateMin=5
            ClampInternalFrameRateMax=10000
            AccessArchiveViaMemoryMappedFile=1
            HighResoText=1
            EnglishRoonic=0

            [game]
            BloodyEffectLevel=2
            Language=1

            [graphics]
            Device=0
            Adapter=0
            BackBufferWidth=\(width)
            BackBufferHeight=\(height)
            BackBufferFormat32=1
            StretchAspect=0
            RefreshRate=0
            MultiSampleType=0
            TextureFilter=2
            Anisotropy=2
            Windowed=0
            WaitVSync=1
            ForceSoftwareVP=0
            DisablePixelShader=0
            TripleBuffer=0
            LowResoTexture=0
            CompressedTexture=1
            OtherLightWeightMode=0
            ShowFPS=0
            Mipmap=1
            GammaEnable=1
            MaskOfEyes=0
            WaterCaustics=0
            DisableQPC=0
            GammaValue=1.00000000
            DisableMovies=0
            WaterEffectLevel=0
            ShadowEffectLevel=2
            GlareEffectLevel=2

            [sound]
            Device=0
            PlayBgm=1
            PlayEffect=1
            Reverb=0
            ForceSoftwareSoundBuffer=0
            BgmVolume=512
            EffectVolume=512

            [input]
            MouseButtonAlwaysOkCancel=1
            PadAnalog=0
            DashControl=1
            AtkBtnMagic=0
            AlwaysDashOK=0
            ForceFeedback=1
            GamePad=1
            GamePadID=1
            FileIndex=0
            Assign{KEY_ACTION}="Z"
            Assign{KEY_JUMP}="X"
            Assign{KEY_SHOT}="C"
            Assign{KEY_USE}="V"
            Assign{KEY_MENU}="Space"
            Assign{KEY_WALK}="L-Shift"
            Assign{KEY_SWORD_REVD}="S"
            Assign{KEY_SWORD_REVU}="D"
            Assign{KEY_SWORD0}="1"
            Assign{KEY_SWORD1}="2"
            Assign{KEY_SWORD2}="3"
            Assign{KEY_UP}="Numpad8"
            Assign{KEY_DOWN}="Numpad2"
            Assign{KEY_LEFT}="Numpad4"
            Assign{KEY_RIGHT}="Numpad6"
            Assign{KEY_UPLEFT}="Numpad7"
            Assign{KEY_UPRIGHT}="Numpad9"
            Assign{KEY_DOWNLEFT}="Numpad1"
            Assign{KEY_DOWNRIGHT}="Numpad3"
            Assign{MOUSE_DIR}="L-Button"
            Assign{PAD_ACTION}="Button1"
            Assign{PAD_JUMP}="Button2"
            Assign{PAD_SHOT}="Button3"
            Assign{PAD_USE}="Button4"
            Assign{PAD_MENU}="Button10"
            Assign{PAD_WALK}="Button9"
            Assign{PAD_SWORD_REVD}="Button5"
            Assign{PAD_SWORD_REVU}="Button8"
            Assign{MOUSE_ACTION}="---"
            Assign{MOUSE_JUMP}="R-Button"
            Assign{MOUSE_SHOT}="---"
            Assign{MOUSE_USE}="M-Button"
            Assign{MOUSE_MENU}="---"
            Assign{MOUSE_WALK}="---"
            DeadZone=0.34999999
            RunWalkThreshold=0.50000000
            MouseSensitivity=1.00000000
            DoubleClickFrame=12
            """ + "\n"
        }

        func value(_ key: String) -> Int? {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = #"(?mi)^\s*"# + escaped + #"\s*=\s*(\d+)\s*$"#
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                      in: existing,
                      range: NSRange(existing.startIndex..<existing.endIndex, in: existing)
                  ),
                  let range = Range(match.range(at: 1), in: existing)
            else { return nil }
            return Int(existing[range])
        }

        let currentWidth = value("BackBufferWidth")
        let currentHeight = value("BackBufferHeight")
        let windowed = value("Windowed")
        let missingGeometry = currentWidth == nil || currentHeight == nil || windowed == nil
        let oversized = (currentWidth ?? 0) > width || (currentHeight ?? 0) > height
        let fullscreenMismatch = windowed == 0
            && (currentWidth != width || currentHeight != height)
        guard missingGeometry || oversized || fullscreenMismatch else { return nil }

        func setGraphicsValue(_ source: String, key: String, value: Int) -> String {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let linePattern = #"(?mi)^\s*"# + escaped + #"\s*=.*$"#
            if let range = source.range(of: linePattern, options: .regularExpression) {
                var result = source
                result.replaceSubrange(range, with: "\(key)=\(value)")
                return result
            }

            let sectionPattern = #"(?ms)^\[graphics\]\s*$.*?(?=^\[|\z)"#
            guard let sectionRange = source.range(of: sectionPattern, options: .regularExpression)
            else {
                return source + (source.hasSuffix("\n") ? "" : "\n")
                    + "\n[graphics]\n\(key)=\(value)\n"
            }
            var section = String(source[sectionRange])
            section += (section.hasSuffix("\n") ? "" : "\n") + "\(key)=\(value)\n"
            var result = source
            result.replaceSubrange(sectionRange, with: section)
            return result
        }

        var repaired = setGraphicsValue(existing, key: "BackBufferWidth", value: width)
        repaired = setGraphicsValue(repaired, key: "BackBufferHeight", value: height)
        if windowed == nil {
            repaired = setGraphicsValue(repaired, key: "Windowed", value: 0)
        }
        return repaired
    }

    /// Prepara el archivo que el propio runtime sincroniza con Steam Cloud. Se escribe antes del
    /// arranque, únicamente para esta firma estructural y conservando audio, controles e idioma.
    private func ensureFalcomYsOriginDisplaySettings(prefix: String, executable: String) {
        guard isNihonFalcomYsOriginD3D9Engine(executable) else { return }
        let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
        let screen = CGSize(width: mode?.width ?? 1512, height: mode?.height ?? 982)
        let fileManager = FileManager.default
        let usersDirectory = "\(prefix)/drive_c/users"
        let users = ((try? fileManager.contentsOfDirectory(atPath: usersDirectory)) ?? []).sorted()
        var paths = users.compactMap { user -> String? in
            let path = "\(usersDirectory)/\(user)/Saved Games/FALCOM/yso_win/yso_win.ini"
            return fileManager.fileExists(atPath: path) ? path : nil
        }
        if paths.isEmpty {
            let preferred = users.contains("crossover") ? "crossover" : users.first
            guard let preferred else { return }
            paths = ["\(usersDirectory)/\(preferred)/Saved Games/FALCOM/yso_win/yso_win.ini"]
        }

        for path in paths {
            let existing = try? String(contentsOfFile: path, encoding: .utf8)
            guard let repaired = Self.repairedFalcomYsOriginConfig(
                existing: existing,
                screenSize: screen
            ) else { continue }
            do {
                try fileManager.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try repaired.write(toFile: path, atomically: true, encoding: .utf8)
                log.log(
                    "Motor Falcom: pantalla completa ajustada automáticamente a \(Int(screen.width))×\(Int(screen.height)).",
                    level: .info
                )
            } catch {
                log.log(
                    "No se pudo preparar la resolución del motor Falcom: \(error.localizedDescription)",
                    level: .warn
                )
            }
        }
    }

    /// Runtime Chowdren compilado a C++ con SDL2 embebido y el renderer D3D9 de Windows.
    ///
    /// No basta con detectar SDL2+D3D9: miles de juegos comparten esa combinación. Chowdren deja
    /// dos nombres de entorno propios en el binario y SDL deja la función de selección del adaptador
    /// D3D9. Exigir todas las señales limita el backend 2D sin comparación de profundidad a la
    /// familia para la que se validó y evita alterar motores 3D o juegos SDL genéricos.
    func isChowdrenSDL2D3D9Engine(_ executable: String) -> Bool {
        guard isExecutable32Bit(executable),
              exeImports(executable, anyOf: ["d3d9.dll"]) else { return false }
        return exeContains(executable, anyOf: ["CHOWDREN_SDL_DEBUG"])
            && exeContains(executable, anyOf: ["CHOWDREN_SDL_LOG"])
            && exeContains(executable, anyOf: ["SDL_CreateRenderer"])
            && exeContains(executable, anyOf: ["SDL_Direct3D9GetAdapterIndex"])
    }

    /// Resolución inicial de los motores Shining Rock sin HiDPI. Se ajusta al área visible de macOS
    /// con margen para la barra de título y el Dock, conserva 16:10 y nunca baja del mínimo oficial
    /// de Banished (800×600). Con Retina desactivado, estos píxeles equivalen a puntos de ventana.
    nonisolated static func shiningRockDisplaySize(for visibleSize: CGSize) -> CGSize {
        let availableWidth = max(800, Int(visibleSize.width.rounded(.down)) - 64)
        let availableHeight = max(600, Int(visibleSize.height.rounded(.down)) - 64)
        var height = min(800, availableHeight)
        var width = min(1280, availableWidth, Int((Double(height) * 1.6).rounded(.down)))
        if width < 800 {
            width = 800
            height = 600
        } else if Double(width) / Double(height) < 1.5 {
            height = max(600, Int((Double(width) / 1.6).rounded(.down)))
        }
        return CGSize(width: width - (width % 8), height: height - (height % 8))
    }

    /// Inicializa únicamente los ajustes de vídeo que aún no existen. Banished guarda Strings en
    /// HKCU; preservar las claves presentes permite que cualquier cambio posterior del usuario gane.
    private func ensureShiningRockDisplaySettings(prefix: String, wine: String) async {
        let registryKey = #"HKCU\Software\Shining Rock Software LLC\Banished"#
        let environment = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "winedbg.exe=d"
        ]
        let query = try? await runWine(
            winePath: wine,
            arguments: ["reg", "query", registryKey],
            prefix: prefix,
            environment: environment,
            allowNonZeroExit: true
        )
        let existing = query?.output.lowercased() ?? ""
        let visibleSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1512, height: 870)
        let target = Self.shiningRockDisplaySize(for: visibleSize)
        let defaults = [
            ("VideoWidth", String(Int(target.width))),
            ("VideoHeight", String(Int(target.height))),
            ("VideoFullscreen", "false")
        ]
        var changed = false
        for (name, value) in defaults where !existing.contains(name.lowercased()) {
            let result = try? await runWine(
                winePath: wine,
                arguments: [
                    "reg", "add", registryKey, "/v", name,
                    "/t", "REG_SZ", "/d", value, "/f"
                ],
                prefix: prefix,
                environment: environment,
                allowNonZeroExit: true
            )
            changed = changed || result?.exitCode == 0
        }
        if changed {
            log.log(
                "Motor Shining Rock: resolución inicial ajustada automáticamente a \(Int(target.width))×\(Int(target.height)).",
                level: .info
            )
        }
    }

    /// Fija la resolución en el `kexengine.cfg` a los **píxeles reales** de la pantalla.
    ///
    /// El motor KEX pregunta la resolución al arrancar y guarda `v_width`/`v_height` en su cfg. Bajo
    /// Wine con Retina, esa resolución llega en PÍXELES (3024×1964 en un panel de 1512×982 puntos), y
    /// el juego abre una ventana de ESE tamaño en puntos → el doble de la pantalla, se ve solo el
    /// centro ampliado. La vuelta: escribirle nosotros `v_width`/`v_height` = los píxeles reales, que
    /// es lo que el motor espera; entonces la ventana sale a los puntos correctos y llena la pantalla.
    /// Verificado con DOOM + DOOM II (KEX/Vulkan): pasó de doble-desbordado a pantalla completa.
    private func fixKexResolution(prefix: String) {
        let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
        let w = mode?.pixelWidth ?? 3024, h = mode?.pixelHeight ?? 1964
        let fm = FileManager.default
        let usersDir = "\(prefix)/drive_c/users"
        for user in (try? fm.contentsOfDirectory(atPath: usersDir)) ?? [] {
            // Los KEX guardan su cfg en `Saved Games/<estudio>/<juego>/kexengine.cfg`.
            let saved = "\(usersDir)/\(user)/Saved Games"
            guard let e = fm.enumerator(atPath: saved) else { continue }
            for case let rel as String in e where (rel as NSString).lastPathComponent == "kexengine.cfg" {
                let path = "\(saved)/\(rel)"
                var cfg = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                func setCvar(_ name: String, _ value: Int) {
                    let line = "seta \(name) \"\(value)\""
                    if let r = cfg.range(of: #"(?m)^seta \#(name) "[^"]*""#, options: .regularExpression) {
                        cfg.replaceSubrange(r, with: line)
                    } else {
                        cfg += (cfg.hasSuffix("\n") || cfg.isEmpty ? "" : "\n") + line + "\n"
                    }
                }
                setCvar("v_width", w); setCvar("v_height", h); setCvar("v_windowmode", 1)
                try? cfg.write(toFile: path, atomically: true, encoding: .utf8)
                log.log("Motor KEX: resolución fijada a \(w)×\(h) (píxeles reales) para que llene la pantalla.", level: .info)
            }
        }
    }

    /// `true` si es un **Godot con Vulkan** (Godot 4 con su render por defecto).
    ///
    /// No vale mirar la tabla de imports: Godot carga `vulkan-1.dll` en tiempo de ejecución, así que
    /// su PE no la declara y la detección de "Vulkan nativo" no lo ve. Acaba clasificado por
    /// descarte y va al motor equivocado: arranca (su log dice "Godot Engine v4.3") pero **no abre
    /// ventana nunca**. Hay que mirar sus cadenas.
    ///
    /// Solo los que traen Vulkan: un Godot compilado únicamente con OpenGL (Cassette Beasts) NO cae
    /// aquí — a ese, forzarle Vulkan lo rompería, y ya funciona por su camino.
    func isGodotVulkanGame(_ executable: String) -> Bool {
        exeContains(executable, anyOf: ["Godot Engine"]) && exeContains(executable, anyOf: ["vulkan"])
    }

    /// Confirma que el ejecutable, o la DLL de motor que carga, usa Vulkan de Windows de forma
    /// nativa. Es distinto de DXVK: aquí el propio juego importa `vulkan-1.dll` y necesita un Wine
    /// con `winevulkan` + MoltenVK. Algunos launchers son mínimos (Hades) y el import vive en una
    /// `Engine*.dll` hermana, por lo que inspeccionar solo el `.exe` daría un falso negativo.
    func isNativeVulkanGame(_ executable: String) -> Bool {
        if exeImports(executable, anyOf: ["vulkan-1.dll"]) { return true }
        let directory = (executable as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        return names.prefix(256).contains { name in
            let lower = name.lowercased()
            guard lower.hasPrefix("engine"), lower.hasSuffix(".dll") else { return false }
            return exeImports("\(directory)/\(name)", anyOf: ["vulkan-1.dll"])
        }
    }

    /// Motor Moai clásico con backend SDL estático. Estas builds PE32 importan OpenGL pero no usan
    /// el contexto core/forward-compatible de los motores OpenGL modernos: con el clon unificado el
    /// proceso queda vivo sin ventana; el Wine completo crea el contexto compatible y renderiza.
    /// La firma exige motor + capa SDL + import PE real para no afectar a otros OpenGL de 32 bits.
    func isLegacyMoaiOpenGLGame(_ executable: String) -> Bool {
        isExecutable32Bit(executable)
            && detectGraphicsAPI(forExecutable: executable) == .opengl
            && exeContains(executable, anyOf: ["MOAIEnvironment", "MOAISim"])
            && exeContains(executable, anyOf: ["AKUSDL"])
    }

    /// Runtime 64-bit del Proton SDK de RTsoft (no relacionado con Valve Proton).
    ///
    /// Estas builds crean correctamente su contexto OpenGL con `wine-full`, pero su intento inicial
    /// de pantalla completa a 1024×768 falla antes de que el usuario pueda cambiar la configuración.
    /// La firma exige arquitectura, imports reales, marcadores internos del SDK, sus DLL adyacentes
    /// y el paquete de interfaz propio; así no convierte en modo ventana cualquier juego OpenGL/FMOD.
    func isRTsoftProtonOpenGLEngine(_ executable: String) -> Bool {
        guard isExecutable64Bit(executable) else { return false }

        let imports = peImportedLibraries(forExecutable: executable)
        let requiredImports: Set<String> = [
            "opengl32.dll", "fmod.dll", "zlibwapi.dll", "dinput8.dll", "libcurl-x64.dll"
        ]
        guard requiredImports.isSubset(of: imports),
              exeContains(executable, anyOf: [#"d:\projects\proton\shared\audio\audiomanagerfmodstudio.cpp"#]),
              exeContains(executable, anyOf: ["protoncurl-agent/1.0"]),
              exeContains(executable, anyOf: ["proton_temp.tmp"]),
              exeContains(executable, anyOf: ["Error initializing GL extensions. Update your GL drivers!"])
        else { return false }

        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: executable).deletingLastPathComponent()
        guard let rootContents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        let names = Set(rootContents.map { $0.lastPathComponent.lowercased() })
        guard ["fmod.dll", "zlibwapi.dll", "libcurl-x64.dll"].allSatisfy(names.contains),
              let interfaceDirectory = rootContents.first(where: {
                  $0.lastPathComponent.caseInsensitiveCompare("interface") == .orderedSame
                      && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
              }),
              let interfaceContents = try? fileManager.contentsOfDirectory(
                  at: interfaceDirectory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else { return false }

        let extensions = Set(interfaceContents.map { $0.pathExtension.lowercased() })
        return extensions.contains("rttex") && extensions.contains("rtfont")
    }

    /// El parámetro pertenece al adaptador automático del motor, no a la configuración del usuario.
    /// Si una tienda ya lo proporciona, se conserva sin duplicarlo.
    nonisolated static func rtsoftProtonLaunchArguments(_ arguments: [String]) -> [String] {
        let alreadyWindowed = arguments.contains {
            let value = $0.lowercased()
            return value == "-window" || value == "-windowed"
        }
        return alreadyWindowed ? arguments : arguments + ["-window"]
    }

    /// OGRE anterior a 1.7 carga el renderizador desde `Plugins.cfg`, no desde el ejecutable.
    /// La presencia de ambas DLL no decide nada: solo cuenta el plugin activo y su tabla PE real.
    /// Esta firma cubre builds PE32 con el D3D9 clásico seleccionado sin depender del título.
    func isLegacyOgreD3D9Game(_ executable: String) -> Bool {
        guard isExecutable32Bit(executable) else { return false }
        let directory = (executable as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory),
              let configName = names.first(where: {
                  $0.caseInsensitiveCompare("Plugins.cfg") == .orderedSame
              }),
              names.contains(where: {
                  $0.caseInsensitiveCompare("OgreMain.dll") == .orderedSame
              }),
              let config = try? String(
                  contentsOfFile: "\(directory)/\(configName)",
                  encoding: .utf8
              ) else { return false }

        let selectedRenderers = config.split(whereSeparator: \.isNewline).compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { return nil }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("Plugin") == .orderedSame else { return nil }
            let normalized = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "/")
            return ((normalized as NSString).lastPathComponent as NSString)
                .deletingPathExtension
        }
        guard selectedRenderers.contains(where: {
            $0.caseInsensitiveCompare("RenderSystem_Direct3D9") == .orderedSame
        }),
        let pluginName = names.first(where: {
            $0.caseInsensitiveCompare("RenderSystem_Direct3D9.dll") == .orderedSame
        }) else { return false }

        return exeImports("\(directory)/\(pluginName)", anyOf: ["d3d9.dll"])
    }

    /// True si el ejecutable es un juego **Java con JVM embebida** (p. ej. Wurm Unlimited): junto
    /// al exe hay un runtime Java (`runtime/bin/java.exe`, `jre/bin/java.exe`) o un `client.jar`.
    /// Misma detección por estructura que usa el importador (`SteamLibraryImporter`).
    func isJavaGame(_ executable: String) -> Bool {
        let dir = (executable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        for jre in ["runtime/bin/java.exe", "jre/bin/java.exe", "jdk/bin/java.exe"] {
            if fm.fileExists(atPath: "\(dir)/\(jre)") { return true }
        }
        return fm.fileExists(atPath: "\(dir)/client.jar")
    }

    /// Project Zomboid usa un launcher Java propio cuya integración Steam nativa espera callbacks
    /// que una API emulada no siempre entrega. El propio motor incluye un modo `-nosteam` oficial,
    /// pero no se debe delegar al usuario como parámetro manual: se activa al reconocer su manifiesto
    /// de launcher (clase principal + LWJGL OpenGL + propiedad Steam), nunca por el título o AppID.
    nonisolated func isZomboidJavaEngine(_ executable: String) -> Bool {
        let directory = (executable as NSString).deletingLastPathComponent
        let stem = ((executable as NSString).lastPathComponent as NSString).deletingPathExtension
        let manifest = "\(directory)/\(stem).json"
        guard let data = FileManager.default.contents(atPath: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mainClass = object["mainClass"] as? String,
              mainClass.replacingOccurrences(of: "/", with: ".")
                .caseInsensitiveCompare("zombie.gameStates.MainScreenState") == .orderedSame,
              let classpath = object["classpath"] as? [String],
              classpath.contains(where: {
                  ($0 as NSString).lastPathComponent.caseInsensitiveCompare("lwjgl-opengl.jar") == .orderedSame
              }),
              let vmArgs = object["vmArgs"] as? [String] else { return false }
        return vmArgs.contains { $0.caseInsensitiveCompare("-Dzomboid.steam=1") == .orderedSame }
    }

    /// Los launchers Java embebidos pueden cerrar todos los handles del directorio de instalación
    /// cuando la JVM ya cargó sus JAR. En ese punto `lsof` sigue confirmando el prefijo por sus logs
    /// y runtime, pero deja de mostrar la carpeta del juego; exigirla haría creer que el proceso se
    /// cerró y el fallback mataría una ventana ya funcional. La firma del motor permite relajar solo
    /// ese segundo filtro; nombre de imagen + prefijo continúan acotando la familia con seguridad.
    nonisolated func processTrackingDirectory(forExecutable executable: String) -> String? {
        isZomboidJavaEngine(executable)
            ? nil
            : (executable as NSString).deletingLastPathComponent
    }

    /// Detecta aplicaciones/juegos empaquetados con NW.js (Chromium + Node). Su ejecutable no suele
    /// importar Direct3D porque ANGLE lo carga desde `nw.dll`, por lo que el análisis PE genérico los
    /// clasificaba como `.other` y los enviaba a wined3d. La estructura del runtime es inequívoca:
    /// `nw.dll` junto a un paquete `package.nw` o `package.json`.
    func isNWJSGame(_ executable: String) -> Bool {
        let dir = (executable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        guard fm.fileExists(atPath: "\(dir)/nw.dll") else { return false }
        return fm.fileExists(atPath: "\(dir)/package.nw")
            || fm.fileExists(atPath: "\(dir)/package.json")
    }

    /// Algunos motores cargan Direct3D desde un módulo dinámico que el `.exe` no declara. NW.js,
    /// por ejemplo, importa `d3d9.dll` desde `nw.dll` aunque ANGLE termine renderizando por D3D11.
    /// Si no se detecta esa dependencia transitiva, el loader rechaza `nw.dll` completo con el
    /// engañoso `Module not found (0x7E)`. La decisión se basa en imports reales, no en títulos.
    func needsExeAdjacentD3D9Support(_ executable: String) -> Bool {
        if exeImports(executable, anyOf: ["d3d9.dll"]) { return true }
        guard isNWJSGame(executable) else { return false }
        let dir = (executable as NSString).deletingLastPathComponent
        return exeImports("\(dir)/nw.dll", anyOf: ["d3d9.dll"])
    }

    /// Respeta el manifiesto del propio runtime. Solo completa capacidades ausentes; no duplica ni
    /// sustituye la configuración que el desarrollador ya empaquetó en `chromium-args`.
    private func nwjsManifestDeclares(_ argument: String, executable: String) -> Bool {
        let dir = (executable as NSString).deletingLastPathComponent
        let candidates = ["\(dir)/package.json", "\(dir)/package.nw/package.json"]
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["chromium-args"] as? String else { continue }
            if raw.split(whereSeparator: \.isWhitespace).contains(where: {
                $0.caseInsensitiveCompare(argument) == .orderedSame
            }) {
                return true
            }
        }
        return false
    }

    /// Ajustes internos que Vessel deduce del motor del juego. No proceden de una configuración
    /// manual ni se guardan como argumentos del usuario: forman parte del adaptador automático del
    /// runtime y deben conservarse en todas las rutas de lanzamiento, incluida Steam real.
    func automaticEngineArguments(forExecutable executable: String) -> [String] {
        var result = unrealEngineArguments(forExecutable: executable)
        if isZomboidJavaEngine(executable) {
            // Goldberg satisface SteamAPI_Init, pero este motor puede quedarse esperando callbacks
            // de red después de `SteamUtils initialised successfully`. Su modo offline soportado
            // evita esa espera y mantiene el arranque completamente automático en Vessel.
            result.append("-nosteam")
        }
        if isNWJSGame(executable),
           !nwjsManifestDeclares("--in-process-gpu", executable: executable) {
            // Chromium/ANGLE bajo DXMT necesita crear el dispositivo GPU en el mismo proceso para
            // presentar una vista Metal real. Vessel lo activa al detectar la estructura de NW.js.
            result.append("--in-process-gpu")
        }
        return result
    }

    /// Compone una sola orden efectiva para cualquier ruta de motor. Los valores solicitados por
    /// el juego/perfil se preservan y los ajustes automáticos no se duplican.
    func resolvedLaunchArguments(
        forExecutable executable: String,
        requested: [String],
        effective: EffectiveLaunchConfig
    ) -> [String] {
        var result = requested + effective.launchArgs
        for argument in automaticEngineArguments(forExecutable: executable)
        where !result.contains(where: { $0.caseInsensitiveCompare(argument) == .orderedSame }) {
            result.append(argument)
        }
        return result
    }

    /// `true` si el juego usa el **XNA de Microsoft** y NO se lo trae consigo: entonces hay que
    /// instalarle el redistribuible, porque lo busca en el sistema.
    ///
    /// Distingue los dos mundos: **FNA** (la reimplementación libre) va en `FNA.dll` dentro de la
    /// carpeta del juego y se basta sola — FEZ. **XNA** de verdad vive en el GAC de Windows, y sin él
    /// el juego muere nada más arrancar con `Could not load file or assembly
    /// 'Microsoft.Xna.Framework'` — Terraria. Traer `...Content.Pipeline.dll` (una herramienta de
    /// desarrollo) no cuenta: lo que hace falta es el runtime.
    func needsXNARedistributable(_ executable: String) -> Bool {
        let dir = (executable as NSString).deletingLastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        let traeFNA = files.contains { $0.caseInsensitiveCompare("FNA.dll") == .orderedSame }
        let usaXNA = files.contains { $0.lowercased().hasPrefix("microsoft.xna.framework") }
        let traeRuntimeXNA = files.contains { $0.caseInsensitiveCompare("Microsoft.Xna.Framework.dll") == .orderedSame }
        return usaXNA && !traeFNA && !traeRuntimeXNA
    }

    /// Raíz del juego a partir del exe del emulador: GOG lo mete en una subcarpeta (`…/DOSBOX/`),
    /// así que la raíz es su padre — que es donde están los `.conf` y el juego en sí. Se confirma
    /// buscando el `goggame-<id>.info`; si no aparece, se asume el padre igualmente.
    nonisolated func retroGameRoot(forExecutable executable: String) -> String? {
        let dir = (executable as NSString).deletingLastPathComponent      // …/DOSBOX
        let parent = (dir as NSString).deletingLastPathComponent          // …/<juego>
        guard !parent.isEmpty, parent != "/" else { return nil }
        return parent
    }

    /// AppID de GOG leído del `goggame-<id>.info` de la carpeta (para nombrar la config traducida).
    nonisolated func retroAppId(_ gameRoot: String) -> String? {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: gameRoot) else { return nil }
        for f in items where f.hasPrefix("goggame-") && f.hasSuffix(".info") {
            return String(f.dropFirst("goggame-".count).dropLast(".info".count))
        }
        return nil
    }

    func detectGraphicsAPI(forExecutable executable: String) -> GameGraphicsAPI {
        let dir = (executable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        let exeName = ((executable as NSString).lastPathComponent as NSString).deletingPathExtension
        // NW.js/Chromium usa ANGLE y carga DXGI/D3D11 dinámicamente desde `nw.dll`; no aparece en
        // la tabla de imports del launcher. DXMT es su backend correcto en Apple Silicon.
        if isNWJSGame(executable) { return .d3d11 }
        // OGRE clásico declara el renderizador activo en Plugins.cfg y lo carga dinámicamente.
        // Inspeccionar solo Torchlight.exe, por ejemplo, lo deja como `.other` aunque el plugin
        // seleccionado importe D3D9 de forma inequívoca.
        if isLegacyOgreD3D9Game(executable) { return .d3d9 }
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
        // ANGLE 1.x legado puede ocultar D3D9 detrás de `libEGL.dll`/`libGLESv2.dll`: el ejecutable
        // solo importa OpenGL ES y la tabla PE principal no menciona Direct3D. La pareja de DLLs,
        // sus imports D3D9 y la firma de versión ANGLE confirman el backend real sin usar el título.
        if isLegacyANGLE1D3D9Game(executable) { return .d3d9 }
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
        // Algunos motores mantienen un launcher mínimo y cargan toda la capa gráfica desde una DLL
        // hermana `Engine*.dll`. Mirar solo el PE del `.exe` los clasifica como carga dinámica y los
        // manda primero a Gcenx aunque la DLL declare D3D11 de forma inequívoca (Hades). Se limita a
        // librerías cuyo nombre empieza por `engine` para no confundir renderers opcionales o SDKs.
        if let siblingAPI = siblingEngineGraphicsAPI(forExecutable: executable) {
            return siblingAPI
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
        // Algunos motores enlazan la API gráfica a través de una DLL local obligatoria. La tabla PE
        // del ejecutable declara ese módulo y el módulo declara D3D; seguir solo ese salto evita que
        // un payload Northlight D3D12 parezca «carga dinámica» y caiga en wined3d/Gcenx. Los imports
        // directos de arriba tienen prioridad para que una DLL de traducción local nunca contradiga
        // el contrato explícito del ejecutable. No se inspeccionan plugins opcionales ni títulos.
        let linkedSiblingImports = PEImportScanner
            .importedLibrariesFromDirectSiblingDependencies(atPath: executable)
        if linkedSiblingImports.contains("d3d12.dll") { return .d3d12 }
        if !linkedSiblingImports.isDisjoint(with: [
            "d3d11.dll", "dxgi.dll", "d3d10.dll", "d3d10core.dll"
        ]) { return .d3d11 }
        if !linkedSiblingImports.isDisjoint(with: ["d3d9.dll", "d3d8.dll", "ddraw.dll"]) {
            return .d3d9
        }
        if linkedSiblingImports.contains("opengl32.dll") { return .opengl }
        // Decima enlaza únicamente el compilador de shaders y resuelve D3D12/DXGI en runtime.
        // Por eso Death Stranding, y otras builds del mismo motor, no exponen la API gráfica en la
        // tabla PE ni mediante una dependencia hermana enlazada. La firma estructural exige a la
        // vez el contrato interno del motor, sus símbolos de carga D3D12 y el paquete de runtime;
        // no depende del título/AppID ni convierte cualquier juego con `dxcompiler.dll` en Decima.
        if isDecimaD3D12Engine(executable) { return .d3d12 }
        // La rama Enhanced de 4A Engine también resuelve la API en runtime. Su PE principal no
        // importa D3D12/DXGI aunque exige D3D12 + DXR 1.1, por lo que necesita D3DMetal desde el
        // primer intento y no la ruta genérica Gcenx. La detección se basa en el contrato del motor.
        if isFourAEnhancedD3D12Engine(executable) { return .d3d12 }
        // CryEngine moderno mantiene un launcher PE mínimo y carga dinámicamente el módulo del
        // juego (`*Game.dll`), que también contiene el renderer monolítico. El launcher no enlaza
        // esa DLL ni D3D, por lo que el salto PE directo no puede descubrirla. La firma exige los
        // diagnósticos de raíz de CryEngine en el launcher, el contrato `EngineModule_CryRenderer`
        // dentro de un módulo PE64 `*Game.dll` y sus imports gráficos reales. Así un plugin o
        // renderer opcional presente junto a cualquier otro juego nunca altera su ruta automática.
        if let cryEngineAPI = cryEngineGameModuleGraphicsAPI(forExecutable: executable) {
            return cryEngineAPI
        }
        // Algunos motores propietarios distribuyen un launcher mínimo y declaran el payload real
        // en un descriptor XML homónimo. GIANTS Engine, por ejemplo, conserva el contrato de
        // arranque/EOS en el launcher raíz y sitúa el renderer en `x64/`: ejecutar el payload
        // directamente rompería ese contrato, pero ignorarlo clasifica el juego como carga D3D
        // dinámica. Se hereda únicamente la API gráfica del payload declarado, con una regla
        // estructural acotada y rutas contenidas; el proceso que se lanza sigue siendo el original.
        if let declaredPayloadAPI = declaredX64PayloadGraphicsAPI(forExecutable: executable) {
            return declaredPayloadAPI
        }
        // **MKXP/RGSS** carga OpenGL dinámicamente desde su runtime Ruby, así que el PE principal no
        // importa `opengl32.dll`. La firma del motor (MKXP + RGSS + Ruby + SDL2) permite identificarlo
        // sin depender del título y evita enviarlo por error a la ruta genérica de Direct3D dinámico.
        if isMKXPRGSSGame(executable) { return .opengl }
        // Juegos con motor **OpenGL puro** (importan `opengl32.dll` y NINGÚN Direct3D): p. ej. Heroes
        // of Hammerwatch II (bgfx GL 3.2). En Apple Silicon bajo Wine el contexto GL 3.2 core se crea
        // por `winemac.so` (OpenGL→Metal de Apple) SOLO si es forward-compatible; muchos motores (bgfx)
        // piden 3.2 core sin ese bit → Wine lo rechaza (`ERROR_INVALID_VERSION_ARB`). El motor UNIFICADO
        // trae un `winemac.so` parcheado (CW Hack 24834) que, con `CX_FWD_COMPAT_GL_CTX=1`, inyecta el
        // bit y el contexto se crea. Se enruta como `.opengl` → motor unificado (ver `launch`).
        if exeImports(executable, anyOf: ["opengl32.dll"])
            || exeContains(executable, anyOf: ["OpenGL Error", "unable to create an OpenGL context", "Failed to init SDL"]) {
            return .opengl
        }
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

    /// API gráfica de un payload nativo declarado por un launcher mediante `<startup><cmdline>`.
    ///
    /// La detección exige simultáneamente el marcador `x64/` en el launcher, un XML homónimo y un
    /// nombre de ejecutable simple que exista dentro de `x64/`. No acepta argumentos, rutas ni
    /// symlinks que escapen del juego. Así se reconoce el patrón del motor sin confiar en títulos,
    /// AppIDs ni archivos opcionales presentes por casualidad.
    private func declaredX64PayloadGraphicsAPI(forExecutable executable: String) -> GameGraphicsAPI? {
        guard let payload = declaredX64PayloadExecutable(forExecutable: executable) else { return nil }
        var imports = PEImportScanner.importedLibraries(atPath: payload)
        imports.formUnion(
            PEImportScanner.importedLibrariesFromDirectSiblingDependencies(atPath: payload)
        )
        if imports.contains("d3d12.dll") { return .d3d12 }
        if !imports.isDisjoint(with: [
            "d3d11.dll", "dxgi.dll", "d3d10.dll", "d3d10core.dll"
        ]) { return .d3d11 }
        if !imports.isDisjoint(with: ["d3d9.dll", "d3d8.dll", "ddraw.dll"]) { return .d3d9 }
        if imports.contains("vulkan-1.dll") { return .d3d11 }
        if imports.contains("opengl32.dll") { return .opengl }
        return nil
    }

    /// Resuelve el payload declarado sin alterar el ejecutable que se debe lanzar. Además del
    /// enrutado gráfico, esta ruta alimenta el seguimiento multiproceso para que la UI no vuelva a
    /// «Jugar» cuando el launcher entrega el control a su proceso nativo.
    private nonisolated func declaredX64PayloadExecutable(forExecutable executable: String) -> String? {
        guard exeContains(executable, anyOf: ["x64/"]) else { return nil }

        let fileManager = FileManager.default
        let root = (executable as NSString).deletingLastPathComponent
        let launcherStem = (((executable as NSString).lastPathComponent) as NSString)
            .deletingPathExtension
        guard !root.isEmpty,
              let rootEntries = try? fileManager.contentsOfDirectory(atPath: root),
              let descriptorName = rootEntries.first(where: {
                  $0.caseInsensitiveCompare("\(launcherStem).xml") == .orderedSame
              }) else { return nil }

        let descriptorPath = (root as NSString).appendingPathComponent(descriptorName)
        guard PathSafety.isContained(descriptorPath, in: root),
              let attributes = try? fileManager.attributesOfItem(atPath: descriptorPath),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= 64 * 1_024,
              let data = try? Data(contentsOf: URL(fileURLWithPath: descriptorPath)) else {
            return nil
        }

        let delegate = StartupCommandLineXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.isInvalid,
              let payloadName = delegate.commandLine,
              Self.isSafeDeclaredPayloadName(payloadName) else { return nil }

        guard let x64Name = rootEntries.first(where: {
            var isDirectory: ObjCBool = false
            let path = (root as NSString).appendingPathComponent($0)
            return $0.caseInsensitiveCompare("x64") == .orderedSame
                && fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }) else { return nil }

        let x64Directory = (root as NSString).appendingPathComponent(x64Name)
        guard PathSafety.isContained(x64Directory, in: root),
              let payloadEntries = try? fileManager.contentsOfDirectory(atPath: x64Directory),
              let actualPayloadName = payloadEntries.first(where: {
                  $0.caseInsensitiveCompare(payloadName) == .orderedSame
              }) else { return nil }

        let payload = (x64Directory as NSString).appendingPathComponent(actualPayloadName)
        var isDirectory: ObjCBool = false
        guard PathSafety.isContained(payload, in: x64Directory),
              fileManager.fileExists(atPath: payload, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return payload
    }

    private nonisolated static func isSafeDeclaredPayloadName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == trimmed,
              !trimmed.isEmpty,
              trimmed.utf8.count <= 255,
              (trimmed as NSString).pathExtension.caseInsensitiveCompare("exe") == .orderedSame,
              !trimmed.contains(".."),
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\"'")) == nil,
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else { return false }
        return (trimmed as NSString).lastPathComponent == trimmed
    }

    private final class StartupCommandLineXMLDelegate: NSObject, XMLParserDelegate {
        private var stack: [String] = []
        private var buffer = ""
        private var capturesCommandLine = false
        private(set) var commandLine: String?
        private(set) var isInvalid = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let element = elementName.lowercased()
            stack.append(element)
            if element == "cmdline" {
                guard stack == ["startup", "cmdline"], commandLine == nil,
                      !capturesCommandLine else {
                    isInvalid = true
                    return
                }
                capturesCommandLine = true
                buffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capturesCommandLine else { return }
            buffer += string
            if buffer.utf8.count > 255 { isInvalid = true }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let element = elementName.lowercased()
            guard stack.last == element else {
                isInvalid = true
                return
            }
            if capturesCommandLine, stack == ["startup", "cmdline"] {
                commandLine = buffer
                capturesCommandLine = false
                buffer = ""
            }
            stack.removeLast()
        }

        func parser(
            _ parser: XMLParser,
            resolveExternalEntityName name: String,
            systemID: String?
        ) -> Data? {
            isInvalid = true
            return nil
        }
    }

    private func siblingEngineGraphicsAPI(forExecutable executable: String) -> GameGraphicsAPI? {
        let directory = (executable as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return nil
        }
        let engines = names.filter {
            let lower = $0.lowercased()
            return lower.hasPrefix("engine") && lower.hasSuffix(".dll")
        }.prefix(12)
        guard !engines.isEmpty else { return nil }

        let paths = engines.map { "\(directory)/\($0)" }
        if paths.contains(where: { exeImports($0, anyOf: ["d3d12.dll"]) }) { return .d3d12 }
        if paths.contains(where: { exeImports($0, anyOf: ["d3d11.dll", "dxgi.dll", "d3d10.dll", "d3d10core.dll"]) }) {
            return .d3d11
        }
        if paths.contains(where: { exeImports($0, anyOf: ["vulkan-1.dll"]) }) { return .d3d11 }
        if paths.contains(where: { exeImports($0, anyOf: ["d3d9.dll", "d3d8.dll", "ddraw.dll"]) }) { return .d3d9 }
        if paths.contains(where: { exeImports($0, anyOf: ["opengl32.dll"]) }) { return .opengl }
        return nil
    }

    /// Reconoce builds PE64 de Decima que cargan D3D12 y DXGI dinámicamente.
    ///
    /// El motor no importa `d3d12.dll` desde el ejecutable, así que una detección basada solo en la
    /// tabla PE lo clasificaría como `.other` y lo lanzaría por wined3d. Se valida una combinación
    /// inseparable de marcadores internos y componentes de distribución para mantener la regla
    /// genérica, automática y suficientemente estricta ante DLLs opcionales de otros motores.
    func isDecimaD3D12Engine(_ executable: String) -> Bool {
        guard isExecutable64Bit(executable) else { return false }

        let imports = peImportedLibraries(forExecutable: executable)
        let explicitGraphicsImports: Set<String> = [
            "d3d12.dll", "d3d11.dll", "d3d10.dll", "d3d10core.dll", "dxgi.dll",
            "d3d9.dll", "d3d8.dll", "ddraw.dll", "vulkan-1.dll", "opengl32.dll"
        ]
        guard imports.isDisjoint(with: explicitGraphicsImports) else { return false }

        let engineMarkers = ["DecimaTexture", "DecimaLogo", "OnFinishDecimaLogo"]
        guard engineMarkers.allSatisfy({ exeContains(executable, anyOf: [$0]) }) else {
            return false
        }

        let dynamicD3D12Markers = [
            "d3d12.dll",
            "D3D12SerializeRootSignature",
            "CreateDXGIFactory2",
            "ED3D12CommandListType"
        ]
        guard dynamicD3D12Markers.allSatisfy({ exeContains(executable, anyOf: [$0]) }) else {
            return false
        }

        let directory = (executable as NSString).deletingLastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        let files = Set(entries.map { $0.lowercased() })
        let hasOodleRuntime = files.contains {
            $0.hasPrefix("oo2core_") && $0.hasSuffix("_win64.dll")
        }
        return files.contains("dxcompiler.dll")
            && files.contains("d3dcompiler_47.dll")
            && files.contains("bink2w64.dll")
            && hasOodleRuntime
    }

    /// Reconoce la rama PC Enhanced de 4A Engine, que exige D3D12/DXR pero carga la API en runtime.
    ///
    /// Se combinan el diagnóstico interno de la edición Enhanced, el requisito DXR 1.1, los
    /// símbolos D3D12 y el paquete propio de compilación/HairWorks. Así las builds 4A que todavía
    /// ofrecen D3D11 no se fuerzan a D3D12 y un conjunto genérico de DLLs RTX tampoco activa la regla.
    func isFourAEnhancedD3D12Engine(_ executable: String) -> Bool {
        guard isExecutable64Bit(executable) else { return false }

        let imports = peImportedLibraries(forExecutable: executable)
        let explicitGraphicsImports: Set<String> = [
            "d3d12.dll", "d3d11.dll", "d3d10.dll", "d3d10core.dll", "dxgi.dll",
            "d3d9.dll", "d3d8.dll", "ddraw.dll", "vulkan-1.dll", "opengl32.dll"
        ]
        guard imports.isDisjoint(with: explicitGraphicsImports) else { return false }

        let engineMarkers = [
            "4A Engine",
            "PC Enhanced version",
            "Only DirectX 12 and Vulkan are supported.",
            "does not support DXR1.1 or above."
        ]
        guard engineMarkers.allSatisfy({ exeContains(executable, anyOf: [$0]) }) else {
            return false
        }

        let dynamicD3D12Markers = [
            "D3D12CreateDevice",
            "D3D12GetDebugInterface",
            "D3D12SerializeRootSignature",
            "CreateDXGIFactory2"
        ]
        guard dynamicD3D12Markers.allSatisfy({ exeContains(executable, anyOf: [$0]) }) else {
            return false
        }

        let directory = (executable as NSString).deletingLastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        let files = Set(entries.map { $0.lowercased() })
        return files.contains("dxcompiler_pc.dll")
            && files.contains("dxil.dll")
            && files.contains("nvhairworksdx12.win64.dll")
            && files.contains("content.vfx")
    }

    private func cryEngineGameModuleGraphicsAPI(
        forExecutable executable: String
    ) -> GameGraphicsAPI? {
        guard isExecutable64Bit(executable),
              exeContains(executable, anyOf: ["Unable to locate CryEngine root folder"]),
              exeContains(executable, anyOf: ["CryEngine root path is to long"])
        else { return nil }

        let directory = (executable as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return nil
        }
        let modules = names
            .filter { $0.lowercased().hasSuffix("game.dll") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(16)
            .map { "\(directory)/\($0)" }
            .filter {
                isExecutable64Bit($0)
                    && exeContains($0, anyOf: ["EngineModule_CryRenderer"])
            }
        guard !modules.isEmpty else { return nil }

        if modules.contains(where: { exeImports($0, anyOf: ["d3d12.dll"]) }) { return .d3d12 }
        if modules.contains(where: {
            exeImports($0, anyOf: ["d3d11.dll", "dxgi.dll", "d3d10.dll", "d3d10core.dll"])
        }) { return .d3d11 }
        if modules.contains(where: { exeImports($0, anyOf: ["vulkan-1.dll"]) }) { return .d3d11 }
        if modules.contains(where: { exeImports($0, anyOf: ["d3d9.dll", "d3d8.dll", "ddraw.dll"]) }) {
            return .d3d9
        }
        if modules.contains(where: { exeImports($0, anyOf: ["opengl32.dll"]) }) { return .opengl }
        return nil
    }

    /// Detecta el runtime ANGLE 1.x que implementa OpenGL ES sobre Direct3D 9.
    /// Requiere evidencia en las tres piezas del runtime para evitar clasificar por nombres sueltos.
    private func isLegacyANGLE1D3D9Game(_ executable: String) -> Bool {
        guard exeImports(executable, anyOf: ["libegl.dll"]),
              exeImports(executable, anyOf: ["libglesv2.dll"]) else { return false }

        let directory = (executable as NSString).deletingLastPathComponent
        let egl = "\(directory)/libEGL.dll"
        let gles = "\(directory)/libGLESv2.dll"
        guard FileManager.default.fileExists(atPath: egl),
              FileManager.default.fileExists(atPath: gles),
              exeImports(egl, anyOf: ["d3d9.dll"]),
              exeImports(gles, anyOf: ["d3d9.dll"]) else { return false }

        return exeContains(gles, anyOf: [
            "OpenGL ES 2.0 (ANGLE 1.",
            "OpenGL ES GLSL ES 1.00 (ANGLE 1."
        ])
    }

    /// Motor propietario clásico de Frozenbyte (Storm3D): D3D9, componentes C++ bajo el espacio
    /// `fb::` y recursos empaquetados en varios archivos `.fbq`. Estas builds no son HiDPI-aware:
    /// con Retina activo Wine crea una superficie de respaldo 2×, pero Storm3D presenta su buffer
    /// lógico 1× en la esquina superior izquierda y deja el resto de la ventana sin dibujar.
    ///
    /// La firma combina import PE, símbolos del motor y estructura de recursos para no convertir
    /// cualquier juego D3D9 moderno en legado ni depender del nombre del juego o de su AppID.
    func isFrozenbyteStorm3DD3D9Engine(_ executable: String) -> Bool {
        guard exeImports(executable, anyOf: ["d3d9.dll"]),
              exeContains(executable, anyOf: ["Storm3D"]),
              exeContains(executable, anyOf: [
                  "fb::animation::",
                  "#define FB_LUA_EXPRESSION_STRING"
              ]) else { return false }

        let directory = (executable as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        let packages = names.map { $0.lowercased() }.filter { $0.hasSuffix(".fbq") }
        guard packages.count >= 3 else { return false }
        let hasShaderPackage = packages.contains { $0.hasPrefix("shader") }
        let hasScriptPackage = packages.contains { $0.hasPrefix("script") }
        let hasWorldPackage = packages.contains {
            $0.hasPrefix("model") || $0.hasPrefix("animation") || $0.hasPrefix("texture")
        }
        return hasShaderPackage && hasScriptPackage && hasWorldPackage
    }

    /// El propio runtime documenta su carpeta de opciones como `%APPDATA%\<carpeta>\` en
    /// `config/readme_info.txt`. Leer ese contrato evita codificar nombres de juegos y permite que
    /// el mismo adaptador cubra otras versiones de Storm3D que empaqueten el manifiesto oficial.
    func frozenbyteOptionsFolderName(forExecutable executable: String) -> String? {
        let directory = (executable as NSString).deletingLastPathComponent
        let manifest = "\(directory)/config/readme_info.txt"
        guard let text = try? String(contentsOfFile: manifest, encoding: .utf8) else { return nil }
        let pattern = #"%APPDATA%[\\/]+([^\\/\r\n]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let folder = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return folder.isEmpty ? nil : folder
    }

    /// Genera la configuración borderless nativa en el primer arranque y repara solo resoluciones
    /// incompatibles de una ventana maximizada. Una configuración válida elegida por el jugador se
    /// conserva: Vessel no vuelve a imponer sus valores después de preparar el motor.
    nonisolated static func repairedFrozenbyteDisplayOptions(
        existing: String?,
        screenSize: CGSize
    ) -> String? {
        let width = max(800, Int(screenSize.width.rounded(.down)))
        let height = max(600, Int(screenSize.height.rounded(.down)))
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [
                "setOption(renderingModule, \"ScreenWidth\", \(width))",
                "setOption(renderingModule, \"ScreenHeight\", \(height))",
                "setOption(renderingModule, \"Windowed\", true)",
                "setOption(renderingModule, \"MaximizeWindow\", true)",
                "setOption(renderingModule, \"WindowTitleBar\", false)"
            ].joined(separator: "\n") + "\n"
        }

        func optionValue(_ key: String) -> String? {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = #"(?mi)^\s*setOption\(\s*renderingModule\s*,\s*"#
                + "\"\(escaped)\""
                + #"\s*,\s*([^\)]+?)\s*\)\s*$"#
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                      in: existing,
                      range: NSRange(existing.startIndex..<existing.endIndex, in: existing)
                  ),
                  let range = Range(match.range(at: 1), in: existing) else { return nil }
            return existing[range].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let currentWidth = optionValue("ScreenWidth").flatMap(Int.init)
        let currentHeight = optionValue("ScreenHeight").flatMap(Int.init)
        let maximized = optionValue("MaximizeWindow")?.lowercased() == "true"
        let missingResolution = currentWidth == nil || currentHeight == nil
        let oversized = (currentWidth ?? 0) > width || (currentHeight ?? 0) > height
        let maximizedMismatch = maximized
            && (currentWidth != width || currentHeight != height)
        guard missingResolution || oversized || maximizedMismatch else { return nil }

        func setting(_ source: String, key: String, value: Int) -> String {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = #"(?mi)^\s*setOption\(\s*renderingModule\s*,\s*"#
                + "\"\(escaped)\""
                + #"\s*,\s*[^\)]+\)\s*$"#
            let replacement = "setOption(renderingModule, \"\(key)\", \(value))"
            guard let range = source.range(of: pattern, options: .regularExpression) else {
                return source + (source.hasSuffix("\n") ? "" : "\n") + replacement + "\n"
            }
            var result = source
            result.replaceSubrange(range, with: replacement)
            return result
        }

        return setting(
            setting(existing, key: "ScreenWidth", value: width),
            key: "ScreenHeight",
            value: height
        )
    }

    /// Prepara el viewport antes de que Steam cree el proceso. Si aún no hay opciones, usa el
    /// perfil Windows efectivo de wine-full (`crossover`); si existen, repara todos los perfiles
    /// que ya tengan ese juego sin tocar volumen, controles, idioma, partidas ni calidad gráfica.
    private func ensureFrozenbyteDisplaySettings(prefix: String, executable: String) {
        guard isFrozenbyteStorm3DD3D9Engine(executable),
              let folder = frozenbyteOptionsFolderName(forExecutable: executable) else { return }

        let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
        let screen = CGSize(width: mode?.width ?? 1512, height: mode?.height ?? 982)
        let fileManager = FileManager.default
        let usersDirectory = "\(prefix)/drive_c/users"
        let users = ((try? fileManager.contentsOfDirectory(atPath: usersDirectory)) ?? []).sorted()
        var paths = users.compactMap { user -> String? in
            let path = "\(usersDirectory)/\(user)/AppData/Roaming/\(folder)/options.txt"
            return fileManager.fileExists(atPath: path) ? path : nil
        }
        if paths.isEmpty {
            let preferred = users.contains("crossover") ? "crossover" : users.first
            guard let preferred else { return }
            paths = ["\(usersDirectory)/\(preferred)/AppData/Roaming/\(folder)/options.txt"]
        }

        for path in paths {
            let existing = try? String(contentsOfFile: path, encoding: .utf8)
            guard let repaired = Self.repairedFrozenbyteDisplayOptions(
                existing: existing,
                screenSize: screen
            ) else { continue }
            do {
                try fileManager.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try repaired.write(toFile: path, atomically: true, encoding: .utf8)
                log.log(
                    "Storm3D/Frozenbyte: viewport ajustado automáticamente a \(Int(screen.width))×\(Int(screen.height)).",
                    level: .info
                )
            } catch {
                log.log(
                    "No se pudo preparar el viewport de Storm3D: \(error.localizedDescription)",
                    level: .warn
                )
            }
        }
    }

    /// Motores D3D9 anteriores a HiDPI deben trabajar 1:1 en puntos. Esta política se consulta
    /// también en pruebas para impedir que el estado Retina de otro juego se filtre al siguiente.
    func usesLegacyD3D9NativeScaling(_ executable: String) -> Bool {
        isLegacyOgreD3D9Game(executable)
            || isLegacyANGLE1D3D9Game(executable)
            || isFrozenbyteStorm3DD3D9Engine(executable)
            || isNihonFalcomYsOriginD3D9Engine(executable)
            || isPlaydeadLegacyD3D9Engine(executable)
            || isClassicPopCapSteamEngine(executable)
            || isUnrealEngine1Game(executable)
    }

    /// El new-WoW64 no crea dispositivos D3D9 de 32 bits y ANGLE 1.x no consigue inicializar EGL
    /// sobre su ruta Vulkan ni siquiera en PE64. Ambos casos usan el wined3d del Wine completo;
    /// los D3D9 modernos de 64 bits conservan Gcenx.
    func usesFullCompatibilityEngineForD3D9(_ executable: String) -> Bool {
        isExecutable32Bit(executable) || isLegacyANGLE1D3D9Game(executable)
    }

    /// ANGLE 1 de 64 bits crea EGL con el Wine completo, pero su composición D3D9 se corrompe con
    /// wined3d. DXVK se limita a esta combinación estructural; ANGLE PE32 y D3D9 modernos mantienen
    /// intactas sus rutas ya validadas.
    func usesIsolatedDXVKForLegacyANGLE64(_ executable: String) -> Bool {
        !isExecutable32Bit(executable) && isLegacyANGLE1D3D9Game(executable)
    }

    /// Busca la variante PE32 oficial de un runtime ANGLE 1 PE64 cuando ambas arquitecturas vienen
    /// en carpetas hermanas del mismo juego (`bin64`/`bin`, `x64`/`x86`, etc.). El ANGLE heredado
    /// exige D3D9 y DXVK necesita geometría Vulkan, una capacidad que MoltenVK no puede ofrecer de
    /// forma válida; la build PE32, en cambio, usa el wined3d de CrossOver ya validado para esta
    /// familia. La selección es estructural y automática: misma firma de motor y mismo nombre base.
    func preferredLegacyANGLE1Executable(for executable: String) -> String? {
        guard usesIsolatedDXVKForLegacyANGLE64(executable) else { return nil }

        let fileManager = FileManager.default
        let executableURL = URL(fileURLWithPath: executable).standardizedFileURL
        let architectureDirectory = executableURL.deletingLastPathComponent()
        let gameRoot = architectureDirectory.deletingLastPathComponent()
        let expectedStem = Self.legacyANGLEArchitectureNeutralStem(executableURL)

        guard let rootContents = try? fileManager.contentsOfDirectory(
            at: gameRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidateDirectories = [gameRoot] + rootContents.filter { url in
            guard url.standardizedFileURL != architectureDirectory else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        let candidates = candidateDirectories.flatMap { directory -> [URL] in
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        .filter { $0.pathExtension.lowercased() == "exe" }
        .filter { Self.legacyANGLEArchitectureNeutralStem($0) == expectedStem }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        return candidates.first { candidate in
            isExecutable32Bit(candidate.path) && isLegacyANGLE1D3D9Game(candidate.path)
        }?.path
    }

    private nonisolated static func legacyANGLEArchitectureNeutralStem(_ url: URL) -> String {
        var stem = url.deletingPathExtension().lastPathComponent.lowercased()
        for suffix in ["_x64", "-x64", "_x86", "-x86", "_64", "-64", "_32", "-32"]
        where stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            break
        }
        return stem
    }

    /// Motor gráfico REAL que usará `launch()` para este ejecutable + override. Se usa para
    /// pasar la capa correcta al **fallback automático**: si se pasara `.auto`, la cadena
    /// `nextLayer` supondría que se arrancó en DXMT y saltaría motores (p. ej. un juego
    /// `.other` arranca en Gcenx pero el fallback probaría gptk→gcenx, sin tocar DXMT).
    /// DEBE reflejar EXACTAMENTE el enrutado de `launch()`. Juegos de 32-bit (CrossOver) y
    /// D3D9 se reportan como `.gcenx`: launch() los re-fuerza a su motor pase lo que pase,
    /// así que el valor solo sirve para arrancar el ciclo de fallback.
    private func effectiveGraphicsOverride(
        forExecutable executable: String,
        effective eff: EffectiveLaunchConfig
    ) -> GameConfig.GraphicsLayer {
        if eff.graphicsOverrideWasLearned,
           eff.graphicsOverride != .auto,
           isNativeVulkanGame(executable) {
            return .auto
        }
        return eff.graphicsOverride
    }

    func resolvedGraphicsLayer(forExecutable executable: String, effective eff: EffectiveLaunchConfig = EffectiveLaunchConfig()) -> GameConfig.GraphicsLayer {
        // Chromium necesita el swapchain de DXMT en el mismo proceso; otras rutas producen una
        // ventana negra aunque el proceso sobreviva. Es una restricción del motor, no una preferencia.
        if isNWJSGame(executable) { return .dxmt }
        // El enum aún no tiene una categoría «Wine completo»; `.gcenx` representa aquí la familia
        // wined3d/compatibilidad y evita que el diagnóstico crea que se lanzó por DXMT.
        if isLegacyMoaiOpenGLGame(executable) { return .gcenx }
        if isRTsoftProtonOpenGLEngine(executable) { return .gcenx }
        if isClassicVirtoolsDirectDrawEngine(executable) { return .gcenx }
        let go = effectiveGraphicsOverride(forExecutable: executable, effective: eff)
        if go == .auto, isNativeVulkanGame(executable) { return .gcenx }
        if go == .gcenx { return .gcenx }
        let api = detectGraphicsAPI(forExecutable: executable)
        if go == .gptk || (go == .auto && api == .d3d12) { return .gptk }
        if isUnity6OrNewer(executable) { return .gptk }
        if api == .d3d9 { return .gcenx }
        if api == .opengl { return .dxmt }                   // motor unificado OpenGL, también en PE32
        if isExecutable32Bit(executable) { return .gcenx }   // CrossOver; launch() lo re-fuerza
        if go == .dxmt { return .dxmt }
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
        if isNWJSGame(executable) { return [.dxmt] }
        // Moai/AKUSDL no tiene «capas Direct3D» que probar: el adaptador Wine completo es su ruta.
        if isLegacyMoaiOpenGLGame(executable) { return [] }
        // El Proton SDK de RTsoft usa OpenGL nativo de Wine y necesita su modo ventana automático;
        // rotar traductores Direct3D no puede reparar ese arranque determinista.
        if isRTsoftProtonOpenGLEngine(executable) { return [] }
        // Virtools DX7 depende de un modo exclusivo emulado y de su rasterizador local. Cambiar de
        // traductor no crea ese modo y solo reiniciaría un juego que ya tiene una ruta determinista.
        if isClassicVirtoolsDirectDrawEngine(executable) { return [] }
        let graphicsOverride = effectiveGraphicsOverride(forExecutable: executable, effective: eff)
        if graphicsOverride == .auto, isNativeVulkanGame(executable) { return [.gcenx] }
        switch graphicsOverride {
        case .gptk:  return [.gptk]
        case .dxmt:  return [.dxmt]
        case .gcenx: return [.gcenx]
        case .auto:  break
        }
        // Juegos .NET Core self-contained: DXMT sobre el motor UNIFICADO (WineHQ 11.10) ejecuta el
        // runtime .NET 8 Y da D3D11→Metal (validado: Romestead renderiza). Gcenx de respaldo (corre
        // .NET pero sin D3D11 en el M5). NUNCA gptk (Wine 9.0, viejo, rompe el loader de .NET 8).
        if isDotNetCoreGame(executable) { return [.dxmt, .gcenx] }
        // **Envoltorios retro (DOSBox/ScummVM): SIN fallback.** No tienen capa gráfica que probar —
        // son SDL, no tocan Direct3D. Reintentar con "otra capa" no cambia nada y encima hace daño:
        // cada reintento MATA el proceso anterior, y estos tardan ~12 s en aparecer (Rosetta + Wine
        // + el emulador). El reintento llegaba antes → el juego moría 4 s después de haber arrancado
        // bien, y el usuario veía "no llegó a arrancar" de un juego que SÍ arrancaba.
        if isRetroWrapper(executable) { return [] }
        let api = detectGraphicsAPI(forExecutable: executable)
        // OpenGL puro usa el motor unificado con winemac.so parcheado también en ejecutables PE32.
        // Debe resolverse ANTES de la regla general de 32 bits (Dead Cells ofrece `*_gl.exe`).
        if api == .opengl { return [.dxmt] }
        // Juegos 32-bit restantes: SIEMPRE van a CrossOver/gptk (launch32BitGame ignora la capa) y
        // `resolvedGraphicsLayer` devuelve `.gcenx` fijo → una lista de UN elemento evita el BUCLE de
        // reintentos (la capa nunca cambia, así que ciclar es inútil). Si falla, el auto-repair pasa a
        // Steam-real (juegos como CaveBlazers) o avisa; no gira en vano.
        if isExecutable32Bit(executable) { return [.gcenx] }
        switch api {
        case .d3d12: return [.gptk]
        case .d3d9:  return [.gcenx]
        case .other: return [.gcenx, .dxmt]
        case .opengl: return [.dxmt]   // ya devuelto arriba; mantiene el switch exhaustivo
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

    /// DLLs que el PE importa de verdad, incluidas las importaciones retardadas.
    ///
    /// Antes se buscaba el nombre de la DLL como texto libre en todo el binario. Eso confundía
    /// mensajes, listas de renderizadores opcionales y rutas de configuración con imports reales:
    /// Broken Age, por ejemplo, contiene el texto `D3D9.DLL` pero su tabla PE solo importa OpenGL.
    /// El falso positivo lo enviaba al adaptador D3D9 aunque el motor fuese Moai/OpenGL.
    ///
    /// La lectura estructural vive en `PEImportScanner`; las detecciones explícitamente dinámicas
    /// continúan usando `exeContains` en su propia regla.
    func peImportedLibraries(forExecutable executable: String) -> Set<String> {
        PEImportScanner.importedLibraries(atPath: executable)
    }

    /// ¿El PE importa alguna de estas DLL? Solo consulta Import/Delay Import; nunca texto libre.
    private func exeImports(_ executable: String, anyOf names: [String]) -> Bool {
        let imports = peImportedLibraries(forExecutable: executable)
        return names.contains { imports.contains($0.lowercased()) }
    }

    /// Algunos juegos Steamworks arrancan sin DRM mediante una API sustitutiva, pero sus funciones
    /// multijugador no pueden funcionar sin el cliente real: red P2P y lobbies dependen del IPC
    /// vivo de Steam. No se exige la API de servidor dedicado: muchos juegos cooperativos son P2P
    /// puros y no la enlazan. Import real de Steamworks + networking + matchmaking sigue siendo una
    /// evidencia fuerte y no convierte juegos que solo usan logros o estadísticas en Steam real.
    func requiresRealSteamNetworking(_ executable: String) -> Bool {
        guard exeImports(executable, anyOf: ["steam_api.dll", "steam_api64.dll"]) else {
            return false
        }
        let hasNetworking = exeContains(
            executable,
            anyOf: ["SteamNetworking006", "SteamNetworkingSockets"]
        )
        let hasMatchmaking = exeContains(
            executable,
            anyOf: ["SteamMatchMaking009", "SteamMatchmakingServers"]
        )
        return hasNetworking && hasMatchmaking
    }

    @discardableResult
    func launch(executable: String, in bottle: Bottle, arguments: [String] = [], steamAppId: String? = nil, graphicsOverride: GameConfig.GraphicsLayer? = nil, effective: EffectiveLaunchConfig? = nil) async throws -> Process {
        if let officialExecutable = preferredLegacyHPL3Executable(for: executable) {
            log.log(
                "HPL3 autodetectado: usando el ejecutable oficial sin Steamworks para evitar el diálogo de inicialización fallida.",
                level: .info
            )
            return try await launch(
                executable: officialExecutable,
                in: bottle,
                arguments: arguments,
                steamAppId: steamAppId,
                graphicsOverride: graphicsOverride,
                effective: effective
            )
        }
        if let compatibleExecutable = preferredLegacyANGLE1Executable(for: executable) {
            dxvkManager.removeGameLocalD3D9(forExecutable: executable)
            log.log(
                "ANGLE 1 PE64 autodetectado: usando la variante PE32 oficial compatible con D3D9/wined3d.",
                level: .info
            )
            return try await launch(
                executable: compatibleExecutable,
                in: bottle,
                arguments: arguments,
                steamAppId: steamAppId,
                graphicsOverride: graphicsOverride,
                effective: effective
            )
        }
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
        let nwjs = isNWJSGame(executable)
        if nwjs {
            // DXMT no puede presentar el swapchain de Chromium desde su proceso GPU separado
            // (`cross-process swapchain → headless mode`). Ejecutar la GPU dentro del proceso crea
            // una vista Metal real. ANGLE necesita además el compilador HLSL nativo de Microsoft.
            eff.graphicsOverride = .dxmt
            eff.dllOverrides["d3dcompiler_47"] = "n,b"
        }
        let normalizedGraphicsOverride = effectiveGraphicsOverride(
            forExecutable: executable,
            effective: eff
        )
        if normalizedGraphicsOverride != eff.graphicsOverride {
            log.log(
                "Override aprendido incompatible ignorado: el ejecutable usa Vulkan nativo y vuelve al motor completo.",
                level: .info
            )
            eff.graphicsOverride = normalizedGraphicsOverride
            eff.graphicsOverrideWasLearned = false
        }
        let go = eff.graphicsOverride
        // Orden efectiva ÚNICA: parámetros solicitados + perfil + adaptador automático del motor.
        // Se reutiliza sin pérdidas tanto en el modo Vessel como al necesitar Steam real.
        var allArgs = resolvedLaunchArguments(
            forExecutable: executable,
            requested: arguments,
            effective: eff
        )
        // AGS 3.6/SDL2 distribuye todavía D3D9 como valor por defecto. En wine-full renderiza, pero
        // mantiene wined3d consumiendo ~42–47 % de CPU; el OpenGL nativo del mismo runtime conserva
        // ventana, escala e imagen con ~13–15 %. La firma exige motor + import + datos + config y la
        // reparación solo cambia ese backend, con copia recuperable antes del primer cambio.
        let agsRepair = AdventureGameStudioCompatibility.repairBeforeLaunch(
            executable: executable
        )
        if agsRepair.didRepair {
            log.log(
                "Adventure Game Studio moderno autodetectado: backend D3D9 sustituido por OpenGL; copia de seguridad conservada.",
                level: .info
            )
        }
        // Estado del propio juego restaurado por nube/backup: corrige únicamente combinaciones
        // verificadas que bajo Retina crean una ventana desbordada y desalinean el ratón. Se hace
        // aquí, DESPUÉS de cualquier restauración previa y ANTES de decidir la ruta de motor; no
        // cambia Wine, DXMT ni las preferencias válidas de otros juegos.
        let displayRepair = GameDisplayStateRepair.repairBeforeLaunch(
            appId: steamAppId,
            executable: executable,
            prefix: bottle.prefixPath,
            isFourAEnhanced: isFourAEnhancedD3D12Engine(executable)
        )
        if displayRepair.didRepair {
            log.log(
                "Estado de pantalla autorreparado antes de jugar (\(displayRepair.repairedFiles.count) perfil(es)); copia de seguridad conservada.",
                level: .info
            )
        }
        let proprietaryRepair = ProprietaryEngineRepair.repairBeforeLaunch(
            appId: steamAppId,
            executable: executable
        )
        if proprietaryRepair.didRepair {
            log.log(
                "Motor propietario autodetectado: MSAA no compatible normalizado antes de crear D3D11; copia de seguridad conservada.",
                level: .info
            )
        }
        try await ensureUnrealEngine1DisplaySettings(executable: executable)
        // Motor KEX (remasters de Nightdive: DOOM, Quake…): fijar la resolución a los píxeles reales,
        // o abre al doble de la pantalla (ver `fixKexResolution`). Se escribe en su cfg Y se pasa por
        // línea de comandos, para que valga también en el PRIMER arranque, cuando el cfg aún no existe.
        if isKexEngineGame(executable) {
            fixKexResolution(prefix: bottle.prefixPath)
            let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
            allArgs += ["+v_width", "\(mode?.pixelWidth ?? 3024)", "+v_height", "\(mode?.pixelHeight ?? 1964)"]
        }
        // HPL3 necesita un perfil OpenGL core con adaptadores de compatibilidad y Retina 1×.
        // Se resuelve antes de Steam/Goldberg: el ejecutable oficial sin Steamworks ya fue elegido
        // arriba y no debe modificar ni depender del cliente Steam del prefijo compartido.
        if isLegacyHPL3OpenGLEngine(executable) {
            return try await launchLegacyHPL3OpenGLGame(
                executable: executable,
                in: bottle,
                arguments: allArgs,
                steamAppId: steamAppId,
                effective: eff
            )
        }
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
        // SteamStub/CEG vive dentro del propio ejecutable y se ejecuta ANTES que la API gráfica.
        // Sustituir `steam_api64.dll` por Goldberg no puede satisfacerlo: el stub intenta cargar el
        // `steamclient` oficial y relanza `steam://run/<appid>`. El detector PE exige evidencia fuerte
        // (`.bind` + entry point dentro de la sección, o magic C0DEC0DE), por lo que esta decisión es
        // automática y no convierte simples juegos Steamworks en modo Steam real. Cube World usa
        // precisamente esta variante y, sin esta ruta, nunca llega a `D3D11CreateDevice`.
        let steamStubRequiresRealClient = SteamDRMScanner.hasSteamStub(executable)
        let legacyValveRunMeRequiresRealClient =
            SteamDRMScanner.hasLegacyValveRunMeBootstrap(executable)
        let steamNetworkingRequiresRealClient = requiresRealSteamNetworking(executable)
        let classicPopCapRequiresRealClient = isClassicPopCapSteamEngine(executable)
        let protectedSteamAppLaunch = requiresSteamAppLaunch(executable)
        let protectedDirectLaunch = usesProtectedDirectLaunchWithConnectedSteam(executable)
        let protectedByThirdParty = officialSteamClientProtection(executable)
        let officialSteamAppLaunchRequired = Self.requiresOfficialSteamAppLaunch(
            builtInProtection: protectedSteamAppLaunch,
            thirdPartyProtection: protectedByThirdParty,
            directLaunchException: protectedDirectLaunch
        )
        let steamShimBootstrapper = steamShimBootstrapper(forPayload: executable)
        // Los juegos protegidos se delegan a Steam, que ejecuta sus `installscript.vdf` antes del
        // juego. Algunos redistribuibles antiguos (sobre todo PhysX) abren asistentes interactivos
        // aunque el flujo se haya iniciado desde Vessel. Preparar por evidencia los runtimes antes
        // de abrir Steam convierte el primer arranque en un proceso completamente desatendido y,
        // además, deja satisfechas las claves de detección que usa el propio installscript.
        if steamStubRequiresRealClient, !protectedDirectLaunch {
            _ = RuntimeDependencyProvisioner.provision(
                executable: executable,
                includeNestedFiles: false
            )
            let runtimePlan = RuntimeDependencyProvisioner.protectedSteamPreflightPlan(
                executable: executable
            )
            if !runtimePlan.winetricksVerbs.isEmpty {
                guard let fullWine = await fullEngineWineEnsured() else {
                    throw WineError.installationFailed("no se pudo preparar el motor para instalar los runtimes del juego protegido")
                }
                await dependencyManager.repairFullEngineShim()
                log.log(
                    "SteamStub/CEG: preparando runtimes automáticamente antes de abrir Steam: \(runtimePlan.winetricksVerbs.joined(separator: ", ")).",
                    level: .info
                )
                guard await applyWinetricksVerbs(
                    runtimePlan.winetricksVerbs,
                    prefix: bottle.prefixPath,
                    wine: fullWine,
                    exclusivePrefixPreparation: true
                ) else {
                    throw WineError.installationFailed("no se pudieron instalar los runtimes requeridos por el juego protegido")
                }
            }
        }
        if (eff.useRealSteam || steamRealGlobal || protectedSteamAppLaunch
                || protectedByThirdParty != nil
                || steamNetworkingRequiresRealClient),
           let appId = steamAppId, !appId.isEmpty {
            let reason: String
            if steamStubRequiresRealClient {
                reason = " [SteamStub/CEG autodetectado]"
            } else if legacyValveRunMeRequiresRealClient {
                reason = " [lanzador heredado de Valve autodetectado]"
            } else if classicPopCapRequiresRealClient {
                reason = " [API Steam heredada de PopCap autodetectada]"
            } else if let protectedByThirdParty {
                reason = " [\(protectedByThirdParty.label) autodetectado]"
            } else if steamNetworkingRequiresRealClient {
                reason = " [red, lobbies y servidores Steam autodetectados]"
            } else if steamRealGlobal && !eff.useRealSteam {
                reason = " [global]"
            } else {
                reason = ""
            }
            log.log("Modo Steam real para este juego (cliente Steam conectado: nube/updates/DLC/logros nativos)\(reason).", level: .info)
            return try await launchViaRealSteam(
                executable: steamShimBootstrapper ?? executable,
                in: bottle,
                appId: appId,
                launchArguments: allArgs,
                effective: eff,
                steamAppLaunchRequired: officialSteamAppLaunchRequired
                    || steamShimBootstrapper != nil
            )
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
        // SteamShim no es un launcher opcional: inicializa Steamworks y entrega al proceso del juego
        // los handles IPC `STEAMSHIM_*`. Ejecutar el payload directamente produce «Could not
        // initialize Steamworks API» aunque Goldberg esté correctamente instalado. Se detecta por
        // firma + import real y se usa automáticamente; el tracker conserva como familia el payload.
        if let steamShimBootstrapper {
            log.log("SteamShim autodetectado: iniciando el bootstrapper requerido por el motor.", level: .info)
            return try await launch(
                executable: steamShimBootstrapper,
                in: bottle,
                arguments: arguments,
                steamAppId: steamAppId,
                effective: eff
            )
        }
        // ⭐ **Envoltorios retro (DOSBox/ScummVM): ANTES que cualquier override de capa gráfica.**
        // Estos no son juegos de Direct3D — son emuladores SDL —, así que "forzar Gcenx/DXMT/GPTK"
        // no significa nada para ellos y solo hace daño: bastaba con que un intento anterior hubiera
        // dejado `graphicsLayer = .gcenx` en su config (lo persiste el propio fallback) para que
        // cayeran en la ruta D3D9→wined3d, que es justo la que hay que evitar. Aquí manda lo que ES
        // el binario, por encima de lo que diga la config.
        if isRetroWrapper(executable) {
            // **Juegos de DOS → DOSBox NATIVO**, saltándose Wine entero: el DOSBox de Windows que
            // trae GOG es SDL 1.2 y aquí no crea ventana ni con una salida de vídeo. El juego es de
            // DOS; no necesita Windows. ScummVM sí va por Wine (SDL2, y renderiza bien).
            if isDOSBoxWrapper(executable), let root = retroGameRoot(forExecutable: executable) {
                return try await launchNativeDOSBox(executable: executable, arguments: allArgs,
                                                    gameRoot: root, appId: retroAppId(root) ?? "game")
            }
            return try await launchRetroWrapper(executable: executable, in: bottle,
                                                arguments: allArgs, effective: eff)
        }
        // **Virtools clásico / DirectX 7**: el rasterizador se carga desde una DLL y el exe no
        // revela DirectDraw en sus imports. Necesita su modo exclusivo 800×600 emulado, escala 1×
        // y vídeo de 32 bits; se resuelve antes de la regla DirectDraw genérica de 640×480×8.
        if isClassicVirtoolsDirectDrawEngine(executable),
           let fullEngineWine = await fullEngineWineEnsured() {
            return try await launchClassicVirtoolsDirectDrawGame(
                executable: executable,
                in: bottle,
                arguments: allArgs,
                effective: eff,
                wine: fullEngineWine
            )
        }
        // **DirectDraw de la era VGA (256 colores)**: escritorio virtual + Wine de CrossOver. Va
        // aquí, antes de la detección de API, porque estos juegos no son "D3D9" ni nada moderno:
        // piden modos de pantalla paletizados que macOS ya no tiene. Verificado con War Wind (1996).
        // `fullEngineWineEnsured()` es perezoso: solo descarga el motor si el juego entra en la ruta.
        if isLegacyDirectDrawGame(executable), let fullEngineWine = await fullEngineWineEnsured() {
            return try await launchLegacyDirectDrawGame(executable: executable, in: bottle,
                                                        arguments: allArgs, effective: eff,
                                                        wine: fullEngineWine)
        }
        // **Source (Valve)**: hay que decirle qué mod cargar y sacarlo de MoltenVK.
        if let mod = sourceModDirectory(forExecutable: executable),
           let fullEngineWine = await fullEngineWineEnsured() {
            log.log("Juego de Source: cargando «\(mod)» con OpenGL (MoltenVK no compila sus shaders).", level: .info)
            let exeName = (executable as NSString).lastPathComponent
            // `renderer=gl` SOLO para este `.exe` (AppDefaults), no para todo el prefijo: con Vulkan,
            // MoltenVK se atraganta con uno de sus shaders internos (`no template named
            // 'textureunsupported'`) y la ventana se queda NEGRA. Los demás juegos del prefijo siguen
            // con Vulkan, que es lo que les va bien. Verificado con Portal.
            await setWined3dRenderer(prefix: bottle.prefixPath, wine: fullEngineWine,
                                     renderer: "gl", forExecutable: exeName)
            cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
            try? await terminateWineProcesses(winePath: fullEngineWine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: fullEngineWine)
            await resyncGamePrefix(gameWine: fullEngineWine, prefix: bottle.prefixPath)
            var env = ["WINEPREFIX": bottle.prefixPath, "WINEDEBUG": "-all",
                       "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
                       "WINEMSYNC": "1", "WINEESYNC": "1"]
            if let appId = steamAppId, !appId.isEmpty { env["SteamAppId"] = appId; env["SteamGameId"] = appId }
            // `-fullscreen` + resolución de la pantalla, explícitos. Source se GUARDA en su `cfg`
            // cómo se jugó la última vez, así que sin esto vuelve a abrirse en la ventanita de 640×400
            // que dejó una sesión anterior, por mucho que la pantalla sea otra.
            // En PÍXELES, no en puntos: Wine le da al juego una pantalla medida en píxeles Retina, así
            // que pedirle los puntos (1512×982) le sale una ventana a mitad de tamaño (756×491).
            let modo = CGDisplayCopyDisplayMode(CGMainDisplayID())
            let ancho = modo?.pixelWidth ?? 3024, alto = modo?.pixelHeight ?? 1964
            return try await launchWineProcess(
                winePath: fullEngineWine,
                prefix: bottle.prefixPath,
                arguments: [executable, "-game", mod, "-fullscreen",
                            "-w", "\(ancho)", "-h", "\(alto)"] + allArgs,
                environment: env,
                workingDirectory: gameWorkingDirectory(forExecutable: executable),
                effective: eff
            )
        }
        // **Vulkan nativo**: el juego habla directamente con `vulkan-1.dll`, por lo que no debe
        // entrar en el motor unificado de DXMT (esa build no incluye winevulkan). El Wine completo
        // aporta winevulkan + MoltenVK y conserva el lanzamiento sin flags ni configuración manual.
        // La detección también cubre el import transitivo desde `Engine*.dll` (Hades x64Vk).
        if go == .auto, isNativeVulkanGame(executable),
           let fullEngineWine = await fullEngineWineEnsured() {
            log.log("Juego Vulkan nativo detectado: MoltenVK→Metal con el motor completo.", level: .info)
            cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
            try? await terminateWineProcesses(winePath: fullEngineWine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: fullEngineWine)
            await resyncGamePrefix(gameWine: fullEngineWine, prefix: bottle.prefixPath)
            await setMacDriverRetinaMode(
                prefix: bottle.prefixPath,
                wine: fullEngineWine,
                enabled: eff.retina
            )
            var env = [
                "WINEPREFIX": bottle.prefixPath,
                "WINEDEBUG": "-all",
                "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
                "WINEMSYNC": "1",
                "WINEESYNC": "1",
                "WINEFSYNC": "1",
                "MVK_CONFIG_LOG_LEVEL": "0"
            ]
            if let appId = steamAppId, !appId.isEmpty {
                env["SteamAppId"] = appId
                env["SteamGameId"] = appId
            }
            do {
                let moltenVK = try await moltenVKManager.ensureLibrary()
                env = Self.modernMoltenVKEnvironment(
                    from: env,
                    libraryDirectory: moltenVK,
                    useMetalArgumentBuffers: true
                )
                // Solo errores: si el juego solicita una feature que Metal no puede representar,
                // el diagnóstico conserva el nombre concreto sin inundar el log normal.
                env["MVK_CONFIG_LOG_LEVEL"] = "1"
                log.log(
                    "Vulkan nativo: MoltenVK \(MoltenVKManager.pinnedVersion) aislado y autogestionado.",
                    level: .info
                )
            } catch {
                log.log(
                    "No se pudo preparar MoltenVK moderno; se conserva el runtime incluido: \(error.localizedDescription)",
                    level: .warn
                )
            }
            return try await launchWineProcess(
                winePath: fullEngineWine,
                prefix: bottle.prefixPath,
                arguments: [executable] + allArgs,
                environment: env,
                workingDirectory: gameWorkingDirectory(forExecutable: executable),
                effective: eff
            )
        }
        // **Godot con Vulkan**: se le dice explícitamente que use Vulkan y va por el Wine completo.
        // Sin esto acaba clasificado por descarte (su PE no declara `vulkan-1.dll`, la carga en
        // runtime), arranca —su log escribe "Godot Engine v4.3"— y NO abre ventana jamás.
        // Verificado con Halls of Torment; Cassette Beasts (Godot solo-OpenGL) no entra aquí.
        if isGodotVulkanGame(executable), let fullEngineWine = await fullEngineWineEnsured() {
            log.log("Juego Godot: render por Vulkan (MoltenVK→Metal) con el Wine completo.", level: .info)
            cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
            try? await terminateWineProcesses(winePath: fullEngineWine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: fullEngineWine)
            await resyncGamePrefix(gameWine: fullEngineWine, prefix: bottle.prefixPath)
            return try await launchWineProcess(
                winePath: fullEngineWine,
                prefix: bottle.prefixPath,
                arguments: [executable] + allArgs + ["--rendering-driver", "vulkan"],
                environment: ["WINEPREFIX": bottle.prefixPath, "WINEDEBUG": "-all",
                              "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
                              "WINEMSYNC": "1", "WINEESYNC": "1"],
                workingDirectory: gameWorkingDirectory(forExecutable: executable),
                effective: eff
            )
        }
        // **FNA/XNA**: lo que les falla no es la capa gráfica sino el RUNTIME — quieren el .NET
        // Framework de verdad, no wine-mono. Por eso va antes de detectar la API: con mono se
        // quedan en negro por muchas capas que se prueben. Verificado con FEZ.
        if isFNAOrXNAGame(executable), let fullEngineWine = await fullEngineWineEnsured() {
            return try await launchFNAGameWithCrossOver(executable: executable, in: bottle,
                                                        arguments: allArgs, effective: eff,
                                                        wine: fullEngineWine)
        }
        // **Unreal Engine 4** (D3D11, sin d3d12): no arranca ni por DXMT ni por GPTK — solo con el
        // Wine completo. Va aquí, antes de la detección de API, porque el problema no es la capa
        // gráfica sino el motor. Solo cuando el usuario no ha forzado una capa a mano. Verificado
        // con ASTRONEER. (UE5 con d3d12 —Palworld— NO entra aquí: sigue por GPTK/D3DMetal.)
        if go == .auto, isUnrealEngine4Game(executable),
           let fullEngineWine = await fullEngineWineEnsured() {
            return try await launchUnreal4WithCrossOver(executable: executable, in: bottle,
                                                        arguments: allArgs, steamAppId: steamAppId,
                                                        effective: eff, wine: fullEngineWine)
        }
        // **Java con JVM embebida**: usa el Wine completo. Los motores modernos (p. ej. Wurm)
        // pueden renderizar por Vulkan/LWJGL y necesitan su MoltenVK reciente; libGDX 1.x usa
        // OpenGL/LWJGL 2. Ambos quedan aislados de las capas Direct3D.
        if go == .auto, isJavaGame(executable),
           let fullEngineWine = await fullEngineWineEnsured() {
            let legacyLibGDX = goldbergManager.hasLegacyLibGDXOpenGL(gameExecutable: executable)
            log.log(
                legacyLibGDX
                    ? "Juego Java/libGDX detectado: OpenGL/LWJGL con el Wine completo y escala nativa."
                    : "Juego Java detectado: runtime JVM/LWJGL con el Wine completo.",
                level: .info
            )
            cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
            try? await terminateWineProcesses(winePath: fullEngineWine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: fullEngineWine)
            await resyncGamePrefix(gameWine: fullEngineWine, prefix: bottle.prefixPath)
            // LWJGL 2 no es DPI-aware: con Retina activo una resolución de 1280×720 ocupa solo
            // 640×360 puntos y puede desalinear entrada/ventana. Se desactiva únicamente para esta
            // familia; los Java modernos conservan la preferencia Retina del perfil.
            await setMacDriverRetinaMode(
                prefix: bottle.prefixPath,
                wine: fullEngineWine,
                enabled: legacyLibGDX ? false : eff.retina
            )
            var env = ["WINEPREFIX": bottle.prefixPath, "WINEDEBUG": "-all",
                       "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
                       "WINEMSYNC": "1", "WINEESYNC": "1"]
            if let appId = steamAppId, !appId.isEmpty { env["SteamAppId"] = appId; env["SteamGameId"] = appId }
            return try await launchWineProcess(
                winePath: fullEngineWine,
                prefix: bottle.prefixPath,
                arguments: [executable] + allArgs,
                environment: env,
                workingDirectory: gameWorkingDirectory(forExecutable: executable),
                effective: eff
            )
        }
        // **Proton SDK de RTsoft (no Valve Proton)**: el fullscreen inicial fijo de estas builds
        // falla antes de poder guardar preferencias y el motor OpenGL unificado no expone las
        // extensiones que esperan. La firma estructural estricta activa `wine-full`, escala nativa
        // y modo ventana automáticamente, sin ajustes ni parámetros manuales del usuario.
        if isRTsoftProtonOpenGLEngine(executable),
           let fullEngineWine = await fullEngineWineEnsured() {
            return try await launchRTsoftProtonOpenGLGame(
                executable: executable,
                in: bottle,
                arguments: allArgs,
                steamAppId: steamAppId,
                effective: eff,
                wine: fullEngineWine
            )
        }
        // **Moai/AKUSDL PE32**: OpenGL de compatibilidad con el Wine completo. Va antes de cualquier
        // override gráfico porque DXMT/GPTK/Gcenx son capas Direct3D y no describen este motor.
        // La regla se basa en firma de motor + import OpenGL real, nunca en el título.
        if isLegacyMoaiOpenGLGame(executable),
           let fullEngineWine = await fullEngineWineEnsured() {
            return try await launchLegacyMoaiOpenGLGame(
                executable: executable,
                in: bottle,
                arguments: allArgs,
                steamAppId: steamAppId,
                effective: eff,
                wine: fullEngineWine
            )
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
        let graphicsAPI = detectGraphicsAPI(forExecutable: executable)
        let useD3D12: Bool
        switch go {
        case .gptk: useD3D12 = true                                  // forzado por usuario/perfil
        case .dxmt: useD3D12 = false                                 // forzado a DXMT
        case .gcenx: useD3D12 = false                                // (ya gestionado arriba)
        case .auto: useD3D12 = graphicsAPI == .d3d12
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
            return try await launchD3D12Game(
                executable: executable,
                in: bottle,
                arguments: allArgs,
                steamAppId: steamAppId,
                effective: eff,
                forceGPTK: true
            )
        }
        // Juegos D3D9/D3D8/DDraw → Gcenx (wine-osx64, Wine 11 completo, wined3d→Metal).
        // wine-dxmt no resuelve el d3d9 (falla con c0000135 "d3d9.dll not found"); Gcenx sí.
        // Se aplica SIEMPRE que la API sea D3D9 — también si un perfil/usuario forzó `.dxmt`:
        // forzar wine-dxmt aquí rompería el juego, así que el override `.dxmt` solo decide el
        // motor de los D3D11 (`.gptk` ya salió arriba por la rama D3D12).
        if graphicsAPI == .d3d9 {
            if go == .dxmt { log.log("Override DXMT ignorado en juego D3D9: se usa Gcenx (wined3d→Vulkan), que es lo que funciona.", level: .info) }
            return try await launchD3D9Game(executable: executable, in: bottle,
                                            arguments: allArgs, steamAppId: steamAppId, effective: eff)
        }
        // Juegos de 32-bit que NO son D3D9 ni OpenGL (típicamente Unity D3D11): el new-WoW64 de
        // Gcenx/wine-dxmt CRASHEA su runtime (p.ej. el Mono de Unity → "Crash!!!" nada más
        // arrancar). El Wine de CrossOver (gptk-mythic) sí los ejecuta; Unity cae a su
        // OpenGL (Apple GLD→Metal) con render monohilo (ver `launch32BitGame`).
        // Validado con "A Short Hike" (Unity 2019.4, 32-bit). Se aplica también con override
        // `.dxmt` (forzar wine-dxmt en 32-bit crashea Mono igualmente).
        // Los PE32 OpenGL explícitos (p. ej. `deadcells_gl.exe`) continúan hasta la ruta genérica
        // del motor unificado; enviarlos a CrossOver reproduce el fallo de contexto GL 3.2.
        if isExecutable32Bit(executable), graphicsAPI != .opengl {
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
        if go == .auto && graphicsAPI == .other {
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
            return try await launchD3D12Game(
                executable: executable,
                in: bottle,
                arguments: allArgs,
                steamAppId: steamAppId,
                effective: eff,
                forceGPTK: true
            )
        }
        // OpenGL necesita primero la base unificada y después su clon con winemac.so parcheado.
        // Se hace antes de resolver el binario para que una instalación nueva no caiga por error al
        // motor normal. No se copian DLL de DXMT junto a un juego OpenGL puro.
        if graphicsAPI == .opengl {
            try? await dependencyManager.ensureUnifiedEngine { msg, pct in
                Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
            }
            await dependencyManager.ensureUnifiedOpenGLEngine { msg, pct in
                Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
            }
        }
        // D3D11 → wine-dxmt (DXMT→Metal). Aseguramos DXMT en el builtin del motor; si
        // no, los juegos usarían wined3d y fallarían con "InitializeEngineGraphics".
        let gameWine = resolveGameWine(for: bottle, executable: executable)
        if nwjs {
            let compiler = "\(bottle.prefixPath)/drive_c/windows/system32/d3dcompiler_47.dll"
            if !FileManager.default.fileExists(atPath: compiler) {
                log.log("NW.js/Chromium: instalando D3DCompiler 47 para ANGLE…", level: .info)
                let installed = await applyWinetricksVerbs(
                    ["d3dcompiler_47"],
                    prefix: bottle.prefixPath,
                    wine: gameWine,
                    force: true
                )
                guard installed, FileManager.default.fileExists(atPath: compiler) else {
                    throw WineError.installationFailed("no se pudo preparar D3DCompiler 47 para Chromium")
                }
            }
        }
        if graphicsAPI != .opengl {
            try await ensureGameEngineDXMT(gameWine: gameWine)
        }
        // GARANTÍA de carga de DXMT: copiar las DLLs de DXMT JUNTO al ejecutable.
        // Wine busca DLLs primero en la carpeta del exe; el builtin del motor NO se
        // resuelve de forma fiable desde el contexto de la app (Wine da c0000135
        // "DLL not found" al no encontrar d3d11). Con las DLLs junto al exe, siempre
        // cargan.
        if graphicsAPI != .opengl {
            ensureGameDXMTDLLs(gameExecutable: executable, gameWine: gameWine)
        }
        // Dependencias de runtime: detecta lo que el juego importa y provisiona los DirectX helper
        // que empaquetamos (d3dx9/d3dcompiler, cuyo builtin de Wine es incompleto). El resto
        // (Visual C++, .NET, XInput) lo cubre el builtin del motor; se registra para el diagnóstico.
        let runtimeDependencies = RuntimeDependencyProvisioner.provision(executable: executable)
        // Cerrar procesos previos (el cliente Steam corre en Gcenx y deja el prefix
        // en su versión; hay que liberarlo antes de re-sincronizar a wine-dxmt).
        log.log("Preparando prefijo para el juego…", level: .info)
        try? await terminateWineProcesses(winePath: gameWine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: gameWine)
        // Re-sincronizar el prefix al motor de juegos. Imprescindible: tras lanzar
        // el cliente Steam (Gcenx) el prefix queda desincronizado y DXMT no carga
        // (el juego falla con InitializeEngineGraphics). `wineboot -u` lo restaura.
        await resyncGamePrefix(gameWine: gameWine, prefix: bottle.prefixPath)
        // MKXP/RGSS incluye Ruby 2.x, cuyo runtime inspecciona detalles privados de UCRT. El
        // `ucrtbase.dll` builtin de Wine satisface los imports pero Ruby lo rechaza con
        // «unexpected ucrtbase.dll». Vessel conserva una copia nativa en su caché del prefijo,
        // la coloca junto al juego y activa `native,builtin` solo en este proceso. El override
        // global que crea winetricks se elimina para no cambiar el UCRT de los demás juegos.
        let usesMKXPRGSS = isMKXPRGSSGame(executable)
        if usesMKXPRGSS {
            let visualCppReady = await applyWinetricksVerbs(
                ["vcrun2022"],
                prefix: bottle.prefixPath,
                wine: gameWine
            )
            let ucrtReady = await ensureIsolatedMKXPUCRT2019(
                forExecutable: executable,
                prefix: bottle.prefixPath,
                wine: gameWine
            )
            guard visualCppReady, ucrtReady else {
                throw WineError.installationFailed("no se pudo preparar el runtime UCRT requerido por MKXP/RGSS")
            }
            log.log("MKXP/RGSS: Visual C++ y UCRT 2019 aislado preparados automáticamente.", level: .info)
        }
        // Quitar DLLs nativas del prefix para que mande el DXMT builtin del motor.
        cleanPrefixNativeGraphicsDLLs(prefixPath: bottle.prefixPath)
        // Modo Retina: los motores Metal modernos lo necesitan para renderizar a resolución física.
        // SDL2/OpenGL legado anterior a HiDPI necesita justo lo contrario: con Retina sus 1280×720
        // acaban en una ventana de 640×360 puntos y la entrada puede quedar desalineada.
        let legacySDL2Scale = usesLegacySDL2OpenGLScaling(executable)
        await setMacDriverRetinaMode(
            prefix: bottle.prefixPath,
            wine: gameWine,
            enabled: legacySDL2Scale ? false : eff.retina
        )
        if legacySDL2Scale {
            log.log("SDL2/OpenGL legado detectado: escala nativa para alinear ventana y entrada.", level: .info)
        }

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
        if usesMKXPRGSS {
            let base = env["WINEDLLOVERRIDES"] ?? ""
            let ucrt = "ucrtbase=n,b"
            env["WINEDLLOVERRIDES"] = base.isEmpty ? ucrt : "\(base);\(ucrt)"
        }
        if graphicsAPI == .opengl {
            env["CX_FWD_COMPAT_GL_CTX"] = "1"
        }
        // Cualquier import administrado real necesita `mscoree` disponible. Incluye .NET Core y
        // DLLs mixtas C++/CLI usadas por motores nativos (p. ej. el reporter de Hades). La evidencia
        // se obtiene del escaneo PE acotado; no se habilita Mono/.NET globalmente ni por título.
        let managedDependencies: [RuntimeDependencyProvisioner.Dependency] =
            (isDotNetCoreGame(executable) && !runtimeDependencies.contains(.dotNet))
            ? runtimeDependencies + [.dotNet]
            : runtimeDependencies
        env = Self.environmentByEnablingManagedRuntimeIfNeeded(
            env,
            dependencies: managedDependencies
        )
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
            effective: eff,
            enableManagedRuntime: managedDependencies.contains(.dotNet)
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
        // ⭐ **D3D9 de 32-bit → wine-full (el Wine de CrossOver)**, no Gcenx. El new-WoW64 de Gcenx
        // NO crea el dispositivo D3D9 de un binario de 32-bit: el juego muere con su propio diálogo
        // ("d3d creation failed") con CUALQUIER combinación de renderer (gl/vulkan) y de d3d9
        // (builtin/native) — probadas todas. El Wine de CrossOver sí, porque lleva años resolviendo
        // justo el 32-bit sobre Rosetta. Verificado en vivo: 20XX (32-bit, D3D9 + d3dx9_43)
        // renderiza su pantalla de inicio con wine-full y falla con Gcenx en todas las variantes.
        // ANGLE 1.x también usa esta ruta en 64 bits: sobre Gcenx/Vulkan `eglInitialize` falla,
        // mientras que el wined3d del Wine completo expone el D3D9Ex que espera este runtime.
        // Los D3D9 modernos de 64 bits se quedan en Gcenx, que es donde están validados.
        if usesFullCompatibilityEngineForD3D9(executable),
           let fullWine = await fullEngineWineEnsured() {
            return try await launchD3D9GameWithCrossOver(executable: executable, in: bottle,
                                                         arguments: arguments, effective: effective,
                                                         wine: fullWine)
        }
        let clientWine = resolveClientWine(for: bottle)
        log.log("Capa gráfica: wined3d → Vulkan → Metal (juego D3D9/D3D8) con Gcenx", level: .info)
        log.log("Preparando prefijo para el juego…", level: .info)
        // Si venimos de un intento con DXMT (fallback), sus DLLs (d3d11/dxgi/winemetal) quedaron
        // JUNTO al exe y usan la capa unix de wine-dxmt → con Gcenx dan
        // "ntdll.__wine_unix_call unimplemented" y el juego ABORTA. Las quitamos para que Gcenx use
        // sus propias d3d9/wined3d.
        cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
        try? await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: clientWine)
        // Re-sincronizar el prefix al motor Gcenx (tras el cliente Steam o un juego
        // D3D11 el prefix puede quedar en otro motor).
        await resyncGamePrefix(gameWine: clientWine, prefix: bottle.prefixPath)
        // El prefijo es compartido también entre los D3D9 de 64 bits. Escribimos siempre el modo
        // Retina para que una build ANGLE 1.x (no HiDPI-aware) no herede el estado del juego
        // anterior y para que un D3D9 moderno recupere la preferencia efectiva del usuario.
        let legacyNativeScale = usesLegacyD3D9NativeScaling(executable)
        await setMacDriverRetinaMode(
            prefix: bottle.prefixPath,
            wine: clientWine,
            enabled: legacyNativeScale ? false : effective.retina
        )
        if legacyNativeScale {
            log.log("D3D9 legado detectado: escala nativa para alinear framebuffer y entrada.", level: .info)
        }
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

    /// Lanza Virtools clásico con el modo 800×600 que su rasterizador DirectX 7 espera. El escritorio
    /// virtual evita pedir a macOS un modo exclusivo inexistente (`BADMODE`) y mantiene framebuffer,
    /// ventana y coordenadas de entrada en la misma escala. La configuración binaria se prepara antes
    /// de abrir Wine para que el primer arranque no caiga silenciosamente en color de 16 bits.
    private func launchClassicVirtoolsDirectDrawGame(
        executable: String,
        in bottle: Bottle,
        arguments: [String],
        effective: EffectiveLaunchConfig,
        wine: String
    ) async throws -> Process {
        log.log(
            "Virtools clásico (DirectX 7): escritorio virtual 800×600, escala nativa y vídeo de 32 bits.",
            level: .info
        )
        cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
        try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
        await resyncGamePrefix(gameWine: wine, prefix: bottle.prefixPath)
        await setMacDriverRetinaMode(
            prefix: bottle.prefixPath,
            wine: wine,
            enabled: false
        )
        ensureClassicVirtoolsDisplaySettings(
            prefix: bottle.prefixPath,
            executable: executable
        )
        return try await launchWineProcess(
            winePath: wine,
            prefix: bottle.prefixPath,
            arguments: ["explorer", "/desktop=VesselVirtools,800x600", executable] + arguments,
            environment: [
                "WINEPREFIX": bottle.prefixPath,
                "WINEDEBUG": "-all",
                "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
                "WINEMSYNC": "1",
                "WINEESYNC": "1",
                "WINEFSYNC": "1"
            ],
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective,
            forceSyncOn: true,
            forceCleanEnv: true
        )
    }

    /// Lanza un **juego de DirectDraw de la era VGA** (1995-1999) en el **escritorio virtual** de
    /// Wine, con el Wine de CrossOver.
    ///
    /// Dos cosas imprescindibles, ambas verificadas con War Wind (1996):
    /// 1. **Escritorio virtual**: el juego pide un modo de pantalla de **256 colores** (`640x480x8`).
    ///    macOS ya no tiene modos paletizados, así que sin el escritorio virtual el juego aborta con
    ///    "Unable to get screen mode 640x480x8". El escritorio virtual de Wine sí los emula.
    /// 2. **El `ddraw` PARCHEADO del motor** (ver `docs/wine-patches/0002-…`): Wine perdía las
    ///    superficies en el propio `SetDisplayMode` del juego y estos títulos no llaman a
    ///    `Restore()` → todos los `Flip` fallaban → pantalla negra.
    private func launchLegacyDirectDrawGame(executable: String, in bottle: Bottle, arguments: [String],
                                            effective: EffectiveLaunchConfig, wine: String) async throws -> Process {
        log.log("Juego DirectDraw clásico (256 colores): escritorio virtual + Wine de CrossOver.", level: .info)
        // Auto-reparación: la `ddraw` parcheada (sin la cual estos juegos se quedan en negro para
        // siempre). Con marcador de versión, así que solo hace algo la primera vez.
        await dependencyManager.applyDDrawFix()
        cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
        try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
        await resyncGamePrefix(gameWine: wine, prefix: bottle.prefixPath)
        // Estos juegos son de la era de Windows 95: la comprobación de "Windows NT no soportado"
        // los para en seco. Se les dice que corren en un Windows de su época (solo a este exe).
        let exeName = (executable as NSString).lastPathComponent
        _ = try? await runWine(winePath: wine,
                               arguments: ["reg", "add", #"HKCU\Software\Wine\AppDefaults\"# + exeName,
                                           "/v", "Version", "/t", "REG_SZ", "/d", "win98", "/f"],
                               prefix: bottle.prefixPath, allowNonZeroExit: true)
        return try await launchWineProcess(
            winePath: wine,
            prefix: bottle.prefixPath,
            // `explorer /desktop=…` crea el escritorio virtual que emula los modos paletizados.
            arguments: ["explorer", "/desktop=Vessel,640x480", executable] + arguments,
            environment: ["WINEPREFIX": bottle.prefixPath, "WINEDEBUG": "-all",
                          "WINEDLLOVERRIDES": "winemenubuilder.exe=d"],
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective,
            forceCleanEnv: true
        )
    }

    /// Lanza un **D3D9 de compatibilidad con el Wine de CrossOver** (`wine-full`).
    ///
    /// Es el único que crea el dispositivo D3D9 de un binario de 32-bit en Apple Silicon: el
    /// new-WoW64 de Gcenx falla con "d3d creation failed" con TODAS las combinaciones de renderer
    /// (gl/vulkan) y de d3d9 (builtin/native). `wine-full` no necesita capa de traducción extra —
    /// trae su propio wined3d y su `cxcompatdb` — así que se lanza tal cual, con el contexto LIMPIO
    /// (`env -i` vía `launchWineProcess`, que ya trata este motor). Validado: 20XX renderiza.
    private func launchD3D9GameWithCrossOver(executable: String, in bottle: Bottle, arguments: [String],
                                             effective: EffectiveLaunchConfig, wine: String) async throws -> Process {
        let legacyANGLE = isLegacyANGLE1D3D9Game(executable)
        let legacyANGLEIsolatedDXVK = usesIsolatedDXVKForLegacyANGLE64(executable)
        let chowdrenIsolatedDXVK = isChowdrenSDL2D3D9Engine(executable)
        let isolatedDXVK = legacyANGLEIsolatedDXVK || chowdrenIsolatedDXVK
        log.log(
            chowdrenIsolatedDXVK
                ? "Capa gráfica: DXVK D3D9 2D aislado sobre MoltenVK (Chowdren/SDL2)."
                : legacyANGLEIsolatedDXVK
                ? "Capa gráfica: DXVK D3D9 aislado sobre MoltenVK (ANGLE 1.x PE64)."
                : legacyANGLE
                ? "Capa gráfica: wined3d de CrossOver (ANGLE 1.x sobre D3D9) — contexto EGL compatible."
                : "Capa gráfica: wined3d de CrossOver (juego D3D9 de 32-bit) — el único que crea el device",
            level: .info
        )
        let legacyOgre = isLegacyOgreD3D9Game(executable)
        let legacyNativeScale = usesLegacyD3D9NativeScaling(executable)
        cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
        try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
        await resyncGamePrefix(gameWine: wine, prefix: bottle.prefixPath)
        if legacyOgre {
            let executableName = (executable as NSString).lastPathComponent
            // OGRE 1.6 crea el device con wined3d/Vulkan pero entrega un framebuffer negro. Su
            // D3D9 original renderiza correctamente sobre el backend OpenGL de Apple. La clave se
            // limita a este ejecutable para no cambiar el renderer de ningún otro juego del bottle.
            await setWined3dRenderer(
                prefix: bottle.prefixPath,
                wine: wine,
                renderer: "gl",
                forExecutable: executableName
            )
            log.log(
                "OGRE D3D9 legado detectado: wined3d/OpenGL por ejecutable.",
                level: .info
            )
        }
        if legacyANGLE {
            let executableName = (executable as NSString).lastPathComponent
            // ANGLE 1 compone correctamente sobre el backend OpenGL de wined3d. Su backend Vulkan
            // crea EGL, pero corrompe la superficie con grandes triángulos negros en Apple Silicon.
            // La clave se limita al ejecutable efectivo, igual que la excepción OGRE anterior.
            await setWined3dRenderer(
                prefix: bottle.prefixPath,
                wine: wine,
                renderer: "gl",
                forExecutable: executableName
            )
            log.log(
                "ANGLE 1 legado detectado: wined3d/OpenGL aislado por ejecutable para evitar corrupción de composición Vulkan.",
                level: .info
            )
        }
        // Se evalúa después de resincronizar el prefijo: la reparación de Steamworks previa puede
        // estar restaurando archivos del juego mientras se decide la ruta gráfica.
        if isAlmostHumanLuaJITD3D9Engine(executable) {
            let executableName = (executable as NSString).lastPathComponent
            await setWined3dRenderer(
                prefix: bottle.prefixPath,
                wine: wine,
                renderer: "gl",
                forExecutable: executableName
            )
            log.log(
                "Motor Almost Human D3D9 detectado: wined3d/OpenGL aislado para superficies depth/stencil.",
                level: .info
            )
        }
        await configurePlaydeadLegacyD3D9Renderer(
            prefix: bottle.prefixPath,
            wine: wine,
            executable: executable
        )
        ensureFalcomYsOriginDisplaySettings(
            prefix: bottle.prefixPath,
            executable: executable
        )
        // Se escribe SIEMPRE: el prefijo es compartido y no puede heredar Retina on/off del juego
        // anterior. OGRE 1.6 y ANGLE 1.x no son HiDPI-aware; el resto respeta la configuración.
        await setMacDriverRetinaMode(
            prefix: bottle.prefixPath,
            wine: wine,
            enabled: legacyNativeScale ? false : effective.retina
        )
        if legacyNativeScale {
            log.log("D3D9 legado detectado: escala nativa para alinear framebuffer y entrada.", level: .info)
        }
        var environment = Self.fullEngineEnvironment(prefix: bottle.prefixPath)
        if isolatedDXVK {
            if chowdrenIsolatedDXVK {
                try await dxvkManager.installGameLocalChowdrenD3D9(forExecutable: executable)
            } else {
                try await dxvkManager.installGameLocalD3D9(
                    forExecutable: executable,
                    is64Bit: true
                )
            }
            let moltenVK = try await moltenVKManager.ensureLibrary()
            environment = Self.modernMoltenVKEnvironment(
                from: environment,
                libraryDirectory: moltenVK,
                // ANGLE necesita argument buffers para separar alias de recursos. Chowdren usa la
                // ruta clásica, más estable para sus samplers 2D ya validados.
                useMetalArgumentBuffers: !chowdrenIsolatedDXVK
            )
            environment["WINEDLLOVERRIDES"] = "d3d9=n,b;winemenubuilder.exe=d"
            environment["DXVK_LOG_LEVEL"] = "info"
            environment["DXVK_LOG_PATH"] = (executable as NSString).deletingLastPathComponent
            log.log("MoltenVK moderno aislado para DXVK: \(moltenVK)", level: .info)
        }
        if legacyOgre {
            environment["WINEMSYNC"] = "1"
            environment["WINEESYNC"] = "1"
        }
        return try await launchWineProcess(
            winePath: wine,
            prefix: bottle.prefixPath,
            arguments: [executable] + arguments,
            environment: environment,
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective
        )
    }

    /// Lanza Moai/AKUSDL PE32 con el contexto OpenGL de compatibilidad de `wine-full`.
    ///
    /// El motor OpenGL unificado está parcheado para contextos 3.2 core modernos; estas builds
    /// antiguas solicitan un contexto compatible y pueden quedarse vivas sin publicar ventana.
    /// `wine-full` conserva esa ruta y no necesita argumentos de lanzamiento ni ajustes del usuario.
    private func launchLegacyMoaiOpenGLGame(
        executable: String,
        in bottle: Bottle,
        arguments: [String],
        steamAppId: String?,
        effective: EffectiveLaunchConfig,
        wine: String
    ) async throws -> Process {
        log.log("Motor Moai/AKUSDL detectado: OpenGL PE32 con el Wine completo.", level: .info)
        cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
        try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
        await resyncGamePrefix(gameWine: wine, prefix: bottle.prefixPath)
        await setMacDriverRetinaMode(
            prefix: bottle.prefixPath,
            wine: wine,
            enabled: effective.retina
        )
        var environment = Self.fullEngineEnvironment(prefix: bottle.prefixPath)
        if let steamAppId, !steamAppId.isEmpty {
            environment["SteamAppId"] = steamAppId
            environment["SteamGameId"] = steamAppId
        }
        return try await launchWineProcess(
            winePath: wine,
            prefix: bottle.prefixPath,
            arguments: [executable] + arguments,
            environment: environment,
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective
        )
    }

    /// Lanza el Proton SDK de RTsoft con la combinación validada: OpenGL de `wine-full`, escala 1×
    /// y ventana redimensionable. El motor conserva después sus preferencias en `save.dat`.
    private func launchRTsoftProtonOpenGLGame(
        executable: String,
        in bottle: Bottle,
        arguments: [String],
        steamAppId: String?,
        effective: EffectiveLaunchConfig,
        wine: String
    ) async throws -> Process {
        log.log(
            "Motor RTsoft Proton SDK detectado: OpenGL compatible en ventana y escala nativa.",
            level: .info
        )
        cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
        try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
        await resyncGamePrefix(gameWine: wine, prefix: bottle.prefixPath)
        await setMacDriverRetinaMode(prefix: bottle.prefixPath, wine: wine, enabled: false)

        var environment = Self.fullEngineEnvironment(prefix: bottle.prefixPath)
        if let steamAppId, !steamAppId.isEmpty {
            environment["SteamAppId"] = steamAppId
            environment["SteamGameId"] = steamAppId
        }
        return try await launchWineProcess(
            winePath: wine,
            prefix: bottle.prefixPath,
            arguments: [executable] + Self.rtsoftProtonLaunchArguments(arguments),
            environment: environment,
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective
        )
    }

    /// Motor completo (`wine-full`) para las rutas que lo necesitan, DESCARGÁNDOLO si falta.
    /// Tarea #47: desde la 0.0.4 `wine-full` es la build propia redistribuible de Vessel (fuentes
    /// FOSS de CrossOver 26.2.0, wine-11.0 + CW HACKs, LGPL), que se descarga de Vessel-Engines.
    /// Antes era una copia manual del CrossOver local, así que en máquinas sin CrossOver estas
    /// rutas (UE4, FNA/XNA, Source, Godot-Vulkan, D3D9 32-bit…) simplemente no iban. Devuelve
    /// `nil` si no está y no se pudo descargar → la ruta cae al enrutado normal, como antes.
    private func fullEngineWineEnsured() async -> String? {
        let path = "\(WineEngineLocator.fullEngineDir())/bin/wine"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
        do {
            try await dependencyManager.ensureFullEngine { msg, pct in
                Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
            }
        } catch {
            log.log("No se pudo descargar el motor completo (wine-full): \(error.localizedDescription)", level: .warn)
        }
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Lanza un juego **FNA/XNA** con el .NET Framework de verdad.
    ///
    /// Con wine-mono estos juegos arrancan a medias: crean ventana y se quedan en NEGRO para
    /// siempre (FEZ), o el runtime revienta con un crash nativo. Con el `dotnet48` real renderizan.
    ///
    /// Va en un **prefijo aislado** (`__net48`) a propósito: instalar .NET Framework **desinstala
    /// wine-mono** (lo hace el propio winetricks), así que hacerlo en el prefijo compartido le
    /// cambiaría el runtime por debajo a todos los demás juegos. Misma regla que el resto de
    /// motores/fixes: reparar una cosa no puede romper las otras.
    private func launchFNAGameWithCrossOver(executable rawExecutable: String, in bottle: Bottle,
                                            arguments: [String], effective: EffectiveLaunchConfig,
                                            wine: String) async throws -> Process {
        log.log("Juego FNA/XNA: necesita el .NET Framework real (wine-mono no le vale).", level: .info)
        // El lanzador del motor tiene que estar sano o winetricks no instalará nada (ver
        // `repairFullEngineShim`). Idempotente y con marcador: solo hace algo la primera vez.
        await dependencyManager.repairFullEngineShim()
        // Drop-in: setupapi que no se cuelga registrando el mscoree de Microsoft (NGen/mscorsvw)
        // en el wineboot -u del prefijo __net48. Idempotente y con marcador.
        await dependencyManager.applyNet48Fix()
        let prefix = await engineScopedPrefix(base: bottle.prefixPath, engineTag: "net48", engineWine: wine)
        let executable = scopedPath(rawExecutable, base: bottle.prefixPath, scoped: prefix)
        try? await terminateWineProcesses(winePath: wine, prefix: prefix)
        try? await killOrphanWineProcesses(prefix: prefix, gameWine: wine)
        await resyncGamePrefix(gameWine: wine, prefix: prefix)
        // Retina OFF: sin esto Wine le dice al juego que la pantalla mide 3024×1964 (los PÍXELES de
        // una Retina de 1512×982), y un juego de esta época no es DPI-aware: se lo cree, pide una
        // ventana de ese tamaño —el doble de la pantalla, desbordada— y **se guarda esa resolución
        // en su config**. A partir de ahí ya da igual lo que haga Wine: el juego lee su fichero.
        await setMacDriverRetinaMode(prefix: prefix, wine: wine, enabled: false)
        // …y por eso hay que tirar la config envenenada de arranques anteriores (ver `resetFNASettings`).
        resetFNAScreenSettings(prefix: prefix, executable: rawExecutable)
        // Idempotente: la primera vez tarda (descarga el redistribuible de Microsoft), luego no.
        // `xna40` solo para los que usan el XNA de Microsoft sin traérselo (Terraria); los de FNA
        // (FEZ) no lo necesitan y no se les instala de más.
        var verbs = ["dotnet48"]
        if needsXNARedistributable(rawExecutable) { verbs.append("xna40") }
        await applyWinetricksVerbs(verbs, prefix: prefix, wine: wine)
        cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
        cleanGameFolderGraphicsDLLs(forExecutable: executable)
        return try await launchWineProcess(
            winePath: wine,
            prefix: prefix,
            arguments: [executable] + arguments,
            // SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0: SDL2 minimiza las ventanas fullscreen al
            // perder el foco POR DEFECTO, así que al cambiar de app el juego se encogía a una
            // ventanita oculta y su render se reiniciaba (pantalla de título / cuadro blanco) —
            // el "congelado al cambiar de ventana". Reproducido con FEZ en AMBOS motores (el
            // juego mismo hace SetWindowPos 800×480 + ShowWindow(SW_MINIMIZE), no es winemac).
            // Con la hint a 0 el juego se queda borderless al fondo y vuelve intacto. Verificado
            // in-vivo: FEZ no se esconde al activar el Finder y sigue respondiendo al volver.
            environment: ["WINEPREFIX": prefix, "WINEDEBUG": "-all",
                          "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
                          "WINEMSYNC": "1", "WINEESYNC": "1",
                          "SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS": "0"],
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective
        )
    }

    /// Tira la resolución guardada por un juego FNA/XNA si es **más grande que la pantalla**.
    ///
    /// Estos juegos **se guardan la resolución en su propio fichero** en el primer arranque. Si ese
    /// primer arranque fue con Retina activado, el juego anotó los PÍXELES de la pantalla (6048×3928
    /// en una Retina de 1512×982) y desde entonces **lee su fichero y se ignora al sistema**: da
    /// igual lo que haga Wine después, sigue dibujando en una superficie enorme y solo se ve una
    /// esquina, ampliada. Esa era la causa real de que FEZ se viera recortado.
    ///
    /// Se borra solo el bloque de pantalla y solo si está fuera de rango, así que no se pierde nada
    /// del jugador (volumen, idioma, mandos): el juego regenera esas líneas en el siguiente arranque
    /// con lo que Wine le diga, que ahora es correcto. Si la resolución guardada cabe en la pantalla,
    /// se respeta — es una elección del usuario.
    private func resetFNAScreenSettings(prefix: String, executable: String) {
        let fm = FileManager.default
        // Tamaño de la pantalla en PUNTOS (que es en lo que piensan estos juegos), vía CoreGraphics
        // para no arrastrar AppKit a la capa de servicios.
        let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
        let screen = CGSize(width: mode?.width ?? 1512, height: mode?.height ?? 982)
        // OJO: el usuario DENTRO del prefijo no tiene por qué llamarse como el del Mac — el motor de
        // CrossOver usa `crossover`. Se recorren todos los del prefijo.
        let usersDir = "\(prefix)/drive_c/users"
        let users = (try? fm.contentsOfDirectory(atPath: usersDir)) ?? []
        for user in users {
            let roaming = "\(usersDir)/\(user)/AppData/Roaming"
            guard let dirs = try? fm.contentsOfDirectory(atPath: roaming) else { continue }
            for dir in dirs {
                let settings = "\(roaming)/\(dir)/Settings"
                guard fm.fileExists(atPath: settings),
                      let raw = try? String(contentsOfFile: settings, encoding: .isoLatin1) else { continue }
                // `width`/`height` en el formato de FezEngine.Tools.Settings.
                func value(_ key: String) -> Int? {
                    guard let r = raw.range(of: #"(?m)^\s*\#(key)\s+(\d+)"#, options: .regularExpression)
                    else { return nil }
                    return Int(raw[r].split(separator: " ").last.map(String.init) ?? "")
                }
                guard let w = value("width"), let h = value("height"),
                      Double(w) > screen.width || Double(h) > screen.height else { continue }
                try? fm.removeItem(atPath: settings)
                log.log("Resolución guardada del juego (\(w)×\(h)) mayor que la pantalla: se descarta para que la vuelva a calcular.", level: .info)
            }
        }
    }

    /// Lanza un **Unreal Engine 4** con el Wine COMPLETO de CrossOver (`wine-full`).
    ///
    /// UE4 no arranca por DXMT ni por GPTK: se queda a medias, sin ventana y sin dejar ni su log.
    /// Con `wine-full` abre. Es la misma razón que en los Unity 32-bit y los D3D9: es el motor que
    /// da un contexto gráfico de verdad. Se queda en el prefijo base (64-bit, comparte con Steam).
    private func launchUnreal4WithCrossOver(executable rawExecutable: String, in bottle: Bottle,
                                            arguments: [String], steamAppId: String?,
                                            effective: EffectiveLaunchConfig, wine: String) async throws -> Process {
        log.log("Capa gráfica: Wine completo de CrossOver (Unreal Engine 4) — el único que le da contexto gráfico", level: .info)
        cleanExeAdjacentDXMTDLLs(gameExecutable: rawExecutable)
        cleanGameFolderGraphicsDLLs(forExecutable: rawExecutable)
        try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
        await resyncGamePrefix(gameWine: wine, prefix: bottle.prefixPath)
        // esync OFF: UE4 arranca con `msync` pero se muere al instante con `esync` activado
        // (aislado con ASTRONEER: mismo comando, esync=1 no abre, esync=0/ausente sí). El arranque de
        // UE4 bajo Wine además tiene una condición de carrera que lo hace intermitente; el reintento
        // de la auto-reparación lo cubre.
        var env = ["WINEPREFIX": bottle.prefixPath, "WINEDEBUG": "-all",
                   "WINEDLLOVERRIDES": "winemenubuilder.exe=d", "WINEMSYNC": "1", "WINEESYNC": "0"]
        if let appId = steamAppId, !appId.isEmpty { env["SteamAppId"] = appId; env["SteamGameId"] = appId }
        var eff = effective
        eff.esync = false; eff.msync = true
        return try await launchWineProcess(
            winePath: wine,
            prefix: bottle.prefixPath,
            arguments: [rawExecutable] + arguments,
            environment: env,
            workingDirectory: gameWorkingDirectory(forExecutable: rawExecutable),
            effective: eff
        )
    }

    /// Lanza un **Unity de 32-bit** con el Wine COMPLETO de CrossOver (`wine-full`).
    ///
    /// Es el mismo motor que ya resuelve los D3D9 de 32-bit (ver `launchD3D9GameWithCrossOver`), y por
    /// el mismo motivo: es el único que le da a un proceso de 32-bit un contexto gráfico de verdad.
    ///
    /// Nada de `-force-glcore`: con él Unity se salta Direct3D y pide OpenGL directo, que es justo lo
    /// que falla. Sin él, Unity usa su ruta normal y renderiza. Sí se conserva `-force-gfx-direct`
    /// (render monohilo): el multihilo bajo Wine corrompe memoria. Verificado con A Short Hike.
    private func launchUnity32BitWithCrossOver(executable: String, in bottle: Bottle, arguments: [String],
                                               effective: EffectiveLaunchConfig, wine: String) async throws -> Process {
        log.log("Capa gráfica: Wine completo de CrossOver (Unity de 32-bit) — el único que le da contexto gráfico", level: .info)
        // DLLs de traducción de OTROS motores junto al `.exe`: pisan el builtin y se llevan el
        // arranque por delante (una `d3d10_1` de DXMT arrastra `winemetal` a un motor que no lo es).
        cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
        cleanGameFolderGraphicsDLLs(forExecutable: executable)
        try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
        await resyncGamePrefix(gameWine: wine, prefix: bottle.prefixPath)
        return try await launchWineProcess(
            winePath: wine,
            prefix: bottle.prefixPath,
            arguments: [executable] + arguments
                + ["-force-gfx-direct", "-screen-fullscreen", "1", "-window-mode", "borderless"],
            environment: ["WINEPREFIX": bottle.prefixPath, "WINEDEBUG": "-all",
                          "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
                          "WINEMSYNC": "1", "WINEESYNC": "1"],
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective
        )
    }

    /// Lanza un juego de **DOS con el DOSBox NATIVO** de Vessel — sin Wine y sin Rosetta.
    ///
    /// El `.exe` que declara GOG es un DOSBox **para Windows**, pero el juego que hay dentro es de
    /// DOS: no necesita Windows para nada. Se descarta ese envoltorio y se ejecuta el mismo juego,
    /// con la misma configuración que GOG afinó, sobre DOSBox Staging nativo (arm64). Sale mejor
    /// que en Windows: sin dos capas de emulación de por medio.
    ///
    /// Motivo de fondo: el DOSBox 0.74-2 de GOG usa SDL 1.2, que bajo este Wine en Apple Silicon no
    /// crea ventana con NINGUNA salida de vídeo (probadas `surface`/`overlay`/`opengl`/`openglnb`/
    /// `ddraw`: todas negras). No es un ajuste que falte: es un muro.
    private func launchNativeDOSBox(executable: String, arguments: [String],
                                    gameRoot: String, appId: String) async throws -> Process {
        let binary = try await DOSBoxManager.shared.ensureInstalled { [weak self] msg in
            self?.log.log(msg, level: .info)
        }
        let args = DOSBoxManager.nativeArguments(from: arguments, gameRoot: gameRoot, appId: appId)
        // El directorio de trabajo es la carpeta del `dosbox.exe` de GOG: sus `.conf` montan las
        // unidades con rutas RELATIVAS a ella (`mount C ".."` = la raíz del juego).
        let workingDir = (executable as NSString).deletingLastPathComponent
        log.log("Juego de DOS: usando el DOSBox NATIVO (arm64, sin Wine ni Rosetta).", level: .info)
        log.log("CMD: dosbox \(args.joined(separator: " "))", level: .debug)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        if FileManager.default.fileExists(atPath: workingDir) {
            p.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        }
        // Log del juego en el mismo sitio que el resto, para diagnóstico real.
        let logPath = "\(NSHomeDirectory())/Library/Logs/Vessel/game-launch.log"
        try? Data().write(to: URL(fileURLWithPath: logPath), options: .atomic)
        if let h = FileHandle(forWritingAtPath: logPath) { p.standardOutput = h; p.standardError = h }
        do { try p.run() } catch { throw WineError.launchFailed(error.localizedDescription) }
        log.log("DOSBox nativo lanzado (pid=\(p.processIdentifier))", level: .info)
        return p
    }

    /// Lanza un **envoltorio retro** (DOSBox / ScummVM) con Gcenx y **sin tocar nada más**.
    ///
    /// Estos no son juegos de Direct3D: son emuladores SDL que pintan por software u OpenGL y se
    /// configuran solos con el `.conf`/`.ini` que les pasa el playTask de GOG. Toda la preparación
    /// que hacen las otras rutas (DLLs nativas de d3dx9, `renderer=vulkan`, overrides de d3d9…) no
    /// les aporta nada y les estorba: con la ruta D3D9 el proceso moría al instante; con un
    /// lanzamiento limpio arrancan. Verificado en vivo con Beneath a Steel Sky (ScummVM), que
    /// renderiza su intro, y con el DOSBox de Akalabeth.
    private func launchRetroWrapper(executable: String, in bottle: Bottle, arguments: [String],
                                    effective: EffectiveLaunchConfig = EffectiveLaunchConfig()) async throws -> Process {
        let wine = resolveClientWine(for: bottle)   // Gcenx: es el que ejecuta binarios de 32-bit
        log.log("Envoltorio retro (DOSBox/ScummVM) con Gcenx — sin capa gráfica: \((executable as NSString).lastPathComponent)",
                level: .info)
        // Si un intento anterior con DXMT dejó sus DLLs junto al exe, con Gcenx abortan.
        cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
        try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
        await resyncGamePrefix(gameWine: wine, prefix: bottle.prefixPath)
        // ⭐ `renderer=gl`, y NO es opcional. SDL (que es lo que usan DOSBox y ScummVM) pinta su
        // framebuffer como un quad = DOS triángulos. Con `renderer=vulkan` (que otro juego D3D9 del
        // MISMO prefijo pudo dejar puesto, porque la clave es del prefijo y persiste) MoltenVK solo
        // rasteriza UNO: el juego se ve **cortado por una diagonal perfecta**, con media pantalla en
        // negro. Con el GL de Apple se ve entero. Verificado en vivo con Beneath a Steel Sky.
        await setWined3dRenderer(prefix: bottle.prefixPath, wine: wine, renderer: "gl")
        return try await launchWineProcess(
            winePath: wine,
            prefix: bottle.prefixPath,
            arguments: [executable] + arguments,
            // Entorno MÍNIMO a propósito: nada de overrides de DLL ni capas de traducción.
            // ⭐ `SDL_RENDER_DRIVER=software` es LA pieza. En Windows, SDL2 elige **Direct3D 9** como
            // backend de render por defecto, así que DOSBox/ScummVM —que no tienen nada de 3D— acaban
            // pasando por `d3d9` → `wined3d` igualmente. Y ahí se rompe todo, de tres formas distintas
            // según el renderer del prefijo: con Vulkan/MoltenVK la imagen sale **cortada por una
            // diagonal** (solo se rasteriza uno de los dos triángulos del quad), con GL se queda en
            // **negro**, y a veces revienta con un page fault cuya traza es inequívoca:
            // `sdl2 → d3d9 → wined3d`. Diciéndole a SDL que pinte por software se salta wined3d
            // entero: son juegos de 320×200, el coste es nulo.
            environment: ["WINEPREFIX": bottle.prefixPath, "WINEDEBUG": "-all",
                          "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
                          "SDL_RENDER_DRIVER": "software",
                          "SDL_FRAMEBUFFER_ACCELERATION": "0"],
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective,
            // Contexto LIMPIO (env -i), igual que los juegos DXMT: heredando la identidad de bundle
            // de Vessel, el contexto OpenGL de SDL se crea pero **no pinta nada** — la ventana abre a
            // pantalla completa y se queda en NEGRO (el proceso vive, así que ni siquiera parece un
            // error). Lanzado como desde un terminal, renderiza.
            forceCleanEnv: true
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
    /// Lanza HPL3 con un motor y un prefijo dedicados. El prefijo comparte únicamente juegos y
    /// partidas con la biblioteca: el registro Retina, `drive_c/windows` y wineserver son privados.
    /// Los adaptadores OpenGL son además opt-in por entorno, por lo que ni siquiera dentro del clon
    /// afectan a procesos que no hayan sido detectados como HPL3.
    private func launchLegacyHPL3OpenGLGame(
        executable rawExecutable: String,
        in bottle: Bottle,
        arguments: [String],
        steamAppId: String?,
        effective: EffectiveLaunchConfig
    ) async throws -> Process {
        try await dependencyManager.ensureUnifiedEngine { message, progress in
            Task { @MainActor in
                LogStore.shared.log("\(message) (\(Int(progress * 100))%)", level: .info)
            }
        }
        let wine = try await dependencyManager.ensureUnifiedLegacyOpenGLEngine {
            message, progress in
            Task { @MainActor in
                LogStore.shared.log("\(message) (\(Int(progress * 100))%)", level: .info)
            }
        }
        let prefix = await engineScopedPrefix(
            base: bottle.prefixPath,
            engineTag: "opengl-legacy",
            engineWine: wine
        )
        let executable = scopedPath(rawExecutable, base: bottle.prefixPath, scoped: prefix)
        let workingDirectory = scopedPath(
            gameWorkingDirectory(forExecutable: rawExecutable),
            base: bottle.prefixPath,
            scoped: prefix
        )

        _ = RuntimeDependencyProvisioner.provision(executable: rawExecutable)
        try? await terminateWineProcesses(winePath: wine, prefix: prefix)
        try? await killOrphanWineProcesses(prefix: prefix, gameWine: wine)
        await setMacDriverRetinaMode(prefix: prefix, wine: wine, enabled: false)

        var environment = gameLaunchEnvironment(prefix: prefix)
        environment["WINEDEBUG"] = "-all"
        environment["VESSEL_FORCE_CORE_GL_CTX"] = "1"
        environment["CX_FWD_COMPAT_GL_CTX"] = "1"
        environment["WINEMSYNC"] = "0"
        environment["WINEESYNC"] = "0"
        environment["WINEFSYNC"] = "0"
        let overrides = [environment["WINEDLLOVERRIDES"], "winegstreamer=d", "winemenubuilder.exe=d"]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        environment["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")
        if let steamAppId, !steamAppId.isEmpty {
            environment["SteamAppId"] = steamAppId
            environment["SteamGameId"] = steamAppId
        }

        log.log(
            "HPL3: OpenGL 4.1 core compatible, escala nativa y prefijo aislado preparados automáticamente.",
            level: .info
        )
        return try await launchWineProcess(
            winePath: wine,
            prefix: prefix,
            arguments: [executable] + arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            effective: effective,
            forceSyncOff: true,
            forceCleanEnv: true
        )
    }

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
        // ⭐ `Games` NO es opcional: es donde Vessel instala los juegos de **Epic y GOG**
        // (`drive_c/Games/…`). Sin enlazarla, `scopedPath` reescribe el ejecutable a un prefijo
        // aislado donde ese juego NO EXISTE, y el lanzamiento muere con un "falta una librería del
        // sistema" que no tiene nada que ver con la causa real. Pasaba con A Short Hike (Epic,
        // Unity 32-bit → prefijo `__gptk`).
        for rel in ["Program Files (x86)", "Program Files", "Games", "users"] {
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
        // **Unity de 32-bit → Wine COMPLETO de CrossOver (`wine-full`)**, no gptk-mythic.
        // Bajo gptk, Unity no consigue contexto gráfico por NINGUNA vía: ni D3D11 ni OpenGL
        // (`OPENGL ERROR: failed to choose pixel format`). Ese error ni se veía, porque Unity lo
        // anuncia en un MessageBox y Wine se mata dibujando ese texto (bug de Uniscribe: en
        // `ScriptString_pSize` lee `glyphs[0].sc->tm.tmHeight` sin comprobar que `sc` exista).
        // `wine-full` sí le da contexto y el juego renderiza. Verificado en vivo: A Short Hike.
        if isUnityGame(rawExecutable), let fullWine = await fullEngineWineEnsured() {
            return try await launchUnity32BitWithCrossOver(executable: rawExecutable, in: bottle,
                                                           arguments: arguments, effective: effective,
                                                           wine: fullWine)
        }
        // **Resto de juegos de 32-bit (GameMaker y similares) → `wine-full` primero.**
        // El gptk-mythic los deja COLGADOS en el init de display con una ventana de 3×41 píxeles
        // (GameMaker prueba APIs y no consigue contexto; todos los hilos en espera de wineserver).
        // Con `wine-full` el mismo juego cambia de API y RENDERIZA. Verificado: Caveblazers abre
        // su menú con wine-full mientras gptk se queda en 3×41 (y 10 Second Ninja X, también
        // GameMaker, va por la misma ruta D3D9-32). Si `wine-full` no está, se mantiene gptk.
        if !isUnityGame(rawExecutable), let fullWine = await fullEngineWineEnsured() {
            log.log("Capa gráfica: Wine completo (juego de 32-bit) — gptk cuelga su init de display.", level: .info)
            cleanExeAdjacentDXMTDLLs(gameExecutable: rawExecutable)
            cleanGameFolderGraphicsDLLs(forExecutable: rawExecutable)
            try? await terminateWineProcesses(winePath: fullWine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: fullWine)
            await resyncGamePrefix(gameWine: fullWine, prefix: bottle.prefixPath)
            // El prefijo es compartido: escribir SIEMPRE el modo evita que un juego herede la
            // escala del anterior. Clickteam/MMF2 necesita píxeles 1:1; el resto recupera la
            // preferencia efectiva del perfil en vez de quedarse accidentalmente con Retina off.
            let legacyNativeScale = usesLegacy32BitNativeScaling(rawExecutable)
            await setMacDriverRetinaMode(
                prefix: bottle.prefixPath,
                wine: fullWine,
                enabled: legacyNativeScale ? false : effective.retina
            )
            if legacyNativeScale {
                let reason = isUnrealEngine1Game(rawExecutable)
                    ? "Unreal Engine 1 detectado: escala nativa para alinear viewport y ratón."
                    : "Clickteam/MMF2 DirectDraw detectado: escala nativa para alinear superficie y ratón."
                log.log(reason, level: .info)
            }
            // Algunos motores D3D9 cargan Direct3D dinámicamente, por lo que llegan por esta ruta
            // genérica PE32 en vez de `launchD3D9GameWithCrossOver`. Almost Human necesita el mismo
            // override OpenGL aislado: el backend Vulkan devuelve D3DERR_INVALIDCALL al crear su
            // superficie depth/stencil. Se decide después de resincronizar para inspeccionar el
            // ejecutable definitivo ya reparado por Steamworks.
            if isAlmostHumanLuaJITD3D9Engine(rawExecutable) {
                let executableName = (rawExecutable as NSString).lastPathComponent
                await setWined3dRenderer(
                    prefix: bottle.prefixPath,
                    wine: fullWine,
                    renderer: "gl",
                    forExecutable: executableName
                )
                log.log(
                    "Motor Almost Human D3D9 detectado: wined3d/OpenGL aislado para superficies depth/stencil.",
                    level: .info
                )
            }
            await configurePlaydeadLegacyD3D9Renderer(
                prefix: bottle.prefixPath,
                wine: fullWine,
                executable: rawExecutable
            )
            return try await launchWineProcess(
                winePath: fullWine,
                prefix: bottle.prefixPath,
                arguments: [rawExecutable] + arguments,
                environment: ["WINEPREFIX": bottle.prefixPath, "WINEDEBUG": "-all",
                              "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
                              "WINEMSYNC": "1", "WINEESYNC": "1"],
                workingDirectory: gameWorkingDirectory(forExecutable: rawExecutable),
                effective: effective
            )
        }
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
        try? await killOrphanWineProcesses(prefix: prefix, gameWine: gptkWine)
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

    /// `true` únicamente para un PE x86-64 (`IMAGE_FILE_MACHINE_AMD64`). Se mantiene separado del
    /// detector de 32 bits para no alterar el enrutado histórico de ningún juego existente.
    private func isExecutable64Bit(_ executable: String) -> Bool {
        guard let file = FileHandle(forReadingAtPath: executable) else { return false }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: 0x40), head.count >= 0x40 else { return false }
        let peOffset = Int(head[0x3c]) | (Int(head[0x3d]) << 8)
            | (Int(head[0x3e]) << 16) | (Int(head[0x3f]) << 24)
        guard peOffset > 0, peOffset < 0x1_000_000 else { return false }
        try? file.seek(toOffset: UInt64(peOffset))
        guard let pe = try? file.read(upToCount: 6), pe.count >= 6,
              pe[0] == 0x50, pe[1] == 0x45 else { return false }
        let machine = Int(pe[4]) | (Int(pe[5]) << 8)
        return machine == 0x8664
    }

    /// Identifica directamente el payload MKXP/RGSS empaquetado con Ruby y SDL2. Este motor carga
    /// OpenGL en runtime, por lo que no aparece en la tabla de imports PE. Se exige la combinación
    /// completa de firmas para no confundir cualquier juego que distribuya SDL2 o Ruby como
    /// herramienta. Esta variante no sigue launchers para evitar recursión al resolver SteamShim.
    private func isDirectMKXPRGSSGame(_ executable: String) -> Bool {
        guard exeContains(executable, anyOf: ["MKXP"]),
              exeContains(executable, anyOf: ["RGSS_VERSION", "$RGSS_SCRIPTS"]),
              let names = try? FileManager.default.contentsOfDirectory(
                atPath: (executable as NSString).deletingLastPathComponent
              ) else {
            return false
        }
        let lower = names.map { $0.lowercased() }
        return lower.contains("sdl2.dll")
            && lower.contains { $0.hasSuffix(".dll") && $0.contains("ruby") }
    }

    /// Identifica MKXP/RGSS tanto al recibir el payload como su bootstrapper SteamShim. De este
    /// modo la selección del motor gráfico y la política HiDPI se mantienen aunque el ejecutable
    /// que deba abrir Wine sea el launcher requerido por Steamworks.
    func isMKXPRGSSGame(_ executable: String) -> Bool {
        isDirectMKXPRGSSGame(executable) || steamShimPayload(forBootstrapper: executable) != nil
    }

    /// SteamShim crea los handles IPC que espera el payload mediante variables `STEAMSHIM_*`.
    /// El nombre por sí solo no basta: se exige una importación PE real de Steamworks y las firmas
    /// de ambos handles más `SteamAPI_Init`, evitando tratar como bootstrapper una copia residual.
    func isSteamShimBootstrapper(_ executable: String) -> Bool {
        guard (executable as NSString).lastPathComponent
            .caseInsensitiveCompare("steamshim.exe") == .orderedSame,
              exeImports(executable, anyOf: ["steam_api64.dll", "steam_api.dll"]) else {
            return false
        }
        return exeContains(executable, anyOf: ["STEAMSHIM_READHANDLE"])
            && exeContains(executable, anyOf: ["STEAMSHIM_WRITEHANDLE"])
            && exeContains(executable, anyOf: ["SteamAPI_Init"])
    }

    /// Devuelve el payload MKXP hermano de un SteamShim verificado. La búsqueda es local y
    /// determinista: no atraviesa subdirectorios ni intenta adivinar por el título del juego.
    func steamShimPayload(forBootstrapper executable: String) -> String? {
        guard isSteamShimBootstrapper(executable) else { return nil }
        let directory = (executable as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return nil
        }
        return names
            .filter { $0.lowercased().hasSuffix(".exe") && $0.caseInsensitiveCompare("steamshim.exe") != .orderedSame }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { (directory as NSString).appendingPathComponent($0) }
            .first(where: isDirectMKXPRGSSGame)
    }

    /// Devuelve el SteamShim hermano que debe iniciar un payload MKXP, solo si ambas partes quedan
    /// verificadas. Así la corrección es automática y portable a cualquier juego con este patrón.
    func steamShimBootstrapper(forPayload executable: String) -> String? {
        guard isDirectMKXPRGSSGame(executable) else { return nil }
        let directory = (executable as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory),
              let shimName = names.first(where: {
                  $0.caseInsensitiveCompare("steamshim.exe") == .orderedSame
              }) else {
            return nil
        }
        let shim = (directory as NSString).appendingPathComponent(shimName)
        return isSteamShimBootstrapper(shim) ? shim : nil
    }

    /// Comprueba que UCRT 2019 no sea el placeholder builtin de Wine. La firma de Microsoft y la
    /// ausencia del marcador del DLL builtin permiten detectar una resincronización del prefijo.
    func hasNativeUCRT2019(in prefix: String) -> Bool {
        let dll = "\(prefix)/drive_c/windows/system32/ucrtbase.dll"
        return isNativeMicrosoftUCRT(dll)
    }

    private func isNativeMicrosoftUCRT(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
            && !exeContains(path, anyOf: ["Wine builtin DLL"])
            && exeContains(path, anyOf: ["Microsoft Corporation"])
    }

    /// Winetricks configura UCRT de forma global. Vessel solo lo necesita para Ruby/MKXP, por lo
    /// que elimina ese override tras extraer el DLL y aplica uno de proceso al lanzar el juego.
    func hasGlobalUCRTOverride(in prefix: String) -> Bool {
        guard let contents = try? String(
            contentsOfFile: "\(prefix)/user.reg",
            encoding: .utf8
        ) else { return false }
        let normalized = contents.lowercased().replacingOccurrences(of: " ", with: "")
        return normalized.contains(#""ucrtbase"="native,builtin""#)
            || normalized.contains(#""*ucrtbase"="native,builtin""#)
            || normalized.contains(#""ucrtbase"="native""#)
            || normalized.contains(#""*ucrtbase"="native""#)
    }

    private func ensureIsolatedMKXPUCRT2019(
        forExecutable executable: String,
        prefix: String,
        wine: String
    ) async -> Bool {
        let fm = FileManager.default
        let systemDLL = "\(prefix)/drive_c/windows/system32/ucrtbase.dll"
        let cacheDirectory = "\(prefix)/.vessel-runtimes/ucrtbase2019/x64"
        let cachedDLL = "\(cacheDirectory)/ucrtbase.dll"

        if !isNativeMicrosoftUCRT(cachedDLL) {
            if !isNativeMicrosoftUCRT(systemDLL) {
                guard await applyWinetricksVerbs(
                    ["ucrtbase2019"],
                    prefix: prefix,
                    wine: wine,
                    force: true
                ) else { return false }

                // El wineserver puede tardar unas décimas en volcar el DLL y el registro después
                // de que termine el script. Esperar de forma asíncrona evita el falso fallo inicial.
                for _ in 0..<20 where !isNativeMicrosoftUCRT(systemDLL) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            guard isNativeMicrosoftUCRT(systemDLL) else { return false }
            do {
                try fm.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)
                try? fm.removeItem(atPath: cachedDLL)
                try fm.copyItem(atPath: systemDLL, toPath: cachedDLL)
            } catch { return false }
        }

        // Elimina las dos formas que pueden escribir distintas versiones de winetricks. Código 1
        // significa simplemente que una de ellas no existía y se acepta deliberadamente.
        for value in ["*ucrtbase", "ucrtbase"] {
            _ = try? await runWine(
                winePath: wine,
                arguments: ["reg", "delete", #"HKCU\Software\Wine\DllOverrides"#, "/v", value, "/f"],
                prefix: prefix,
                environment: ["WINEPREFIX": prefix, "WINEDEBUG": "-all"],
                allowNonZeroExit: true
            )
        }
        for _ in 0..<20 where hasGlobalUCRTOverride(in: prefix) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !hasGlobalUCRTOverride(in: prefix) else { return false }

        let gameDirectory = (executable as NSString).deletingLastPathComponent
        let localDLL = (gameDirectory as NSString).appendingPathComponent("ucrtbase.dll")
        if !isNativeMicrosoftUCRT(localDLL) {
            do {
                try? fm.removeItem(atPath: localDLL)
                try fm.copyItem(atPath: cachedDLL, toPath: localDLL)
            } catch { return false }
        }
        return isNativeMicrosoftUCRT(localDLL)
    }

    /// Los motores SDL2/OpenGL anteriores al soporte HiDPI interpretan las dimensiones
    /// que Wine expone con Retina como píxeles lógicos. Una ventana interna de 1280×720 termina así
    /// ocupando 640×360 puntos y la transformación de entrada puede no coincidir con el framebuffer.
    /// La regla se limita a PE32 OpenGL con referencia SDL2, a la firma completa MKXP/RGSS o al
    /// motor propietario SDL2 + FMOD Studio cuyo árbol de datos confirma su sistema de opciones.
    /// No depende del título ni afecta a Unity/D3D11, GameMaker o motores OpenGL modernos genéricos.
    func usesLegacySDL2OpenGLScaling(_ executable: String) -> Bool {
        let mkxp = isMKXPRGSSGame(executable)
        let contentDrivenFMOD = isLegacyContentDrivenFMODStudioEngine(executable)
        guard detectGraphicsAPI(forExecutable: executable) == .opengl,
              mkxp || contentDrivenFMOD || (isExecutable32Bit(executable)
                && exeContains(executable, anyOf: ["SDL2.dll", "sdl2.dll", "SDL2.DLL"])) else {
            return false
        }
        let directory = (executable as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        return names.contains { $0.caseInsensitiveCompare("SDL2.dll") == .orderedSame }
    }

    /// Firma del motor propietario usado por juegos de Red Hook: PE64 OpenGL/SDL2, audio FMOD
    /// Studio y un árbol de contenido declarativo con órdenes de carga y opciones compartidas.
    /// Esta generación del motor no es HiDPI-aware: con Retina interpreta 3024×1964 píxeles como
    /// puntos y crea una superficie que desborda una pantalla lógica de 1512×982.
    private func isLegacyContentDrivenFMODStudioEngine(_ executable: String) -> Bool {
        let imports = peImportedLibraries(forExecutable: executable)
        guard imports.contains("sdl2.dll"),
              imports.contains("opengl32.dll"),
              imports.contains("fmod64.dll"),
              imports.contains("fmodstudio64.dll") else { return false }

        let fm = FileManager.default
        var root = (executable as NSString).deletingLastPathComponent
        for _ in 0..<4 {
            let audioOrder = "\(root)/audio/base.app.load_order.json"
            let optionDefinitions = "\(root)/shared/options/options.value_definitions.json"
            if fm.fileExists(atPath: audioOrder), fm.fileExists(atPath: optionDefinitions) {
                return true
            }
            let parent = (root as NSString).deletingLastPathComponent
            guard parent != root else { break }
            root = parent
        }
        return false
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
            environment: Self.wineControlEnvironment(prefix: prefix, wine: wine),
            allowNonZeroExit: true
        )
    }

    /// Igual, pero **solo para un `.exe`** (`AppDefaults`): el resto del prefijo conserva su
    /// renderer. Necesario cuando un juego concreto necesita otro backend y comparte prefijo con
    /// juegos que ya funcionan (Portal quiere `gl`; Grim Dawn y compañía siguen con `vulkan`).
    private func setWined3dRenderer(prefix: String, wine: String, renderer: String,
                                    forExecutable exeName: String) async {
        _ = try? await runWine(
            winePath: wine,
            arguments: ["reg", "add", #"HKCU\Software\Wine\AppDefaults\"# + exeName + #"\Direct3D"#,
                        "/v", "renderer", "/t", "REG_SZ", "/d", renderer, "/f"],
            prefix: prefix,
            environment: Self.wineControlEnvironment(prefix: prefix, wine: wine),
            allowNonZeroExit: true
        )
    }

    /// Aísla el backend OpenGL en el ejecutable Playdead detectado. El renderer global del bottle
    /// permanece intacto para que los juegos ya validados sigan usando Vulkan cuando corresponda.
    private func configurePlaydeadLegacyD3D9Renderer(
        prefix: String,
        wine: String,
        executable: String
    ) async {
        guard isPlaydeadLegacyD3D9Engine(executable) else { return }
        await setWined3dRenderer(
            prefix: prefix,
            wine: wine,
            renderer: "gl",
            forExecutable: (executable as NSString).lastPathComponent
        )
        log.log(
            "Motor Playdead D3D9 detectado: wined3d/OpenGL aislado y escala nativa.",
            level: .info
        )
    }

    /// El wrapper DRM clásico extrae el juego real como `popcapgame1.exe` (o uno de sus dos
    /// slots rotatorios). En Vulkan crea la ventana, pero el framebuffer queda negro; OpenGL
    /// renderiza correctamente DirectDraw/D3D8. Las claves se limitan a esos payloads internos.
    private func configureClassicPopCapSteamRenderer(
        prefix: String,
        wine: String,
        executable: String
    ) async {
        guard isClassicPopCapSteamEngine(executable) else { return }
        for payloadName in Self.processFamilyImageNames("popcapgame1.exe") {
            await setWined3dRenderer(
                prefix: prefix,
                wine: wine,
                renderer: "gl",
                forExecutable: payloadName
            )
        }
        log.log(
            "Motor PopCap clásico detectado: wined3d/OpenGL aislado para sus payloads DRM.",
            level: .info
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
    @discardableResult
    private func setMacDriverRetinaMode(prefix: String, wine: String, enabled: Bool) async -> Bool {
        let result = try? await runWine(
            winePath: wine,
            arguments: ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode",
                        "/t", "REG_SZ", "/d", enabled ? "y" : "n", "/f"],
            prefix: prefix,
            environment: Self.wineControlEnvironment(prefix: prefix, wine: wine),
            allowNonZeroExit: true
        )
        if result?.exitCode != 0 {
            log.log(
                "No se pudo aplicar el modo Retina al prefijo activo; Wine devolvió \(result?.exitCode ?? -1).",
                level: .warn
            )
            return false
        }
        return true
    }

    /// Entorno mínimo para comandos de control (`reg`, `wineboot`, etc.). Cuando `wine-full`
    /// ya mantiene vivo el wineserver de Steam, esos comandos deben usar exactamente su mismo
    /// backend de sincronización. Wine rechaza cualquier cliente que llegue sin `WINEMSYNC=1`
    /// (`Server is running with WINEMSYNC but this process is not`), por lo que el registro no se
    /// actualizaba aunque el fallo quedase oculto por ser una operación idempotente. Otros motores
    /// conservan su comportamiento histórico para no arrancar prematuramente un wineserver con un
    /// perfil de sincronización distinto del que elegirá después el juego.
    nonisolated static func wineControlEnvironment(prefix: String, wine: String) -> [String: String] {
        var environment = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "winedbg.exe=d"
        ]
        if WineEngineLocator.isFullEngine(wine)
            || WineEngineLocator.isD3DMetalMediaEngine(wine) {
            environment["WINEMSYNC"] = "1"
            environment["WINEESYNC"] = "1"
            environment["WINEFSYNC"] = "1"
        }
        if WineEngineLocator.isFullEngine(wine) {
            environment["WINESERVER"] = matchingWineserverPath(forWine: wine)
        }
        return environment
    }

    /// Fija el `wineserver` hermano del loader que Vessel ha elegido. Wine suele deducirlo por
    /// su cuenta, pero hacerlo explícito impide que un hijo o una utilidad de control caigan en el
    /// server de otro motor presente en el PATH. No se resuelve el symlink `wine64`: ambos loaders
    /// viven en el mismo `bin`, que es exactamente la identidad de runtime que necesitamos.
    nonisolated static func matchingWineserverPath(forWine wine: String) -> String {
        URL(fileURLWithPath: wine)
            .deletingLastPathComponent()
            .appendingPathComponent("wineserver")
            .path
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
    private func launchD3D12Game(
        executable: String,
        in bottle: Bottle,
        arguments: [String] = [],
        steamAppId: String?,
        effective: EffectiveLaunchConfig = EffectiveLaunchConfig(),
        forceGPTK: Bool = false
    ) async throws -> Process {
        let gameDir = (executable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        // La ruta D3D12 se resolvía antes del preflight común de runtimes. Eso dejaba activo el
        // `mscoree=d` preventivo de GPTK incluso cuando una DLL mixta adyacente lo importaba (4A
        // Enhanced carga BugTrap.dll, que a su vez necesita mscoree), y el loader devolvía 126 antes
        // de crear ventana. El mismo escaneo acotado y estructural del resto de rutas evita depender
        // de títulos y provisiona además cualquier helper DirectX empaquetado que sí corresponda.
        let runtimeDependencies = RuntimeDependencyProvisioner.provision(executable: executable)

        // 1) Motor: por defecto el motor D3DMetal propio (`wine-d3dmetal`, WineHQ 11.10 + D3DMetal
        //    de Apple), que corre D3D12→Metal en Wine MODERNO. EXCEPCIÓN: **Unity 6.x (6000.x+)
        //    que renderiza por D3D11** (no D3D12), o `forceGPTK` → GPTK/D3DMetal (gptk-mythic): su
        //    `d3d11` builtin ES el D3DMetal de Apple, mientras que en wine-d3dmetal el `d3d11` es
        //    DXMT y se CUELGA en la init gráfica de Unity 6 (bucle de IOSurfaces). Es la receta con
        //    la que CrossOver corre Unity 6 + EOS (Dragon Is Dead). Si wine-d3dmetal no está, GPTK
        //    como fallback auto-descargable igualmente.
        let unity6NeedsAppleD3D11 = isUnity6OrNewer(executable)
            && detectGraphicsAPI(forExecutable: executable) != .d3d12
        let needsManagedMedia = requiresManagedD3D12MediaEngine(executable)
        let needsCoherentGPUProbe = requiresCoherentD3DMetalGPUProbeEngine(executable)
        let needsVoidDriverCompatibility = requiresVoidEngineD3DMetalDriverCompatibility(executable)
        let needsStableFourAWindowing = isFourAEnhancedD3D12Engine(executable)
        let needsIsolatedD3DMetalEngine = Self.requiresIsolatedD3DMetalRuntime(
            managedMedia: needsManagedMedia,
            coherentGPUProbe: needsCoherentGPUProbe,
            stableMacFullscreen: needsStableFourAWindowing
        )
        let preferGPTK = !needsIsolatedD3DMetalEngine && (forceGPTK || unity6NeedsAppleD3D11)
        let mediaWine: String?
        if needsIsolatedD3DMetalEngine {
            if needsManagedMedia {
                log.log(
                    "D3D12 + Media Foundation detectado: preparando el motor multimedia aislado…",
                    level: .info
                )
            } else if needsStableFourAWindowing {
                log.log(
                    "4A Enhanced detectado: preparando Wine 11 + D3DMetal aislado para estabilizar sus transiciones de pantalla…",
                    level: .info
                )
            } else {
                log.log(
                    "Sondeo GPU D3D11+D3D12 detectado: preparando un conjunto D3DMetal coherente…",
                    level: .info
                )
            }
            mediaWine = try await dependencyManager.ensureD3DMetalMediaEngine { msg, pct in
                Task { @MainActor in
                    LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info)
                }
            }
        } else {
            mediaWine = nil
        }
        let useD3DMetalEngine = mediaWine != nil
            || (!preferGPTK && WineEngineLocator.isD3DMetalEngineInstalled())
        let d3d12Wine: String
        if let mediaWine {
            d3d12Wine = mediaWine
            log.log(
                needsManagedMedia
                    ? "Motor D3DMetal multimedia listo (Wine 11 FOSS + GStreamer oficial)."
                    : needsStableFourAWindowing
                    ? "Motor D3DMetal 4A aislado listo (Wine 11 FOSS + compositor moderno)."
                    : "Motor D3DMetal aislado listo (D3D11/D3D12/DXGI de Apple).",
                level: .info
            )
        } else if useD3DMetalEngine, let w = WineEngineLocator.d3dmetalWineBinary() {
            log.log("Preparando el motor D3DMetal propio (WineHQ 11.10) para juego D3D12…", level: .info)
            d3d12Wine = w
        } else {
            if unity6NeedsAppleD3D11 {
                log.log("Unity 6.x (D3D11) → GPTK/D3DMetal (gptk-mythic): usa el d3d11 REAL de Apple, no DXMT (que cuelga la init).", level: .info)
            } else if forceGPTK {
                log.log("Preparando GPTK/D3DMetal para juego D3D12 (ruta validada desde Vessel)…", level: .info)
            } else {
                log.log("Preparando GPTK/D3DMetal para juego D3D12…", level: .info)
            }
            try await gptkManager.ensureInstalled { msg, pct in
                Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
            }
            guard var gptkWine = gptkManager.wineBinaryPath else {
                throw WineError.launchFailed("No se pudo localizar el wine de GPTK/D3DMetal.")
            }
            // Unreal (UE4/UE5) MUERE con la variante **mousefix** del GPTK (su `win32u`
            // parcheado a WM_POINTER tumba el proceso antes de crear ventana; verificado con
            // Dwarven Realms, UE5: mousefix muere en <60 s sin dejar log; el motor BASE llega
            // al menú). El mousefix se creó para el ratón de Unity 6 (Dragon Is Dead): ahí se
            // queda — este cambio solo desvía a Unreal al motor base, no toca la ruta Unity.
            if isUnrealGame(executable) {
                let gptkBase = "\(gptkManager.engineRootPath)/wine/bin/wine"
                if FileManager.default.isExecutableFile(atPath: gptkBase) { gptkWine = gptkBase }
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

        // 3) Steamworks: la política ya se resolvió antes de entrar aquí. Los juegos sin protección
        //    adicional conservan Goldberg; Denuvo/VMProtect/Themida/Enigma se desvían previamente al
        //    cliente oficial con su DLL original. Aquí solo se fija el AppID para el runtime elegido.
        if let appId = steamAppId, !appId.isEmpty {
            try? appId.write(toFile: "\(gameDir)/steam_appid.txt", atomically: true, encoding: .utf8)
        }

        // 4) Re-sincronizar el prefijo al motor D3D12 elegido y cerrar cualquier wine previo
        //    (p.ej. el cliente Steam en otro motor). El juego corre solo en D3DMetal.
        log.log("Preparando el prefijo para el motor D3D12…", level: .info)
        try? await terminateWineProcesses(winePath: d3d12Wine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: d3d12Wine)
        await resyncGamePrefix(gameWine: d3d12Wine, prefix: bottle.prefixPath)
        // Esta ruta también puede recibir juegos D3D11 tras un fallback aprendido a GPTK. Escribe
        // SIEMPRE el estado Retina después de sincronizar el prefijo para que no herede la escala
        // del juego anterior. Liquid Engine necesita coordenadas 1×: con Retina convierte el
        // framebuffer físico 3024×1964 en puntos y desborda un escritorio lógico 1512×982.
        // 4A Enhanced crea el contenedor fullscreen con el tamaño del framebuffer físico aunque
        // winemac.drv ya esté trabajando en puntos Retina. En una pantalla 2× eso convierte una
        // ventana de 3024×1964 en 3024×1964 *puntos* sobre un escritorio de 1512×982: durante
        // algunas transiciones solo queda visible un cuadrante. Su huella estructural es la misma
        // que exige DXR, así que la excepción queda aislada de las ramas 4A que aún usan D3D11.
        let isFourAEnhanced = isFourAEnhancedD3D12Engine(executable)
        let requiresOneXWindowCoordinates = isFourAEnhanced
            || GameDisplayStateRepair.requiresOneXWindowCoordinates(
                appId: steamAppId,
                executable: executable
            )
        await setMacDriverRetinaMode(
            prefix: bottle.prefixPath,
            wine: d3d12Wine,
            enabled: requiresOneXWindowCoordinates ? false : effective.retina
        )
        if requiresOneXWindowCoordinates {
            log.log(
                "Motor con coordenadas físicas detectado: escala nativa 1× para mantener ventana e input dentro del escritorio.",
                level: .info
            )
        }
        if let repairArguments = fourAUncleanExitRegistryRepairArguments(
            executable: executable
        ) {
            let repair = try? await runWine(
                winePath: d3d12Wine,
                arguments: repairArguments,
                prefix: bottle.prefixPath,
                environment: Self.wineControlEnvironment(
                    prefix: bottle.prefixPath,
                    wine: d3d12Wine
                ),
                allowNonZeroExit: true
            )
            if repair?.exitCode == 0 {
                log.log(
                    "4A Enhanced: estado de cierre anterior normalizado; se evita el falso diálogo de modo seguro.",
                    level: .info
                )
            } else {
                log.log(
                    "4A Enhanced: no se pudo normalizar el marcador de cierre anterior (Wine: \(repair?.exitCode ?? -1)).",
                    level: .warn
                )
            }
        }
        if needsManagedMedia {
            await enableManagedMediaFoundation(
                for: executable,
                prefix: bottle.prefixPath,
                wine: d3d12Wine
            )
        }

        // 5) Lanzar el juego con el entorno de D3DMetal (del motor propio o de GPTK).
        var env: [String: String]
        if needsIsolatedD3DMetalEngine {
            env = D3DMetalMediaEngineProvisioner.mediaEnvironment(
                winePath: d3d12Wine,
                prefix: bottle.prefixPath
            )
        } else if useD3DMetalEngine {
            env = d3dMetalUnifiedEnvironment(prefix: bottle.prefixPath)
        } else {
            env = gptkManager.d3dMetalEnvironment(prefix: bottle.prefixPath)
        }
        env = Self.environmentByEnablingManagedRuntimeIfNeeded(
            env,
            dependencies: runtimeDependencies
        )
        env = environmentByEnablingRequiredD3DMetalFeatures(
            env,
            executable: executable
        )
        env = Self.environmentByApplyingVoidEngineD3DMetalIdentity(
            env,
            required: needsVoidDriverCompatibility
        )
        if runtimeDependencies.contains(.dotNet) {
            log.log(
                "D3D12: runtime administrado importado por el ejecutable o una DLL del motor; mscoree habilitado de forma aislada.",
                level: .info
            )
        }
        if env["D3DM_SUPPORT_DXR"] == "1" {
            log.log(
                "D3D12: el motor exige DXR; soporte de ray tracing de D3DMetal habilitado automáticamente.",
                level: .info
            )
        }
        if needsVoidDriverCompatibility {
            log.log(
                "Void Engine + D3DMetal: identidad DXGI alineada con el driver virtual del traductor; se evita el falso aviso previo.",
                level: .info
            )
        }
        // Unreal + GPTK: DYLD al `external` del motor BASE (el de mousefix no le sirve).
        // El sync (esync/fsync=0) se pisa más abajo, en el overlay efectivo de launchWineProcess
        // (que si no volvería a activarlos según el perfil). Solo afecta a Unreal.
        if !useD3DMetalEngine, isUnrealGame(executable) {
            env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(gptkManager.engineRootPath)/wine/lib/external"
        }
        if let appId = steamAppId, !appId.isEmpty {
            env["SteamAppId"] = appId
            env["SteamGameId"] = appId
        }
        // 4A Enhanced carga D3D12 y sus módulos de forma dinámica. Los fallos tempranos de su loader
        // devuelven ERROR_MOD_NOT_FOUND (126) sin llegar a crear ventana y no siempre usan la clase
        // `err`; habilitar los canales `module`/`loaddll` completos permite que el LaunchAgent
        // protegido conserve únicamente esas líneas técnicas, sin escribir jamás los tokens
        // efímeros de Epic ni el comando completo.
        if isFourAEnhancedD3D12Engine(executable) {
            env["WINEDEBUG"] = "+module,+loaddll"
        }
        // Unity sobre GPTK/D3DMetal: fullscreen borderless + render MONOHILO (`-force-gfx-direct`),
        // igual que el resto de paths Unity — el fullscreen EXCLUSIVO revienta el swapchain y el
        // multihilo casca en Unity 6 + EOS (Dragon Is Dead). Para D3D12 no-Unity (FFT), vacío.
        let unityArgs = preferGPTK ? unityLaunchArguments(forExecutable: executable, singleThreaded: true) : []
        let engineLbl = needsIsolatedD3DMetalEngine
            ? (needsManagedMedia
                ? "motor D3DMetal multimedia (Wine 11 FOSS)"
                : needsStableFourAWindowing
                ? "motor D3DMetal 4A aislado (Wine 11 FOSS)"
                : "motor D3DMetal aislado (trío gráfico coherente)")
            : (useD3DMetalEngine ? "motor D3DMetal Vessel (WineHQ 11.10)" : "GPTK/D3DMetal")
        log.log("Lanzando juego D3D12 con \(engineLbl): \((executable as NSString).lastPathComponent)", level: .info)
        let processArguments = Self.d3d12ProcessArguments(
            executable: executable,
            engineArguments: unityArgs + unrealEngineArguments(forExecutable: executable),
            resolvedArguments: arguments
        )
        return try await launchWineProcess(
            winePath: d3d12Wine,
            prefix: bottle.prefixPath,
            // `unrealEngineArguments` (`-nohmd`) también aquí: esta ruta arma su propia lista y se
            // saltaba los argumentos del motor. Justo los juegos de UE con D3D12 son los que más lo
            // necesitan — sin él se quedan buscando un visor de VR y no abren (ASTRONEER).
            arguments: processArguments,
            environment: env,
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective,
            enableManagedRuntime: runtimeDependencies.contains(.dotNet),
            d3dMetalGame: useD3DMetalEngine
        )
    }

    /// Lista final de argumentos de la ruta D3D12. `resolvedArguments` ya contiene la petición de
    /// la tienda, el perfil y los ajustes automáticos; recomponerla desde `effective.launchArgs`
    /// descartaba silenciosamente la autenticación de Epic en esta única ruta.
    nonisolated static func d3d12ProcessArguments(
        executable: String,
        engineArguments: [String],
        resolvedArguments: [String]
    ) -> [String] {
        [executable] + engineArguments + resolvedArguments
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
        guard let data = FileManager.default.contents(atPath: logPath) else { return false }
        return SteamConnectionLogState.parseRecent(data) == .connected
    }

    private func steamConnectionLogData(in bottle: Bottle) -> Data {
        let path = "\(bottle.steamDirectory)/logs/connection_log.txt"
        return FileManager.default.contents(atPath: path) ?? Data()
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

    /// Identidad del motor que está sirviendo el prefijo en este instante. `lsof` es la fuente
    /// principal; el marker escrito por `ensurePrefixSyncedToEngine` cubre el breve intervalo en
    /// que Steam está vivo pero macOS todavía no expone descriptores suficientes del wineserver.
    private func currentSteamEngineID(prefix: String) async -> String? {
        if let engine = await Self.liveWineserverEngine(prefix: prefix) {
            return URL(fileURLWithPath: engine).lastPathComponent
        }
        let marker = "\(prefix)/.vessel-prefix-engine"
        return (try? String(contentsOfFile: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cambia de forma explícita entre los dos roles de Steam. Nunca permite que la idempotencia
    /// de `launchSteam` reutilice un wineserver de otro motor: eso hacía que la acción «Abrir Steam»
    /// enfocara el cliente D3DMetal negro y que el siguiente juego chocara con el Gcenx interactivo.
    @discardableResult
    private func transitionSteamClientIfNeeded(
        in bottle: Bottle,
        to wine: String,
        role: SteamClientRole
    ) async -> Bool {
        let running = isWineProcessRunning(matching: "steam.exe", prefix: bottle.prefixPath)
        let targetEngineID = engineID(forWine: wine)
        let currentEngineID = await currentSteamEngineID(prefix: bottle.prefixPath)
        let wrapperInstalled = wrapperInstaller.isInstalled(in: bottle)
        guard Self.shouldRestartSteamClient(
            steamRunning: running,
            currentEngineID: currentEngineID,
            targetEngineID: targetEngineID,
            role: role,
            wrapperInstalled: wrapperInstalled
        ) else { return true }

        let reason = currentEngineID != targetEngineID
            ? "cambio de motor \(currentEngineID ?? "desconocido") → \(targetEngineID)"
            : "cambio de cliente DRM a interfaz interactiva"
        NotificationService.shared.status("Preparando el cliente Steam visible…")
        log.log("Transición de rol Steam: \(reason).", level: .info)
        try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
        try? await Task.sleep(for: .seconds(1))

        let stopped = !isWineProcessRunning(matching: "steam.exe", prefix: bottle.prefixPath)
        if !stopped {
            log.log(
                "Steam sigue ocupado y no pudo completar la transición de rol todavía.",
                level: .warn
            )
        }
        return stopped
    }

    /// Asegura que el cliente Steam está CORRIENDO y **conectado** en `clientWine` (mismo
    /// motor que usará el juego, para compartir wineserver → DRM). Lo arranca si hace falta y
    /// espera hasta `timeoutSeconds` a que el `connection_log` confirme el logon. Devuelve si
    /// llegó a conectar. Con `-tcp` la conexión al CM es estable bajo Wine (el UDP se caía).
    func ensureSteamConnected(in bottle: Bottle, clientWine: String, timeoutSeconds: Int = 90, background: Bool = false) async -> Bool {
        let role: SteamClientRole = background ? .backgroundDRM : .interactive
        guard await transitionSteamClientIfNeeded(in: bottle, to: clientWine, role: role) else {
            NotificationService.shared.status(nil)
            return false
        }
        // No basta con la conexión (login por JWT / backend vivo): para el cliente VISIBLE hay que
        // confirmar además que el CEF creó su ventana. Si no, "conecta" pero el usuario no ve nada.
        // En modo background (DRM) NO se exige ventana (Steam corre sin UI a propósito, `-silent`).
        let interactiveWrapperReady = background || wrapperInstaller.isInstalled(in: bottle)
        if interactiveWrapperReady, isSteamConnected(in: bottle),
           background || steamClientWindowVisible() { return true }
        let initialConnectionData = steamConnectionLogData(in: bottle)
        let initialConnectionState = SteamConnectionLogState.parseRecent(initialConnectionData)
        // `Session Replaced` es terminal para ESTE proceso (`not auto reconnecting` en el log).
        // Reutilizarlo por idempotencia deja para siempre el cliente visible en «SIN CONEXIÓN».
        // Se reinicia únicamente el wineserver de esta botella y con el mismo rol/motor.
        if isWineProcessRunning(matching: "steam.exe", prefix: bottle.prefixPath),
           initialConnectionState == .sessionReplaced {
            NotificationService.shared.status("Reconectando el Steam interno de Vessel…")
            log.log(
                "Steam perdió la sesión porque fue reemplazada; reiniciando únicamente el cliente interno para que vuelva a conectar.",
                level: .warn
            )
            try? await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: clientWine)
            try? await Task.sleep(for: .seconds(1))
        }
        // Si el cliente de ESTE prefijo sigue vivo pero su último estado ya es Access Denied, no
        // esperamos otros 90–120 s por un login que Steam ha rechazado definitivamente.
        if isWineProcessRunning(matching: "steam.exe", prefix: bottle.prefixPath),
           SteamConnectionLogState.parse(initialConnectionData) == .accessDenied {
            handleSteamClientAccessDenied()
            NotificationService.shared.status(nil)
            return false
        }
        // El registro acumula sesiones. Guardar el límite ANTES del nuevo arranque impide aceptar el
        // `Logged On` de ayer durante los segundos en que el cliente actual aún no escribió nada.
        let connectionLogBaseline = initialConnectionData
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
        var lastConnectionState: SteamConnectionLogState = .unknown
        for elapsed in 0..<timeoutSeconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let currentConnectionData = steamConnectionLogData(in: bottle)
            var currentAttemptState = SteamConnectionLogState.parse(
                currentConnectionData,
                afterBaseline: connectionLogBaseline
            )
            // Fallback seguro para ficheros que Steam reescribe internamente sin conservar una
            // frontera byte a byte idéntica: solo se consulta el estado global si el registro ha
            // cambiado DESPUÉS de esta llamada. El `Client version` nuevo deja el estado en
            // `.starting`, por lo que un Logged On histórico no puede satisfacer el intento; el
            // estado solo vuelve a `.connected` cuando aparece el Logged On de esta generación.
            if currentConnectionData != connectionLogBaseline {
                let recentState = SteamConnectionLogState.parseRecent(currentConnectionData)
                if recentState == .connected || recentState == .accessDenied
                    || recentState == .sessionReplaced {
                    currentAttemptState = recentState
                }
            }
            if currentAttemptState != lastConnectionState {
                log.log("Estado Steam CM del intento actual: \(currentAttemptState).", level: .debug)
                lastConnectionState = currentAttemptState
            }
            if currentAttemptState == .accessDenied {
                handleSteamClientAccessDenied()
                NotificationService.shared.status(nil)
                return false
            }
            if currentAttemptState == .sessionReplaced {
                guard restarts < 2 else {
                    log.log("Steam volvió a reemplazar la sesión durante la reconexión.", level: .warn)
                    NotificationService.shared.status(nil)
                    return false
                }
                restarts += 1
                lastRestartElapsed = elapsed
                NotificationService.shared.status("La sesión cambió; reconectando Steam automáticamente…")
                try? await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
                try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: clientWine)
                cleanCEFCache(in: bottle)
                do {
                    _ = try await launchSteam(
                        in: bottle,
                        using: clientWine,
                        background: background
                    )
                } catch {
                    log.log("No se pudo reconectar Steam: \(error.localizedDescription)", level: .error)
                }
                continue
            }
            if currentAttemptState == .connected,
               background || wrapperInstaller.isInstalled(in: bottle),
               background || steamClientWindowVisible() {
                NotificationService.shared.status(nil)
                return true
            }
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
            let connected = currentAttemptState == .connected
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
                try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: clientWine)
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
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: clientWine)
        }
        NotificationService.shared.status(nil)
        let connected = SteamConnectionLogState.parse(
            steamConnectionLogData(in: bottle),
            afterBaseline: connectionLogBaseline
        ) == .connected
        return connected && (background || (
            wrapperInstaller.isInstalled(in: bottle) && steamClientWindowVisible()
        ))
    }

    private func handleSteamClientAccessDenied() {
        if SteamAuthService.storedRefreshMatchesSeededClientSession {
            SteamAuthService.markStoredClientSessionRejectedBySteam()
            log.log("Steam rechazó remotamente la sesión que Vessel sembró; se solicitará una autenticación nueva.", level: .warn)
        } else {
            // ConnectCache puede pertenecer a una sesión creada por el propio cliente Steam y ser
            // distinta del refresh web guardado por Vessel. No atribuirle el rechazo evita destruir
            // una credencial independiente que quizá siga siendo válida.
            log.log("Steam rechazó su sesión interna, pero no coincide con una credencial sembrada por Vessel; se preserva el login de Vessel.", level: .warn)
        }
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
    @discardableResult
    private func maybeSeedSteamSession(in bottle: Bottle, wine: String, force: Bool = false) async -> Bool {
        let hasExistingSession = SteamClientSeeder.shared.hasSeededSession(in: bottle)
        let shouldSeed = SteamAuthService.shouldSeedStoredRefresh(
            hasExistingClientSession: hasExistingSession
        )
        if hasExistingSession, (!force || !shouldSeed) { return true }
        let d = UserDefaults.standard
        let login = d.string(forKey: "steam.accountName") ?? ""
        let token = d.string(forKey: "steam.refreshToken") ?? ""
        let sid = UInt64(d.string(forKey: "steam.steamID64") ?? "") ?? 0
        guard !login.isEmpty, !token.isEmpty, sid > 0 else { return false }
        log.log(hasExistingSession
            ? "Actualizando la sesión del cliente Steam desde el login válido de Vessel…"
            : "Usuario sin sesión en el cliente de Steam; sembrando el auto-login desde el login de Vessel…",
            level: .info)
        let ok = await SteamClientSeeder.shared.seed(login: login, steamID64: sid, personaName: login,
                                                     refreshToken: token, in: bottle, wine: wine)
        log.log(ok ? "Sesión de Steam sembrada ✓ (auto-login sin CEF)." : "No se pudo sembrar la sesión de Steam (se abrirá el login).", level: ok ? .info : .warn)
        return ok
    }

    /// Error accionable cuando falta una credencial SteamClient local vigente. No abrimos el cliente
    /// ni repetimos intentos: ninguna reparación puede sustituir la autorización del usuario.
    private func steamRealReauthenticationRequired(gameExecutable: String) -> WineError {
        let name = ((gameExecutable as NSString).lastPathComponent as NSString).deletingPathExtension
        NotificationService.shared.alert(
            title: "\(name): vuelve a iniciar sesión en Steam",
            body: "Steam ya no acepta la sesión guardada. Inicia sesión una vez desde el botón de Steam de Vessel; después el juego volverá a abrirse automáticamente.")
        log.log("La sesión SteamClient guardada no es utilizable; se detiene el arranque y se solicita una nueva autorización.", level: .warn)
        return WineError.launchFailed("La sesión de Steam ya no es válida. Inicia sesión en Steam desde Vessel y vuelve a pulsar Jugar.")
    }

    /// Prepara en frío el cliente Steam que compartirá wineserver con el juego:
    ///  - registra los appmanifest REALES de SteamCMD antes del arranque;
    ///  - reinicia el cliente si estaba vivo y debe releer un manifiesto o una sesión;
    ///  - solo reemplaza ConnectCache si hay un login CM nuevo pendiente de aplicar.
    /// Nunca escribe la sesión con Steam abierto ni corta una descarga activa.
    private func prepareRealSteamClient(in bottle: Bottle, wine: String,
                                        gameExecutable: String) async throws {
        let newManifests = SteamAppManifestWriter.ensureManifests(in: bottle)
        if newManifests > 0 {
            log.log("Steam real: \(newManifests) manifiesto(s) real(es) registrado(s) antes del arranque.", level: .info)
        }

        let steamWasRunning = isWineProcessRunning(matching: "steam.exe", prefix: bottle.prefixPath)
        let targetEngineID = engineID(forWine: wine)
        let currentEngineID = await currentSteamEngineID(prefix: bottle.prefixPath)
        // Un Steam interactivo Gcenx puede estar conectado y aun así ser inútil para el juego:
        // Steamworks solo cruza procesos del MISMO wineserver. Al volver de una EULA hay que cerrar
        // Gcenx y levantar el cliente background en el motor gráfico exacto del juego.
        let engineChanged = steamWasRunning && currentEngineID != targetEngineID
        let mustRestart = steamWasRunning
            && (engineChanged || newManifests > 0 || !isSteamConnected(in: bottle))
        if mustRestart {
            if engineChanged {
                log.log(
                    "Steam real: restaurando el motor DRM \(targetEngineID) tras el cliente interactivo \(currentEngineID ?? "desconocido").",
                    level: .info
                )
            }
            try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // Si sigue vivo, la protección de descargas evitó cerrarlo. No modificamos su sesión
            // por debajo: se reintentará cuando Steam termine la operación en curso.
            if isWineProcessRunning(matching: "steam.exe", prefix: bottle.prefixPath) {
                throw WineError.launchFailed("Steam está terminando una descarga. Espera a que finalice y vuelve a pulsar Jugar.")
            }
        }

        if !isWineProcessRunning(matching: "steam.exe", prefix: bottle.prefixPath) {
            // `force` no significa «pisar siempre»: `maybeSeedSteamSession` solo reemplaza una
            // sesión existente cuando la huella pendiente procede de un login CM recién completado.
            guard await maybeSeedSteamSession(in: bottle, wine: wine, force: true) else {
                throw steamRealReauthenticationRequired(gameExecutable: gameExecutable)
            }
        }
    }

    /// MODO "STEAM REAL" (nuestro equivalente a CrossOver, invisible): lanza un juego DRM de
    /// Steam con el cliente Steam REAL corriendo y **conectado** en el MISMO motor/wineserver
    /// que el juego, para que `SteamAPI_Init` hable con él (DRM real, como en Windows).
    /// Usa el **motor unificado** (cliente CEF + juego DXMT/Metal en un solo wineserver,
    /// lo que hace CrossOver con su Wine propietario); si no está disponible, cae a
    /// GPTK/D3DMetal (el modelo anterior).
    func launchViaRealSteam(executable: String, in bottle: Bottle, appId: String,
                            launchArguments: [String],
                            effective: EffectiveLaunchConfig = EffectiveLaunchConfig(),
                            steamAppLaunchRequired: Bool = false) async throws -> Process {
        // Validación local segura: JWT vigente, audiencia SteamClient y misma cuenta. La comprobación
        // remota la hará el cliente sobre CM; Steam ya no permite validarla mediante la Web API.
        let hasInternalClientSession = SteamClientSeeder.shared.hasSeededSession(in: bottle)
        let hasUsableSession = hasInternalClientSession
            ? true
            : await SteamAuthService.validateStoredClientSession()
        guard hasUsableSession else {
            throw steamRealReauthenticationRequired(gameExecutable: executable)
        }

        // 1) DRM REAL: restaurar el steam_api ORIGINAL del juego (deshacer Goldberg) + appid.
        goldbergManager.restoreGame(gameExecutable: executable)
        let gameDir = (executable as NSString).deletingLastPathComponent
        try? appId.write(toFile: "\(gameDir)/steam_appid.txt", atomically: true, encoding: .utf8)

        // SteamStub + Virtools clásico: el cliente interno sigue siendo obligatorio para autorizar
        // el ejecutable, pero `-applaunch` abre el splash raíz y no puede transportar el escritorio
        // virtual. Con Steam ya conectado, lanzar el payload directamente en el MISMO wineserver
        // conserva el DRM real y permite crear el modo exclusivo emulado de 800×600.
        if usesProtectedDirectLaunchWithConnectedSteam(executable) {
            guard let fullWine = await fullEngineWineEnsured() else {
                throw WineError.launchFailed("No se encontró el motor completo para el runtime Virtools protegido.")
            }
            try await prepareRealSteamClient(
                in: bottle,
                wine: fullWine,
                gameExecutable: executable
            )
            ensureSteamConfig(in: bottle)
            log.log(
                "Virtools protegido: preparando el cliente Steam interno en el wineserver compartido…",
                level: .info
            )
            let connected = await ensureSteamConnected(
                in: bottle,
                clientWine: fullWine,
                timeoutSeconds: 120,
                background: true
            )
            if !connected {
                if SteamAuthService.storedSessionNeedsReauthentication {
                    throw steamRealReauthenticationRequired(gameExecutable: executable)
                }
                throw steamRealNotConnected(gameExecutable: executable, in: bottle)
            }

            cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
            await setMacDriverRetinaMode(
                prefix: bottle.prefixPath,
                wine: fullWine,
                enabled: false
            )
            ensureClassicVirtoolsDisplaySettings(
                prefix: bottle.prefixPath,
                executable: executable
            )
            var environment = steamClientEnvironment(
                prefix: bottle.prefixPath,
                wine: fullWine
            )
            environment["SteamAppId"] = appId
            environment["SteamGameId"] = appId
            for (key, value) in effective.extraEnv { environment[key] = value }
            log.log(
                "Cliente Steam conectado; lanzando Virtools autorizado en escritorio virtual 800×600.",
                level: .info
            )
            return try await launchWineProcess(
                winePath: fullWine,
                prefix: bottle.prefixPath,
                arguments: [
                    "explorer", "/desktop=VesselVirtools,800x600", executable
                ] + launchArguments,
                environment: environment,
                workingDirectory: gameWorkingDirectory(forExecutable: executable),
                effective: effective,
                forceSyncOn: true,
                forceCleanEnv: true
            )
        }

        // 2) Motor según la API gráfica del juego:
        //    · D3D11 (Unity/Unreal/…) → motor UNIFICADO (DXMT→Metal); cliente y juego en su
        //      wineserver. Es lo que valida Grim Dawn.
        //    · D3D12 (Agility SDK, p. ej. FFT: The Ivalice Chronicles, AppID 1004640) → el
        //      unificado NO lo corre (solo D3D11); va por GPTK/D3DMetal (D3D12→Metal), con el
        //      cliente Steam en el MISMO wineserver de GPTK para el DRM. Se salta la rama unificada.
        let graphicsAPI = detectGraphicsAPI(forExecutable: executable)
        ensureFrozenbyteDisplaySettings(prefix: bottle.prefixPath, executable: executable)
        if Self.shouldUseFullWineForSteamAppLaunch(
            required: steamAppLaunchRequired,
            graphicsAPI: graphicsAPI
        ), let fullWine = await fullEngineWineEnsured() {
            // SteamStub/CEG no debe cruzar motores: `-applaunch` solo llega al cliente que comparte
            // wineserver y wineloader con la orden. Un Steam conectado en wine-full no recibe una
            // segunda instancia enviada desde wine-unified aunque ambos apunten al mismo prefijo.
            // El motor completo aporta además la autodetección de CrossOver para DX9/DX11/DX12.
            try await prepareRealSteamClient(in: bottle, wine: fullWine, gameExecutable: executable)
            ensureSteamConfig(in: bottle)
            log.log(
                "Protección Steam: preparando cliente y juego en el motor completo compartido…",
                level: .info
            )
            let connected = await ensureSteamConnected(
                in: bottle,
                clientWine: fullWine,
                timeoutSeconds: 120,
                background: true
            )
            if !connected {
                if SteamAuthService.storedSessionNeedsReauthentication {
                    throw steamRealReauthenticationRequired(gameExecutable: executable)
                }
                throw steamRealNotConnected(gameExecutable: executable, in: bottle)
            }

            // Un intento anterior por DXMT puede haber dejado DLLs locales que ganarían al backend
            // elegido automáticamente por cxcompatdb. Se retiran antes de que Steam cree el proceso.
            cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
            await configurePlaydeadLegacyD3D9Renderer(
                prefix: bottle.prefixPath,
                wine: fullWine,
                executable: executable
            )
            await configureClassicPopCapSteamRenderer(
                prefix: bottle.prefixPath,
                wine: fullWine,
                executable: executable
            )
            ensureFalcomYsOriginDisplaySettings(
                prefix: bottle.prefixPath,
                executable: executable
            )
            await setMacDriverRetinaMode(
                prefix: bottle.prefixPath,
                wine: fullWine,
                enabled: (usesLegacyD3D9NativeScaling(executable)
                    || isShiningRockDualRendererEngine(executable)) ? false : effective.retina
            )
            if isShiningRockDualRendererEngine(executable) {
                await ensureShiningRockDisplaySettings(prefix: bottle.prefixPath, wine: fullWine)
            }
            log.log(
                "Cliente Steam conectado en wine-full; autorizando y lanzando el AppID protegido.",
                level: .info
            )
            return try await launchThroughConnectedSteamClient(
                executable: executable,
                appId: appId,
                launchArguments: launchArguments,
                bottle: bottle,
                wine: fullWine
            )
        }
        if graphicsAPI == .d3d9, let fullWine = await fullEngineWineEnsured() {
            try await prepareRealSteamClient(in: bottle, wine: fullWine, gameExecutable: executable)
            ensureSteamConfig(in: bottle)
            log.log(
                "Modo Steam real (D3D9 de compatibilidad): preparando el cliente Steam conectado…",
                level: .info
            )
            let connected = await ensureSteamConnected(
                in: bottle,
                clientWine: fullWine,
                timeoutSeconds: 120,
                background: true
            )
            if !connected {
                if SteamAuthService.storedSessionNeedsReauthentication {
                    throw steamRealReauthenticationRequired(gameExecutable: executable)
                }
                throw steamRealNotConnected(gameExecutable: executable, in: bottle)
            }

            dxvkManager.removeGameLocalD3D9(forExecutable: executable)
            cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
            let legacyANGLE = isLegacyANGLE1D3D9Game(executable)
            if legacyANGLE {
                await setWined3dRenderer(
                    prefix: bottle.prefixPath,
                    wine: fullWine,
                    renderer: "gl",
                    forExecutable: (executable as NSString).lastPathComponent
                )
                log.log(
                    "ANGLE 1 legado con Steam real: wined3d/OpenGL aislado por ejecutable.",
                    level: .info
                )
            }
            await configurePlaydeadLegacyD3D9Renderer(
                prefix: bottle.prefixPath,
                wine: fullWine,
                executable: executable
            )
            ensureFalcomYsOriginDisplaySettings(
                prefix: bottle.prefixPath,
                executable: executable
            )
            await setMacDriverRetinaMode(
                prefix: bottle.prefixPath,
                wine: fullWine,
                enabled: usesLegacyD3D9NativeScaling(executable) ? false : effective.retina
            )

            if steamAppLaunchRequired {
                log.log(
                    "SteamStub/CEG D3D9: delegando el arranque al cliente conectado por AppID.",
                    level: .info
                )
                return try await launchThroughConnectedSteamClient(
                    executable: executable,
                    appId: appId,
                    launchArguments: launchArguments,
                    bottle: bottle,
                    wine: fullWine
                )
            }

            var environment = steamClientEnvironment(prefix: bottle.prefixPath, wine: fullWine)
            environment["SteamAppId"] = appId
            environment["SteamGameId"] = appId
            for (key, value) in effective.extraEnv { environment[key] = value }
            log.log(
                "Cliente Steam conectado; lanzando \((executable as NSString).lastPathComponent) con D3D9/wined3d en el mismo wineserver.",
                level: .info
            )
            return try await launchWineProcess(
                winePath: fullWine,
                prefix: bottle.prefixPath,
                arguments: [executable] + launchArguments,
                environment: environment,
                workingDirectory: gameWorkingDirectory(forExecutable: executable),
                effective: effective,
                forceSyncOn: true
            )
        }
        let isD3D12 = graphicsAPI == .d3d12
        if !isD3D12 {
        let isOpenGL = graphicsAPI == .opengl
        if isOpenGL {
            // El motor OpenGL es un clon COW del unificado: en una instalación nueva hay que asegurar
            // primero la base; `ensureUnifiedOpenGLEngine` por sí solo no la descarga.
            try? await dependencyManager.ensureUnifiedEngine { msg, pct in
                Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
            }
            await dependencyManager.ensureUnifiedOpenGLEngine { msg, pct in
                Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
            }
        } else {
            try? await dependencyManager.ensureUnifiedEngine { msg, pct in
                Task { @MainActor in LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info) }
            }
        }
        let candidateWine = isOpenGL
            ? WineEngineLocator.openglGameWineBinary()
            : WineEngineLocator.clientWineBinary()
        if let unifiedWine = candidateWine,
           WineEngineLocator.isUnifiedEngine(unifiedWine) {
            try await prepareRealSteamClient(in: bottle, wine: unifiedWine, gameExecutable: executable)
            ensureSteamConfig(in: bottle)
            log.log(isOpenGL
                ? "Modo Steam real (motor OpenGL compartido): preparando el cliente Steam conectado…"
                : "Modo Steam real (motor unificado): preparando el cliente Steam conectado…",
                level: .info)
            // Cliente en SEGUNDO PLANO (multiproceso `-silent`): loguea por JWT sin ventana ni
            // colgarse (a diferencia del wrapper single-process del CEF). Para el DRM basta con
            // Steam vivo + logueado; la UI no se necesita. Timeout amplio (el login tarda ~45-60s).
            let connected = await ensureSteamConnected(in: bottle, clientWine: unifiedWine, timeoutSeconds: 120, background: true)
            // Sin sesión en Steam no hay DRM: en vez de lanzar el juego (que moriría en
            // silencio → "no abre nada"), AVISAMOS al usuario y dejamos el cliente Steam
            // ABIERTO para que inicie sesión y lo lance desde su biblioteca de Steam (cero
            // fricción, acción clara — como haría CrossOver).
            if !connected {
                if SteamAuthService.storedSessionNeedsReauthentication {
                    throw steamRealReauthenticationRequired(gameExecutable: executable)
                }
                throw steamRealNotConnected(gameExecutable: executable, in: bottle)
            }
            log.log("Cliente Steam conectado; lanzando el juego con DRM real.", level: .info)

            // Juego en el MISMO wineserver que el cliente → la sincronización DEBE coincidir
            // (WINEMSYNC/ESYNC/FSYNC=0). El perfil se pasa para conservar los ajustes detectados,
            // pero `forceSyncOff` tiene precedencia. `forceCleanEnv` rompe la identidad heredada de
            // Vessel sin aislar el wineserver: este depende del prefijo, que sí se conserva.
            await setMacDriverRetinaMode(prefix: bottle.prefixPath, wine: unifiedWine, enabled: effective.retina)
            // Juegos DX11 por DXMT: el `d3d11` builtin del motor ES DXMT, pero muchos juegos
            // compilan shaders con `d3dcompiler_43` (cuyo builtin de Wine importa `wined3d`,
            // ausente en el motor unificado → "Couldn't initialize graphics engine"). Sembramos
            // el d3dcompiler/d3dx9 NATIVO de Microsoft + lo forzamos por override. También
            // dejamos las DLLs de DXMT junto al exe (idempotente). Verificado con Grim Dawn.
            if !isOpenGL {
                ensureNativeShaderCompiler(in: bottle)
                ensureGameDXMTDLLs(gameExecutable: executable, gameWine: unifiedWine)
            }
            if steamAppLaunchRequired {
                log.log("SteamStub/CEG: delegando el arranque al cliente por AppID para que Steam autorice y desempaquete el ejecutable.", level: .info)
                NotificationService.shared.status("Steam conectado. Autorizando y lanzando el juego…")
                let process = try await launchThroughConnectedSteamClient(
                    executable: executable,
                    appId: appId,
                    launchArguments: launchArguments,
                    bottle: bottle,
                    wine: unifiedWine
                )
                NotificationService.shared.status(nil)
                return process
            }
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
            let runtimeOverrides = isOpenGL ? mfOff : "\(Self.shaderCompilerOverrides);\(mfOff)"
            env["WINEDLLOVERRIDES"] = (baseOverrides?.isEmpty == false)
                ? "\(baseOverrides!);\(runtimeOverrides)"
                : runtimeOverrides
            if isOpenGL { env["CX_FWD_COMPAT_GL_CTX"] = "1" }
            for (k, v) in effective.extraEnv { env[k] = v }
            log.log(isOpenGL
                ? "Lanzando \((executable as NSString).lastPathComponent) vía Steam real (OpenGL nativo de Wine→Metal)."
                : "Lanzando \((executable as NSString).lastPathComponent) vía Steam real (motor unificado, DXMT→Metal).",
                level: .info)
            NotificationService.shared.status("Steam conectado. Lanzando el juego…")
            let proc = try await launchWineProcess(
                winePath: unifiedWine,
                prefix: bottle.prefixPath,
                arguments: [executable] + launchArguments,
                environment: env,
                workingDirectory: gameWorkingDirectory(forExecutable: executable),
                effective: effective,
                forceSyncOff: true,
                forceCleanEnv: true
            )
            NotificationService.shared.status(nil)
            return proc
        }
        }   // fin de `if !isD3D12` (rama motor unificado)

        // ── D3D12 + DRM real: PREFERIR el motor D3DMetal apropiado ──
        // Es el UNIFICADO + D3DMetal de Apple: corre el CEF de Steam (login por JWT) Y el juego
        // D3D12 por D3DMetal en el MISMO wineserver — exactamente lo que hace CrossOver. GPTK
        // (abajo) NO corre el CEF moderno (loopback 0x3008/0x3009), así que con él el DRM no podía
        // conectar; por eso este motor es EL correcto para D3D12+Steam. Validado a mano: FFT
        // (AppID 1004640) supera el DRM, carga D3DMetal y renderiza (solo lo frena su anti-tamper
        // Denuvo); juegos D3D12 SIN Denuvo funcionan de principio a fin.
        let needsManagedMedia = isD3D12 && requiresManagedD3D12MediaEngine(executable)
        let needsCoherentGPUProbe = isD3D12
            && requiresCoherentD3DMetalGPUProbeEngine(executable)
        let needsIsolatedD3DMetalEngine = needsManagedMedia || needsCoherentGPUProbe
        let selectedD3DMetalWine: String?
        if needsIsolatedD3DMetalEngine {
            selectedD3DMetalWine = try await dependencyManager.ensureD3DMetalMediaEngine { msg, pct in
                Task { @MainActor in
                    LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info)
                }
            }
        } else {
            selectedD3DMetalWine = WineEngineLocator.d3dmetalWineBinary()
        }
        if isD3D12, let d3dmWine = selectedD3DMetalWine {
            try await prepareRealSteamClient(in: bottle, wine: d3dmWine, gameExecutable: executable)
            ensureSteamConfig(in: bottle)
            let requiresOneXWindowCoordinates = GameDisplayStateRepair
                .requiresOneXWindowCoordinates(appId: appId, executable: executable)
            var oneXRetinaWriteSucceeded = false
            if requiresOneXWindowCoordinates {
                // Se aplica antes de arrancar Steam para que el wineserver no pueda conservar el
                // RetinaMode del juego anterior. En esta build concreta de RE Engine, Retina 2×
                // convierte 2704×1756 en tamaño de ventana y desborda el escritorio.
                oneXRetinaWriteSucceeded = await setMacDriverRetinaMode(
                    prefix: bottle.prefixPath,
                    wine: d3dmWine,
                    enabled: false
                )
            }
            let steamPreparationMessage: String
            if needsManagedMedia {
                steamPreparationMessage = "Modo Steam real (D3DMetal + multimedia): preparando el cliente Steam conectado…"
            } else if needsCoherentGPUProbe {
                steamPreparationMessage = "Modo Steam real (D3DMetal coherente D3D11+D3D12): preparando el cliente Steam conectado…"
            } else {
                steamPreparationMessage = "Modo Steam real (motor D3DMetal): preparando el cliente Steam conectado…"
            }
            log.log(steamPreparationMessage, level: .info)
            // Cliente en 2º plano (multiproceso -silent → loguea por JWT sin ventana). El motor
            // D3DMetal corre el CEF igual que el unificado (WINEMSYNC=0, wrapper SwiftShader).
            let connected = await ensureSteamConnected(in: bottle, clientWine: d3dmWine, timeoutSeconds: 120, background: true)
            if !connected {
                if SteamAuthService.storedSessionNeedsReauthentication {
                    throw steamRealReauthenticationRequired(gameExecutable: executable)
                }
                throw steamRealNotConnected(gameExecutable: executable, in: bottle)
            }
            if needsManagedMedia {
                await enableManagedMediaFoundation(
                    for: executable,
                    prefix: bottle.prefixPath,
                    wine: d3dmWine
                )
            }
            log.log("Cliente Steam conectado; lanzando el juego D3D12 con DRM real (D3DMetal).", level: .info)
            // Que mande el d3d12/dxgi builtin de D3DMetal: quitar del game dir las DLLs de DXMT que
            // un intento previo dejara junto al exe (chocan). NO se toca la subcarpeta D3D12/ (Agility SDK).
            cleanExeAdjacentDXMTDLLs(gameExecutable: executable)
            // Modo Retina para render a resolución física completa en pantallas Retina.
            let retinaWriteSucceeded: Bool
            if requiresOneXWindowCoordinates {
                // Un fallo temprano se reintenta ahora con el wineserver definitivo del cliente.
                if oneXRetinaWriteSucceeded {
                    retinaWriteSucceeded = true
                } else {
                    retinaWriteSucceeded = await setMacDriverRetinaMode(
                        prefix: bottle.prefixPath,
                        wine: d3dmWine,
                        enabled: false
                    )
                }
            } else {
                retinaWriteSucceeded = await setMacDriverRetinaMode(
                    prefix: bottle.prefixPath,
                    wine: d3dmWine,
                    enabled: effective.retina
                )
            }
            if needsManagedMedia {
                let scaleRepair = GameDisplayStateRepair.repairKunitsuGamiForEffectiveRetina(
                    appId: appId,
                    executable: executable,
                    retinaEnabled: !requiresOneXWindowCoordinates
                        && effective.retina
                        && retinaWriteSucceeded
                )
                if scaleRepair.didRepair {
                    log.log(
                        requiresOneXWindowCoordinates
                            ? "Escala nativa 1× de RE Engine aplicada para mantener la ventana dentro del escritorio."
                            : retinaWriteSucceeded
                            ? "Resolución RE Engine sincronizada con el modo Retina efectivo."
                            : "Retina no quedó activo; resolución RE Engine reducida automáticamente para no desbordar la pantalla.",
                        level: requiresOneXWindowCoordinates || retinaWriteSucceeded ? .info : .warn
                    )
                }
            }
            var env = needsIsolatedD3DMetalEngine
                ? D3DMetalMediaEngineProvisioner.mediaEnvironment(
                    winePath: d3dmWine,
                    prefix: bottle.prefixPath
                )
                : d3dMetalUnifiedEnvironment(prefix: bottle.prefixPath)
            env["SteamAppId"] = appId
            env["SteamGameId"] = appId
            for (k, v) in effective.extraEnv { env[k] = v }
            if steamAppLaunchRequired {
                log.log("Protección Steam D3D12: delegando el arranque al cliente por AppID.", level: .info)
                NotificationService.shared.status("Steam conectado. Autorizando y lanzando el juego…")
                let process = try await launchThroughConnectedSteamClient(
                    executable: executable,
                    appId: appId,
                    launchArguments: launchArguments,
                    bottle: bottle,
                    wine: d3dmWine
                )
                NotificationService.shared.status(nil)
                return process
            }
            log.log("Lanzando \((executable as NSString).lastPathComponent) vía Steam real (motor D3DMetal, D3D12→Metal).", level: .info)
            NotificationService.shared.status("Steam conectado. Lanzando el juego…")
            let proc = try await launchWineProcess(
                winePath: d3dmWine,
                prefix: bottle.prefixPath,
                arguments: [executable] + launchArguments,
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
        try await prepareRealSteamClient(in: bottle, wine: gptkWine, gameExecutable: executable)
        ensureSteamConfig(in: bottle)
        log.log("Modo Steam real (GPTK/D3DMetal): preparando el cliente Steam conectado…", level: .info)
        let connected = await ensureSteamConnected(in: bottle, clientWine: gptkWine, timeoutSeconds: 120, background: true)
        if !connected {
            if SteamAuthService.storedSessionNeedsReauthentication {
                throw steamRealReauthenticationRequired(gameExecutable: executable)
            }
            throw steamRealNotConnected(gameExecutable: executable, in: bottle)
        }
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
        if steamAppLaunchRequired {
            log.log("SteamStub/CEG: delegando el arranque al cliente Steam por AppID.", level: .info)
            NotificationService.shared.status("Steam conectado. Autorizando y lanzando el juego…")
            let process = try await launchThroughConnectedSteamClient(
                executable: executable,
                appId: appId,
                launchArguments: launchArguments,
                bottle: bottle,
                wine: gptkWine
            )
            NotificationService.shared.status(nil)
            return process
        }
        log.log("Lanzando \((executable as NSString).lastPathComponent) vía Steam real (GPTK/D3DMetal).", level: .info)
        NotificationService.shared.status("Steam conectado. Lanzando el juego…")
        let proc = try await launchWineProcess(
            winePath: gptkWine,
            prefix: bottle.prefixPath,
            arguments: [executable] + launchArguments,
            environment: env,
            workingDirectory: gameWorkingDirectory(forExecutable: executable),
            effective: effective,
            forceSyncOff: true   // mismo wineserver que el cliente Steam → sync=0 obligatorio
        )
        NotificationService.shared.status(nil)
        return proc
    }

    /// Distingue una orden nueva aceptada por Steam de las entradas históricas del mismo AppID.
    /// El registro puede rotarse entre la captura y la lectura; en ese caso se inspecciona completo.
    nonisolated static func steamAppLaunchAcknowledged(
        in currentLog: Data,
        after baseline: Data,
        appId: String
    ) -> Bool {
        let delta: Data
        if currentLog.count >= baseline.count,
           currentLog.prefix(baseline.count).elementsEqual(baseline) {
            delta = Data(currentLog.dropFirst(baseline.count))
        } else {
            delta = currentLog
        }
        let text = String(decoding: delta, as: UTF8.self)
        let escapedAppId = NSRegularExpression.escapedPattern(for: appId)
        let commandPattern = #"(?i)-applaunch[ \t]+"?"#
            + escapedAppId + #"(?=[" \t,\r\n]|$)"#
        let actionPattern = #"(?i)GameAction[ \t]+\[AppID[ \t]+"#
            + escapedAppId + #"(?=[,\]])"#
        return text.range(of: commandPattern, options: .regularExpression) != nil
            || text.range(of: actionPattern, options: .regularExpression) != nil
    }

    private func steamConsoleLogData(in bottle: Bottle) -> Data {
        FileManager.default.contents(
            atPath: "\(bottle.steamDirectory)/logs/console_log.txt"
        ) ?? Data()
    }

    private func steamWebHelperJavaScriptLogData(in bottle: Bottle) -> Data {
        FileManager.default.contents(
            atPath: "\(bottle.steamDirectory)/logs/webhelper_js.txt"
        ) ?? Data()
    }

    private func steamUIHTMLLogData(in bottle: Bottle) -> Data {
        FileManager.default.contents(
            atPath: "\(bottle.steamDirectory)/logs/steamui_html.txt"
        ) ?? Data()
    }

    private func waitForSteamAppLaunchAcknowledgement(
        supervisor: Process,
        executable: String,
        appId: String,
        bottle: Bottle,
        baseline: Data,
        timeoutSeconds: Int
    ) async -> Bool {
        for elapsed in 0..<timeoutSeconds {
            if Self.steamAppLaunchAcknowledged(
                in: steamConsoleLogData(in: bottle),
                after: baseline,
                appId: appId
            ) {
                return true
            }
            if elapsed.isMultiple(of: 2),
               await isGameProcessFamilyRunning(
                   executable: executable,
                   prefix: bottle.prefixPath
               ) {
                return true
            }
            guard supervisor.isRunning else { return false }
            try? await Task.sleep(for: .seconds(1))
        }
        return Self.steamAppLaunchAcknowledged(
            in: steamConsoleLogData(in: bottle),
            after: baseline,
            appId: appId
        )
    }

    /// Tras aceptar `-applaunch`, Steam todavía puede detenerse en una decisión de UI. Se espera
    /// brevemente al ejecutable real o a esa señal para no confundir «orden recibida» con «juego
    /// arrancado». El supervisor continúa su espera larga si no aparece ninguna de las dos.
    private func waitForSteamBlockingTask(
        supervisor: Process,
        executable: String,
        appId: String,
        bottle: Bottle,
        baseline: Data,
        timeoutSeconds: Int
    ) async -> String? {
        var sustainedWait = SteamGameActionLog.SustainedWaitingTask()
        for elapsed in 0..<timeoutSeconds {
            if elapsed.isMultiple(of: 2),
               await isGameProcessFamilyRunning(
                executable: executable,
                   prefix: bottle.prefixPath
               ) {
                return nil
            }
            let waitingTask = SteamGameActionLog.waitingTask(
                in: steamConsoleLogData(in: bottle),
                after: baseline,
                appId: appId
            )
            // Cuatro muestras a intervalos de un segundo: suficiente para que Steam escriba la
            // continuación automática de `ShowInterstitials`, sin retrasar de forma apreciable una
            // EULA o decisión de hardware que sí permanece bloqueada.
            if let task = sustainedWait.observe(
                waitingTask,
                requiredConsecutiveSamples: 4
            ) {
                return task
            }
            guard supervisor.isRunning else { return nil }
            try? await Task.sleep(for: .seconds(1))
        }
        return SteamGameActionLog.waitingTask(
            in: steamConsoleLogData(in: bottle),
            after: baseline,
            appId: appId
        )
    }

    /// Envía `-applaunch` al Steam Windows conectado. Si un cliente zombi conserva procesos y
    /// sesión pero no acepta la orden, Vessel lo detecta por el registro nuevo, reinicia únicamente
    /// ese prefijo y reintenta una vez. Las descargas activas nunca se interrumpen.
    /// El supervisor vive hasta que termina el ejecutable real para que la UI, las estadísticas,
    /// las copias y «Detener» sigan el juego y no el relé fugaz.
    private func launchThroughConnectedSteamClient(
        executable: String,
        appId: String,
        launchArguments: [String],
        bottle: Bottle,
        wine: String
    ) async throws -> Process {
        guard !appId.isEmpty, appId.allSatisfy(\.isNumber) else {
            throw WineError.launchFailed("Steam devolvió un AppID inválido para el juego protegido.")
        }
        func shq(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        var environment = steamClientEnvironment(prefix: bottle.prefixPath, wine: wine)
        environment["HOME"] = NSHomeDirectory()
        environment["USER"] = NSUserName()
        environment["TMPDIR"] = NSTemporaryDirectory()
        if let root = WineEngineLocator.engineRoot(forWineExecutable: URL(fileURLWithPath: wine)) {
            if environment["DYLD_FALLBACK_LIBRARY_PATH"]?.isEmpty != false {
                environment["DYLD_FALLBACK_LIBRARY_PATH"] = root.appendingPathComponent("lib").path
            }
            environment["WINESERVER"] = root.appendingPathComponent("bin/wineserver").path
        }

        let assignments = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shq($0.value))" }
            .joined(separator: " ")
        let command = ([wine, bottle.steamPath, "-applaunch", appId] + launchArguments)
            .map(shq)
            .joined(separator: " ")
        let imageName = (executable as NSString).lastPathComponent
        let pattern = Self.steamProtectedProcessPattern(imageName)
        // Windows no distingue mayúsculas en nombres de imagen. Steam puede analizar `limbo.exe`
        // y crear `Limbo.exe`; el supervisor debe considerar ambos el mismo proceso.
        let pgrep = Self.caseInsensitivePgrepShellCommand(matchingPattern: pattern)
        let steamDirectory = (bottle.steamPath as NSString).deletingLastPathComponent
        let script = """
        cd \(shq(steamDirectory)) || exit 70
        /usr/bin/env -i \(assignments) \(command)
        launch_status=$?
        appeared=0
        attempt=0
        while [ "$attempt" -lt 120 ]; do
          if \(pgrep) >/dev/null 2>&1; then appeared=1; break; fi
          attempt=$((attempt + 1))
          sleep 1
        done
        if [ "$appeared" -ne 1 ]; then exit "$launch_status"; fi
        while \(pgrep) >/dev/null 2>&1; do sleep 2; done
        """

        let logDirectory = "\(NSHomeDirectory())/Library/Logs/Vessel"
        try? FileManager.default.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)
        let logPath = "\(logDirectory)/steam-protected-launch.log"

        func makeSupervisor() throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]
            process.environment = [
                "HOME": NSHomeDirectory(),
                "USER": NSUserName(),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ]
            FileManager.default.createFile(atPath: logPath, contents: nil)
            if launchArguments.contains(where: Self.isSensitiveLaunchArgument) {
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
            } else if let handle = FileHandle(forWritingAtPath: logPath) {
                process.standardOutput = handle
                process.standardError = handle
            }
            do {
                try process.run()
                return process
            } catch {
                throw WineError.launchFailed(
                    "No se pudo solicitar el juego al cliente Steam: \(error.localizedDescription)"
                )
            }
        }

        let baseline = steamConsoleLogData(in: bottle)
        let firstSupervisor = try makeSupervisor()
        let firstAcknowledged = await waitForSteamAppLaunchAcknowledgement(
            supervisor: firstSupervisor,
            executable: executable,
            appId: appId,
            bottle: bottle,
            baseline: baseline,
            timeoutSeconds: 20
        )
        if firstAcknowledged {
            let blockingTask = await waitForSteamBlockingTask(
                supervisor: firstSupervisor,
                executable: executable,
                appId: appId,
                bottle: bottle,
                baseline: baseline,
                timeoutSeconds: 20
            )
            guard blockingTask?.caseInsensitiveCompare("ShowInterstitials") == .orderedSame else {
                return firstSupervisor
            }

            // El único interstitial no vinculante que Vessel puede resolver automáticamente es
            // «mando recomendado». Se registra como visto por AppID usando las mismas claves de
            // Steam y se reintenta una sola vez. Si el bloqueo persiste era un requisito real.
            log.log(
                "Steam mostró un aviso previo de hardware; preparando automáticamente el aviso informativo de mando recomendado para \(appId).",
                level: .info
            )
            NotificationService.shared.status("Preparando el juego para teclado y mando…")
            defer { NotificationService.shared.status(nil) }
            if firstSupervisor.isRunning { firstSupervisor.terminate() }
            try? await Task.sleep(for: .milliseconds(300))
            try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
            try? await Task.sleep(for: .seconds(1))

            guard !isWineProcessRunning(matching: "steam.exe", prefix: bottle.prefixPath) else {
                throw WineError.launchFailed(
                    "Steam sigue cerrando el aviso anterior. Espera un momento y vuelve a pulsar Jugar."
                )
            }
            let preference = SteamClientPreferences.markGamepadRecommendationSeen(
                appId: appId,
                inSteamDirectory: bottle.steamDirectory
            )
            guard preference.filesUpdated > 0 else {
                if preference.filesAlreadyConfigured > 0 {
                    throw WineError.launchFailed(
                        "Steam necesita una confirmación obligatoria de hardware para este juego; no se aceptará automáticamente."
                    )
                }
                throw WineError.launchFailed(
                    "Steam no encontró el perfil local donde guardar su aviso de mando recomendado."
                )
            }

            log.log(
                "Aviso GamepadRecommended registrado para \(appId) en \(preference.filesUpdated) perfil(es) Steam; reconectando y reintentando.",
                level: .info
            )
            let connected = await ensureSteamConnected(
                in: bottle,
                clientWine: wine,
                timeoutSeconds: 120,
                background: true
            )
            guard connected else {
                throw WineError.launchFailed(
                    "Steam no recuperó su conexión después de preparar el aviso de mando."
                )
            }

            let retryBaseline = steamConsoleLogData(in: bottle)
            let retrySupervisor = try makeSupervisor()
            guard await waitForSteamAppLaunchAcknowledgement(
                supervisor: retrySupervisor,
                executable: executable,
                appId: appId,
                bottle: bottle,
                baseline: retryBaseline,
                timeoutSeconds: 30
            ) else {
                if retrySupervisor.isRunning { retrySupervisor.terminate() }
                throw WineError.launchFailed(
                    "Steam no aceptó el reintento automático del juego."
                )
            }
            if let retryBlock = await waitForSteamBlockingTask(
                supervisor: retrySupervisor,
                executable: executable,
                appId: appId,
                bottle: bottle,
                baseline: retryBaseline,
                timeoutSeconds: 20
            ), retryBlock.caseInsensitiveCompare("ShowInterstitials") == .orderedSame {
                if retrySupervisor.isRunning { retrySupervisor.terminate() }
                throw WineError.launchFailed(
                    "Steam requiere un mando, VR u otra decisión de hardware obligatoria para este juego."
                )
            }
            log.log("Steam superó automáticamente el aviso de mando para \(appId).", level: .info)
            return retrySupervisor
        }

        if await steamHasActiveDownloads(prefix: bottle.prefixPath, gameWine: wine) {
            log.log(
                "Steam no confirmó -applaunch, pero mantiene una descarga: se preserva el cliente.",
                level: .warn
            )
            return firstSupervisor
        }

        log.log(
            "Steam no aceptó -applaunch en 20 s; reinicio aislado del cliente y reintento único.",
            level: .warn
        )
        NotificationService.shared.status(
            "Steam no responde; reiniciándolo automáticamente…"
        )
        defer { NotificationService.shared.status(nil) }
        if firstSupervisor.isRunning { firstSupervisor.terminate() }
        try? await Task.sleep(for: .milliseconds(300))
        try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
        try? await Task.sleep(for: .seconds(1))

        let connected = await ensureSteamConnected(
            in: bottle,
            clientWine: wine,
            timeoutSeconds: 120,
            background: true
        )
        guard connected else {
            throw WineError.launchFailed(
                "Steam no recuperó su conexión después del reinicio automático."
            )
        }

        let retryBaseline = steamConsoleLogData(in: bottle)
        let retrySupervisor = try makeSupervisor()
        guard await waitForSteamAppLaunchAcknowledgement(
            supervisor: retrySupervisor,
            executable: executable,
            appId: appId,
            bottle: bottle,
            baseline: retryBaseline,
            timeoutSeconds: 30
        ) else {
            if retrySupervisor.isRunning { retrySupervisor.terminate() }
            throw WineError.launchFailed(
                "Steam siguió sin aceptar la orden del juego tras el reinicio automático."
            )
        }
        return retrySupervisor
    }

    /// Abre el cliente Steam visible con el motor Gcenx validado para CEF. El rol interactivo está
    /// aislado de los motores de juego: antes de un lanzamiento protegido, Vessel cambia de nuevo al
    /// motor gráfico exacto del título para compartir allí su wineserver con el backend DRM.
    /// EXPERIMENTAL — Sincroniza la partida con la NUBE de Steam para el **Modo Vessel** (el juego se
    /// juega con el motor gráfico ÓPTIMO, no bajo el cliente). VALIDADO empíricamente (spike con Grim
    /// Dawn): arrancar el cliente Steam headless dispara su **AutoCloud REAL** — evalúa todos los juegos
    /// propios, descarga lo nuevo de la nube y sube lo cambiado (el `cloud_log.txt` del cliente lo
    /// confirma: "Starting sync (eval)", "File is in sync …player.gdc", "YldWriteCacheDirectoryToFile").
    /// Aquí solo se asegura el cliente conectado en 2º plano (`-silent`, sin ventana); su AutoCloud hace
    /// el resto. Degrada en SILENCIO si no hay login/cliente; el backup local (`SaveBackupManager`) es
    /// SIEMPRE la red de seguridad. Se llama antes de jugar (baja lo último) y al salir (sube la sesión).
    func syncSteamCloud(appId: String, in bottle: Bottle) async {
        guard !appId.isEmpty else { return }
        let clientWine = WineEngineLocator.fullWineBinaryForSteamClient()
            ?? WineEngineLocator.steamDedicatedWineBinary()
            ?? resolveClientWine(for: bottle)
        let ok = await ensureSteamConnected(in: bottle, clientWine: clientWine, timeoutSeconds: 90, background: true)
        if ok || isWineProcessRunning(matching: "steam.exe") {
            log.log("Steam Cloud (Modo Vessel): cliente conectado en 2º plano; AutoCloud sincroniza la nube del juego \(appId).", level: .info)
        } else {
            log.log("Steam Cloud: el cliente no se conectó (¿sin sesión de Steam iniciada?); se omite la nube. El backup local protege la partida.", level: .info)
        }
    }

    /// Abre el rol interactivo de Steam. Si `requestingAppId` está presente, vuelve a enviar la
    /// orden oficial `-applaunch` una vez que la interfaz ya es visible, para que Steam muestre la
    /// EULA pendiente dentro de ese cliente en vez de dejarla atrapada en el backend negro de DRM.
    func openSteamClient(
        in bottle: Bottle,
        requestingAppId: String? = nil,
        resumeAfterEULAAcceptance: NotificationService.SteamAuthorizationResumption? = nil
    ) async {
        // Serialización: si otro flujo (p. ej. "Iniciar sesión" de la vista) ya está
        // preparando Steam, esperar y reutilizar en vez de pisarnos los procesos.
        let isOwner = await acquireSteamFlowTurn()
        defer { if isOwner { Self.steamFlowActive = false } }
        if !isOwner {
            let wine = WineEngineLocator.interactiveSteamWineBinary()
                ?? resolveClientWine(for: bottle)
            let ok = await ensureSteamConnected(in: bottle, clientWine: wine)
            if ok, let appId = requestingAppId {
                await requestSteamAuthorizationUI(
                    appId: appId,
                    in: bottle,
                    wine: wine,
                    resumeAfterEULAAcceptance: resumeAfterEULAAcceptance
                )
            }
            log.log(ok ? "Steam abierto y conectado ✓" : "Steam abierto (la conexión se confirmará al iniciar sesión).", level: ok ? .info : .warn)
            return
        }

        // 1) Motor del rol INTERACTIVO: Gcenx exacto. El unificado y D3DMetal se conservan para
        // juegos/DRM, pero no se usan para UI: el primero reinicia CEF con 0x80000003 y el segundo
        // crea una superficie negra. Gcenx + software compositor quedó validado por el usuario.
        let wine: String
        do {
            wine = try await dependencyManager.ensureInteractiveSteamEngineInstalled { msg, pct in
                Task { @MainActor in
                    LogStore.shared.log("\(msg) (\(Int(pct * 100))%)", level: .info)
                }
            }
        } catch {
            log.log(
                "No se pudo preparar el cliente Steam visible: \(error.localizedDescription)",
                level: .error
            )
            NotificationService.shared.alert(
                title: "No se pudo abrir Steam",
                body: "Vessel no pudo preparar su motor interactivo. No se ha abierto un cliente negro ni incompleto; revisa los registros y vuelve a intentarlo."
            )
            return
        }
        log.log("Abriendo Steam interactivo con Gcenx y composición por software.", level: .info)

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
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
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
                try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
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
        if newManifests > 0,
           isWineProcessRunning(matching: "steam.exe", prefix: bottle.prefixPath) {
            log.log("Reiniciando Steam para que recoja los \(newManifests) juego(s) recién marcados como instalados…", level: .info)
            try? await terminateWineProcesses(winePath: wine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: wine)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // 5) Arrancar y esperar conexión (idempotente si ya corre).
        log.log("Abriendo el cliente Steam completo para gestionar la cuenta y la biblioteca.", level: .info)
        let ok = await ensureSteamConnected(in: bottle, clientWine: wine, timeoutSeconds: 90)
        if ok, let appId = requestingAppId {
            await requestSteamAuthorizationUI(
                appId: appId,
                in: bottle,
                wine: wine,
                resumeAfterEULAAcceptance: resumeAfterEULAAcceptance
            )
        }
        log.log(ok ? "Steam abierto y conectado ✓" : "Steam abierto (la conexión se confirmará al iniciar sesión).", level: ok ? .info : .warn)
    }

    /// Reproduce la orden que quedó detenida en `ShowEula`, ahora dentro del cliente interactivo.
    /// Solo muestra el flujo oficial de Steam; Vessel no acepta ni modifica la licencia. No da el
    /// trabajo por terminado hasta que `webhelper_js.txt` confirma que SteamUI renderizó el prompt.
    private func requestSteamAuthorizationUI(
        appId: String,
        in bottle: Bottle,
        wine: String,
        resumeAfterEULAAcceptance: NotificationService.SteamAuthorizationResumption?
    ) async {
        guard !appId.isEmpty, appId.allSatisfy(\.isNumber) else {
            log.log("AppID inválido al solicitar la autorización de Steam: \(appId)", level: .warn)
            return
        }
        Self.steamAuthorizationMonitor?.cancel()

        let consoleBaseline = steamConsoleLogData(in: bottle)
        let promptBaseline = steamWebHelperJavaScriptLogData(in: bottle)
        NotificationService.shared.status("Abriendo la licencia pendiente en Steam…")
        do {
            try await sendSteamAuthorizationRequest(appId: appId, in: bottle, wine: wine)
        } catch {
            log.log(
                "No se pudo abrir la licencia de Steam para \(appId): \(error.localizedDescription)",
                level: .error
            )
            NotificationService.shared.status(nil)
            return
        }

        let rendered = await waitForSteamEULAPrompt(
            appId: appId,
            in: bottle,
            after: promptBaseline,
            timeoutSeconds: 30
        )
        NotificationService.shared.status(nil)
        guard rendered else {
            log.log(
                "Steam aceptó la orden de \(appId), pero su interfaz no confirmó que el EULA fuese visible.",
                level: .warn
            )
            NotificationService.shared.alert(
                title: "Steam no mostró la licencia",
                body: "Vessel no detectó ningún diálogo visible y no afirmará que puedes aceptarlo. Vuelve a pulsar «Abrir Steam» para reintentarlo."
            )
            return
        }

        log.log(
            "SteamUI confirmó en pantalla el EULA de \(appId). Se supervisará su interfaz por si el webhelper se reinicia.",
            level: .info
        )
        let uiBaseline = steamUIHTMLLogData(in: bottle)
        let webBaseline = steamWebHelperJavaScriptLogData(in: bottle)
        // Captura fuerte deliberada: esta instancia suele nacer en la acción de una alerta y se
        // liberaría al retornar `openSteamClient`; el monitor debe sobrevivir mientras el acuerdo
        // siga pendiente. La siguiente solicitud cancela y reemplaza esta tarea estática.
        Self.steamAuthorizationMonitor = Task { @MainActor in
            await self.maintainSteamAuthorizationUI(
                appId: appId,
                in: bottle,
                wine: wine,
                consoleBaseline: consoleBaseline,
                acceptanceBaseline: promptBaseline,
                webBaseline: webBaseline,
                uiBaseline: uiBaseline,
                resumeAfterEULAAcceptance: resumeAfterEULAAcceptance
            )
        }
    }

    private func sendSteamAuthorizationRequest(
        appId: String,
        in bottle: Bottle,
        wine: String
    ) async throws {
        _ = try await launchWineProcess(
            winePath: wine,
            prefix: bottle.prefixPath,
            arguments: [bottle.steamPath, "-applaunch", appId],
            environment: steamClientEnvironment(prefix: bottle.prefixPath, wine: wine),
            workingDirectory: (bottle.steamPath as NSString).deletingLastPathComponent
        )
        log.log(
            "Steam interactivo recibió -applaunch \(appId) para mostrar la licencia pendiente.",
            level: .info
        )
    }

    private func waitForSteamEULAPrompt(
        appId: String,
        in bottle: Bottle,
        after baseline: Data,
        timeoutSeconds: Int
    ) async -> Bool {
        for _ in 0..<timeoutSeconds {
            if SteamAuthorizationLog.eulaPromptRendered(
                in: steamWebHelperJavaScriptLogData(in: bottle),
                after: baseline,
                appId: appId
            ) {
                return true
            }
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .seconds(1))
        }
        return SteamAuthorizationLog.eulaPromptRendered(
            in: steamWebHelperJavaScriptLogData(in: bottle),
            after: baseline,
            appId: appId
        )
    }

    /// El CEF single-process de Steam puede auto-reiniciarse después de mostrar una autorización.
    /// Steam conserva el backend en `ShowEula`, pero no reconstruye el modal. Si ocurre, Vessel
    /// espera a que la nueva SteamUI esté lista y reenvía la orden oficial. Nunca pulsa ni decide.
    private func maintainSteamAuthorizationUI(
        appId: String,
        in bottle: Bottle,
        wine: String,
        consoleBaseline: Data,
        acceptanceBaseline: Data,
        webBaseline initialWebBaseline: Data,
        uiBaseline initialUIBaseline: Data,
        resumeAfterEULAAcceptance: NotificationService.SteamAuthorizationResumption?
    ) async {
        var webBaseline = initialWebBaseline
        var uiBaseline = initialUIBaseline

        for recovery in 1...4 {
            var restarted = false
            for _ in 0..<150 {
                guard !Task.isCancelled else { return }
                if SteamAuthorizationLog.eulaAccepted(
                    in: steamWebHelperJavaScriptLogData(in: bottle),
                    after: acceptanceBaseline,
                    appId: appId
                ) {
                    log.log("SteamUI confirmó la aceptación del EULA de \(appId).", level: .info)
                    if let resumeAfterEULAAcceptance {
                        NotificationService.shared.status(
                            "Licencia aceptada. Preparando el motor correcto del juego…"
                        )
                        await resumeAfterEULAAcceptance()
                        NotificationService.shared.status(nil)
                    }
                    return
                }
                if SteamAuthorizationLog.eulaResolved(
                    in: steamConsoleLogData(in: bottle),
                    after: consoleBaseline,
                    appId: appId
                ) {
                    log.log("Steam registró la respuesta del usuario al EULA de \(appId).", level: .info)
                    return
                }
                let liveSteamEngineID = await currentSteamEngineID(prefix: bottle.prefixPath)
                guard isWineProcessRunning(
                    matching: "steam.exe",
                    prefix: bottle.prefixPath
                ), liveSteamEngineID == engineID(forWine: wine)
                else { return }

                if SteamAuthorizationLog.webHelperRestarted(
                    in: steamUIHTMLLogData(in: bottle),
                    after: uiBaseline
                ) {
                    restarted = true
                    break
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard restarted, !Task.isCancelled else { return }

            log.log(
                "SteamUI se reinició con un EULA pendiente; esperando su nueva interfaz para restaurar el diálogo (\(recovery)/4).",
                level: .warn
            )
            var ready = false
            for _ in 0..<45 {
                guard !Task.isCancelled else { return }
                if SteamAuthorizationLog.steamUIReady(
                    in: steamWebHelperJavaScriptLogData(in: bottle),
                    after: webBaseline
                ) {
                    ready = true
                    break
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard ready,
                  !SteamAuthorizationLog.eulaAccepted(
                    in: steamWebHelperJavaScriptLogData(in: bottle),
                    after: acceptanceBaseline,
                    appId: appId
                  ),
                  !SteamAuthorizationLog.eulaResolved(
                    in: steamConsoleLogData(in: bottle),
                    after: consoleBaseline,
                    appId: appId
                  ),
                  isSteamConnected(in: bottle)
            else { return }

            let retryPromptBaseline = steamWebHelperJavaScriptLogData(in: bottle)
            do {
                NotificationService.shared.status("Restaurando la licencia pendiente en Steam…")
                try await sendSteamAuthorizationRequest(appId: appId, in: bottle, wine: wine)
            } catch {
                NotificationService.shared.status(nil)
                log.log(
                    "No se pudo restaurar el diálogo legal tras reiniciarse SteamUI: \(error.localizedDescription)",
                    level: .error
                )
                return
            }

            let rendered = await waitForSteamEULAPrompt(
                appId: appId,
                in: bottle,
                after: retryPromptBaseline,
                timeoutSeconds: 30
            )
            NotificationService.shared.status(nil)
            guard rendered else {
                log.log(
                    "SteamUI volvió, pero no confirmó la restauración visible del EULA de \(appId).",
                    level: .warn
                )
                return
            }

            log.log(
                "EULA de \(appId) restaurado en la interfaz después del reinicio de SteamUI.",
                level: .info
            )
            webBaseline = steamWebHelperJavaScriptLogData(in: bottle)
            uiBaseline = steamUIHTMLLogData(in: bottle)
        }
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
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: clientWine)
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
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: clientWine)
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

    /// Variante acotada a un prefijo Wine. Evita confundir el Steam de otro bottle —o cualquier
    /// proceso nativo con un nombre parecido— con el cliente que debe compartir wineserver con este
    /// juego. `lsof` es la fuente de verdad porque Wine reescribe el argv a una ruta de Windows y ya
    /// no deja `WINEPREFIX` visible en la línea de comandos. Siempre se ejecuta sin resolución de
    /// nombres y en formato de campos: el formato tabular por defecto puede bloquearse durante
    /// minutos intentando resolver los recursos abiertos por Steam/CEF bajo Wine.
    nonisolated static func lsofProcessLookupArguments(processID: pid_t) -> [String] {
        ["-nP", "-a", "-p", String(processID), "-Fn"]
    }

    /// Argumentos comunes para localizar una imagen Wine. `-i` conserva la semántica de nombres
    /// de Windows aunque el argv que publica Wine use otra capitalización que el fichero analizado.
    nonisolated static func pgrepProcessLookupArguments(matching pattern: String) -> [String] {
        ["-i", "-f", NSRegularExpression.escapedPattern(for: pattern)]
    }

    private nonisolated static func wineProcessIDs(
        matching pattern: String,
        prefix: String,
        executableDirectory: String? = nil
    ) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = pgrepProcessLookupArguments(matching: pattern)
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return [] }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        pgrep.waitUntilExit()

        var result: [pid_t] = []
        for line in output.split(whereSeparator: { $0.isWhitespace }) {
            guard let pid = Int32(line) else { continue }
            let lsof = Process()
            lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsof.arguments = lsofProcessLookupArguments(processID: pid)
            let files = Pipe()
            lsof.standardOutput = files
            lsof.standardError = FileHandle.nullDevice
            guard (try? lsof.run()) != nil else { continue }
            let listing = String(data: files.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            lsof.waitUntilExit()
            guard listing.contains(prefix) else { continue }
            if let executableDirectory, !listing.contains(executableDirectory) { continue }
            result.append(pid)
        }
        return result
    }

    /// `pgrep` + `lsof` pueden tardar cientos de milisegundos con runtimes Chromium. Nunca deben
    /// ejecutarse en el actor principal: el sondeo de vida es frecuente mientras el juego está
    /// abierto y bloquearía animaciones, accesibilidad y entrada de la app.
    private nonisolated static func gameWineProcessIDs(
        matching pattern: String,
        prefix: String,
        executableDirectory: String?
    ) async -> [pid_t] {
        await Task.detached(priority: .utility) {
            wineProcessIDs(
                matching: pattern,
                prefix: prefix,
                executableDirectory: executableDirectory
            )
        }.value
    }

    /// Steam puede resolver una opción de lanzamiento distinta de la que Vessel analizó. En
    /// títulos duales el manifiesto suele ofrecer `x32` y `x64`, y `-applaunch` elige una según el
    /// sistema. Ambas imágenes pertenecen al mismo juego y deben compartir estado, ventana y cierre.
    nonisolated static func processFamilyImageNames(_ executableName: String) -> [String] {
        guard !executableName.isEmpty else { return [] }
        if executableName.range(
            of: #"^popcapgame[1-3]\.exe$"#,
            options: [.caseInsensitive, .regularExpression]
        ) != nil {
            return ["popcapgame1.exe", "popcapgame2.exe", "popcapgame3.exe"]
        }
        var names = [executableName]
        for architecture in ["x32", "x64"] {
            guard let range = executableName.range(
                of: architecture,
                options: [.caseInsensitive, .backwards]
            ) else { continue }
            let siblingArchitecture = architecture == "x32" ? "x64" : "x32"
            let sibling = String(executableName[..<range.lowerBound])
                + siblingArchitecture
                + String(executableName[range.upperBound...])
            if !names.contains(where: { $0.caseInsensitiveCompare(sibling) == .orderedSame }) {
                names.append(sibling)
            }
            break
        }
        return names
    }

    /// Imágenes que forman una única sesión jugable para un ejecutable concreto. Mantiene las
    /// variantes de arquitectura existentes y añade el payload declarado por el launcher cuando
    /// el contrato XML/x64 ha sido validado. El orden conserva primero el ejecutable solicitado.
    nonisolated func trackedProcessFamilyImageNames(forExecutable executable: String) -> [String] {
        let launcherName = (executable as NSString).lastPathComponent
        var names = Self.processFamilyImageNames(launcherName)
        if let payload = declaredX64PayloadExecutable(forExecutable: executable) {
            for candidate in Self.processFamilyImageNames((payload as NSString).lastPathComponent)
            where !names.contains(where: {
                $0.caseInsensitiveCompare(candidate) == .orderedSame
            }) {
                names.append(candidate)
            }
        }
        return names
    }

    /// Patrón del supervisor launchd que sobrevive a un handoff launcher→payload sin coincidir con
    /// su propia orden `pgrep`. Cada alternativa se autoexcluye de forma independiente.
    nonisolated func launchSupervisorProcessPattern(forExecutable executable: String) -> String {
        let patterns = trackedProcessFamilyImageNames(forExecutable: executable)
            .map(Self.selfExcludingProcessPattern)
        guard let first = patterns.first else { return Self.selfExcludingProcessPattern("wine") }
        return patterns.count == 1 ? first : "(" + patterns.joined(separator: "|") + ")"
    }

    /// Obtiene la unión exacta de PIDs de todas las variantes oficiales de una misma imagen. La
    /// comprobación sigue acotada por prefijo y directorio abierto mediante `lsof`.
    private nonisolated static func gameWineProcessFamilyIDs(
        imageNames: [String],
        prefix: String,
        executableDirectory: String?
    ) async -> [pid_t] {
        return await Task.detached(priority: .utility) {
            var identifiers = Set<pid_t>()
            for candidate in imageNames {
                identifiers.formUnion(wineProcessIDs(
                    matching: candidate,
                    prefix: prefix,
                    executableDirectory: executableDirectory
                ))
            }
            return identifiers.sorted()
        }.value
    }

    private func isWineProcessRunning(matching pattern: String, prefix: String) -> Bool {
        !Self.wineProcessIDs(matching: pattern, prefix: prefix).isEmpty
    }

    /// Vida real de un juego Wine multiproceso, acotada por nombre de imagen Y por archivos abiertos
    /// dentro de su prefijo. Evita confundir un launcher que terminó con el cierre del juego, y evita
    /// a la vez atribuir procesos de otro bottle o del Steam nativo de macOS.
    nonisolated func isGameProcessFamilyRunning(executable: String, prefix: String) async -> Bool {
        let imageNames = trackedProcessFamilyImageNames(forExecutable: executable)
        let executableDirectory = processTrackingDirectory(forExecutable: executable)
        guard !imageNames.isEmpty else { return false }
        return !(await Self.gameWineProcessFamilyIDs(
            imageNames: imageNames,
            prefix: prefix,
            executableDirectory: executableDirectory
        )).isEmpty
    }

    /// Determina si CoreGraphics describe una superficie grande y visible cuyo propietario es uno
    /// de los procesos exactos del juego. No se restringe a la capa 0: Wine publica algunos juegos
    /// a pantalla completa en capas elevadas (Project Zomboid usa la 21) aunque sean ventanas reales,
    /// interactivas y del PID correcto. El PID ya está acotado por ejecutable y prefijo mediante
    /// `lsof`, por lo que aceptar su superficie no puede atribuir una ventana de otro juego.
    nonisolated static func isUsableGameWindow(
        _ window: [String: Any],
        ownedBy processIDs: Set<pid_t>
    ) -> Bool {
        guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
              processIDs.contains(ownerPID),
              (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any] else {
            return false
        }
        let title = (window[kCGWindowName as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let diagnosticMarkers = [
            "unhandled exception",
            "exception raised",
            "program error",
            "wine debugger",
            "fatal error",
            "error initializing"
        ]
        if diagnosticMarkers.contains(where: title.contains)
            || title == "console"
            || title.hasSuffix(" console") {
            return false
        }
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0
        return width >= 200 && height >= 150
    }

    /// Confirma que la familia exacta del juego posee una ventana visible y utilizable. Mantener un
    /// proceso Wine vivo no basta: launchers, SDKs y watchdogs pueden sobrevivir sin renderizar nada
    /// y no deben convertirse en una capa de compatibilidad «aprendida».
    nonisolated func hasVisibleGameWindow(executable: String, prefix: String) async -> Bool {
        let imageNames = trackedProcessFamilyImageNames(forExecutable: executable)
        let executableDirectory = processTrackingDirectory(forExecutable: executable)
        guard !imageNames.isEmpty else { return false }
        let processIDs = Set(await Self.gameWineProcessFamilyIDs(
            imageNames: imageNames,
            prefix: prefix,
            executableDirectory: executableDirectory
        ))
        guard !processIDs.isEmpty,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else { return false }

        return windows.contains { Self.isUsableGameWindow($0, ownedBy: processIDs) }
    }

    /// Cierra únicamente la familia exacta del juego en su prefijo. Nunca usa `wineserver -k`, por
    /// lo que el cliente Steam interno y sus descargas permanecen intactos.
    nonisolated func terminateGameProcessFamily(executable: String, prefix: String) async {
        let imageNames = trackedProcessFamilyImageNames(forExecutable: executable)
        let executableDirectory = processTrackingDirectory(forExecutable: executable)
        guard !imageNames.isEmpty else { return }
        var processIDs = await Self.gameWineProcessFamilyIDs(
            imageNames: imageNames,
            prefix: prefix,
            executableDirectory: executableDirectory
        )
        guard !processIDs.isEmpty else { return }

        for processID in processIDs { _ = Darwin.kill(processID, SIGTERM) }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            processIDs = await Self.gameWineProcessFamilyIDs(
                imageNames: imageNames,
                prefix: prefix,
                executableDirectory: executableDirectory
            )
            if processIDs.isEmpty { return }
        }
        for processID in processIDs { _ = Darwin.kill(processID, SIGKILL) }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if (await Self.gameWineProcessFamilyIDs(
                imageNames: imageNames,
                prefix: prefix,
                executableDirectory: executableDirectory
            )).isEmpty { return }
        }
        await MainActor.run {
            LogStore.shared.log(
                "No se pudo cerrar por completo la familia de procesos de \(imageNames.joined(separator: ", ")).",
                level: .error
            )
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
        if goldbergManager.hasEmbeddedSteamworks(gameExecutable: executable) { return true }
        let dir = (executable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        let names = ["steam_api64.dll", "steam_api.dll"]
        // 1) Ubicaciones CONOCIDAS (O(1), cubren la inmensa mayoría de layouts) — evita enumerar en el
        //    caso común: raíz del juego, Unity (`<exe>_Data/Plugins/x86_64|x86`) y Unreal (`Binaries/…`).
        let exeName = ((executable as NSString).lastPathComponent as NSString).deletingPathExtension
        var knownDirs = [dir]
        for sub in ["\(exeName)_Data/Plugins/x86_64", "\(exeName)_Data/Plugins/x86",
                    "\(exeName)_Data/Plugins", "Binaries/Win64", "Binaries/Win32", "Binaries/WinGDK"] {
            knownDirs.append("\(dir)/\(sub)")
        }
        for base in knownDirs {
            for n in names where fm.fileExists(atPath: "\(base)/\(n)") { return true }
        }
        // 2) Fallback: enumeración con tope ALTO. Buscar un nombre concreto es barato (solo nombres, sin
        //    leer ficheros); el tope de 4000 anterior dejaba fuera juegos UE5 con árboles enormes cuyo
        //    `steam_api64.dll` vive muy profundo (p. ej. Engine/Binaries/ThirdParty/Steamworks/…) →
        //    Goldberg no se aplicaba y el juego moría en `SteamAPI_Init`. Solo se llega aquí si las
        //    ubicaciones conocidas no lo tenían (raro), así que el coste no afecta al caso común.
        if let walker = fm.enumerator(atPath: dir) {
            var checked = 0
            for case let rel as String in walker {
                checked += 1; if checked > 60000 { break }
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

    /// `true` si es un **Unreal Engine 4** (no 5).
    ///
    /// La diferencia importa para el motor. Un UE5 va por GPTK/D3DMetal (Palworld), pero un UE4 no
    /// arranca ni por DXMT ni por GPTK — se queda a medias sin dejar ni el log. Con el Wine COMPLETO
    /// de CrossOver sí abre. Verificado con ASTRONEER: pasó de no abrir a su menú completo. El
    /// `-nohmd` (ver `unrealEngineArguments`) es aparte y hace falta igual: apaga la VR que lo cuelga.
    ///
    /// La versión se lee de las CADENAS del binario (`UE4` / `UE5`), no de la tabla de imports: UE4
    /// carga `d3d12.dll` dinámicamente (sí aparece en el PE) aunque su RHI real sea D3D11, así que
    /// mirar los imports lo confunde con un UE5. Astroneer trae 35 veces "UE4" y ninguna "UE5".
    func isUnrealEngine4Game(_ executable: String) -> Bool {
        guard isUnrealGame(executable) else { return false }
        if exeContains(executable, anyOf: ["UE5", "++UE5+"]) { return false }
        return exeContains(executable, anyOf: ["UE4", "++UE4+"])
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

    /// Argumentos para los juegos de **Unreal Engine**: apagar la realidad virtual.
    ///
    /// Un UE con el plugin de OpenXR compilado **busca un visor de VR al arrancar**, y bajo Wine no
    /// hay ninguno: el buscador entra en bucle (*"Failed to find default runtime"*, *"RuntimeManifestFile
    /// ::FindManifestFiles - failed to find active runtime file"*, una y otra vez) y el juego **muere
    /// sin llegar a escribir su log ni a abrir ventana** — desde fuera parece que no arranca y ya.
    /// Con `-nohmd` ni lo intenta. Verificado con ASTRONEER, que pasó de no abrir a su menú completo.
    ///
    /// A un Unreal sin VR no le molesta: es una opción del motor, no del juego. `-nosplash` quita la
    /// ventanita de carga, que bajo Wine a veces se queda encima del juego.
    func unrealEngineArguments(forExecutable executable: String) -> [String] {
        let dir = (executable as NSString).deletingLastPathComponent.lowercased()
        guard dir.contains("/binaries/win64") || dir.contains("/binaries/win32")
                || dir.contains("/binaries/wingdk") else { return [] }
        return ["-nohmd", "-nosplash"]
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
        if needsExeAdjacentD3D9Support(gameExecutable) {
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
        let restoredOriginalD3D9 = dxvkManager.removeGameLocalD3D9(forExecutable: gameExecutable)
        for dll in ["d3d9.dll", "wined3d.dll", "d3d11.dll", "dxgi.dll", "d3d10core.dll", "d3d10.dll", "d3d10_1.dll", "winemetal.dll"] {
            if dll == "d3d9.dll", restoredOriginalD3D9 { continue }
            try? fm.removeItem(atPath: "\(gameDir)/\(dll)")
        }
    }

    /// Directorio de trabajo del juego. Normalmente la carpeta del exe; PERO si el exe vive en una
    /// subcarpeta de binarios de 64 bits (x64/win64/bin64/…), muchos juegos con doble build esperan
    /// como CWD la RAÍZ del juego (donde están sus datos/BD), no la subcarpeta — p. ej. Grim Dawn
    /// (`x64/Grim Dawn.exe`) sale al instante con CWD=`x64/` porque no encuentra sus datos.
    func gameWorkingDirectory(forExecutable executable: String) -> String {
        let exeDir = (executable as NSString).deletingLastPathComponent
        let last = (exeDir as NSString).lastPathComponent.lowercased()
        let bin64: Set<String> = ["x64", "x64vk", "win64", "bin64", "binaries64", "x86_64", "amd64"]
        guard bin64.contains(last) else { return exeDir }
        let parent = (exeDir as NSString).deletingLastPathComponent

        // El motor propietario de Klei conserva los paquetes bajo `data/databundles`, pero su
        // bootstrap calcula esa raíz partiendo del CWD oficial `bin64`. Si Vessel sube a la raíz,
        // el motor omite todos los ZIP (`shaders`, `fonts`, `scripts`…) y termina con un shader
        // ausente aunque la instalación esté íntegra. La firma combina contenido del PE y la
        // estructura de recursos, sin depender del título ni del AppID.
        let bundles = "\(parent)/data/databundles"
        if FileManager.default.fileExists(atPath: "\(bundles)/hashes.txt"),
           FileManager.default.fileExists(atPath: "\(bundles)/shaders.zip"),
           FileManager.default.fileExists(atPath: "\(bundles)/scripts.zip"),
           exeContains(executable, anyOf: ["DataBundleFileHashes"]),
           exeContains(executable, anyOf: ["Mounting file system databundles/shaders.zip"]) {
            return exeDir
        }

        // El exe vive en una subcarpeta de binarios (x64/Win64/…). Subir UN nivel es correcto cuando
        // esa subcarpeta cuelga DIRECTAMENTE de la raíz del juego (p. ej. Grim Dawn `x64/Grim Dawn.exe`
        // → raíz). PERO en el patrón **Unreal** `…/Binaries/Win64/Juego.exe`, subir un nivel da
        // `…/Binaries` — una carpeta INTERMEDIA sin los datos del juego → el juego arranca pero su
        // WebView interno (notas del parche) sale en BLANCO y el audio/recursos degradan (validado con
        // Palworld: con CWD=Win64 va bien, con CWD=Binaries no). En ese caso el CWD correcto es la
        // carpeta del exe (Win64), no la intermedia.
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
            // Se aparta CUALQUIER DLL con estos nombres, pese su tamaño lo que pese. No vale filtrar
            // por tamaño: la `d3d10_1` de DXMT ocupa 86 KB y `winemetal` 73 KB (son forwarders finos),
            // así que un umbral de 100 KB las dejaba pasar — y con `d3d10_1=n,b` Wine cargaba ESA en vez
            // del builtin del motor, arrastrando `winemetal` a un motor que no lo es. Resultado: page
            // fault en `gdi32` y ni una ventana. Verificado con A Short Hike (Unity 32-bit sobre gptk).
            // Al lado del `.exe`, cualquier DLL gráfica pisa el builtin: el criterio es el nombre.
            guard fm.fileExists(atPath: path) else { continue }
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

    /// Entorno limpio común del motor completo. Algunas rutas (D3D9/wined3d) cargan MoltenVK por
    /// nombre mediante `dlopen`; al ejecutar con `env -i`, dyld no ve `wine-full/lib` aunque la
    /// biblioteca ya esté empaquetada. Exponer solo ese directorio también es inocuo para OpenGL.
    nonisolated static func fullEngineEnvironment(
        prefix: String,
        engineRoot: String = WineEngineLocator.fullEngineDir()
    ) -> [String: String] {
        [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
            "DYLD_FALLBACK_LIBRARY_PATH": "\(engineRoot)/lib"
        ]
    }

    /// Superpone el MoltenVK oficial versionado sin modificar el motor instalado. El ICD y dyld
    /// apuntan a la misma copia, mientras las demás bibliotecas siguen resolviéndose desde
    /// `wine-full`. Así una actualización de Vulkan queda aislada, recuperable y compartida por
    /// todas las rutas que realmente la necesitan.
    nonisolated static func modernMoltenVKEnvironment(
        from environment: [String: String],
        libraryDirectory: String,
        useMetalArgumentBuffers: Bool
    ) -> [String: String] {
        var result = environment
        let existingLibraries = environment["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
        let isolatedLibraries = existingLibraries.isEmpty
            ? libraryDirectory
            : "\(libraryDirectory):\(existingLibraries)"
        result["DYLD_FALLBACK_LIBRARY_PATH"] = isolatedLibraries
        // `winevulkan` puede traer un @rpath al MoltenVK del propio motor; dyld y el cargador Vulkan
        // deben ver primero la misma copia oficial para no mezclar dos implementaciones en el proceso.
        result["DYLD_LIBRARY_PATH"] = isolatedLibraries
        result["VK_ICD_FILENAMES"] = "\(libraryDirectory)/MoltenVK_icd.json"
        result["VK_DRIVER_FILES"] = "\(libraryDirectory)/MoltenVK_icd.json"
        // `wine-full` carga Vulkan con `dlopen(SONAME_LIBVULKAN)`. Su parche CW HACK 25909 solo
        // respeta una biblioteca explícita cuando el backend activo es `wined3d`; los dos paths de
        // dyld y el ICD no bastan si el motor ya aporta otro `libMoltenVK.dylib`. Fijar ambos valores
        // evita que Wine consulte capacidades en una copia y cree el dispositivo en otra.
        result["CX_ACTIVE_GRAPHICS_BACKEND"] = "wined3d"
        result["CX_LIBVULKAN"] = "\(libraryDirectory)/libMoltenVK.dylib"
        result["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS"] = useMetalArgumentBuffers ? "1" : "0"
        return result
    }

    /// Lista blanca del entorno que cruza la frontera `env -i` del motor completo.
    ///
    /// Mantenerla en una función comprobable evita que una ruta prepare un backend gráfico y que
    /// el LaunchAgent descarte silenciosamente sus variables justo antes de ejecutar Wine. Solo se
    /// conservan claves explícitas: el resto del entorno de Vessel (incluidas credenciales) queda
    /// aislado del proceso Windows.
    nonisolated static func fullEngineCleanEnvironment(
        from environment: [String: String]
    ) -> [String: String] {
        let allowedKeys = [
            "HOME", "USER", "TMPDIR", "WINEPREFIX", "WINEDEBUG", "WINEDLLOVERRIDES",
            "WINESERVER",
            "WINEPRELOADERAPPNAME",
            "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_LIBRARY_PATH",
            "VK_ICD_FILENAMES", "VK_DRIVER_FILES", "DXVK_LOG_LEVEL", "DXVK_LOG_PATH",
            "CX_ACTIVE_GRAPHICS_BACKEND", "CX_LIBVULKAN",
            "SteamAppId", "SteamGameId",
            "WINEMSYNC", "WINEESYNC", "WINEFSYNC",
            "MVK_CONFIG_LOG_LEVEL", "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "MTL_HUD_ENABLED",
            "GST_PLUGIN_SYSTEM_PATH", "GST_PLUGIN_PATH", "GST_PLUGIN_SCANNER", "GST_REGISTRY",
            "GIO_EXTRA_MODULES",
            "DOTNET_ReadyToRun", "DOTNET_TieredCompilation", "DOTNET_TieredPGO",
            "DOTNET_EnableWriteXorExecute", "DOTNET_gcServer", "ROSETTA_ADVERTISE_AVX",
            "SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS",
            "SDL_JOYSTICK_HIDAPI", "SDL_JOYSTICK_HIDAPI_PS4", "SDL_JOYSTICK_HIDAPI_PS4_RUMBLE",
            "SDL_JOYSTICK_HIDAPI_PS5", "SDL_JOYSTICK_HIDAPI_PS5_RUMBLE",
            "SDL_JOYSTICK_HIDAPI_SWITCH"
        ]

        return Dictionary(uniqueKeysWithValues: allowedKeys.compactMap { key in
            environment[key].map { (key, $0) }
        })
    }

    /// Steam y el juego deben vivir en agentes de launchd distintos. Compartir etiqueta provoca
    /// que el `bootout` del juego descargue el agente que mantiene vivo al cliente y rompe el IPC
    /// Steamworks justo antes de `SteamAPI_Init`.
    nonisolated static func fullEngineLaunchAgentLabel(arguments: [String]) -> String {
        let executable = arguments.first.map { ($0 as NSString).lastPathComponent.lowercased() }
        return executable == "steam.exe"
            ? "com.swondev.vessel.steamlauncher"
            : "com.swondev.vessel.fullgamelauncher"
    }

    /// El motor multimedia deriva de `wine-full`, pero su nombre aislado impide que
    /// `isFullEngine` lo reconozca. El cliente Steam necesita igualmente quedar desligado del
    /// responsible process de Vessel; los comandos auxiliares del perfil no deben pagar ese coste.
    nonisolated static func requiresDetachedSteamLaunchContext(
        winePath: String,
        arguments: [String]
    ) -> Bool {
        if WineEngineLocator.isFullEngine(winePath) { return true }
        guard WineEngineLocator.isD3DMetalMediaEngine(winePath) else { return false }
        return arguments.first.map {
            ($0 as NSString).lastPathComponent.lowercased() == "steam.exe"
        } ?? false
    }

    /// Entorno para el CLIENTE de Steam en Gcenx. El render del webhelper lo hace
    /// el wrapper (--disable-gpu, CPU), así que NO se pasan overrides d3d.
    private func steamClientEnvironment(prefix: String) -> [String: String] {
        var environment = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            // La combinación validada del CEF interactivo usa todo el sync apagado. Evita que
            // ConnectEx/NetworkService se quede a medias y coincide con la prueba visual completa.
            "WINEMSYNC": "0",
            "WINEESYNC": "0",
            "WINEFSYNC": "0",
            "SteamAppId": "753",
            "SteamGameId": "753",
            "MVK_CONFIG_LOG_LEVEL": "0",
            "DOTNET_EnableWriteXorExecute": "0"
        ]
        if #available(macOS 15, *) { environment["ROSETTA_ADVERTISE_AVX"] = "1" }
        return environment
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
            var env = WineEngineLocator.isD3DMetalMediaEngine(wine)
                ? D3DMetalMediaEngineProvisioner.mediaEnvironment(
                    winePath: wine,
                    prefix: prefix
                )
                : steamClientEnvironment(prefix: prefix)
            env["WINEMSYNC"] = "1"
            env["WINEESYNC"] = "1"
            env["WINEFSYNC"] = "1"
            env["MVK_CONFIG_LOG_LEVEL"] = "0"
            env["SteamAppId"] = "753"
            env["SteamGameId"] = "753"
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
        // Gcenx (interfaz validada): composición software y sync=0.
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

        // El rol visible siempre usa Gcenx; el rol DRM recibe normalmente un motor explícito para
        // compartir wineserver con el juego. El fallback background conserva la resolución histórica.
        let clientWine = winePath
            ?? (background
                ? resolveClientWine(for: bottle)
                : WineEngineLocator.interactiveSteamWineBinary() ?? resolveClientWine(for: bottle))
        let role: SteamClientRole = background ? .backgroundDRM : .interactive
        guard await transitionSteamClientIfNeeded(in: bottle, to: clientWine, role: role) else {
            throw WineError.launchFailed(
                "Steam está terminando una operación y aún no puede cambiar al cliente \(background ? "de DRM" : "visible")."
            )
        }

        // 0) Idempotencia: si Steam ya está arrancando o cargado (steam.exe vivo),
        //    NO lo matamos ni relanzamos. Matar un cliente a medio cargar —al pulsar
        //    "Lanzar Steam" y "Jugar" a la vez, o varias veces seguidas— era justo lo
        //    que impedía que el webhelper terminara de cargar (se relanzaba en bucle).
        if isWineProcessRunning(matching: "steam.exe", prefix: bottle.prefixPath) {
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
        try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: clientWine)
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
            let wine = try await dependencyManager.ensureInteractiveSteamEngineInstalled { _, _ in }
            _ = try await launchSteam(in: bottle, using: wine)   // idempotente si ya corre
            return
        }
        let clientWine = try await dependencyManager.ensureInteractiveSteamEngineInstalled { msg, _ in
            progress(msg)
        }
        if !isSteamBootstrapped(in: bottle) {
            progress("Descargando el cliente de Steam…")
            _ = try await launchSteam(in: bottle, using: clientWine) // bootstrap en crudo
            for _ in 0..<150 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if isSteamBootstrapped(in: bottle) { break }
            }
            // Cerrar el Steam del bootstrap para relanzarlo limpio con el wrapper.
            try? await terminateWineProcesses(winePath: clientWine, prefix: bottle.prefixPath)
            try? await killOrphanWineProcesses(prefix: bottle.prefixPath, gameWine: clientWine)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        // Ya bootstrapped → este lanzamiento aplica wrapper + steam.cfg + caché limpia,
        // así el login se ve (no pantalla negra).
        progress("Abriendo Steam para iniciar sesión…")
        _ = try await launchSteam(in: bottle, using: clientWine)
    }

    /// Instala un juego de la biblioteca **desde Vessel**: asegura el cliente Steam
    /// corriendo y le pasa `steam://install/<appid>` para que Steam lo descargue. El
    /// watcher en tiempo real lo añadirá a la lista cuando termine la instalación.
    func installSteamGame(appId: String, in bottle: Bottle) async throws {
        guard FileManager.default.fileExists(atPath: bottle.steamPath) else {
            throw WineError.launchFailed("Steam no está instalado en este bottle.")
        }
        let clientWine = WineEngineLocator.interactiveSteamWineBinary()
            ?? resolveClientWine(for: bottle)
        if !isWineProcessRunning(matching: "steamwebhelper") {
            log.log("Abriendo Steam para instalar el juego…", level: .info)
            _ = try? await launchSteam(in: bottle, using: clientWine)
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
    private func killOrphanWineProcesses(prefix: String, gameWine: String? = nil) async throws {
        // Con una descarga de Steam a medias no se limpia el prefijo: se llevaría por delante el
        // cliente y el usuario perdería la descarga por lanzar un juego (ver `terminateWineProcesses`).
        if await steamHasActiveDownloads(prefix: prefix, gameWine: gameWine) {
            log.log("Steam está descargando: se respeta el prefijo para no cortar la descarga.", level: .info)
            return
        }
        await Self.runCleanupCommand(
            path: "/usr/bin/pkill",
            arguments: ["-9", "-f", prefix]
        )
        // Primero se cierran los CLIENTES mientras todavía conservan abiertos sus ficheros del
        // prefijo. Si se mata antes el wineserver, algunos clientes que están mostrando una
        // excepción pierden esos descriptores antes de que `lsof` pueda atribuirlos al bottle y
        // sobreviven al cambio de motor. Uno de esos clientes puede volver a levantar SU
        // wineserver justo cuando arranca el juego siguiente: DOOM (wine-full) llegó a conectarse
        // así al server de GPTK y winevulkan abortó en `vkWaitForFences` por mezclar dos ABI.
        await killPrefixWineClients(prefix: prefix, gameWine: gameWine)
        // El WINESERVER NO lleva el prefix en su argv (lo lee de la env `WINEPREFIX`),
        // así que `pkill -f <prefix>` NO lo alcanza y queda ZOMBI. Al cambiar de motor
        // (fallback DXMT→GPTK→Gcenx, o cliente Steam→juego) el nuevo wine —de otra
        // versión— choca con ese server zombi: «wine client error: version mismatch» y
        // el juego MUERE nada más arrancar (el clásico "se ejecuta y se cierra"). Lo
        // matamos por SEÑAL (independiente de versión): localizamos los `wineserver`
        // cuyos descriptores abiertos apuntan a ESTE prefix vía `lsof` y les mandamos
        // SIGKILL. `wineserver -k` no vale aquí porque también dialoga por protocolo y
        // falla igual con el mismatch de versión.
        await killPrefixWineservers(prefix: prefix, gameWine: gameWine)
        // Segunda pasada corta la carrera de cierre: un cliente puede estar terminando mientras
        // cae el server y reabrirlo durante unos milisegundos. El pequeño yield es asíncrono, no
        // bloquea la UI, y deja el prefijo realmente sin runtime antes de cambiar de motor.
        try? await Task.sleep(for: .milliseconds(250))
        await killPrefixWineClients(prefix: prefix, gameWine: gameWine)
        await killPrefixWineservers(prefix: prefix, gameWine: gameWine)
    }

    /// `true` si hay una **descarga de Steam a medias** en este prefijo Y se puede respetar sin
    /// romperle el arranque al juego.
    ///
    /// Lo primero se mira en disco: `steamapps/downloading/<appid>` son los trozos que Steam está
    /// bajando. No hace falta preguntarle a nadie.
    ///
    /// Lo segundo es la parte delicada. Dentro de un prefijo solo puede haber **un wineserver**, y
    /// tiene que ser de la misma versión de Wine que el juego: si el cliente dejó uno de `wine-full`
    /// y el juego arranca con otro motor, muere al instante con *"wine client error: version
    /// mismatch"*. Por eso solo se respeta a Steam cuando el juego usa **su mismo motor**; si no,
    /// toca echarlo (y el usuario pierde la descarga, que es el mal menor frente a que el juego no
    /// abra). Con `gameWine` a `nil` se asume que sí, para las limpiezas que no van atadas a un
    /// motor concreto.
    private func steamHasActiveDownloads(prefix: String, gameWine: String? = nil) async -> Bool {
        var hayDescarga = false
        for base in ["Program Files (x86)", "Program Files"] {
            let dir = "\(prefix)/drive_c/\(base)/Steam/steamapps/downloading"
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            if items.contains(where: { Int($0) != nil }) { hayDescarga = true; break }
        }
        guard hayDescarga else { return false }
        // Hay descarga: solo se puede respetar si el wineserver que está vivo es del MISMO motor que
        // el juego. Si no, el juego moriría con "version mismatch" nada más arrancar, y eso es peor
        // que perder la descarga. NO basta con mirar el motor del juego: el server vivo puede haberlo
        // dejado OTRO juego (pasó con DOOM: server de wine-unified + juego de wine-full → mismatch).
        guard let wine = gameWine else { return true }
        guard let liveEngine = await Self.liveWineserverEngine(prefix: prefix) else { return true }
        return liveEngine == engineDirectory(forWine: wine)
    }

    /// Directorio del motor al que pertenece un binario `wine` (…/<motor>/bin/wine → …/<motor>).
    private func engineDirectory(forWine wine: String) -> String {
        ((wine as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    }

    /// Motor del `wineserver` que está vivo en este prefijo, o `nil` si no hay ninguno.
    private nonisolated static func liveWineserverEngine(prefix: String) async -> String? {
        await Task.detached(priority: .utility) {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-x", "wineserver"]
            let pidsPipe = Pipe()
            pgrep.standardOutput = pidsPipe
            pgrep.standardError = FileHandle.nullDevice
            guard (try? pgrep.run()) != nil else { return nil }
            let pidsData = pidsPipe.fileHandleForReading.readDataToEndOfFile()
            pgrep.waitUntilExit()

            for pidText in String(decoding: pidsData, as: UTF8.self)
                .split(whereSeparator: { $0.isWhitespace }) {
                guard let pid = Int32(pidText) else { continue }
                let lsof = Process()
                lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                lsof.arguments = lsofProcessLookupArguments(processID: pid)
                let filesPipe = Pipe()
                lsof.standardOutput = filesPipe
                lsof.standardError = FileHandle.nullDevice
                guard (try? lsof.run()) != nil else { continue }
                let listing = String(
                    decoding: filesPipe.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
                lsof.waitUntilExit()
                guard listing.contains(prefix) else { continue }

                let ps = Process()
                ps.executableURL = URL(fileURLWithPath: "/bin/ps")
                ps.arguments = ["-o", "command=", "-p", String(pid)]
                let commandPipe = Pipe()
                ps.standardOutput = commandPipe
                ps.standardError = FileHandle.nullDevice
                guard (try? ps.run()) != nil else { continue }
                let command = String(
                    decoding: commandPipe.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                ps.waitUntilExit()

                // …/<motor>/bin/wineserver o …/<motor>/lib/wine/…/wineserver → <motor>.
                guard let enginesRange = command.range(of: "/Engines/") else { continue }
                let remainder = command[enginesRange.upperBound...]
                guard let slash = remainder.firstIndex(of: "/") else { continue }
                return String(command[..<enginesRange.upperBound]) + String(remainder[..<slash])
            }
            return nil
        }.value
    }

    /// Mata por SIGKILL los procesos Wine CLIENTE (argv de Windows, con `.exe`) que
    /// tengan abierto algo bajo `prefix`. No toca CrossOver ni otros prefijos (su
    /// `lsof` no apunta a este prefix) ni procesos nativos de macOS (no casan `.exe`).
    ///
    /// **Excepción: Steam mientras descarga.** Matarlo aquí le cortaba al usuario la descarga en
    /// curso sin decirle nada — y encima Steam ya está donde tiene que estar: mismo prefijo y mismo
    /// motor que el juego, así que no hay choque de versiones de wineserver que justifique echarlo
    /// (de hecho los juegos con DRM COMPARTEN wineserver con el cliente a propósito). Si no hay
    /// descargas, se mantiene el comportamiento de siempre: fuera, para que el juego arranque limpio.
    private func killPrefixWineClients(prefix: String, gameWine: String? = nil) async {
        let preservarSteam = await steamHasActiveDownloads(prefix: prefix, gameWine: gameWine)
        if preservarSteam {
            log.log("Steam está descargando: se deja abierto para no cortar la descarga.", level: .info)
        }
        // `grep -v` de los ejecutables del cliente: solo cuando hay una descarga que proteger.
        let filtroSteam = preservarSteam
            ? "| /usr/bin/grep -viE 'steam\\.exe|steamwebhelper|steamservice|steamerrorreporter'"
            : ""
        let script = """
        for pid in $(/bin/ps -axo pid=,command= | /usr/bin/grep -F '.exe' | /usr/bin/grep -v grep \(filtroSteam) | /usr/bin/awk '{print $1}'); do
          if /usr/sbin/lsof -nP -a -p "$pid" -Fn 2>/dev/null | /usr/bin/grep -qF '\(prefix)'; then
            /bin/kill -9 "$pid" 2>/dev/null
          fi
        done
        """
        await Self.runCleanupCommand(path: "/bin/sh", arguments: ["-c", script])
    }

    /// Mata por SIGKILL cualquier `wineserver` ligado a `prefix`, sea cual sea el motor
    /// (versión) que lo arrancó. Evita el "version mismatch" que deja colgado al juego
    /// tras un cambio de motor. Silencioso e idempotente.
    private func killPrefixWineservers(prefix: String, gameWine: String? = nil) async {
        // El wineserver es la raíz del prefijo: matarlo se lleva por delante TODO lo que corre
        // dentro, incluido el Steam que esté descargando. Si hay una descarga a medias se respeta;
        // el cliente usa el mismo motor que el juego, así que no hay mismatch de versión que temer
        // (que es para lo que existe esta limpieza).
        if await steamHasActiveDownloads(prefix: prefix, gameWine: gameWine) { return }
        // Para cada wineserver vivo, si tiene ABIERTO algo bajo el prefix → SIGKILL.
        let script = """
        for pid in $(/usr/bin/pgrep -x wineserver 2>/dev/null); do
          if /usr/sbin/lsof -nP -a -p "$pid" -Fn 2>/dev/null | /usr/bin/grep -qF '\(prefix)'; then
            /bin/kill -9 "$pid" 2>/dev/null
          fi
        done
        """
        await Self.runCleanupCommand(path: "/bin/sh", arguments: ["-c", script])
    }

    /// Ejecuta limpiezas de procesos fuera del actor principal. Los sondeos de `lsof` sobre Steam
    /// y CEF pueden recorrer muchos descriptores; aunque usen `-nP`, nunca deben bloquear entrada,
    /// animaciones o accesibilidad de Vessel.
    private nonisolated static func runCleanupCommand(
        path: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            if let environment { process.environment = environment }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
        }.value
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
        let isFullEngine = WineEngineLocator.isFullEngine(wine)
        if (try? String(contentsOfFile: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == id {
            // La política de crash tiene su propia versión: un prefijo puede estar sincronizado con
            // el motor y conservar todavía la configuración antigua `Auto=0`, que precisamente
            // muestra el diálogo «Exception raised». La migración solo ejecuta `reg` una vez.
            if !isFullEngine {
                await ensureAutoDebuggerDisabled(prefix: prefix, wine: wine)
            }
            return
        }
        // Motor COMPLETO (wine-full): trae su propio Wine + DXMT + winemac completos y gestiona el
        // prefijo de fábrica (validado: cliente Steam y juegos corren sin un `wineboot -u` externo).
        // Además su `bin/wine` es un shim que exige su propio entorno, mientras `resyncGamePrefix`
        // lanza wineboot con el entorno REEMPLAZADO (sin HOME/PATH) → no encaja. Marcamos el prefijo
        // como sincronizado sin forzar el resync.
        if isFullEngine {
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
    /// Desactiva el **depurador automático** de Wine en el prefijo (idempotente).
    ///
    /// Por defecto, ante una excepción no controlada Wine lanza `winedbg --auto`. En Apple Silicon
    /// ese `winedbg` **crashea él mismo** (división por cero), lo que dispara otro `winedbg`… y así
    /// sin fin: una **bomba fork**. Medido en vivo: **982 `winedbg` + 982 `conhost`** de un solo
    /// crash. El daño no se queda en ese juego — cada proceso abre clientes de IOSurface, el kernel
    /// corta en ~1020 (`_iosConnectInitalize ... e00002c7`) y a partir de ahí **NINGÚN** juego puede
    /// crear ventana hasta reiniciar. Un crash cualquiera dejaba el Mac inservible para jugar.
    ///
    /// Sin depurador automático, un crash es solo un crash: el resto del sistema sigue sano. No se
    /// pierde diagnóstico — el error real de Wine sigue yendo al log del juego.
    ///
    /// Se escribe en las DOS ramas del registro: los procesos de 32-bit leen `Wow6432Node`, así que
    /// poner solo la nativa NO evita la bomba (comprobado: seguían saliendo 78 `winedbg`).
    nonisolated static var disabledAutoDebuggerRegistryCommands: [[String]] {
        [#"HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug"#,
         #"HKLM\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug"#]
            .flatMap { key in
                [
                    ["reg", "add", key, "/v", "Debugger", "/t", "REG_SZ", "/d", "", "/f"],
                    // En Wine, `Auto=0` NO desactiva el depurador: abre primero el MessageBox
                    // «Exception raised / Do you wish to debug it?». `Auto=1` omite ese diálogo y
                    // el comando Debugger vacío falla en silencio; la excepción permanece en el log.
                    ["reg", "add", key, "/v", "Auto", "/t", "REG_SZ", "/d", "1", "/f"]
                ]
            }
    }

    private func ensureAutoDebuggerDisabled(prefix: String, wine: String) async {
        let policyVersion = "2"
        let policyMarker = "\(prefix)/.vessel-aedebug-policy"
        if (try? String(contentsOfFile: policyMarker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == policyVersion {
            return
        }

        var succeeded = true
        for arguments in Self.disabledAutoDebuggerRegistryCommands {
            do {
                let result = try await runWine(
                    winePath: wine,
                    arguments: arguments,
                    prefix: prefix,
                    allowNonZeroExit: true
                )
                if result.exitCode != 0 { succeeded = false }
            } catch {
                succeeded = false
            }
        }
        if succeeded {
            try? policyVersion.write(
                toFile: policyMarker,
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func resyncGamePrefix(gameWine: String, prefix: String) async {
        // SEGURIDAD: matar wineservers zombis del prefix ANTES de `wineboot`. Si queda uno de
        // OTRO motor/versión (p. ej. tras un crash del intento anterior en el fallback), el
        // `wineboot -u` choca con él y se queda COLGADO esperando —dejando el árbol de
        // servicios a medias y disparando el clásico cuelgue/fork-bomba—. Limpiarlo antes lo evita.
        await killPrefixWineservers(prefix: prefix)
        await ensureAutoDebuggerDisabled(prefix: prefix, wine: gameWine)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gameWine)
        process.arguments = ["wineboot", "-u"]
        var resyncEnvironment = Self.wineControlEnvironment(prefix: prefix, wine: gameWine)
        resyncEnvironment["WINEDLLOVERRIDES"] = "mscoree,mshtml=d;d3d9,d3d8,ddraw=b"
        process.environment = resyncEnvironment
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
        try? await killOrphanWineProcesses(prefix: prefix, gameWine: gameWine)
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
        // `wineserver -k` tumba TODO lo que corre en el prefijo, y ahí dentro puede estar el Steam
        // que está descargando: al usuario se le cortaba la descarga por lanzar un juego, sin
        // avisarle. Si hay una descarga a medias se respeta — el cliente usa el mismo motor que el
        // juego, así que no hay choque de versiones que justifique echarlo (de hecho los juegos con
        // DRM comparten wineserver con él a propósito). Solo si el juego usa SU MISMO motor.
        if await steamHasActiveDownloads(prefix: prefix, gameWine: winePath) { return }
        guard let wineserverPath = siblingTool(named: "wineserver", forWinePath: winePath) else {
            return
        }

        await Self.runCleanupCommand(
            path: wineserverPath,
            arguments: ["-k"],
            environment: [
                "WINEPREFIX": prefix,
                "WINEDEBUG": "-all"
            ]
        )
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

    /// Los launch tokens de Epic/EOS son credenciales efímeras. Deben llegar al proceso del juego,
    /// pero nunca al log de Vessel ni a los logs de los LaunchAgents.
    nonisolated static func isSensitiveLaunchArgument(_ argument: String) -> Bool {
        let lower = argument.lowercased()
        return ["auth_login", "auth_password", "auth_type", "epicusername", "epicuserid",
                "access_token", "refresh_token", "exchange", "credential", "password="]
            .contains(where: lower.contains)
    }

    /// Genera el script efímero que consume un LaunchAgent. El propio script programa una limpieza
    /// privada y acotada después de abrirse. Borrarlo desde el proceso que hace `bootstrap` crea una
    /// carrera: con el sistema ocupado, `launchd` puede arrancar unos segundos más tarde y encontrar
    /// el archivo desaparecido (`last exit code = 1`). Borrarlo inmediatamente desde el primer agente
    /// también rompe los `kickstart` de recuperación cuando Wine sale durante el cierre del wineserver
    /// anterior. Los 90 segundos cubren todo el bucle de reintentos; el archivo sigue siendo `0600`.
    nonisolated static func selfRemovingLaunchAgentScript(
        commandFile: String,
        workingDirectory: String,
        command: String
    ) -> String {
        func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let attemptMarker = commandFile + ".started"
        return "(/bin/sleep 90; /bin/rm -f \(shellQuote(commandFile)) \(shellQuote(attemptMarker))) >/dev/null 2>&1 &\n"
            + "/usr/bin/touch \(shellQuote(attemptMarker))\n"
            + "cd \(shellQuote(workingDirectory))\n"
            + "\(command)\n"
    }

    /// Conserva diagnóstico útil para lanzamientos con credenciales sin persistir su salida cruda.
    /// El filtro solo deja firmas técnicas de carga/render y descarta de forma explícita cualquier
    /// línea relacionada con autenticación. La sustitución de proceso mantiene `exec`: Wine sigue
    /// siendo el proceso del LaunchAgent y conserva el contexto gráfico validado.
    nonisolated static func launchAgentCommand(
        _ command: String,
        containsSensitiveArguments: Bool,
        diagnosticLogPath: String
    ) -> String {
        guard containsSensitiveArguments else { return "exec \(command)" }

        func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let logPath = shellQuote(diagnosticLogPath)
        let allowTechnicalLine =
            "tolower($0) ~ /(:module:|:loaddll:|failed|not found|unsupported|exception|c0000135|d3d12|dxgi)/"
        let rejectSensitiveLine =
            "tolower($0) !~ /(auth_|exchangecode|exchange|password|credential|access_token|refresh_token|epicuser|epicid)/"
        let filter = "\(allowTechnicalLine) && \(rejectSensitiveLine)"
        return "umask 077\n"
            + ": > \(logPath)\n"
            + "exec \(command) > >(/usr/bin/awk '\(filter)' >> \(logPath)) 2>&1"
    }

    /// Comprueba si el LaunchAgent ya consumió su script. En macOS `test` vive en `/bin`, no en
    /// `/usr/bin`; usar una ruta inexistente hacía que el bucle de recuperación ignorase el marcador
    /// y relanzase el mismo juego varias veces después de un fallo rápido.
    nonisolated static func launchAttemptMarkerCheckCommand(_ marker: String) -> String {
        let quoted = "'" + marker.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "/bin/test -f \(quoted)"
    }

    /// Coincide con el ejecutable real, pero no con la propia orden de vigilancia que contiene el
    /// patrón. `pgrep -f 'Hades'` también encontraba al bash cuyo argumento incluía `Hades` y podía
    /// mantener el tracker vivo sin juego; `[H]ades` conserva la coincidencia real y evita la propia.
    nonisolated static func selfExcludingProcessPattern(_ executableName: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: executableName)
        return selfExcludingEscapedPattern(escaped)
    }

    /// Comando equivalente para los supervisores bash. Centralizarlo impide que una de las rutas
    /// de lanzamiento vuelva accidentalmente al comportamiento sensible a mayúsculas de macOS.
    nonisolated static func caseInsensitivePgrepShellCommand(matchingPattern pattern: String) -> String {
        let quoted = "'" + pattern.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "/usr/bin/pgrep -i -f \(quoted)"
    }

    /// Los AppID con varias arquitecturas pueden analizar una build y arrancar otra según la
    /// configuración oficial de Steam. El supervisor debe reconocer ambas sin confundirse con su
    /// propia orden `pgrep`.
    nonisolated static func steamProtectedProcessPattern(_ executableName: String) -> String {
        for architecture in ["x32", "x64"] {
            guard let range = executableName.range(
                of: architecture,
                options: [.caseInsensitive, .backwards]
            ) else { continue }
            let prefix = String(executableName[..<range.lowerBound])
            let suffix = String(executableName[range.upperBound...])
            let familyPattern = NSRegularExpression.escapedPattern(for: prefix)
                + "x(32|64)"
                + NSRegularExpression.escapedPattern(for: suffix)
            return selfExcludingEscapedPattern(familyPattern)
        }
        return selfExcludingProcessPattern(executableName)
    }

    private nonisolated static func selfExcludingEscapedPattern(_ escaped: String) -> String {
        guard let index = escaped.firstIndex(where: { $0.isLetter || $0.isNumber }) else {
            return escaped
        }
        let character = escaped[index]
        return String(escaped[..<index])
            + "[\(character)]"
            + String(escaped[escaped.index(after: index)...])
    }

    /// Retira únicamente la desactivación de `mscoree` de una cadena de overrides y conserva el
    /// resto. Así un juego con evidencia administrada puede usar Wine Mono/.NET sin reactivar Gecko
    /// (`mshtml`) ni alterar sus capas gráficas. El parser evita reemplazos frágiles dependientes del
    /// orden (`mscoree,mshtml=d`, `mscoree=d`, etc.).
    nonisolated static func enablingManagedRuntime(in overrides: String) -> String {
        overrides.split(separator: ";", omittingEmptySubsequences: true).compactMap { rawSegment in
            let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "d" else {
                return segment.isEmpty ? nil : segment
            }
            let names = parts[0].split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.caseInsensitiveCompare("mscoree") != .orderedSame }
            guard !names.isEmpty else { return nil }
            return "\(names.joined(separator: ","))=d"
        }.joined(separator: ";")
    }

    /// Reactiva únicamente `mscoree` cuando el inventario acotado del juego demuestra una carga
    /// administrada. Conserva intactos Gecko, multimedia y las capas gráficas del entorno elegido.
    nonisolated static func environmentByEnablingManagedRuntimeIfNeeded(
        _ environment: [String: String],
        dependencies: [RuntimeDependencyProvisioner.Dependency]
    ) -> [String: String] {
        guard dependencies.contains(.dotNet),
              let overrides = environment["WINEDLLOVERRIDES"] else { return environment }
        var resolved = environment
        resolved["WINEDLLOVERRIDES"] = enablingManagedRuntime(in: overrides)
        return resolved
    }

    /// D3DMetal conserva DXR detrás de una capacidad explícita para que los juegos que no lo usan
    /// no cambien de ruta gráfica. La rama Enhanced de 4A exige DXR 1.1 incluso para crear el
    /// dispositivo inicial: si no se publica, muestra el aviso de requisitos mínimos antes de abrir
    /// su renderizador. La huella estructural completa del motor evita habilitar ray tracing por
    /// título, tienda o para cualquier otro D3D12 que solo lo incluya de forma opcional.
    func environmentByEnablingRequiredD3DMetalFeatures(
        _ environment: [String: String],
        executable: String
    ) -> [String: String] {
        guard isFourAEnhancedD3D12Engine(executable) else { return environment }
        var resolved = environment
        resolved["D3DM_SUPPORT_DXR"] = "1"
        return resolved
    }

    /// 4A marca `BadQuit=1` al empezar y lo limpia únicamente tras una salida ordinaria. Cuando
    /// Vessel detiene una ejecución bloqueada, el siguiente arranque muestra un diálogo de modo
    /// seguro cuyos textos no llegan a pintarse bajo Wine. Vessel ya aplica el perfil gráfico
    /// compatible antes de lanzar, por lo que restablecer el marcador es la recuperación automática
    /// equivalente a «Run normally». Se exige la huella completa de Enhanced; ningún título ni
    /// AppID participa en la decisión.
    func fourAUncleanExitRegistryRepairArguments(executable: String) -> [String]? {
        guard isFourAEnhancedD3D12Engine(executable) else { return nil }
        return [
            "reg", "add", #"HKCU\Software\4A-Games\Metro Exodus"#,
            "/v", "BadQuit", "/t", "REG_DWORD", "/d", "0", "/f"
        ]
    }

    /// Variables que pueden cruzar el aislamiento `env -i` del motor D3DMetal propio. Mantener
    /// aquí las capacidades del traductor evita que un perfil correctamente detectado se pierda
    /// justo al separar el juego del contexto gráfico de la app.
    nonisolated static var d3dMetalGameCleanEnvironmentKeys: [String] {
        [
            "HOME", "USER", "TMPDIR", "WINEPREFIX", "WINEDEBUG", "MVK_CONFIG_LOG_LEVEL",
            "WINEDLLOVERRIDES", "DYLD_FALLBACK_LIBRARY_PATH", "SteamAppId", "SteamGameId",
            "WINEPRELOADERAPPNAME", "VESSEL_DOCK_APP_NAME",
            "VESSEL_DOCK_PRELOADER_ALIAS", "DYLD_INSERT_LIBRARIES",
            "WINEMSYNC", "WINEESYNC", "WINEFSYNC", "CX_FWD_COMPAT_GL_CTX",
            "VESSEL_FORCE_CORE_GL_CTX", "VESSEL_WINE_FIBER_GS_REWRITE",
            "MTL_HUD_ENABLED", "D3DM_SUPPORT_DXR", "ROSETTA_ADVERTISE_AVX",
            "D3DM_VENDOR_ID", "D3DM_DEVICE_ID", "D3DM_DEVICE_DESCRIPTION",
            "GST_PLUGIN_SYSTEM_PATH", "GST_PLUGIN_PATH", "GST_PLUGIN_SCANNER",
            "GST_REGISTRY", "GIO_EXTRA_MODULES",
            "SDL_RENDER_DRIVER", "SDL_FRAMEBUFFER_ACCELERATION",
            "SDL_JOYSTICK_HIDAPI", "SDL_JOYSTICK_HIDAPI_PS4", "SDL_JOYSTICK_HIDAPI_PS4_RUMBLE",
            "SDL_JOYSTICK_HIDAPI_PS5", "SDL_JOYSTICK_HIDAPI_PS5_RUMBLE", "SDL_JOYSTICK_HIDAPI_SWITCH"
        ]
    }

    /// Lista blanca equivalente para GPTK, cuya sesión Aqua independiente es necesaria para crear
    /// el dispositivo Metal desde una app sandboxed/embebida. DXR debe viajar en el comando del
    /// LaunchAgent: dejarlo solo en `fullEnv` no tiene efecto porque el hijo arranca con `env -i`.
    nonisolated static var gptkGameCleanEnvironmentKeys: [String] {
        [
            "HOME", "USER", "TMPDIR", "WINEPREFIX", "WINEDEBUG", "MVK_CONFIG_LOG_LEVEL",
            "WINEDLLOVERRIDES", "DYLD_FALLBACK_LIBRARY_PATH", "SteamAppId", "SteamGameId",
            "WINEPRELOADERAPPNAME",
            "WINEMSYNC", "WINEESYNC", "WINEFSYNC", "CX_FWD_COMPAT_GL_CTX", "MTL_HUD_ENABLED",
            "D3DM_SUPPORT_DXR", "ROSETTA_ADVERTISE_AVX", "SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS",
            "D3DM_VENDOR_ID", "D3DM_DEVICE_ID", "D3DM_DEVICE_DESCRIPTION",
            "SDL_JOYSTICK_HIDAPI", "SDL_JOYSTICK_HIDAPI_PS4", "SDL_JOYSTICK_HIDAPI_PS4_RUMBLE",
            "SDL_JOYSTICK_HIDAPI_PS5", "SDL_JOYSTICK_HIDAPI_PS5_RUMBLE", "SDL_JOYSTICK_HIDAPI_SWITCH"
        ]
    }

    nonisolated static func redactedArgumentsForLogging(_ arguments: [String]) -> [String] {
        arguments.map { argument in
            guard isSensitiveLaunchArgument(argument) else { return argument }
            if let separator = argument.firstIndex(of: "=") {
                return String(argument[...separator]) + "<redactado>"
            }
            return "<redactado>"
        }
    }

    /// El proceso anfitrión puede ejecutarse desde Codex, Xcode o un terminal que contenga tokens
    /// de desarrollo. Wine propaga variables desconocidas a sus procesos Windows, donde quedarían
    /// visibles sin aportar nada al juego. Se filtran solo del entorno HEREDADO; el entorno explícito
    /// y controlado por Vessel se superpone después para conservar Steam, Wine, Metal y launchers.
    nonisolated static func sanitizedInheritedEnvironment(_ environment: [String: String]) -> [String: String] {
        let sensitiveFragments = [
            "TOKEN", "PASSWORD", "PASSWD", "SECRET", "CREDENTIAL",
            "API_KEY", "PRIVATE_KEY", "ACCESS_KEY", "AUTH"
        ]
        let developmentPrefixes = [
            "OPENAI_", "ANTHROPIC_", "GITHUB_", "GITLAB_", "GH_",
            "AWS_", "AZURE_", "GOOGLE_", "SLACK_", "CODEX_", "CLAUDE_"
        ]
        return environment.filter { key, _ in
            let upper = key.uppercased()
            return !sensitiveFragments.contains(where: upper.contains)
                && !developmentPrefixes.contains(where: upper.hasPrefix)
        }
    }

    /// Normaliza el título que macOS mostrará como identidad del proceso Wine. Se conserva Unicode,
    /// pero se eliminan controles y separadores de ruta porque el mismo valor nombra un hard link
    /// temporal al preloader. El límite evita nombres de Dock patológicos y cabe en el plist
    /// embebido de los cargadores WineHQ más antiguos.
    nonisolated static func normalizedDockDisplayName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let sanitizedScalars = rawValue.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            switch scalar.value {
            case 0x2F: return "∕" // `/` separaría componentes POSIX.
            case 0x3A: return "꞉" // `:` es ambiguo para Finder/HFS.
            default: return String(scalar)
            }
        }.joined()
        let collapsed = sanitizedScalars
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(64))
    }

    /// Composición pura y comprobable del entorno de identidad. Los motores CrossOver/GPTK ya
    /// implementan `WINEPRELOADERAPPNAME`; WineHQ recibe además el helper de Vessel que replica ese
    /// comportamiento y ejecuta el preloader mediante un alias con el título real del juego.
    nonisolated static func dockIdentityEnvironment(
        from environment: [String: String],
        displayName: String?,
        nativeOverrideAvailable: Bool,
        injectionLibraryPath: String? = nil,
        preloaderAliasPath: String? = nil
    ) -> [String: String] {
        var result = environment
        for key in [
            "WINEPRELOADERAPPNAME", "VESSEL_DOCK_APP_NAME",
            "VESSEL_DOCK_PRELOADER_ALIAS", "DYLD_INSERT_LIBRARIES"
        ] {
            result[key] = nil
        }
        guard let name = normalizedDockDisplayName(displayName) else { return result }
        result["WINEPRELOADERAPPNAME"] = name
        guard !nativeOverrideAvailable,
              let injectionLibraryPath,
              !injectionLibraryPath.isEmpty,
              let preloaderAliasPath,
              !preloaderAliasPath.isEmpty else { return result }
        result["VESSEL_DOCK_APP_NAME"] = name
        result["VESSEL_DOCK_PRELOADER_ALIAS"] = preloaderAliasPath
        // Es una biblioteca controlada y firmada por Vessel. No se propaga una inyección heredada
        // del entorno anfitrión ni una posible sustitución declarada por un perfil externo.
        result["DYLD_INSERT_LIBRARIES"] = injectionLibraryPath
        return result
    }

    private func loaderSupportsNativeDockIdentity(winePath: String) -> Bool {
        if WineEngineLocator.isFullEngine(winePath)
            || WineEngineLocator.isGPTKEngine(winePath)
            || WineEngineLocator.isD3DMetalMediaEngine(winePath) {
            return true
        }

        var candidates = [URL(fileURLWithPath: winePath)]
        if let root = WineEngineLocator.engineRoot(
            forWineExecutable: URL(fileURLWithPath: winePath)
        ) {
            candidates += [
                root.appendingPathComponent("bin/wine"),
                root.appendingPathComponent("bin/wine64"),
                root.appendingPathComponent("wine/bin/wine"),
                root.appendingPathComponent("lib/wine/x86_64-unix/wine")
            ]
        }
        let marker = Data("WINEPRELOADERAPPNAME".utf8)
        return Set(candidates.map(\.standardizedFileURL)).contains { candidate in
            guard let data = try? Data(contentsOf: candidate, options: .mappedIfSafe) else {
                return false
            }
            return data.range(of: marker) != nil
        }
    }

    private func environmentByApplyingDockIdentity(
        _ environment: [String: String],
        displayName: String?,
        winePath: String
    ) -> [String: String] {
        guard let name = Self.normalizedDockDisplayName(displayName) else {
            return Self.dockIdentityEnvironment(
                from: environment,
                displayName: nil,
                nativeOverrideAvailable: true
            )
        }
        let nativeOverrideAvailable = loaderSupportsNativeDockIdentity(winePath: winePath)
        guard !nativeOverrideAvailable else {
            return Self.dockIdentityEnvironment(
                from: environment,
                displayName: name,
                nativeOverrideAvailable: true
            )
        }
        guard let helper = VesselPaths.bundledResource(
            "dock-identity/libVesselDockIdentity.dylib"
        ) else {
            log.log("No se encontró el helper de identidad del Dock; se conserva el fallback nativo de Wine.", level: .warn)
            return Self.dockIdentityEnvironment(
                from: environment,
                displayName: name,
                nativeOverrideAvailable: true
            )
        }

        let digest = SHA256.hash(data: Data(winePath.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let aliasDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VesselDockIdentity", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: aliasDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let alias = aliasDirectory.appendingPathComponent(name, isDirectory: false)
            if FileManager.default.fileExists(atPath: alias.path) {
                try FileManager.default.removeItem(at: alias)
            }
            return Self.dockIdentityEnvironment(
                from: environment,
                displayName: name,
                nativeOverrideAvailable: false,
                injectionLibraryPath: helper.path,
                preloaderAliasPath: alias.path
            )
        } catch {
            log.log("No se pudo preparar la identidad del Dock para \(name): \(error.localizedDescription)", level: .warn)
            return Self.dockIdentityEnvironment(
                from: environment,
                displayName: name,
                nativeOverrideAvailable: true
            )
        }
    }

    private func launchWineProcess(
        winePath: String,
        prefix: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        effective: EffectiveLaunchConfig? = nil,
        forceSyncOff: Bool = false,
        forceSyncOn: Bool = false,
        /// Reaplica la evidencia administrada después de todos los overlays del perfil. Es la última
        /// palabra sobre `mscoree`: una dependencia PE demostrada no puede quedar desactivada por una
        /// configuración base o aprendida anterior.
        enableManagedRuntime: Bool = false,
        d3dMetalGame: Bool = false,
        /// Fuerza el lanzamiento con entorno LIMPIO (`env -i` vía bash), como si viniera de un
        /// terminal. No es solo cosa de Metal: **cualquier** juego que cree un contexto gráfico
        /// (también el OpenGL de SDL) puede fallar heredando la identidad de bundle de Vessel — la
        /// ventana abre y se queda NEGRA. Lo usan los envoltorios retro (DOSBox/ScummVM).
        forceCleanEnv: Bool = false
    ) async throws -> Process {
        // Motor COMPLETO (wine-full): su `bin/wine` es un shim que traduce `wine <exe>` →
        // `wineloader winewrapper.exe --run -- <exe>` y fija WINELOADER/WINESERVER/WINEDLLPATH, así
        // que aquí se lanza como cualquier otro motor (sin casos especiales). El wineloader resuelve
        // sus libs por rpath (@loader_path/@rpath).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = arguments
        let containsSensitiveArguments = arguments.contains(where: Self.isSensitiveLaunchArgument)
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
        var fullEnv = Self.sanitizedInheritedEnvironment(ProcessInfo.processInfo.environment)
        for (key, value) in Self.sanitizedInheritedEnvironment(Self.userShellEnvironment) {
            fullEnv[key] = value
        }
        for (key, value) in environment { fullEnv[key] = value }
        // `wine-full` debe levantar siempre el server de SU MISMA distribución. La limpieza del
        // prefijo evita servidores previos; este pin cubre además los hijos y comandos auxiliares
        // que Wine pueda crear tras cruzar `env -i`/launchd.
        if WineEngineLocator.isFullEngine(winePath) {
            fullEnv["WINESERVER"] = Self.matchingWineserverPath(forWine: winePath)
        }
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
            let extDir = WineEngineLocator.isD3DMetalMediaEngine(winePath)
                ? root.appendingPathComponent("lib64/apple_gptk/external").path
                : root.appendingPathComponent("lib/external").path
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
            // Unreal (UE4/UE5) sobre GPTK: esync/fsync le MATAN el arranque (mismo criterio que
            // la ruta UE4 de wine-full); solo msync es compatible. Pisa el sync del perfil SOLO
            // en este caso. Verificado con Dwarven Realms (UE5): con WINEESYNC=1 muere antes de
            // crear ventana; con msync solo llega al menú.
            if WineEngineLocator.isGPTKEngine(winePath),
               let exe = arguments.first, isUnrealGame(exe) {
                fullEnv["WINEESYNC"] = "0"
                fullEnv["WINEFSYNC"] = "0"
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
        fullEnv = environmentByApplyingDockIdentity(
            fullEnv,
            displayName: effective?.gameDisplayName,
            winePath: winePath
        )
        if enableManagedRuntime, let overrides = fullEnv["WINEDLLOVERRIDES"] {
            fullEnv["WINEDLLOVERRIDES"] = Self.enablingManagedRuntime(in: overrides)
        }
        if let ownership = effective?.epicLaunchOwnership {
            let effectiveExecutable = arguments.first ?? ownership.installedExecutable
            let requiresVesselProtectedSpawn = forceCleanEnv
                || d3dMetalGame
                || isDotNetCoreGame(effectiveExecutable)
                || WineEngineLocator.isGPTKEngine(winePath)
                || WineEngineLocator.isD3DMetalEngine(winePath)
                || Self.requiresDetachedSteamLaunchContext(
                    winePath: winePath,
                    arguments: arguments
                )
                || effective?.useRealSteam == true
            guard !requiresVesselProtectedSpawn,
                  let legendaryArguments = LegendaryManager.delegatedLaunchArguments(
                    appName: ownership.appName,
                    winePath: winePath,
                    prefix: prefix,
                    installedExecutable: ownership.installedExecutable,
                    effectiveExecutable: effectiveExecutable,
                    installPath: ownership.installPath,
                    gameArguments: Array(arguments.dropFirst()),
                    offline: ownership.offline
                  ) else {
                throw EpicLaunchDelegationError.unsupported
            }
            return try LegendaryManager().launchDelegatedGame(
                arguments: legendaryArguments,
                environment: fullEnv,
                workingDirectory: workingDirectory
            )
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
                      "WINEPRELOADERAPPNAME", "VESSEL_DOCK_APP_NAME",
                      "VESSEL_DOCK_PRELOADER_ALIAS", "DYLD_INSERT_LIBRARIES",
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
        } else if forceCleanEnv
                    || (WineEngineLocator.isUnifiedEngine(winePath) && !forceSyncOff && !d3dMetalGame)
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
            for k in Self.d3dMetalGameCleanEnvironmentKeys {
                if let v = fullEnv[k] { clean[k] = v }
            }
            func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let assignments = clean.map { "\($0.key)=\(shq($0.value))" }.joined(separator: " ")
            let cmdline = ([winePath] + arguments).map { shq($0) }.joined(separator: " ")
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "exec /usr/bin/env -i \(assignments) \(cmdline)"]
            process.environment = fullEnv
        } else if WineEngineLocator.isGPTKEngine(winePath), effective != nil {
            // Juegos por **GPTK/D3DMetal de Apple (gptk-mythic)**: desde la app MUEREN al instante
            // tanto con el entorno heredado como con `env -i` en hijo directo — el "responsible
            // process" de la .app les impide crear su contexto gráfico (UE5 integra CEF para sus
            // web widgets: misma clase de problema que el CEF del cliente Steam). Solo arrancan
            // vía **LaunchAgent** (bootstrap en `gui/<uid>`, PPID=1, sesión Aqua propia), igual que
            // el cliente Steam del motor completo. Verificado con Dwarven Realms (UE5): hijo
            // directo (heredado o env -i) muere en <60 s sin dejar log; LaunchAgent abre hasta el
            // menú. Agente PROPIO (no el del cliente Steam): ni le pisa el label ni mata steam.exe.
            log.log("GPTK/D3DMetal: lanzando el juego vía LaunchAgent (launchd bootstrap, independiente de la app).", level: .info)
            var clean: [String: String] = [:]
            for k in Self.gptkGameCleanEnvironmentKeys {
                if let v = fullEnv[k] { clean[k] = v }
            }
            func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let assignments = clean.map { "\($0.key)=\(shq($0.value))" }.joined(separator: " ")
            let cmdline = ([winePath] + arguments).map { shq($0) }.joined(separator: " ")
            let cwd = workingDirectory ?? (prefix as NSString).deletingLastPathComponent
            let cmdFile = "\(NSHomeDirectory())/Library/Application Support/Vessel/.game-launch.sh"
            let attemptMarker = cmdFile + ".started"
            try? FileManager.default.removeItem(atPath: attemptMarker)
            let rawLaunchCommand = "/usr/bin/env -i \(assignments) \(cmdline)"
            let protectedLog = "\(NSHomeDirectory())/Library/Logs/Vessel/protected-game-agent.log"
            let script = Self.selfRemovingLaunchAgentScript(
                commandFile: cmdFile,
                workingDirectory: cwd,
                command: Self.launchAgentCommand(
                    rawLaunchCommand,
                    containsSensitiveArguments: containsSensitiveArguments,
                    diagnosticLogPath: protectedLog
                )
            )
            try? script.write(toFile: cmdFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cmdFile)
            let uid = getuid()
            let agentLabel = "com.swondev.vessel.gamelauncher"
            let agentPlist = "\(NSHomeDirectory())/Library/Application Support/Vessel/gamelauncher.plist"
            let agentLog = containsSensitiveArguments
                ? "/dev/null"
                : "\(NSHomeDirectory())/Library/Logs/Vessel/game-agent.log"
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
            // bootout del agente previo (idempotente) + bootstrap; el kickstart de refuerzo espera
            // al exe del juego (RunAtLoad puede fallar si el wineserver anterior aún se cierra).
            // Conservar `.exe` evita coincidencias por prefijo con procesos nativos de macOS.
            // Ejemplo real: vigilar `CrashReport` mantenía este supervisor vivo para siempre porque
            // también encontraba `/System/.../CrashReporterSupportHelper`.
            let supervisedExecutable = arguments.first(where: {
                $0.lowercased().hasSuffix(".exe")
            }) ?? "wine"
            let processPattern = launchSupervisorProcessPattern(
                forExecutable: supervisedExecutable
            )
            let pgrepGame = Self.caseInsensitivePgrepShellCommand(
                matchingPattern: processPattern
            )
            let bootCmd =
                "/bin/launchctl bootout gui/\(uid)/\(agentLabel) 2>/dev/null; sleep 1; "
                + "/bin/launchctl bootstrap gui/\(uid) '\(agentPlist)' 2>/dev/null; "
                + "for r in 1 2 3 4 5 6; do sleep 4; \(pgrepGame) >/dev/null 2>&1 && break; "
                + "\(Self.launchAttemptMarkerCheckCommand(attemptMarker)) && break; "
                + "/bin/launchctl kickstart gui/\(uid)/\(agentLabel) 2>/dev/null; done; "
                // VITAL: el bash devuelto debe VIVIR lo que viva el juego — el tracker
                // (GameLaunchTracker) y el watchdog miden la vida del juego por ESTE proceso.
                // Si el bash sale tras el bootstrap, el watchdog cree a los ~9 s que el juego
                // murió y dispara la auto-reparación (Dwarven Realms: mató el agente sano).
                + "while \(pgrepGame) >/dev/null 2>&1; do sleep 5; done"
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", bootCmd]
            process.environment = ["HOME": NSHomeDirectory(), "USER": NSUserName(),
                                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        } else if Self.requiresDetachedSteamLaunchContext(
            winePath: winePath,
            arguments: arguments
        ) {
            // Motor COMPLETO (wine-full): el cliente Steam CEF **y** los juegos necesitan el contexto
            // LIMPIO (`env -i` vía bash). Desde la app (hijo directo), el bundle GUI
            // (`__CFBundleIdentifier`/`XPC_*` + DYLD stripped) rompe el CEF/DXMT: el proceso arranca
            // pero MUERE sin pintar (validado: lanzado desde terminal RENDERIZA la tienda; desde la app
            // muere). Igual que los juegos .NET/D3DMetal. El wineserver es por-prefijo, así que `env -i`
            // conserva `WINEPREFIX` y los juegos comparten wineserver con el cliente (mismo prefijo →
            // DRM). El shim `bin/wine` (sh) solo usa builtins + rutas absolutas, así que corre sin PATH.
            log.log("Motor completo: lanzando con entorno LIMPIO (env -i) para evitar el contexto GUI que rompe el CEF/DXMT.", level: .info)
            var clean = Self.fullEngineCleanEnvironment(from: fullEnv)
            // ⭐ CrossOver cxcompatdb — LA clave de que los juegos vayan PERFECTOS desde el Steam de
            // wine (como CrossOver; NO era D3DMetal, como se creyó al principio). `CX_ROOT` activa el
            // módulo `cxcompatdb.so`, que aplica los "hacks" de compatibilidad POR JUEGO (dll_overrides,
            // env_vars, cmdline…). Los juegos que el cliente Steam lanza HEREDAN estas vars → cxcompatdb
            // activo → render correcto SIN ir juego a juego. Validado in-vivo: Palworld (UE5/D3D12)
            // renderiza perfecto y el CEF del cliente NO se rompe (el webhelper va por CPU, ajeno a
            // CX_GRAPHICS_BACKEND). `WINEMSYNC=1` (ya en la whitelist) DEBE coincidir con el cliente.
            let isManagedMediaEngine = WineEngineLocator.isD3DMetalMediaEngine(winePath)
            let cxRoot = WineEngineLocator.fullEngineDir()
            // ⚠️ NO forzar CX_GRAPHICS_BACKEND: CrossOver NO lo setea (su bottle Steam va sin él) y usa
            // su AUTO-DETECCIÓN por juego (D3D9→wined3d, D3D11/12→D3DMetal/vkd3d…). Forzarlo a "d3dmetal"
            // rompía los juegos que NO son D3D11/12 — p.ej. Cube World (D3D9) daba "Could not initialize
            // Direct3D". Sin forzarlo, cada juego usa su backend correcto, exactamente como CrossOver.
            // `CX_APPLEGPTK_LIBD3DSHARED_PATH` sí se exporta siempre (CrossOver hace igual): deja D3DMetal
            // DISPONIBLE para cuando la auto-detección lo elija (D3D11/12), sin imponerlo.
            if !isManagedMediaEngine {
                clean["CX_ROOT"] = cxRoot
                let cxLibd3d = "\(cxRoot)/lib64/apple_gptk/external/libd3dshared.dylib"
                if FileManager.default.fileExists(atPath: cxLibd3d) {
                    clean["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = cxLibd3d
                }
                if let cxHome = ensureCXCompatDB() { clean["CX_HOME"] = cxHome }
            } else {
                // Este perfil se validó sin la base propietaria: ni siquiera debe heredarse por
                // accidente al cruzar el LaunchAgent del cliente DRM.
                clean["CX_ROOT"] = nil
                clean["CX_HOME"] = nil
                clean["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = nil
            }
            func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let assignments = clean.map { "\($0.key)=\(shq($0.value))" }.joined(separator: " ")
            let cmdline = ([winePath] + arguments).map { shq($0) }.joined(separator: " ")
            let bashCmd = "/usr/bin/env -i \(assignments) \(cmdline)"
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
            let esSteam = arguments.first.map {
                ($0 as NSString).lastPathComponent.lowercased() == "steam.exe"
            } ?? false
            let agentStem = esSteam ? "steamlauncher" : "fullgamelauncher"
            let cmdFile = "\(NSHomeDirectory())/Library/Application Support/Vessel/.\(agentStem)-launch.sh"
            let attemptMarker = cmdFile + ".started"
            try? FileManager.default.removeItem(atPath: attemptMarker)
            let cwd = workingDirectory ?? (prefix as NSString).deletingLastPathComponent
            let protectedLog = "\(NSHomeDirectory())/Library/Logs/Vessel/protected-game-agent.log"
            let script = Self.selfRemovingLaunchAgentScript(
                commandFile: cmdFile,
                workingDirectory: cwd,
                command: Self.launchAgentCommand(
                    bashCmd,
                    containsSensitiveArguments: containsSensitiveArguments,
                    diagnosticLogPath: protectedLog
                )
            )
            try? script.write(toFile: cmdFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cmdFile)
            let uid = getuid()
            let agentLabel = Self.fullEngineLaunchAgentLabel(arguments: arguments)
            // ⚠️ El plist va en Application Support, NO en ~/Library/LaunchAgents: allí launchd lo
            // auto-cargaría en CADA inicio de sesión (RunAtLoad) → Steam arrancaría solo al login.
            // `bootstrap gui/<uid> <plist>` acepta cualquier ruta de plist para una carga puntual.
            let agentPlist = "\(NSHomeDirectory())/Library/Application Support/Vessel/\(agentStem).plist"
            let agentLog = containsSensitiveArguments
                ? "/dev/null"
                : "\(NSHomeDirectory())/Library/Logs/Vessel/\(agentStem)-agent.log"
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
            // Ese "mata residuos" es para cuando lo que arranca es STEAM (single-instance). Cuando lo
            // que arranca es un JUEGO y Steam está descargando, matarlo le corta la descarga al
            // usuario por la cara: ahí se respeta. El juego no necesita que Steam muera — comparten
            // motor y prefijo, y los que llevan DRM hasta lo agradecen.
            let matarSteam = esSteam
                ? "/usr/bin/pkill -9 -f 'steam\\.exe' 2>/dev/null; /usr/bin/pkill -9 -f steamwebhelper 2>/dev/null; "
                  + "for i in 1 2 3 4 5 6 7 8; do /usr/bin/pgrep -f 'steam\\.exe' >/dev/null 2>&1 || break; sleep 1; done; "
                : ""
            let bootCmd: String
            if esSteam {
                bootCmd =
                    "/bin/launchctl bootout gui/\(uid)/\(agentLabel) 2>/dev/null; "
                    + matarSteam
                    + "sleep 2; "
                    + "/bin/launchctl bootstrap gui/\(uid) '\(agentPlist)' 2>/dev/null; "
                    + "for r in 1 2 3 4 5 6; do sleep 4; /usr/bin/pgrep -f 'steam\\.exe' >/dev/null 2>&1 && break; "
                    + "/bin/launchctl kickstart gui/\(uid)/\(agentLabel) 2>/dev/null; done"
            } else {
                let supervisedExecutable = arguments.first(where: {
                    $0.lowercased().hasSuffix(".exe")
                }) ?? "wine"
                let processPattern = launchSupervisorProcessPattern(
                    forExecutable: supervisedExecutable
                )
                let pgrepGame = Self.caseInsensitivePgrepShellCommand(
                    matchingPattern: processPattern
                )
                bootCmd =
                    "/bin/launchctl bootout gui/\(uid)/\(agentLabel) 2>/dev/null; sleep 1; "
                    + "/bin/launchctl bootstrap gui/\(uid) '\(agentPlist)' 2>/dev/null; "
                    + "for r in 1 2 3 4 5 6; do sleep 4; \(pgrepGame) >/dev/null 2>&1 && break; "
                    + "\(Self.launchAttemptMarkerCheckCommand(attemptMarker)) && break; "
                    + "/bin/launchctl kickstart gui/\(uid)/\(agentLabel) 2>/dev/null; done; "
                    + "while \(pgrepGame) >/dev/null 2>&1; do sleep 5; done"
            }
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
        try? Data().write(to: URL(fileURLWithPath: outPath), options: .atomic)
        if containsSensitiveArguments {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        } else if let handle = FileHandle(forWritingAtPath: outPath) {
            process.standardOutput = handle
            process.standardError = handle
        }

        let loggedArguments = Self.redactedArgumentsForLogging(arguments)
            .map { ($0 as NSString).lastPathComponent }
            .joined(separator: " ")
        log.log("CMD: \((winePath as NSString).lastPathComponent) \(loggedArguments)", level: .debug)
        do {
            try process.run()
            log.log("Proceso Wine lanzado (pid=\(process.processIdentifier))", level: .info)
            // El juego es el primer argumento que acaba en `.exe` (los demás son opciones, o
            // `explorer` cuando va en escritorio virtual).
            if let exe = arguments.first(where: { $0.lowercased().hasSuffix(".exe") }) {
                nudgeGameWindowFocus(exeName: (exe as NSString).lastPathComponent)
            }
            dismissAMDDriverWarningDialog()
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

    /// Auto-reparación de runtime: cuando `LaunchDiagnostics` confirma que falta una librería,
    /// inspecciona la instalación y aplica únicamente las generaciones de VC++, .NET, DirectX,
    /// XNA, audio u otros componentes que el juego referencia. El plan evita el antiguo
    /// `vcrun2022` universal, que no cubría títulos antiguos y podía ocultar la causa real.
    ///
    /// `applyWinetricksVerbs` conserva la instalación idempotente, desatendida y verificada. Cambiar
    /// de motor no arregla una dependencia ausente, por eso esta reparación es independiente del
    /// ciclo de capas gráficas.
    @discardableResult
    func installMissingRuntimes(in bottle: Bottle, forExecutable executable: String,
                                missingLibrary: String? = nil) async -> Bool {
        let wine = resolveGameWine(for: bottle, executable: executable)
        let plan = RuntimeDependencyProvisioner.repairPlan(
            executable: executable,
            missingLibrary: missingLibrary
        )
        let verbs: [String]
        if plan.winetricksVerbs.isEmpty, missingLibrary == nil, plan.dependencies.isEmpty {
            verbs = ["vcrun2022"]
        }
        else { verbs = plan.winetricksVerbs }
        guard !verbs.isEmpty else {
            log.log("La librería ausente \(missingLibrary ?? "desconocida") no corresponde a un runtime autorreparable; se evita instalar componentes sin evidencia.", level: .warn)
            return false
        }
        if plan.dependencies.isEmpty {
            log.log("No se pudo identificar el runtime exacto; aplicando el fallback seguro VC++ 2015-2022.", level: .warn)
        } else {
            log.log("Plan de reparación detectado: \(plan.dependencies.map(\.label).joined(separator: ", ")) → \(verbs.joined(separator: ", ")).", level: .info)
        }
        // Llegamos aquí porque existe evidencia de fallo aunque el marcador diga que el verbo se
        // aplicó anteriormente. Forzar una reinstalación permite autorreparar un prefijo incompleto
        // o dañado; sin esto la ruta de reparación podía convertirse en un no-op.
        return await applyWinetricksVerbs(verbs, prefix: bottle.prefixPath, wine: wine, force: true)
    }

    /// Resuelve `winetricks`: si no está en el sistema, DESCARGA el script oficial (un único fichero
    /// shell, sin compilar) a la caché de Vessel y lo hace ejecutable. Así la auto-reparación de
    /// runtimes funciona sin depender de `brew install winetricks` (coherente con "todo
    /// auto-descargable"). Idempotente. Devuelve `nil` si no hay red.
    private func ensureWinetricks() async -> String? {
        let dir = "\(VesselPaths.cacheDirectory)/winetricks"
        let path = "\(dir)/winetricks"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
        // SEGURIDAD (evitar RCE por script manipulado): pin a un RELEASE INMUTABLE de winetricks +
        // verificación SHA-256 de los bytes descargados ANTES de escribirlos y hacerlos ejecutables.
        // Aunque el tag se re-apuntara o hubiera un MITM, el hash no coincidiría → se rechaza y no se
        // ejecuta nada. (Actualizar `tag`+`expectedSHA` juntos al subir de versión de winetricks.)
        let tag = "20260125"
        let expectedSHA = "431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b"
        guard let url = URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/\(tag)/src/winetricks") else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard sha == expectedSHA else {
                log.log("winetricks descargado con SHA-256 INESPERADO (\(sha.prefix(12))…) — se RECHAZA por seguridad; no se ejecuta.", level: .warn)
                return nil
            }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(atPath: path)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)   // solo tras verificar el hash
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
            log.log("winetricks \(tag) descargado y VERIFICADO (SHA-256) — auto-reparación de runtimes sin depender de brew.", level: .info)
            return path
        } catch { return nil }
    }

    /// Aplica los verbos de winetricks que pide el perfil (vcrun, d3dx9…) de forma IDEMPOTENTE:
    /// lleva un registro en `<prefix>/.vessel-winetricks-applied` y solo aplica los que falten.
    ///
    /// Si el equipo no tiene winetricks, usa `ensureWinetricks()` para obtener el script oficial
    /// fijado y verificado por SHA-256 en la caché de Vessel. La ejecución es asíncrona y desatendida,
    /// de modo que no depende de Homebrew ni bloquea la interfaz mientras instala el runtime.
    @discardableResult
    private func applyWinetricksVerbs(_ verbs: [String], prefix: String, wine: String,
                                      force: Bool = false,
                                      exclusivePrefixPreparation: Bool = false) async -> Bool {
        let marker = "\(prefix)/.vessel-winetricks-applied"
        let already = Set(((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init))
        var seen = Set<String>()
        let requested = verbs.filter { seen.insert($0).inserted }
        let pending = force ? requested : requested.filter { !already.contains($0) }
        guard !pending.isEmpty else { return true }

        let hasActiveSteamDownloads: Bool
        if exclusivePrefixPreparation {
            hasActiveSteamDownloads = await steamHasActiveDownloads(prefix: prefix)
        } else {
            hasActiveSteamDownloads = false
        }
        let preparationDecision = Self.runtimePrefixPreparationDecision(
            exclusiveRequested: exclusivePrefixPreparation,
            hasPendingRuntimes: true,
            hasActiveSteamDownloads: hasActiveSteamDownloads
        )
        switch preparationDecision {
        case .continueWithoutCleanup:
            break
        case .deferForActiveDownloads:
            log.log(
                "Steam está descargando: se difiere la preparación de runtimes para no cortar la descarga.",
                level: .warn
            )
            return false
        case .prepareExclusively:
            guard await preparePrefixForExclusiveRuntimeInstallation(prefix: prefix, wine: wine) else {
                return false
            }
        }

        // winetricks: del sistema o AUTO-DESCARGADO (es un único script shell público, sin compilar),
        // para que la auto-reparación de runtimes NO dependa de `brew install winetricks`.
        let candidates = ["/opt/homebrew/bin/winetricks", "/usr/local/bin/winetricks"]
        let winetricks: String
        if let sys = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            winetricks = sys
        } else if let dl = await ensureWinetricks() {
            winetricks = dl
        } else {
            log.log("Falta winetricks para instalar [\(pending.joined(separator: ", "))] y no se pudo descargar (¿sin red?); el juego podría faltarle ese runtime.", level: .warn)
            return false
        }

        log.log("Aplicando winetricks (perfil): \(pending.joined(separator: ", "))…", level: .info)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winetricks)
        process.arguments = ["--unattended"] + (force ? ["--force"] : []) + pending
        var env = ProcessInfo.processInfo.environment
        env["WINE"] = wine
        env["WINEPREFIX"] = prefix
        env["WINEDEBUG"] = "-all"
        // winetricks necesita `cabextract` (y a veces `7z`) en PATH para extraer los redistribuibles.
        // El motor (wine-full) trae cabextract en su `bin`; brew también. Los ponemos en PATH (el
        // entorno de una .app puede venir con un PATH mínimo sin /opt/homebrew/bin).
        var pathParts = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        if let root = WineEngineLocator.engineRoot(forWineExecutable: URL(fileURLWithPath: wine)) {
            pathParts.insert(root.appendingPathComponent("bin").path, at: 0)
        }
        env["PATH"] = pathParts.joined(separator: ":")
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
        let succeeded = status == 0
        if succeeded {
            let updated = already.union(pending).sorted().joined(separator: "\n")
            try? updated.write(toFile: marker, atomically: true, encoding: .utf8)
            log.log("✓ winetricks aplicado: \(pending.joined(separator: ", "))", level: .info)
        } else if let status {
            log.log("winetricks devolvió código \(status) aplicando [\(pending.joined(separator: ", "))]. Detalle: \(outPath)", level: .warn)
        } else {
            log.log("No se pudo ejecutar winetricks.", level: .warn)
        }

        if preparationDecision == .prepareExclusively {
            let released = await releasePrefixAfterExclusiveRuntimeInstallation(
                prefix: prefix,
                wine: wine
            )
            guard released else { return false }
        }
        return succeeded
    }

    /// Detiene cualquier cliente/servidor Wine del prefijo antes de ejecutar Winetricks con un
    /// motor distinto. Es deliberadamente exclusiva: mezclar clientes Wine de versiones diferentes
    /// en un mismo `wineserver` hace que `cmd.exe` no pueda resolver ni siquiera `%AppData%`.
    private func preparePrefixForExclusiveRuntimeInstallation(prefix: String, wine: String) async -> Bool {
        log.log("Alineando el prefijo al motor de runtimes antes del preflight protegido…", level: .info)
        try? await terminateWineProcesses(winePath: wine, prefix: prefix)
        try? await killOrphanWineProcesses(prefix: prefix, gameWine: wine)
        try? await Task.sleep(for: .milliseconds(500))

        guard await Self.liveWineserverEngine(prefix: prefix) == nil,
              !isWineProcessRunning(matching: "steam.exe", prefix: prefix) else {
            log.log(
                "No se pudo liberar el prefijo para instalar los runtimes sin mezclar motores Wine.",
                level: .warn
            )
            return false
        }
        await ensurePrefixSyncedToEngine(wine, prefix: prefix)
        return true
    }

    /// Winetricks puede dejar vivo el `wineserver` del motor de preparación. Se cierra antes de
    /// entregar el prefijo al motor D3DMetal del juego; de lo contrario el lanzamiento siguiente
    /// vuelve a chocar por versión aunque la instalación del runtime haya terminado correctamente.
    private func releasePrefixAfterExclusiveRuntimeInstallation(prefix: String, wine: String) async -> Bool {
        try? await terminateWineProcesses(winePath: wine, prefix: prefix)
        try? await killOrphanWineProcesses(prefix: prefix, gameWine: wine)
        try? await Task.sleep(for: .milliseconds(500))

        guard await Self.liveWineserverEngine(prefix: prefix) == nil else {
            log.log(
                "El motor de runtimes dejó un wineserver activo; se cancela el arranque para evitar un cambio de motor inseguro.",
                level: .warn
            )
            return false
        }
        return true
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
