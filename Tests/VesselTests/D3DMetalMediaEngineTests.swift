import Foundation
import XCTest
@testable import Vessel

final class D3DMetalMediaEngineTests: XCTestCase {
    private let fileManager = FileManager.default

    func testManagedRuntimeSelectsMediaComponentsWithoutRestrictedFamilies() {
        let components = ManagedGStreamerRuntime.componentPackages

        XCTAssertTrue(components.contains(where: { $0.contains("core") }))
        XCTAssertTrue(components.contains(where: { $0.contains("playback") }))
        XCTAssertTrue(components.contains(where: { $0.contains("codecs") }))
        XCTAssertTrue(components.contains(where: { $0.contains("effects") }))
        XCTAssertFalse(components.contains(where: { $0.localizedCaseInsensitiveContains("gpl") }))
        XCTAssertFalse(components.contains(where: { $0.localizedCaseInsensitiveContains("restricted") }))
    }

    func testAtomicDirectoryReplacementPreservesTheNewTree() throws {
        let root = temporaryDirectory(named: "atomic-replacement")
        defer { try? fileManager.removeItem(at: root) }
        let staging = root.appendingPathComponent(".runtime-installing", isDirectory: true)
        let final = root.appendingPathComponent("runtime", isDirectory: true)
        try write("anterior", to: final.appendingPathComponent("version.txt"))
        try write("nueva", to: staging.appendingPathComponent("version.txt"))

        try AtomicDirectoryReplacement.replace(
            staging: staging,
            final: final,
            backupPrefix: "runtime"
        )

        XCTAssertEqual(
            try String(contentsOf: final.appendingPathComponent("version.txt"), encoding: .utf8),
            "nueva"
        )
        XCTAssertFalse(fileManager.fileExists(atPath: staging.path))
        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: root.path).allSatisfy {
            !$0.contains("backup")
        })
    }

    func testManagedRuntimeValidationRequiresManifestAndCriticalPlugins() throws {
        let installation = temporaryDirectory(named: "gstreamer-validation")
        defer { try? fileManager.removeItem(at: installation) }

        let runtime = installation.appendingPathComponent(
            "GStreamer.framework/Versions/1.0",
            isDirectory: true
        )
        let requiredFiles = [
            "lib/libgstreamer-1.0.0.dylib",
            "lib/libgstvideo-1.0.0.dylib",
            "lib/gstreamer-1.0/libgstapplemedia.dylib",
            "lib/gstreamer-1.0/libgstdeinterlace.dylib",
            "lib/gstreamer-1.0/libgstisomp4.dylib",
            "libexec/gstreamer-1.0/gst-plugin-scanner",
            "bin/gst-inspect-1.0"
        ]
        for relativePath in requiredFiles {
            try write("runtime", to: runtime.appendingPathComponent(relativePath))
        }
        let manifest = try JSONEncoder().encode(ManagedGStreamerRuntime.currentManifest)
        try manifest.write(
            to: installation.appendingPathComponent(".vessel-gstreamer-runtime.json"),
            options: .atomic
        )

        XCTAssertTrue(ManagedGStreamerRuntime.isInstallationValid(at: installation))

        try fileManager.removeItem(
            at: runtime.appendingPathComponent("lib/gstreamer-1.0/libgstdeinterlace.dylib")
        )
        XCTAssertFalse(ManagedGStreamerRuntime.isInstallationValid(at: installation))
    }

    func testOverlayBuildsIsolatedD3DMetalMediaLayoutAndRemovesCXCompat() throws {
        let root = temporaryDirectory(named: "media-overlay")
        defer { try? fileManager.removeItem(at: root) }

        let engine = root.appendingPathComponent("wine-d3dmetal-media", isDirectory: true)
        let gptk = root.appendingPathComponent("gptk/wine", isDirectory: true)
        let gcenx = root.appendingPathComponent("wine-osx64", isDirectory: true)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: engine.appendingPathComponent("bin/wine"))
        try write(
            "framework",
            to: gptk.appendingPathComponent("lib/external/D3DMetal.framework/D3DMetal")
        )
        try write(
            "d3d-shared",
            to: gptk.appendingPathComponent("lib/external/libd3dshared.dylib")
        )
        for library in D3DMetalMediaEngineProvisioner.d3dMetalLibraries {
            try write(
                "pe-\(library)",
                to: gptk.appendingPathComponent("lib/wine/x86_64-windows/\(library).dll")
            )
        }
        try write(
            "winegstreamer-unix",
            to: gcenx.appendingPathComponent("lib/wine/x86_64-unix/winegstreamer.so")
        )
        try write(
            "winegstreamer-x64",
            to: gcenx.appendingPathComponent("lib/wine/x86_64-windows/winegstreamer.dll")
        )
        try write(
            "winegstreamer-i386",
            to: gcenx.appendingPathComponent("lib/wine/i386-windows/winegstreamer.dll")
        )
        for relativePath in [
            "lib/wine/x86_64-unix/cxcompatdb.so",
            "lib64/wine/x86_64-unix/cxcompatdb.so"
        ] {
            try write("no debe sobrevivir", to: engine.appendingPathComponent(relativePath))
        }

        try D3DMetalMediaEngineProvisioner.applyOverlayFiles(
            to: engine,
            gptkWineRoot: gptk,
            gcenxEngine: gcenx
        )

        XCTAssertTrue(fileManager.fileExists(
            atPath: engine.appendingPathComponent(
                "lib64/apple_gptk/external/D3DMetal.framework/D3DMetal"
            ).path
        ))
        XCTAssertEqual(
            try String(contentsOf: engine.appendingPathComponent(
                "lib/wine/x86_64-windows/winegstreamer.dll"
            ), encoding: .utf8),
            "winegstreamer-x64"
        )
        XCTAssertTrue(fileManager.fileExists(
            atPath: engine.appendingPathComponent(
                "lib/wine/i386-windows/winegstreamer.dll"
            ).path
        ))
        for library in D3DMetalMediaEngineProvisioner.d3dMetalLibraries {
            XCTAssertEqual(
                try fileManager.destinationOfSymbolicLink(
                    atPath: engine.appendingPathComponent(
                        "lib/wine/x86_64-unix/\(library).so"
                    ).path
                ),
                "../../../lib64/apple_gptk/external/libd3dshared.dylib"
            )
        }
        XCTAssertFalse(fileManager.fileExists(
            atPath: engine.appendingPathComponent("lib/wine/x86_64-unix/cxcompatdb.so").path
        ))
        XCTAssertFalse(fileManager.fileExists(
            atPath: engine.appendingPathComponent("lib64/wine/x86_64-unix/cxcompatdb.so").path
        ))

        let identity = try D3DMetalMediaEngineProvisioner.sourceIdentity(
            baseEngine: engine,
            gptkWineRoot: gptk,
            gcenxEngine: gcenx
        )
        let installedWineGStreamer = engine.appendingPathComponent(
            "lib/wine/x86_64-unix/winegstreamer.so"
        )
        let manifest = D3DMetalMediaEngineProvisioner.Manifest(
            source: identity,
            installedWineGStreamerSHA256: try ManagedGStreamerRuntime.sha256Hex(
                of: installedWineGStreamer
            )
        )
        try JSONEncoder().encode(manifest).write(
            to: engine.appendingPathComponent(D3DMetalMediaEngineProvisioner.manifestName),
            options: .atomic
        )
        XCTAssertTrue(D3DMetalMediaEngineProvisioner.isInstallationValid(
            at: engine,
            expectedSource: identity
        ))
    }

    func testMediaEnvironmentUsesPrivateRuntimeWithoutDisablingMediaFoundation() throws {
        let engines = temporaryDirectory(named: "media-environment")
        defer { try? fileManager.removeItem(at: engines) }
        let wine = engines.appendingPathComponent(
            "\(WineEngineLocator.d3dmetalMediaEngineName)/bin/wine"
        )
        try writeExecutable("#!/bin/sh\nexit 0\n", to: wine)

        let environment = D3DMetalMediaEngineProvisioner.mediaEnvironment(
            winePath: wine.path,
            prefix: "/tmp/Vessel/MediaPrefix",
            enginesDirectory: engines.path
        )

        XCTAssertEqual(environment["WINEDLLOVERRIDES"], "mscoree,mshtml=d")
        XCTAssertFalse(environment["WINEDLLOVERRIDES", default: ""].contains("winegstreamer"))
        XCTAssertFalse(environment["WINEDLLOVERRIDES", default: ""].contains("mfplat"))
        XCTAssertEqual(environment["WINEPREFIX"], "/tmp/Vessel/MediaPrefix")
        XCTAssertTrue(environment["GST_PLUGIN_SYSTEM_PATH", default: ""].contains(
            "gstreamer-1.28.2/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0"
        ))
        XCTAssertTrue(environment["DYLD_FALLBACK_LIBRARY_PATH", default: ""].contains(
            "wine-d3dmetal-media/lib64/apple_gptk/external"
        ))
    }

    func testMediaEngineLocatorDoesNotBroadenOtherEngineRoles() throws {
        let engines = temporaryDirectory(named: "media-locator")
        defer { try? fileManager.removeItem(at: engines) }
        let wine = engines.appendingPathComponent(
            "\(WineEngineLocator.d3dmetalMediaEngineName)/bin/wine"
        )
        try writeExecutable("#!/bin/sh\nexit 0\n", to: wine)

        XCTAssertEqual(
            WineEngineLocator.d3dmetalMediaWineBinary(enginesDirectory: engines.path),
            wine.path
        )
        XCTAssertTrue(WineEngineLocator.isD3DMetalMediaEngine(wine.path))
        XCTAssertTrue(WineEngineLocator.isD3DMetalEngine(wine.path))
        XCTAssertTrue(WineEngineLocator.isModernSteamEngine(wine.path))
        XCTAssertTrue(WineEngineLocator.isGameEngine(wine.path))
        XCTAssertFalse(WineEngineLocator.isD3DMetalMediaEngine(
            engines.appendingPathComponent("wine-d3dmetal/bin/wine").path
        ))
    }

    @MainActor
    func testLiveD3DMetalMediaEngineProvisioningWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["VESSEL_RUN_LIVE_MEDIA_ENGINE_TEST"] == "1" else {
            throw XCTSkip("El aprovisionamiento real del motor multimedia solo se ejecuta bajo demanda.")
        }

        if let packagePath = ProcessInfo.processInfo.environment["VESSEL_GSTREAMER_PACKAGE_FILE"],
           !packagePath.isEmpty {
            _ = try await ManagedGStreamerRuntime.shared.ensureInstalled(
                packageFile: URL(fileURLWithPath: packagePath),
                progress: { message, progress in
                    print("[GStreamer \(Int(progress * 100))%] \(message)")
                }
            )
        }

        let manager = DependencyManager()
        let winePath = try await manager.ensureD3DMetalMediaEngine { message, progress in
            print("[Motor multimedia \(Int(progress * 100))%] \(message)")
        }
        let engine = try XCTUnwrap(WineEngineLocator.engineRoot(
            forWineExecutable: URL(fileURLWithPath: winePath)
        ))
        let baseWine = try XCTUnwrap(WineEngineLocator.fullWineBinary())
        let baseEngine = try XCTUnwrap(WineEngineLocator.engineRoot(
            forWineExecutable: URL(fileURLWithPath: baseWine)
        ))
        let gptk = URL(
            fileURLWithPath: GPTKManager().engineRootPath,
            isDirectory: true
        ).appendingPathComponent("wine", isDirectory: true)
        let gcenxWine = try XCTUnwrap(WineEngineLocator.interactiveSteamWineBinary())
        let gcenx = try XCTUnwrap(WineEngineLocator.engineRoot(
            forWineExecutable: URL(fileURLWithPath: gcenxWine)
        ))
        let identity = try D3DMetalMediaEngineProvisioner.sourceIdentity(
            baseEngine: baseEngine,
            gptkWineRoot: gptk,
            gcenxEngine: gcenx
        )

        XCTAssertEqual(winePath, WineEngineLocator.d3dmetalMediaWineBinary())
        XCTAssertTrue(ManagedGStreamerRuntime.isInstallationValid(
            at: ManagedGStreamerRuntime.installationDirectory()
        ))
        XCTAssertTrue(D3DMetalMediaEngineProvisioner.isInstallationValid(
            at: engine,
            expectedSource: identity
        ))
    }

    @MainActor
    func testLiveAutomaticD3D12MediaLaunchWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VESSEL_RUN_LIVE_MEDIA_GAME_TEST"] == "1" else {
            throw XCTSkip("El lanzamiento visual real solo se ejecuta bajo demanda.")
        }
        let appID = try XCTUnwrap(environment["VESSEL_LIVE_STEAM_APP_ID"])
        let match = try XCTUnwrap(BottleStore.shared.bottles.lazy.compactMap { bottle in
            bottle.games.first(where: { $0.steamAppId == appID }).map { (bottle, $0) }
        }.first)
        let manager = WineManager()
        XCTAssertTrue(
            manager.requiresManagedD3D12MediaEngine(match.1.executablePath),
            "El ejecutable real debe activar el perfil por su firma D3D12 + Media Foundation."
        )

        let process = try await manager.launch(
            executable: match.1.executablePath,
            in: match.0,
            steamAppId: appID
        )
        XCTAssertTrue(process.isRunning)

        let holdSeconds = Int(environment["VESSEL_LIVE_GAME_HOLD_SECONDS"] ?? "45") ?? 45
        for _ in 0..<max(1, holdSeconds) {
            try await Task.sleep(for: .seconds(1))
            if !process.isRunning {
                XCTFail("El supervisor del juego terminó antes de completar la validación visual.")
                break
            }
        }
    }

    private func temporaryDirectory(named name: String) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(
            "VesselTests-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func write(_ value: String, to destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: destination)
    }

    private func writeExecutable(_ value: String, to destination: URL) throws {
        try write(value, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }
}
