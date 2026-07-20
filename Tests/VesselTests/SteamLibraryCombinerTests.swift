import XCTest
@testable import Vessel

@MainActor
final class SteamLibraryCombinerTests: XCTestCase {
    func testInstalledGameReplacesOwnedEntryWithoutChangingTotal() {
        let owned = [
            SteamAccountService.OwnedGame(appId: "10", name: "Installed"),
            SteamAccountService.OwnedGame(appId: "20", name: "Available")
        ]
        let installed = GameInstall(
            name: "Installed",
            executablePath: "/Games/Installed/game.exe",
            steamAppId: "10",
            installPath: "/Games/Installed"
        )

        let games = SteamLibraryCombiner.games(installed: [installed], owned: owned)

        XCTAssertEqual(games.count, 2)
        XCTAssertEqual(games.first(where: { $0.id == "10" })?.installed, true)
        XCTAssertEqual(games.first(where: { $0.id == "20" })?.installed, false)
        XCTAssertEqual(owned.map(\.appId), ["10", "20"], "Combinar estados nunca debe mutar la propiedad de Steam")
    }

    func testUninstalledGameReappearsImmediatelyAsOwned() {
        let owned = [SteamAccountService.OwnedGame(appId: "10", name: "Owned")]

        let games = SteamLibraryCombiner.games(installed: [], owned: owned)

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].id, "10")
        XCTAssertFalse(games[0].installed)
    }

    func testUpdateAndInstallMetadataArePreserved() {
        let installed = GameInstall(
            name: "Installed",
            executablePath: "/Games/Installed/game.exe",
            steamAppId: "10",
            installPath: "/Games/Installed"
        )

        let games = SteamLibraryCombiner.games(
            installed: [installed],
            owned: [],
            updatesAvailable: ["10"],
            installSize: { $0 == "10" ? 42 : nil }
        )

        XCTAssertTrue(games[0].updateAvailable)
        XCTAssertEqual(games[0].installSizeBytes, 42)
        XCTAssertEqual(games[0].installPath, "/Games/Installed")
        XCTAssertEqual(games[0].executablePath, "/Games/Installed/game.exe")
    }
}
