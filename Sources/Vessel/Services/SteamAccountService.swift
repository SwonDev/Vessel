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

    struct OwnedGame: Identifiable, Hashable {
        var id: String { appId }
        let appId: String
        let name: String
    }

    /// Detecta la cuenta logueada en el Steam del bottle leyendo `loginusers.vdf`.
    /// Prefiere la marcada como `MostRecent`.
    func detectAccount(bottle: Bottle) -> Account? {
        let path = "\(bottle.prefixPath)/drive_c/Program Files (x86)/Steam/config/loginusers.vdf"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Self.parseLoginUsers(content)
    }

    /// Carga la biblioteca COMPLETA (owned) del usuario desde el endpoint público de
    /// Steam Community. Requiere que el perfil/biblioteca sea público; si es privado
    /// devuelve vacío (y la UI cae a mostrar solo los instalados).
    func fetchOwnedGames(steamID64: String) async -> [OwnedGame] {
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
