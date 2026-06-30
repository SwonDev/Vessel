import Foundation

/// Gestiona la instalación y uso de **gogdl** (cliente CLI de GOG, proyecto de Heroic Games Launcher).
///
/// gogdl se auto-descarga del repositorio `Heroic-Games-Launcher/heroic-gogdl` (binario nativo macOS).
/// La versión está pinneada explícitamente para garantizar compatibilidad, igual que Legendary.
/// La configuración se guarda en `~/Library/Application Support/Vessel/Gog` para no
/// interferir con la instalación de Heroic que el usuario pueda tener en el sistema.
///
/// ## Notas sobre la CLI de gogdl (verificadas con `gogdl --help` v1.2.1)
///
/// `--auth-config-path` es un argumento **GLOBAL** (va ANTES del subcomando) y apunta a un
/// **archivo JSON** donde gogdl guarda los tokens (no a un directorio):
/// - Auth:     `gogdl --auth-config-path <auth.json> auth --code <code>`
/// - Refresco: `gogdl --auth-config-path <auth.json> auth`  (sin code; refresca y reescribe)
/// - Descarga: `gogdl --auth-config-path <auth.json> download <appId> --path <installPath>`
/// - Lanzar:   mediante wine-dxmt desde Vessel (sin delegar en gogdl, igual que Steam/Epic).
///
/// gogdl **no** lista la biblioteca; eso se obtiene de la **API web de GOG**
/// (`embed.gog.com/account/getFilteredProducts`) con el `access_token` guardado en el auth.json,
/// igual que hace Heroic.
@MainActor
@Observable
final class GogdlManager {

    // MARK: - Tipos públicos

    struct GogGame: Identifiable, Hashable, Codable {
        /// Identificador numérico de GOG (appId).
        let appId: String
        let title: String
        var installed: Bool
        /// Carátula del juego (API web de GOG); puede ser `nil` → placeholder.
        var coverURL: String? = nil
        var id: String { appId }
    }

    // MARK: - Rutas (estáticas)

    /// Directorio base de gogdl dentro de los motores de Vessel.
    static let gogdlDir    = "\(VesselPaths.enginesDirectory)/gogdl"
    /// Ruta del binario compilado descargado de GitHub.
    static let binaryPath  = "\(gogdlDir)/gogdl"
    /// Directorio de configuración aislado de Vessel.
    static let configDir   = "\(VesselPaths.appSupport)/Gog"

    /// Archivo JSON donde gogdl guarda los tokens (lo que se pasa a `--auth-config-path`).
    static let authConfigPath = "\(configDir)/auth.json"

    /// `client_id` de GOG Galaxy que gogdl usa por defecto (clave del objeto en `auth.json`).
    private static let gogClientID = "46899977096215655"

    // MARK: - Estado

    private let log = LogStore.shared

    /// Versión de gogdl pinneada (la misma que usa Heroic). Repo: `Heroic-Games-Launcher/heroic-gogdl`.
    private static let gogdlVersion = "v1.2.1"

    // MARK: - Instalación del binario

    /// Devuelve la ruta al binario de gogdl, descargándolo si aún no está disponible.
    /// Idempotente: si ya existe y es ejecutable, vuelve directamente.
    func ensureInstalled(onProgress: @escaping @Sendable (String) -> Void) async throws -> String {
        if FileManager.default.isExecutableFile(atPath: Self.binaryPath) {
            return Self.binaryPath
        }

        try FileManager.default.createDirectory(atPath: Self.gogdlDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true)

        // Binario nativo de macOS del fork heroic-gogdl (mismo origen y versión que usa Heroic).
        #if arch(arm64)
        let assetName = "gogdl_macos_arm64"
        #else
        let assetName = "gogdl_macos_x86_64"
        #endif
        let urlString = "https://github.com/Heroic-Games-Launcher/heroic-gogdl/releases/download/\(Self.gogdlVersion)/\(assetName)"
        guard let downloadURL = URL(string: urlString) else {
            throw NSError(domain: "Vessel", code: 100,
                userInfo: [NSLocalizedDescriptionKey: "URL de gogdl inválida."])
        }

        onProgress("Descargando gogdl \(Self.gogdlVersion) (GOG)…")
        log.log("gogdl: descargando \(assetName) v\(Self.gogdlVersion) (heroic-gogdl)", level: .info)

        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(domain: "Vessel", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Descarga de gogdl falló: HTTP \(http.statusCode)"])
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
            throw NSError(domain: "Vessel", code: 101,
                userInfo: [NSLocalizedDescriptionKey: "gogdl se descargó pero no es ejecutable (\(Self.binaryPath))."])
        }

        log.log("✓ gogdl \(Self.gogdlVersion) listo en \(Self.binaryPath)", level: .info)
        return Self.binaryPath
    }

