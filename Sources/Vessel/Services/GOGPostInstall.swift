import Foundation

/// **Post-instalación de GOG.** Cuando instalas un juego con el instalador oficial de GOG (o con
/// Galaxy), además de copiar los ficheros se ejecuta un `goggame-<id>.script` que **genera parte
/// del juego**: los `.ini`/`.conf` de configuración, las carpetas de partidas y algunas claves de
/// registro que el juego lee al arrancar.
///
/// `gogdl` (el backend de descarga, el mismo que usa Heroic) **descarga los ficheros pero NO
/// ejecuta ese script**. El resultado es silencioso y desconcertante: el juego queda "instalado",
/// pero al lanzarlo se cierra al instante porque le falta su configuración.
///
/// Se vio con *Beneath a Steel Sky*: su playTask es `ScummVM\scummvm.exe -c "..\beneath.ini" beneath`
/// y `beneath.ini` **no existía** — lo crea este script con cinco acciones `setIni`. Afecta a buena
/// parte del catálogo clásico de GOG (DOSBox/ScummVM), que es justo lo más DRM-free que hay: juegos
/// que ya nadie más va a mantener.
///
/// Es idempotente (marca `.vessel-postinstall`) y sirve tanto al instalar como de **auto-reparación**
/// de lo ya instalado antes de que esto existiera.
@MainActor
enum GOGPostInstall {
    /// Marcador de que el script ya se aplicó (con su versión, por si se amplían las acciones).
    static let markerName = ".vessel-postinstall"
    private static let version = "v1"

    struct Report {
        var applied: [String] = []      // acciones ejecutadas
        var skipped: [String] = []      // acciones que aún no sabemos hacer (se dicen, no se ocultan)
        var isEmpty: Bool { applied.isEmpty && skipped.isEmpty }
    }

    /// Aplica el script de post-instalación si hace falta. `root` = carpeta REAL del juego,
    /// `prefix` = prefijo de Wine (para el registro y para calcular la ruta Windows del juego).
    @discardableResult
    static func applyIfNeeded(appId: String, root: String, prefix: String, winePath: String) async -> Report {
        let marker = "\(root)/\(markerName)"
        if let done = try? String(contentsOfFile: marker, encoding: .utf8),
           done.trimmingCharacters(in: .whitespacesAndNewlines) == version { return Report() }
        let report = await apply(appId: appId, root: root, prefix: prefix, winePath: winePath)
        try? version.write(toFile: marker, atomically: true, encoding: .utf8)
        return report
    }

