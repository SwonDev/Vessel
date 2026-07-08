import Foundation

@MainActor
@Observable
final class Updater {
    struct Release: Codable, Identifiable {
        let id: Int
        let tagName: String
        let name: String
        let body: String
        let publishedAt: Date
        let htmlUrl: String
        let assets: [Asset]

        struct Asset: Codable, Identifiable {
            let id: Int
            let name: String
            let browserDownloadUrl: String
            let size: Int
        }
    }

    private let repoOwner = "SwonDev"
    private let repoName = "Vessel"

    func checkForUpdates(currentVersion: String) async -> Release? {
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let release = try decoder.decode(Release.self, from: data)
            return isNewer(release.tagName, than: currentVersion) ? release : nil
        } catch {
            return nil
        }
    }

    private func isNewer(_ remote: String, than current: String) -> Bool {
        let remoteClean = remote.hasPrefix("v") ? String(remote.dropFirst()) : remote
        return remoteClean.compare(current, options: .numeric) == .orderedDescending
    }
}
