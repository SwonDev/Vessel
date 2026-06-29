import Foundation

/// Gestiona la instalación y uso de **nile** (cliente CLI de Amazon Games).
///
/// **Cómo se obtiene nile:**
/// nile publica binarios standalone para macOS (arm64 y x86_64) en cada release de GitHub
/// (`imLinguin/nile`). Vessel descarga directamente el binario `nile_macOS_arm64`, lo
/// hace ejecutable, quita la cuarentena y lo firma ad-hoc — igual que con Legendary.
/// No se requiere Python, pip ni venv.
///
/// **Aislamiento de configuración:**
/// La variable de entorno `NILE_CONFIG_PATH` apunta a
/// `~/Library/Application Support/Vessel/Amazon`. nile añade automáticamente el
/// subdirectorio `/nile`, de modo que los archivos de sesión quedan en
/// `…/Vessel/Amazon/nile/`. Esto no interfiere con la configuración global del
/// usuario en `~/.config/nile`.
///
/// **Flujo de autenticación PKCE (2 pasos):**
/// Amazon Games usa OAuth PKCE, distinto al flujo de auth-code simple de Legendary:
///
/// 1. `nile auth --login --non-interactive` → JSON `{client_id, code_verifier, serial, url}`.
///    Vessel abre la `url` en el navegador para que el usuario inicie sesión con su cuenta
///    Amazon / Prime Gaming.
///
/// 2. Amazon redirige a `https://www.amazon.com` con el parámetro
///    `openid.oa2.authorization_code=XXXX` en la URL. El usuario copia ese código.
///
/// 3. `nile register --code <code> --client-id ... --code-verifier ... --serial ...`
///    completa el registro y guarda las credenciales cifradas en disco.
///
/// **Sesión activa:** nile escribe `current_user.json` en su configDir tras el `register`.
/// `isAuthenticated()` comprueba la existencia de ese archivo.
@MainActor
@Observable
final class NileManager {

    // MARK: - Tipos públicos

    /// Juego de Amazon Games.
    struct AmazonGame: Identifiable, Hashable {
        let id: String
        let title: String
        var installed: Bool
    }

    /// Parámetros PKCE generados en el paso 1 del flujo de auth.
    /// Deben persistir en memoria entre el paso 1 (abrir el navegador) y el paso 2
    /// (pegar el código), por lo que `AmazonStore` los guarda en `@State`.
    struct AuthSession: Decodable {
        let clientId: String
        let codeVerifier: String
        let serial: String
        let url: URL

        enum CodingKeys: String, CodingKey {
            case clientId     = "client_id"
            case codeVerifier = "code_verifier"
            case serial
            case url
        }
    }

    // MARK: - Rutas (estáticas)

    static let nileDir       = "\(VesselPaths.enginesDirectory)/nile"
    static let binaryPath    = "\(nileDir)/nile"
    /// Valor de NILE_CONFIG_PATH → nile usa internamente «{configDir}/nile/»
    static let configDir     = "\(VesselPaths.appSupport)/Amazon"
    /// Directorio real de nile (con el subfijo /nile añadido por nile).
    static let nileConfigDir = "\(configDir)/nile"
    /// Archivo que nile crea tras un `register` exitoso.
    private static let currentUserPath = "\(nileConfigDir)/current_user.json"

    // MARK: - Estado privado

    private let log = LogStore.shared

    /// Versión de nile pinneada (la misma que usa Heroic). Repo: `imLinguin/nile`.
    private static let nileVersion = "v1.1.2"

    // MARK: - Instalación del binario

    /// Devuelve la ruta al binario de nile, descargándolo de GitHub si aún no está.
    /// Idempotente: si ya existe y es ejecutable, vuelve directamente.
    func ensureInstalled(onProgress: @escaping @Sendable (String) -> Void) async throws -> String {
        if FileManager.default.isExecutableFile(atPath: Self.binaryPath) {
            return Self.binaryPath
        }

        try FileManager.default.createDirectory(atPath: Self.nileDir,   withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true)

        // Binario nativo de macOS de imLinguin/nile (mismo origen y versión que usa Heroic).
        #if arch(arm64)
        let assetName = "nile_macOS_arm64"
        #else
        let assetName = "nile_macOS_x86_64"
        #endif
        let urlString = "https://github.com/imLinguin/nile/releases/download/\(Self.nileVersion)/\(assetName)"
        guard let downloadURL = URL(string: urlString) else {
            throw NSError(
                domain: "Vessel", code: 110,
                userInfo: [NSLocalizedDescriptionKey: "URL de nile inválida."]
            )
        }

        onProgress("Descargando nile \(Self.nileVersion) (Amazon Games)…")
        log.log("nile: descargando \(assetName) v\(Self.nileVersion)", level: .info)

        let (tempURL, httpResponse) = try await URLSession.shared.download(from: downloadURL)
        if let http = httpResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(
                domain: "Vessel", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Descarga de nile falló: HTTP \(http.statusCode)"]
            )
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let finalURL = URL(fileURLWithPath: Self.binaryPath)
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.binaryPath)

