import Foundation

/// Cliente de **itch.io** (API server‑side). El usuario vincula su cuenta pegando una **API key**
/// (la genera en https://itch.io/user/settings/api-keys). Con ella Vessel:
///  - valida la cuenta (`/profile`),
///  - lista los juegos que POSEE (`/profile/owned-keys`, paginado),
///  - resuelve la URL de descarga del build de Windows (`/games/{id}/uploads` → `/uploads/{id}/download`).
///
/// La descarga/instalación la hace `DRMFreeInstaller`; el resultado se guarda en `LocalGamesStore`.
/// Modelos TOLERANTES (`decodeIfPresent`) para no romper ante cambios menores de la API.
actor ItchService {
    static let shared = ItchService()

    private static let base = URL(string: "https://api.itch.io")!
    private static let apiKeyDefault = "vessel.itch.apikey"

    // MARK: - Vinculación

    /// API key persistida (UserDefaults, como el resto de credenciales de backends en Vessel).
    nonisolated var apiKey: String? {
        get { UserDefaults.standard.string(forKey: Self.apiKeyDefault) }
    }
    nonisolated var isLinked: Bool { !(apiKey ?? "").isEmpty }

    nonisolated func setAPIKey(_ key: String?) {
        let k = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let k, !k.isEmpty { UserDefaults.standard.set(k, forKey: Self.apiKeyDefault) }
        else { UserDefaults.standard.removeObject(forKey: Self.apiKeyDefault) }
    }

    // MARK: - Modelos (tolerantes)

    struct Profile: Decodable { let user: User?; struct User: Decodable { let username: String?; let id: Int? } }

    struct OwnedKeysPage: Decodable {
        let owned_keys: [OwnedKey]?
        let per_page: Int?
        let page: Int?
    }
    struct OwnedKey: Decodable {
        let id: Int?              // id del download‑key (se pasa como download_key_id)
        let game: Game?
    }
    struct Game: Decodable {
        let id: Int?
        let title: String?
        let cover_url: String?
        let url: String?          // página del juego
        let classification: String?   // "game", "tool", "assets"…
        let type: String?         // "default", "html"…
    }
    struct UploadsResponse: Decodable { let uploads: [Upload]? }
    struct Upload: Decodable {
        let id: Int?
        let filename: String?
        let size: Int64?
        let type: String?                     // "default", "soundtrack", "book", "html"…
        let demo: Bool?
        let platforms: [String: String]?      // API moderna: {"windows":"all", "osx":"all", ...}
        let p_windows: Bool?                  // API legacy: booleano plano
        let p_osx: Bool?
        var isWindows: Bool { (platforms?["windows"] != nil) || (p_windows ?? false) }
        /// Build NATIVO de macOS. En un Mac es SIEMPRE mejor que pasar por Wine: sin traducción,
        /// sin Rosetta y con el rendimiento real de la máquina. itch lo llama "osx".
        var isMac: Bool { (platforms?["osx"] != nil) || (p_osx ?? false) }
        var isDemo: Bool { demo ?? false }
        /// Descarta descargas que no son un ejecutable (soundtrack, libro, html play-in-browser).
        var isRunnable: Bool { !["soundtrack", "book", "html"].contains((type ?? "default").lowercased()) }
    }

    enum ItchError: LocalizedError {
        case notLinked, http(Int), badKey, noWindowsBuild
        var errorDescription: String? {
            switch self {
            case .notLinked: return "No has vinculado tu cuenta de itch.io."
            case .http(let c): return "itch.io respondió HTTP \(c)."
            case .badKey: return "La API key de itch.io no es válida."
            case .noWindowsBuild: return "Este juego no tiene una descarga para Windows en itch.io."
            }
        }
    }

    // MARK: - Peticiones

    private func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        guard let key = apiKey, !key.isEmpty else { throw ItchError.notLinked }
        var comps = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw ItchError.badKey }
            if !(200...299).contains(http.statusCode) { throw ItchError.http(http.statusCode) }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Valida la key y devuelve el nombre de usuario.
    func validate() async throws -> String {
        let p = try await request("profile", as: Profile.self)
        guard let name = p.user?.username else { throw ItchError.badKey }
        return name
    }

    /// Todos los juegos que el usuario posee y son ejecutables (excluye assets/soundtracks; solo
    /// los que declaran build de Windows o macOS — DRM‑free). Recorre la paginación.
    func fetchOwnedGames() async throws -> [OwnedKey] {
        var all: [OwnedKey] = []
        var page = 1
        while true {
            let resp = try await request("profile/owned-keys",
                                         query: [URLQueryItem(name: "page", value: String(page))],
                                         as: OwnedKeysPage.self)
            let keys = resp.owned_keys ?? []
            if keys.isEmpty { break }
            all.append(contentsOf: keys)
            page += 1
            if page > 50 { break }   // salvaguarda
        }
        // Solo juegos/herramientas jugables (no assets/soundtrack). El objeto `game` de la API
        // moderna NO expone plataforma de forma fiable → la disponibilidad de Windows se comprueba
        // al resolver la descarga (uploads). Así no dejamos la biblioteca vacía por un filtro ciego.
        return all.filter { k in
            guard let g = k.game else { return false }
            let cls = (g.classification ?? "game").lowercased()
            return cls == "game" || cls == "tool"
        }
    }

    /// Plataforma del build elegido: condiciona cómo se ejecuta (nativo vs Wine).
    enum BuildPlatform: String, Sendable { case mac, windows }

    /// Resuelve la mejor descarga de un juego que se posee. **Prefiere el build NATIVO de macOS**
    /// si existe (mejor que Wine en todos los sentidos) y cae a Windows si no.
    /// Devuelve la URL (endpoint moderno con Bearer, que responde 302 al CDN firmado), el nombre de
    /// fichero real (para conocer la extensión) y la plataforma que se ha elegido.
    func bestDownload(gameId: Int, downloadKeyId: Int,
                      preferNative: Bool = true) async throws -> (url: URL, filename: String?, platform: BuildPlatform) {
        guard let key = apiKey, !key.isEmpty else { throw ItchError.notLinked }
        let ur = try await request("games/\(gameId)/uploads",
                                   query: [URLQueryItem(name: "download_key_id", value: String(downloadKeyId))],
                                   as: UploadsResponse.self)
        let uploads = (ur.uploads ?? []).filter { $0.isRunnable }
        // Dentro de cada plataforma: no‑demo primero y, a igualdad, el más grande (el juego completo).
        func pick(_ f: (Upload) -> Bool) -> Upload? {
            uploads.filter { f($0) && !$0.isDemo }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }.first
                ?? uploads.filter(f).sorted { ($0.size ?? 0) > ($1.size ?? 0) }.first
        }
        var platform: BuildPlatform = .windows
        var chosen: Upload?
        if preferNative, let mac = pick({ $0.isMac }) { chosen = mac; platform = .mac }
        if chosen == nil { chosen = pick({ $0.isWindows }); platform = .windows }
        guard let up = chosen, let upId = up.id else { throw ItchError.noWindowsBuild }

        // Endpoint moderno de descarga: 302 → URL firmada del CDN. Autenticamos con el header
        // `Authorization: Bearer` (NO metemos la API key en la URL: acabaría en logs/Referer) y
        // capturamos el redirect SIN seguirlo — así el header no viaja al CDN y devolvemos la URL
        // firmada del CDN (su firma es temporal, no contiene el secreto).
        var comps = URLComponents(url: Self.base.appendingPathComponent("uploads/\(upId)/download"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "download_key_id", value: String(downloadKeyId))]
        guard let apiURL = comps.url else { throw ItchError.http(0) }
        let signed = try await Self.resolveSignedURL(apiURL, bearer: key)
        return (signed, up.filename, platform)
    }

    /// Compatibilidad: la variante que fuerza Windows (la usan flujos que ya asumen Wine).
    func windowsDownload(gameId: Int, downloadKeyId: Int) async throws -> (url: URL, filename: String?) {
        let r = try await bestDownload(gameId: gameId, downloadKeyId: downloadKeyId, preferNative: false)
        return (r.url, r.filename)
    }

    /// Hace un GET autenticado con Bearer al endpoint de descarga y devuelve la URL del `Location`
    /// del 302 (URL firmada del CDN) SIN seguir el redirect (para no reenviar el header al CDN).
    private static func resolveSignedURL(_ url: URL, bearer: String) async throws -> URL {
        let capturer = RedirectCapturer()
        let session = URLSession(configuration: .ephemeral, delegate: capturer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, resp) = try await session.data(for: req)
        if let loc = capturer.captured { return loc }                    // Location del 302
        if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let u = http.url { return u }                                 // sin redirect: la propia URL
        throw ItchError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Captura el `Location` de un redirect HTTP sin seguirlo (evita reenviar el header `Authorization`
/// al host del CDN). `@unchecked Sendable`: `captured` se escribe en el callback del delegado y se
/// lee tras el `await`, que garantiza que la tarea ya terminó.
private final class RedirectCapturer: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var captured: URL?
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        captured = request.url
        completionHandler(nil)   // NO seguir el redirect
    }
}
