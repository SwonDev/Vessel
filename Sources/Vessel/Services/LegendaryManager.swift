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

    struct EpicGame: Identifiable, Hashable, Codable {
        let appName: String
        let title: String
        var installed: Bool
        var coverURL: String?
        var installPath: String?     // carpeta de instalación (si está instalado)
        var executablePath: String?  // .exe principal en macOS (ruta del prefijo)
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

        // Juegos instalados localmente (con su ruta de instalación y ejecutable).
        let installedResult = try await runBackground(bin, args: ["list-installed", "--json"])
        var installed: [String: (installPath: String, executable: String)] = [:]
        if installedResult.exitCode == 0,
           let data = installedResult.stdout.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for obj in arr {
                guard let name = obj["app_name"] as? String else { continue }
                installed[name] = ((obj["install_path"] as? String) ?? "",
                                   (obj["executable"] as? String) ?? "")
            }
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
        let games = parseGames(from: data, installed: installed)
        log.log("Biblioteca Epic: \(games.count) juego(s)", level: .info)
        LibraryCache.save("epic", games)   // para carga instantánea la próxima vez
        return games
    }

    // MARK: - Instalación y lanzamiento (TODO)

    /// Instala un juego de Epic en `basePath` (dentro del bottle de Vessel), reportando el
    /// progreso por las líneas de salida de legendary. Operación larga (sin timeout corto).
    func installGame(appName: String, basePath: String, onProgress: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true)
        let code = try await runStreaming(
            Self.binaryPath,
            args: ["install", appName, "--base-path", basePath, "--platform", "Windows", "--yes"],
            onLine: onProgress
        )
        guard code == 0 else {
            throw NSError(domain: "Vessel", code: 110, userInfo: [NSLocalizedDescriptionKey:
                "La instalación de Epic falló (código \(code)). Revisa los logs."])
        }
        log.log("✓ Epic: \(appName) instalado en \(basePath)", level: .info)
    }

    /// Verifica y REPARA los archivos de un juego de Epic ya instalado. `repair` es un alias de
    /// `install` en legendary: re-descarga SOLO los trozos dañados o ausentes. Mismo progreso.
    func repairGame(appName: String, basePath: String, onProgress: @escaping @Sendable (String) -> Void) async throws {
        let code = try await runStreaming(
            Self.binaryPath,
            args: ["repair", appName, "--base-path", basePath, "--platform", "Windows", "--yes"],
            onLine: onProgress
        )
        guard code == 0 else {
            throw NSError(domain: "Vessel", code: 111, userInfo: [NSLocalizedDescriptionKey:
                "La verificación de Epic falló (código \(code)). Revisa los logs."])
        }
        log.log("✓ Epic: \(appName) verificado/reparado", level: .info)
    }

    /// Aplica la actualización de un juego de Epic (`legendary update`, alias de install).
    func updateGame(appName: String, basePath: String, onProgress: @escaping @Sendable (String) -> Void) async throws {
        let code = try await runStreaming(
            Self.binaryPath,
            args: ["update", appName, "--base-path", basePath, "--platform", "Windows", "--yes"],
            onLine: onProgress
        )
        guard code == 0 else {
            throw NSError(domain: "Vessel", code: 112, userInfo: [NSLocalizedDescriptionKey:
                "La actualización de Epic falló (código \(code)). Revisa los logs."])
        }
        log.log("✓ Epic: \(appName) actualizado", level: .info)
    }

    enum SaveSyncDirection { case download, upload, both }

    /// Sincroniza las partidas guardadas en la nube de Epic (`legendary sync-saves`). legendary
    /// RESUELVE SOLO la ruta de guardado del juego (no hay que adivinarla). Se usa DIRECCIONAL a
    /// propósito (`--skip-upload` para bajar antes de jugar, `--skip-download` para subir al
    /// cerrar): así NO hay prompt de conflicto y el subproceso nunca se cuelga. Silencioso: si el
    /// juego no soporta cloud saves, legendary lo informa y termina sin romper nada.
    func syncSaves(appName: String, direction: SaveSyncDirection) async {
        var args = ["sync-saves", appName]
        switch direction {
        case .download: args.append("--skip-upload")
        case .upload:   args.append("--skip-download")
        case .both:     break
        }
        guard let result = try? await runBackground(Self.binaryPath, args: args) else { return }
        if result.exitCode == 0 {
            log.log("Epic: cloud saves sincronizados (\(appName), \(direction))", level: .debug)
        }
    }

    /// Devuelve los `appName` de juegos INSTALADOS con actualización disponible
    /// (`legendary list-installed --check-updates --json` → campo `update_available`).
    /// Silencioso ante fallos (devuelve vacío): es información orientativa, no crítica.
    func gamesWithUpdates() async -> Set<String> {
        guard let result = try? await runBackground(Self.binaryPath, args: ["list-installed", "--check-updates", "--json"]),
              result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var updates: Set<String> = []
        for obj in arr where (obj["update_available"] as? Bool) == true {
            if let name = obj["app_name"] as? String { updates.insert(name) }
        }
        return updates
    }

    /// Ejecuta legendary para una operación LARGA (instalación), drenando la salida en vivo
    /// y reportando cada línea de progreso. Sin timeout: las descargas pueden durar mucho.
    private func runStreaming(_ binary: String, args: [String], onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let configDir = Self.configDir
        let shellEnv  = WineManager.userShellEnvironment
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var env = shellEnv
                env["LEGENDARY_CONFIG_PATH"] = configDir
                let task = Process()
                task.executableURL = URL(fileURLWithPath: binary)
                task.arguments = args
                task.environment = env
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError  = pipe
                pipe.fileHandleForReading.readabilityHandler = { fh in
                    let d = fh.availableData
                    guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                    for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) where !line.isEmpty {
                        onLine(String(line))
                    }
                }
                do { try task.run() } catch { cont.resume(throwing: error); return }
                task.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: task.terminationStatus)
            }
        }
    }

    /// Extrae el porcentaje de descarga (0–100) de una línea de salida de legendary.
    /// Formato: `[DLManager] INFO: = Progress: 45.30% (1234/2722), Running for 00:01:23, ETA: …`.
    nonisolated static func progressPercent(in line: String) -> Double? {
        guard let r = line.range(of: "Progress:") else { return nil }
        let tail = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        let num = tail.prefix { $0.isNumber || $0 == "." }
        return Double(num)
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
    private func parseGames(from data: Data, installed: [String: (installPath: String, executable: String)]) -> [EpicGame] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { obj -> EpicGame? in
            guard let appName = obj["app_name"] as? String,
                  let title = (obj["title"] as? String) ?? (obj["app_title"] as? String),
                  !title.isEmpty
            else { return nil }
            let info = installed[appName]
            // executable de legendary es relativo a install_path (salvo que sea absoluto).
            let exePath: String? = info.flatMap { i in
                guard !i.executable.isEmpty else { return nil }
                if i.executable.hasPrefix("/") { return i.executable }
                return i.installPath.isEmpty ? i.executable : "\(i.installPath)/\(i.executable)"
            }
            return EpicGame(appName: appName, title: title,
                            installed: info != nil,
                            coverURL: Self.coverURL(from: obj),
                            installPath: info?.installPath,
                            executablePath: exePath)
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
