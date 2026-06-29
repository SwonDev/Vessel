import Foundation

/// Gestiona la instalación y uso de **gogdl** (cliente CLI de GOG, proyecto de Heroic Games Launcher).
///
/// ## Estrategia de instalación (dos niveles):
///
/// 1. **Binario compilado de GitHub** (preferido): se busca en la última release de
///    `Heroic-Games-Launcher/gogdl` un asset macOS/arm64. Si lo hay, se descarga,
///    se le quita la cuarentena y se firma ad-hoc. Es el mismo flujo que Legendary.
///
/// 2. **Python venv** (fallback): si no se publica un binario macOS en esa release,
///    se crea un venv en `gogdlDir/venv` con el Python de sistema (`/usr/bin/python3`)
///    y se instala gogdl directamente del repositorio git con pip.
///    → Requiere que Xcode Command Line Tools estén instalados (git + python3).
///    → El binario queda en `gogdlDir/venv/bin/gogdl`.
///
/// La configuración se guarda en `~/Library/Application Support/Vessel/Gog` para no
/// interferir con la instalación de Heroic que el usuario pueda tener en el sistema.
///
/// ## Notas sobre la CLI de gogdl
///
/// TODO: Verificar flags exactos con `gogdl --help` en la versión instalada. Los usados
/// aquí son los habituales en el código fuente de Heroic (Python argparse):
/// - Auth:         `gogdl auth --code <code> --auth-config-path <dir>`
/// - Lista juegos: `gogdl games list --auth-config-path <dir>`
/// - Descarga:     `gogdl download <appName> --auth-config-path <dir> --path <installPath>`
/// - Lanzar:       mediante wine-dxmt desde Vessel (sin delegar en gogdl, igual que Steam/Epic).
@MainActor
@Observable
final class GogdlManager {

    // MARK: - Tipos públicos

    struct GogGame: Identifiable, Hashable {
        /// Identificador numérico de GOG (appId).
        let appId: String
        let title: String
        var installed: Bool
        var id: String { appId }
    }

    // MARK: - Rutas (estáticas)

    /// Directorio base de gogdl dentro de los motores de Vessel.
    static let gogdlDir    = "\(VesselPaths.enginesDirectory)/gogdl"
    /// Ruta del binario compilado descargado de GitHub.
    static let binaryPath  = "\(gogdlDir)/gogdl"
    /// Directorio del venv de Python (fallback si no hay binario en GitHub).
    static let venvDir     = "\(gogdlDir)/venv"
    /// Ruta del binario gogdl dentro del venv.
    static let venvBinary  = "\(venvDir)/bin/gogdl"
    /// Directorio de configuración y credenciales aislado de Vessel.
    static let configDir   = "\(VesselPaths.appSupport)/Gog"

    /// Archivo de credenciales que gogdl crea tras autenticarse correctamente.
    /// (gogdl guarda tokens en `credentials` dentro del `--auth-config-path`.)
    private static let credentialsPath = "\(configDir)/credentials"

    // MARK: - Modelos GitHub API

    private struct GHRelease: Decodable {
        let tagName: String
        let assets: [GHAsset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"; case assets
        }
    }

    private struct GHAsset: Decodable {
        let name: String
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey {
            case name; case browserDownloadURL = "browser_download_url"
        }
    }

    // MARK: - Estado

    private let log = LogStore.shared

    // MARK: - Instalación del binario

    /// Devuelve la ruta al binario de gogdl, instalándolo si aún no está disponible.
    ///
    /// Orden de preferencia:
    /// 1. Binario compilado ya descargado (`binaryPath`).
    /// 2. Binario dentro del venv ya creado (`venvBinary`).
    /// 3. Descarga del binario desde GitHub releases (si hay asset macOS).
    /// 4. Creación de venv Python + pip install desde git (fallback).
    func ensureInstalled(onProgress: @escaping @Sendable (String) -> Void) async throws -> String {
        // ── Caso 1: binario directo ya listo ──────────────────────────────────
        if FileManager.default.isExecutableFile(atPath: Self.binaryPath) {
            return Self.binaryPath
        }
        // ── Caso 2: venv ya creado ────────────────────────────────────────────
        if FileManager.default.isExecutableFile(atPath: Self.venvBinary) {
            return Self.venvBinary
        }

        // Asegurar directorios
        try FileManager.default.createDirectory(atPath: Self.gogdlDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true)

        // ── Caso 3: intentar binario de GitHub ───────────────────────────────
        onProgress("Buscando última versión de gogdl (GOG)…")
        do {
            let bin = try await downloadBinaryFromGitHub(onProgress: onProgress)
            return bin
        } catch GogdlError.noBinaryForMacOS {
            // No hay binario macOS publicado en esta release → fallback a venv
            log.log("gogdl: no hay binario macOS en GitHub releases, instalando vía Python venv…", level: .info)
        }
        // otros errores de red los propagamos (el usuario verá el mensaje)

        // ── Caso 4: venv Python ───────────────────────────────────────────────
        return try await installViaVenv(onProgress: onProgress)
    }

