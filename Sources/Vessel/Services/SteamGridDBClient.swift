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
    private let apiKey: String? = nil

    func search(query: String) async throws -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        var components = URLComponents(string: "\(baseURL)/search/autocomplete")!
        components.queryItems = [URLQueryItem(name: "term", value: query)]

        var request = URLRequest(url: components.url!)
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
