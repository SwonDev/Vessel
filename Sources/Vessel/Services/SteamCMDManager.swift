import Foundation

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
    func installGame(appId: String, user: String, installDir: String, onProgress: @escaping @MainActor (Double, String) -> Void) async -> Bool {
        try? FileManager.default.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        let args = [
            "+@sSteamCmdForcePlatformType windows",
            "+force_install_dir \(shellQuote(installDir))",
            "+login \(shellQuote(user))",
            "+app_update \(appId) validate",
            "+quit"
        ]
        var success = false
        let (output, code) = await run(arguments: args) { line in
            let l = line.lowercased()
            if let pct = Self.progressPercent(in: line) {
                onProgress(pct, "Descargando… \(Int(pct))%")
            } else if l.contains("fully installed") {
                onProgress(100, "Instalación completada")
            } else if l.contains("validating") {
                onProgress(0, "Verificando…")
            }
        }
        if output.lowercased().contains("fully installed") || code == 0 {
            success = output.lowercased().contains("fully installed")
        }
        return success
    }

    // MARK: - Ejecución

    /// Ejecuta SteamCMD a través de un login shell (entorno completo, necesario para
    /// Rosetta/SteamCMD). Transmite cada línea de salida a `onLine`.
    private func run(arguments: [String], onLine: (@MainActor (String) -> Void)?) async -> (output: String, exitCode: Int32) {
        let command = "cd \(shellQuote(dir)) && ./steamcmd.sh \(arguments.joined(separator: " "))"
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
                pipe.fileHandleForReading.readabilityHandler = { fh in
                    let data = fh.availableData
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
                    continuation.resume(returning: (error.localizedDescription, -1))
                    return
                }
                // Cinturón de seguridad extra: si algo se cuelga (descarga atascada), matar a los
                // 45 min. Las descargas grandes caben de sobra; un login/validate es de segundos.
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2700, execute: watchdog)
                process.waitUntilExit()
                watchdog.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
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

    nonisolated static func lastError(in output: String) -> String {
        let lines = output.split(separator: "\n").map(String.init)
        if let err = lines.last(where: { $0.lowercased().contains("error") || $0.lowercased().contains("failed") }) {
            return err.trimmingCharacters(in: .whitespaces)
        }
        return "No se pudo completar la operación de SteamCMD."
    }
}