    // MARK: - Autenticación

    /// `true` si hay una sesión GOG activa guardada en el configDir de Vessel.
    func isAuthenticated() -> Bool {
        // gogdl escribe el archivo `credentials` en el --auth-config-path tras auth correcto.
        // También comprobamos `user.json` por si la versión cambia el nombre.
        FileManager.default.fileExists(atPath: Self.credentialsPath)
        || FileManager.default.fileExists(atPath: "\(Self.configDir)/user.json")
    }

    /// URL de inicio de sesión de GOG (la misma que usa Heroic Launcher).
    /// El usuario inicia sesión y GOG redirige a `embed.gog.com/on_login_success?…&code=<code>`.
    /// El usuario debe copiar el valor del parámetro `code` de esa URL.
    var authURL: URL {
        URL(string:
            "https://auth.gog.com/auth"
            + "?client_id=46899977096215655"
            + "&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient"
            + "&response_type=code"
            + "&layout=client2"
        )!
    }

    /// Autentica con el **authorization code** obtenido de la URL de redirección de GOG.
    /// Ejecuta: `gogdl auth --code <code> --auth-config-path <configDir>`.
    ///
    /// TODO: Verificar que el flag sea `--auth-config-path` con `gogdl auth --help`.
    ///       En algunas versiones puede ser `--config-path` o simplemente una variable
    ///       de entorno `GOGDL_CONFIG_PATH`.
    func authenticate(code: String) async throws {
        let bin = try resolvedBinaryPath()
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GogdlError.emptyCode
        }

