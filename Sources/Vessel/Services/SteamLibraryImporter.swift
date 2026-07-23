import Foundation

/// Analizador de disco sin estado. No está aislado al actor principal porque recorrer los árboles
/// de instalación puede tardar varios segundos; sus resultados son valores inmutables y se aplican
/// después a la UI desde `BottleDetailView`.
final class SteamLibraryImporter: Sendable {
    struct ImportedGame: Identifiable, Hashable, Sendable {
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

        if let exe = findMainExecutable(
            in: gameDir,
            appID: appId,
            steamDirectory: (steamapps as NSString).deletingLastPathComponent
        ) {
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

    private func findMainExecutable(
        in dir: String,
        appID: String,
        steamDirectory: String
    ) -> String? {
        Self.mainGameExecutable(
            in: dir,
            appID: appID,
            steamDirectory: steamDirectory
        )
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

    /// Confirma una variante Vulkan oficial distribuida en una carpeta dedicada (`x64Vk`,
    /// `Vulkan`, etc.). Algunos launchers son mínimos y el renderer vive en `Engine*.dll`, por lo
    /// que no basta con inspeccionar el `.exe`. Se exigen marcadores inequívocos del backend para no
    /// preferir una carpeta cuyo nombre contenga `vk` por casualidad.
    private static func isConfirmedVulkanVariant(_ executable: String) -> Bool {
        let directory = (executable as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        let candidates = names.filter {
            let lower = $0.lowercased()
            return lower.hasPrefix("engine") && lower.hasSuffix(".dll")
        }.prefix(12)
        for name in candidates {
            let path = "\(directory)/\(name)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            else { continue }
            let hasLoader = data.range(of: Data("vulkan-1.dll".utf8)) != nil
            let hasRenderer = ["Running Vulkan", "Vulkan initialization failed", "renderer/vulkan"]
                .contains { data.range(of: Data($0.utf8)) != nil }
            if hasLoader && hasRenderer { return true }
        }
        return false
    }

    /// Ejecutables Vulkan paralelos en la misma carpeta (`Game.exe` + `GameVk.exe`, o
    /// `Game.exe` + `Game_Vulkan.exe`). Algunos motores, como id Tech 6, distribuyen así sus dos
    /// renderizadores oficiales en lugar de separarlos en carpetas `x64`/`x64Vk`.
    ///
    /// El sufijo por sí solo no es evidencia: exigimos tanto el ejecutable base hermano como un
    /// import PE real de `vulkan-1.dll`. Así no se premian por accidente juegos cuyo nombre termine
    /// en «vk», herramientas auxiliares ni binarios que solo mencionen Vulkan en mensajes de texto.
    private static func confirmedVulkanSiblingExecutables(
        in candidates: [(rel: String, full: String)]
    ) -> Set<String> {
        let suffixes = ["_vulkan", "-vulkan", "vulkan", "_vk", "-vk", "vk"]
        let stemsByDirectory = Dictionary(grouping: candidates) { candidate in
            (candidate.rel as NSString).deletingLastPathComponent
        }.mapValues { directoryCandidates in
            Set(directoryCandidates.map {
                (($0.rel as NSString).lastPathComponent as NSString)
                    .deletingPathExtension.lowercased()
            })
        }

        var confirmed: Set<String> = []
        for candidate in candidates {
            let directory = (candidate.rel as NSString).deletingLastPathComponent
            let stem = (((candidate.rel as NSString).lastPathComponent as NSString)
                .deletingPathExtension).lowercased()
            guard let suffix = suffixes.first(where: {
                stem.hasSuffix($0) && stem.count > $0.count
            }) else { continue }
            let baseStem = String(stem.dropLast(suffix.count))
            guard stemsByDirectory[directory]?.contains(baseStem) == true,
                  PEImportScanner.importedLibraries(atPath: candidate.full)
                    .contains("vulkan-1.dll") else { continue }
            confirmed.insert(candidate.full)
        }
        return confirmed
    }

    /// Confirma una variante *standalone* oficial incluida junto al ejecutable protegido.
    ///
    /// Algunos juegos distribuyen dos árboles paralelos dentro del mismo depot, por ejemplo
    /// `_windows/win64/Game.exe` y `_windowsnosteam/win64/Game.exe`. El primero puede estar envuelto
    /// con SteamStub/CEG mientras que el segundo es el binario oficial sin DRM que el propio estudio
    /// usa para otras tiendas. Preferirlo evita abrir Steam real (y sus conflictos de sesión) sin
    /// recurrir a parches, argumentos ni reglas por AppID.
    ///
    /// El nombre de carpeta por sí solo no basta: exigimos un ejecutable espejo con el mismo sufijo
    /// de ruta y SteamStub confirmado, y que la variante candidata no lo tenga. Así no premiamos
    /// carpetas arbitrarias llamadas `nosteam` ni copias de terceros.
    private static func isConfirmedOfficialStandaloneVariant(
        relativePath: String,
        executable: String,
        candidates: [(rel: String, full: String)]
    ) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let markerIndex = components.indices.first(where: { index in
            normalizedName(components[index]).contains("nosteam")
        }) else { return false }

        let marker = normalizedName(components[markerIndex])
        let protectedMarker = marker.replacingOccurrences(of: "nosteam", with: "")
        guard !protectedMarker.isEmpty,
              !SteamDRMScanner.hasSteamStub(executable) else { return false }

        let suffix = components.dropFirst(markerIndex + 1)
        return candidates.contains { candidate in
            let peer = candidate.rel.split(separator: "/").map(String.init)
            guard peer.indices.contains(markerIndex),
                  peer.dropFirst(markerIndex + 1).elementsEqual(suffix) else { return false }
            let peerMarker = normalizedName(peer[markerIndex])
            return peerMarker == protectedMarker
                && SteamDRMScanner.hasSteamStub(candidate.full)
        }
    }

    /// Descubre el payload que un launcher oficial declara mediante una configuración verificable.
    ///
    /// Algunos depots conservan una edición antigua en la raíz y añaden una edición moderna en un
    /// subdirectorio. El botón de Steam apunta a `*_launcher.exe`, mientras que su INI contiene una
    /// relación inequívoca `ApplicationPath=<juego>.exe`. La heurística por profundidad no puede
    /// conocer esa relación y terminaba escogiendo el ejecutable antiguo de la raíz. Seguirla evita
    /// mostrar el launcher y permite que Vessel analice y prepare el motor del payload real.
    ///
    /// La evidencia se acota deliberadamente: fichero pequeño, relación exacta, launcher binario
    /// verificable, destino `.exe` existente dentro del árbol y candidato ya validado por el
    /// escaneo. Además del INI moderno se reconoce el splash clásico de DotEmu: su
    /// `splash/config.txt` declara `exe <payload>` y una o más imágenes reales, mientras el launcher
    /// raíz contiene las firmas `DotEmu`, `SDL.dll` y la ruta del propio config. No se confía en
    /// nombres de juegos, AppID ni argumentos manuales.
    private static func launcherConfiguredPayloads(
        in root: String,
        candidates: [(rel: String, full: String)]
    ) -> Set<String> {
        let fm = FileManager.default
        let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        let candidatePaths = candidates.map { URL(fileURLWithPath: $0.full).standardizedFileURL.path }
        var payloads: Set<String> = []

        let launchersByDirectory = Dictionary(grouping: candidatePaths.filter { path in
            let stem = (((path as NSString).lastPathComponent as NSString).deletingPathExtension)
            return normalizedName(stem).contains("launcher")
        }) { (path: String) in
            (path as NSString).deletingLastPathComponent
        }

        func binaryContains(_ path: String, markers: [String]) -> Bool {
            guard let data = try? Data(
                contentsOf: URL(fileURLWithPath: path),
                options: .mappedIfSafe
            ) else { return false }
            return markers.allSatisfy { marker in
                data.range(of: Data(marker.utf8)) != nil
            }
        }

        func dotEmuPayload(from url: URL, contents: String) -> String? {
            let splashDirectory = url.deletingLastPathComponent().standardizedFileURL
            guard url.lastPathComponent.caseInsensitiveCompare("config.txt") == .orderedSame,
                  splashDirectory.lastPathComponent.caseInsensitiveCompare("splash") == .orderedSame
            else { return nil }

            let entries = contents.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
                let fields = line.split(
                    maxSplits: 1,
                    omittingEmptySubsequences: true,
                    whereSeparator: \.isWhitespace
                )
                guard fields.count == 2 else { return nil }
                return (
                    String(fields[0]).lowercased(),
                    String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                )
            }
            guard let payloadValue = entries.first(where: { $0.0 == "exe" })?.1,
                  !payloadValue.isEmpty,
                  (payloadValue as NSString).pathExtension.caseInsensitiveCompare("exe") == .orderedSame
            else { return nil }

            let images = entries.filter { $0.0 == "img" }.map(\.1)
            guard !images.isEmpty,
                  images.allSatisfy({ image in
                      let resolved = URL(fileURLWithPath: image, relativeTo: splashDirectory)
                          .standardizedFileURL.path
                      return resolved.hasPrefix(splashDirectory.path + "/")
                          && fm.fileExists(atPath: resolved)
                  })
            else { return nil }

            let gameRoot = splashDirectory.deletingLastPathComponent().standardizedFileURL
            guard gameRoot.path == standardizedRoot,
                  candidatePaths.contains(where: { launcher in
                      let launcherURL = URL(fileURLWithPath: launcher).standardizedFileURL
                      return launcherURL.deletingLastPathComponent() == gameRoot
                          && binaryContains(
                              launcher,
                              markers: ["DotEmu", "SDL.dll", #"splash\config.txt"#]
                          )
                  })
            else { return nil }

            let relative = payloadValue.replacingOccurrences(of: "\\", with: "/")
            let resolved = URL(fileURLWithPath: relative, relativeTo: gameRoot)
                .standardizedFileURL.path
            guard resolved.hasPrefix(standardizedRoot + "/"),
                  let candidate = candidatePaths.first(where: {
                      $0.caseInsensitiveCompare(resolved) == .orderedSame
                  })
            else { return nil }
            return candidate
        }

        // Los dos contratos admitidos ya acotan por construcción dónde puede vivir su descriptor:
        // DotEmu exige `<raíz>/splash/config.txt` y el launcher moderno exige un INI hermano. Recorrer
        // todo el depot para encontrarlos era equivalente pero muy costoso: God of War contiene más
        // de 155.000 assets y cada sincronización repetía un segundo paseo completo, llevando Vessel
        // por encima del 100 % de CPU y varios GiB de memoria aunque no hubiera ningún launcher.
        let textKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        func smallTextContents(at url: URL) -> String? {
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(standardizedRoot + "/"),
                  let values = try? standardized.resourceValues(forKeys: textKeys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= 64 * 1024 else { return nil }
            return try? String(contentsOf: standardized, encoding: .utf8)
        }

        // Mantener la comparación case-insensitive del escaneo anterior también en volúmenes que
        // distingan mayúsculas: solo se listan la raíz y su carpeta `splash`, nunca los assets.
        let rootURL = URL(fileURLWithPath: standardizedRoot, isDirectory: true)
        if let rootEntries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ), let splashURL = rootEntries.first(where: {
            $0.lastPathComponent.caseInsensitiveCompare("splash") == .orderedSame
        }), let splashValues = try? splashURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           splashValues.isDirectory == true,
           splashValues.isSymbolicLink != true,
           let splashEntries = try? fm.contentsOfDirectory(
               at: splashURL,
               includingPropertiesForKeys: Array(textKeys),
               options: [.skipsHiddenFiles]
           ), let configURL = splashEntries.first(where: {
               $0.lastPathComponent.caseInsensitiveCompare("config.txt") == .orderedSame
           }), let contents = smallTextContents(at: configURL),
           let payload = dotEmuPayload(from: configURL, contents: contents) {
            payloads.insert(payload)
        }

        // Un INI solo es relevante si comparte carpeta con un ejecutable cuyo nombre confirma que
        // es launcher. Consultar esas pocas carpetas conserva exactamente el contrato previo y evita
        // inspeccionar árboles de texturas, idiomas, cinemáticas o mods.
        for directory in launchersByDirectory.keys.sorted() {
            guard directory == standardizedRoot || directory.hasPrefix(standardizedRoot + "/") else {
                continue
            }
            let directoryURL = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
            guard let entries = try? fm.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(textKeys),
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in entries where url.pathExtension.caseInsensitiveCompare("ini") == .orderedSame {
                guard let contents = smallTextContents(at: url) else { continue }

                let iniStem = normalizedName(url.deletingPathExtension().lastPathComponent)
                guard !iniStem.isEmpty,
                      launchersByDirectory[directory]?.contains(where: { launcher in
                          let launcherStem = normalizedName(
                              ((((launcher as NSString).lastPathComponent) as NSString).deletingPathExtension)
                          )
                          return launcherStem.contains(iniStem)
                      }) == true else { continue }

                guard let applicationPath = contents
                    .split(whereSeparator: \.isNewline)
                    .compactMap({ line -> String? in
                        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        guard parts.count == 2,
                              parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                                .caseInsensitiveCompare("ApplicationPath") == .orderedSame else { return nil }
                        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    })
                    .first,
                      !applicationPath.isEmpty,
                      (applicationPath as NSString).pathExtension.caseInsensitiveCompare("exe") == .orderedSame
                else { continue }

                let relative = applicationPath.replacingOccurrences(of: "\\", with: "/")
                let resolved = URL(fileURLWithPath: relative, relativeTo: directoryURL)
                    .standardizedFileURL.path
                guard resolved.hasPrefix(standardizedRoot + "/"),
                      let candidate = candidatePaths.first(where: {
                          $0.caseInsensitiveCompare(resolved) == .orderedSame
                      }),
                      !normalizedName((candidate as NSString).lastPathComponent).contains("launcher")
                else { continue }
                payloads.insert(candidate)
            }
        }
        return payloads
    }

    static func mainGameExecutable(
        in dir: String,
        appID: String? = nil,
        steamDirectory: String? = nil
    ) -> String? {
        let fm = FileManager.default
        // Steam ya ha resuelto plataforma, edición y opción predeterminada en `appinfo.vdf`.
        // Esa decisión es más autoritativa que cualquier heurística de nombres (p. ej. una edición
        // «classic» más corta junto a la edición actual). Si la caché está ausente, corrupta o apunta
        // a un fichero que ya no existe tras una actualización, se conserva el resolutor estructural
        // de abajo como fallback seguro.
        if let appID, !appID.isEmpty,
           let steamDirectory, !steamDirectory.isEmpty,
           let relative = SteamAppInfoLaunchResolver.defaultWindowsExecutable(
               appID: appID,
               appInfoPath: "\(steamDirectory)/appcache/appinfo.vdf"
           ),
           let official = SteamAppInfoLaunchResolver.resolvedExecutable(
               relativePath: relative,
               installRoot: dir,
               fileManager: fm
           ) {
            return official
        }

        guard let enumerator = fm.enumerator(atPath: dir) else { return nil }
        let folderKey = normalizedName((dir as NSString).lastPathComponent)

        var exes: [(rel: String, full: String)] = []
        for case let path as String in enumerator where path.lowercased().hasSuffix(".exe") {
            let lower = path.lowercased()
            let executableStem = ((((lower as NSString).lastPathComponent) as NSString)
                .deletingPathExtension)
            let normalizedStem = normalizedName(executableStem)
            if lower.contains("redist") || lower.contains("vcredist") || lower.contains("crashpad")
                || lower.contains("unitycrash") || lower.contains("crashhandler") || lower.contains("dxsetup")
                || lower.contains("dotnet") || lower.contains("directx") || lower.contains("uninstall") {
                continue
            }
            // Reportadores de fallos e instaladores auxiliares modernos: tampoco son payloads
            // jugables. RE ENGINE, entre otros motores AAA, deja `CrashReport.exe` e
            // `InstallerMessage.exe` en la misma raíz que el juego; como sus rutas son más cortas,
            // el desempate antiguo podía abrir el reportador en vez del ejecutable principal.
            // Acotamos la exclusión a nombres funcionales inequívocos para no castigar juegos cuyo
            // título contenga palabras genéricas como «crash» o «install».
            let auxiliaryPrefixes = [
                "crashreport", "crashreporter", "crashsender", "crashuploader", "crashdump",
                "errorreport", "reportcrash", "installermessage", "installerhelper",
                "installhelper", "installationhelper", "prerequisiteinstaller", "prereqinstaller"
            ]
            if auxiliaryPrefixes.contains(where: { normalizedStem.hasPrefix($0) }) {
                continue
            }
            // Paneles auxiliares de configuración: no son el juego. Algunos depots antiguos los
            // dejan en la raíz junto al ejecutable real y, por tener un nombre más corto, ganaban
            // el desempate (Ys Origin: `config.exe` frente a `yso_win.exe`). Si el depot solo trae
            // uno de estos paneles, la instalación está incompleta y tampoco debe marcarse jugable.
            if ["config", "configuration", "configure", "settings", "setup"].contains(executableStem) {
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
        let configuredLauncherPayloads = launcherConfiguredPayloads(in: dir, candidates: exes)
        let confirmedVulkanSiblings = confirmedVulkanSiblingExecutables(in: exes)

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
            // Variantes Vulkan oficiales: en Apple Silicon se enrutan después al motor completo con
            // winevulkan + MoltenVK. Se eligen automáticamente cuando la carpeta lo declara y una DLL
            // de motor confirma el backend; no hay argumento ni ajuste manual para el usuario.
            let rendererDirectory = comps.dropLast().last ?? ""
            let vulkanDirectory = rendererDirectory.contains("vulkan")
                || rendererDirectory.hasSuffix("vk")
            if vulkanDirectory, isConfirmedVulkanVariant(full) { s += 260 }
            // Renderers paralelos en la misma carpeta. La lista se precalcula para no releer varias
            // veces ejecutables grandes durante las comparaciones del `max`.
            if confirmedVulkanSiblings.contains(full) { s += 260 }
            // Si el depot incluye una edición oficial paralela sin SteamStub, esa es la ruta más
            // autónoma y segura. La evidencia estructural supera preferencias de profundidad/64-bit.
            if isConfirmedOfficialStandaloneVariant(
                relativePath: rel,
                executable: full,
                candidates: exes
            ) { s += 700 }
            // Un launcher oficial ha declarado explícitamente este ejecutable como su payload.
            // La relación tiene más peso que raíz/profundidad, pero menos que una variante oficial
            // standalone confirmada frente a SteamStub.
            if configuredLauncherPayloads.contains(
                URL(fileURLWithPath: full).standardizedFileURL.path
            ) { s += 450 }
            // Preferir la variante de **64 bits** (carpeta x64/win64/bin64/…): es la que los juegos
            // con doble build (p. ej. Grim Dawn: `Grim Dawn.exe` 32-bit arriba + `x64/Grim Dawn.exe`
            // 64-bit) lanzan por defecto, y la que va por DXMT→Metal (mejor que el 32-bit por
            // CrossOver). +120 supera el −50 de profundidad, así que gana al mismo exe en la raíz.
            let dir64: Set<String> = ["x64", "x64vk", "win64", "bin64", "binaries64", "x86_64", "amd64"]
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
