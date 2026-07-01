import Foundation

/// Sesión **web** de Steam derivada del `refresh_token` de la sesión (login oficial). Finaliza el
/// login como hace el navegador (`login.steampowered.com/jwt/finalizelogin` → `settoken` en la
/// tienda) para obtener la cookie `steamLoginSecure` de `store.steampowered.com`, y con ella lee
/// **`rgOwnedApps`** (TODO lo que el usuario posee: juegos **y DLC**).
///
/// Así Vessel sabe qué DLC tienes comprados y puede atenuar los que no — **sin SteamCMD, sin pedirte
/// nada, reutilizando la sesión que ya hiciste**. Verificado en vivo. Ver [[vessel-logros-steam-reales]].
actor SteamWebSession {
    static let shared = SteamWebSession()

    private var ownedCache: Set<Int>?
    private var lastFetch: Date?

    /// AppIDs que el usuario POSEE (juegos + DLC). Cacheado 10 min. Vacío si no hay sesión válida.
    func ownedAppIDs() async -> Set<Int> {
        if let c = ownedCache, let t = lastFetch, Date().timeIntervalSince(t) < 600 { return c }
        let owned = await fetchOwnedApps()
        if !owned.isEmpty { ownedCache = owned; lastFetch = Date() }
        return owned
    }

    // MARK: - Flujo

    private func fetchOwnedApps() async -> Set<Int> {
        let refresh = UserDefaults.standard.string(forKey: "steam.refreshToken") ?? ""
        let steamID = SteamAccountService.currentSteamID64
        guard !refresh.isEmpty, !steamID.isEmpty else { return [] }

        // Almacén de cookies AISLADO, con el sessionid puesto ANTES de crear la sesión (si no, la
        // sesión ya copió la config y el cookie no cuenta) para que fluyan entre los 3 pasos.
        let sessionID = Self.randomHex(24)
        let storage = HTTPCookieStorage()
        for domain in ["login.steampowered.com", "store.steampowered.com", "steamcommunity.com"] {
            if let c = HTTPCookie(properties: [.domain: domain, .path: "/", .name: "sessionid", .value: sessionID]) {
                storage.setCookie(c)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = storage
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: config)

        guard let store = await finalizeLogin(session: session, refresh: refresh, sessionID: sessionID) else {
            log("Ownership: finalizeLogin falló"); return []
        }
        // La cookie steamLoginSecure la extraemos MANUALMENTE del Set-Cookie (URLSession no la guarda
        // de forma fiable en un storage efímero) y la mandamos como header (como hace el navegador/curl).
        guard let loginSecure = await setToken(session: session, store: store, steamID: steamID) else {
            log("Ownership: settoken no devolvió steamLoginSecure"); return []
        }
        let owned = await ownedFromUserdata(session: session, cookie: "sessionid=\(sessionID); steamLoginSecure=\(loginSecure)")
        log("Ownership: \(owned.count) apps poseídas")
        return owned
    }

    private struct StoreTransfer { let url: String; let nonce: String; let auth: String }

    /// Paso 1: finalizelogin → devuelve el `settoken` de la TIENDA (url + nonce + auth).
    private func finalizeLogin(session: URLSession, refresh: String, sessionID: String) async -> StoreTransfer? {
        guard let url = URL(string: "https://login.steampowered.com/jwt/finalizelogin") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("https://steamcommunity.com", forHTTPHeaderField: "Origin")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form([
            "nonce": refresh, "sessionid": sessionID,
            "redir": "https://steamcommunity.com/login/home/?goto="
        ])
        guard let (data, _) = try? await session.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["transfer_info"] as? [[String: Any]] else { return nil }
        for t in list {
            guard let u = t["url"] as? String, u.contains("store.steampowered.com"),
                  let p = t["params"] as? [String: Any],
                  let nonce = p["nonce"] as? String, let auth = p["auth"] as? String else { continue }
            return StoreTransfer(url: u, nonce: nonce, auth: auth)
        }
        return nil
    }

    /// Paso 2: settoken en la tienda → devuelve el valor de la cookie `steamLoginSecure` del
    /// Set-Cookie de la respuesta (autenticación de la sesión web de tienda).
    private func setToken(session: URLSession, store: StoreTransfer, steamID: String) async -> String? {
        guard let url = URL(string: store.url) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(["nonce": store.nonce, "auth": store.auth, "steamID": steamID])
        guard let (_, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        let setCookie = (http.value(forHTTPHeaderField: "Set-Cookie")) ?? ""
        // steamLoginSecure=<steamid>||<jwt> ; … (el valor no lleva ';' ni ',')
        guard let r = setCookie.range(of: "steamLoginSecure=") else { return nil }
        let value = setCookie[r.upperBound...].prefix { $0 != ";" && $0 != "," }
        return value.isEmpty ? nil : String(value)
    }

    /// Paso 3: `dynamicstore/userdata` → `rgOwnedApps`, mandando la cookie de sesión a mano.
    private func ownedFromUserdata(session: URLSession, cookie: String) async -> Set<Int> {
        guard let url = URL(string: "https://store.steampowered.com/dynamicstore/userdata/") else { return [] }
        var req = URLRequest(url: url)
        req.setValue("https://store.steampowered.com/", forHTTPHeaderField: "Referer")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        guard let (data, _) = try? await session.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let owned = obj["rgOwnedApps"] as? [Int] else { return [] }
        return Set(owned)
    }

    private nonisolated func log(_ msg: String) {
        Task { @MainActor in LogStore.shared.log(msg, level: .debug) }
    }

    // MARK: - Utilidades

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
