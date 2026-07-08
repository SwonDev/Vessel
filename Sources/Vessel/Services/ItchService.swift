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
        let platforms: [String: String]?      // API moderna: {"windows":"all", ...}
        let p_windows: Bool?                  // API legacy: booleano plano
        var isWindows: Bool { (platforms?["windows"] != nil) || (p_windows ?? false) }
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

    /// Resuelve la descarga del build de **Windows** de un juego que se posee. Devuelve la URL de
    /// descarga (endpoint moderno con `api_key`+`download_key_id`, que responde 302 al fichero
    /// firmado del CDN) y el nombre de fichero real (para conocer la extensión .zip/.exe/.msi).
    func windowsDownload(gameId: Int, downloadKeyId: Int) async throws -> (url: URL, filename: String?) {
        guard let key = apiKey, !key.isEmpty else { throw ItchError.notLinked }
        let ur = try await request("games/\(gameId)/uploads",
                                   query: [URLQueryItem(name: "download_key_id", value: String(downloadKeyId))],
                                   as: UploadsResponse.self)
        let uploads = (ur.uploads ?? []).filter { $0.isRunnable }
        // Preferir Windows no‑demo (el más grande); si no, cualquier Windows; si no, el runnable mayor.
        let win = uploads.filter { $0.isWindows && !$0.isDemo }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        let chosen = win.first
            ?? uploads.filter { $0.isWindows }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }.first
        guard let up = chosen, let upId = up.id else { throw ItchError.noWindowsBuild }

        // Endpoint moderno de descarga: 302 → URL firmada del CDN. URLSession sigue el redirect y
        // baja los bytes; NO se decodifica JSON. `api_key` en query firma la petición.
        var comps = URLComponents(url: Self.base.appendingPathComponent("uploads/\(upId)/download"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "api_key", value: key),
                            URLQueryItem(name: "download_key_id", value: String(downloadKeyId))]
        guard let u = comps.url else { throw ItchError.http(0) }
        return (u, up.filename)
    }
}
