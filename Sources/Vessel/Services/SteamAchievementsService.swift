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
        let token = UserDefaults.standard.string(forKey: "steam.accessToken") ?? ""
        let key = await SteamAccountService.webAPIKey
        guard !steamID64.isEmpty else { return nil }

        async let schemaTask = key.isEmpty ? [:] : schemaIcons(appId: appId, key: key, language: language)
        async let globalsTask = globalPercentages(appId: appId)

        // Estado del jugador: access_token y, si no, la key. Puede venir vacío (perfil privado).
        var player: [PlayerAch] = []
        if !token.isEmpty {
            player = await playerAchievements(appId: appId, steamID64: steamID64, auth: "access_token=\(token)", language: language)
        }
        if player.isEmpty, !key.isEmpty {
            player = await playerAchievements(appId: appId, steamID64: steamID64, auth: "key=\(key)", language: language)
        }
        let schema = await schemaTask
        let globals = await globalsTask
        let playerByName = Dictionary(player.map { ($0.apiname, $0) }, uniquingKeysWith: { a, _ in a })
        let stateKnown = !player.isEmpty

        var list: [Achievement]
        if !schema.isEmpty {
            // Base = schema COMPLETO (iconos+nombres), con estado si lo conocemos.
            list = schema.map { (apiname, s) in
                let p = playerByName[apiname]
                return Achievement(
                    apiName: apiname,
                    displayName: s.displayName,
                    description: s.description,
                    unlocked: p?.achieved == 1,
                    unlockTime: (p?.unlocktime ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(p!.unlocktime!)) : nil,
                    iconUnlocked: s.icon,
                    iconLocked: s.iconGray,
                    globalPercent: globals[apiname]
                )
            }
        } else if !player.isEmpty {
            // Sin key: solo el estado del jugador (nombres del propio endpoint, sin iconos de juego).
            list = player.map { p in
                Achievement(
                    apiName: p.apiname,
                    displayName: p.name?.isEmpty == false ? p.name! : p.apiname,
                    description: p.description ?? "",
                    unlocked: p.achieved == 1,
                    unlockTime: (p.unlocktime ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(p.unlocktime!)) : nil,
                    iconUnlocked: nil, iconLocked: nil,
                    globalPercent: globals[p.apiname]
                )
            }
        } else {
            return nil   // nada que mostrar → la ficha usa su vista decorativa
        }

        // Orden: si conocemos el estado, desbloqueados primero (recientes arriba); si no, por rareza
        // (los más raros primero, que lucen más). Luego por rareza descendente / nombre.
        list.sort { a, b in
            if stateKnown, a.unlocked != b.unlocked { return a.unlocked }
            if stateKnown, a.unlocked, b.unlocked { return (a.unlockTime ?? .distantPast) > (b.unlockTime ?? .distantPast) }
            let pa = a.globalPercent ?? 0, pb = b.globalPercent ?? 0
            if pa != pb { return pa < pb }   // más raro (menor %) primero
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
        let unlocked = list.filter(\.unlocked).count
        return Progress(achievements: list, unlocked: unlocked, total: list.count, stateKnown: stateKnown)
    }

    // MARK: - Endpoints

    private struct PlayerAch: Decodable {
        let apiname: String
        let achieved: Int
        let unlocktime: Int?
        let name: String?
        let description: String?
    }

    private func playerAchievements(appId: String, steamID64: String, auth: String, language: String) async -> [PlayerAch] {
        let urlStr = "\(base)/GetPlayerAchievements/v1/?\(auth)&steamid=\(steamID64)&appid=\(appId)&l=\(language)&format=json"
        guard let url = URL(string: urlStr),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        struct Payload: Decodable {
            struct Stats: Decodable { let success: Bool?; let achievements: [PlayerAch]? }
            let playerstats: Stats?
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data),
              p.playerstats?.success == true else { return [] }
        return p.playerstats?.achievements ?? []
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
