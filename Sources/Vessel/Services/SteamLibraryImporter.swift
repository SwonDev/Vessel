import Foundation

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
        var stateFlags = 0

        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("\"appid\"") {
                appId = extractValue(from: trimmed) ?? ""
            } else if trimmed.contains("\"name\"") {
                name = extractValue(from: trimmed) ?? ""
            } else if trimmed.contains("\"installdir\"") {
                installdir = extractValue(from: trimmed) ?? ""
            } else if trimmed.contains("\"StateFlags\"") {
                stateFlags = Int(extractValue(from: trimmed) ?? "") ?? 0
            }
        }

        guard !appId.isEmpty, !installdir.isEmpty else { return nil }
        // Solo juegos COMPLETAMENTE instalados (bit 4 = fully installed). El cliente Steam real
        // escribe el appmanifest en cuanto EMPIEZA la descarga (StateFlags=2/1026 y similares),
        // y sin este filtro la auto-importación registraba juegos a medias —con la carpeta llena
        // de staging y sin ejecutable— como si estuvieran instalados (Portal Stories: Mel).
        guard stateFlags & 4 != 0 else { return nil }
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
    /// `true` si el `.exe` es de **MS-DOS** (16 bits), no de Windows.
    ///
    /// Todo ejecutable de Windows empieza por la cabecera `MZ` de DOS, pero lleva detrás una firma
    /// `PE\0\0` en el desplazamiento que marca `e_lfanew` (offset 0x3C). Si esa firma no está, es un
    /// binario de DOS puro: Wine no lo ejecuta en un macOS de 64 bits (necesitaría DOSBox).
    static func isDOSExecutable(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 0x40), head.count >= 0x40,
              head[0] == 0x4D, head[1] == 0x5A else { return false }        // sin 'MZ' no es ejecutable
        let lfanew = head.withUnsafeBytes { $0.load(fromByteOffset: 0x3C, as: UInt32.self) }
        guard lfanew > 0, lfanew < 0x1000_0000,
              (try? fh.seek(toOffset: UInt64(lfanew))) != nil,
              let sig = try? fh.read(upToCount: 4), sig.count == 4 else { return true }
        return !(sig[0] == 0x50 && sig[1] == 0x45 && sig[2] == 0 && sig[3] == 0)   // 'PE\0\0'
    }

    /// Confirma que una variante cuyo nombre termina en `_gl` es realmente el renderer OpenGL.
    /// El nombre por sí solo no basta; exigimos una firma embebida del propio motor para no preferir
    /// por accidente herramientas auxiliares. Ocho MiB cubren la tabla de strings de estos launchers
    /// pequeños sin mapear ejecutables completos de varios GiB.
    private static func isConfirmedOpenGLVariant(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 8 * 1024 * 1024), !data.isEmpty else { return false }
        return ["OpenGL Error", "unable to create an OpenGL context", "Failed to init SDL"]
            .contains { data.range(of: Data($0.utf8)) != nil }
    }

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
            // **Ejecutables de MS-DOS**: fuera. Wine no corre binarios de 16 bits en un macOS de 64,
            // así que elegirlos es garantía de que el juego no arranca. Y los hay: las recopilaciones
            // modernas incluyen el original junto al remaster (DOOM + DOOM II trae `base/DOOM.EXE` de
            // 1993 **y** `rerelease/doom.exe` de 2024 — Vessel se quedaba con el de 1993 y no abría
            // nada). Se reconocen porque su cabecera MZ no lleva un PE detrás.
            if isDOSExecutable("\(dir)/\(path)") { continue }
            exes.append((lower, "\(dir)/\(path)"))
        }
        guard !exes.isEmpty else { return nil }

        func score(_ rel: String, _ full: String) -> Int {
            var s = 0
            let comps = rel.split(separator: "/").map(String.init)
            let base = (rel as NSString).lastPathComponent
            let rawStem = (base as NSString).deletingPathExtension
            let baseNoExt = normalizedName((base as NSString).deletingPathExtension)
            let depth = comps.count - 1

            // Servidor dedicado: lo PEOR (headless, sin ventana). Carpeta o nombre server/dedicated.
            let serverLike = comps.dropLast().contains { $0.contains("server") || $0.contains("dedicated") }
                || base.contains("server") || base.contains("dedicated")
            if serverLike { s -= 1000 }
            // **Herramientas del JRE/JDK embebido** (juegos Java: Wurm, etc.). El juego trae un Java
            // portable en `runtime/bin`, `jre/bin` o `jdk*/bin`, lleno de `.exe` que NO son el juego
            // (`java`, `javaw`, `java-rmi`, `rmiregistry`, `keytool`, `jarsigner`, `policytool`…). Sin
            // esto ganaban al launcher real (que se llama `*Launcher.exe` y está penalizado), y Vessel
            // lanzaba `java-rmi.exe` en vez del juego. Se hunden por carpeta y por nombre. El launcher
            // Java de verdad (`<Juego>Launcher.exe`, junto a un `client.jar`) queda muy por encima.
            let dirComps = comps.dropLast()
            let inJreDir = dirComps.contains { $0 == "bin" }
                && dirComps.contains { $0 == "runtime" || $0 == "jre" || $0.hasPrefix("jdk") || $0.hasPrefix("jre") }
            let jreTool = ["java", "javaw", "java-rmi", "rmiregistry", "keytool", "jarsigner", "policytool",
                           "kinit", "ktab", "klist", "pack200", "unpack200", "javacpl", "jabswitch",
                           "jjs", "orbd", "servertool", "tnameserv", "jp2launcher"].contains(baseNoExt)
            if inJreDir || jreTool { s -= 900 }
            // **Herramientas del Source SDK** (mapping/modelado/empaquetado): nunca son el juego.
            // En descargas parciales (o mods cuyo depot no trae el exe del motor) son el ÚNICO
            // `.exe` presente y ganaban por ausencia de competencia: Vessel "instalaba" vbsp.exe
            // como si fuera el juego (Portal Stories: Mel). Mismo hundimiento que el JRE.
            let sourceTool = ["vbsp", "vvis", "vrad", "vbspinfo", "bspzip", "vpk", "hlmv", "hammer",
                              "hammerplusplus", "studiomdl", "glview", "vtex", "vmtedit",
                              "captioncompiler", "dmxconvert", "dmxedit", "mksheet", "pet",
                              "qc_eyes", "sfm", "tga2vtf", "vcdgenerator"].contains(baseNoExt)
            if sourceTool { s -= 900 }
            // Launchers de terceros: penalizar (pero por encima de un servidor).
            if rel.contains("launcher") { s -= 200 }
            // **Unreal Engine**: el juego REAL vive en `<Proyecto>/Binaries/Win64/…-Shipping.exe`;
            // el `.exe` de la raíz es un LANZADOR que lo arranca. Si Vessel lanza el lanzador, DXMT
            // no llega al exe real y Unreal muere con "A D3D11-compatible GPU (Feature Level 11.0,
            // Shader Model 5.0) is required to run the engine". Se prefiere el exe de `Binaries/Win64`
            // con fuerza (supera al lanzador de la raíz pese a la penalización de profundidad).
            if comps.dropLast().contains("binaries"),
               comps.dropLast().contains(where: { $0 == "win64" || $0 == "win32" || $0 == "wingdk" }) {
                s += 400
                if base.contains("shipping") { s += 100 }   // el Shipping ES el build de release
            }
            // Marcador de cliente Unity: existe la carpeta hermana `<base>_Data`.
            let sibling = (full as NSString).deletingLastPathComponent
            let exeStem = ((base as NSString).deletingPathExtension)
            if fm.fileExists(atPath: "\(sibling)/\(exeStem)_Data") { s += 300 }
            // Nombre del exe ≈ nombre de la carpeta del juego (normalizado).
            if !folderKey.isEmpty, !baseNoExt.isEmpty,
               baseNoExt.contains(folderKey) || folderKey.contains(baseNoExt) { s += 150 }
            // Algunos juegos entregan renderers equivalentes en la raíz (`game.exe` y
            // `game_gl.exe`). En macOS la variante OpenGL puede ser la ruta compatible real, pero la
            // heurística antigua empataba y elegía el nombre más corto. Solo la premiamos cuando
            // existe el ejecutable base hermano Y el binario confirma que inicializa OpenGL.
            let stemLower = rawStem.lowercased()
            if stemLower.hasSuffix("_gl") {
                let siblingStem = String(stemLower.dropLast(3))
                let siblingDir = (rel as NSString).deletingLastPathComponent
                let hasBaseSibling = exes.contains { candidate in
                    (candidate.rel as NSString).deletingLastPathComponent == siblingDir
                        && (((candidate.rel as NSString).lastPathComponent as NSString)
                            .deletingPathExtension.lowercased() == siblingStem)
                }
                if hasBaseSibling, isConfirmedOpenGLVariant(full) { s += 220 }
            }
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

        let best = exes.max { a, b in
            let sa = score(a.rel, a.full), sb = score(b.rel, b.full)
            if sa != sb { return sa < sb }
            return a.rel.count > b.rel.count   // empate → ruta más corta gana
        }
        // Sin candidato creíble, `nil` (el juego NO se importa): si lo mejor que hay es una
        // herramienta hundida (JRE/Source SDK/launcher — score ≤ −900), elegirla "porque es la
        // única" convierte una descarga parcial en un juego "instalado" que no arranca.
        guard let best, score(best.rel, best.full) > -900 else { return nil }
        return best.full
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

}
