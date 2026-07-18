import Foundation

/// **Base de datos de DRM** (en vivo, con caché). Complementa al escáner de disco con lo que los
/// ficheros NO pueden decir: la señal decisiva de muchos DRM vive FUERA del disco (token de Denuvo,
/// licencia por dispositivo de UWP, token de Epic/Battle.net validado en servidor).
///
/// Combina TRES fuentes, todas verificadas en vivo:
///  1. **PCGamingWiki** (Cargo API) — campo `Steam_DRM`/`Uses_DRM`. Cataloga **~1.930 juegos como
///     DRM‑free**. Es la única fuente con una señal POSITIVA de "esto no lleva DRM".
///  2. **Steam Store** (`appdetails`) — `drm_notice` / `ext_user_account_notice`, escritos por el
///     publisher. **Precisión alta, recall bajo**: si dice Denuvo, es Denuvo; su silencio NO prueba
///     nada (p. ej. Tekken 8 lleva Denuvo y su aviso está vacío).
///  3. **MacAnticheatData** (Heroic) — anti‑cheat en **macOS** (no el de Linux): 1.166 entradas,
///     **0 funcionando**. Si un juego sale ahí, es un muro y hay que decirlo con honestidad.
///
/// ⚠️ Matiz que condiciona todo el diseño: el valor `Steam` de PCGW es **grueso** (mezcla "usa
/// Steamworks" con "tiene CEG") → **NO se usa para bloquear**. Core Keeper figura como `Steam` y sin
/// embargo corre standalone con Goldberg (verificado). Solo se bloquea con señales POSITIVAS de DRM
/// real (Denuvo, always‑online, cuenta de terceros, anti‑cheat). Quién decide de verdad si un juego
/// de Steam es "generable" sigue siendo el escáner de disco (CEG/SteamStub).
actor DRMDatabase {
    static let shared = DRMDatabase()

    // MARK: - Modelo

    struct Verdict: Codable, Sendable {
        var appId: String
        /// Valores del campo `Steam_DRM` de PCGW ("DRM-free", "Steam", "Denuvo Anti-Tamper"…).
        var pcgwSteamDRM: [String] = []
        /// Campo `Uses_DRM` de PCGW: todos los DRM que conoce del juego.
        var pcgwUsesDRM: [String] = []
        var steamDRMNotice: String?
        var steamAccountNotice: String?
        var antiCheats: [String] = []
        /// Estado en macOS: "Denied" | "Broken" | "Unknown" (de MacAnticheatData). Ninguno funciona.
        var antiCheatStatus: String?
        var checkedAt: Date = Date()

        /// MacAnticheatData usa `Denied` y `Broken` para estados que no pueden jugarse en macOS.
        /// `Unknown` se conserva como incertidumbre y nunca se convierte automáticamente en
        /// «No funciona» para evitar falsos negativos.
        var antiCheatBlocksMacOS: Bool {
            guard !antiCheats.isEmpty else { return false }
            switch antiCheatStatus?.lowercased() {
            case "denied", "broken": return true
            default: return false
            }
        }

        /// PCGW lo declara **DRM‑free**: la señal positiva más fiable que existe.
        var isDRMFreeConfirmed: Bool {
            pcgwSteamDRM.contains { $0.caseInsensitiveCompare("DRM-free") == .orderedSame }
        }

        /// Motivos por los que el juego **no** puede correr como copia local independiente. Solo
        /// señales POSITIVAS (nunca el `Steam` genérico de PCGW, que es ambiguo).
        var blockers: [String] {
            var out: [String] = []
            let notice = (steamDRMNotice ?? "").lowercased()
            let all = (pcgwSteamDRM + pcgwUsesDRM).map { $0.lowercased() }

            if notice.contains("denuvo") || all.contains(where: { $0.contains("denuvo") }) {
                out.append("Denuvo Anti-Tamper")
            }
            for name in ["always online", "online activation"] where all.contains(where: { $0.contains(name) }) {
                out.append("Requiere conexión permanente")
            }
            for (needle, label) in [("ubisoft connect", "Ubisoft Connect"), ("ea app", "EA app"),
                                    ("rockstar games launcher", "Rockstar Games Launcher"),
                                    ("games for windows", "Games for Windows LIVE"),
                                    ("securom", "SecuROM"), ("starforce", "StarForce"), ("tages", "TAGES")]
            where all.contains(where: { $0.contains(needle) }) { out.append(label) }

            if let acct = steamAccountNotice, !acct.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("Cuenta/launcher de terceros: \(acct)")
            }
            if let st = antiCheatStatus, !antiCheats.isEmpty {
                out.append("Anti-cheat (\(antiCheats.joined(separator: ", "))) — en macOS: \(st.lowercased())")
            }
            return Array(Set(out)).sorted()
        }

        /// Resumen honesto para la UI/logs.
        var summary: String {
            if isDRMFreeConfirmed && blockers.isEmpty { return "DRM‑free confirmado por PCGamingWiki." }
            if blockers.isEmpty { return "Sin DRM conocido en las bases de datos (el silencio no lo garantiza)." }
            return "DRM detectado: " + blockers.joined(separator: " · ")
        }
    }

    // MARK: - Caché

    private var cache: [String: Verdict] = [:]
    private var antiCheatIndex: [String: (status: String, list: [String])]?
    /// Catálogo completo de AppIDs DRM‑free (PCGW), cacheado en disco: son 4 páginas de API.
    private var drmFreeSet: Set<String>?
    private var drmFreeFetchedAt: Date?
    private let cacheURL = URL(fileURLWithPath: "\(VesselPaths.cacheDirectory)/drm-db.json")
    private let drmFreeURL = URL(fileURLWithPath: "\(VesselPaths.cacheDirectory)/drm-free-appids.json")
    /// Denuvo ROTA (≈34 % de los juegos que lo llevaron se lo han quitado) → nunca empaquetar una
    /// lista estática; consultar en vivo y refrescar cada pocos días.
    private let ttl: TimeInterval = 7 * 24 * 3600

    /// La caché se lee del disco de forma perezosa (un actor no puede hacerlo en su `init`).
    private var cacheLoaded = false

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: cacheURL), let c = try? dec.decode([String: Verdict].self, from: d) {
            cache = c
        }
        if let d = try? Data(contentsOf: drmFreeURL),
           let s = try? dec.decode(DRMFreeCache.self, from: d) {
            drmFreeSet = s.appIds; drmFreeFetchedAt = s.fetchedAt
        }
    }

    private struct DRMFreeCache: Codable { let appIds: Set<String>; let fetchedAt: Date }

    private func saveDRMFreeSet() {
        guard let s = drmFreeSet, let at = drmFreeFetchedAt else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(atPath: VesselPaths.cacheDirectory, withIntermediateDirectories: true)
        if let d = try? enc.encode(DRMFreeCache(appIds: s, fetchedAt: at)) { try? d.write(to: drmFreeURL, options: .atomic) }
    }
    private func saveCache() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(atPath: VesselPaths.cacheDirectory, withIntermediateDirectories: true)
        if let d = try? enc.encode(cache) { try? d.write(to: cacheURL, options: .atomic) }
    }

    // MARK: - Consulta

    /// Veredicto combinado para un juego de Steam. Cacheado (TTL 7 días). Nunca lanza: si una fuente
    /// falla (sin red, API caída), devuelve lo que haya conseguido.
    func lookup(steamAppId appId: String) async -> Verdict {
        loadCacheIfNeeded()
        if let hit = cache[appId], Date().timeIntervalSince(hit.checkedAt) < ttl { return hit }

        var v = Verdict(appId: appId)
        if let p = await pcgw(appId: appId) { v.pcgwSteamDRM = p.steamDRM; v.pcgwUsesDRM = p.usesDRM }
        if let s = await steamNotices(appId: appId) { v.steamDRMNotice = s.drm; v.steamAccountNotice = s.account }
        if let a = await antiCheat(appId: appId) { v.antiCheatStatus = a.status; v.antiCheats = a.list }
        v.checkedAt = Date()
        cache[appId] = v
        saveCache()
        return v
    }

    /// **Autodetección masiva**: cruza tu biblioteca con el catálogo DRM‑free de PCGamingWiki y
    /// devuelve los juegos que son **DRM‑free confirmados** — los que puedes convertir en copias
    /// locales tuyas para siempre. Una sola consulta para toda la biblioteca (cacheada).
    ///
    /// Verificado con una biblioteca real de 1.749 juegos → **219 confirmados DRM‑free** (12 %),
    /// entre ellos Baldur's Gate 3, ARK, ABZÛ o Amnesia.
    func drmFreeGames<T>(in owned: [T], appId: (T) -> String) async -> [T] {
        let set = await drmFreeAppIds()
        guard !set.isEmpty else { return [] }
        return owned.filter { set.contains(appId($0)) }
    }

    /// Conjunto (cacheado) de AppIDs DRM‑free. Se refresca con el mismo TTL que el resto: el catálogo
    /// cambia (juegos que quitan Denuvo, altas nuevas…).
    func drmFreeAppIds() async -> Set<String> {
        loadCacheIfNeeded()
        if let s = drmFreeSet, let at = drmFreeFetchedAt, Date().timeIntervalSince(at) < ttl { return s }
        let ids = await allDRMFreeSteamAppIds()
        if !ids.isEmpty {
            drmFreeSet = ids
            drmFreeFetchedAt = Date()
            saveDRMFreeSet()
            await MainActor.run {
                LogStore.shared.log("DRM: catálogo DRM-free de PCGamingWiki cargado (\(ids.count) AppIDs).", level: .info)
            }
        }
        return ids
    }

    /// Todos los AppIDs de Steam que PCGamingWiki cataloga como **DRM‑free**. Un juego puede aportar
    /// varios AppIDs (base + DLCs), así que el total supera al de fichas (~1.930 fichas → ~3.050 IDs).
    func allDRMFreeSteamAppIds() async -> Set<String> {
        var ids: Set<String> = []
        var offset = 0
        while offset < 4000 {   // salvaguarda; el límite duro de la API es 500 por página
            guard let rows = await cargo(
                tables: "Availability,Infobox_game",
                joinOn: "Availability._pageID=Infobox_game._pageID",
                fields: "Infobox_game.Steam_AppID=appids",
                where: #"Availability.Steam_DRM HOLDS "DRM-free""#,
                limit: 500, offset: offset), !rows.isEmpty else { break }
            for row in rows {
                // `Steam_AppID` es un campo LISTA separado por ", " y puede incluir DLCs.
                (row["appids"] as? String)?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .forEach { ids.insert($0) }
            }
            offset += 500
        }
        return ids
    }

    // MARK: - Fuentes

    /// PCGamingWiki vía **Cargo API** (`api.php` NO está tras Cloudflare; `/wiki/` sí).
    private func pcgw(appId: String) async -> (steamDRM: [String], usesDRM: [String])? {
        // `Steam_AppID` es un campo LISTA → solo admite HOLDS (un `IS NOT NULL` lanza MWException).
        guard let rows = await cargo(
            tables: "Infobox_game,Availability",
            joinOn: "Infobox_game._pageID=Availability._pageID",
            fields: "Availability.Steam_DRM=steam_drm,Availability.Uses_DRM=uses_drm",
            where: #"Infobox_game.Steam_AppID HOLDS "\#(appId)""#,
            limit: 5, offset: 0), let first = rows.first else { return nil }
        func list(_ key: String) -> [String] {
            (first[key] as? String)?.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? []
        }
        // Se deduplica: `Uses_DRM` repite valores (un elemento por plataforma/edición).
        return (Array(Set(list("steam_drm"))).sorted(), Array(Set(list("uses_drm"))).sorted())
    }

    /// Ejecuta una consulta Cargo y devuelve las filas (`title` de cada resultado).
    private func cargo(tables: String, joinOn: String, fields: String, where whereClause: String,
                       limit: Int, offset: Int) async -> [[String: Any]]? {
        var c = URLComponents(string: "https://www.pcgamingwiki.com/w/api.php")!
        c.queryItems = [
            .init(name: "action", value: "cargoquery"), .init(name: "format", value: "json"),
            .init(name: "tables", value: tables), .init(name: "join_on", value: joinOn),
            .init(name: "fields", value: fields), .init(name: "where", value: whereClause),
            .init(name: "limit", value: String(limit)), .init(name: "offset", value: String(offset))
        ]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(SteamConstants.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["cargoquery"] as? [[String: Any]] else { return nil }
        return arr.compactMap { $0["title"] as? [String: Any] }
    }

    /// Steam Store `appdetails`. Texto LIBRE del publisher → comparar por substring, con trim.
    private func steamNotices(appId: String) async -> (drm: String?, account: String?)? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appId)&l=english") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(SteamConstants.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json[appId] as? [String: Any],
              (entry["success"] as? Bool) == true,
              let d = entry["data"] as? [String: Any] else { return nil }
        func clean(_ s: Any?) -> String? {
            let t = (s as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
        return (clean(d["drm_notice"]), clean(d["ext_user_account_notice"]))
    }

    /// Anti‑cheat en **macOS** (dataset de Heroic). Se descarga una vez y se indexa por AppID de Steam.
    private func antiCheat(appId: String) async -> (status: String, list: [String])? {
        if antiCheatIndex == nil { await loadAntiCheatIndex() }
        return antiCheatIndex?[appId]
    }

    private func loadAntiCheatIndex() async {
        antiCheatIndex = [:]
        guard let url = URL(string: "https://raw.githubusercontent.com/Heroic-Games-Launcher/MacAnticheatData/main/games.json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        var idx: [String: (status: String, list: [String])] = [:]
        for g in arr {
            guard let stores = g["storeIds"] as? [String: Any],
                  let steam = stores["steam"] as? String,
                  let status = g["status"] as? String else { continue }
            idx[steam] = (status, (g["anticheats"] as? [String]) ?? [])
        }
        antiCheatIndex = idx
        let n = idx.count
        await MainActor.run {
            LogStore.shared.log("DRM: índice de anti-cheat de macOS cargado (\(n) juegos con AppID).", level: .debug)
        }
    }
}
