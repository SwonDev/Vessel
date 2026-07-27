import Foundation

/// Detecta licencias pendientes antes de arrancar el cliente DRM silencioso.
///
/// Steam declara los EULAs y su versión en `appcache/appinfo.vdf`, mientras que cada cuenta local
/// conserva la aceptación en `userdata/<cuenta>/config/localconfig.vdf`. Vessel sólo compara ambos
/// estados: nunca acepta ni modifica una licencia en nombre del usuario.
enum SteamEULAPreflight {
    static func pendingEULAs(
        appID: String,
        appInfoPath: String,
        steamDirectory: String,
        fileManager: FileManager = .default
    ) -> [SteamAppInfoLaunchResolver.EULA]? {
        guard !appID.isEmpty, appID.allSatisfy(\.isNumber),
              let eulas = SteamAppInfoLaunchResolver.eulas(
                  appID: appID,
                  appInfoPath: appInfoPath
              ) else { return nil }
        guard !eulas.isEmpty else { return [] }

        let userdata = URL(fileURLWithPath: steamDirectory, isDirectory: true)
            .appendingPathComponent("userdata", isDirectory: true)
        let accounts = (try? fileManager.contentsOfDirectory(
            at: userdata,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let localConfigs = accounts
            .filter { !$0.lastPathComponent.isEmpty && $0.lastPathComponent.allSatisfy(\.isNumber) }
            .compactMap { account in
                try? Data(contentsOf: account
                    .appendingPathComponent("config", isDirectory: true)
                    .appendingPathComponent("localconfig.vdf"))
            }

        return eulas.filter { eula in
            !localConfigs.contains { data in
                guard let accepted = acceptedVersion(
                    appID: appID,
                    eulaID: eula.id,
                    in: data
                ) else { return false }
                return satisfies(requiredVersion: eula.version, acceptedVersion: accepted)
            }
        }
    }

    static func acceptedVersion(appID: String, eulaID: String, in data: Data) -> String? {
        guard !appID.isEmpty, appID.allSatisfy(\.isNumber), !eulaID.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return nil }
        var parser = VDFParser(text: text)
        guard let root = parser.parse() else { return nil }

        let store = object(named: "UserLocalConfigStore", in: root) ?? root
        guard let software = object(named: "Software", in: store),
              let valve = object(named: "Valve", in: software),
              let steam = object(named: "Steam", in: valve),
              let apps = object(named: "apps", in: steam),
              let app = object(named: appID, in: apps),
              case .string(let version)? = value(named: eulaID, in: app) else { return nil }
        let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func satisfies(requiredVersion: String, acceptedVersion: String) -> Bool {
        let required = requiredVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let accepted = acceptedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requiredNumber = UInt64(required), let acceptedNumber = UInt64(accepted) {
            return acceptedNumber >= requiredNumber
        }
        return accepted == required
    }

    private indirect enum VDFValue {
        case object([String: VDFValue])
        case string(String)
    }

    private static func object(
        named name: String,
        in object: [String: VDFValue]
    ) -> [String: VDFValue]? {
        guard case .object(let child)? = value(named: name, in: object) else { return nil }
        return child
    }

    private static func value(named name: String, in object: [String: VDFValue]) -> VDFValue? {
        if let exact = object[name] { return exact }
        return object.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    private struct VDFParser {
        private enum Token {
            case text(String)
            case open
            case close
        }

        private let text: String
        private var index: String.Index

        init(text: String) {
            self.text = text
            self.index = text.startIndex
        }

        mutating func parse() -> [String: VDFValue]? {
            parseObject(expectClosingBrace: false)
        }

        private mutating func parseObject(expectClosingBrace: Bool) -> [String: VDFValue]? {
            var result: [String: VDFValue] = [:]
            while let token = nextToken() {
                switch token {
                case .close:
                    return expectClosingBrace ? result : nil
                case .open:
                    return nil
                case .text(let key):
                    guard let valueToken = nextToken() else { return nil }
                    switch valueToken {
                    case .text(let value):
                        result[key] = .string(value)
                    case .open:
                        guard let child = parseObject(expectClosingBrace: true) else { return nil }
                        result[key] = .object(child)
                    case .close:
                        return nil
                    }
                }
            }
            return expectClosingBrace ? nil : result
        }

        private mutating func nextToken() -> Token? {
            skipTrivia()
            guard index < text.endIndex else { return nil }
            switch text[index] {
            case "{":
                index = text.index(after: index)
                return .open
            case "}":
                index = text.index(after: index)
                return .close
            case "\"":
                return .text(readQuotedString())
            default:
                let start = index
                while index < text.endIndex,
                      !text[index].isWhitespace,
                      text[index] != "{",
                      text[index] != "}" {
                    index = text.index(after: index)
                }
                guard start < index else { return nil }
                return .text(String(text[start..<index]))
            }
        }

        private mutating func skipTrivia() {
            while index < text.endIndex {
                if text[index].isWhitespace {
                    index = text.index(after: index)
                    continue
                }
                let next = text.index(after: index)
                if text[index] == "/", next < text.endIndex, text[next] == "/" {
                    index = text.index(after: next)
                    while index < text.endIndex, text[index] != "\n", text[index] != "\r" {
                        index = text.index(after: index)
                    }
                    continue
                }
                return
            }
        }

        private mutating func readQuotedString() -> String {
            index = text.index(after: index)
            var result = ""
            while index < text.endIndex {
                let character = text[index]
                index = text.index(after: index)
                if character == "\"" { return result }
                if character == "\\", index < text.endIndex {
                    let escaped = text[index]
                    index = text.index(after: index)
                    switch escaped {
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    default: result.append(escaped)
                    }
                } else {
                    result.append(character)
                }
            }
            return result
        }
    }
}
