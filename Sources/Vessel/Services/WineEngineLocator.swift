import Foundation

enum WineEngineLocator {
    static let portableEngineName = "wine-osx64"
    /// Motor Wine con soporte DXMT (3Shain/wine v9.9-mingw). Necesario para
    /// que juegos D3D11 rendericen en Apple Silicon via Metal nativo.
    static let dxmtEngineName = "wine-dxmt"

    // MARK: - Roles de motor (arquitectura de doble motor)
    //
    // Tras validación empírica en Apple Silicon:
    //  - El CLIENTE de Steam (Chromium/steamwebhelper) solo arranca en un Wine
    //    completo y moderno (Gcenx wine-osx64, p.ej. 11.x). En wine-dxmt el
    //    proceso GPU de CEF revienta (STATUS_BREAKPOINT) y da error 0x3008.
    //  - Los JUEGOS D3D11 (Unity feature level 11_0) solo funcionan con DXMT
    //    (Metal nativo) integrado en wine-dxmt. DXVK no puede (Metal no tiene
    //    geometry shaders → feature level insuficiente) y DXMT externo no carga
    //    en Gcenx por incompatibilidad de ABI del winemetal.so.
    //
    // Por eso Vessel usa DOS motores según la tarea, sobre el mismo prefijo.

    /// Motor para el CLIENTE de Steam y apps generales: Wine completo (Gcenx).
    static var clientEngineName: String { portableEngineName }

    /// Motor para JUEGOS D3D11: wine-dxmt (DXMT builtin → Metal nativo).
    static var gameEngineName: String { dxmtEngineName }

    /// Binario Wine del motor del CLIENTE de Steam (Gcenx wine-osx64).
    static func clientWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        wineBinary(in: clientEngineName, enginesDirectory: enginesDirectory)
    }

    /// Binario Wine del motor de JUEGOS D3D11 (wine-dxmt).
    static func gameWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        wineBinary(in: gameEngineName, enginesDirectory: enginesDirectory)
    }

    /// Resuelve el binario `wine`/`wine64` dentro de un motor por nombre.
    static func wineBinary(in engineName: String, enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        let base = URL(fileURLWithPath: enginesDirectory).appendingPathComponent(engineName)
        for sub in ["bin/wine64", "bin/wine"] {
            let path = base.appendingPathComponent(sub).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return findExecutable(named: ["wine64", "wine"], under: base)
    }

    /// True si la ruta de Wine pertenece al motor de juegos (wine-dxmt).
    static func isGameEngine(_ winePath: String) -> Bool {
        winePath.contains("/\(gameEngineName)/")
    }

    static func portableEngineDirectory(enginesDirectory: String = VesselPaths.enginesDirectory) -> URL {
        // Preferir wine-dxmt (3Shain) si está instalado, si no, wine-osx64 (Gcenx).
        let dxmtDir = URL(fileURLWithPath: enginesDirectory).appendingPathComponent(dxmtEngineName)
        if FileManager.default.fileExists(atPath: "\(dxmtDir.path)/bin/wine") {
            return dxmtDir
        }
        return URL(fileURLWithPath: enginesDirectory).appendingPathComponent(portableEngineName)
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
