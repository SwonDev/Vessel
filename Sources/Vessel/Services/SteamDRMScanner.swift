import Foundation

/// Identifica los juegos de **Steam instalados** (en el bottle de Vessel) que son **DRM‑free** —
/// es decir, que pueden ejecutarse SIN el DRM de Steam (sin CEG/SteamStub) — y **genera una copia
/// local standalone** de sus archivos en la biblioteca DRM‑free, aplicando Goldberg (emulación de
/// `steam_api`) para que arranquen sin el cliente de Steam. Así el usuario "genera los archivos
/// locales del juego" y los conserva DRM‑free.
///
/// Clasificación por juego:
///  - **DRM de Steam (CEG/SteamStub)** → el `.exe` está cifrado y NO corre sin Steam → se excluye.
///  - **Steamworks** → usa `steam_api` (logros/nube), pero NO es DRM: corre standalone con Goldberg.
///  - **DRM‑free** → ni CEG ni `steam_api`: corre tal cual.
@MainActor
@Observable
final class SteamDRMScanner {
    static let shared = SteamDRMScanner()

    enum DRMStatus: String {
        case drmFree, steamworks, steamDRM
        var label: String {
            switch self {
            case .drmFree: return "DRM‑free"
            case .steamworks: return "Steamworks (Goldberg)"
            case .steamDRM: return "DRM de Steam"
            }
        }
        /// Puede generarse como juego local DRM‑free.
        var isGenerable: Bool { self != .steamDRM }
    }

    struct Candidate: Identifiable, Hashable {
        let id: String          // appId
        let appId: String
        let name: String
        let installPath: String
        let executablePath: String
        let coverURL: String?
        let status: DRMStatus
        let sizeBytes: Int64
    }

    private let importer = SteamLibraryImporter()
    private let wine = WineManager()
    private let goldberg = GoldbergManager()

    /// Escanea los juegos instalados en el Steam del bottle y los clasifica por DRM.
    func scan(bottle: Bottle) -> [Candidate] {
        importer.scanBottleGames(bottle: bottle).map { g in
            let hasCEG = Self.hasSteamStub(g.executablePath)
            let steamworks = wine.usesSteamworks(g.executablePath)
            let status: DRMStatus = hasCEG ? .steamDRM : (steamworks ? .steamworks : .drmFree)
            return Candidate(id: g.appId, appId: g.appId, name: g.name,
                             installPath: g.installPath, executablePath: g.executablePath,
                             coverURL: g.coverURL, status: status, sizeBytes: Self.dirSize(g.installPath))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    enum GenError: LocalizedError {
        case hasDRM, copyFailed(Int32), exeNotFound
        var errorDescription: String? {
            switch self {
            case .hasDRM: return "El juego usa el DRM de Steam (CEG) y no puede ejecutarse sin Steam."
            case .copyFailed(let c): return "La copia de los archivos falló (código \(c))."
            case .exeNotFound: return "No se encontró el ejecutable en la copia."
            }
        }
    }

    /// **Genera la copia local DRM‑free** de un juego de Steam: copia toda la carpeta del juego a
    /// `DRMFree/<nombre>`, aplica Goldberg al `steam_api` de la copia (si lo usa) y devuelve el
    /// ejecutable de la copia — listo para ejecutarse sin Steam. `progress` = (fracción, mensaje).
    func generateLocalCopy(_ c: Candidate,
                           progress: @escaping @Sendable (Double, String) -> Void) async throws -> (exe: String, dir: String) {
        guard c.status.isGenerable else { throw GenError.hasDRM }
        let dest = "\(VesselPaths.drmFreeDirectory)/\(DRMFreeInstaller.sanitize(c.name))"
        try? FileManager.default.removeItem(atPath: dest)

        // Goldberg listo (descarga la primera vez), en paralelo conceptual antes de copiar.
        if c.status == .steamworks {
            progress(0.02, "Preparando Goldberg…")
            try? await goldberg.ensureInstalled { _, _ in }
        }

        progress(0.05, "Copiando los archivos del juego…")
        try await Self.copyTree(from: c.installPath, to: dest, totalBytes: c.sizeBytes) { frac in
            progress(0.05 + frac * 0.85, "Copiando… \(Int(frac * 100))%")
        }

        // Ejecutable dentro de la copia (misma ruta relativa que en el original).
        let rel = c.executablePath.hasPrefix(c.installPath)
            ? String(c.executablePath.dropFirst(c.installPath.count)).drop(while: { $0 == "/" })
            : Substring(((c.executablePath as NSString).lastPathComponent))
        let destExe = "\(dest)/\(rel)"
        guard FileManager.default.fileExists(atPath: destExe) else { throw GenError.exeNotFound }

        // Aplicar Goldberg a la COPIA (sustituye steam_api por la emulación → corre sin Steam).
        if c.status == .steamworks {
            progress(0.94, "Aplicando emulación de Steam (Goldberg)…")
            _ = goldberg.applyToGame(gameExecutable: destExe, appId: c.appId)
        }
        await Self.stripQuarantine(dest)
        progress(1.0, "Listo")
        return (destExe, dest)
    }

    // MARK: - Copia con progreso

    private static func copyTree(from src: String, to dest: String, totalBytes: Int64,
                                 _ onProgress: @Sendable @escaping (Double) -> Void) async throws {
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        // `ditto` copia rápido preservando estructura; medimos progreso sondeando el tamaño del destino.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = [src, dest]
        try p.run()
        let total = max(totalBytes, 1)
        while p.isRunning {
            try? await Task.sleep(for: .milliseconds(1200))
            let copied = dirSize(dest)
            onProgress(min(0.999, Double(copied) / Double(total)))
        }
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw GenError.copyFailed(p.terminationStatus) }
        onProgress(1.0)
    }

    // MARK: - Utilidades

    /// Tamaño total de un directorio (rápido, vía `du -sk`).
    static func dirSize(_ path: String) -> Int64 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return 0 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let s = String(data: data, encoding: .utf8),
              let kb = Int64(s.split(separator: "\t").first ?? "") else { return 0 }
        return kb * 1024
    }

