import Foundation

@MainActor
@Observable
final class WineManager {
    struct ProcessResult {
        let exitCode: Int32
        let output: String
    }

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
    private let steamInstallerURL = URL(string: SteamConstants.setupURL)!

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
        if FileManager.default.fileExists(atPath: bottle.steamPath) {
            try await terminateWineProcesses(winePath: bottle.winePath, prefix: bottle.prefixPath)
            return
        }

        let downloadPath = "\(bottle.prefixPath)/drive_c/users/crossover/Downloads/SteamSetup.exe"
        try FileManager.default.createDirectory(
            atPath: "\(bottle.prefixPath)/drive_c/users/crossover/Downloads",
            withIntermediateDirectories: true
        )

        let (tempURL, response) = try await URLSession.shared.download(from: steamInstallerURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw WineError.installationFailed("Descarga de Steam falló con HTTP \(http.statusCode)")
        }

        let installerURL = URL(fileURLWithPath: downloadPath)
        try? FileManager.default.removeItem(at: installerURL)
        try FileManager.default.moveItem(at: tempURL, to: installerURL)

        let result = try await runWine(
            winePath: bottle.winePath,
            arguments: [downloadPath, "/S"],
            prefix: bottle.prefixPath,
            environment: steamInstallEnvironment(prefix: bottle.prefixPath),
            allowNonZeroExit: true
        )
        try await terminateWineProcesses(winePath: bottle.winePath, prefix: bottle.prefixPath)

        if FileManager.default.fileExists(atPath: bottle.steamPath) {
            return
        }

        let detail = Self.summarizeWineOutput(result.output)
        if Self.isRecoverableSteamServiceCrash(result.output) {
            throw WineError.installationFailed(
                "SteamService falló, pero Steam.exe no apareció en el bottle. \(detail)"
            )
        }

        throw WineError.installationFailed(
            "Steam no terminó de instalarse. Código \(result.exitCode). \(detail)"
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

    @discardableResult
    private func runWine(
        winePath: String,
        arguments: [String],
        prefix: String,
        environment: [String: String]? = nil,
        allowNonZeroExit: Bool = false
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = arguments
        process.environment = environment ?? [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                if allowNonZeroExit {
                    return ProcessResult(exitCode: process.terminationStatus, output: output)
                }

                throw WineError.launchFailed(output.isEmpty ? "Wine terminó con código \(process.terminationStatus)" : output)
            }
            return ProcessResult(exitCode: process.terminationStatus, output: output)
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

    private func steamInstallEnvironment(prefix: String) -> [String: String] {
        [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "winedbg.exe=d",
            "MVK_CONFIG_LOG_LEVEL": "0"
        ]
    }

    private func terminateWineProcesses(winePath: String, prefix: String) async throws {
        guard let wineserverPath = siblingTool(named: "wineserver", forWinePath: winePath) else {
            return
        }

        _ = try? await runExecutableAllowingFailure(
            path: wineserverPath,
            arguments: ["-k"],
            prefix: prefix
        )
    }

    private func runExecutableAllowingFailure(path: String, arguments: [String], prefix: String) async throws -> ProcessResult {
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
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, output: output)
    }

    nonisolated static func isRecoverableSteamServiceCrash(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        return lowercased.contains("steamservice")
            && lowercased.contains("unhandled page fault")
    }

    nonisolated static func summarizeWineOutput(_ output: String) -> String {
        let relevantLines = output
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                let lowercased = line.lowercased()
                return lowercased.contains("error")
                    || lowercased.contains("fail")
                    || lowercased.contains("unhandled")
                    || lowercased.contains("steamservice")
            }
            .prefix(4)

        guard !relevantLines.isEmpty else { return "" }
        return relevantLines.joined(separator: " ")
    }
}
