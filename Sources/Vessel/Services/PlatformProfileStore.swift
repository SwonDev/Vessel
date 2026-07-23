import Foundation

/// Identidad pública y no sensible de una cuenta conectada a una plataforma.
/// Nunca contiene tokens, correo ni credenciales: solo nombre, avatar y URL pública.
struct PlatformAccountProfile: Codable, Equatable, Sendable {
    let storeID: String
    let userID: String
    var displayName: String
    var avatarURL: URL?
    var avatarData: Data?
    var profileURL: URL?

    var store: StoreKind? { StoreKind(rawValue: storeID) }
}

/// Los perfiles públicos cambian con poca frecuencia. Esta política evita que cada activación de
/// la ventana provoque una petición de red y dos invalidaciones del árbol SwiftUI completo.
enum PlatformProfileRefreshPolicy {
    static let minimumInterval: TimeInterval = 15 * 60

    static func shouldRefresh(
        lastRefresh: Date?,
        now: Date = Date(),
        force: Bool
    ) -> Bool {
        guard !force, let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= minimumInterval
    }
}

/// Carga el perfil de la cuenta activa con una estrategia «local primero, red después»:
/// la cápsula aparece de inmediato desde la sesión/caché y se enriquece en segundo plano.
/// Los endpoints consultados son perfiles públicos; no se envía telemetría ni se copian tokens.
@MainActor
@Observable
final class PlatformProfileStore {
    static let shared = PlatformProfileStore()

    private(set) var profiles: [StoreKind: PlatformAccountProfile] = [:]
    private(set) var loadingStores: Set<StoreKind> = []
    private var refreshingStores: Set<StoreKind> = []
    private var lastRemoteRefresh: [StoreKind: Date] = [:]

    private init() {
        for store in StoreKind.allCases where store != .local {
            if let local = localProfile(for: store) {
                profiles[store] = cachedProfile(for: store, matching: local.userID) ?? local
            }
        }
    }

    func profile(for store: StoreKind) -> PlatformAccountProfile? {
        profiles[store]
    }

    func isLoading(_ store: StoreKind) -> Bool {
        loadingStores.contains(store)
    }

    /// Refresca únicamente datos públicos. Si la sesión ya no existe, elimina también la caché.
    func refresh(_ store: StoreKind, force: Bool = false) async {
        guard store != .local else {
            profiles[store] = nil
            lastRemoteRefresh[store] = nil
            return
        }
        guard let local = localProfile(for: store) else {
            profiles[store] = nil
            lastRemoteRefresh[store] = nil
            removeCache(for: store)
            return
        }

        if profiles[store]?.userID != local.userID {
            profiles[store] = cachedProfile(for: store, matching: local.userID) ?? local
            lastRemoteRefresh[store] = nil
        } else if profiles[store] == nil {
            profiles[store] = local
        }

        let now = Date()
        guard PlatformProfileRefreshPolicy.shouldRefresh(
            lastRefresh: lastRemoteRefresh[store],
            now: now,
            force: force
        ), !refreshingStores.contains(store) else { return }

        refreshingStores.insert(store)
        if force { loadingStores.insert(store) }
        defer {
            refreshingStores.remove(store)
            if force { loadingStores.remove(store) }
        }

        let enriched: PlatformAccountProfile?
        switch store {
        case .steam:
            enriched = await fetchSteamProfile(fallback: local)
        case .gog:
            enriched = await fetchGogProfile(fallback: local)
        case .epic, .local:
            enriched = local
        }

        if let enriched {
            if profiles[store] != enriched {
                profiles[store] = enriched
            }
            saveCache(enriched, for: store)
            lastRemoteRefresh[store] = now
        }
    }

    /// Invalida una plataforma tras login/logout y vuelve a detectar su sesión local.
    func accountDidChange(_ store: StoreKind) async {
        profiles[store] = nil
        lastRemoteRefresh[store] = nil
        await refresh(store, force: true)
    }

    // MARK: - Identidad local (sin secretos)

    private func localProfile(for store: StoreKind) -> PlatformAccountProfile? {
        switch store {
        case .steam:
            let id = SteamAccountService.currentSteamID64
            guard !id.isEmpty else { return nil }
            let persona = UserDefaults.standard.string(forKey: "steam.personaName")
            let account = UserDefaults.standard.string(forKey: "steam.accountName")
            let name = Self.firstNonEmpty(persona, account) ?? "Steam"
            return PlatformAccountProfile(
                storeID: store.rawValue,
                userID: id,
                displayName: name,
                avatarURL: nil,
                avatarData: nil,
                profileURL: URL(string: "https://steamcommunity.com/profiles/\(id)")
            )

        case .epic:
            let path = "\(LegendaryManager.configDir)/user.json"
            guard let object = Self.jsonObject(at: path),
                  let id = Self.stringValue(object["account_id"]), !id.isEmpty else { return nil }
            let name = Self.stringValue(object["displayName"]) ?? "Epic Games"
            return PlatformAccountProfile(
                storeID: store.rawValue,
                userID: id,
                displayName: name,
                avatarURL: nil,
                avatarData: nil,
                profileURL: nil
            )

        case .gog:
            guard let root = Self.jsonObject(at: GogdlManager.authConfigPath),
                  let entry = root.values.compactMap({ $0 as? [String: Any] }).first,
                  let id = Self.stringValue(entry["user_id"]), !id.isEmpty else { return nil }
            return PlatformAccountProfile(
                storeID: store.rawValue,
                userID: id,
                displayName: "Cuenta de GOG",
                avatarURL: nil,
                avatarData: nil,
                profileURL: nil
            )

        case .local:
            return nil
        }
    }