    private static func stripQuarantine(_ dir: String) async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", dir]
        try? p.run(); p.waitUntilExit()
    }

    /// Detecta el wrapper **SteamStub / CEG** (DRM de Steam) leyendo la tabla de secciones del PE:
    /// SteamStub añade una sección `.bind` (marcador de sus variantes v2/v3, las más comunes).
    /// Heurística: no garantiza el 100% de los casos, pero identifica el DRM de Steam habitual.
    static func hasSteamStub(_ exePath: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: exePath) else { return false }
        defer { try? fh.close() }
        // Cabeceras + tabla de secciones caben de sobra en los primeros 16 KB.
        guard let data = try? fh.read(upToCount: 16384), data.count > 0x40 else { return false }
        let bytes = [UInt8](data)
        func u16(_ off: Int) -> Int { off + 1 < bytes.count ? Int(bytes[off]) | (Int(bytes[off + 1]) << 8) : 0 }
        func u32(_ off: Int) -> Int {
            off + 3 < bytes.count ? Int(bytes[off]) | (Int(bytes[off+1]) << 8) | (Int(bytes[off+2]) << 16) | (Int(bytes[off+3]) << 24) : 0
        }
        guard bytes[0] == 0x4D, bytes[1] == 0x5A else { return false }   // "MZ"
        let peOff = u32(0x3C)
        guard peOff + 24 < bytes.count,
              bytes[peOff] == 0x50, bytes[peOff+1] == 0x45 else { return false }   // "PE\0\0"
        let numSections = u16(peOff + 6)
        let sizeOptHeader = u16(peOff + 20)
        var sectOff = peOff + 24 + sizeOptHeader
        for _ in 0..<max(0, min(numSections, 96)) {
            guard sectOff + 8 <= bytes.count else { break }
            let nameBytes = bytes[sectOff..<sectOff+8].prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self)
            if name == ".bind" { return true }
            sectOff += 40
        }
        return false
    }
}
