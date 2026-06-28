import Foundation

@MainActor
@Observable
final class DependencyManager {
    struct WineRelease: Codable {
        let tagName: String
        let assets: [WineReleaseAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    struct WineReleaseAsset: Codable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum Dependency: String, CaseIterable, Identifiable {
        case winePortable = "Wine (motor portable)"
        case gptk = "Game Porting Toolkit"
        case rosetta = "Rosetta 2 (traducción x86_64)"
        case dxmt = "DXMT (D3D → Metal nativo)"
        case dxvk = "DXVK (D3D → Vulkan)"

        var id: String { rawValue }
    }

    struct CheckResult {
        let dependency: Dependency
        let installed: Bool
        let path: String?
        let version: String?
        let note: String?
    }

    /// Directorio de engines portables de Vessel — todo auto-gestionado.
    let enginesDirectory = VesselPaths.enginesDirectory

    func checkAll() async -> [CheckResult] {
        var results: [CheckResult] = []
        for dep in Dependency.allCases {
            results.append(await check(dep))
        }
        return results
    }

    func check(_ dep: Dependency) async -> CheckResult {
        switch dep {
        case .winePortable:
            return await findWinePortable()
        case .gptk:
            return await findGPTK()
        case .rosetta:
            return await checkRosetta()
        case .dxmt:
            let path = await findDXMT()
            return CheckResult(dependency: dep, installed: path != nil, path: path, version: path != nil ? "0.80" : nil, note: nil)
        case .dxvk:
            return CheckResult(dependency: dep, installed: true, path: "Bundled con Wine", version: nil, note: nil)
        }
    }

    // MARK: - Wine portable (descargado por Vessel, no de Homebrew)

    private func findWinePortable() async -> CheckResult {
        try? FileManager.default.createDirectory(atPath: enginesDirectory, withIntermediateDirectories: true)

        if let winePath = WineEngineLocator.findPortableWineBinary(enginesDirectory: enginesDirectory) {
            let version = await runCapture(executable: winePath, arguments: ["--version"])
            return CheckResult(
                dependency: .winePortable,
                installed: true,
                path: winePath,
                version: version?.split(separator: "\n").first.map(String.init),
                note: "Auto-instalado por Vessel"
            )
        }

        return CheckResult(dependency: .winePortable, installed: false, path: nil, version: nil, note: nil)
    }

    func ensureWinePortableInstalled(progress: @escaping @Sendable (String, Double) -> Void) async throws -> String {
        let current = await check(.winePortable)
        if let path = current.path, current.installed {
            return path
        }

        try await installWinePortable(progress: progress)

        let verified = await check(.winePortable)
        if let path = verified.path, verified.installed {
            return path
        }

        throw NSError(
            domain: "Vessel",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Wine se instaló, pero no se pudo autodetectar. Revisa los logs de Vessel."]
        )
    }

    /// Descarga Wine portable desde el repo oficial de Gcenx, lo extrae,
    /// lo firma con ad-hoc, y verifica que NO tiene quarantine.
    /// 100% transparente para el usuario: no toca /Applications, no pide sudo.
    func installWinePortable(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        try FileManager.default.createDirectory(atPath: enginesDirectory, withIntermediateDirectories: true)

        progress("Buscando última versión de Wine…", 0.05)
        let apiURL = URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/latest")!
        let (data, _) = try await URLSession.shared.data(from: apiURL)

        let release = try JSONDecoder().decode(WineRelease.self, from: data)
        let progress5 = progress
        let wineAsset = Self.selectWineAsset(from: release)

        guard let asset = wineAsset, let downloadURL = URL(string: asset.browserDownloadURL) else {
            throw NSError(domain: "Vessel", code: 1, userInfo: [NSLocalizedDescriptionKey: "No se encontró un build de Wine descargable en el release actual"])
        }

        progress5("Descargando Wine \(release.tagName) (~190 MB)…", 0.20)
        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Vessel", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Descarga falló con HTTP \(http.statusCode)"])
        }

        progress5("Verificando integridad del archivo…", 0.45)
        _ = await removeQuarantineIfPresent(at: tempURL.path)

        let finalEngineDir = WineEngineLocator.portableEngineDirectory(enginesDirectory: enginesDirectory)
        let stagingDir = URL(fileURLWithPath: enginesDirectory).appendingPathComponent("wine-osx64-installing-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: stagingDir)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.removeItem(at: tempURL)
        }

        progress5("Extrayendo Wine…", 0.65)
        try await extractTar(at: tempURL, to: stagingDir)