    // MARK: - Autenticación

    /// `true` si hay una sesión GOG activa: el `auth.json` existe y contiene un `access_token`
    /// para el `client_id` de Galaxy.
    func isAuthenticated() -> Bool {
        guard let token = authEntry()?["access_token"] as? String, !token.isEmpty else { return false }
        return true
    }

    /// Entrada de tokens del `client_id` de Galaxy dentro del `auth.json` (o `nil`).
    private func authEntry() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: Self.authConfigPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[Self.gogClientID] as? [String: Any]
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
    /// Ejecuta: `gogdl --auth-config-path <auth.json> auth --code <code>`.
    /// (El flag es **global** → va antes del subcomando; apunta a un **archivo** JSON.)
    func authenticate(code: String) async throws {
        let bin = try resolvedBinaryPath()
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GogdlError.emptyCode
        }
        // gogdl escribe el auth.json dentro de configDir: garantízalo.
        try? FileManager.default.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true)

        let result = try await runBackground(
            bin,
            args: ["--auth-config-path", Self.authConfigPath, "auth", "--code", trimmed]
        )
        guard result.exitCode == 0, isAuthenticated() else {
            log.log("Error al autenticar con GOG: \(result.output)", level: .error)
            throw GogdlError.authFailed(result.output)
        }
        log.log("✓ Autenticación de GOG correcta", level: .info)
    }

    /// Elimina el auth.json de Vessel → cierra sesión de GOG.
    func logout() {
        try? FileManager.default.removeItem(atPath: Self.authConfigPath)
        log.log("Sesión de GOG cerrada", level: .info)
    }

    // MARK: - Biblioteca de juegos

    /// Devuelve la lista completa de juegos de la cuenta GOG.
    ///
    /// gogdl no lista la biblioteca: se obtiene de la **API web de GOG**
    /// (`embed.gog.com/account/getFilteredProducts`, paginada) con el `access_token`
    /// guardado en el auth.json. Mismo enfoque que Heroic.
    func ownedGames() async throws -> [GogGame] {
        let token = try await accessToken()

        var collected: [GogGame] = []
        var page = 1
        var totalPages = 1
        repeat {
            let (pageGames, pages) = try await fetchProductsPage(page: page, token: token)
            collected.append(contentsOf: pageGames)
            totalPages = pages
            page += 1
        } while page <= totalPages && page <= 100   // tope de seguridad

        var seen = Set<String>()
        let unique = collected
            .filter { seen.insert($0.appId).inserted }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        log.log("Biblioteca GOG: \(unique.count) juego(s)", level: .info)
        LibraryCache.save("gog", unique)   // carga instantánea la próxima vez (patrón Heroic)
        return unique
    }

    /// Obtiene un `access_token` válido. Si el token guardado aún no ha caducado lo devuelve
    /// directo (evita los ~5 s de `gogdl auth`); solo si caducó refresca con `gogdl auth`.
    private func accessToken() async throws -> String {
        // 1) Token guardado todavía válido (con margen de 5 min) → úsalo sin refrescar.
        if let entry = authEntry(),
           let token = entry["access_token"] as? String, !token.isEmpty,
           let loginTime = entry["loginTime"] as? Double,
           let expiresIn = entry["expires_in"] as? Double,
           loginTime + expiresIn - 300 > Date().timeIntervalSince1970 {
            return token
        }
        // 2) Caducado o ausente: refresca con `gogdl auth` (reescribe auth.json) y relee.
        let bin = try resolvedBinaryPath()
        _ = try? await runBackground(bin, args: ["--auth-config-path", Self.authConfigPath, "auth"])
        guard let token = authEntry()?["access_token"] as? String, !token.isEmpty
        else { throw GogdlError.notAuthenticated }
        return token
    }

    /// Descarga una página de la biblioteca de GOG. Devuelve `(juegos, totalPaginas)`.
    private func fetchProductsPage(page: Int, token: String) async throws -> ([GogGame], Int) {
        guard let url = URL(string:
            "https://embed.gog.com/account/getFilteredProducts?mediaType=1&page=\(page)")
        else { return ([], 1) }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw GogdlError.notAuthenticated
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GogdlError.libraryFailed("Respuesta de GOG no válida.")
        }
        let totalPages = (obj["totalPages"] as? Int) ?? 1
        let products = (obj["products"] as? [[String: Any]]) ?? []
        let games: [GogGame] = products.compactMap { p in
            let appId: String? = (p["id"] as? Int).map(String.init) ?? (p["id"] as? String)
            guard let appId, let title = p["title"] as? String, !title.isEmpty else { return nil }
            return GogGame(appId: appId, title: title, installed: false,
                           coverURL: Self.coverURL(from: p["image"] as? String))
        }
        return (games, totalPages)
    }

    /// Construye la URL de carátula de GOG a partir del hash `image` de la API
    /// (formato `//images-N.gog.com/<hash>` sin extensión → plantilla de tarjeta).
    private static func coverURL(from image: String?) -> String? {
        guard var img = image, !img.isEmpty else { return nil }
        if img.hasPrefix("//") { img = "https:" + img }
        else if !img.hasPrefix("http") { img = "https://images.gog.com/" + img }
        return img + "_product_card_v2_mobile_slider_639.jpg"
    }

    // MARK: - Instalación y lanzamiento

    /// Instala un juego de GOG en `installDir` (dentro del bottle de Vessel) con progreso en vivo.
    /// Ejecuta: `gogdl --auth-config-path <auth.json> download <id> --path <dir> --platform windows`.
    func installGame(appId: String, installDir: String,
                     onProgress: @escaping @Sendable (String) -> Void) async throws {
        let bin = try resolvedBinaryPath()
        try FileManager.default.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        let code = try await runStreaming(bin, args: [
            "--auth-config-path", Self.authConfigPath,
            "download", appId, "--path", installDir,
            "--platform", "windows", "--lang", "en-US"
        ], onLine: onProgress)
        guard code == 0 else {
            throw GogdlError.installFailed("La instalación de GOG falló (código \(code)). Revisa los logs.")
        }
        log.log("✓ GOG: \(appId) instalado en \(installDir)", level: .info)
    }

    /// Verifica y REPARA un juego de GOG ya instalado. `repair` es un alias de `download` en
    /// gogdl: re-descarga SOLO lo dañado o ausente. Mismo progreso que `installGame`.
    func repairGame(appId: String, installDir: String,
                    onProgress: @escaping @Sendable (String) -> Void) async throws {
        let bin = try resolvedBinaryPath()
        let code = try await runStreaming(bin, args: [
            "--auth-config-path", Self.authConfigPath,
            "repair", appId, "--path", installDir,
            "--platform", "windows", "--lang", "en-US"
        ], onLine: onProgress)
        guard code == 0 else {
            throw GogdlError.installFailed("La verificación de GOG falló (código \(code)). Revisa los logs.")
        }
        log.log("✓ GOG: \(appId) verificado/reparado", level: .info)
    }

    /// Aplica la actualización de un juego de GOG (`gogdl update`, alias de download).
    func updateGame(appId: String, installDir: String,
                    onProgress: @escaping @Sendable (String) -> Void) async throws {
        let bin = try resolvedBinaryPath()
        let code = try await runStreaming(bin, args: [
            "--auth-config-path", Self.authConfigPath,
            "update", appId, "--path", installDir,
            "--platform", "windows", "--lang", "en-US"
        ], onLine: onProgress)
        guard code == 0 else {
            throw GogdlError.installFailed("La actualización de GOG falló (código \(code)). Revisa los logs.")
        }
        log.log("✓ GOG: \(appId) actualizado", level: .info)
    }

    /// Carpeta REAL del juego dentro de `installDir`. gogdl ANIDA los archivos en una subcarpeta
    /// con el nombre del juego (p. ej. `installDir/War Wind/`), NO directamente en `installDir`;
    /// por eso buscamos el `goggame-<id>.info` en `installDir` o UN nivel por debajo. Sin esto,
    /// el juego se descargaba bien pero Vessel lo daba por "Sin instalar" y no se podía jugar.
    func gameRoot(appId: String, installDir: String) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(installDir)/goggame-\(appId).info") { return installDir }
        if let subs = try? fm.contentsOfDirectory(atPath: installDir) {
            for sub in subs where fm.fileExists(atPath: "\(installDir)/\(sub)/goggame-\(appId).info") {
                return "\(installDir)/\(sub)"
            }
        }
        return nil
    }

    /// `true` si el juego está instalado (existe su `goggame-<id>.info` en la carpeta real).
    func isInstalled(appId: String, installDir: String) -> Bool {
        gameRoot(appId: appId, installDir: installDir) != nil
    }

    /// Ejecutable principal del juego (del `goggame-<id>.info` que instala GOG), ruta absoluta.
    /// Se resuelve relativo a la carpeta REAL (la subcarpeta donde gogdl puso los archivos). Se
    /// lanza luego con wine-dxmt desde Vessel (igual que Steam/Epic), no con `gogdl launch`.
    func primaryExecutable(appId: String, installDir: String) -> String? {
        guard let root = gameRoot(appId: appId, installDir: installDir) else { return nil }
        let info = "\(root)/goggame-\(appId).info"
        guard let data = FileManager.default.contents(atPath: info),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = obj["playTasks"] as? [[String: Any]] else { return nil }
        let primary = tasks.first { ($0["isPrimary"] as? Bool) == true } ?? tasks.first
        guard let rel = primary?["path"] as? String, !rel.isEmpty else { return nil }
        return "\(root)/\(rel)"
    }

    /// Extrae el porcentaje de descarga (0–100) de una línea de salida de gogdl
    /// (formato `[…] = Progress: 45.30% (…)`, igual estilo que legendary).
    nonisolated static func progressPercent(in line: String) -> Double? {
        guard let r = line.range(of: "Progress:") else { return nil }
        let tail = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        let num = tail.prefix { $0.isNumber || $0 == "." }
        return Double(num)
    }

    // MARK: - Errores del dominio

    enum GogdlError: LocalizedError {
        case emptyCode
        case authFailed(String)
        case libraryFailed(String)
        case installFailed(String)
        case notInstalled
        case notAuthenticated
        case notImplemented(String)

        var errorDescription: String? {
            switch self {
            case .emptyCode:
                return "El código de autorización de GOG está vacío."
            case .authFailed(let output):
                return "Autenticación con GOG fallida. Comprueba que el código sea correcto y no haya caducado.\n\(output)"
            case .libraryFailed(let output):
                return "No se pudo obtener la biblioteca de GOG. Comprueba tu conexión.\n\(output)"
            case .installFailed(let msg):
                return msg
            case .notInstalled:
                return "gogdl no está instalado. Llama antes a ensureInstalled."
            case .notAuthenticated:
                return "No hay sesión de GOG. Vuelve a iniciar sesión."
            case .notImplemented(let msg):
                return msg
            }
        }
    }

    // MARK: - Privado: resolución del binario

    /// Devuelve la ruta al binario o lanza error si no está instalado.
    private func resolvedBinaryPath() throws -> String {
        if FileManager.default.isExecutableFile(atPath: Self.binaryPath) { return Self.binaryPath }
        throw GogdlError.notInstalled
    }

    // MARK: - Ejecución de subprocesos

    private struct RunResult {
        let exitCode: Int32
        let output: String
    }

    /// Ejecuta gogdl en un hilo de fondo para no bloquear el actor principal.
    /// Inyecta `GOGDL_CONFIG_PATH` apuntando al directorio aislado de Vessel.
    private func runBackground(_ binary: String, args: [String]) async throws -> RunResult {
        let configDir = Self.configDir
        let shellEnv  = WineManager.userShellEnvironment

        return try await withCheckedThrowingContinuation { cont in
            Task.detached(priority: .userInitiated) {
                var env = shellEnv
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

    /// Ejecuta gogdl para una operación LARGA (descarga), drenando la salida en vivo y
    /// reportando cada línea de progreso. Sin timeout: las descargas pueden durar mucho.
    private func runStreaming(_ binary: String, args: [String],
                              onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let shellEnv = WineManager.userShellEnvironment
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var env = shellEnv
                env["TERM"] = "xterm-256color"
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

}
