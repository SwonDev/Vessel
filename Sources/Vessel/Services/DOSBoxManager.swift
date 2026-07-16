import Foundation

/// **DOSBox NATIVO (arm64) para los juegos de DOS.**
///
/// Un juego de DOS no necesita Windows. GOG lo envuelve en un DOSBox **para Windows** porque su
/// tienda vende a usuarios de Windows — pero eso, en un Mac, obliga a la cadena absurda
/// *DOS → DOSBox de Windows → Wine → Rosetta*, y ahí se rompe: el DOSBox 0.74-2 de GOG usa **SDL 1.2**,
/// que bajo este Wine en Apple Silicon **no consigue crear ventana con NINGUNA de sus salidas**
/// (`surface`, `overlay`, `opengl`, `openglnb`, `ddraw`: todas negras — comprobado una a una).
///
/// La solución no es pelearse con eso: es **saltarse las dos capas**. Vessel ejecuta el juego con
/// **DOSBox Staging nativo de macOS** (universal, arm64), usando el `.conf` que el propio GOG
/// instaló. El resultado es mejor que en Windows: sin Wine, sin Rosetta, con vídeo y sonido nativos.
/// Verificado en vivo: *Akalabeth: World of Doom* (1979) renderiza su VGA 320×200.
///
/// Es el mismo patrón que ya usa Vessel con `gogdl`/`legendary`: binario auto-descargable, aislado
/// en `Engines/`, sin tocar nada del sistema.
@MainActor
@Observable
final class DOSBoxManager {
    static let shared = DOSBoxManager()

    /// Versión FIJADA a propósito (como el resto de dependencias): actualizarla es una decisión,
    /// no algo que pase solo a espaldas del usuario.
    static let version = "v0.82.2"

    static let dosboxDir  = "\(VesselPaths.enginesDirectory)/dosbox-staging"
    static let appPath    = "\(dosboxDir)/DOSBox Staging.app"
    static let binaryPath = "\(appPath)/Contents/MacOS/dosbox"
    private static let markerPath = "\(dosboxDir)/.vessel-version"

    /// `.dmg` oficial del proyecto (GPL-2.0, https://dosbox-staging.github.io). ~10 MB.
    private static var downloadURL: URL {
        URL(string: "https://github.com/dosbox-staging/dosbox-staging/releases/download/\(version)/dosbox-staging-macOS-\(version).dmg")!
    }

    private let log = LogStore.shared
    private let fm = FileManager.default

    enum DOSBoxError: LocalizedError {
        case downloadFailed, mountFailed(String), notFound
        var errorDescription: String? {
            switch self {
            case .downloadFailed: return "No se pudo descargar DOSBox."
            case .mountFailed(let m): return "No se pudo abrir la imagen de DOSBox: \(m)"
            case .notFound: return "No se encontró el ejecutable de DOSBox tras instalarlo."
            }
        }
    }

