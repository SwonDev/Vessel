import Foundation

/// Gestiona la instalación y uso de **Legendary** (cliente CLI de Epic Games).
///
/// Legendary se auto-descarga del repositorio `derrod/legendary` (binario macOS standalone).
/// La configuración se guarda en una carpeta PROPIA de Vessel para no interferir con la
/// configuración global que el usuario pueda tener en `~/.config/legendary`.
///
/// Modelo de uso (igual que Heroic): el usuario abre la página de Epic → inicia sesión →
/// copia el authorization code → lo pega en Vessel → biblioteca disponible.
@MainActor
@Observable
final class LegendaryManager {

    // MARK: - Tipos públicos

    struct EpicGame: Identifiable, Hashable {
        let appName: String
        let title: String
        var installed: Bool
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

    // MARK: - Instalación del binario

    /// Devuelve la ruta al binario de Legendary, descargándolo si aún no está.
    /// Idempotente: si ya existe, devuelve la ruta inmediatamente.
    func ensureInstalled(onProgress: @escaping @Sendable (String) -> Void) async throws -> String {
        if FileManager.default.isExecutableFile(atPath: Self.binaryPath) {
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

    /// URL de inicio de sesión de Epic Games (redirige al portal OAuth de Epic).
    var authURL: URL { URL(string: "https://legendary.gl/epiclogin")! }

    /// Autentica con el **authorization code** del portal de Epic.
    /// Ejecuta: `legendary auth --code <code>`.
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

        let result = try await runBackground(bin, args: ["auth", "--code", trimmed])
        if result.exitCode != 0 {
            log.log("Error al autenticar con Epic Games: \(result.output)", level: .error)
            throw NSError(
                domain: "Vessel", code: 104,
                userInfo: [NSLocalizedDescriptionKey:
                    "Autenticación con Epic Games fallida. Comprueba que el código sea correcto y no haya caducado.\n\(result.output)"]
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
           let data = installedResult.output.data(using: .utf8) {
            installedNames = Set(extractAppNames(from: data))
        } else {
            installedNames = []
        }

        // Todos los juegos en propiedad
        let listResult = try await runBackground(bin, args: ["list", "--json"])
        guard listResult.exitCode == 0 else {
            log.log("Error al listar biblioteca Epic: \(listResult.output)", level: .error)
            throw NSError(
                domain: "Vessel", code: 105,
                userInfo: [NSLocalizedDescriptionKey:
                    "No se pudo obtener la biblioteca de Epic Games. Comprueba tu conexión.\n\(listResult.output)"]
            )
        }

        guard let data = listResult.output.data(using: .utf8) else { return [] }
        let games = parseGames(from: data, installedNames: installedNames)
        log.log("Biblioteca Epic: \(games.count) juego(s)", level: .info)
        return games
    }

    // MARK: - Instalación y lanzamiento (TODO)

    /// TODO: Instalar un juego vía `legendary install <appName>`.
    func installGame(appName: String, progress: @escaping @Sendable (String) -> Void) async throws {
        // TODO: Implementar descarga e instalación de juegos de Epic Games vía Legendary.
        //       Gestionar el bottle de Wine correcto, rutas de instalación en VesselPaths, etc.
        throw NSError(
            domain: "Vessel", code: 199,
            userInfo: [NSLocalizedDescriptionKey: "Instalación de juegos de Epic Games: próximamente."]
        )
    }

    /// TODO: Lanzar un juego con `legendary launch <appName>` usando el motor wine-dxmt.
    func launchGame(appName: String) async throws {
        // TODO: Implementar lanzamiento de juegos de Epic Games vía Legendary + wine-dxmt.
        //       Reutilizar la arquitectura de doble motor: wine-dxmt para D3D11, igual que Steam.
        throw NSError(
            domain: "Vessel", code: 200,
            userInfo: [NSLocalizedDescriptionKey: "Lanzamiento de juegos de Epic Games: próximamente."]
        )
    }

    // MARK: - Ejecución de subprocesos

    private struct RunResult {
        let exitCode: Int32
        let output: String
    }

    /// Ejecuta legendary en un hilo de fondo para no bloquear el actor principal.
    /// Inyecta `LEGENDARY_CONFIG_PATH` apuntando al directorio aislado de Vessel.
    private func runBackground(_ binary: String, args: [String]) async throws -> RunResult {
        // Capturar los valores fuera del Task.detached para evitar capturar self
        let configDir = Self.configDir
        let shellEnv  = WineManager.userShellEnvironment

        return try await withCheckedThrowingContinuation { cont in
            Task.detached(priority: .userInitiated) {
                var env = shellEnv
                env["LEGENDARY_CONFIG_PATH"] = configDir
                env["TERM"] = "xterm-256color"
                // Desactivar el formateo de tabla para que --json sea limpio
                env["LEGENDARY_NO_BROWSER"] = "1"

                let task = Process()
                task.executableURL = URL(fileURLWithPath: binary)
                task.arguments = args
                task.environment = env

                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError  = pipe

                do {
                    try task.run()
                    task.waitUntilExit()
                    let data   = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(returning: RunResult(exitCode: task.terminationStatus, output: output))
                } catch {
                    cont.resume(throwing: error)
                }
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
            return EpicGame(appName: appName, title: title, installed: installedNames.contains(appName))
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
