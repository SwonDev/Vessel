import Foundation
import XCTest
@testable import Vessel

@MainActor
final class GoldbergManagerTests: XCTestCase {
    func testWritesInstalledBuildIDFromStandardSteamManifest() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("Vessel-GoldbergBuildIDTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let steamApps = root.appendingPathComponent(
            "prefix/drive_c/Program Files (x86)/Steam/steamapps",
            isDirectory: true
        )
        let gameDir = steamApps.appendingPathComponent("common/Test Game/bin64", isDirectory: true)
        let cache = root.appendingPathComponent("goldberg", isDirectory: true)
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)

        let executable = gameDir.appendingPathComponent("TestGame.exe")
        let steamAPI = gameDir.appendingPathComponent("steam_api64.dll")
        try Data("MZ".utf8).write(to: executable)
        try Data("official-SteamClient020".utf8).write(to: steamAPI)
        try Data("vessel-goldberg".utf8).write(to: cache.appendingPathComponent("steam_api64.dll"))
        try """
        "AppState"
        {
            "appid"     "123456"
            "buildid"   "24080983"
        }
        """.write(
            to: steamApps.appendingPathComponent("appmanifest_123456.acf"),
            atomically: true,
            encoding: .utf8
        )

        let manager = GoldbergManager(cacheDirectoryOverride: cache.path)
        XCTAssertEqual(
            GoldbergManager.installedBuildID(
                forExecutable: executable.path,
                appId: "123456",
                fileManager: fm
            ),
            "24080983"
        )
        XCTAssertTrue(manager.applyToGame(gameExecutable: executable.path, appId: "123456"))

        XCTAssertEqual(
            try publicBuildID(
                in: gameDir.appendingPathComponent("steam_settings/branches.json")
            ),
            24_080_983
        )
    }

    func testPatchesEmbeddedSteamworks4jAndRestoresItForRealSteam() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("Vessel-GoldbergTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let prefix = root.appendingPathComponent("prefix", isDirectory: true)
        let gameDir = prefix
            .appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps/common/Test Game", isDirectory: true)
        let userTemp = prefix.appendingPathComponent("drive_c/users/tester/Temp", isDirectory: true)
        let cache = root.appendingPathComponent("goldberg", isDirectory: true)
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: userTemp, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)

        let executable = gameDir.appendingPathComponent("TestGame.exe")
        try Data("MZ".utf8).write(to: executable)
        let embeddedSteamApps = gameDir.appendingPathComponent("steamapps", isDirectory: true)
        try fm.createDirectory(at: embeddedSteamApps, withIntermediateDirectories: true)
        try """
        "AppState"
        {
            "appid"   "646570"
            "buildid" "99887766"
        }
        """.write(
            to: embeddedSteamApps.appendingPathComponent("appmanifest_646570.acf"),
            atomically: true,
            encoding: .utf8
        )
        let original = Data("official-SteamClient017-SteamUser021".utf8)
        let replacement = Data("vessel-goldberg".utf8)
        try replacement.write(to: cache.appendingPathComponent("steam_api64.dll"))

        let archive = gameDir.appendingPathComponent("desktop.jar")
        try makeSteamworks4jArchive(at: archive, originalSteamAPI: original, root: root)
        let manager = GoldbergManager(cacheDirectoryOverride: cache.path)

        XCTAssertTrue(manager.hasEmbeddedSteamworks(gameExecutable: executable.path))
        XCTAssertTrue(manager.hasLegacyLibGDXOpenGL(gameExecutable: executable.path))
        XCTAssertTrue(manager.applyToGame(gameExecutable: executable.path, appId: "646570"))
        XCTAssertEqual(try archiveEntry("steam_api64.dll", in: archive), replacement)
        let backup = URL(fileURLWithPath: archive.path + ".vessel-orig")
        XCTAssertEqual(try archiveEntry("steam_api64.dll", in: backup), original)

        // Cada lanzamiento vuelve a preparar el runtime. Debe ser idempotente y conservar siempre
        // el DLL oficial en el respaldo, nunca convertir el reemplazo de Vessel en el "original".
        XCTAssertTrue(manager.applyToGame(gameExecutable: executable.path, appId: "646570"))
        XCTAssertEqual(try archiveEntry("steam_api64.dll", in: archive), replacement)
        XCTAssertEqual(try archiveEntry("steam_api64.dll", in: backup), original)

        let extraction = userTemp.appendingPathComponent("steamworks4j/1.9.0", isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: extraction.appendingPathComponent("steam_api64.dll")), replacement)
        XCTAssertEqual(
            try String(contentsOf: extraction.appendingPathComponent("steam_appid.txt"), encoding: .utf8),
            "646570"
        )
        let interfaces = try String(
            contentsOf: extraction.appendingPathComponent("steam_settings/steam_interfaces.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(interfaces.contains("SteamClient017"))
        XCTAssertTrue(interfaces.contains("SteamUser021"))
        XCTAssertEqual(
            try publicBuildID(
                in: extraction.appendingPathComponent("steam_settings/branches.json")
            ),
            99_887_766
        )

        manager.restoreGame(gameExecutable: executable.path)

        XCTAssertEqual(try archiveEntry("steam_api64.dll", in: archive), original)
        XCTAssertFalse(fm.fileExists(atPath: extraction.appendingPathComponent("steam_api64.dll").path))
    }

    private func makeSteamworks4jArchive(at archive: URL, originalSteamAPI: Data, root: URL) throws {
        let staging = root.appendingPathComponent("jar-source", isDirectory: true)
        let properties = staging.appendingPathComponent(
            "META-INF/maven/com.code-disaster.steamworks4j/steamworks4j/pom.properties"
        )
        try FileManager.default.createDirectory(
            at: properties.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try originalSteamAPI.write(to: staging.appendingPathComponent("steam_api64.dll"))
        try Data("jni-bridge".utf8).write(to: staging.appendingPathComponent("steamworks4j64.dll"))
        try Data("lwjgl".utf8).write(to: staging.appendingPathComponent("lwjgl64.dll"))
        let libGDXClass = staging.appendingPathComponent(
            "com/badlogic/gdx/backends/lwjgl/LwjglApplication.class"
        )
        try FileManager.default.createDirectory(
            at: libGDXClass.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("class".utf8).write(to: libGDXClass)
        try "version=1.9.0\n".write(to: properties, atomically: true, encoding: .utf8)
        try run(
            "/usr/bin/zip",
            arguments: [
                "-q", "-r", archive.path,
                "steam_api64.dll", "steamworks4j64.dll", "lwjgl64.dll", "META-INF", "com",
            ],
            currentDirectory: staging
        )
    }

    private func archiveEntry(_ entry: String, in archive: URL) throws -> Data {
        try run(
            "/usr/bin/unzip",
            arguments: ["-p", archive.path, entry]
        )
    }

    private func publicBuildID(in branchesFile: URL) throws -> Int? {
        let data = try Data(contentsOf: branchesFile)
        let branches = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        return branches.first(where: {
            ($0["name"] as? String)?.caseInsensitiveCompare("public") == .orderedSame
        })?["build_id"] as? Int
    }

    @discardableResult
    private func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }
}
