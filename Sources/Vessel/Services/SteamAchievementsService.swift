import Foundation

/// Trae el **estado REAL de logros** (desbloqueado/bloqueado) de un juego de Steam para el usuario
/// logueado, vía Steam Web API. Enriquece la sección de logros de la ficha (que hoy solo muestra el
/// total + iconos destacados públicos de `appdetails`, sin estado). NO duplica esa sección: la
/// alimenta con datos reales cuando hay credencial; si no, la ficha mantiene su vista decorativa.
///
/// Credenciales (en orden): el **access_token** de la sesión oficial (`steam.accessToken`) o la
/// **Web API key** del usuario (`SteamAccountService.webAPIKey`, en Ajustes). Sin ninguna válida
/// devuelve `nil` (degradación limpia).
///
/// - `GetPlayerAchievements` → estado real (achieved/unlocktime) + nombre/descripción (con `l=`).
/// - `GetGlobalAchievementPercentagesForApp` → rareza global (PÚBLICO, sin key).
/// - `GetSchemaForGame` → iconos por logro (requiere key; sin ella se muestran sin icono de juego).
actor SteamAchievementsService {
    struct Achievement: Identifiable, Hashable {
        let apiName: String
        var displayName: String
        var description: String
        var unlocked: Bool
        var unlockTime: Date?
        var iconUnlocked: URL?
        var iconLocked: URL?
        var globalPercent: Double?     // % de jugadores que lo tienen (rareza)
        var id: String { apiName }
    }

    struct Progress {
        let achievements: [Achievement]
        let unlocked: Int
        let total: Int
        /// `true` si conocemos el estado real desbloqueado/bloqueado (perfil público o token de
        /// sesión). Si es `false`, mostramos la lista completa (iconos/nombres/rareza) SIN marcar
        /// estado — es honesto: no sabemos cuáles tienes.
        let stateKnown: Bool
        var fraction: Double { total > 0 ? Double(unlocked) / Double(total) : 0 }
    }

    static let shared = SteamAchievementsService()
    private let base = "https://api.steampowered.com/ISteamUserStats"

    /// Logros del `appId`. Combina lo que se puede obtener:
    ///  - **Schema** (con la Web API key): lista COMPLETA con iconos + nombres + descripciones. Va
    ///    aunque el perfil sea privado.
    ///  - **Rareza global** (público): % de jugadores que tienen cada logro.
    ///  - **Estado del jugador** (access_token o key): desbloqueado/bloqueado + fecha. Requiere
    ///    perfil "Detalles del juego" público (o un token de sesión válido). Si no, `stateKnown=false`
    ///    y mostramos la lista sin marcar estado (honesto).
    ///
    /// `nil` solo si no hay NADA que mostrar (ni schema con key ni estado). En ese caso la ficha se
    /// queda con su vista decorativa.
    func fetch(appId: String, steamID64: String, language: String = "spanish") async -> Progress? {
        // access_token de sesión (se refresca solo desde el refresh_token). Autentica como el usuario
        // → ve sus logros DESBLOQUEADOS aunque el perfil sea privado (como el cliente de Steam), vía
        // IPlayerService/GetTopAchievementsForGames (la Web API GetPlayerAchievements NO lo permite).
        let token = await SteamAuthService.currentAccessToken()
        let key = await SteamAccountService.webAPIKey
        guard !steamID64.isEmpty else { return nil }

        async let schemaTask = key.isEmpty ? [:] : schemaIcons(appId: appId, key: key, language: language)
        async let topTask = token.isEmpty ? Optional<TopResult>.none
            : topAchievements(appId: appId, steamID64: steamID64, token: token, language: language)

        let schema = await schemaTask
        let top = await topTask
        // Estado real de desbloqueo desde el login: conjunto de hashes de icono + nombres desbloqueados.
        let unlockedHashes = Set((top?.unlocked ?? []).compactMap { Self.iconHash($0.icon) })
        let unlockedNames = Set((top?.unlocked ?? []).map { $0.name })
        let stateKnown = top != nil

        var list: [Achievement]
        var total: Int
        if !schema.isEmpty {
            // Lista COMPLETA (schema, con key) + estado real de desbloqueo (login).
            let globals = await globalPercentages(appId: appId)
            list = schema.map { (apiname, s) in
                let hash = s.icon.flatMap { Self.iconHash($0.lastPathComponent) }
                let unlocked = (hash.map(unlockedHashes.contains) ?? false) || unlockedNames.contains(s.displayName)
                return Achievement(apiName: apiname, displayName: s.displayName, description: s.description,
                    unlocked: stateKnown && unlocked, unlockTime: nil,
                    iconUnlocked: s.icon, iconLocked: s.iconGray, globalPercent: globals[apiname])
            }
            total = list.count
        } else if let top, top.total > 0 {
            // Solo con login (sin key): mostramos los DESBLOQUEADOS con todo el detalle (icono real,
            // nombre, descripción, rareza) + el total del juego. Los bloqueados no se detallan (sin
            // schema no tenemos sus nombres/iconos) pero se indican como recuento.
            list = top.unlocked.map { t in
                Achievement(apiName: t.name, displayName: t.name, description: t.desc,
                    unlocked: true, unlockTime: nil,
                    iconUnlocked: Self.iconURL(appId: appId, file: t.icon),
                    iconLocked: Self.iconURL(appId: appId, file: t.iconGray),
                    globalPercent: Double(t.percent))
            }
            total = top.total
        } else {
            return nil   // ni schema ni login → la ficha usa su vista decorativa
        }

        // Desbloqueados primero; luego por rareza (más raro antes) y nombre.
        list.sort { a, b in
            if stateKnown, a.unlocked != b.unlocked { return a.unlocked }
            let pa = a.globalPercent ?? 0, pb = b.globalPercent ?? 0
            if pa != pb { return pa < pb }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
        let unlocked = stateKnown ? (schema.isEmpty ? list.count : list.filter(\.unlocked).count) : 0
        return Progress(achievements: list, unlocked: unlocked, total: total, stateKnown: stateKnown)
    }

    // MARK: - Endpoints

    struct TopAch { let name: String; let desc: String; let icon: String; let iconGray: String; let percent: Double }
    struct TopResult { let unlocked: [TopAch]; let total: Int }

    /// Logros DESBLOQUEADOS del usuario vía `IPlayerService/GetTopAchievementsForGames` (acepta
    /// access_token → ve datos propios aunque el perfil sea privado). Devuelve los desbloqueados
    /// (con icono/nombre/desc/rareza) + el total del juego. `nil` si el token no vale.
    private func topAchievements(appId: String, steamID64: String, token: String, language: String) async -> TopResult? {
        var comps = URLComponents(string: "https://api.steampowered.com/IPlayerService/GetTopAchievementsForGames/v1/")!
        comps.queryItems = [
            .init(name: "access_token", value: token),
            .init(name: "steamid", value: steamID64),
            .init(name: "language", value: language),
            .init(name: "max_achievements", value: "100"),
            .init(name: "appids[0]", value: appId)
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        struct Payload: Decodable {
            struct Game: Decodable { let total_achievements: Int?; let achievements: [Ach]? }
            struct Ach: Decodable {
                let name: String?; let desc: String?; let icon: String?; let icon_gray: String?
                let player_percent_unlocked: String?
            }
            struct Resp: Decodable { let games: [Game]? }
            let response: Resp?
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data),
              let game = p.response?.games?.first else { return nil }
        let unlocked = (game.achievements ?? []).map {
            TopAch(name: $0.name ?? "", desc: $0.desc ?? "", icon: $0.icon ?? "",
                   iconGray: $0.icon_gray ?? "", percent: Double($0.player_percent_unlocked ?? "0") ?? 0)
        }
        return TopResult(unlocked: unlocked, total: game.total_achievements ?? unlocked.count)
    }

    /// Hash del icono (nombre de fichero sin extensión) para casar schema ↔ top achievements.
    static func iconHash(_ fileOrURL: String) -> String? {
        let last = (fileOrURL as NSString).lastPathComponent
        let name = (last as NSString).deletingPathExtension
        return name.isEmpty ? nil : name
    }
    /// URL del icono de un logro (los de `GetTopAchievementsForGames` vienen como nombre de fichero).
    static func iconURL(appId: String, file: String) -> URL? {
        guard !file.isEmpty else { return nil }
        return URL(string: "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/\(appId)/\(file)")
    }

    private func globalPercentages(appId: String) async -> [String: Double] {
        let urlStr = "\(base)/GetGlobalAchievementPercentagesForApp/v2/?gameid=\(appId)&format=json"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return [:] }
        struct Item: Decodable {
            let name: String
            let percent: Double
            enum K: String, CodingKey { case name, percent }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: K.self)
                name = try c.decode(String.self, forKey: .name)
                if let dbl = try? c.decode(Double.self, forKey: .percent) { percent = dbl }
                else { percent = Double((try? c.decode(String.self, forKey: .percent)) ?? "0") ?? 0 }
            }
        }
        struct Payload: Decodable {
            struct Wrap: Decodable { let achievements: [Item]? }
            let achievementpercentages: Wrap?
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: (p.achievementpercentages?.achievements ?? []).map { ($0.name, $0.percent) })
    }

    private struct SchemaAch { let displayName: String; let description: String; let icon: URL?; let iconGray: URL? }

    private func schemaIcons(appId: String, key: String, language: String) async -> [String: SchemaAch] {
        let urlStr = "\(base)/GetSchemaForGame/v2/?key=\(key)&appid=\(appId)&l=\(language)&format=json"
        guard let url = URL(string: urlStr),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [:] }
        struct Payload: Decodable {
            struct Game: Decodable { let availableGameStats: Stats? }
            struct Stats: Decodable { let achievements: [Ach]? }
            struct Ach: Decodable { let name: String; let displayName: String?; let description: String?; let icon: String?; let icongray: String? }
            let game: Game?
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { return [:] }
        var map: [String: SchemaAch] = [:]
        for a in p.game?.availableGameStats?.achievements ?? [] {
            map[a.name] = SchemaAch(displayName: a.displayName ?? a.name,
                                    description: a.description ?? "",
                                    icon: a.icon.flatMap(URL.init(string:)),
                                    iconGray: a.icongray.flatMap(URL.init(string:)))
        }
        return map
    }
}
