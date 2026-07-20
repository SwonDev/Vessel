import CryptoKit
import Foundation

/// Instala de forma aislada el renderizador OpenGL moderno de Chris Dohnal para Deus Ex 1.112fm.
///
/// El `OpenGlDrv.dll` que Steam distribuye es un backend de 2000: en Wine/macOS puede crear la
/// ventana y quedarse en negro o bloquearse durante la inicialización. La versión 2.1 mantiene el
/// ABI de Deus Ex, usa OpenGL 1.x/2.1 y funciona sobre el OpenGL→Metal del motor completo de Vessel.
/// La descarga queda fijada por dos SHA-256 y nunca sustituye una DLL personalizada desconocida.
@MainActor
final class UnrealEngine1RendererManager {
    enum RendererError: LocalizedError {
        case missingRenderer
        case invalidRenderer(String)
        case downloadFailed(String)
        case checksumMismatch(String)
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingRenderer:
                return "No se encontró OpenGlDrv.dll junto al ejecutable de Unreal Engine 1."
            case .invalidRenderer(let detail):
                return "El renderizador de Unreal Engine 1 no es válido: \(detail)"
            case .downloadFailed(let detail):
                return "No se pudo descargar el renderizador de Unreal Engine 1: \(detail)"
            case .checksumMismatch(let asset):
                return "La verificación de integridad de \(asset) falló."
            case .extractionFailed(let detail):
                return "No se pudo extraer el renderizador de Unreal Engine 1: \(detail)"
            }
        }
    }

    enum InstallationStatus: Equatable {
        case installedPinned
        case alreadyPinned
        case existingCustom
    }

    struct InstallationResult: Equatable {
        let destination: String
        let status: InstallationStatus
    }

    static let pinnedVersion = "2.1"
    static let pinnedAssetName = "dxglr21.zip"
    static let pinnedDownloadURL = URL(
        string: "https://www.cwdohnal.com/utglr/dxglr21.zip"
    )!
    static let pinnedArchiveSHA256 =
        "c1029421ab1bfd1f38a236cd92b21d577f505024720f8dc089b24bb8c48a462a"
    static let pinnedRendererSHA256 =
        "c47b639fd90250ebf8bc6a9d2c013720628751dae163416a1f44b1b1953fb93b"
    static let steamRendererSHA256 =
        "3f9d083bd47135d887fe9a008f199584589b68375c9de6861574945f25de547f"

    private let cacheDirectory: String
    private let localRendererPath: String?
    private let downloadURL: URL
    private let archiveSHA256: String
    private let rendererSHA256: String
    private let stockRendererSHA256: String

    init(
        cacheDirectory: String = VesselPaths.cacheDirectory,
        localRendererPath: String? = nil,
        downloadURL: URL = UnrealEngine1RendererManager.pinnedDownloadURL,
        archiveSHA256: String = UnrealEngine1RendererManager.pinnedArchiveSHA256,
        rendererSHA256: String = UnrealEngine1RendererManager.pinnedRendererSHA256,
        stockRendererSHA256: String = UnrealEngine1RendererManager.steamRendererSHA256
    ) {
        self.cacheDirectory = "\(cacheDirectory)/ue1-renderers/deus-ex-\(Self.pinnedVersion)"
        self.localRendererPath = localRendererPath
        self.downloadURL = downloadURL
        self.archiveSHA256 = archiveSHA256
        self.rendererSHA256 = rendererSHA256
        self.stockRendererSHA256 = stockRendererSHA256
    }

    /// Prepara el backend junto al ejecutable. Una verificación de Steam puede restaurar la DLL
    /// original; el marcador y la caché permiten repararla de nuevo en el siguiente arranque.
    func installModernDeusExOpenGL(
        forExecutable executable: String
    ) async throws -> InstallationResult {
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: executable).standardizedFileURL
            .deletingLastPathComponent()
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path),
              let rendererName = entries.first(where: {
                  $0.caseInsensitiveCompare("OpenGlDrv.dll") == .orderedSame
              }) else {
            throw RendererError.missingRenderer
        }

        let destination = directory.appendingPathComponent(rendererName)
        let backup = URL(fileURLWithPath: destination.path + ".vessel-original")
        let marker = URL(fileURLWithPath: destination.path + ".vessel-renderer")
        let existing = try Data(contentsOf: destination, options: .mappedIfSafe)
        let existingHash = Self.sha256(existing)
        if existingHash == rendererSHA256 {
            try writeMarker(to: marker)
            return .init(destination: destination.path, status: .alreadyPinned)
        }

        let isManaged = fm.fileExists(atPath: marker.path)
        let isLegacyStock = existingHash == stockRendererSHA256
        let looksLikePE = existing.starts(with: [0x4D, 0x5A])
        if !isManaged, looksLikePE, !isLegacyStock {
            // El jugador o un mod ya instaló un backend moderno. No se pisa una DLL desconocida.
            return .init(destination: destination.path, status: .existingCustom)
        }

        let source = try await ensureCachedRenderer()
        if !fm.fileExists(atPath: backup.path), looksLikePE {
            try fm.copyItem(at: destination, to: backup)
        }
        let verified = try Data(contentsOf: source, options: .mappedIfSafe)
        try verified.write(to: destination, options: .atomic)
        try writeMarker(to: marker)
        return .init(destination: destination.path, status: .installedPinned)
    }

    private func ensureCachedRenderer() async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)
        let cached = URL(fileURLWithPath: cacheDirectory)
            .appendingPathComponent("OpenGlDrv.dll")
        if let data = try? Data(contentsOf: cached, options: .mappedIfSafe),
           Self.isExpectedRenderer(data, sha256: rendererSHA256) {
            return cached
        }
        try? fm.removeItem(at: cached)

        if let localRendererPath {
            let local = URL(fileURLWithPath: localRendererPath)
            let data = try Data(contentsOf: local, options: .mappedIfSafe)
            guard Self.isExpectedRenderer(data, sha256: rendererSHA256) else {
                throw RendererError.checksumMismatch(local.lastPathComponent)
            }
            try data.write(to: cached, options: .atomic)
            return cached
        }

        let (temporary, response) = try await URLSession.shared.download(from: downloadURL)
        defer { try? fm.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RendererError.downloadFailed("HTTP \(http.statusCode)")
        }
        let archiveData = try Data(contentsOf: temporary, options: .mappedIfSafe)
        guard Self.sha256(archiveData) == archiveSHA256 else {
            throw RendererError.checksumMismatch(Self.pinnedAssetName)
        }

        let extraction = URL(fileURLWithPath: cacheDirectory)
            .appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: extraction, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extraction) }
        try Self.extractZip(temporary, to: extraction)
        let extracted = extraction.appendingPathComponent("OpenGLDrv.dll")
        guard let renderer = try? Data(contentsOf: extracted, options: .mappedIfSafe),
              Self.isExpectedRenderer(renderer, sha256: rendererSHA256) else {
            throw RendererError.checksumMismatch("OpenGLDrv.dll")
        }
        try renderer.write(to: cached, options: .atomic)
        return cached
    }

    private func writeMarker(to marker: URL) throws {
        let value = "dxglr \(Self.pinnedVersion)\nsha256=\(rendererSHA256)\n"
        try value.write(to: marker, atomically: true, encoding: .utf8)
    }

    private nonisolated static func extractZip(_ archive: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.flatMap { $0.isEmpty ? nil : $0 }
                ?? "ditto terminó con código \(process.terminationStatus)"
            throw RendererError.extractionFailed(message)
        }
    }

    private nonisolated static func isExpectedRenderer(_ data: Data, sha256: String) -> Bool {
        data.starts(with: [0x4D, 0x5A]) && Self.sha256(data) == sha256
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
