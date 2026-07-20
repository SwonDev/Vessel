import Foundation
import Darwin

/// Gestiona **SteamCMD** (cliente de línea de comandos de Steam) para instalar juegos
/// de forma ROBUSTA, sin depender del frágil cliente GUI bajo Wine. Descarga los
/// archivos **Windows** del juego (`ForcePlatformType windows`) directo a la carpeta
/// del bottle; luego Vessel los lanza con su motor. Login con la cuenta del usuario
/// (SteamCMD recuerda la sesión tras el primer inicio con Steam Guard).
@MainActor
@Observable
final class SteamCMDManager {
    enum LoginResult: Equatable {
        case ok
        case needsGuard          // pide código de Steam Guard / 2FA
        case invalidPassword
        case failed(String)
    }

    static let downloadURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!

    var dir: String { "\(VesselPaths.cacheDirectory)/steamcmd" }
    var scriptPath: String { "\(dir)/steamcmd.sh" }
    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: scriptPath) }

    private let log = LogStore.shared
    nonisolated private let processRegistry = ManagedProcessRegistry()

    // MARK: - Instalación de SteamCMD

    func ensureInstalled() async throws {
        if isInstalled { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        log.log("Descargando SteamCMD…", level: .info)
        let (tmp, response) = try await URLSession.shared.download(from: Self.downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Vessel", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Descarga de SteamCMD falló: HTTP \(http.statusCode)"])
        }
        let dest = "\(dir)/steamcmd_osx.tar.gz"
        try? FileManager.default.removeItem(atPath: dest)
        try FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: dest))
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xzf", dest, "-C", dir]
        try task.run(); task.waitUntilExit()
        guard isInstalled else {
            throw NSError(domain: "Vessel", code: 40, userInfo: [NSLocalizedDescriptionKey: "SteamCMD se descargó pero no se encontró steamcmd.sh"])
        }
        // Primer arranque: se auto-actualiza.
        _ = await run(arguments: ["+quit"], onLine: nil)
    }

    // MARK: - Login

    /// Inicia sesión. SteamCMD guarda la sesión (sentry) tras el primer login con
    /// Steam Guard, así que las siguientes instalaciones no piden el código.
    func login(user: String, password: String, guardCode: String?) async -> LoginResult {
        var loginCmd = "+login \(shellQuote(user)) \(shellQuote(password))"
        if let code = guardCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
            loginCmd += " \(shellQuote(code))"
        }
        let (output, _) = await run(arguments: [loginCmd, "+quit"], onLine: nil)
        let lower = output.lowercased()
        if lower.contains("waiting for user info...ok") || lower.contains("logged in ok") {
            return .ok
        }
        if lower.contains("two-factor") || lower.contains("steam guard") || lower.contains("twofactorcode") {
            return .needsGuard
        }
        if lower.contains("invalid password") || lower.contains("invalidpassword") {
            return .invalidPassword
        }
        return .failed(Self.lastError(in: output))
    }

    /// True si SteamCMD ya tiene sesión recordada para `user` (sin pedir 2FA).
    func hasSession(user: String) async -> Bool {
        let (output, _) = await run(arguments: ["+login \(shellQuote(user))", "+quit"], onLine: nil)
        return output.lowercased().contains("waiting for user info...ok") || output.lowercased().contains("logged in ok")
    }

    // MARK: - Instalar juego

    /// Descarga/instala el juego (archivos Windows) en `installDir`. Llama `onProgress`
    /// con el porcentaje (0–100) y un mensaje. Devuelve true si terminó OK.
    /// Instala/actualiza/verifica un juego con SteamCMD. `validate` fuerza la comprobación de
    /// integridad (re-hash de TODOS los ficheros): necesaria para instalar y para "Verificar/
    /// reparar", pero innecesaria y lenta para una simple "Actualización" (que es incremental).
    func installGame(
        appId: String,
        user: String,
        installDir: String,
        validate: Bool = true,
        operationID: String? = nil,
        onProgress: @escaping @MainActor (Double, String) -> Void
    ) async -> Bool {
        try? FileManager.default.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        let executionID = operationID ?? "steamcmd-\(UUID().uuidString)"
        processRegistry.prepare(executionID)
        let args = [
            "+@sSteamCmdForcePlatformType windows",
            "+force_install_dir \(shellQuote(installDir))",
            "+login \(shellQuote(user))",
            "+app_update \(appId)\(validate ? " validate" : "")",
            "+quit"
        ]
        var success = false
        // Estimador de velocidad (media móvil ~15 s) y ETA: la línea de steamcmd trae los bytes
        // ("progress: 45.30 (1234 / 5678)") — con ellos el mensaje pasa a ser estilo Steam:
        // "Descargando… 45 % · 12,3 MB/s · quedan 3 min" (antes solo el %, sin velocidad ni ETA).
        var samples: [(at: Date, bytes: Int64)] = []
        let (output, code) = await withTaskCancellationHandler {
            await run(arguments: args, operationID: executionID) { line in
                let l = line.lowercased()
                if let pct = Self.progressPercent(in: line) {
                    var message = "Descargando… \(Int(pct))%"
                    if let (done, total) = Self.progressBytes(in: line), total > 0 {
                        let now = Date()
                        samples.append((now, done))
                        samples.removeAll { now.timeIntervalSince($0.at) > 15 }
                        if let first = samples.first, samples.count >= 2 {
                            let dt = now.timeIntervalSince(first.at)
                            let db = done - first.bytes
                            if dt > 0.5, db > 0 {
                                let speed = Double(db) / dt   // bytes/s
                                let mb = speed / 1_000_000
                                message += String(format: " · %.1f MB/s", mb)
                                let remaining = Double(total - done) / speed
                                if remaining > 1, remaining.isFinite {
                                    message += " · quedan \(Self.formatETA(seconds: remaining))"
                                }
                            }
                        }
                    }
                    onProgress(pct, message)
                } else if l.contains("fully installed") {
                    onProgress(100, "Instalación completada")
                } else if l.contains("already up to date") {
                    onProgress(100, "Ya está actualizado")
                } else if l.contains("validating") {
                    onProgress(0, "Verificando…")
                }
            }
        } onCancel: {
            processRegistry.cancel(executionID)
        }
        guard !Task.isCancelled else { return false }
        success = Self.appUpdateSucceeded(in: output, exitCode: code)
        return success
    }

    /// Interrumpe una operación concreta. SteamCMD conserva su staging y una ejecución posterior
    /// continúa desde el punto descargado, lo que permite pausar sin corromper la instalación.
    nonisolated func cancel(operationID: String) {
        processRegistry.cancel(operationID)
    }

    /// Compara en una sola sesión de SteamCMD los `buildid` locales con la rama pública remota.
    /// Se usa solo para juegos cuyo appmanifest contiene una versión real (> 0).
    func gamesWithUpdates(localBuildIDs: [String: String]) async -> Set<String> {
        let comparable = localBuildIDs.filter { !$0.key.isEmpty && (Int($0.value) ?? 0) > 0 }
        guard isInstalled, !comparable.isEmpty else { return [] }
        var arguments = ["+login anonymous", "+app_info_update 1"]
        arguments.append(contentsOf: comparable.keys.sorted().map { "+app_info_print \($0)" })
        arguments.append("+quit")
        let (output, code) = await run(arguments: arguments, onLine: nil)
        guard code == 0 else { return [] }
        let remote = Self.publicBuildIDs(in: output)
        return Set(comparable.compactMap { appID, localBuild in
            guard let remoteBuild = remote[appID], remoteBuild != localBuild else { return nil }
            return appID
        })
    }

    /// Manifiestos que pueden describir una instalación de Vessel, por orden de autoridad.
    ///
    /// SteamCMD escribe el manifiesto que realmente actualiza dentro de `force_install_dir`,
    /// mientras el cliente Steam del bottle conserva su propia copia en la biblioteca. Cuando
    /// Vessel actualiza un juego instalado por SteamCMD, esa segunda copia puede quedar antigua;
    /// leerla primero hacía reaparecer «Actualización disponible» tras completar la descarga.
    nonisolated static func appManifestPaths(
        appID: String,
        installPath: String,
        steamDirectory: String
    ) -> [String] {
        var paths: [String] = []
        if !installPath.isEmpty {
            paths.append("\(installPath)/steamapps/appmanifest_\(appID).acf")
        }
        let clientManifest = "\(steamDirectory)/steamapps/appmanifest_\(appID).acf"
        if !paths.contains(clientManifest) { paths.append(clientManifest) }
        return paths
    }

    /// Devuelve la build instalada por la fuente que realmente gestiona los archivos. Solo acepta
    /// manifiestos terminados (`StateFlags & 4`) para que una descarga parcial no se anuncie como
    /// actualizada. Los manifiestos antiguos sin `StateFlags` mantienen compatibilidad.
    nonisolated static func installedBuildID(
        appID: String,
        installPath: String,
        steamDirectory: String,
        contentsAtPath: (String) -> String?
    ) -> String? {
        for path in appManifestPaths(
            appID: appID,
            installPath: installPath,
            steamDirectory: steamDirectory
        ) {
            guard let manifest = contentsAtPath(path),
                  let buildID = manifestValue(named: "buildid", in: manifest),
                  (Int(buildID) ?? 0) > 0 else { continue }
            if let rawFlags = manifestValue(named: "StateFlags", in: manifest),
               let flags = Int(rawFlags), flags & 4 == 0 {
                continue
            }
            return buildID
        }
        return nil
    }

    nonisolated private static func manifestValue(named key: String, in manifest: String) -> String? {
        for line in manifest.split(separator: "\n") {
            let fields = line.split(separator: "\"").map(String.init)
            guard fields.count >= 4,
                  fields[1].caseInsensitiveCompare(key) == .orderedSame else { continue }
            let value = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Ejecución

    /// Ejecuta SteamCMD a través de un login shell (entorno completo, necesario para
    /// Rosetta/SteamCMD). Transmite cada línea de salida a `onLine`.
    private func run(
        arguments: [String],
        operationID: String? = nil,
        onLine: (@MainActor (String) -> Void)?
    ) async -> (output: String, exitCode: Int32) {
        let command = "cd \(shellQuote(dir)) && exec ./steamcmd.sh \(arguments.joined(separator: " "))"
        let processRegistry = self.processRegistry
        return await withCheckedContinuation { (continuation: CheckedContinuation<(String, Int32), Never>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lic", command]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                // CLAVE: stdin NULO. Sin esto, un `+login <user>` sin sesión cacheada hace que
                // steamcmd PIDA la contraseña por stdin y se quede COLGADO PARA SIEMPRE (la app no
                // tiene terminal) → el install "no hacía nada". Con stdin nulo recibe EOF y sale.
                process.standardInput = FileHandle.nullDevice
                let buffer = OutputBuffer()
                // Watchdog POR INACTIVIDAD (no por duración total): una descarga grande puede
                // tardar más de 45 min (antes se mataba el steamcmd a los 45 min pese a ir bien —
                // así murieron varias instalaciones de >5 GB). Solo se mata si lleva 20 min SIN
                // escribir una línea (atasco real). La actividad se marca en el readabilityHandler.
                let activity = ActivityMarker()
                pipe.fileHandleForReading.readabilityHandler = { fh in
                    let data = fh.availableData
                    activity.mark()
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    buffer.append(chunk)
                    if let onLine {
                        for line in chunk.split(separator: "\n") {
                            let s = String(line)
                            Task { @MainActor in onLine(s) }
                        }
                    }
                }
                do {
                    try process.run()
                } catch {
                    if let operationID { processRegistry.finish(operationID) }
                    continuation.resume(returning: (error.localizedDescription, -1))
                    return
                }
                let processGroupID: pid_t? = setpgid(process.processIdentifier, process.processIdentifier) == 0
                    ? process.processIdentifier
                    : nil
                if let operationID {
                    processRegistry.register(process, processGroupID: processGroupID, for: operationID)
                }
                let watchdog = DispatchWorkItem {
                    while process.isRunning {
                        if activity.secondsSinceLastMark() > 1200 {
                            if let operationID { processRegistry.cancel(operationID) }
                            else { process.terminate() }
                            break
                        }
                        Thread.sleep(forTimeInterval: 30)
                    }
                }
                DispatchQueue.global().async(execute: watchdog)
                process.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                if let operationID { processRegistry.finish(operationID) }
                continuation.resume(returning: (buffer.value, process.terminationStatus))
            }
        }
    }

    /// Acumulador thread-safe de la salida (el readabilityHandler corre en otro hilo).
    private final class OutputBuffer: @unchecked Sendable {
        private var storage = ""
        private let lock = NSLock()
        func append(_ chunk: String) { lock.lock(); storage += chunk; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// Marca de actividad thread-safe para el watchdog por inactividad.
    private final class ActivityMarker: @unchecked Sendable {
        private var last = Date()
        private let lock = NSLock()
        func mark() { lock.lock(); last = Date(); lock.unlock() }
        func secondsSinceLastMark() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last)
        }
    }

    // MARK: - Helpers

    nonisolated private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func progressPercent(in line: String) -> Double? {
        // "Update state (0x61) downloading, progress: 45.30 (1234 / 5678)"
        guard line.lowercased().contains("progress:") else { return nil }
        let parts = line.components(separatedBy: "progress:")
        guard parts.count > 1 else { return nil }
        let tail = parts[1].trimmingCharacters(in: .whitespaces)
        let num = tail.prefix { $0.isNumber || $0 == "." }
        return Double(num)
    }

    /// Bytes descargados y totales de la línea de progreso de steamcmd: "(1234 / 5678)".
    nonisolated static func progressBytes(in line: String) -> (done: Int64, total: Int64)? {
        guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), close > open else { return nil }
        let inner = line[line.index(after: open)..<close]
        let parts = inner.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let done = Int64(parts[0]), let total = Int64(parts[1]) else { return nil }
        return (done, total)
    }

    /// ETA legible: "< 1 min", "3 min", "1 h 12 min".
    nonisolated static func formatETA(seconds: Double) -> String {
        if seconds < 60 { return "< 1 min" }
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let h = totalMinutes / 60, m = totalMinutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    nonisolated static func lastError(in output: String) -> String {
        let lines = output.split(separator: "\n").map(String.init)
        if let err = lines.last(where: { $0.lowercased().contains("error") || $0.lowercased().contains("failed") }) {
            return err.trimmingCharacters(in: .whitespaces)
        }
        return "No se pudo completar la operación de SteamCMD."
    }

    /// SteamCMD puede devolver código 0 incluso ante algunos errores de contenido, por lo que el
    /// estado de salida no basta. Aceptamos únicamente sus dos confirmaciones finales reales:
    /// descarga/verificación completada o aplicación que ya estaba al día. Esta segunda respuesta
    /// es normal al reintentar una actualización y antes se convertía falsamente en fallo.
    nonisolated static func appUpdateSucceeded(in output: String, exitCode: Int32) -> Bool {
        guard exitCode == 0 else { return false }
        return output.split(whereSeparator: \.isNewline).reversed().contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard line.contains("success! app '") else { return false }
            return line.contains("fully installed") || line.contains("already up to date")
        }
    }

    nonisolated static func sizeOnDisk(in manifest: String) -> Int64? {
        for line in manifest.split(separator: "\n") where line.lowercased().contains("\"sizeondisk\"") {
            let fields = line.split(separator: "\"").map(String.init)
            if let value = fields.last(where: { Int64($0.trimmingCharacters(in: .whitespaces)) != nil }) {
                return Int64(value.trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Extrae el `buildid` de la rama `public` de cada bloque `app_info_print`.
    nonisolated static func publicBuildIDs(in output: String) -> [String: String] {
        guard let appRegex = try? NSRegularExpression(pattern: #"(?m)^AppID\s*:\s*(\d+)"#),
              let branchRegex = try? NSRegularExpression(
                pattern: #"(?s)\"branches\"\s*\{.*?\"public\"\s*\{.*?\"buildid\"\s*\"(\d+)\""#
              ) else { return [:] }
        let ns = output as NSString
        let matches = appRegex.matches(in: output, range: NSRange(location: 0, length: ns.length))
        var result: [String: String] = [:]
        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges > 1 else { continue }
            let appID = ns.substring(with: match.range(at: 1))
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard end > start else { continue }
            let blockRange = NSRange(location: start, length: end - start)
            guard let branch = branchRegex.firstMatch(in: output, range: blockRange),
                  branch.numberOfRanges > 1 else { continue }
            result[appID] = ns.substring(with: branch.range(at: 1))
        }
        return result
    }
}
