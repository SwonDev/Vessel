import Foundation
import XCTest
@testable import Vessel

final class SteamUninstallPlannerTests: XCTestCase {
    private let fileManager = FileManager.default

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-steam-uninstall-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeManifest(appID: String, installDirectory: String, to url: URL) throws {
        let content = """
        "AppState"
        {
            "appid" "\(appID)"
            "name" "Test Game"
            "StateFlags" "4"
            "installdir" "\(installDirectory)"
        }
        """
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
    }

    func testIncludesVerifiedLegacyFolderAndEveryManifestForDeletedInstallDirectory() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }
        let steam = root.appendingPathComponent("Steam", isDirectory: true)
        let steamapps = steam.appendingPathComponent("steamapps", isDirectory: true)
        let common = steamapps.appendingPathComponent("common", isDirectory: true)
        let canonical = common.appendingPathComponent("Test Game", isDirectory: true)
        let legacy = common.appendingPathComponent("App 42", isDirectory: true)
        try fileManager.createDirectory(at: canonical, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        let executable = canonical.appendingPathComponent("Game.exe")
        try Data("MZ".utf8).write(to: executable)

        try writeManifest(
            appID: "42",
            installDirectory: "Test Game",
            to: steamapps.appendingPathComponent("appmanifest_42.acf")
        )
        try writeManifest(
            appID: "99",
            installDirectory: "Test Game",
            to: steamapps.appendingPathComponent("appmanifest_99.acf")
        )
        try writeManifest(
            appID: "100",
            installDirectory: "Unrelated",
            to: steamapps.appendingPathComponent("appmanifest_100.acf")
        )
        try writeManifest(
            appID: "42",
            installDirectory: "App 42",
            to: legacy.appendingPathComponent("steamapps/appmanifest_42.acf")
        )

        let plan = SteamUninstallPlanner.plan(
            appID: "42",
            executablePath: executable.path,
            steamDirectory: steam.path,
            fileManager: fileManager
        )

        XCTAssertEqual(
            Set(plan.installFolders),
            Set([PathSafety.canonical(canonical.path), PathSafety.canonical(legacy.path)])
        )
        XCTAssertEqual(
            Set(plan.manifestFiles),
            Set([
                PathSafety.canonical(steamapps.appendingPathComponent("appmanifest_42.acf").path),
                PathSafety.canonical(steamapps.appendingPathComponent("appmanifest_99.acf").path)
            ])
        )
    }

    func testRejectsLegacyFolderWithoutMatchingNestedManifest() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }
        let steam = root.appendingPathComponent("Steam", isDirectory: true)
        let legacy = steam.appendingPathComponent("steamapps/common/App 42", isDirectory: true)
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try writeManifest(
            appID: "7",
            installDirectory: "App 42",
            to: legacy.appendingPathComponent("steamapps/appmanifest_42.acf")
        )

        let plan = SteamUninstallPlanner.plan(
            appID: "42",
            executablePath: steam.appendingPathComponent("missing/Game.exe").path,
            steamDirectory: steam.path,
            fileManager: fileManager
        )
        XCTAssertTrue(plan.installFolders.isEmpty)
    }

    func testRejectsLegacySymlinkEscapingSteamCommon() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }
        let steam = root.appendingPathComponent("Steam", isDirectory: true)
        let common = steam.appendingPathComponent("steamapps/common", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try fileManager.createDirectory(at: common, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try writeManifest(
            appID: "42",
            installDirectory: "App 42",
            to: outside.appendingPathComponent("steamapps/appmanifest_42.acf")
        )
        try fileManager.createSymbolicLink(
            at: common.appendingPathComponent("App 42"),
            withDestinationURL: outside
        )

        let plan = SteamUninstallPlanner.plan(
            appID: "42",
            executablePath: steam.appendingPathComponent("missing/Game.exe").path,
            steamDirectory: steam.path,
            fileManager: fileManager
        )
        XCTAssertTrue(plan.installFolders.isEmpty)
    }

    func testEpicResidualCleanupAcceptsOnlyARealDescendantOfGamesRoot() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }
        let games = root.appendingPathComponent("Games", isDirectory: true)
        let installed = games.appendingPathComponent("Installed Game", isDirectory: true)
        try fileManager.createDirectory(at: installed, withIntermediateDirectories: true)

        XCTAssertEqual(
            LegendaryManager.safeResidualInstallDirectory(
                installPath: installed.path,
                gamesRoot: games.path,
                fileManager: fileManager
            ),
            PathSafety.canonical(installed.path)
        )
        XCTAssertNil(LegendaryManager.safeResidualInstallDirectory(
            installPath: games.path,
            gamesRoot: games.path,
            fileManager: fileManager
        ))
        XCTAssertNil(LegendaryManager.safeResidualInstallDirectory(
            installPath: root.appendingPathComponent("Games-Other").path,
            gamesRoot: games.path,
            fileManager: fileManager
        ))
    }

    func testEpicResidualCleanupRejectsSymlinkOutsideGamesRoot() throws {
        let root = try makeRoot()
        defer { try? fileManager.removeItem(at: root) }
        let games = root.appendingPathComponent("Games", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try fileManager.createDirectory(at: games, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = games.appendingPathComponent("Escaped Game")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertNil(LegendaryManager.safeResidualInstallDirectory(
            installPath: link.path,
            gamesRoot: games.path,
            fileManager: fileManager
        ))
    }
}
