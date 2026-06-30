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

    /// Escanea los juegos instalados DENTRO del bottle (el Steam del prefijo),
    /// que es donde Vessel los instala — no el Steam nativo de macOS. Es la fuente
    /// correcta para que los juegos aparezcan en la lista de Vessel.
    func scanBottleGames(bottle: Bottle) -> [ImportedGame] {
        let bottleSteam = "\(bottle.prefixPath)/drive_c/Program Files (x86)/Steam"
        guard FileManager.default.fileExists(atPath: "\(bottleSteam)/steamapps") else { return [] }
        // Filtramos los AppID de herramientas internas de Steam (Steamworks, redist…).
        let internalAppIds: Set<String> = ["228980", "1070560", "1391110", "1493710", "250820"]
        return scanSteamApps(at: bottleSteam).filter { !internalAppIds.contains($0.appId) }
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

        // (ruta relativa en minúsculas, ruta completa) de cada .exe.
        var exes: [(rel: String, full: String)] = []
        for case let path as String in enumerator where path.lowercased().hasSuffix(".exe") {
            exes.append((path.lowercased(), "\(dir)/\(path)"))
        }
        guard !exes.isEmpty else { return nil }

        // Los launchers de terceros (EA App, Ubisoft Connect, Rockstar…) NO son el juego: si
        // los eligiéramos, Vessel lanzaría el launcher (y enrutaría el motor por su bitness/API,
        // no la del juego). Preferimos el ejecutable real y dejamos el launcher como último recurso.
        func isLauncher(_ rel: String) -> Bool { rel.contains("launcher") }
        let real = exes.filter { !isLauncher($0.rel) }

        // 1) exe cuyo nombre coincide con la carpeta del juego y NO es launcher → el juego real.
        if let game = real.first(where: { $0.rel.contains(dirName) }) { return game.full }
        // 2) cualquier exe que no sea launcher (ruta más corta → normalmente en la raíz del juego).
        if let shortest = real.min(by: { $0.rel.count < $1.rel.count }) { return shortest.full }
        // 3) solo quedan launchers (juegos que SÍ arrancan por su launcher): el de ruta más corta.
        return exes.min(by: { $0.rel.count < $1.rel.count })?.full
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
