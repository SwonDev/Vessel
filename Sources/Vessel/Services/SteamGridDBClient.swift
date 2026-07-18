import Foundation

actor SteamGridDBClient {
    struct GameArtwork: Codable {
        let url: String
        let thumb: String?

        enum CodingKeys: String, CodingKey {
            case url
            case thumb
        }
    }

    struct SearchResult: Codable {
        let id: Int
        let name: String
        let types: [String]?
    }

    struct GridResponse<T: Codable>: Codable {
        let success: Bool
        let data: [T]?
    }

    private let baseURL = "https://www.steamgriddb.com/api/v2"
    /// Clave de la API de SteamGridDB (gratis en steamgriddb.com/profile/preferences/api). Se
    /// configura en Ajustes y se guarda en `UserDefaults`. Sin ella la búsqueda de carátulas va
    /// muy limitada (rate-limit anónimo); con ella se obtienen portadas de alta calidad.
    static let apiKeyDefaultsKey = "vessel.steamgriddb.apikey"
    private var apiKey: String? {
        let k = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey) ?? ""
        return k.isEmpty ? nil : k
    }

    /// URL de búsqueda: el término va como **segmento de ruta** (`/search/autocomplete/{term}`),
    /// NO como query param. La API v2 de SteamGridDB responde 404 a `?term=` (verificado: la forma
    /// por path da 401 sin key = existe; `?term=` da 404), así que con `?term=` la búsqueda de
    /// carátulas devolvía SIEMPRE vacío.
    static func searchURL(base: String, query: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let term = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: "\(base)/search/autocomplete/\(term)")
    }

    func search(query: String) async throws -> [SearchResult] {
        guard !query.isEmpty, let url = Self.searchURL(base: baseURL, query: query) else { return [] }

        var request = URLRequest(url: url)
        if let key = apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(GridResponse<SearchResult>.self, from: data)
        return decoded.data ?? []
    }

    func artwork(for gameId: Int, type: String = "600x900") async throws -> [GameArtwork] {
        let url = URL(string: "\(baseURL)/grids/game/\(gameId)?dimensions=\(type)")!
        var request = URLRequest(url: url)
        if let key = apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(GridResponse<GameArtwork>.self, from: data)
        return decoded.data ?? []
    }

    func coverURLs(forSteamAppId appId: String) -> String {
        "https://cdn.akamai.steamstatic.com/steam/apps/\(appId)/library_600x900_2x.jpg"
    }
}
