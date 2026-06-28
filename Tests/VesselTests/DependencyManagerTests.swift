import Foundation
import XCTest
@testable import Vessel

final class DependencyManagerTests: XCTestCase {
    func testDecodesGitHubReleaseSnakeCaseFields() throws {
        let json = """
        {
          "tag_name": "11.10",
          "assets": [
            {
              "name": "wine-devel-11.10-osx64.tar.xz",
              "browser_download_url": "https://example.com/wine-devel-11.10-osx64.tar.xz"
            }
          ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(DependencyManager.WineRelease.self, from: json)

        XCTAssertEqual(release.tagName, "11.10")
        XCTAssertEqual(release.assets.first?.browserDownloadURL, "https://example.com/wine-devel-11.10-osx64.tar.xz")
    }

    func testSelectsWineDevelTarballBeforeOtherOSXAssets() throws {
        let release = DependencyManager.WineRelease(
            tagName: "11.10",
            assets: [
                .init(name: "wine-staging-11.10-osx64.tar.xz", browserDownloadURL: "https://example.com/staging.tar.xz"),
                .init(name: "wine-devel-11.10-osx64.tar.xz", browserDownloadURL: "https://example.com/devel.tar.xz")
            ]
        )

        let asset = DependencyManager.selectWineAsset(from: release)

        XCTAssertEqual(asset?.browserDownloadURL, "https://example.com/devel.tar.xz")
    }

    func testNormalizesNestedWineEngineExtraction() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VesselTests-\(UUID().uuidString)")
        let staging = tempRoot.appendingPathComponent("staging")
        let nestedBin = staging
            .appendingPathComponent("wine-devel-11.10-osx64")
            .appendingPathComponent("bin")
        let finalEngine = tempRoot
            .appendingPathComponent("Engines")
            .appendingPathComponent(WineEngineLocator.portableEngineName)
        try FileManager.default.createDirectory(at: nestedBin, withIntermediateDirectories: true)
        let wine = nestedBin.appendingPathComponent("wine64")
        try "#!/bin/sh\nexit 0\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let normalizedPath = try WineEngineLocator.normalizeExtractedEngine(
            stagingDirectory: staging,
            finalEngineDirectory: finalEngine
        )

        XCTAssertEqual(normalizedPath, finalEngine.appendingPathComponent("bin/wine64").path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: normalizedPath))
        XCTAssertNotNil(WineEngineLocator.findPortableWineBinary(enginesDirectory: finalEngine.deletingLastPathComponent().path))
    }

    func testNormalizesWineAppBundleExtraction() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VesselTests-\(UUID().uuidString)")
        let staging = tempRoot.appendingPathComponent("app-staging")
        let bundleWineBin = staging
            .appendingPathComponent("Wine Devel.app")
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("wine")
            .appendingPathComponent("bin")
        let finalEngine = tempRoot
            .appendingPathComponent("Engines")
            .appendingPathComponent(WineEngineLocator.portableEngineName)
        try FileManager.default.createDirectory(at: bundleWineBin, withIntermediateDirectories: true)
        let wine = bundleWineBin.appendingPathComponent("wine")
        try "#!/bin/sh\nexit 0\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let normalizedPath = try WineEngineLocator.normalizeExtractedEngine(
            stagingDirectory: staging,
            finalEngineDirectory: finalEngine
        )

        XCTAssertEqual(normalizedPath, finalEngine.appendingPathComponent("bin/wine").path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: normalizedPath))
    }

    func testDetectsRecoverableSteamServiceCrash() {
        let output = """
        wine: Unhandled page fault on read access to 00000000 at address 00461342
        Backtrace:
        0 0x00461342 in steamservice (+0x61342)
        """

        XCTAssertTrue(WineManager.isRecoverableSteamServiceCrash(output))
    }

    func testSummarizesRelevantWineOutput() {
        let output = """
        harmless line
        wine: Unhandled page fault on read access to 00000000
        0 0x00461342 in steamservice (+0x61342)
        """

        let summary = WineManager.summarizeWineOutput(output)

        XCTAssertTrue(summary.contains("Unhandled page fault"))
        XCTAssertTrue(summary.contains("steamservice"))
        XCTAssertFalse(summary.contains("harmless line"))
    }

    func testSteamLaunchUsesCompatibilityArguments() {
        XCTAssertTrue(WineManager.steamLaunchArguments.contains("-cef-disable-gpu"))
        XCTAssertTrue(WineManager.steamLaunchArguments.contains("-cef-disable-sandbox"))
        XCTAssertTrue(WineManager.steamLaunchArguments.contains("-no-cef-sandbox"))
    }

    @MainActor
    func testLiveWineAutoInstallWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["VESSEL_RUN_LIVE_INSTALL_TEST"] == "1" else {
            throw XCTSkip("La descarga real de Wine solo se ejecuta bajo demanda.")
        }

        let manager = DependencyManager()
        let winePath = try await manager.ensureWinePortableInstalled { _, _ in }

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: winePath))
        XCTAssertEqual(WineEngineLocator.findPortableWineBinary(), winePath)
    }

    @MainActor
    func testLiveSteamInstallWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["VESSEL_RUN_LIVE_STEAM_TEST"] == "1" else {
            throw XCTSkip("La instalación real de Steam solo se ejecuta bajo demanda.")
        }

        guard let winePath = WineEngineLocator.findPortableWineBinary() else {
            throw XCTSkip("Wine portable no está instalado.")
        }

        let bottle = Bottle(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Steam Integration Test",
            winePath: winePath
        )
        try? FileManager.default.removeItem(atPath: bottle.prefixPath)
        defer { try? FileManager.default.removeItem(atPath: bottle.prefixPath) }

        let manager = WineManager()
        try await manager.createBottle(at: bottle.prefixPath, winePath: bottle.winePath)
        try await manager.installSteam(bottle: bottle)

        XCTAssertTrue(FileManager.default.fileExists(atPath: bottle.steamPath))
    }
}
