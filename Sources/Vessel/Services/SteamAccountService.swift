import Foundation

/// Gestiona la **cuenta de Steam** logueada en el bottle y carga la **biblioteca
/// completa** del usuario (juegos owned, estén o no instalados). Así Vessel puede
/// mostrar toda tu biblioteca y dejar instalar/jugar desde su propia vista, sin
/// tener que abrir Steam — coherente con la filosofía de [[vessel-filosofia-ux]].
@MainActor
@Observable
final class SteamAccountService {
    struct Account: Hashable {
        let steamID64: String
        let personaName: String
        let accountName: String
    }

    struct OwnedGame: Identifiable, Hashable, Codable {
        var id: String { appId }
        let appId: String
        let name: String
    }

    /// Detecta la cuenta logueada en el Steam del bottle. Intenta varias fuentes,
    /// porque según el estado de Steam puede faltar `loginusers.vdf`:
    ///  1. `config/loginusers.vdf` (lo normal; trae también el nombre de usuario).
    ///  2. cualquier SteamID64 dentro de `config/config.vdf`.
    ///  3. la carpeta `userdata/<accountID>` (AccountID → SteamID64).
    func detectAccount(bottle: Bottle) -> Account? {
        let steamRoot = "\(bottle.prefixPath)/drive_c/Program Files (x86)/Steam"

        if let content = try? String(contentsOfFile: "\(steamRoot)/config/loginusers.vdf", encoding: .utf8),
           let account = Self.parseLoginUsers(content) {
            return remember(account)
        }

        if let content = try? String(contentsOfFile: "\(steamRoot)/config/config.vdf", encoding: .utf8),
           let id = Self.firstSteamID64(in: content) {
            return remember(Account(steamID64: id, personaName: "Steam", accountName: ""))
        }

        let userdata = "\(steamRoot)/userdata"
        if let dirs = try? FileManager.default.contentsOfDirectory(atPath: userdata) {
            for dir in dirs.sorted() {
                if let accountID = UInt64(dir), accountID > 0 {
                    let id64 = accountID + 76561197960265728
                    return remember(Account(steamID64: String(id64), personaName: "Steam", accountName: ""))
                }
            }
        }
        return nil
    }

    /// SteamID64 del usuario logueado (persistido al detectar la cuenta). Lo usan otras vistas
    /// (p. ej. la ficha, para los logros reales) sin necesidad del bottle.
    static var currentSteamID64: String { UserDefaults.standard.string(forKey: "steam.steamID64") ?? "" }

    @discardableResult
    private func remember(_ account: Account) -> Account {
        UserDefaults.standard.set(account.steamID64, forKey: "steam.steamID64")
        return account
    }

    nonisolated static func firstSteamID64(in content: String) -> String? {
        let pattern = #"7656119[0-9]{10}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        if let match = regex.firstMatch(in: content, range: range),
           let r = Range(match.range, in: content) {
            return String(content[r])
        }
        return nil
    }

