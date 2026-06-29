import Foundation

/// Gestiona la instalación y uso de **Legendary** (cliente CLI de Epic Games).
///
/// Legendary se auto-descarga del repositorio `derrod/legendary` (binario macOS standalone).
/// La configuración se guarda en una carpeta PROPIA de Vessel para no interferir con la
/// configuración global que el usuario pueda tener en `~/.config/legendary`.
///
/// Modelo de uso (igual que Heroic/Mythic): el usuario inicia sesión en un WebView embebido →
/// el `authorizationCode` se captura automáticamente → biblioteca disponible.
@MainActor
@Observable
final class LegendaryManager {

    // MARK: - Tipos públicos

    struct EpicGame: Identifiable, Hashable {
        let appName: String
        let title: String
        var installed: Bool
        var coverURL: String?
        var id: String { appName }
    }

    // MARK: - Rutas (estáticas, no aisladas al actor)

    static let legendaryDir  = "\(VesselPaths.enginesDirectory)/legendary"
    static let binaryPath    = "\(legendaryDir)/legendary"
    static let configDir     = "\(VesselPaths.appSupport)/Legendary"

    private static let userJSONPath = "\(configDir)/user.json"

    // MARK: - Estado

    private let log = LogStore.shared

    /// Versión de Legendary fijada (la MISMA que usa Heroic). Nota clave: `derrod/legendary`
    /// NO publica binario de macOS — Heroic mantiene un fork con binarios **nativos arm64**.
    private static let legendaryVersion = "0.20.43"

    /// Tiempo máximo de espera para cualquier subproceso de Legendary (segundos).
    /// Evita que la UI se quede colgada indefinidamente si legendary no responde.
    private static let processTimeoutSeconds: Double = 90

    // MARK: - Instalación del binario

    /// Devuelve la ruta al binario de Legendary, descargándolo si aún no está.
    /// Idempotente: si ya existe, devuelve la ruta inmediatamente.
    func ensureInstalled(onProgress: @escaping @Sendable (String) -> Void) async throws -> String {
        if FileManager.default.isExecutableFile(atPath: Self.binaryPath) {
            // Asegurar que el directorio de configuración también existe
            try? FileManager.default.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true)
            return Self.binaryPath
        }

        try FileManager.default.createDirectory(atPath: Self.legendaryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true)

        // Binario nativo de macOS del fork de Heroic (mismo origen y versión que usa Heroic).
        #if arch(arm64)
        let assetName = "legendary_macOS_arm64"
        #else
        let assetName = "legendary_macOS_x86_64"
        #endif
        let urlString = "https://github.com/Heroic-Games-Launcher/legendary/releases/download/\(Self.legendaryVersion)/\(assetName)"
        guard let downloadURL = URL(string: urlString) else {
            throw NSError(domain: "Vessel", code: 100,
                userInfo: [NSLocalizedDescriptionKey: "URL de Legendary inválida."])
        }

        onProgress("Descargando Legendary \(Self.legendaryVersion) (Epic Games)…")
        log.log("Legendary: descargando \(assetName) v\(Self.legendaryVersion) (fork Heroic)", level: .info)

        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(domain: "Vessel", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Descarga de Legendary falló: HTTP \(http.statusCode)"])
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let finalURL = URL(fileURLWithPath: Self.binaryPath)
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.binaryPath)

        onProgress("Quitando cuarentena y firmando Legendary…")
        await stripQuarantine(Self.binaryPath)
        await adhocSign(Self.binaryPath)

        guard FileManager.default.isExecutableFile(atPath: Self.binaryPath) else {
            throw NSError(domain: "Vessel", code: 101,
                userInfo: [NSLocalizedDescriptionKey: "Legendary se descargó pero no es ejecutable (\(Self.binaryPath))."])
        }

