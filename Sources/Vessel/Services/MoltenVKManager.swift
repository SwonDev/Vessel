import CryptoKit
import Foundation

/// Gestiona una copia oficial y aislada de MoltenVK para rutas DXVK que no pueden usar la
/// implementación antigua empaquetada en algunos motores Wine.
@MainActor
final class MoltenVKManager {
    enum MoltenVKError: LocalizedError {
        case downloadFailed(String)
        case bundledRuntimeMissing
        case checksumMismatch
        case extractionFailed(String)
        case invalidRuntime

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let message):
                return "Descarga de MoltenVK falló: \(message)"
            case .bundledRuntimeMissing:
                return "Vessel no contiene el runtime Vulkan nativo de compatibilidad."
            case .checksumMismatch:
                return "La verificación de integridad de MoltenVK falló."
            case .extractionFailed(let message):
                return "Extracción de MoltenVK falló: \(message)"
            case .invalidRuntime:
                return "El paquete de MoltenVK no contiene un runtime macOS x86_64 válido."
            }
        }
    }

    static let pinnedVersion = "1.4.1"
    static let pinnedDownloadURL = URL(
        string: "https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.1/MoltenVK-macos.tar"
    )!
    /// Digest publicado por GitHub para el asset oficial de la release v1.4.1.
    static let pinnedArchiveSHA256 =
        "5ea0c259df7ded9a275444820f09cced54d6e5a7c7a31d262de62a5cdb7e15cf"
    static let archiveRuntimePath = "MoltenVK/MoltenVK/dynamic/dylib/macOS"

    /// Build aislada para juegos Vulkan nativos que requieren `wideLines`, `logicOp`, más de
    /// 16 samplers y el contrato id Tech comprobado. DXVK sigue usando exclusivamente el asset
    /// oficial anterior y el refresco de presentación solo se activa mediante su variable opt-in.
    static let nativeVulkanCompatibilityVersion = "1.4.1-vessel.2"
    static let nativeVulkanCompatibilityArchiveResource =
        "moltenvk-compat/MoltenVK-v1.4.1-vessel.2-x86_64.zip"
    static let nativeVulkanCompatibilityArchiveSHA256 =
        "2af10a46c3a97cf52feac16e9da1282242266c09de9d757e1c00807b75b85634"
    static let nativeVulkanCompatibilityLibrarySHA256 =
        "35d9e265662373f436ea4b274decc7a4bd0b82fc2cd12c421653bcdb2e1ae785"

    private let cacheRoot: String
    private let bundledResource: (String) -> URL?

    init(
        cacheDirectory: String = VesselPaths.cacheDirectory,
        bundledResource: @escaping (String) -> URL? = VesselPaths.bundledResource
    ) {
        cacheRoot = "\(cacheDirectory)/moltenvk"
        self.bundledResource = bundledResource
    }

    func cachedLibraryDirectory() -> String? {
        let directory = "\(cacheRoot)/\(Self.pinnedVersion)"
        let library = "\(directory)/libMoltenVK.dylib"
        guard FileManager.default.fileExists(atPath: library),
              ((try? FileManager.default.attributesOfItem(atPath: library)[.size] as? UInt64) ?? 0) > 1_000_000 else {
            return nil
        }
        return directory
    }

    func ensureLibrary(
        progress: @escaping @Sendable (String, Double) -> Void = { _, _ in }
    ) async throws -> String {
        if let cached = cachedLibraryDirectory() {
            progress("MoltenVK \(Self.pinnedVersion) preparado", 1.0)
            return cached
        }

        progress("Descargando MoltenVK \(Self.pinnedVersion)…", 0.1)
        let (archive, response) = try await URLSession.shared.download(from: Self.pinnedDownloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MoltenVKError.downloadFailed("HTTP \(http.statusCode)")
        }

        let fm = FileManager.default
        try fm.createDirectory(atPath: cacheRoot, withIntermediateDirectories: true)
        let staging = "\(cacheRoot)/installing-\(UUID().uuidString)"
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(atPath: staging)
            try? fm.removeItem(at: archive)
        }

        let archiveData = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard Self.sha256(archiveData) == Self.pinnedArchiveSHA256 else {
            throw MoltenVKError.checksumMismatch
        }

        progress("Extrayendo MoltenVK…", 0.65)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xf", archive.path, "-C", staging, Self.archiveRuntimePath]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let message = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "tar terminó con código \(task.terminationStatus)"
            throw MoltenVKError.extractionFailed(message)
        }

        let extracted = "\(staging)/\(Self.archiveRuntimePath)"
        let library = "\(extracted)/libMoltenVK.dylib"
        guard fm.fileExists(atPath: library), Self.containsX8664Slice(library) else {
            throw MoltenVKError.invalidRuntime
        }

        let finalDirectory = "\(cacheRoot)/\(Self.pinnedVersion)"
        try? fm.removeItem(atPath: finalDirectory)
        try fm.moveItem(atPath: extracted, toPath: finalDirectory)
        Self.removeQuarantine(at: finalDirectory)
        progress("MoltenVK \(Self.pinnedVersion) listo", 1.0)
        return finalDirectory
    }

    func cachedNativeVulkanCompatibilityLibraryDirectory() -> String? {
        let directory = "\(cacheRoot)/\(Self.nativeVulkanCompatibilityVersion)"
        let library = "\(directory)/libMoltenVK.dylib"
        let manifest = "\(directory)/MoltenVK_icd.json"
        guard FileManager.default.fileExists(atPath: manifest),
              let data = try? Data(
                contentsOf: URL(fileURLWithPath: library),
                options: .mappedIfSafe
              ),
              Self.sha256(data) == Self.nativeVulkanCompatibilityLibrarySHA256,
              Self.containsX8664Slice(library) else {
            return nil
        }
        return directory
    }

    /// Extrae el runtime empaquetado en una caché versionada y lo valida tanto antes como después
    /// de la extracción. No hay descarga ni compilación en el equipo del usuario.
    func ensureNativeVulkanCompatibilityLibrary(
        progress: @escaping @Sendable (String, Double) -> Void = { _, _ in }
    ) async throws -> String {
        if let cached = cachedNativeVulkanCompatibilityLibraryDirectory() {
            progress("Runtime Vulkan nativo preparado", 1.0)
            return cached
        }

        guard let archive = bundledResource(Self.nativeVulkanCompatibilityArchiveResource) else {
            throw MoltenVKError.bundledRuntimeMissing
        }
        let archiveData = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard Self.sha256(archiveData) == Self.nativeVulkanCompatibilityArchiveSHA256 else {
            throw MoltenVKError.checksumMismatch
        }

        progress("Preparando el runtime Vulkan nativo…", 0.25)
        let fm = FileManager.default
        try fm.createDirectory(atPath: cacheRoot, withIntermediateDirectories: true)
        let staging = "\(cacheRoot)/installing-\(UUID().uuidString)"
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: staging) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", archive.path, staging]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let message = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "ditto terminó con código \(task.terminationStatus)"
            throw MoltenVKError.extractionFailed(message)
        }

        let library = "\(staging)/libMoltenVK.dylib"
        let manifest = "\(staging)/MoltenVK_icd.json"
        guard fm.fileExists(atPath: manifest),
              let libraryData = try? Data(
                contentsOf: URL(fileURLWithPath: library),
                options: .mappedIfSafe
              ),
              Self.sha256(libraryData) == Self.nativeVulkanCompatibilityLibrarySHA256,
              Self.containsX8664Slice(library) else {
            throw MoltenVKError.invalidRuntime
        }

        let finalDirectory = "\(cacheRoot)/\(Self.nativeVulkanCompatibilityVersion)"
        try? fm.removeItem(atPath: finalDirectory)
        try fm.moveItem(atPath: staging, toPath: finalDirectory)
        Self.removeQuarantine(at: finalDirectory)
        progress("Runtime Vulkan nativo listo", 1.0)
        return finalDirectory
    }

    private nonisolated static func containsX8664Slice(_ library: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-archs", library]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let architectures = String(data: data, encoding: .utf8) ?? ""
            return process.terminationStatus == 0
                && architectures.split(whereSeparator: \Character.isWhitespace).contains("x86_64")
        } catch {
            return false
        }
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func removeQuarantine(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
