import Foundation

@MainActor
@Observable
final class EngineManager {
    struct Engine: Identifiable, Hashable {
        let id: String
        let name: String
        let type: EngineType
        let version: String
        let downloadURL: URL
        let size: UInt64
        let releaseDate: Date

        enum EngineType: String, Codable {
            case wineGE = "wine-ge"
            case protonGE = "proton-ge"
            case protonCachyOS = "proton-cachyos"
            case wineCrossover = "wine-crossover"
            case wineStaging = "wine-staging"
            case wineStable = "wine-stable"
            case gptk = "gptk"
        }
    }

    private let enginesDirectory = VesselPaths.enginesDirectory

    func enginesDirectoryURL() -> URL {
        URL(fileURLWithPath: enginesDirectory)
    }

    func availableEngines() -> [Engine] {
        var engines: [Engine] = []
        let urls = try? FileManager.default.contentsOfDirectory(
            at: enginesDirectoryURL(),
            includingPropertiesForKeys: nil
        )
        for url in urls ?? [] {
            let name = url.lastPathComponent
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("bin/wine64").path) {
                engines.append(Engine(
                    id: name,
                    name: name,
                    type: .wineGE,
                    version: name,
                    downloadURL: url,
                    size: 0,
                    releaseDate: Date()
                ))
            }
        }
        return engines
    }

    func downloadRecommendedEngines(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        let recommended: [(name: String, type: Engine.EngineType, url: String)] = [
            ("Wine-GE-Proton8-26", .wineGE, "https://github.com/GloriousEggroll/wine-ge-custom/releases/download/GE-Proton8-26/wine-ge-proton8-26-x86_64.tar.xz"),
        ]

        try FileManager.default.createDirectory(at: enginesDirectoryURL(), withIntermediateDirectories: true)

        for engine in recommended {
            progress("Descargando \(engine.name)…", 0.1)
            let downloadURL = URL(string: engine.url)!
            let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
            progress("Extrayendo \(engine.name)…", 0.6)
            let extractPath = enginesDirectoryURL().appendingPathComponent(engine.name)
            try? FileManager.default.removeItem(at: extractPath)
            try FileManager.default.createDirectory(at: extractPath, withIntermediateDirectories: true)
            try await extractTar(at: tempURL, to: extractPath)
            progress("✓ \(engine.name) instalado", 1.0)
        }
    }

    private func extractTar(at file: URL, to dest: URL) async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xf", file.path, "-C", dest.path]
        try task.run()
        task.waitUntilExit()
    }
}