        log.log("✓ Legendary \(Self.legendaryVersion) listo en \(Self.binaryPath)", level: .info)
        return Self.binaryPath
    }

    // MARK: - Autenticación

    /// Devuelve `true` si hay una sesión activa guardada en el configDir de Vessel.
    func isAuthenticated() -> Bool {
        FileManager.default.fileExists(atPath: Self.userJSONPath)
    }

    /// Autentica con el **authorization code** capturado por el WebView de Epic.
    /// Ejecuta: `legendary auth --code <code>`.
    ///
    /// - Asegura que `configDir` existe antes de invocar el binario.
    /// - Verifica que las credenciales quedaron guardadas tras la ejecución.
    func authenticate(code: String) async throws {
        let bin = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            throw NSError(
                domain: "Vessel", code: 102,
                userInfo: [NSLocalizedDescriptionKey: "Legendary no está instalado. Llama antes a ensureInstalled."]
            )
        }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "Vessel", code: 103,
                userInfo: [NSLocalizedDescriptionKey: "El código de autorización está vacío."]
            )
        }

        // Garantizar que el directorio de configuración existe antes de ejecutar legendary
        // (si legendary se instaló en una sesión anterior, configDir puede no existir todavía).
        try? FileManager.default.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true)

        let result = try await runBackground(bin, args: ["auth", "--code", trimmed])
        if result.exitCode != 0 {
            log.log("Error al autenticar con Epic Games (exit \(result.exitCode)): \(result.combined)", level: .error)
            throw NSError(
                domain: "Vessel", code: 104,
                userInfo: [NSLocalizedDescriptionKey:
                    "Autenticación con Epic Games fallida. Comprueba que el código sea correcto y no haya caducado."]
            )
        }

        // Verificar que legendary guardó las credenciales correctamente.
        // Si el proceso terminó con éxito pero no hay user.json, el código había caducado.
        guard isAuthenticated() else {
            log.log("Auth exit 0 pero sin user.json. Output: \(result.combined)", level: .error)
            throw NSError(
                domain: "Vessel", code: 106,
                userInfo: [NSLocalizedDescriptionKey:
                    "La autenticación completó pero no se guardaron las credenciales. El código puede haber caducado. Inténtalo de nuevo."]
            )
        }

        log.log("✓ Autenticación de Epic Games correcta", level: .info)
    }

    /// Elimina el `user.json` de la config de Vessel → cierra sesión.
    func logout() {
        try? FileManager.default.removeItem(atPath: Self.userJSONPath)
        log.log("Sesión de Epic Games cerrada", level: .info)
    }

    // MARK: - Biblioteca de juegos

    /// Devuelve la lista completa de juegos de la cuenta (instalados y no instalados).
    func ownedGames() async throws -> [EpicGame] {
        let bin = Self.binaryPath

        // Juegos instalados localmente
        let installedResult = try await runBackground(bin, args: ["list-installed", "--json"])
        let installedNames: Set<String>
        if installedResult.exitCode == 0,
           let data = installedResult.stdout.data(using: .utf8) {
            installedNames = Set(extractAppNames(from: data))
        } else {
            installedNames = []
        }

        // Todos los juegos en propiedad. PLATAFORMA WINDOWS: Vessel ejecuta los juegos vía
        // Wine, así que se listan los de Windows (el default de legendary es Mac → filtraba
        // a ~136; con Windows aparecen los 550+ reales de la cuenta).
        let listResult = try await runBackground(bin, args: ["list", "--json", "--platform", "Windows"])
        guard listResult.exitCode == 0 else {
            log.log("Error al listar biblioteca Epic (exit \(listResult.exitCode)): \(listResult.combined)", level: .error)
            throw NSError(
                domain: "Vessel", code: 105,
                userInfo: [NSLocalizedDescriptionKey:
                    "No se pudo obtener la biblioteca de Epic Games. Comprueba tu conexión."]
            )
        }

        guard let data = listResult.stdout.data(using: .utf8) else { return [] }
        let games = parseGames(from: data, installedNames: installedNames)
        log.log("Biblioteca Epic: \(games.count) juego(s)", level: .info)
        return games
    }

    // MARK: - Instalación y lanzamiento (TODO)

    /// TODO: Instalar un juego vía `legendary install <appName>`.
    func installGame(appName: String, progress: @escaping @Sendable (String) -> Void) async throws {
        throw NSError(
            domain: "Vessel", code: 199,
            userInfo: [NSLocalizedDescriptionKey: "Instalación de juegos de Epic Games: próximamente."]
        )
    }

    /// TODO: Lanzar un juego con `legendary launch <appName>` usando el motor wine-dxmt.
    func launchGame(appName: String) async throws {
        throw NSError(
            domain: "Vessel", code: 200,
            userInfo: [NSLocalizedDescriptionKey: "Lanzamiento de juegos de Epic Games: próximamente."]
        )
    }

    // MARK: - Ejecución de subprocesos

    private struct RunResult {
        let exitCode: Int32
        let stdout: String   // salida estándar (el JSON de `--json` va aquí, LIMPIO)
        let stderr: String   // logs de legendary ([cli]/[Core] INFO…) — NUNCA mezclar con el JSON
        /// Texto combinado, solo para mensajes de error legibles (no para parsear JSON).
        var combined: String {
            if stdout.isEmpty { return stderr }
            if stderr.isEmpty { return stdout }
            return "\(stderr)\n\(stdout)"
        }
    }

    /// Ejecuta legendary en un hilo de fondo para no bloquear el actor principal.
    ///
    /// **Anti-deadlock**: drena stdout y stderr de forma CONCURRENTE mientras el proceso corre,
    /// usando `readabilityHandler` de FileHandle. Si se leyese la pipe DESPUÉS de
    /// `waitUntilExit()`, el proceso se bloquearía al llenarse el buffer del SO (~64 KB),
    /// causando un deadlock permanente en bibliotecas grandes.
    ///
    /// **Timeout de 90 s**: si legendary no termina, el proceso se mata y se lanza un error
    /// claro para que la UI nunca se quede en estado "cargando" para siempre.
    ///
    /// **Contexto no-async**: usa `DispatchQueue.global().async` (no `Task.detached`) para
    /// poder usar `DispatchGroup.wait()` y `DispatchSemaphore`, que están prohibidos en
    /// contextos async de Swift 6.
    ///
    /// Inyecta `LEGENDARY_CONFIG_PATH` apuntando al directorio aislado de Vessel.
    private func runBackground(_ binary: String, args: [String]) async throws -> RunResult {
        let configDir = Self.configDir
        let shellEnv  = WineManager.userShellEnvironment
        let timeout   = Self.processTimeoutSeconds

        // Envoltura @unchecked Sendable para acumular bytes de forma thread-safe
        // desde los readabilityHandlers (que se ejecutan en una cola interna de FileHandle).
        final class SafeBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var _data = Data()
            func append(_ chunk: Data) { lock.withLock { _data.append(chunk) } }
            var data: Data { lock.withLock { _data } }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RunResult, Error>) in
            // DispatchQueue.global().async → closure NO es async → DispatchGroup.wait() es legal.
            DispatchQueue.global(qos: .userInitiated).async {
                var env = shellEnv
                env["LEGENDARY_CONFIG_PATH"] = configDir
                env["TERM"] = "xterm-256color"
                // Desactivar el formateo de tabla para que --json sea limpio
                env["LEGENDARY_NO_BROWSER"] = "1"

                let task = Process()
                task.executableURL = URL(fileURLWithPath: binary)
                task.arguments = args
                task.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                task.standardOutput = stdoutPipe
                task.standardError  = stderrPipe

                let stdoutBuf = SafeBuffer()
                let stderrBuf = SafeBuffer()

                do {
                    try task.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }

                // Timeout: matar el proceso si tarda más de `timeout` segundos.
                let timeoutWork = DispatchWorkItem {
                    if task.isRunning { task.terminate() }
                }
                DispatchQueue.global(qos: .background).asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutWork
                )

                // Drenar AMBAS tuberías en hilos CONCURRENTES con readDataToEndOfFile, que
                // lee hasta EOF sin tope de buffer. Así nunca se llena el buffer del SO
                // (~64 KB) → imposible el deadlock que colgaba bibliotecas grandes (1 MB+).
                let drainGroup = DispatchGroup()
                drainGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stdoutBuf.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    drainGroup.leave()
                }
                drainGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrBuf.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    drainGroup.leave()
                }

                drainGroup.wait()        // ambas lecturas completas (EOF en los dos pipes)
                task.waitUntilExit()     // proceso terminado
                timeoutWork.cancel()

                let exitCode = task.terminationStatus

                // Detectar si el proceso fue matado por nuestro timeout (SIGTERM = 15)
                if task.terminationReason == .uncaughtSignal, exitCode == SIGTERM {
                    cont.resume(throwing: NSError(
                        domain: "Vessel", code: 108,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Legendary no respondió en \(Int(timeout)) s. Comprueba tu conexión e inténtalo de nuevo."]
                    ))
                    return
                }

                let stdout = String(data: stdoutBuf.data, encoding: .utf8) ?? ""
                let stderr = String(data: stderrBuf.data, encoding: .utf8) ?? ""
                cont.resume(returning: RunResult(exitCode: exitCode, stdout: stdout, stderr: stderr))
            }
        }
    }

    // MARK: - Firmas y cuarentena

    private func stripQuarantine(_ path: String) async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments     = ["-d", "com.apple.quarantine", path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    private func adhocSign(_ path: String) async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments     = ["--force", "--sign", "-", path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - Parseo JSON de Legendary

    /// Extrae los `app_name` de un array JSON (p. ej. de `list-installed --json`).
    private func extractAppNames(from data: Data) -> [String] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["app_name"] as? String }
    }

    /// Parsea el array JSON de `legendary list --json`.
    /// Admite tanto `title` como `app_title` por compatibilidad entre versiones de Legendary.
    private func parseGames(from data: Data, installedNames: Set<String>) -> [EpicGame] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { obj -> EpicGame? in
            guard let appName = obj["app_name"] as? String,
                  let title = (obj["title"] as? String) ?? (obj["app_title"] as? String),
                  !title.isEmpty
            else { return nil }
            return EpicGame(appName: appName, title: title,
                            installed: installedNames.contains(appName),
                            coverURL: Self.coverURL(from: obj))
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Extrae la URL de la portada vertical desde `metadata.keyImages`
    /// (preferencia DieselGameBoxTall, igual arte que muestra Epic/Heroic).
    private static func coverURL(from obj: [String: Any]) -> String? {
        guard let metadata = obj["metadata"] as? [String: Any],
              let keyImages = metadata["keyImages"] as? [[String: Any]] else { return nil }
        let preference = ["DieselGameBoxTall", "OfferImageTall", "Thumbnail", "DieselGameBox", "OfferImageWide"]
        for type in preference {
            if let img = keyImages.first(where: { ($0["type"] as? String) == type }),
               let url = img["url"] as? String, !url.isEmpty {
                return url
            }
        }
        return keyImages.first?["url"] as? String
    }
}
