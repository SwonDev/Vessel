import Foundation
import XCTest
@testable import Vessel

final class DependencyManagerTests: XCTestCase {
    func testWinePrefixReadinessRequiresRegistersAndCoreDLLs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VesselPrefixReadiness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("drive_c/windows/system32"),
            withIntermediateDirectories: true
        )
        XCTAssertFalse(WineManager.isWinePrefixInitialized(at: root.path))

        for relativePath in [
            "system.reg",
            "user.reg",
            "drive_c/windows/system32/kernel32.dll",
            "drive_c/windows/system32/ntdll.dll"
        ] {
            try Data(repeating: 0x01, count: 2_048)
                .write(to: root.appendingPathComponent(relativePath))
        }
        XCTAssertTrue(WineManager.isWinePrefixInitialized(at: root.path))

        try Data().write(to: root.appendingPathComponent("user.reg"))
        XCTAssertFalse(WineManager.isWinePrefixInitialized(at: root.path))
    }

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

    func testInteractiveSteamEngineNeverFallsThroughToUnifiedWine() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VesselSteamRoleTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        for engine in [WineEngineLocator.unifiedEngineName, WineEngineLocator.portableEngineName] {
            let bin = tempRoot.appendingPathComponent(engine).appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let wine = bin.appendingPathComponent("wine")
            try "#!/bin/sh\nexit 0\n".write(to: wine, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        }

        let resolved = WineEngineLocator.interactiveSteamWineBinary(
            enginesDirectory: tempRoot.path
        )

        XCTAssertEqual(
            resolved,
            tempRoot.appendingPathComponent(WineEngineLocator.portableEngineName)
                .appendingPathComponent("bin/wine").path
        )
    }

    func testFullEngineRejectsExternalRuntimeMarker() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VesselExternalEngineTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let engine = tempRoot.appendingPathComponent(WineEngineLocator.fullEngineName)
        let bin = engine.appendingPathComponent("bin")
        let windows = engine.appendingPathComponent("lib/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)

        let wine = bin.appendingPathComponent("wine")
        try "#!/bin/sh\nexit 0\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try Data([0x4d, 0x5a]).write(to: windows.appendingPathComponent("winewrapper.exe"))

        XCTAssertTrue(WineEngineLocator.containsExternalFullEngineRuntime(enginesDirectory: tempRoot.path))
        XCTAssertNil(WineEngineLocator.fullWineBinary(enginesDirectory: tempRoot.path))
        XCTAssertFalse(WineEngineLocator.isFullEngineInstalled(enginesDirectory: tempRoot.path))
    }

    func testWineDiscoveryOnlyIncludesVesselManagedEngine() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VesselEngineDiscoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let externalWine = tempRoot
            .appendingPathComponent("Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64")
        try FileManager.default.createDirectory(
            at: externalWine.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: externalWine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalWine.path)

        let engines = tempRoot.appendingPathComponent("Engines")
        let managedWine = engines
            .appendingPathComponent(WineEngineLocator.portableEngineName)
            .appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(
            at: managedWine.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: managedWine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedWine.path)

        let detected = WineEngineLocator.detectWineInstallations(
            enginesDirectory: engines.path,
            homeDirectory: tempRoot.path
        )

        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected.first?.name, "Wine (Vessel portable)")
        XCTAssertEqual(detected.first?.path, managedWine.path)
    }

    func testWineDiscoveryFallsBackToAnotherManagedEngine() throws {
        let engines = FileManager.default.temporaryDirectory
            .appendingPathComponent("VesselManagedDiscoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: engines) }

        let unifiedWine = engines
            .appendingPathComponent(WineEngineLocator.unifiedEngineName)
            .appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(
            at: unifiedWine.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(
            to: unifiedWine,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: unifiedWine.path
        )

        let detected = WineEngineLocator.detectWineInstallations(
            enginesDirectory: engines.path
        )
        XCTAssertEqual(detected.map(\.path), [unifiedWine.path])
        XCTAssertEqual(detected.first?.name, "Wine unificado de Vessel")
    }

    func testManagedWinePathRejectsSymbolicLinkEscapingEngines() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VesselManagedSymlinkTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let engines = tempRoot.appendingPathComponent("Engines")
        let externalWine = tempRoot.appendingPathComponent("External/bin/wine")
        let apparentWine = engines
            .appendingPathComponent(WineEngineLocator.unifiedEngineName)
            .appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(
            at: externalWine.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: apparentWine.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(
            to: externalWine,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: externalWine.path
        )
        try FileManager.default.createSymbolicLink(
            at: apparentWine,
            withDestinationURL: externalWine
        )

        XCTAssertFalse(WineEngineLocator.isManagedRuntimePath(
            apparentWine.path,
            enginesDirectory: engines.path
        ))
        XCTAssertNil(WineEngineLocator.wineBinary(
            in: WineEngineLocator.unifiedEngineName,
            enginesDirectory: engines.path
        ))
    }

    func testStoredExternalWinePathMigratesToManagedEngine() throws {
        let engines = FileManager.default.temporaryDirectory
            .appendingPathComponent("VesselStoredWineTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: engines) }

        let managed = engines
            .appendingPathComponent(WineEngineLocator.unifiedEngineName)
            .appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(
            at: managed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: managed, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managed.path)

        XCTAssertEqual(
            WineEngineLocator.repairedStoredWinePath(
                "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine",
                enginesDirectory: engines.path
            ),
            managed.path
        )
        XCTAssertEqual(
            WineEngineLocator.repairedStoredWinePath(managed.path, enginesDirectory: engines.path),
            managed.path
        )

        let quarantined = engines
            .appendingPathComponent("ExternalRuntimeQuarantine")
            .appendingPathComponent("wine-full-copy/bin/wine")
        XCTAssertEqual(
            WineEngineLocator.repairedStoredWinePath(
                quarantined.path,
                enginesDirectory: engines.path
            ),
            managed.path
        )
    }

    func testManagedDXMTDetectionIgnoresGlobalTools() throws {
        let engines = FileManager.default.temporaryDirectory
            .appendingPathComponent("VesselManagedDXMTTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: engines) }

        XCTAssertNil(DependencyManager.findManagedDXMT(enginesDirectory: engines.path))

        let builtins = engines
            .appendingPathComponent(WineEngineLocator.unifiedEngineName)
            .appendingPathComponent("lib/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: builtins, withIntermediateDirectories: true)
        try Data(repeating: 0x01, count: 1_100_000)
            .write(to: builtins.appendingPathComponent("d3d11.dll"))
        try Data([0x01]).write(to: builtins.appendingPathComponent("winemetal.dll"))

        XCTAssertEqual(
            DependencyManager.findManagedDXMT(enginesDirectory: engines.path),
            builtins.appendingPathComponent("d3d11.dll").path
        )
    }

    func testQuarantinesExternalRuntimeResidueWithoutTouchingManagedEngine() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VesselRuntimeQuarantineTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let activeEngine = tempRoot.appendingPathComponent(WineEngineLocator.fullEngineName)
        let managedWine = activeEngine.appendingPathComponent("bin/wine")
        let compatibilityDB = activeEngine
            .appendingPathComponent("cxcompatdb-home")
            .appendingPathComponent("compatdb-26.dat")
        let externalBackup = tempRoot
            .appendingPathComponent("wine-full-crossover-bak")
            .appendingPathComponent("lib/wine/x86_64-windows/winewrapper.exe")

        for file in [managedWine, compatibilityDB, externalBackup] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0x01]).write(to: file)
        }

        let quarantined = try DependencyManager.quarantineExternalRuntimeResidue(
            enginesDirectory: tempRoot.path
        )

        XCTAssertEqual(quarantined.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedWine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: compatibilityDB.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalBackup.path))
        XCTAssertTrue(quarantined.allSatisfy {
            $0.hasPrefix(tempRoot.appendingPathComponent("ExternalRuntimeQuarantine").path)
                && FileManager.default.fileExists(atPath: $0)
        })
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
        // Flags imprescindibles para que CEF/Steam arranquen bajo Wine en macOS.
        XCTAssertTrue(WineManager.steamLaunchArguments.contains("-no-cef-sandbox"))
        XCTAssertTrue(WineManager.steamLaunchArguments.contains("-noverifyfiles"))
        XCTAssertTrue(WineManager.steamLaunchArguments.contains("-skipinitialbootstrap"))
        // GUARD DE REGRESIÓN: `-cef-disable-gpu` y `-noreactlogin` fuerzan software
        // compositing que Wine no hace bien en macOS → PANTALLA NEGRA. Nunca deben
        // estar en los argumentos (ver WineManager.steamLaunchArguments).
        XCTAssertFalse(WineManager.steamLaunchArguments.contains("-cef-disable-gpu"))
        XCTAssertFalse(WineManager.steamLaunchArguments.contains("-noreactlogin"))
    }

    func testSteamWebHelperWrapperForcesValidatedSoftwareCompositor() throws {
        let source = try String(
            contentsOf: VesselPaths.devRepoRoot
                .appendingPathComponent("Resources/wrapper/steamwebhelper-wrapper.c"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("--disable-gpu --single-process"))
        let wrapper = VesselPaths.devRepoRoot
            .appendingPathComponent("Resources/steamwebhelper-wrapper.exe").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrapper))
        XCTAssertTrue(SteamWebHelperWrapperInstaller.isTrustedWrapper(atPath: wrapper))
    }

    func testManagedCabextractNeverUsesGlobalInstallation() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VesselCabextractTests-\(UUID().uuidString)")
        let engines = tempRoot.appendingPathComponent("Engines")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let selectedWine = engines
            .appendingPathComponent(WineEngineLocator.unifiedEngineName)
            .appendingPathComponent("bin/wine")
        XCTAssertNil(WineManager.managedCabextractPath(
            for: selectedWine.path,
            enginesDirectory: engines.path
        ))

        let externalWine = tempRoot.appendingPathComponent("ExternalWine/bin/wine")
        let externalCabextract = externalWine.deletingLastPathComponent()
            .appendingPathComponent("cabextract")
        try FileManager.default.createDirectory(
            at: externalCabextract.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for executable in [externalWine, externalCabextract] {
            try "#!/bin/sh\nexit 0\n".write(
                to: executable,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        XCTAssertNil(WineManager.managedCabextractPath(
            for: externalWine.path,
            enginesDirectory: engines.path
        ))

        let cabextract = engines
            .appendingPathComponent(WineEngineLocator.fullEngineName)
            .appendingPathComponent("bin/cabextract")
        let fullWine = cabextract.deletingLastPathComponent().appendingPathComponent("wine")
        try FileManager.default.createDirectory(
            at: cabextract.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for executable in [fullWine, cabextract] {
            try "#!/bin/sh\nexit 0\n".write(
                to: executable,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }

        XCTAssertEqual(
            WineManager.managedCabextractPath(
                for: selectedWine.path,
                enginesDirectory: engines.path
            ),
            cabextract.path
        )
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
