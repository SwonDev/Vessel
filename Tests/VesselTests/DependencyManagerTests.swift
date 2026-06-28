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
}