    // MARK: - Perfiles públicos

    private func fetchSteamProfile(fallback: PlatformAccountProfile) async -> PlatformAccountProfile {
        guard let url = URL(string: "https://steamcommunity.com/profiles/\(fallback.userID)?xml=1") else {
            return fallback
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(SteamConstants.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let parsed = Self.parseSteamCommunityProfile(data) else {
            return fallback
        }
        var result = fallback
        if !parsed.displayName.isEmpty { result.displayName = parsed.displayName }
        result.avatarURL = parsed.avatarURL ?? fallback.avatarURL
        result.avatarData = await fetchAvatarData(from: result.avatarURL) ?? fallback.avatarData
        return result
    }

    private func fetchGogProfile(fallback: PlatformAccountProfile) async -> PlatformAccountProfile {
        guard let url = URL(string: "https://users.gog.com/users/\(fallback.userID)") else {
            return fallback
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Vessel", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(GogPublicProfile.self, from: data),
              !payload.username.isEmpty else {
            return fallback
        }
        var result = fallback
        result.displayName = payload.username
        result.avatarURL = Self.normalizedURL(payload.avatar.medium2x ?? payload.avatar.medium ?? payload.avatar.large)
        result.avatarData = await fetchAvatarData(from: result.avatarURL) ?? fallback.avatarData
        let escaped = payload.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? payload.username
        result.profileURL = URL(string: "https://www.gog.com/u/\(escaped)")
        return result
    }

    /// Descarga defensiva: solo HTTPS, respuesta de imagen y tope de 2 MB. El toolbar nunca recibe
    /// una vista remota, únicamente bytes ya validados y decodificables.
    private func fetchAvatarData(from url: URL?) async -> Data? {
        guard let url, url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Vessel", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              http.mimeType?.lowercased().hasPrefix("image/") == true,
              !data.isEmpty,
              data.count <= 2_000_000 else { return nil }
        return data
    }

    private struct GogPublicProfile: Decodable {
        struct Avatar: Decodable {
            let medium: String?
            let medium2x: String?
            let large: String?

            enum CodingKeys: String, CodingKey {
                case medium, large
                case medium2x = "medium_2x"
            }
        }

        let username: String
        let avatar: Avatar
    }

    // MARK: - Parsing de Steam Community XML

    nonisolated static func parseSteamCommunityProfile(_ data: Data) -> (displayName: String, avatarURL: URL?)? {
        let delegate = SteamCommunityProfileXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let name = delegate.value(for: "steamID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        return (name, normalizedURL(delegate.value(for: "avatarFull")))
    }

    private final class SteamCommunityProfileXMLDelegate: NSObject, XMLParserDelegate {
        private var currentElement: String?
        private var buffer = ""
        private var values: [String: String] = [:]
        private let accepted = Set(["steamID", "avatarFull"])

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            guard accepted.contains(elementName) else { return }
            currentElement = elementName
            buffer = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard currentElement != nil else { return }
            buffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            guard currentElement == elementName else { return }
            values[elementName] = buffer
            currentElement = nil
            buffer = ""
        }

        func value(for key: String) -> String? { values[key] }
    }

    // MARK: - Caché pública

    private func cachedProfile(for store: StoreKind, matching userID: String) -> PlatformAccountProfile? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(store)),
              let profile = try? JSONDecoder().decode(PlatformAccountProfile.self, from: data),
              profile.userID == userID else { return nil }
        return profile
    }

    private func saveCache(_ profile: PlatformAccountProfile, for store: StoreKind) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(store))
    }

    private func removeCache(for store: StoreKind) {
        UserDefaults.standard.removeObject(forKey: cacheKey(store))
    }

    private func cacheKey(_ store: StoreKind) -> String { "profile.public.\(store.rawValue)" }

    private nonisolated static func jsonObject(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private nonisolated static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private nonisolated static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    private nonisolated static func normalizedURL(_ value: String?) -> URL? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("//") { value = "https:" + value }
        return URL(string: value)
    }
}