    var isInstalled: Bool {
        fm.isExecutableFile(atPath: Self.binaryPath)
            && (try? String(contentsOfFile: Self.markerPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == Self.version
    }

    /// Descarga e instala DOSBox nativo si falta (idempotente). Devuelve la ruta del binario.
    @discardableResult
    func ensureInstalled(progress: @escaping (String) -> Void = { _ in }) async throws -> String {
        if isInstalled { return Self.binaryPath }
        progress("Descargando DOSBox nativo…")
        log.log("DOSBox nativo: descargando \(Self.version)…", level: .info)
        try fm.createDirectory(atPath: Self.dosboxDir, withIntermediateDirectories: true)

        let dmg = "\(Self.dosboxDir)/dosbox.dmg"
        let (tmp, response) = try await URLSession.shared.download(from: Self.downloadURL)
        guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false else {
            throw DOSBoxError.downloadFailed
        }
        try? fm.removeItem(atPath: dmg)
        try fm.moveItem(at: tmp, to: URL(fileURLWithPath: dmg))

        progress("Instalando DOSBox…")
        // Montar en solo lectura y sin salir en el Finder; se copia el `.app` fuera y se desmonta.
        let (out, code) = await Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-plist", dmg])
        guard code == 0, let mount = Self.firstMountPoint(inPlist: out) else {
            throw DOSBoxError.mountFailed(out.isEmpty ? "hdiutil exit \(code)" : String(out.prefix(200)))
        }
        defer { Task { _ = await Self.run("/usr/bin/hdiutil", ["detach", mount.device, "-quiet"]) } }

        guard let src = (try? fm.contentsOfDirectory(atPath: mount.path))?
                .first(where: { $0.hasSuffix(".app") }) else {
            throw DOSBoxError.notFound
        }
        try? fm.removeItem(atPath: Self.appPath)
        // `ditto` conserva la firma del bundle (un `cp` puede romperla y Gatekeeper lo bloquearía).
        let (cpOut, cpCode) = await Self.run("/usr/bin/ditto", ["\(mount.path)/\(src)", Self.appPath])
        guard cpCode == 0 else { throw DOSBoxError.mountFailed(cpOut) }

        // Viene de una descarga → sin esto macOS lo bloquea (igual que con los motores Wine).
        _ = await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", Self.appPath])
        try? fm.removeItem(atPath: dmg)
        guard fm.isExecutableFile(atPath: Self.binaryPath) else { throw DOSBoxError.notFound }
        try? Self.version.write(toFile: Self.markerPath, atomically: true, encoding: .utf8)
        log.log("DOSBox nativo \(Self.version) instalado (arm64, sin Wine).", level: .info)
        return Self.binaryPath
    }

    // MARK: - Traducción de la config de GOG

    /// Adapta un `.conf` de GOG (escrito para el DOSBox **de Windows**) al DOSBox nativo.
    ///
    /// Lo único que hay que tocar de verdad son las **rutas del `[autoexec]`**: GOG las escribe con
    /// barra invertida (`mount C "..\cloud_saves"`), que en macOS no existe. El resto de la config
    /// (ciclos, memoria, tarjeta de sonido, el juego que se ejecuta) se respeta TAL CUAL: es la que
    /// el propio GOG afinó para ese juego, y DOSBox Staging ignora con un aviso lo que ya no usa.
    ///
    /// El resultado se escribe en la caché de Vessel, NO en la carpeta del juego: así la copia
    /// DRM‑free que el usuario exporta a un USB sigue siendo exactamente la de GOG.
    nonisolated static func translatedConf(from originalPath: String, appId: String) -> String? {
        guard let raw = try? String(contentsOfFile: originalPath, encoding: .isoLatin1) else { return nil }
        var out: [String] = []
        var inAutoexec = false
        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasPrefix("[") { inAutoexec = (t == "[autoexec]") }
            // Solo se tocan las rutas del autoexec; en el resto una `\` puede ser otra cosa.
            out.append(inAutoexec ? line.replacingOccurrences(of: "\\", with: "/") : line)
        }
        let dir = "\(VesselPaths.cacheDirectory)/dosbox"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let name = (originalPath as NSString).lastPathComponent
        let dest = "\(dir)/\(appId)-\(name)"
        guard (try? out.joined(separator: "\n").write(toFile: dest, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        return dest
    }

    /// Traduce los argumentos del playTask de GOG a los del DOSBox nativo.
    ///
    /// - `-conf "..\x.conf"` → la ruta absoluta del `.conf` ya traducido.
    /// - `-noconsole` se **descarta**: es exclusivo del DOSBox 0.74 de Windows; el nativo lo
    ///   rechazaría y no arrancaría.
    /// - `-c exit` se conserva (cierra DOSBox cuando el juego termina, que es lo que quiere GOG).
    nonisolated static func nativeArguments(from args: [String], gameRoot: String, appId: String) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a.lowercased() {
            case "-noconsole", "--noconsole":
                i += 1                                  // no existe en el nativo
            case "-conf", "--conf":
                guard i + 1 < args.count else { i += 1; continue }
                let rel = args[i + 1].replacingOccurrences(of: "\\", with: "/")
                // Las rutas del playTask son relativas a la carpeta del exe (`…/DOSBOX`).
                let original = URL(fileURLWithPath: "\(gameRoot)/DOSBOX/\(rel)").standardizedFileURL.path
                if let translated = translatedConf(from: original, appId: appId) {
                    out += ["-conf", translated]
                }
                i += 2
            default:
                out.append(a); i += 1
            }
        }
        // Ignorar la config GLOBAL del usuario (~/.config/dosbox): el juego debe correr con lo que
        // GOG afinó para él, no con lo que alguien tenga puesto por ahí.
        out.append("-noprimaryconf")
        return out
    }

    // MARK: - Internos

    private static func firstMountPoint(inPlist plist: String) -> (device: String, path: String)? {
        guard let data = plist.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        for e in entities {
            if let mp = e["mount-point"] as? String, !mp.isEmpty {
                return ((e["dev-entry"] as? String) ?? mp, mp)
            }
        }
        return nil
    }

    private static func run(_ tool: String, _ args: [String]) async -> (String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (error.localizedDescription, -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }
}
