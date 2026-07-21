import Foundation

/// Preferencias del cliente Steam que Vessel puede preparar sin tomar decisiones por el usuario.
///
/// Steam guarda el aviso informativo «se recomienda un mando» como una preferencia por juego dentro
/// de `WebStorage`. Marcar únicamente ese aviso evita que un cliente DRM sin interfaz se bloquee en
/// `ShowInterstitials`; las licencias y los requisitos obligatorios de mando o VR no se modifican.
enum SteamClientPreferences {
    struct UpdateResult: Equatable {
        let filesFound: Int
        let filesUpdated: Int
        let filesAlreadyConfigured: Int
    }

    private static let versionKey = "Deck_ConfiguratorInterstitialsVersionSeen_GamepadRecommended"
    private static let checkboxKey = "Deck_ConfiguratorInterstitialsCheckbox_GamepadRecommended"
    private static let appsKey = "Deck_ConfiguratorInterstitialApps_GamepadRecommended"

    static func isGamepadRecommendationSeen(appId: String, in data: Data) -> Bool {
        guard !appId.isEmpty, appId.allSatisfy(\.isNumber),
              let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: newline(in: text))
        guard let storage = webStorageRange(in: lines),
              value(for: versionKey, in: lines[storage]) == "1",
              value(for: checkboxKey, in: lines[storage]) != nil,
              let rawApps = value(for: appsKey, in: lines[storage]) else { return false }
        return appIDs(in: rawApps).contains(appId)
    }

    /// Devuelve el VDF actualizado o `nil` si no es un `localconfig.vdf` utilizable.
    static func markingGamepadRecommendationSeen(appId: String, in data: Data) -> Data? {
        guard !appId.isEmpty, appId.allSatisfy(\.isNumber),
              let text = String(data: data, encoding: .utf8) else { return nil }

        let separator = newline(in: text)
        var lines = text.components(separatedBy: separator)
        guard let storage = webStorageRange(in: lines) else { return nil }

        var apps = value(for: appsKey, in: lines[storage]).map(appIDs(in:)) ?? []
        if !apps.contains(appId) { apps.append(appId) }

        let values = [
            (versionKey, "1"),
            (checkboxKey, "0"),
            (appsKey, "[\(apps.joined(separator: ","))]")
        ]
        var missing: [(String, String)] = []
        for (key, value) in values {
            if let index = lines[storage].firstIndex(where: { $0.contains("\"\(key)\"") }) {
                let indentation = String(lines[index].prefix { $0 == "\t" || $0 == " " })
                lines[index] = "\(indentation)\"\(key)\"\t\t\"\(value)\""
            } else {
                missing.append((key, value))
            }
        }

        if !missing.isEmpty {
            let additions = missing.map { "\t\t\"\($0.0)\"\t\t\"\($0.1)\"" }
            lines.insert(contentsOf: additions, at: storage.upperBound)
        }
        return lines.joined(separator: separator).data(using: .utf8)
    }

    /// Actualiza atómicamente todos los perfiles locales del Steam interno. Debe invocarse con el
    /// wineserver detenido para que Steam no sobrescriba el VDF con su caché al cerrarse.
    static func markGamepadRecommendationSeen(
        appId: String,
        inSteamDirectory steamDirectory: String,
        fileManager: FileManager = .default
    ) -> UpdateResult {
        let userdata = URL(fileURLWithPath: steamDirectory, isDirectory: true)
            .appendingPathComponent("userdata", isDirectory: true)
        let accounts = (try? fileManager.contentsOfDirectory(
            at: userdata,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var found = 0
        var updated = 0
        var configured = 0
        for account in accounts where account.lastPathComponent.allSatisfy(\.isNumber) {
            let localConfig = account
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("localconfig.vdf")
            guard let data = try? Data(contentsOf: localConfig) else { continue }
            found += 1
            if isGamepadRecommendationSeen(appId: appId, in: data) {
                configured += 1
                continue
            }
            guard let replacement = markingGamepadRecommendationSeen(appId: appId, in: data),
                  replacement != data else { continue }
            do {
                try replacement.write(to: localConfig, options: .atomic)
                updated += 1
            } catch {
                continue
            }
        }
        return UpdateResult(
            filesFound: found,
            filesUpdated: updated,
            filesAlreadyConfigured: configured
        )
    }

    private static func newline(in text: String) -> String {
        text.contains("\r\n") ? "\r\n" : "\n"
    }

    private static func value<C: Collection>(for key: String, in lines: C) -> String?
    where C.Element == String {
        let needle = "\"\(key)\""
        guard let line = lines.first(where: { $0.contains(needle) }),
              let keyRange = line.range(of: needle) else { return nil }
        let remainder = line[keyRange.upperBound...]
        guard let openingQuote = remainder.firstIndex(of: "\"") else { return nil }
        let valueStart = remainder.index(after: openingQuote)
        guard let closingQuote = remainder[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(remainder[valueStart..<closingQuote])
    }

    private static func appIDs(in value: String) -> [String] {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func webStorageRange(in lines: [String]) -> Range<Int>? {
        guard let header = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "\"WebStorage\""
        }) else { return nil }

        guard let opening = lines.indices.dropFirst(header + 1).first(where: {
            lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "{"
        }) else { return nil }

        var depth = 0
        for index in opening..<lines.endIndex {
            switch lines[index].trimmingCharacters(in: .whitespacesAndNewlines) {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return (opening + 1)..<index }
            default: break
            }
        }
        return nil
    }
}
