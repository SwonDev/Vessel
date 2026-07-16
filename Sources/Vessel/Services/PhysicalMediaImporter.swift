import Foundation

/// **Medio físico**: instalar juegos desde un **disco** o una **imagen ISO**, y **preservar** un disco
/// como ISO antes de que se raye, se pierda o el formato desaparezca.
///
/// Por qué está aquí: un juego en disco es el DRM‑free original — lo compraste, es tuyo, y no depende
/// de que ninguna tienda siga existiendo. Con la industria retirando el formato físico, poder **volcar
/// tu disco a una imagen** y **reinstalarlo cuando quieras** es justo lo que hace de Vessel un bastión.
///
/// macOS monta ISO9660/UDF de forma nativa (`hdiutil`), así que no hace falta ninguna dependencia:
/// se monta la imagen en solo lectura, se localiza el instalador y se ejecuta en el bottle con Wine.
///
/// ⚠️ Los DRM de disco de la época (SafeDisc, SecuROM, StarForce, TAGES) usan **drivers ring‑0** y son
/// imposibles en macOS — `DRMAnalyzer` los detecta y avisa con honestidad en vez de fallar sin más.
actor PhysicalMediaImporter {
    static let shared = PhysicalMediaImporter()

    enum MediaError: LocalizedError {
        case mountFailed(String), noInstaller, ripFailed(Int32), notADisc
        var errorDescription: String? {
            switch self {
            case .mountFailed(let m): return "No se pudo montar la imagen: \(m)"
            case .noInstaller: return "No se encontró ningún instalador (setup.exe) en el disco."
            case .ripFailed(let c): return "El volcado del disco falló (código \(c))."
            case .notADisc: return "Eso no parece un disco ni una imagen de disco."
            }
        }
    }

    /// Un volumen montado (disco real o imagen), listo para instalar desde él.
    struct Media: Sendable {
        let mountPoint: String
        /// Dispositivo asociado (para desmontar la imagen). `nil` si es un disco físico ya montado.
        let device: String?
        let isImage: Bool
    }

    // MARK: - Montar / desmontar

    /// Monta una imagen (`.iso`, `.img`, `.cue/.bin` no) en **solo lectura** y sin salir en el Finder.
    func mount(imageAt path: String) async throws -> Media {
        let (out, code) = await Self.run("/usr/bin/hdiutil",
                                         ["attach", "-nobrowse", "-readonly", "-plist", path])
        guard code == 0 else { throw MediaError.mountFailed(out.isEmpty ? "hdiutil exit \(code)" : out) }
        // El plist trae las entradas del sistema: nos quedamos con la que tiene punto de montaje.
        guard let mount = Self.firstMountPoint(inPlist: out) else {
            throw MediaError.mountFailed("la imagen no expone ningún volumen")
        }
        return Media(mountPoint: mount.path, device: mount.device, isImage: true)
    }

    /// Desmonta lo que se montó (best‑effort: nunca revienta el flujo).
    func unmount(_ media: Media) async {
        guard media.isImage else { return }
        _ = await Self.run("/usr/bin/hdiutil", ["detach", media.device ?? media.mountPoint, "-quiet"])
    }

    /// Volúmenes que parecen **discos de juego** ya montados (CD/DVD o imágenes). Se reconocen porque
    /// son de solo lectura y traen `autorun.inf` o un instalador en la raíz.
    nonisolated static func mountedGameDiscs() -> [String] {
        let fm = FileManager.default
        guard let vols = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return [] }
        return vols.compactMap { name -> String? in
            let path = "/Volumes/\(name)"
            guard let items = try? fm.contentsOfDirectory(atPath: path) else { return nil }
            let lower = Set(items.map { $0.lowercased() })
            let looksLikeGame = lower.contains("autorun.inf")
                || lower.contains(where: { $0.hasPrefix("setup") && $0.hasSuffix(".exe") })
            return looksLikeGame ? path : nil
        }
    }

    // MARK: - Instalador del disco

    /// Localiza el instalador del disco. Prioridad: lo que diga `autorun.inf` (es LA fuente oficial
    /// del propio disco) y, si no, la heurística habitual de nombres en la raíz.
    nonisolated static func findInstaller(in mountPoint: String) -> String? {
        let fm = FileManager.default
        // 1) autorun.inf → `open=setup.exe` (a veces con argumentos o rutas con backslash).
        for name in ["autorun.inf", "AUTORUN.INF", "Autorun.inf"] {
            let p = "\(mountPoint)/\(name)"
            guard let raw = try? String(contentsOfFile: p, encoding: .isoLatin1) else { continue }
            for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.lowercased().hasPrefix("open=") || t.lowercased().hasPrefix("shellexecute=") else { continue }
                var value = String(t.drop(while: { $0 != "=" }).dropFirst()).trimmingCharacters(in: .whitespaces)
                // Quitar argumentos y normalizar el separador de Windows.
                if let sp = value.firstIndex(of: " ") { value = String(value[..<sp]) }
                value = value.replacingOccurrences(of: "\\", with: "/")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"/"))
                let candidate = "\(mountPoint)/\(value)"
                if fm.fileExists(atPath: candidate) { return candidate }
            }
        }
        // 2) Heurística: instalador en la raíz.
        guard let items = try? fm.contentsOfDirectory(atPath: mountPoint) else { return nil }
        let exes = items.filter { $0.lowercased().hasSuffix(".exe") }
        for pref in ["setup.exe", "install.exe", "autorun.exe", "start.exe"] {
            if let hit = exes.first(where: { $0.lowercased() == pref }) { return "\(mountPoint)/\(hit)" }
        }
        return exes.first.map { "\(mountPoint)/\($0)" }
    }

    // MARK: - Preservar el disco

    /// **Vuelca un disco a una imagen ISO**: tu disco pasa a ser un fichero que conservas para siempre
    /// (y desde el que puedes reinstalar aunque el disco se raye o no tengas lector). `device` es el
    /// dispositivo (`/dev/diskN`); `dest` la ruta destino del `.iso`.
    ///
    /// Usa `hdiutil makehybrid`, que produce una ISO estándar (UDF+ISO9660) legible en cualquier sitio.
    func ripDiscToISO(mountPoint: String, dest: String,
                      progress: @Sendable @escaping (String) -> Void = { _ in }) async throws -> String {
        progress("Volcando el disco a una imagen… (puede tardar)")
        let out = dest.hasSuffix(".iso") ? dest : dest + ".iso"
        try? FileManager.default.removeItem(atPath: out)
        let (log, code) = await Self.run("/usr/bin/hdiutil",
                                         ["makehybrid", "-iso", "-udf", "-o", out, mountPoint])
        guard code == 0, FileManager.default.fileExists(atPath: out) else {
            throw MediaError.ripFailed(code == 0 ? -1 : code)
        }
        _ = log
        progress("Imagen creada")
        return out
    }

    // MARK: - Internos

    /// Primer volumen con punto de montaje del plist de `hdiutil attach`.
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
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return (error.localizedDescription, -1) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let edata = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8) ?? ""
        return (s.isEmpty ? (String(data: edata, encoding: .utf8) ?? "") : s, p.terminationStatus)
    }
}
