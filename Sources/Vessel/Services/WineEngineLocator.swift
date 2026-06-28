import Foundation

enum WineEngineLocator {
    static let portableEngineName = "wine-osx64"

    static func portableEngineDirectory(enginesDirectory: String = VesselPaths.enginesDirectory) -> URL {
        URL(fileURLWithPath: enginesDirectory).appendingPathComponent(portableEngineName)
    }

    static func knownPortableWinePaths(enginesDirectory: String = VesselPaths.enginesDirectory) -> [String] {
        let engineDir = portableEngineDirectory(enginesDirectory: enginesDirectory).path
        return [
            "\(engineDir)/bin/wine64",
            "\(engineDir)/bin/wine"
        ]
    }

    static func findPortableWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        for path in knownPortableWinePaths(enginesDirectory: enginesDirectory) {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return findExecutable(named: ["wine64", "wine"], under: portableEngineDirectory(enginesDirectory: enginesDirectory))
    }

    static func detectWineInstallations(
        enginesDirectory: String = VesselPaths.enginesDirectory,
        homeDirectory: String = NSHomeDirectory()
    ) -> [(name: String, path: String, version: String)] {
        var results: [(name: String, path: String, version: String)] = []

        if let portable = findPortableWineBinary(enginesDirectory: enginesDirectory) {
            results.append(("Wine (Vessel portable)", portable, "Auto"))
        }

        let candidates: [(String, String)] = [
            ("Homebrew Wine", "/opt/homebrew/bin/wine64"),
            ("Homebrew Wine", "/opt/homebrew/bin/wine"),
            ("Homebrew Wine Intel", "/usr/local/bin/wine64"),
            ("Homebrew Wine Intel", "/usr/local/bin/wine"),
            ("Game Porting Toolkit (Apple)", "/Library/Apple/usr/libexec/oah/translation/wine64"),
            ("CrossOver", "\(homeDirectory)/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64"),
            ("CrossOver", "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64")
        ]

        var seen = Set(results.map(\.path))
        for (name, path) in candidates where !seen.contains(path) {
            if FileManager.default.isExecutableFile(atPath: path) {
                results.append((name, path, "Auto"))
                seen.insert(path)
            }
        }

        return results
    }

    static func findExecutable(named names: [String], under directory: URL) -> String? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isExecutableKey]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            if url.pathExtension == "app",
               let bundledWine = findWineInAppBundle(url, executableNames: names) {
                return bundledWine
            }

            guard names.contains(url.lastPathComponent) else { continue }
            if fm.isExecutableFile(atPath: url.path) {
                return url.path
            }
        }

        return nil
    }

    private static func findWineInAppBundle(_ appURL: URL, executableNames: [String]) -> String? {
        let binDirectory = appURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("wine")
            .appendingPathComponent("bin")

        for name in executableNames {
            let candidate = binDirectory.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    static func engineRoot(forWineExecutable wineURL: URL) -> URL? {
        let binDirectory = wineURL.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else { return nil }
        return binDirectory.deletingLastPathComponent()
    }

    @discardableResult
    static func normalizeExtractedEngine(stagingDirectory: URL, finalEngineDirectory: URL) throws -> String {
        guard let winePath = findExecutable(named: ["wine64", "wine"], under: stagingDirectory),
              let engineRoot = engineRoot(forWineExecutable: URL(fileURLWithPath: winePath)) else {
            throw NSError(
                domain: "Vessel",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "La descarga de Wine no contenía un binario wine64/wine válido."]
            )
        }

        let fm = FileManager.default
        try? fm.removeItem(at: finalEngineDirectory)
        try fm.createDirectory(at: finalEngineDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: engineRoot, to: finalEngineDirectory)

        guard let normalizedWinePath = findPortableWineBinary(enginesDirectory: finalEngineDirectory.deletingLastPathComponent().path) else {
            throw NSError(
                domain: "Vessel",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Wine se extrajo, pero Vessel no pudo detectar el motor instalado."]
            )
        }

        return normalizedWinePath
    }
}