        onProgress("Quitando cuarentena y firmando nile…")
        await stripQuarantine(Self.binaryPath)
        await adhocSign(Self.binaryPath)

        guard FileManager.default.isExecutableFile(atPath: Self.binaryPath) else {
            throw NSError(
                domain: "Vessel", code: 111,
                userInfo: [NSLocalizedDescriptionKey:
                    "nile se descargó pero no es ejecutable (\(Self.binaryPath))."]
            )
        }

        log.log("✓ nile \(Self.nileVersion) listo en \(Self.binaryPath)", level: .info)
        return Self.binaryPath
    }

    // MARK: - Autenticación (PKCE de Amazon)

    /// `true` si `current_user.json` existe en el configDir de nile dentro de Vessel.
    func isAuthenticated() -> Bool {
        FileManager.default.fileExists(atPath: Self.currentUserPath)
    }

    /// **Paso 1 del flujo de auth:** genera los parámetros PKCE y la URL de login de Amazon.
    ///
    /// Ejecuta `nile auth --login --non-interactive` y parsea el JSON de respuesta:
    /// `{"client_id":"…","code_verifier":"…","serial":"…","url":"https://amazon.com/ap/signin?…"}`.
    ///
    /// El llamador debe:
    /// 1. Abrir `session.url` en el navegador (p.ej. con `NSWorkspace.shared.open`).
    /// 2. Tras el login de Amazon, la página redirige a `https://www.amazon.com` con
    ///    `openid.oa2.authorization_code=XXXX` en la URL. El usuario copia ese valor.
    /// 3. Llamar a `register(code:session:)` con el código y la sesión devuelta aquí.
    func startAuth() async throws -> AuthSession {
        let bin = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            throw NSError(
                domain: "Vessel", code: 112,
                userInfo: [NSLocalizedDescriptionKey: "nile no está instalado. Llama antes a ensureInstalled."]
            )
        }

        let result = try await runBackground(bin, args: ["auth", "--login", "--non-interactive"])

        // La salida puede incluir mensajes de log (líneas con «ERROR [CLI]», etc.).
        // Buscamos la primera línea que empiece por '{' (el JSON).
        let jsonLine = result.output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
            .map(String.init)
            ?? result.output

        guard let data = jsonLine.data(using: .utf8) else {
            throw NSError(
                domain: "Vessel", code: 113,
                userInfo: [NSLocalizedDescriptionKey:
                    "Respuesta inesperada de nile al iniciar la auth de Amazon: \(result.output)"]
            )
        }

        do {
            return try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            throw NSError(
                domain: "Vessel", code: 114,
                userInfo: [NSLocalizedDescriptionKey:
                    "No se pudo leer los parámetros PKCE de nile. "
                    + "Error: \(error.localizedDescription)\nSalida: \(result.output)"]
            )
        }
    }

    /// **Paso 2 del flujo de auth:** completa el registro con el authorization code de Amazon.
    ///
    /// Ejecuta:
    /// ```
    /// nile register --code <code> --client-id <…> --code-verifier <…> --serial <…>
    /// ```
    /// Tras el éxito, nile escribe `current_user.json` y `isAuthenticated()` devuelve `true`.
    func register(code: String, session: AuthSession) async throws {
        let bin = Self.binaryPath
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "Vessel", code: 115,
                userInfo: [NSLocalizedDescriptionKey: "El código de autorización está vacío."]
            )
        }

        let result = try await runBackground(bin, args: [
            "register",
            "--code",           trimmed,
            "--client-id",      session.clientId,
            "--code-verifier",  session.codeVerifier,
            "--serial",         session.serial
        ])

        // Verificamos tanto el código de salida como la presencia del archivo de sesión.
        if result.exitCode != 0 || !isAuthenticated() {
            log.log("Error al registrar cuenta Amazon Games: \(result.output)", level: .error)
            throw NSError(
                domain: "Vessel", code: 116,
                userInfo: [NSLocalizedDescriptionKey:
                    "Registro con Amazon Games fallido. Comprueba que el código sea correcto "
                    + "y no haya caducado.\n\(result.output)"]
            )
        }
        log.log("✓ Cuenta Amazon Games registrada correctamente", level: .info)
    }

    /// Cierra sesión eliminando los archivos de credenciales de nile en el directorio de Vessel.
    func logout() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: Self.nileConfigDir) else {
            return
        }
        for filename in files where filename.hasSuffix(".json") || filename.hasSuffix(".enc") || filename.hasSuffix(".raw") {
            try? FileManager.default.removeItem(atPath: "\(Self.nileConfigDir)/\(filename)")
        }
        log.log("Sesión de Amazon Games cerrada", level: .info)
    }

    // MARK: - Biblioteca de juegos

    /// Sincroniza la biblioteca con los servidores de Amazon.
    /// Ejecuta `nile library sync`. No lanza error si falla (los datos locales se usan igualmente).
    func syncLibrary() async throws {
        let bin = Self.binaryPath
        let result = try await runBackground(bin, args: ["library", "sync"])
        if result.exitCode != 0 {
            // Solo warning: si ya hay datos locales cacheados, `ownedGames` los usará.
            log.log("Aviso al sincronizar biblioteca Amazon: \(result.output)", level: .info)
        }
    }

    /// Devuelve la lista completa de juegos de la cuenta Amazon, instalados y no instalados.
    ///
    /// Flujo:
    /// 1. `nile library sync` → actualiza el caché local (`library.json`).
    /// 2. Lectura directa de `installed.json` para obtener los IDs instalados.
    ///    (Nota: `nile library list --json --installed` ignora el flag `--installed` cuando
    ///    se usa con `--json` — bug conocido de nile; leer el archivo directamente es más
    ///    fiable y evita un proceso adicional.)
    /// 3. `nile library list --json` → biblioteca completa.
    ///
    /// JSON de cada juego: `{"product": {"id": "…", "title": "…"}, …}`.
    /// `installed.json` tiene el formato: `[{"id": "…", …}, …]`.
    func ownedGames() async throws -> [AmazonGame] {
        let bin = Self.binaryPath

        // Sincronizar para tener los datos más recientes; no abortamos si falla.
        try? await syncLibrary()

        // Juegos instalados: leemos installed.json directamente (más fiable que --installed --json).
        let installedPath = "\(Self.nileConfigDir)/installed.json"
        let installedIDs: Set<String>
        if let installedData = FileManager.default.contents(atPath: installedPath),
           let arr = try? JSONSerialization.jsonObject(with: installedData) as? [[String: Any]] {
            installedIDs = Set(arr.compactMap { $0["id"] as? String })
        } else {
            installedIDs = []
        }

        // Biblioteca completa
        let listResult = try await runBackground(bin, args: ["library", "list", "--json"])
        guard listResult.exitCode == 0 else {
            log.log("Error al listar biblioteca Amazon: \(listResult.output)", level: .error)
            throw NSError(
                domain: "Vessel", code: 117,
                userInfo: [NSLocalizedDescriptionKey:
                    "No se pudo obtener la biblioteca de Amazon Games. "
                    + "Comprueba tu conexión.\n\(listResult.output)"]
            )
        }

        guard let data = extractJSON(from: listResult.output) else { return [] }
        let games = parseGames(from: data, installedIDs: installedIDs)
        log.log("Biblioteca Amazon: \(games.count) juego(s)", level: .info)
        return games
    }

    // MARK: - Instalación y lanzamiento (TODO)

    /// TODO: Instalar un juego vía `nile install <id>`.
    /// Gestionar el bottle de Wine correcto, rutas de instalación en VesselPaths.games, etc.
    func installGame(id: String, progress: @escaping @Sendable (String) -> Void) async throws {
        throw NSError(
            domain: "Vessel", code: 198,
            userInfo: [NSLocalizedDescriptionKey: "Instalación de juegos de Amazon Games: próximamente."]
        )
    }

    /// TODO: Lanzar un juego con `nile launch <id>` usando el motor wine-dxmt.
    /// Reutilizar la arquitectura de doble motor: wine-dxmt para D3D11, igual que Steam.
    func launchGame(id: String) async throws {
        throw NSError(
            domain: "Vessel", code: 199,
            userInfo: [NSLocalizedDescriptionKey: "Lanzamiento de juegos de Amazon Games: próximamente."]
        )
    }

    // MARK: - Ejecución de subprocesos

    private struct RunResult {
        let exitCode: Int32
        let output: String
    }

    /// Ejecuta nile en un hilo de fondo para no bloquear el actor principal.
    /// Inyecta `NILE_CONFIG_PATH` apuntando al directorio aislado de Vessel.
    private func runBackground(_ binary: String, args: [String]) async throws -> RunResult {
        let configDir = Self.configDir
        let shellEnv  = WineManager.userShellEnvironment

        return try await withCheckedThrowingContinuation { cont in
            Task.detached(priority: .userInitiated) {
                var env = shellEnv
                env["NILE_CONFIG_PATH"] = configDir
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

    // MARK: - Firmas y cuarentena (igual que LegendaryManager)

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

    // MARK: - Parseo JSON de nile

    /// Extrae la primera línea del output de nile que contenga JSON (array o dict).
    /// nile puede anteponer líneas de log antes del JSON útil.
    private func extractJSON(from output: String) -> Data? {
        let jsonString = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("[") || t.hasPrefix("{")
            }
            .map(String.init)
            ?? output
        return jsonString.data(using: .utf8)
    }

    /// Parsea el array JSON de `nile library list --json`.
    /// Formato de cada entrada: `{"product": {"id": "…", "title": "…"}, …}`.
    private func parseGames(from data: Data, installedIDs: Set<String>) -> [AmazonGame] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { obj -> AmazonGame? in
            guard let product = obj["product"] as? [String: Any],
                  let id    = product["id"]    as? String,
                  let title = product["title"] as? String,
                  !title.isEmpty
            else { return nil }
            return AmazonGame(id: id, title: title, installed: installedIDs.contains(id))
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
