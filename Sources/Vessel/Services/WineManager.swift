import Foundation

@MainActor
@Observable
final class WineManager {
    enum WineError: LocalizedError {
        case noEngine
        case launchFailed(String)
        case installationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noEngine: return "Wine no instalado. Vessel lo descargará automáticamente."
            case .launchFailed(let msg): return "Error al lanzar: \(msg)"
            case .installationFailed(let msg): return "Error en la instalación: \(msg)"
            }
        }
    }

    private let dependencyManager = DependencyManager()

    /// Resuelve el binario de Wine: prefiere el portable descargado por Vessel,
    /// si no está usa GPTK de Apple. Nunca toca /Applications.
    func resolveWineBinary() -> String? {
        detectWineInstallations().first?.path
    }

    func detectWineInstallations() -> [(name: String, path: String, version: String)] {
        WineEngineLocator.detectWineInstallations()
    }

    func createBottle(at path: String, winePath: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: winePath) else {
            throw WineError.noEngine
        }

        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        try await runWineTool(
            winePath: winePath,
            toolName: "wineboot",
            fallbackArguments: ["wineboot", "--init"],
            toolArguments: ["--init"],
            prefix: path
        )
    }

    func installSteam(bottle: Bottle) async throws {
        let steamURL = "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
        let downloadPath = "\(bottle.prefixPath)/drive_c/users/crossover/Downloads/SteamSetup.exe"
        try FileManager.default.createDirectory(
            atPath: "\(bottle.prefixPath)/drive_c/users/crossover/Downloads",
            withIntermediateDirectories: true
        )
        guard let url = URL(string: steamURL) else {
            throw WineError.installationFailed("URL inválida")
        }
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: downloadPath))
        try await runWine(
            winePath: bottle.winePath,
            arguments: [downloadPath, "/S"],
            prefix: bottle.prefixPath
        )
    }

    @discardableResult
    func launch(executable: String, in bottle: Bottle, arguments: [String] = []) async throws -> Process {
        let prefix = bottle.prefixPath
        let env = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "DXVK_ASYNC": "1",
            "MVK_CONFIG_LOG_LEVEL": "0"
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bottle.winePath)
        process.arguments = [executable] + arguments
        process.environment = env
        do {
            try process.run()
            return process
        } catch {
            throw WineError.launchFailed(error.localizedDescription)
        }
    }

    private func runWine(winePath: String, arguments: [String], prefix: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = arguments
        process.environment = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw WineError.launchFailed(output.isEmpty ? "Wine terminó con código \(process.terminationStatus)" : output)
            }
        } catch let error as WineError {
            throw error
        } catch {
            throw WineError.launchFailed(error.localizedDescription)
        }
    }

    private func runWineTool(
        winePath: String,
        toolName: String,
        fallbackArguments: [String],
        toolArguments: [String],
        prefix: String
    ) async throws {
        if let toolPath = siblingTool(named: toolName, forWinePath: winePath) {
            try await runExecutable(path: toolPath, arguments: toolArguments, prefix: prefix)
        } else {
            try await runWine(winePath: winePath, arguments: fallbackArguments, prefix: prefix)
        }
    }

    private func siblingTool(named toolName: String, forWinePath winePath: String) -> String? {
        let wineURL = URL(fileURLWithPath: winePath)
        let toolURL = wineURL.deletingLastPathComponent().appendingPathComponent(toolName)
        return FileManager.default.isExecutableFile(atPath: toolURL.path) ? toolURL.path : nil
    }

    private func runExecutable(path: String, arguments: [String], prefix: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw WineError.launchFailed(output.isEmpty ? "wineboot terminó con código \(process.terminationStatus)" : output)
            }
        } catch let error as WineError {
            throw error
        } catch {
            throw WineError.launchFailed(error.localizedDescription)
        }
    }
}
