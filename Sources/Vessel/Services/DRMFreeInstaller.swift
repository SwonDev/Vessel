import Foundation

/// Descarga e instala juegos **DRM‑free** (itch.io / Humble) en `VesselPaths.drmFreeDirectory`,
/// un subdirectorio por juego. Soporta descargas con cabeceras (cookie de Humble / clave de itch)
/// y progreso. Extrae `.zip` y localiza el `.exe` principal con heurística; para un `.exe` suelto
/// lo deja en su carpeta (portable) o lo marca como instalador para ejecutarlo en el bottle.
///
/// NUNCA borra fuera de `drmFreeDirectory`. Idempotente por carpeta de juego (re‑descargar
/// reemplaza el contenido).
actor DRMFreeInstaller {
    static let shared = DRMFreeInstaller()

    struct Installed {
        let executablePath: String
        let installDir: String
        /// `true` si el ejecutable parece un instalador (Inno/NSIS/MSI) y no un juego portable.
        let isInstaller: Bool
    }

    enum InstallError: LocalizedError {
        case http(Int)
        case emptyDownload
        case noExecutable
        case extractionFailed(String)
        var errorDescription: String? {
            switch self {
            case .http(let c): return "La descarga falló (HTTP \(c))."
            case .emptyDownload: return "La descarga llegó vacía."
            case .noExecutable: return "No se encontró ningún ejecutable de Windows (.exe) en la descarga."
            case .extractionFailed(let m): return "No se pudo extraer el archivo: \(m)"
            }
        }
    }

    /// Descarga `url` (con `headers`) e instala el juego en una carpeta propia bajo DRMFree/.
    /// `slug` da nombre a la carpeta; `suggestedName` es el nombre a buscar para el exe principal.
    func downloadAndInstall(url: URL, headers: [String: String] = [:], slug: String,
                            suggestedName: String, filenameHint: String? = nil,
                            progress: @Sendable @escaping (Double, String) -> Void) async throws -> Installed {
        progress(0.02, "Preparando descarga…")
        let installDir = "\(VesselPaths.drmFreeDirectory)/\(Self.sanitize(slug))"
        // Descargar a un fichero temporal.
        var req = URLRequest(url: url)
        req.setValue(SteamConstants.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (tempURL, response) = try await Self.downloadWithProgress(req) { frac in
            progress(0.02 + frac * 0.68, "Descargando… \(Int(frac * 100))%")
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw InstallError.http(http.statusCode)
        }
        let dlAttrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path)
        let size = (dlAttrs?[.size] as? Int) ?? 0
        if size < 1 { throw InstallError.emptyDownload }

        // Nombre de fichero real (para saber la extensión): Content-Disposition → hint del upload
        // → última componente de la URL final (tras redirects) → URL original.
        let finalURL = response.url ?? url
        var filename = Self.filename(from: response, fallbackURL: finalURL)
        if (filename as NSString).pathExtension.isEmpty, let hint = filenameHint, !hint.isEmpty {
            filename = hint
        }
        let ext = (filename as NSString).pathExtension.lowercased()

        // Reiniciar la carpeta de instalación.
        try? FileManager.default.removeItem(atPath: installDir)
        try FileManager.default.createDirectory(atPath: installDir, withIntermediateDirectories: true)

        // Nombre de fichero SEGURO: solo la última componente (descarta cualquier `../` o ruta
        // absoluta que venga en Content-Disposition), y confinado a installDir.
        let safeName = Self.safeLeafName(filename, defaultExt: ext.isEmpty ? "bin" : ext)

        progress(0.74, "Instalando…")
        switch ext {
        case "zip":
            try Self.unzip(tempURL, to: installDir)
        case "exe", "msi":
            // .exe/.msi suelto: lo colocamos en la carpeta (portable o instalador), con nombre saneado.
            try Self.safeCopy(tempURL.path, toLeaf: safeName, in: installDir)
        default:
            // Otros contenedores (.7z/.rar) no soportados nativamente por macOS: intentar como zip,
            // y si falla, dejar el fichero (nombre saneado) para que el usuario lo gestione.
            do { try Self.unzip(tempURL, to: installDir) }
            catch { try? Self.safeCopy(tempURL.path, toLeaf: safeName, in: installDir) }
        }
        // Defensa Zip Slip / symlink escape: elimina cualquier entrada cuyo destino real se salga
        // de installDir (un .zip malicioso de itch/Humble podría traer symlinks o `..`).
        Self.enforceContainment(of: installDir)

        progress(0.88, "Buscando el ejecutable…")
        guard let exe = Self.findMainExecutable(in: installDir, suggestedName: suggestedName) else {
            throw InstallError.noExecutable
        }
        // Quitar quarantine del árbol instalado (evita bloqueos de Gatekeeper al pasar por Wine).
        await Self.stripQuarantine(at: installDir)
        progress(1.0, "Listo")
        return Installed(executablePath: exe, installDir: installDir,
                         isInstaller: Self.looksLikeInstaller(exe))
    }

    // MARK: - Descarga con progreso

    private static func downloadWithProgress(_ req: URLRequest,
                                             _ onProgress: @Sendable @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let total = response.expectedContentLength
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vessel-dl-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        var lastReport = Date.distantPast
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {   // volcar cada 1 MB
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let now = Date()
                if total > 0, now.timeIntervalSince(lastReport) > 0.15 {
                    onProgress(min(0.999, Double(received) / Double(total)))
                    lastReport = now
                }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); received += Int64(buffer.count) }
        onProgress(1.0)
        return (tmp, response)
    }

    // MARK: - Extracción / heurísticas

    /// Nombre de fichero seguro: solo la última componente (sin `/`, `\`, `..` ni ruta absoluta).
    private static func safeLeafName(_ filename: String, defaultExt: String) -> String {
        var leaf = (filename as NSString).lastPathComponent
        // `lastPathComponent` ya descarta directorios; por si acaso, quita restos peligrosos.
        leaf = leaf.replacingOccurrences(of: "\\", with: "_")
        if leaf.isEmpty || leaf == "." || leaf == ".." { leaf = "descarga.\(defaultExt)" }
        return leaf
    }

    /// Copia un fichero a `leaf` dentro de `dir`, verificando que el destino NO se sale de `dir`.
    private static func safeCopy(_ srcPath: String, toLeaf leaf: String, in dir: String) throws {
        let dst = URL(fileURLWithPath: dir).appendingPathComponent(leaf).standardizedFileURL
        let base = URL(fileURLWithPath: dir).standardizedFileURL.path
        guard dst.path == base + "/" + leaf || dst.path.hasPrefix(base + "/") else {
            throw InstallError.extractionFailed("nombre de fichero inseguro")
        }
        try FileManager.default.copyItem(atPath: srcPath, toPath: dst.path)
    }

    /// Recorre `dir` y elimina cualquier entrada cuyo destino REAL (resolviendo symlinks) se salga
    /// de `dir` — defensa contra Zip Slip y symlinks que escapan del árbol.
    static func enforceContainment(of dir: String) {
        let fm = FileManager.default
        let baseReal = URL(fileURLWithPath: dir).resolvingSymlinksInPath().standardizedFileURL.path
        guard let en = fm.enumerator(atPath: dir) else { return }
        var toRemove: [String] = []
        while let rel = en.nextObject() as? String {
            let full = "\(dir)/\(rel)"
            // Symlink cuyo destino se sale, o cualquier componente `..`.
            let real = URL(fileURLWithPath: full).resolvingSymlinksInPath().standardizedFileURL.path
            if rel.split(separator: "/").contains("..") || !(real == baseReal || real.hasPrefix(baseReal + "/")) {
                toRemove.append(full)
            }
        }
        for p in toRemove { try? fm.removeItem(atPath: p) }
    }

    private static func unzip(_ archive: URL, to dir: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", archive.path, dir]   // ditto lee zip preservando estructura
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallError.extractionFailed(msg.isEmpty ? "ditto exit \(p.terminationStatus)" : msg)
        }
    }

    /// Localiza el `.exe` de Windows principal: descarta instaladores de dependencias y
    /// desinstaladores; prioriza el que coincide con el nombre del juego y, si no, el más grande.
    static func findMainExecutable(in dir: String, suggestedName: String) -> String? {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return nil }
        let junk = ["unins", "vcredist", "vc_redist", "dxsetup", "dxwebsetup", "directx",
                    "dotnet", "ndp", "oalinst", "uninstall", "crashreport", "crashpad",
                    "python", "setup_", "redist", "notification_helper"]
        var candidates: [(path: String, size: Int64, score: Int)] = []
        let normTarget = suggestedName.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        while let rel = en.nextObject() as? String {
            guard (rel as NSString).pathExtension.lowercased() == "exe" else { continue }
            let base = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            if junk.contains(where: { base.contains($0) }) { continue }
            let full = "\(dir)/\(rel)"
            let attrs = try? fm.attributesOfItem(atPath: full)
            let size = (attrs?[.size] as? Int64) ?? 0
            var score = 0
            let normBase = base.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
            if !normTarget.isEmpty, normBase.contains(normTarget) || normTarget.contains(normBase) { score += 1000 }
            // Menos profundidad = más probable que sea el exe principal (no en subcarpetas de tools).
            let depth = rel.components(separatedBy: "/").count
            score += max(0, 10 - depth)
            candidates.append((full, size, score))
        }
        guard !candidates.isEmpty else { return nil }
        // Mayor score; a igualdad, el más grande.
        return candidates.sorted { ($0.score, $0.size) > ($1.score, $1.size) }.first?.path
    }

    static func looksLikeInstaller(_ exePath: String) -> Bool {
        let base = ((exePath as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        return base.contains("setup") || base.contains("install") || base.hasSuffix("_inst")
    }

    private static func filename(from response: URLResponse, fallbackURL: URL) -> String {
        if let http = response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           let range = cd.range(of: "filename=") {
            var name = String(cd[range.upperBound...])
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
            if let semi = name.firstIndex(of: ";") { name = String(name[..<semi]) }
            if !name.isEmpty { return name }
        }
        let last = fallbackURL.lastPathComponent
        return last.isEmpty ? "download.zip" : last
    }

    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(s.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "juego-\(abs(s.hashValue))" : cleaned
    }

    private static func stripQuarantine(at dir: String) async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", dir]
        try? p.run(); p.waitUntilExit()
    }
}
