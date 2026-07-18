import Foundation
import XCTest
@testable import Vessel

final class SteamAppManifestWriterTests: XCTestCase {
    private func makeSteamTree() throws -> (root: URL, steam: URL, game: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-manifest-test-\(UUID().uuidString)", isDirectory: true)
        let steam = root.appendingPathComponent("Steam", isDirectory: true)
        let game = steam.appendingPathComponent("steamapps/common/Dead Cells", isDirectory: true)
        try FileManager.default.createDirectory(
            at: game.appendingPathComponent("steamapps", isDirectory: true),
            withIntermediateDirectories: true
        )
        return (root, steam, game)
    }

    func testCopiesCompleteSteamCMDManifestIntoClientLibrary() throws {
        let tree = try makeSteamTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let source = tree.game.appendingPathComponent("steamapps/appmanifest_588650.acf")
        try """
        "AppState"
        {
            "appid" "588650"
            "StateFlags" "4"
            "installdir" "Wrong Folder"
            "buildid" "19007642"
            "InstalledDepots"
            {
                "588651" { "manifest" "123456789" }
            }
        }
        """.write(to: source, atomically: true, encoding: .utf8)

        let created = SteamAppManifestWriter.run(
            steamDirectory: tree.steam.path,
            games: [(appId: "588650", name: "Dead Cells", installPath: tree.game.path,
                     exe: tree.game.appendingPathComponent("deadcells_gl.exe").path)],
            steamID64: "76561198000000000"
        )

        XCTAssertEqual(created, 1)
        let destination = tree.steam.appendingPathComponent("steamapps/appmanifest_588650.acf")
        let installed = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(installed.contains("\"installdir\"\t\t\"Dead Cells\""))
        XCTAssertTrue(installed.contains(#""buildid" "19007642""#))
        XCTAssertTrue(installed.contains(#""manifest" "123456789""#))
    }

    func testPreservesExistingInstalledClientManifest() throws {
        let tree = try makeSteamTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let destination = tree.steam.appendingPathComponent("steamapps/appmanifest_588650.acf")
        let original = """
        "AppState"
        {
            "appid" "588650"
            "StateFlags" "4"
            "installdir" "Dead Cells"
            "buildid" "already-managed-by-client"
        }
        """
        try original.write(to: destination, atomically: true, encoding: .utf8)

        let created = SteamAppManifestWriter.run(
            steamDirectory: tree.steam.path,
            games: [(appId: "588650", name: "Dead Cells", installPath: tree.game.path, exe: "")],
            steamID64: "76561198000000000"
        )

        XCTAssertEqual(created, 0)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), original)
    }
}
