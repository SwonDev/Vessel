import Foundation

/// Una noticia del juego (parche, evento, anuncio) del feed público de Steam.
struct SteamNewsItem: Codable, Identifiable, Hashable {
    var id: String { gid }
    let gid: String
    let title: String
    let url: String
    let date: Date
    let feedName: String
    let isExternal: Bool
}

/// Noticias y notas de parche de un juego, vía la API pública **ISteamNews** (`GetNewsForApp`,
/// sin clave). Es la sección «Noticias» de la ficha de Steam: qué cambió en la última
/// actualización y eventos recientes. Caché en disco por juego (`news-<appId>`) con el patrón
/// de la biblioteca: se muestra lo cacheado al instante y se refresca en segundo plano.
@MainActor
final class SteamNewsService {
    static let shared = SteamNewsService()
    private var cache: [String: [SteamNewsItem]] = [:]

    /// Noticias del juego (cache primero; refresco de red en segundo plano y re-entrega).
    /// Máximo `count` ítems, más recientes primero.
    func news(appId: String, count: Int = 4) async -> [SteamNewsItem] {
        if let mem = cache[appId] { return Array(mem.prefix(count)) }
        if let disk = LibraryCache.load("news-\(appId)", as: [SteamNewsItem].self) {
            cache[appId] = disk
            Task { await refresh(appId: appId) }   // refresco silencioso para la próxima apertura
            return Array(disk.prefix(count))
        }
        return await refresh(appId: appId, limit: count)
    }

    @discardableResult
    private func refresh(appId: String, limit: Int = 4) async -> [SteamNewsItem] {
        guard let url = URL(string: "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=\(appId)&count=8&maxlength=240&format=json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appnews = obj["appnews"] as? [String: Any],
              let items = appnews["newsitems"] as? [[String: Any]]
        else { return Array((cache[appId] ?? []).prefix(limit)) }

        let parsed: [SteamNewsItem] = items.compactMap { item in
            guard let gid = item["gid"] as? String,
                  let title = item["title"] as? String,
                  let link = item["url"] as? String,
                  let ts = item["date"] as? TimeInterval else { return nil }
            return SteamNewsItem(
                gid: gid,
                title: title,
                url: link,
                date: Date(timeIntervalSince1970: ts),
                feedName: (item["feedlabel"] as? String) ?? "Steam",
                isExternal: (item["is_external_url"] as? Bool) ?? false
            )
        }
        guard !parsed.isEmpty else { return Array((cache[appId] ?? []).prefix(limit)) }
        cache[appId] = parsed
        LibraryCache.save("news-\(appId)", parsed)
        return Array(parsed.prefix(limit))
    }
}