    /// Clave Web API de Steam del usuario (https://steamcommunity.com/dev/apikey).
    /// Permite cargar la biblioteca completa AUNQUE el perfil sea privado.
    static var webAPIKey: String {
        get { UserDefaults.standard.string(forKey: "steam.webApiKey") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "steam.webApiKey") }
    }

    /// Carga la biblioteca COMPLETA (owned) del usuario:
    ///  1. Con la **Web API key** (GetOwnedGames) — funciona también con perfil privado.
    ///  2. Si no hay key, cae al endpoint público de Steam Community (requiere perfil
    ///     de juegos público).
    func fetchOwnedGames(steamID64: String) async -> [OwnedGame] {
        // 1) Con el access_token del login oficial (refrescado automáticamente) — sin pegar clave.
        let token = await SteamAuthService.currentAccessToken()
        if !token.isEmpty, let viaToken = await fetchViaWebAPI(steamID64: steamID64, auth: "access_token=\(token)"), !viaToken.isEmpty {
            return viaToken
        }
        // 2) Con la clave Web API que el usuario haya introducido.
        let key = Self.webAPIKey
        if !key.isEmpty, let viaAPI = await fetchViaWebAPI(steamID64: steamID64, auth: "key=\(key)"), !viaAPI.isEmpty {
            return viaAPI
        }
        // 3) Endpoint público (requiere perfil de juegos público).
        return await fetchViaPublicXML(steamID64: steamID64)
    }

    private func fetchViaWebAPI(steamID64: String, auth: String) async -> [OwnedGame]? {
        let urlStr = "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?\(auth)&steamid=\(steamID64)&include_appinfo=1&include_played_free_games=1&format=json"
        guard let url = URL(string: urlStr) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        struct Payload: Decodable {
            struct Inner: Decodable { let games: [Game]? }
            struct Game: Decodable { let appid: Int; let name: String? }
            let response: Inner
        }
        guard let decoded = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return (decoded.response.games ?? []).map {
            OwnedGame(appId: String($0.appid), name: $0.name ?? "App \($0.appid)")
        }
    }

    private func fetchViaPublicXML(steamID64: String) async -> [OwnedGame] {
        guard let url = URL(string: "https://steamcommunity.com/profiles/\(steamID64)/games?tab=all&xml=1") else {
            return []
        }
        var request = URLRequest(url: url)
        request.setValue(SteamConstants.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let xml = String(data: data, encoding: .utf8) else {
            return []
        }
        return Self.parseGamesXML(xml)
    }

    // MARK: - Parsing

    nonisolated static func parseLoginUsers(_ content: String) -> Account? {
        // Bloques: "76561198XXXXXXXXX" { "AccountName" "x" "PersonaName" "y" "MostRecent" "1" ... }
        let pattern = #""(7656119[0-9]{10})"\s*\{([^}]*)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        var candidates: [(account: Account, mostRecent: Bool, timestamp: Int)] = []
        for match in regex.matches(in: content, range: range) {
            guard let idRange = Range(match.range(at: 1), in: content),
                  let bodyRange = Range(match.range(at: 2), in: content) else { continue }
            let id = String(content[idRange])
            let body = String(content[bodyRange])
            let persona = value(of: "PersonaName", in: body) ?? value(of: "AccountName", in: body) ?? id
            let accountName = value(of: "AccountName", in: body) ?? ""
            let mostRecent = (value(of: "MostRecent", in: body) ?? "0") == "1"
            let timestamp = Int(value(of: "Timestamp", in: body) ?? "0") ?? 0
            candidates.append((Account(steamID64: id, personaName: persona, accountName: accountName), mostRecent, timestamp))
        }
        guard !candidates.isEmpty else { return nil }
        // Preferir MostRecent; si no, el de Timestamp más alto.
        if let recent = candidates.first(where: { $0.mostRecent }) { return recent.account }
        return candidates.max(by: { $0.timestamp < $1.timestamp })?.account
    }

    nonisolated static func parseGamesXML(_ xml: String) -> [OwnedGame] {
        var games: [OwnedGame] = []
        // <game><appID>123</appID>...<name><![CDATA[Title]]></name>...</game>
        let pattern = #"<game>.*?<appID>(\d+)</appID>.*?<name>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</name>.*?</game>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return games }
        let range = NSRange(xml.startIndex..., in: xml)
        for match in regex.matches(in: xml, range: range) {
            guard let appRange = Range(match.range(at: 1), in: xml),
                  let nameRange = Range(match.range(at: 2), in: xml) else { continue }
            let appId = String(xml[appRange])
            let name = String(xml[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !appId.isEmpty, !name.isEmpty {
                games.append(OwnedGame(appId: appId, name: name))
            }
        }
        return games
    }

    nonisolated private static func value(of key: String, in body: String) -> String? {
        let pattern = "\"\(key)\"\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        if let match = regex.firstMatch(in: body, range: range),
           let r = Range(match.range(at: 1), in: body) {
            return String(body[r])
        }
        return nil
    }
}
