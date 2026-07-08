import Foundation

/// Cliente **no oficial** de Humble Bundle. Autentica con la cookie de sesión `_simpleauth_sess`
/// capturada por `HumbleLoginWebView`, y usa los endpoints internos que emplean las herramientas
/// open‑source:
///  - `GET /api/v1/user/order` → lista de `gamekey` (compras).
///  - `GET /api/v1/order/{gamekey}?all_tpkds=true` → detalle con `subproducts[].downloads[]`.
///
/// Solo expone descargas **DRM‑free de Windows** (`download_struct[].url.web`); ignora las claves
/// de terceros (Steam, etc.). Las URLs `dl.humble.com` están firmadas y caducan, así que la
/// descarga se resuelve **fresca** en el momento (por `gamekey:machine_name`).
actor HumbleService {
    static let shared = HumbleService()

    private static let base = "https://www.humblebundle.com"
    private static let sessionDefault = "vessel.humble.session"

    // MARK: - Vinculación

    nonisolated var sessionCookie: String? { UserDefaults.standard.string(forKey: Self.sessionDefault) }
    nonisolated var isLinked: Bool { !(sessionCookie ?? "").isEmpty }
    nonisolated func setSession(_ value: String?) {
        if let v = value, !v.isEmpty { UserDefaults.standard.set(v, forKey: Self.sessionDefault) }
        else { UserDefaults.standard.removeObject(forKey: Self.sessionDefault) }
    }

    // MARK: - Modelos (tolerantes)

    struct OrderRef: Decodable { let gamekey: String? }

    struct Order: Decodable {
        let gamekey: String?
        let product: Product?
        let subproducts: [Subproduct]?
        struct Product: Decodable { let human_name: String? }
    }
    struct Subproduct: Decodable {
        let machine_name: String?
        let human_name: String?
        let icon: String?
        let downloads: [Download]?
    }
    struct Download: Decodable {
        let platform: String?          // "windows" | "mac" | "linux" | "audio"…
        let download_struct: [DownloadStruct]?
    }
    struct DownloadStruct: Decodable {
        let name: String?
        let human_size: String?
        let file_size: Int64?
        let url: DLURL?
        struct DLURL: Decodable { let web: String?; let bittorrent: String? }
    }

    /// Entrada de biblioteca lista para mostrar (una por subproducto con build de Windows DRM‑free).
    struct LibraryItem: Sendable {
        let gamekey: String
        let machineName: String
        let name: String
        let iconURL: String?
        let humanSize: String?
        /// id estable para `LocalGamesStore` (`sourceId`).
        var sourceId: String { "\(gamekey):\(machineName)" }
    }

    enum HumbleError: LocalizedError {
        case notLinked, http(Int), sessionExpired, noWindowsBuild
        var errorDescription: String? {
            switch self {
            case .notLinked: return "No has vinculado tu cuenta de Humble Bundle."
            case .http(let c): return "Humble respondió HTTP \(c)."
            case .sessionExpired: return "La sesión de Humble ha caducado. Vuelve a iniciar sesión."
            case .noWindowsBuild: return "Este producto no tiene una descarga DRM‑free de Windows."
            }
        }
    }

    // MARK: - Peticiones

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let sess = sessionCookie, !sess.isEmpty else { throw HumbleError.notLinked }
        var req = URLRequest(url: URL(string: Self.base + path)!)
        req.setValue("_simpleauth_sess=\(sess)", forHTTPHeaderField: "Cookie")
        req.setValue("hb_android_app", forHTTPHeaderField: "X-Requested-By")   // igual que las libs OSS
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Vessel/0.1",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw HumbleError.sessionExpired }
            if !(200...299).contains(http.statusCode) { throw HumbleError.http(http.statusCode) }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Lista los `gamekey` de todas las compras del usuario.
    func fetchOrderKeys() async throws -> [String] {
        let refs = try await get("/api/v1/user/order", as: [OrderRef].self)
        return refs.compactMap { $0.gamekey }
    }

    func fetchOrder(_ gamekey: String) async throws -> Order {
        try await get("/api/v1/order/\(gamekey)?all_tpkds=true", as: Order.self)
    }

    /// Biblioteca completa: recorre todas las órdenes y devuelve un item por subproducto que tenga
    /// una descarga **DRM‑free de Windows**. Ignora claves de Steam/terceros (no tienen `url.web`).
    func fetchLibrary() async throws -> [LibraryItem] {
        let keys = try await fetchOrderKeys()
        var items: [LibraryItem] = []
        var seen = Set<String>()
        // Concurrencia acotada para no martillear la API.
        try await withThrowingTaskGroup(of: [LibraryItem].self) { group in
            var iterator = keys.makeIterator()
            let maxConcurrent = 6
            var running = 0
            func addNext() { if let k = iterator.next() { running += 1; group.addTask { (try? await self.itemsForOrder(k)) ?? [] } } }
            for _ in 0..<maxConcurrent { addNext() }
            while running > 0 {
                if let batch = try await group.next() {
                    running -= 1
                    for it in batch where !seen.contains(it.sourceId) { seen.insert(it.sourceId); items.append(it) }
                    addNext()
                }
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func itemsForOrder(_ gamekey: String) async throws -> [LibraryItem] {
        let order = try await fetchOrder(gamekey)
        var out: [LibraryItem] = []
        for sub in order.subproducts ?? [] {
            guard let mn = sub.machine_name,
                  let win = (sub.downloads ?? []).first(where: { ($0.platform ?? "").lowercased() == "windows" }),
                  let ds = (win.download_struct ?? []).first(where: { $0.url?.web != nil }) else { continue }
            out.append(LibraryItem(gamekey: gamekey, machineName: mn,
                                   name: sub.human_name ?? mn, iconURL: sub.icon,
                                   humanSize: ds.human_size))
        }
        return out
    }

    /// Resuelve la URL de descarga (firmada, fresca) del build de Windows de un subproducto.
    func windowsDownloadURL(gamekey: String, machineName: String) async throws -> URL {
        let order = try await fetchOrder(gamekey)
        guard let sub = (order.subproducts ?? []).first(where: { $0.machine_name == machineName }),
              let win = (sub.downloads ?? []).first(where: { ($0.platform ?? "").lowercased() == "windows" }),
              let web = (win.download_struct ?? []).compactMap({ $0.url?.web }).first,
              let u = URL(string: web) else { throw HumbleError.noWindowsBuild }
        return u
    }
}
