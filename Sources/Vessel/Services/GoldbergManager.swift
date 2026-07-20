import Foundation

/// Gestiona **Goldberg / gbe_fork**, un emulador open-source de la Steamworks API.
/// Reemplaza el `steam_api(64).dll` del juego por una implementación emulada que
/// hace creer al juego que Steam está corriendo y con sesión iniciada, **sin
/// necesitar el cliente de Steam**. Es la vía robusta para el DRM de Steamworks
/// en Apple Silicon: el cliente de Steam (Chromium/CEF) es inestable bajo Wine
/// (error 0x3008) en el motor de GPTK que los juegos D3D12 necesitan, así que en
/// vez de pelear con él, emulamos la API. Legítimo para juegos que posees; es lo
/// que usan Heroic/Lutris para desacoplar el arranque del cliente.
///
/// Solo cubre el DRM de Steamworks. Juegos con DRM adicional (Denuvo, etc.) no se
/// soportan; FF Tactics solo usa Steamworks (fallaba con "Unable to initialize
/// SteamAPI", no con un error de Denuvo).
@MainActor
final class GoldbergManager {
    /// gbe_fork (fork mantenido de Goldberg). El `.7z` lo extrae `tar` (libarchive).
    static let releaseURL = URL(string: "https://github.com/Detanup01/gbe_fork/releases/download/release-2026_05_30/emu-win-release.7z")!

    private let dependencyManager = DependencyManager()
    private let cacheDirectoryOverride: String?

    init(cacheDirectoryOverride: String? = nil) {
        self.cacheDirectoryOverride = cacheDirectoryOverride
    }

    /// Juegos cuyo runtime exige una vtable de ISteamClient ANTIGUA (con
    /// ISteamUnifiedMessages en su slot histórico; Valve lo movió al final como
    /// «deprecated» a partir de SteamClient017). gbe_fork se queda con la ÚLTIMA
    /// línea `SteamClientNNN` de `steam_interfaces.txt` para decidir la vtable que
    /// expone: si es demasiado nueva, las llamadas por slot del juego caen en la
    /// función equivocada (pedía GetISteamUnifiedMessages y gbe recibía la versión
    /// en GetISteamHTTP → diálogo modal «Missing interface» + exit(0x4155149)).
    /// Verificado con Archvale (GameMaker Studio 2.3): con SteamClient016 arranca.
    private static let steamClientVtableOverride: [String: String] = [
        "1296360": "SteamClient016", // Archvale — GameMaker Studio 2.3 (slot ISteamUnifiedMessages)
    ]

