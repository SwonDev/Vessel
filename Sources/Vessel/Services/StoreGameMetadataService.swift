import Foundation

/// Entrada `Sendable` para pedir metadatos sin trasladar tipos de SwiftUI al actor.
struct StoreGameMetadataRequest: Hashable, Sendable {
    enum Source: String, Sendable {
        case steam, epic, gog, local
    }

    let source: Source
    let id: String
    let title: String
    let steamAppId: String?
}

/// Fuente común, cacheada y sin autenticación para los metadatos visibles en biblioteca.
///
/// Seguridad y privacidad:
/// - solo consulta endpoints públicos por HTTPS;
/// - Epic se lee del caché local que ya mantiene Legendary;
/// - no adjunta cookies, tokens, identificadores de cuenta ni telemetría;
/// - limita el tamaño aceptado de cada JSON para evitar respuestas descontroladas.
actor StoreGameMetadataService {
    static let shared = StoreGameMetadataService()

    private static let maximumPayloadBytes = 6 * 1_024 * 1_024
    private struct CacheEntry: Codable, Sendable {
        let metadata: StoreGameMetadata
        let fetchedAt: Date
    }

    // La v2 invalida las entradas escritas antes de que `reviewSummary` formara parte del modelo.
    // Esas entradas son decodificables, pero el `nil` heredado impediría refrescar el veredicto
    // durante siete días y haría que la función nueva pareciera no funcionar.
    private static let persistentCacheURL = URL(fileURLWithPath: VesselPaths.cacheDirectory)
        .appendingPathComponent("store-metadata-v2.json")
    private static let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60
    private var cache: [String: CacheEntry]
    private var inFlight: [String: Task<StoreGameMetadata?, Never>] = [:]
    private var failedAt: [String: Date] = [:]
    private var persistenceTask: Task<Void, Never>?

    init() {
        cache = Self.loadPersistentCache()
    }

    func details(for request: StoreGameMetadataRequest) async -> StoreGameMetadata? {
        let key = "\(request.source.rawValue):\(request.id)"
        if let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < Self.cacheLifetime {
            return cached.metadata
        }
        if let failure = failedAt[key], Date().timeIntervalSince(failure) < 300 { return nil }
        if let task = inFlight[key] { return await task.value }

        let task = Task { await Self.fetchDetails(for: request) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            cache[key] = CacheEntry(metadata: result, fetchedAt: Date())
            failedAt[key] = nil
            schedulePersistence()
        } else {
            failedAt[key] = Date()
        }
        return result
    }

    func steamDetails(appId: String) async -> StoreGameMetadata? {
        await details(for: .init(source: .steam, id: appId, title: "", steamAppId: appId))
    }

    func gogDetails(productID: String, title: String = "") async -> StoreGameMetadata? {
        await details(for: .init(source: .gog, id: productID, title: title, steamAppId: nil))
    }

    func steamAppId(matching title: String) async -> String? {
        await Self.fetchMatchingSteamAppId(title: title)
    }

    /// Devuelve el índice local disponible sin tráfico. Es el primer paso de los filtros avanzados:
    /// al abrir una biblioteca aparecen inmediatamente los géneros ya vistos en fichas anteriores.
    func cachedDetails(for requests: [StoreGameMetadataRequest]) -> [String: StoreGameMetadata] {
        let now = Date()
        let values: [(String, StoreGameMetadata)] = requests.compactMap { request in
            guard let entry = cache[cacheKey(for: request)],
                  now.timeIntervalSince(entry.fetchedAt) < Self.cacheLifetime else { return nil }
            return (request.id, entry.metadata)
        }
        return Dictionary(uniqueKeysWithValues: values)
    }

    /// Completa el índice bajo petición explícita, en lotes pequeños. Nunca se lanza al iniciar la
    /// app ni al teclear en el buscador, evitando cientos de solicitudes invisibles.
    func indexDetails(for requests: [StoreGameMetadataRequest],
                      onProgress: @escaping @Sendable (Int, Int) -> Void) async -> [String: StoreGameMetadata] {
        var indexed = cachedDetails(for: requests)
        let missing = requests.filter { indexed[$0.id] == nil }
        let total = missing.count
        onProgress(0, total)
        var completed = 0
        for start in stride(from: 0, to: missing.count, by: 4) {
            guard !Task.isCancelled else { break }
            let batch = Array(missing[start..<min(start + 4, missing.count)])
            let results = await withTaskGroup(of: (String, StoreGameMetadata?).self) { group in
                for request in batch {
                    group.addTask { [weak self] in
                        guard let self else { return (request.id, nil) }
                        return (request.id, await self.details(for: request))
                    }
                }
                var values: [(String, StoreGameMetadata?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (id, metadata) in results { if let metadata { indexed[id] = metadata } }
            completed += batch.count
            onProgress(completed, total)
        }
        return indexed
    }

    private func cacheKey(for request: StoreGameMetadataRequest) -> String {
        "\(request.source.rawValue):\(request.id)"
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        let snapshot = cache
        persistenceTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Self.persist(snapshot)
        }
    }

    private static func loadPersistentCache() -> [String: CacheEntry] {
        guard let data = try? Data(contentsOf: persistentCacheURL),
              data.count <= 24 * 1_024 * 1_024,
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return [:] }
        return decoded
    }

    private static func persist(_ entries: [String: CacheEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: persistentCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: persistentCacheURL, options: .atomic)
    }

    // MARK: - Fuentes

    private static func fetchDetails(for request: StoreGameMetadataRequest) async -> StoreGameMetadata? {
        if let appId = request.steamAppId, !appId.isEmpty,
           let steam = await fetchSteamDetails(appId: appId) {
            return steam
        }

        switch request.source {
        case .steam:
            return nil
        case .gog:
            let gog = await fetchGogDetails(productID: request.id)
            guard let appId = await fetchMatchingSteamAppId(title: request.title),
                  let steam = await fetchSteamDetails(appId: appId) else { return gog }
            return merge(primary: gog, fallback: steam)
        case .epic:
            let epic = fetchEpicDetails(appName: request.id)
            guard let appId = await fetchMatchingSteamAppId(title: request.title),
                  let steam = await fetchSteamDetails(appId: appId) else { return epic }
            return merge(primary: epic, fallback: steam)
        case .local:
            guard let appId = await fetchMatchingSteamAppId(title: request.title) else { return nil }
            return await fetchSteamDetails(appId: appId)
        }
    }

    private static func fetchSteamDetails(appId: String) async -> StoreGameMetadata? {
        guard isNumericIdentifier(appId),
              let url = url(
                scheme: "https",
                host: "store.steampowered.com",
                path: "/api/appdetails",
                queryItems: [
                    URLQueryItem(name: "appids", value: appId),
                    URLQueryItem(name: "l", value: "spanish")
                ])
        else { return nil }
        guard let data = await fetchJSON(url) else { return nil }
        var details = parseSteamPayload(data, appId: appId)
        // Veredicto de las reseñas («Muy positivas»…), de appreviews (público, sin clave).
        details?.reviewSummary = await fetchReviewSummary(appId: appId)
        return details
    }

    /// Veredicto de las reseñas de Steam de `appreviews` traducido al español (la API solo lo
    /// ofrece en inglés). `nil` si no hay reseñas o falla la petición.
    private static func fetchReviewSummary(appId: String) async -> String? {
        guard let url = url(
            scheme: "https",
            host: "store.steampowered.com",
            path: "/appreviews/\(appId)",
            queryItems: [
                URLQueryItem(name: "json", value: "1"),
                URLQueryItem(name: "language", value: "all"),
                URLQueryItem(name: "purchase_type", value: "all"),
                URLQueryItem(name: "num_per_page", value: "0")
            ]) else { return nil }

        // Conserva el diagnóstico en vivo de Kimi sin perder las garantías actuales del cliente
        // común: HTTPS tras redirecciones, límite de payload, caché y timeout acotado.
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard data.count <= maximumPayloadBytes,
                  let http = response as? HTTPURLResponse,
                  http.url?.scheme?.lowercased() == "https",
                  (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Task { @MainActor in
                    LogStore.shared.log("appreviews \(appId): respuesta HTTP no válida (\(code)).", level: .warn)
                }
                return nil
            }
            guard let summary = parseSteamReviewSummaryPayload(data) else {
                Task { @MainActor in
                    LogStore.shared.log("appreviews \(appId): payload inesperado (\(data.count) bytes).", level: .warn)
                }
                return nil
            }
            return summary
        } catch {
            Task { @MainActor in
                LogStore.shared.log("appreviews \(appId): error \(error.localizedDescription)", level: .warn)
            }
            return nil
        }
    }

    static func parseSteamReviewSummaryPayload(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["success"] as? Int) == 1,
              let summary = object["query_summary"] as? [String: Any],
              let description = summary["review_score_desc"] as? String,
              !description.isEmpty else { return nil }
        return spanishReviewSummary(description)
    }

    /// Traducción de los veredictos de reseñas de Steam al español.
    static func spanishReviewSummary(_ english: String) -> String {
        switch english {
        case "Overwhelmingly Positive": return "Extremadamente positivas"
        case "Very Positive": return "Muy positivas"
        case "Positive": return "Positivas"
        case "Mostly Positive": return "Mayormente positivas"
        case "Mixed": return "Mixtas"
        case "Mostly Negative": return "Mayormente negativas"
        case "Negative": return "Negativas"
        case "Very Negative": return "Muy negativas"
        case "Overwhelmingly Negative": return "Extremadamente negativas"
        default: return english
        }
    }

    private static func fetchGogDetails(productID: String) async -> StoreGameMetadata? {
        guard isNumericIdentifier(productID),
              let url = url(
                scheme: "https",
                host: "api.gog.com",
                path: "/products/\(productID)",
                queryItems: [URLQueryItem(name: "expand", value: "description,screenshots")])
        else { return nil }
        guard let data = await fetchJSON(url) else { return nil }
        return parseGogPayload(data)
    }

    private static func fetchEpicDetails(appName: String) -> StoreGameMetadata? {
        guard isSafeFileComponent(appName) else { return nil }
        let file = URL(fileURLWithPath: "\(VesselPaths.appSupport)/Legendary", isDirectory: true)
            .appendingPathComponent("metadata", isDirectory: true)
            .appendingPathComponent("\(appName).json", isDirectory: false)
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
              data.count <= maximumPayloadBytes else { return nil }
        return parseEpicPayload(data)
    }

    private static func fetchMatchingSteamAppId(title: String) async -> String? {
        let normalized = normalizedTitle(title)
        let searchTerm = String(title.prefix(180))
        guard !normalized.isEmpty,
              let url = url(
                scheme: "https",
                host: "store.steampowered.com",
                path: "/api/storesearch/",
                queryItems: [
                    URLQueryItem(name: "term", value: searchTerm),
                    URLQueryItem(name: "cc", value: "us"),
                    URLQueryItem(name: "l", value: "es")
                ])
        else { return nil }
        guard let data = await fetchJSON(url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { return nil }

        for item in items.prefix(5) {
            guard let name = item["name"] as? String,
                  let id = item["id"] as? Int,
                  normalizedTitle(name) == normalized else { continue }
            return String(id)
        }
        return nil
    }

    private static func fetchJSON(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard data.count <= maximumPayloadBytes,
                  let http = response as? HTTPURLResponse,
                  http.url?.scheme?.lowercased() == "https",
                  (200...299).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Parsers comprobables sin red

    static func parseSteamPayload(_ data: Data, appId: String) -> StoreGameMetadata? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = object[appId] as? [String: Any],
              (entry["success"] as? Bool) == true,
              let source = entry["data"] as? [String: Any] else { return nil }

        var details = StoreGameMetadata()
        if let description = (source["short_description"] as? String)
            ?? (source["about_the_game"] as? String) {
            details.description = stripHTML(description)
        }
        details.developers = (source["developers"] as? [String]) ?? []
        details.publishers = (source["publishers"] as? [String]) ?? []
        details.releaseDate = (source["release_date"] as? [String: Any])?["date"] as? String
        details.genres = ((source["genres"] as? [[String: Any]]) ?? [])
            .compactMap { $0["description"] as? String }
        details.categories = ((source["categories"] as? [[String: Any]]) ?? [])
            .compactMap { $0["description"] as? String }
        details.metacritic = (source["metacritic"] as? [String: Any])?["score"] as? Int
        details.reviewCount = (source["recommendations"] as? [String: Any])?["total"] as? Int
        details.dlcIds = (source["dlc"] as? [Int]) ?? []

        if let achievements = source["achievements"] as? [String: Any] {
            details.achievementsTotal = achievements["total"] as? Int
            details.achievementIcons = ((achievements["highlighted"] as? [[String: Any]]) ?? [])
                .prefix(10)
                .compactMap { httpsURL($0["path"] as? String) }
        }

        let screenshots = ((source["screenshots"] as? [[String: Any]]) ?? []).prefix(12)
        details.screenshots = screenshots.compactMap { httpsURL($0["path_thumbnail"] as? String) }
        details.screenshotsFull = screenshots.compactMap { httpsURL($0["path_full"] as? String) }

        details.movies = ((source["movies"] as? [[String: Any]]) ?? []).prefix(4).compactMap { movie in
            guard let mp4 = movie["mp4"] as? [String: Any],
                  let videoURL = httpsURL((mp4["max"] as? String) ?? (mp4["480"] as? String))
            else { return nil }
            let rawID = movie["id"]
            let id = (rawID as? Int).map(String.init) ?? (rawID as? String) ?? videoURL.absoluteString
            return StoreGameMovie(
                id: id,
                name: movie["name"] as? String,
                thumbnailURL: httpsURL(movie["thumbnail"] as? String),
                videoURL: videoURL
            )
        }
        return details
    }

    static func parseGogPayload(_ data: Data) -> StoreGameMetadata? {
        guard let source = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var details = StoreGameMetadata()
        if let description = source["description"] as? [String: Any] {
            let body = (description["full"] as? String) ?? (description["lead"] as? String) ?? ""
            details.description = stripHTML(body)
        }
        let screenshots = ((source["screenshots"] as? [[String: Any]]) ?? []).prefix(12)
        details.screenshots = screenshots.compactMap { gogImageURL($0, formatter: "ggvgm_2x") }
        details.screenshotsFull = screenshots.compactMap { gogImageURL($0, formatter: "ggvgl_2x") }
        return details
    }

    static func parseEpicPayload(_ data: Data) -> StoreGameMetadata? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = object["metadata"] as? [String: Any] else { return nil }
        var details = StoreGameMetadata()
        if let description = source["description"] as? String, !description.isEmpty {
            details.description = stripHTML(description)
        }
        if let developer = source["developer"] as? String, !developer.isEmpty {
            details.developers = [developer]
        }
        details.screenshots = ((source["keyImages"] as? [[String: Any]]) ?? [])
            .filter { ($0["type"] as? String) == "Screenshot" }
            .prefix(12)
            .compactMap { httpsURL($0["url"] as? String) }
        details.screenshotsFull = details.screenshots
        return details
    }

    static func normalizedTitle(_ value: String) -> String {
        var title = value.lowercased()
        for junk in ["™", "®", "©", "’", "'", ":", "-", "–", "—", ".", ",", "!", "?", "(", ")"] {
            title = title.replacingOccurrences(of: junk, with: " ")
        }
        for suffix in ["definitive edition", "game of the year edition", "goty edition",
                       "complete edition", "deluxe edition", "remastered", "the "] {
            title = title.replacingOccurrences(of: suffix, with: " ")
        }
        return title.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined()
    }

    private static func merge(primary: StoreGameMetadata?, fallback: StoreGameMetadata) -> StoreGameMetadata {
        guard var primary else { return fallback }
        if primary.description?.isEmpty != false { primary.description = fallback.description }
        if primary.developers.isEmpty { primary.developers = fallback.developers }
        if primary.publishers.isEmpty { primary.publishers = fallback.publishers }
        if primary.releaseDate == nil { primary.releaseDate = fallback.releaseDate }
        if primary.genres.isEmpty { primary.genres = fallback.genres }
        if primary.metacritic == nil { primary.metacritic = fallback.metacritic }
        if primary.screenshots.isEmpty { primary.screenshots = fallback.screenshots }
        if primary.screenshotsFull.isEmpty { primary.screenshotsFull = fallback.screenshotsFull }
        if primary.movies.isEmpty { primary.movies = fallback.movies }
        if primary.categories.isEmpty { primary.categories = fallback.categories }
        if primary.reviewCount == nil { primary.reviewCount = fallback.reviewCount }
        if primary.reviewSummary == nil { primary.reviewSummary = fallback.reviewSummary }
        return primary
    }

    private static func gogImageURL(_ source: [String: Any], formatter: String) -> URL? {
        guard let template = source["formatter_template_url"] as? String else { return nil }
        let value = template.replacingOccurrences(of: "{formatter}", with: formatter)
        return httpsURL(value.hasPrefix("//") ? "https:\(value)" : value)
    }

    private static func httpsURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    private static func url(scheme: String, host: String, path: String,
                            queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = queryItems
        return components.url
    }

    private static func isNumericIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func isSafeFileComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"), !value.contains("..") else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        }
    }

    private static func stripHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