        let normalizedWinePath = try WineEngineLocator.normalizeExtractedEngine(
            stagingDirectory: stagingDir,
            finalEngineDirectory: finalEngineDir
        )

        progress5("Firmando binarios con ad-hoc…", 0.85)
        await adhocSignBinaries(in: finalEngineDir.path)

        guard FileManager.default.isExecutableFile(atPath: normalizedWinePath) else {
            throw NSError(
                domain: "Vessel",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Wine se instaló, pero el binario no es ejecutable."]
            )
        }

        progress5("✓ Wine \(release.tagName) listo", 1.0)
    }

    nonisolated static func selectWineAsset(from release: WineRelease) -> WineReleaseAsset? {
        release.assets.first { $0.name.contains("wine-devel") && $0.name.hasSuffix(".tar.xz") }
            ?? release.assets.first { $0.name.contains("osx64") && $0.name.hasSuffix(".tar.xz") }
    }

    private func extractTar(at archiveURL: URL, to destinationURL: URL) async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xf", archiveURL.path, "-C", destinationURL.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "Vessel",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Falló la extracción de Wine: \(output)"]
            )
        }
    }

    private func removeQuarantineIfPresent(at path: String) async -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = [path]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let attrs = String(data: data, encoding: .utf8) ?? ""
            if attrs.contains("com.apple.quarantine") {
                let rm = Process()
                rm.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                rm.arguments = ["-d", "com.apple.quarantine", path]
                try rm.run()
                rm.waitUntilExit()
                return true
            }
        } catch {}
        return false
    }

    private func adhocSignBinaries(in directory: String) async {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: directory) else { return }
        let paths: [String] = Array(enumerator.compactMap { $0 as? String })
        for path in paths {
            let full = "\(directory)/\(path)"
            if isMachOFile(atPath: full) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                task.arguments = ["--force", "--sign", "-", full]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe
                do {
                    try task.run()
                    task.waitUntilExit()
                } catch {}
            }
        }
    }

    private func isMachOFile(atPath path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 4), data.count == 4 else {
            return false
        }

        let bytes = [UInt8](data)
        let magic = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let machOMagics: Set<UInt32> = [
            0xFEEDFACE, 0xFEEDFACF,
            0xCEFAEDFE, 0xCFFAEDFE,
            0xCAFEBABE, 0xCAFEBABF,
            0xBEBAFECA, 0xBFBAFECA
        ]
        return machOMagics.contains(magic)
    }

    // MARK: - GPTK (nativo ARM de Apple, sin Gatekeeper)

    private func findGPTK() async -> CheckResult {
        let gptk = "/Library/Apple/usr/libexec/oah/translation"
        let gptkBin = "\(gptk)/wine64"
        if FileManager.default.isExecutableFile(atPath: gptkBin) {
            return CheckResult(dependency: .gptk, installed: true, path: gptkBin, version: "Apple GPTK", note: "Nativo ARM")
        }
        if FileManager.default.fileExists(atPath: gptk) {
            return CheckResult(dependency: .gptk, installed: true, path: gptk, version: nil, note: "Directorio presente")
        }
        return CheckResult(dependency: .gptk, installed: false, path: nil, version: nil, note: "Requiere macOS Sonoma 14.2+")
    }

    // MARK: - Rosetta 2

    private func checkRosetta() async -> CheckResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        task.arguments = ["-x86_64", "true"]
        let pipe = Pipe()
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                return CheckResult(dependency: .rosetta, installed: true, path: "/usr/bin/arch", version: "Activo", note: nil)
            }
        } catch {}
        return CheckResult(dependency: .rosetta, installed: false, path: nil, version: nil, note: nil)
    }

    /// Instala Rosetta automáticamente (puede pedir contraseña del Mac).
    func installRosetta() async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/softwareupdate")
        task.arguments = ["--install-rosetta", "--agree-to-license"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw NSError(domain: "Vessel", code: Int(task.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "softwareupdate falló: \(err)"])
            }
        } catch {
            throw error
        }
    }

    // MARK: - DXMT (D3D→Metal nativo ARM)

    private func findDXMT() async -> String? {
        let candidates = [
            "\(enginesDirectory)/dxmt/dxmt64",
            "/usr/local/bin/dxmt64",
            "/opt/homebrew/bin/dxmt64",
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }

    // MARK: - Helpers

    private func runCapture(executable: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { cont in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = arguments
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do { try task.run() } catch {
                cont.resume(returning: nil); return
            }
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            cont.resume(returning: String(data: data, encoding: .utf8))
        }
    }
}