    var cacheDir: String { cacheDirectoryOverride ?? "\(VesselPaths.cacheDirectory)/goldberg" }
    var steamApi64Path: String { "\(cacheDir)/steam_api64.dll" }
    var steamApi32Path: String { "\(cacheDir)/steam_api.dll" }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: steamApi64Path) }

    func ensureInstalled(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        if isInstalled { return }
        try await dependencyManager.installGoldberg(from: Self.releaseURL, progress: progress)
        guard isInstalled else {
            throw NSError(domain: "Vessel", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "Goldberg se instaló pero no se pudo autodetectar."
            ])
        }
    }

    // MARK: - Aplicar/restaurar en el juego

    /// Reemplaza el/los `steam_api(64).dll` del juego por los de Goldberg
    /// (respaldando el original como `.vessel-orig`) y escribe el AppID + un usuario.
    /// Idempotente: si ya está aplicado, no rehace el respaldo. Devuelve true si el
    /// juego tenía algún `steam_api*.dll` que reemplazar.
    @discardableResult
    func applyToGame(gameExecutable: String, appId: String, accountName: String = "Vessel") -> Bool {
        let fm = FileManager.default
        let root = Self.installRoot(forExecutable: gameExecutable)
        let buildID = Self.installedBuildID(
            forExecutable: gameExecutable,
            appId: appId,
            fileManager: fm
        )
        var applied = false
        // Buscar TODOS los `steam_api(64).dll` del juego, RECURSIVAMENTE: los juegos Unity los
        // colocan en `<Juego>_Data/Plugins/x86_64/`, NO en la carpeta del exe (bug real: Core
        // Keeper fallaba con "SteamApi_Init returned false" porque Goldberg solo miraba la raíz).
        // Goldberg lee su config (steam_settings/steam_appid.txt) desde el DIRECTORIO del DLL
        // cargado, así que se escribe JUNTO A CADA DLL.
        let dlls = Self.findSteamApiDLLs(under: root, fm: fm)
        for dll in dlls {
            let is64 = (dll as NSString).lastPathComponent.lowercased() == "steam_api64.dll"
            // Generar `steam_interfaces.txt` desde el DLL ORIGINAL **antes** de reemplazarlo por Goldberg.
            let dir = (dll as NSString).deletingLastPathComponent
            generateSteamInterfaces(fromDLL: dll, intoSettingsDir: "\(dir)/steam_settings", fm: fm)
            if replaceDLL(at: dll, with: is64 ? steamApi64Path : steamApi32Path, fm: fm) { applied = true }
            if !appId.isEmpty {
                try? appId.write(toFile: "\(dir)/steam_appid.txt", atomically: true, encoding: .utf8)
            }
            writeSteamSettings(
                inDir: dir,
                appId: appId,
                accountName: accountName,
                buildID: buildID
            )
            applySteamClientVtableOverride(appId: appId, settingsDir: "\(dir)/steam_settings", fm: fm)
        }
        // Fallback defensivo: si no se halló ningún DLL, aplicar en la carpeta del exe (como antes).
        if dlls.isEmpty {
            let gameDir = (gameExecutable as NSString).deletingLastPathComponent
            generateSteamInterfaces(fromDLL: "\(gameDir)/steam_api64.dll", intoSettingsDir: "\(gameDir)/steam_settings", fm: fm)
            generateSteamInterfaces(fromDLL: "\(gameDir)/steam_api.dll", intoSettingsDir: "\(gameDir)/steam_settings", fm: fm)
            if replaceDLL(at: "\(gameDir)/steam_api64.dll", with: steamApi64Path, fm: fm) { applied = true }
            if replaceDLL(at: "\(gameDir)/steam_api.dll", with: steamApi32Path, fm: fm) { applied = true }
            if !appId.isEmpty { try? appId.write(toFile: "\(gameDir)/steam_appid.txt", atomically: true, encoding: .utf8) }
            writeSteamSettings(
                inDir: gameDir,
                appId: appId,
                accountName: accountName,
                buildID: buildID
            )
            applySteamClientVtableOverride(appId: appId, settingsDir: "\(gameDir)/steam_settings", fm: fm)
        }
        // Java/libGDX puede llevar Steamworks4j dentro del JAR. Ese runtime extrae su propio
        // `steam_api(64).dll` al Temp del usuario de Wine, por lo que no existe ningún DLL visible
        // junto al exe que el recorrido anterior pueda sustituir. Vessel parchea de forma atómica
        // el recurso embebido y prepara el directorio de extracción que Steamworks4j calcula.
        if applyToEmbeddedSteamworksArchives(
            gameExecutable: gameExecutable,
            appId: appId,
            accountName: accountName,
            buildID: buildID,
            fm: fm
        ) {
            applied = true
        }
        return applied
    }

    /// Restaura el/los `steam_api(64).dll` original(es) del juego (revertir Goldberg), buscando los
    /// respaldos `.vessel-orig` RECURSIVAMENTE (cubre la subcarpeta de plugins de Unity).
    func restoreGame(gameExecutable: String) {
        let fm = FileManager.default
        let root = Self.installRoot(forExecutable: gameExecutable)
        guard let en = fm.enumerator(atPath: root) else { return }
        for case let rel as String in en where rel.hasSuffix("steam_api64.dll.vessel-orig") || rel.hasSuffix("steam_api.dll.vessel-orig") {
            let backup = "\(root)/\(rel)"
            let path = String(backup.dropLast(".vessel-orig".count))
            try? fm.removeItem(atPath: path)
            try? fm.copyItem(atPath: backup, toPath: path)
        }
        restoreEmbeddedSteamworksArchives(gameExecutable: gameExecutable, root: root, fm: fm)
    }

    /// Steamworks4j empaqueta la API nativa dentro de un JAR en vez de dejarla en el árbol del
    /// juego. Se expone al diagnóstico para que un fallo de inicialización siga clasificándose como
    /// Steamworks y nunca termine convertido en un falso problema gráfico.
    func hasEmbeddedSteamworks(gameExecutable: String) -> Bool {
        !embeddedSteamworksArchives(forExecutable: gameExecutable).isEmpty
    }

    /// libGDX 1.x con LWJGL 2 usa OpenGL clásico y no es consciente del escalado Retina de Wine.
    /// Se detecta por clases y nativos embebidos, nunca por el título del juego.
    func hasLegacyLibGDXOpenGL(gameExecutable: String) -> Bool {
        candidateJavaArchives(forExecutable: gameExecutable).contains { jar in
            guard let listingData = runTool("/usr/bin/unzip", arguments: ["-Z1", jar]),
                  let listing = String(data: listingData, encoding: .utf8) else { return false }
            return listing.contains("com/badlogic/gdx/backends/lwjgl/LwjglApplication.class")
                && (listing.contains("lwjgl64.dll") || listing.contains("lwjgl.dll"))
        }
    }

    /// Raíz de instalación del juego. El exe puede estar en la raíz o en una subcarpeta (`x64/`),
    /// y el `steam_api` puede estar en otra rama del árbol → se busca desde `steamapps/common/<juego>`.
    private static func installRoot(forExecutable exe: String) -> String {
        let comps = (exe as NSString).pathComponents
        if let i = comps.firstIndex(where: { $0.lowercased() == "common" }), i + 1 < comps.count {
            return NSString.path(withComponents: Array(comps[0...(i + 1)]))
        }
        return (exe as NSString).deletingLastPathComponent
    }

    /// Recupera el BuildID de la instalación real de Steam. Algunos motores usan
    /// `ISteamApps::GetAppBuildId` para seleccionar sus paquetes de datos, por lo que el valor
    /// ficticio del emulador puede dejar recursos válidos sin montar. Admite tanto el layout
    /// estándar (`steamapps/appmanifest_*.acf`) como instalaciones autocontenidas que conservan
    /// el manifiesto dentro de la raíz del juego.
    static func installedBuildID(
        forExecutable executable: String,
        appId: String,
        fileManager fm: FileManager = .default
    ) -> String? {
        guard !appId.isEmpty,
              appId.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains) else {
            return nil
        }

        let manifestName = "appmanifest_\(appId).acf"
        var directory = URL(fileURLWithPath: installRoot(forExecutable: executable), isDirectory: true)
        var visited = Set<String>()

        for _ in 0..<8 {
            let candidates = [
                directory.appendingPathComponent(manifestName),
                directory.appendingPathComponent("steamapps", isDirectory: true)
                    .appendingPathComponent(manifestName),
            ]
            for candidate in candidates where visited.insert(candidate.path).inserted {
                guard fm.fileExists(atPath: candidate.path),
                      let manifest = try? String(contentsOf: candidate, encoding: .utf8),
                      let buildID = buildID(fromSteamManifest: manifest) else {
                    continue
                }
                return buildID
            }

            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return nil
    }

    private static func buildID(fromSteamManifest manifest: String) -> String? {
        let pattern = #"(?im)^\s*"buildid"\s*"([0-9]+)"\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: manifest,
                range: NSRange(manifest.startIndex..., in: manifest)
              ),
              let range = Range(match.range(at: 1), in: manifest) else {
            return nil
        }
        let buildID = String(manifest[range])
        guard let numericBuildID = UInt32(buildID), numericBuildID > 0 else { return nil }
        return String(numericBuildID)
    }

    /// Localiza todos los `steam_api(64).dll` del árbol del juego (no los respaldos `.vessel-orig`).
    private static func findSteamApiDLLs(under root: String, fm: FileManager) -> [String] {
        var out: [String] = []
        guard let en = fm.enumerator(atPath: root) else { return out }
        for case let rel as String in en {
            let base = (rel as NSString).lastPathComponent.lowercased()
            if base == "steam_api64.dll" || base == "steam_api.dll" { out.append("\(root)/\(rel)") }
        }
        return out
    }

    private struct EmbeddedSteamworksArchive {
        let path: String
        let version: String
        let libraries: [String]
    }

    /// Busca JARs del lanzador y de `lib/` sin recorrer árboles completos de recursos. Un paquete
    /// Steamworks4j válido contiene tanto el bridge JNI como `steam_api(64).dll` en la raíz.
    private func embeddedSteamworksArchives(forExecutable executable: String) -> [EmbeddedSteamworksArchive] {
        candidateJavaArchives(forExecutable: executable).compactMap { jar in
            guard let listingData = runTool("/usr/bin/unzip", arguments: ["-Z1", jar]),
                  let listing = String(data: listingData, encoding: .utf8) else { return nil }
            let entries = Set(listing.components(separatedBy: .newlines))
            let hasBridge = entries.contains("steamworks4j64.dll") || entries.contains("steamworks4j.dll")
            guard hasBridge else { return nil }
            let libraries = ["steam_api64.dll", "steam_api.dll"].filter(entries.contains)
            guard !libraries.isEmpty else { return nil }

            let propertiesPath = entries.first {
                $0.hasSuffix("/com.code-disaster.steamworks4j/steamworks4j/pom.properties")
            }
            let rawVersion = propertiesPath
                .flatMap { archiveEntryData(archive: jar, entry: $0) }
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { text in
                    text.components(separatedBy: .newlines)
                        .first(where: { $0.hasPrefix("version=") })?
                        .dropFirst("version=".count)
                }
                .map(String.init) ?? "embedded"
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            let version = rawVersion.unicodeScalars.allSatisfy(allowed.contains) ? rawVersion : "embedded"
            return EmbeddedSteamworksArchive(path: jar, version: version, libraries: libraries)
        }
    }

    private func candidateJavaArchives(forExecutable executable: String) -> [String] {
        let fm = FileManager.default
        let gameDir = (executable as NSString).deletingLastPathComponent
        var candidates: [String] = []
        for directory in [gameDir, "\(gameDir)/lib"] {
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            candidates += names
                .filter { ($0 as NSString).pathExtension.lowercased() == "jar" }
                .map { "\(directory)/\($0)" }
        }
        return candidates.sorted()
    }

    private func applyToEmbeddedSteamworksArchives(
        gameExecutable: String,
        appId: String,
        accountName: String,
        buildID: String?,
        fm: FileManager
    ) -> Bool {
        let archives = embeddedSteamworksArchives(forExecutable: gameExecutable)
        guard !archives.isEmpty else { return false }
        var applied = false

        for archive in archives {
            let backup = "\(archive.path).vessel-orig"
            let currentLibraries = Dictionary(uniqueKeysWithValues: archive.libraries.compactMap { name in
                archiveEntryData(archive: archive.path, entry: name).map { (name, $0) }
            })
            guard currentLibraries.count == archive.libraries.count else { continue }

            let replacements = Dictionary(uniqueKeysWithValues: archive.libraries.compactMap { name in
                let source = name == "steam_api64.dll" ? steamApi64Path : steamApi32Path
                return fm.contents(atPath: source).map { (name, $0) }
            })
            guard replacements.count == archive.libraries.count else { continue }

            let alreadyPatched = archive.libraries.allSatisfy { currentLibraries[$0] == replacements[$0] }
            var originalLibraries: [String: Data] = [:]
            if alreadyPatched {
                if fm.fileExists(atPath: backup) {
                    for name in archive.libraries {
                        originalLibraries[name] = archiveEntryData(archive: backup, entry: name)
                    }
                }
            } else {
                // Una API oficial de Steam es pequeña. Si aparece otro reemplazo grande que no es
                // el de Vessel, no lo pisamos: puede pertenecer a otra herramienta del usuario.
                guard archive.libraries.allSatisfy({ (currentLibraries[$0]?.count ?? .max) < 5_000_000 }) else {
                    continue
                }
                originalLibraries = currentLibraries
                do {
                    if fm.fileExists(atPath: backup) { try fm.removeItem(atPath: backup) }
                    try fm.copyItem(atPath: archive.path, toPath: backup)
                    try patchArchiveAtomically(
                        archive: archive.path,
                        replacements: replacements,
                        fileManager: fm
                    )
                } catch {
                    continue
                }
            }

            prepareSteamworksExtraction(
                gameExecutable: gameExecutable,
                version: archive.version,
                replacements: replacements,
                originals: originalLibraries,
                appId: appId,
                accountName: accountName,
                buildID: buildID,
                fileManager: fm
            )
            applied = true
        }
        return applied
    }

    private func patchArchiveAtomically(
        archive: String,
        replacements: [String: Data],
        fileManager fm: FileManager
    ) throws {
        let staging = fm.temporaryDirectory
            .appendingPathComponent("Vessel-Steamworks4j-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let patched = staging.appendingPathComponent("patched.jar")
        try fm.copyItem(atPath: archive, toPath: patched.path)
        for (name, data) in replacements {
            try data.write(to: staging.appendingPathComponent(name), options: .atomic)
        }
        let names = replacements.keys.sorted()
        guard runTool(
            "/usr/bin/zip",
            arguments: ["-q", patched.path] + names,
            currentDirectory: staging
        ) != nil else {
            throw CocoaError(.fileWriteUnknown)
        }
        for (name, data) in replacements {
            guard archiveEntryData(archive: patched.path, entry: name) == data else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        _ = try fm.replaceItemAt(URL(fileURLWithPath: archive), withItemAt: patched)
    }

    private func prepareSteamworksExtraction(
        gameExecutable: String,
        version: String,
        replacements: [String: Data],
        originals: [String: Data],
        appId: String,
        accountName: String,
        buildID: String?,
        fileManager fm: FileManager
    ) {
        for tempDir in wineUserTempDirectories(forExecutable: gameExecutable, fileManager: fm) {
            let extraction = "\(tempDir)/steamworks4j/\(version)"
            try? fm.createDirectory(atPath: extraction, withIntermediateDirectories: true)
            for (name, data) in replacements {
                let path = "\(extraction)/\(name)"
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                if let original = originals[name] {
                    try? original.write(
                        to: URL(fileURLWithPath: "\(path).vessel-orig"),
                        options: .atomic
                    )
                }
                generateSteamInterfaces(
                    fromDLL: path,
                    intoSettingsDir: "\(extraction)/steam_settings",
                    fm: fm
                )
            }
            if !appId.isEmpty {
                try? appId.write(
                    toFile: "\(extraction)/steam_appid.txt",
                    atomically: true,
                    encoding: .utf8
                )
            }
            writeSteamSettings(
                inDir: extraction,
                appId: appId,
                accountName: accountName,
                buildID: buildID
            )
            applySteamClientVtableOverride(
                appId: appId,
                settingsDir: "\(extraction)/steam_settings",
                fm: fm
            )
        }
    }

    private func restoreEmbeddedSteamworksArchives(gameExecutable: String, root: String, fm: FileManager) {
        guard let enumerator = fm.enumerator(atPath: root) else { return }
        var restoredJars: [String] = []
        for case let relative as String in enumerator where relative.hasSuffix(".jar.vessel-orig") {
            let backup = "\(root)/\(relative)"
            let jar = String(backup.dropLast(".vessel-orig".count))
            try? fm.removeItem(atPath: jar)
            if (try? fm.copyItem(atPath: backup, toPath: jar)) != nil { restoredJars.append(jar) }
        }
        guard !restoredJars.isEmpty else { return }
        for archive in embeddedSteamworksArchives(forExecutable: gameExecutable) {
            for tempDir in wineUserTempDirectories(forExecutable: gameExecutable, fileManager: fm) {
                let extraction = "\(tempDir)/steamworks4j/\(archive.version)"
                for name in archive.libraries {
                    try? fm.removeItem(atPath: "\(extraction)/\(name)")
                }
            }
        }
    }

    private func wineUserTempDirectories(forExecutable executable: String, fileManager fm: FileManager) -> [String] {
        let marker = "/drive_c/"
        guard let range = executable.range(of: marker, options: .caseInsensitive) else { return [] }
        let prefix = String(executable[..<range.lowerBound])
        let usersRoot = "\(prefix)/drive_c/users"
        let ignored = Set(["public", "default", "default user", "all users"])
        var result: [String] = []
        if let users = try? fm.contentsOfDirectory(atPath: usersRoot) {
            for user in users where !ignored.contains(user.lowercased()) {
                let userDir = "\(usersRoot)/\(user)"
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: userDir, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                result.append("\(userDir)/Temp")
            }
        }
        if result.isEmpty {
            result.append("\(usersRoot)/\(NSUserName())/Temp")
        }
        return result
    }

    private func archiveEntryData(archive: String, entry: String) -> Data? {
        runTool("/usr/bin/unzip", arguments: ["-p", archive, entry])
    }

    private func runTool(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    /// Reemplaza un DLL del juego por el de Goldberg. Respalda el original una sola
    /// vez. Si el DLL del juego ya coincide en tamaño con el de Goldberg, asume que
    /// ya está aplicado y no hace nada.
    private func replaceDLL(at gamePath: String, with goldbergPath: String, fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: goldbergPath), fm.fileExists(atPath: gamePath) else { return false }
        let goldbergSize = (try? fm.attributesOfItem(atPath: goldbergPath)[.size] as? UInt64) ?? 0
        let gameSize = (try? fm.attributesOfItem(atPath: gamePath)[.size] as? UInt64) ?? 0
        if gameSize == goldbergSize { return true } // ya es Goldberg
        let backup = "\(gamePath).vessel-orig"
        if !fm.fileExists(atPath: backup) {
            try? fm.copyItem(atPath: gamePath, toPath: backup)
        }
        try? fm.removeItem(atPath: gamePath)
        do {
            try fm.copyItem(atPath: goldbergPath, toPath: gamePath)
            return true
        } catch {
            return false
        }
    }

    /// Genera `steam_settings/steam_interfaces.txt` extrayendo TODAS las versiones de interfaz
    /// Steamworks del `steam_api(64).dll` **ORIGINAL** del juego (tanto las CamelCase tipo
    /// `SteamClient017`/`SteamUser018` como las UPPERCASE `STEAMXXX_INTERFACE_VERSIONNNN`).
    ///
    /// Es IMPRESCINDIBLE, al contrario de lo que asumíamos: gbe_fork usa este archivo para
    /// exponer la vtable de la **versión EXACTA** de `ISteamClient` que el juego espera. Si falta
    /// la línea `SteamClientNNN` correcta, gbe_fork expone su vtable por defecto (más nueva) y los
    /// slots se desalinean → el juego pide una interfaz por el slot equivocado (p. ej. CaveBlazers
    /// pedía `STEAMUNIFIEDMESSAGES` a través de `GetISteamController`) → diálogo modal fatal
    /// "Missing interface" que congela y mata el juego. gbe_fork NO autodetecta esto.
    ///
    /// Replica en Swift lo que hace el `generate_interfaces` oficial. Si el DLL ya fue reemplazado
    /// por Goldberg (~20 MB), lee del respaldo `.vessel-orig`; nunca extrae del propio Goldberg.
    private func generateSteamInterfaces(fromDLL dll: String, intoSettingsDir settingsDir: String, fm: FileManager) {
        // Elegir el DLL ORIGINAL real. El de Goldberg contiene TODAS las versiones (las más nuevas):
        // extraer de él reintroduciría justo la desalineación de vtable que queremos evitar.
        let backup = "\(dll).vessel-orig"
        let source: String
        if fm.fileExists(atPath: backup) {
            source = backup
        } else if fm.fileExists(atPath: dll) {
            let attrs = try? fm.attributesOfItem(atPath: dll)
            let sz = (attrs?[.size] as? UInt64) ?? 0
            if sz > 5_000_000 { return } // es Goldberg, no el original → sin fuente fiable
            source = dll
        } else {
            return
        }
        guard let data = fm.contents(atPath: source),
              let text = String(bytes: data, encoding: .isoLatin1) else { return }
        // Prefijos de interfaz conocidos; los más largos primero para el alternador del regex
        // (p. ej. `SteamMatchMakingServers` debe intentarse antes que `SteamMatchMaking`).
        let camel = [
            "SteamMatchMakingServers", "SteamMatchMaking",
            "SteamGameServerStats", "SteamGameServer",
            "SteamNetworkingUtils", "SteamNetworkingMessages", "SteamNetworkingSockets", "SteamNetworking",
            "SteamMasterServerUpdater", "SteamRemoteStorage", "SteamRemotePlay",
            "SteamMusicRemote", "SteamMusic", "SteamParentalSettings", "SteamGameSearch",
            "SteamHTMLSurface", "SteamScreenshots", "SteamController", "SteamInventory", "SteamUserStats",
            "SteamClient", "SteamUser", "SteamFriends", "SteamUtils", "SteamApps",
            "SteamHTTP", "SteamUGC", "SteamAppList", "SteamVideo", "SteamInput", "SteamParties",
        ].joined(separator: "|")
        let pattern = "(?:\(camel))[0-9]{3}|STEAM[A-Z]+_INTERFACE_VERSION[0-9]{3}"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = text as NSString
        var found = Set<String>()
        rx.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m = m { found.insert(ns.substring(with: m.range)) }
        }
        guard !found.isEmpty else { return }
        try? fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
        let content = found.sorted().joined(separator: "\n") + "\n"
        try? content.write(toFile: "\(settingsDir)/steam_interfaces.txt", atomically: true, encoding: .utf8)
    }

    /// Escribe `steam_settings/` junto al exe con un usuario por defecto (+ desactiva los diálogos
    /// de warning de gbe_fork, que son modales y bloquean el hilo del juego).
    private func writeSteamSettings(
        inDir dir: String,
        appId: String,
        accountName: String,
        buildID: String?
    ) {
        let settingsDir = "\(dir)/steam_settings"
        try? FileManager.default.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
        let userIni = """
        [user::general]
        account_name=\(accountName)
        language=spanish
        ip_country=ES
        """
        try? userIni.write(toFile: "\(settingsDir)/configs.user.ini", atomically: true, encoding: .utf8)
        // Desactivar los diálogos de aviso de gbe_fork: son `MessageBox` modales que congelan el
        // hilo del juego (el usuario no los ve venir y el juego parece colgado). Sin red (offline).
        let mainIni = """
        [main::misc]
        disable_warning_any=1
        disable_warning_bad_appid=1
        disable_warning_local_save=1

        [main::connectivity]
        disable_networking=1
        offline=1
        """
        try? mainIni.write(toFile: "\(settingsDir)/configs.main.ini", atomically: true, encoding: .utf8)
        if let buildID {
            writeBranchesSettings(in: settingsDir, buildID: buildID)
        }
    }

    /// gbe_fork moderno obtiene `GetAppBuildId()` de la rama seleccionada en `branches.json`.
    /// La antigua clave `build_id` de `configs.app.ini` está deprecada y se ignora. Se conserva
    /// cualquier rama ya configurada y solo se crea o actualiza la rama pública instalada.
    private func writeBranchesSettings(in settingsDir: String, buildID: String) {
        guard let numericBuildID = UInt32(buildID), numericBuildID > 0 else { return }
        let fm = FileManager.default
        let branchesURL = URL(fileURLWithPath: settingsDir, isDirectory: true)
            .appendingPathComponent("branches.json")

        var branches: [[String: Any]] = []
        if let data = try? Data(contentsOf: branchesURL),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            branches = decoded
        }

        if let index = branches.firstIndex(where: {
            ($0["name"] as? String)?.caseInsensitiveCompare("public") == .orderedSame
        }) {
            branches[index]["build_id"] = Int(numericBuildID)
        } else {
            branches.append([
                "name": "public",
                "description": "",
                "protected": false,
                "build_id": Int(numericBuildID),
            ])
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: branches,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: branchesURL, options: .atomic)
        }

        // Limpiar solo el archivo mínimo que escribió la primera implementación de Vessel. No se
        // toca ningún `configs.app.ini` con ajustes adicionales del usuario.
        let legacyConfig = "\(settingsDir)/configs.app.ini"
        if let contents = try? String(contentsOfFile: legacyConfig, encoding: .utf8) {
            let meaningfulLines = contents.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if meaningfulLines.count == 2,
               meaningfulLines[0].caseInsensitiveCompare("[app::general]") == .orderedSame,
               meaningfulLines[1].lowercased().hasPrefix("build_id=") {
                try? fm.removeItem(atPath: legacyConfig)
            }
        }
    }

    /// Fuerza la versión de vtable de ISteamClient que gbe_fork expone, para juegos con
    /// runtimes antiguos (ver `steamClientVtableOverride`). Reescribe las líneas
    /// `SteamClientNNN` del `steam_interfaces.txt` del juego dejando solo la versión
    /// pedida, y garantiza la línea STEAMUNIFIEDMESSAGES (el runtime la pide por nombre).
    /// Aislado por appId: no cambia el archivo de ningún otro juego.
    private func applySteamClientVtableOverride(appId: String, settingsDir: String, fm: FileManager) {
        guard let version = Self.steamClientVtableOverride[appId] else { return }
        let path = "\(settingsDir)/steam_interfaces.txt"
        var lines = (try? String(contentsOfFile: path, encoding: .utf8))?
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("SteamClient") } ?? []
        if !lines.contains("STEAMUNIFIEDMESSAGES_INTERFACE_VERSION001") {
            lines.append("STEAMUNIFIEDMESSAGES_INTERFACE_VERSION001")
        }
        lines.append(version)
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
