import Foundation
import AppKit

@MainActor
@Observable
final class SteamLibraryImporter {
    struct ImportedGame: Identifiable, Hashable {
        let id: String
        let appId: String
        let name: String
        let installPath: String
        let executablePath: String
        let coverURL: String?
    }

    struct SteamLibrary {
        let path: String
        let games: [ImportedGame]
    }

    func discoverSteamLibraries() -> [SteamLibrary] {
        var libraries: [SteamLibrary] = []
        let home = NSHomeDirectory()

        let possiblePaths = [
            "\(home)/Library/Application Support/Steam",
            "\(home)/.steam/steam",
            "\(home)/.local/share/Steam",
            "/Applications/Steam.app/Contents/MacOS"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                let games = scanSteamApps(at: path)
                if !games.isEmpty {
                    libraries.append(SteamLibrary(path: path, games: games))
                }
            }
        }

        if let configPath = "\(home)/Library/Application Support/Steam/steamapps/libraryfolders.vdf".asFileURL,
           let data = try? String(contentsOf: configPath, encoding: .utf8) {
            let extraPaths = parseLibraryFolders(data)
            for extra in extraPaths {
                if !libraries.contains(where: { $0.path == extra }) {
                    let games = scanSteamApps(at: extra)
                    libraries.append(SteamLibrary(path: extra, games: games))
                }
            }
        }

        return libraries
    }

    private func scanSteamApps(at steamPath: String) -> [ImportedGame] {
        var games: [ImportedGame] = []
        let steamapps = "\(steamPath)/steamapps"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: steamapps) else {
            return games
        }

        for item in contents where item.hasPrefix("appmanifest_") && item.hasSuffix(".acf") {
            let manifestPath = "\(steamapps)/\(item)"
            if let manifest = try? String(contentsOfFile: manifestPath, encoding: .utf8),
               let game = parseManifest(manifest, steamapps: steamapps) {
                games.append(game)
            }
        }
        return games
    }

    private func parseManifest(_ content: String, steamapps: String) -> ImportedGame? {
        var appId = ""
        var name = ""
        var installdir = ""

        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("\"appid\"") {
                appId = extractValue(from: trimmed) ?? ""
            } else if trimmed.contains("\"name\"") {
                name = extractValue(from: trimmed) ?? ""
            } else if trimmed.contains("\"installdir\"") {
                installdir = extractValue(from: trimmed) ?? ""
            }
        }

        guard !appId.isEmpty, !installdir.isEmpty else { return nil }
        let gameDir = "\(steamapps)/common/\(installdir)"

        if let exe = findMainExecutable(in: gameDir) {
            return ImportedGame(
                id: appId,
                appId: appId,
                name: name.isEmpty ? installdir : name,
                installPath: gameDir,
                executablePath: exe,
                coverURL: "https://cdn.akamai.steamstatic.com/steam/apps/\(appId)/library_600x900_2x.jpg"
            )
        }
        return nil
    }

    private func findMainExecutable(in dir: String) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dir) else { return nil }

        let dirName = (dir as NSString).lastPathComponent.lowercased()

        var candidates: [String] = []
        for case let path as String in enumerator {
            if path.lowercased().hasSuffix(".exe") {
                let lower = path.lowercased()
                if lower.contains("launcher") || lower.contains(dirName) {
                    return "\(dir)/\(path)"
                }
                candidates.append("\(dir)/\(path)")
            }
        }

        if let first = candidates.sorted(by: { $0.count < $1.count }).first {
            return first
        }
        return nil
    }

    private func extractValue(from line: String) -> String? {
        let pattern = #""[^"]*"\s+"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        if let match = regex.firstMatch(in: line, range: range),
           let valueRange = Range(match.range(at: 1), in: line) {
            return String(line[valueRange])
        }
        return nil
    }

    private func parseLibraryFolders(_ content: String) -> [String] {
        var paths: [String] = []
        let pattern = #""path"\s+"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return paths }
        let range = NSRange(content.startIndex..., in: content)
        for match in regex.matches(in: content, range: range) {
            if let r = Range(match.range(at: 1), in: content) {
                paths.append(String(content[r]))
            }
        }
        return paths
    }
}

private extension String {
    var asFileURL: URL? {
        let expanded = (self as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return URL(fileURLWithPath: expanded)
        }
        return nil
    }
}