    /// Ejecuta las acciones `install` del `goggame-<id>.script`.
    static func apply(appId: String, root: String, prefix: String, winePath: String) async -> Report {
        var report = Report()
        let scriptPath = "\(root)/goggame-\(appId).script"
        guard let data = FileManager.default.contents(atPath: scriptPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actions = obj["actions"] as? [[String: Any]] else { return report }

        // `{app}` en los VALORES es la ruta del juego **como la ve Windows** (el juego la escribe en
        // su .ini y luego la abre desde dentro de Wine), no la de macOS.
        let appWindows = windowsPath(for: root, prefix: prefix)

        // PRIMERO los ficheros de soporte: son la BASE sobre la que los `setIni` escriben después.
        for copied in copySupportFiles(root: root, appId: appId) { report.applied.append("copiado \(copied)") }

        for action in actions {
            guard let install = action["install"] as? [String: Any],
                  let kind = install["action"] as? String else { continue }
            let args = (install["arguments"] as? [String: Any]) ?? [:]
            switch kind {
            case "setIni":
                if applySetIni(args, root: root, appId: appId, appWindows: appWindows) {
                    report.applied.append("setIni \(expand((args["filename"] as? String) ?? "", appId: appId, app: appWindows))")
                }
            case "setRegistry":
                if await applySetRegistry(args, appId: appId, appWindows: appWindows,
                                          prefix: prefix, winePath: winePath) {
                    report.applied.append("setRegistry \(expand((args["subkey"] as? String) ?? "", appId: appId, app: appWindows))")
                }
            case "supportData":
                if applySupportData(args, root: root, appId: appId, appWindows: appWindows) {
                    report.applied.append("carpeta \(expand((args["target"] as? String) ?? "", appId: appId, app: appWindows))")
                }
            default:
                // Nada de fingir: si aparece una acción que no cubrimos, se dice en el log en vez
                // de dejar el juego medio instalado sin explicación.
                report.skipped.append(kind)
            }
        }
        if !report.isEmpty {
            LogStore.shared.log(
                "GOG post-instalación (\(appId)): \(report.applied.count) acción(es) aplicadas"
                + (report.skipped.isEmpty ? "" : " · sin cubrir: \(Set(report.skipped).sorted().joined(separator: ", "))"),
                level: report.skipped.isEmpty ? .info : .warn)
        }
        return report
    }

    // MARK: - Acciones

    /// **Ficheros de configuración base.** GOG empaqueta en `gog-support/<productID>/app/` la
    /// configuración de partida del juego: el `.ini` de ScummVM (con su `gameid`, sin el cual
    /// ScummVM responde *"Unrecognized game target"* y no arranca) o los `.conf` de DOSBox que el
    /// propio playTask exige con `-conf`. Su instalador los copia a la raíz del juego y **después**
    /// les aplica los `setIni` encima. `gogdl` se los descarga pero no los copia — por eso el juego
    /// quedaba instalado y no arrancaba, sin decir por qué.
    ///
    /// No se pisa nada que ya exista: si el usuario ha tocado su configuración, manda la suya.
    private static func copySupportFiles(root: String, appId: String) -> [String] {
        let fm = FileManager.default
        // La subcarpeta `app` es la que mapea a `{app}` (la raíz del juego).
        let source = "\(root)/gog-support/\(appId)/app"
        guard let items = try? fm.contentsOfDirectory(atPath: source) else { return [] }
        var copied: [String] = []
        for item in items {
            let dest = "\(root)/\(item)"
            guard !fm.fileExists(atPath: dest) else { continue }
            if (try? fm.copyItem(atPath: "\(source)/\(item)", toPath: dest)) != nil { copied.append(item) }
        }
        return copied
    }

    private static func applySetIni(_ args: [String: Any], root: String, appId: String, appWindows: String) -> Bool {
        guard let rawFile = args["filename"] as? String,
              let section = args["keyName"] == nil ? nil : (args["section"] as? String) ?? "",
              let key = args["keyName"] as? String else { return false }
        let value = expand(stringValue(args["keyValue"]), appId: appId, app: appWindows)
        // La ruta del FICHERO sí es de macOS (lo escribimos nosotros desde fuera de Wine).
        let file = localPath(expand(rawFile, appId: appId, app: appWindows), root: root, appWindows: appWindows)
        // `utf8: false` (lo normal en los clásicos) → Latin-1, que es lo que esperan.
        let useUTF8 = (args["utf8"] as? Bool) ?? true
        return IniFile.set(file: file, section: section, key: key, value: value, utf8: useUTF8)
    }

    private static func applySetRegistry(_ args: [String: Any], appId: String, appWindows: String,
                                         prefix: String, winePath: String) async -> Bool {
        guard let rawSubkey = args["subkey"] as? String else { return false }
        let root = normalizeHive((args["root"] as? String) ?? "HKEY_LOCAL_MACHINE")
        let subkey = expand(rawSubkey, appId: appId, app: appWindows)
        var cmd = ["reg", "add", "\(root)\\\(subkey)"]
        // Puede venir SIN valor: entonces solo se crea la clave (War Wind hace justo eso).
        if let name = args["valueName"] as? String, !name.isEmpty {
            let data = expand(stringValue(args["valueData"]), appId: appId, app: appWindows)
            cmd += ["/v", name, "/t", registryType((args["valueType"] as? String) ?? "string"), "/d", data]
        }
        cmd.append("/f")
        return await runWine(winePath, cmd, prefix: prefix)
    }

    private static func applySupportData(_ args: [String: Any], root: String, appId: String, appWindows: String) -> Bool {
        // Solo carpetas: es lo que usan los juegos para su directorio de partidas. Otros tipos
        // (ficheros de soporte) los copia ya el propio depot de gogdl.
        guard (args["type"] as? String) == "folder", let rawTarget = args["target"] as? String else { return false }
        let dir = localPath(expand(rawTarget, appId: appId, app: appWindows), root: root, appWindows: appWindows)
        guard !dir.isEmpty, dir != root else { return false }
        return (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil
    }

    // MARK: - Rutas y plantillas

    /// Sustituye las plantillas de GOG. `{app}` = carpeta del juego, `{productID}` = appId.
    private static func expand(_ s: String, appId: String, app: String) -> String {
        s.replacingOccurrences(of: "{app}", with: app)
         .replacingOccurrences(of: "{productID}", with: appId)
         .replacingOccurrences(of: "{productId}", with: appId)
    }

    /// Ruta de macOS a partir de una ruta ya expandida que puede venir en formato Windows
    /// (`C:\Games\…\beneath.ini`) o relativa a `{app}`.
    private static func localPath(_ expanded: String, root: String, appWindows: String) -> String {
        var s = expanded
        // Lo más habitual: `{app}\algo` → ya expandido a `<appWindows>\algo`. Se re-ancla al root real.
        if s.hasPrefix(appWindows) {
            let tail = String(s.dropFirst(appWindows.count))
            s = root + tail.replacingOccurrences(of: "\\", with: "/")
        } else {
            s = s.replacingOccurrences(of: "\\", with: "/")
            if !s.hasPrefix("/") { s = "\(root)/\(s)" }
        }
        while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
        return s
    }

    /// Ruta **Windows** de una carpeta del prefijo: `<prefix>/drive_c/X/Y` → `C:\X\Y`. Es determinista
    /// (no hace falta llamar a `winepath`) porque `drive_c` SIEMPRE es `C:` en un prefijo de Wine.
    static func windowsPath(for path: String, prefix: String) -> String {
        let driveC = "\(prefix)/drive_c/"
        guard path.hasPrefix(driveC) else {
            // Fuera de `drive_c` Wine lo ve por la unidad Z: (raíz del sistema de ficheros).
            return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
        }
        let rel = String(path.dropFirst(driveC.count)).replacingOccurrences(of: "/", with: "\\")
        return "C:\\" + rel
    }

    private static func normalizeHive(_ h: String) -> String {
        switch h.uppercased() {
        case "HKLM", "HKEY_LOCAL_MACHINE": return "HKLM"
        case "HKCU", "HKEY_CURRENT_USER": return "HKCU"
        case "HKCR", "HKEY_CLASSES_ROOT": return "HKCR"
        case "HKU", "HKEY_USERS": return "HKU"
        default: return h.uppercased()
        }
    }

    private static func registryType(_ t: String) -> String {
        switch t.lowercased() {
        case "dword": return "REG_DWORD"
        case "binary": return "REG_BINARY"
        case "expandString", "expandstring": return "REG_EXPAND_SZ"
        default: return "REG_SZ"
        }
    }

    /// Los valores del script pueden venir como texto o como número (`"keyValue": 0`).
    private static func stringValue(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case let n as Int: return String(n)
        case let b as Bool: return b ? "1" : "0"
        case let d as Double: return String(Int(d))
        default: return ""
        }
    }

    @discardableResult
    private static func runWine(_ winePath: String, _ args: [String], prefix: String) async -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: winePath)
        p.arguments = args
        p.environment = ["WINEPREFIX": prefix, "WINEDEBUG": "-all",
                         "WINEDLLOVERRIDES": "winedbg.exe=d"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return false }
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// Lector/escritor mínimo de ficheros `.ini` estilo Windows, para las acciones `setIni` de GOG.
/// Hace read-modify-write conservando el resto del fichero: varias acciones escriben claves
/// distintas en secciones distintas del MISMO `.ini`, y no pueden pisarse entre ellas.
enum IniFile {
    static func set(file: String, section: String, key: String, value: String, utf8: Bool) -> Bool {
        let encoding: String.Encoding = utf8 ? .utf8 : .isoLatin1
        var lines: [String] = []
        if let existing = try? String(contentsOfFile: file, encoding: encoding), !existing.isEmpty {
            lines = existing.components(separatedBy: .newlines)
        }
        let header = "[\(section)]"
        var sectionStart: Int? = nil, sectionEnd = lines.count
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if sectionStart == nil {
                if t.caseInsensitiveCompare(header) == .orderedSame { sectionStart = i }
            } else if t.hasPrefix("[") && t.hasSuffix("]") {
                sectionEnd = i; break
            }
        }
        let entry = "\(key)=\(value)"
        if let start = sectionStart {
            // ¿Ya existe la clave en la sección? → se sustituye; si no, se añade al final de ella.
            for i in (start + 1)..<sectionEnd {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                guard let eq = t.firstIndex(of: "="), !t.hasPrefix(";"), !t.hasPrefix("#") else { continue }
                if t[..<eq].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame {
                    lines[i] = entry
                    return write(lines, to: file, encoding: encoding)
                }
            }
            // Se inserta tras la ÚLTIMA línea con contenido de la sección: si no, la clave nueva
            // caería detrás de la línea en blanco que separa de la sección siguiente.
            var insertAt = sectionEnd
            while insertAt > start + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert(entry, at: insertAt)
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append(header)
            lines.append(entry)
        }
        return write(lines, to: file, encoding: encoding)
    }

    private static func write(_ lines: [String], to file: String, encoding: String.Encoding) -> Bool {
        let text = lines.joined(separator: "\n")
        guard let data = text.data(using: encoding, allowLossyConversion: true) else { return false }
        try? FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return (try? data.write(to: URL(fileURLWithPath: file), options: .atomic)) != nil
    }
}
