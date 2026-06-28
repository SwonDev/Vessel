import Foundation

actor ProtonDBClient {
    enum Tier: String {
        case platinum = "platinum"
        case gold = "gold"
        case silver = "silver"
        case bronze = "bronze"
        case borked = "borked"

        var color: String {
            switch self {
            case .platinum: return "🟢"
            case .gold: return "🟡"
            case .silver: return "⚪"
            case .bronze: return "🟤"
            case .borked: return "🔴"
            }
        }

        var label: String {
            switch self {
            case .platinum: return "Perfecto — funciona out of the box"
            case .gold: return "Funciona con pequeños tweaks"
            case .silver: return "Funciona con ajustes moderados"
            case .bronze: return "Funciona parcialmente"
            case .borked: return "No funciona"
            }
        }
    }

    struct Summary: Codable {
        let tier: String
        let confidence: String?
        let score: Double?
        let total: Int?
        let trending: Bool?
    }

    private let baseURL = "https://www.protondb.com/api/v1"

    func fetchSummary(appId: String) async throws -> Summary? {
        guard let url = URL(string: "\(baseURL)/reports/summaries/\(appId).json") else {
            return nil
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return try? JSONDecoder().decode(Summary.self, from: data)
    }

    func tier(for appId: String) async -> Tier? {
        guard let summary = try? await fetchSummary(appId: appId) else { return nil }
        return Tier(rawValue: summary.tier)
    }
}
