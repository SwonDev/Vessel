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
        let bottleSteam = bottle.steamDirectory
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
        Self.mainGameExecutable(in: dir)
    }

    /// Normaliza un nombre dejando solo alfanuméricos en minúscula. Permite comparar el nombre
    /// del exe con el de la carpeta aunque difieran en espacios/símbolos
    /// (p. ej. carpeta "Ancient Kingdoms" ↔ exe "ancientkingdoms.exe").
    static func normalizedName(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Resuelve el ejecutable PRINCIPAL (el **cliente**) de un juego instalado en `dir`.
    /// Única fuente de verdad (la usan el importador y la instalación directa de Steam).
    ///
    /// Usa una HEURÍSTICA POR PUNTUACIÓN en vez de "la ruta más corta" porque esa regla fallaba
    /// con MMOs que traen un `server/server.exe` headless (Unity con `GfxDevice: Null`): al ser
    /// su ruta más corta que la del cliente, se lanzaba el SERVIDOR → corría eternamente SIN
    /// ventana ("Ejecutándose" para siempre). Reglas:
    ///  - Descarta redistribuibles, crash handlers e instaladores (nunca son el juego).
    ///  - Penaliza MUCHO los servidores dedicados (carpeta/nombre `server`/`dedicated`).
    ///  - Premia el marcador de cliente Unity: existe la carpeta hermana `<exe>_Data`.
    ///  - Premia que el nombre del exe ≈ nombre de la carpeta (normalizado, ignora espacios).
    ///  - Prefiere la raíz del juego frente a subcarpetas; penaliza launchers de terceros.
    static func mainGameExecutable(in dir: String) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dir) else { return nil }
        let folderKey = normalizedName((dir as NSString).lastPathComponent)

        var exes: [(rel: String, full: String)] = []
        for case let path as String in enumerator where path.lowercased().hasSuffix(".exe") {
            let lower = path.lowercased()
            if lower.contains("redist") || lower.contains("vcredist") || lower.contains("crashpad")
                || lower.contains("unitycrash") || lower.contains("crashhandler") || lower.contains("dxsetup")
                || lower.contains("dotnet") || lower.contains("directx") || lower.contains("uninstall") {
                continue
            }
            exes.append((lower, "\(dir)/\(path)"))
        }
        guard !exes.isEmpty else { return nil }

        func score(_ rel: String, _ full: String) -> Int {
            var s = 0
            let comps = rel.split(separator: "/").map(String.init)
            let base = (rel as NSString).lastPathComponent
            let baseNoExt = normalizedName((base as NSString).deletingPathExtension)
            let depth = comps.count - 1

            // Servidor dedicado: lo PEOR (headless, sin ventana). Carpeta o nombre server/dedicated.
            let serverLike = comps.dropLast().contains { $0.contains("server") || $0.contains("dedicated") }
                || base.contains("server") || base.contains("dedicated")
            if serverLike { s -= 1000 }
            // Launchers de terceros: penalizar (pero por encima de un servidor).
            if rel.contains("launcher") { s -= 200 }
            // Marcador de cliente Unity: existe la carpeta hermana `<base>_Data`.
            let sibling = (full as NSString).deletingLastPathComponent
            let exeStem = ((base as NSString).deletingPathExtension)
            if fm.fileExists(atPath: "\(sibling)/\(exeStem)_Data") { s += 300 }
            // Nombre del exe ≈ nombre de la carpeta del juego (normalizado).
            if !folderKey.isEmpty, !baseNoExt.isEmpty,
               baseNoExt.contains(folderKey) || folderKey.contains(baseNoExt) { s += 150 }
            // Preferir la variante de **64 bits** (carpeta x64/win64/bin64/…): es la que los juegos
            // con doble build (p. ej. Grim Dawn: `Grim Dawn.exe` 32-bit arriba + `x64/Grim Dawn.exe`
            // 64-bit) lanzan por defecto, y la que va por DXMT→Metal (mejor que el 32-bit por
            // CrossOver). +120 supera el −50 de profundidad, así que gana al mismo exe en la raíz.
            let dir64: Set<String> = ["x64", "win64", "bin64", "binaries64", "x86_64", "amd64"]
            if comps.dropLast().contains(where: { dir64.contains($0) }) { s += 120 }
            // Preferir la raíz del juego frente a subcarpetas.
            s -= depth * 50
            return s
        }

        return exes.max { a, b in
            let sa = score(a.rel, a.full), sb = score(b.rel, b.full)
            if sa != sb { return sa < sb }
            return a.rel.count > b.rel.count   // empate → ruta más corta gana
        }?.full
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