        let result = try await runBackground(
            bin,
            args: ["auth", "--code", trimmed, "--auth-config-path", Self.configDir]
        )
        if result.exitCode != 0 {
            log.log("Error al autenticar con GOG: \(result.output)", level: .error)
            throw GogdlError.authFailed(result.output)
        }
        log.log("✓ Autenticación de GOG correcta", level: .info)
    }

    /// Elimina las credenciales de la config de Vessel → cierra sesión de GOG.
    func logout() {
        try? FileManager.default.removeItem(atPath: Self.credentialsPath)
        try? FileManager.default.removeItem(atPath: "\(Self.configDir)/user.json")
        log.log("Sesión de GOG cerrada", level: .info)
    }

    // MARK: - Biblioteca de juegos

    /// Devuelve la lista completa de juegos de la cuenta GOG (instalados y no instalados).
    ///
    /// Ejecuta: `gogdl games list --auth-config-path <configDir>`.
    ///
    /// TODO: Verificar el subcomando exacto con `gogdl games --help`.
    ///       En algunas versiones puede ser `gogdl library` o `gogdl games owned`.
    func ownedGames() async throws -> [GogGame] {
        let bin = try resolvedBinaryPath()

        let result = try await runBackground(
            bin,
            args: ["games", "list", "--auth-config-path", Self.configDir]
        )
        guard result.exitCode == 0 else {
            log.log("Error al listar biblioteca GOG: \(result.output)", level: .error)
            throw GogdlError.libraryFailed(result.output)
        }

        guard let data = result.output.data(using: .utf8) else { return [] }
        let games = parseGames(from: data)
        log.log("Biblioteca GOG: \(games.count) juego(s)", level: .info)
        return games
    }

    // MARK: - Instalación y lanzamiento (TODO)

    /// TODO: Instalar un juego de GOG vía `gogdl download <appId>`.
    ///       Gestionar el bottle de Wine, rutas dentro de VesselPaths, progreso, etc.
    func installGame(appId: String, progress: @escaping @Sendable (String) -> Void) async throws {
        throw GogdlError.notImplemented("Instalación de juegos de GOG: próximamente.")
    }

    /// TODO: Lanzar un juego de GOG con wine-dxmt (mismo modelo que Steam/Epic).
    ///       El ejecutable se resuelve desde el manifiesto de instalación de gogdl.
    func launchGame(appId: String) async throws {
        throw GogdlError.notImplemented("Lanzamiento de juegos de GOG: próximamente.")
    }

    // MARK: - Errores del dominio

    enum GogdlError: LocalizedError {
        case noBinaryForMacOS
        case emptyCode
        case authFailed(String)
        case libraryFailed(String)
        case notInstalled
        case pythonNotAvailable
        case notImplemented(String)

        var errorDescription: String? {
            switch self {
            case .noBinaryForMacOS:
                return "No se encontró un binario de gogdl para macOS en la release de GitHub."
            case .emptyCode:
                return "El código de autorización de GOG está vacío."
            case .authFailed(let output):
                return "Autenticación con GOG fallida. Comprueba que el código sea correcto y no haya caducado.\n\(output)"
            case .libraryFailed(let output):
                return "No se pudo obtener la biblioteca de GOG. Comprueba tu conexión.\n\(output)"
            case .notInstalled:
                return "gogdl no está instalado. Llama antes a ensureInstalled."
            case .pythonNotAvailable:
                return "Python 3 no está disponible en /usr/bin/python3. Instala Xcode Command Line Tools con: xcode-select --install"
            case .notImplemented(let msg):
                return msg
            }
        }
    }

    // MARK: - Privado: resolución del binario

    /// Devuelve la ruta al binario disponible (directo o venv) o lanza error si no hay ninguno.
    private func resolvedBinaryPath() throws -> String {
        if FileManager.default.isExecutableFile(atPath: Self.binaryPath)  { return Self.binaryPath }
        if FileManager.default.isExecutableFile(atPath: Self.venvBinary)  { return Self.venvBinary }
        throw GogdlError.notInstalled
    }

    // MARK: - Privado: descarga binario de GitHub

    private func downloadBinaryFromGitHub(onProgress: @escaping @Sendable (String) -> Void) async throws -> String {
        let apiURL = URL(string: "https://api.github.com/repos/Heroic-Games-Launcher/gogdl/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("Vessel/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let release = try JSONDecoder().decode(GHRelease.self, from: data)

        // Prioridad de selección de asset macOS arm64:
        // 1. "gogdl-macOS-arm64" / "gogdl_macOS_arm64"
        // 2. "gogdl-macOS" / "gogdl_macOS" (binario universal macOS)
        // 3. cualquier asset con "darwin" o "mac" sin extensión .exe/.tar.gz/.zip
        let lower = release.assets.map { ($0.name.lowercased(), $0) }
        let asset = lower.first { $0.0 == "gogdl-macos-arm64" || $0.0 == "gogdl_macos_arm64" }?.1
            ?? lower.first { $0.0 == "gogdl-macos" || $0.0 == "gogdl_macos" }?.1
            ?? lower.first {
                let n = $0.0
                return (n.contains("macos") || n.contains("darwin") || (n.contains("mac") && !n.contains("linux")))
                    && !n.hasSuffix(".tar.gz") && !n.hasSuffix(".zip") && !n.hasSuffix(".exe")
            }?.1

        guard let asset, let downloadURL = URL(string: asset.browserDownloadURL) else {
            throw GogdlError.noBinaryForMacOS
        }

        onProgress("Descargando gogdl \(release.tagName) para macOS…")
        log.log("gogdl: descargando \(asset.name) desde \(release.tagName)", level: .info)

        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(
                domain: "Vessel", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Descarga de gogdl falló: HTTP \(http.statusCode)"]
            )
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let finalURL = URL(fileURLWithPath: Self.binaryPath)
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.binaryPath)

        onProgress("Quitando cuarentena y firmando gogdl…")
        await stripQuarantine(Self.binaryPath)
        await adhocSign(Self.binaryPath)

        guard FileManager.default.isExecutableFile(atPath: Self.binaryPath) else {
            throw NSError(
                domain: "Vessel", code: 101,
                userInfo: [NSLocalizedDescriptionKey: "gogdl se descargó pero no es ejecutable. Revisa los permisos de \(Self.binaryPath)"]
            )
        }

        log.log("✓ gogdl \(release.tagName) (binario) listo en \(Self.binaryPath)", level: .info)
        return Self.binaryPath
    }

    // MARK: - Privado: instalación vía Python venv

    /// Crea un venv Python e instala gogdl desde GitHub con pip.
    /// Requiere `/usr/bin/python3` (incluido con Xcode Command Line Tools en macOS 15+).
    private func installViaVenv(onProgress: @escaping @Sendable (String) -> Void) async throws -> String {
        let python3 = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python3) else {
            throw GogdlError.pythonNotAvailable
        }

        onProgress("Creando entorno Python para gogdl…")
        let venvResult = try await runBackground(
            python3,
            args: ["-m", "venv", Self.venvDir]
        )
        guard venvResult.exitCode == 0 else {
            throw NSError(
                domain: "Vessel", code: 110,
                userInfo: [NSLocalizedDescriptionKey: "Error al crear el venv para gogdl:\n\(venvResult.output)"]
            )
        }

        onProgress("Instalando gogdl (esto puede tardar un momento)…")
        // pip install desde el repositorio oficial de Heroic
        let pipResult = try await runBackground(
            "\(Self.venvDir)/bin/pip",
            args: ["install", "--quiet",
                   "git+https://github.com/Heroic-Games-Launcher/gogdl.git"]
        )
        guard pipResult.exitCode == 0 else {
            throw NSError(
                domain: "Vessel", code: 111,
                userInfo: [NSLocalizedDescriptionKey: "Error al instalar gogdl vía pip:\n\(pipResult.output)"]
            )
        }

        guard FileManager.default.isExecutableFile(atPath: Self.venvBinary) else {
            throw NSError(
                domain: "Vessel", code: 112,
                userInfo: [NSLocalizedDescriptionKey: "pip terminó sin error pero gogdl no aparece en \(Self.venvBinary)"]
            )
        }

        log.log("✓ gogdl instalado vía Python venv en \(Self.venvBinary)", level: .info)
        return Self.venvBinary
    }

    // MARK: - Ejecución de subprocesos

    private struct RunResult {
        let exitCode: Int32
        let output: String
    }

    /// Ejecuta gogdl en un hilo de fondo para no bloquear el actor principal.
    /// Inyecta `GOGDL_CONFIG_PATH` apuntando al directorio aislado de Vessel (por si
    /// gogdl lo usa como alternativa a `--auth-config-path`).
    private func runBackground(_ binary: String, args: [String]) async throws -> RunResult {
        let configDir = Self.configDir
        let shellEnv  = WineManager.userShellEnvironment

        return try await withCheckedThrowingContinuation { cont in
            Task.detached(priority: .userInitiated) {
                var env = shellEnv
                // Variable de entorno que algunas versiones de gogdl leen para la config.
                env["GOGDL_CONFIG_PATH"] = configDir
                env["TERM"] = "xterm-256color"

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

    // MARK: - Cuarentena y firma

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

    // MARK: - Parseo JSON de gogdl

    /// Parsea la salida JSON de `gogdl games list`.
    ///
    /// gogdl puede devolver:
    /// - Un array directo: `[{"app_name": "...", "title": "...", ...}, ...]`
    /// - Un objeto con clave "games" o "owned": `{"games": [...], ...}`
    ///
    /// TODO: Verificar el formato exacto de la versión instalada con:
    ///       `gogdl games list --auth-config-path <dir> | python3 -m json.tool | head -40`
    private func parseGames(from data: Data) -> [GogGame] {
        // Intento 1: array directo
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return gamesFromArray(arr)
        }
        // Intento 2: objeto con clave "games" o "owned"
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let arr = (obj["games"] as? [[String: Any]])
                ?? (obj["owned"] as? [[String: Any]])
                ?? []
            return gamesFromArray(arr)
        }
        log.log("gogdl: no se pudo parsear la respuesta de games list", level: .warn)
        return []
    }

    private func gamesFromArray(_ arr: [[String: Any]]) -> [GogGame] {
        arr.compactMap { obj -> GogGame? in
            // gogdl puede usar "app_name", "appId" o "id" como identificador
            let appId = (obj["app_name"] as? String)
                ?? (obj["appId"]    as? String)
                ?? (obj["id"]       as? String)
                ?? (obj["app_id"]   as? String)
            // Título puede estar en "title" o "app_title"
            let title = (obj["title"]     as? String)
                ?? (obj["app_title"] as? String)

            guard let appId, let title, !title.isEmpty else { return nil }

            let installed = (obj["installed"] as? Bool) ?? false
            return GogGame(appId: appId, title: title, installed: installed)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
