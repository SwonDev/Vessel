import Foundation
import CryptoKit

/// **Archivo de preservación** de un juego DRM‑free. Escribe junto a la copia un manifiesto
/// (`.vessel-archive.json`) con sus **metadatos** (título, origen, DRM, fecha, ejecutable) y el
/// **SHA‑256 de cada fichero**, y permite **verificar** después que la copia sigue íntegra.
///
/// Por qué importa: una copia sin manifiesto es solo un montón de bytes — dentro de 5 años, en un USB
/// o un disco viejo, no hay forma de saber si se ha corrompido (bit rot), si falta algo o de qué
/// versión venía. Con el manifiesto, la copia es **autodescriptiva y verificable**: eso es lo que
/// convierte "tener el juego" en "conservarlo".
///
/// El manifiesto vive DENTRO de la carpeta del juego, así que viaja solo con cualquier exportación
/// (carpeta de Windows o `.app` de Mac) sin trabajo extra.
actor DRMFreeArchive {
    static let shared = DRMFreeArchive()

    /// Nombre del manifiesto. Empieza por punto para no estorbar y que los juegos lo ignoren.
    static let manifestName = ".vessel-archive.json"

    // MARK: - Modelo

    struct Manifest: Codable {
        var schemaVersion: Int = 1
        /// Título legible del juego.
        var title: String
        /// De dónde salió: "steam" | "itch" | "humble" | "gog" | "local".
        var source: String
        /// Id en su origen (AppID de Steam, id de itch, gamekey:machine de Humble…).
        var sourceId: String?
        /// Ruta RELATIVA del ejecutable dentro de la carpeta.
        var executable: String?
        /// Qué DRM tenía el original y cómo se resolvió (p. ej. "Steamworks → emulado con Goldberg").
        var drm: String?
        var createdAt: Date
        var createdBy: String
        var totalBytes: Int64
        var files: [Entry]

        struct Entry: Codable {
            let path: String     // relativa a la carpeta del juego
            let size: Int64
            let sha256: String
        }
    }

    /// Resultado de verificar una copia contra su manifiesto.
    struct Report: Sendable {
        var manifestFound: Bool
        var checked: Int
        var missing: [String]     // ficheros del manifiesto que ya no están
        var corrupted: [String]   // ficheros cuyo SHA‑256 no coincide (bit rot / modificación)
        var title: String?
        var createdAt: Date?
        var isIntact: Bool { manifestFound && missing.isEmpty && corrupted.isEmpty }

        var summary: String {
            guard manifestFound else { return "Esta copia no tiene manifiesto de Vessel; no se puede verificar." }
            if isIntact { return "Íntegro: \(checked) fichero(s) verificados, todo correcto." }
            var parts: [String] = []
            if !missing.isEmpty { parts.append("\(missing.count) fichero(s) que faltan") }
            if !corrupted.isEmpty { parts.append("\(corrupted.count) fichero(s) corrompidos") }
            return "Copia dañada: " + parts.joined(separator: " y ") + " de \(checked) verificados."
        }
    }

    enum ArchiveError: LocalizedError {
        case folderMissing, manifestUnreadable
        var errorDescription: String? {
            switch self {
            case .folderMissing: return "La carpeta del juego no existe."
            case .manifestUnreadable: return "El manifiesto del archivo está dañado o no se puede leer."
            }
        }
    }

    // MARK: - Escribir el manifiesto

    /// Genera (o regenera) el manifiesto de la carpeta del juego. Hashea todos los ficheros —
    /// `progress` = (fracción 0…1, mensaje). El propio manifiesto se excluye del hash.
    @discardableResult
    func writeManifest(folder: String, title: String, source: String, sourceId: String? = nil,
                       executable: String? = nil, drm: String? = nil,
                       appVersion: String = DRMFreeArchive.appVersion,
                       progress: @Sendable @escaping (Double, String) -> Void = { _, _ in }) async throws -> Manifest {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder) else { throw ArchiveError.folderMissing }

        progress(0.02, "Listando ficheros…")
        let paths = Self.allFiles(in: folder)
        var entries: [Manifest.Entry] = []
        entries.reserveCapacity(paths.count)
        var total: Int64 = 0

        for (i, rel) in paths.enumerated() {
            let full = "\(folder)/\(rel)"
            let attrs = try? fm.attributesOfItem(atPath: full)
            let size = (attrs?[.size] as? Int64) ?? 0
            let hash = (try? Self.sha256(of: full)) ?? ""
            guard !hash.isEmpty else { continue }
            entries.append(.init(path: rel, size: size, sha256: hash))
            total += size
            if i % 8 == 0 {
                progress(0.02 + Double(i) / Double(max(paths.count, 1)) * 0.96,
                         "Calculando huellas… \(i)/\(paths.count)")
            }
        }

        let manifest = Manifest(title: title, source: source, sourceId: sourceId,
                                executable: executable, drm: drm, createdAt: Date(),
                                createdBy: "Vessel \(appVersion)", totalBytes: total, files: entries)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(manifest)
        try data.write(to: URL(fileURLWithPath: "\(folder)/\(Self.manifestName)"), options: .atomic)
        progress(1.0, "Manifiesto listo")
        return manifest
    }

    // MARK: - Verificar

    /// Verifica la copia contra su manifiesto: detecta ficheros que faltan y ficheros corrompidos
    /// (SHA‑256 distinto). Ficheros NUEVOS (p. ej. partidas o config que el juego haya creado) se
    /// ignoran a propósito: no son daño.
    func verify(folder: String,
                progress: @Sendable @escaping (Double, String) -> Void = { _, _ in }) async throws -> Report {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder) else { throw ArchiveError.folderMissing }
        let manifestPath = "\(folder)/\(Self.manifestName)"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)) else {
            return Report(manifestFound: false, checked: 0, missing: [], corrupted: [], title: nil, createdAt: nil)
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let manifest = try? dec.decode(Manifest.self, from: data) else { throw ArchiveError.manifestUnreadable }

        var missing: [String] = [], corrupted: [String] = []
        for (i, entry) in manifest.files.enumerated() {
            let full = "\(folder)/\(entry.path)"
            guard fm.fileExists(atPath: full) else { missing.append(entry.path); continue }
            if let hash = try? Self.sha256(of: full), hash != entry.sha256 { corrupted.append(entry.path) }
            if i % 8 == 0 {
                progress(Double(i) / Double(max(manifest.files.count, 1)),
                         "Verificando… \(i)/\(manifest.files.count)")
            }
        }
        progress(1.0, "Verificación completada")
        return Report(manifestFound: true, checked: manifest.files.count, missing: missing,
                      corrupted: corrupted, title: manifest.title, createdAt: manifest.createdAt)
    }

    /// Lee solo los metadatos (sin verificar hashes) — para mostrar de dónde vino una copia.
    nonisolated static func readManifest(folder: String) -> Manifest? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(folder)/\(manifestName)")) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Manifest.self, from: data)
    }

    // MARK: - Internos

    /// Todos los ficheros (rutas relativas), saltando el propio manifiesto y basura de macOS.
    private static func allFiles(in folder: String) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: folder) else { return [] }
        var out: [String] = []
        while let rel = en.nextObject() as? String {
            let leaf = (rel as NSString).lastPathComponent
            if leaf == manifestName || leaf == ".DS_Store" { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: "\(folder)/\(rel)", isDirectory: &isDir), !isDir.boolValue else { continue }
            out.append(rel)
        }
        return out.sorted()
    }

    /// SHA‑256 en streaming (1 MB por bloque): los juegos pesan GB, no caben en memoria.
    private static func sha256(of path: String) throws -> String {
        let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Versión de la app (para dejar constancia de con qué se archivó).
    nonisolated static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "desconocida"
    }
}
