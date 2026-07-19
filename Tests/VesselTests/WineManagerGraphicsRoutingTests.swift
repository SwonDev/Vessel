import Foundation
import XCTest
@testable import Vessel

@MainActor
final class WineManagerGraphicsRoutingTests: XCTestCase {
    private func makePE32(named name: String, marker: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-graphics-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        var data = Data(repeating: 0, count: 0x200)
        data[0] = 0x4d
        data[1] = 0x5a
        data[0x3c] = 0x80
        data[0x80] = 0x50
        data[0x81] = 0x45
        data[0x84] = 0x4c
        data[0x85] = 0x01
        data.append(Data(marker.utf8))
        try data.write(to: url)
        return url
    }

    private func makePE64(named name: String, marker: String = "") throws -> URL {
        let url = try makePE32(named: name, marker: marker)
        var data = try Data(contentsOf: url)
        data[0x84] = 0x64
        data[0x85] = 0x86
        try data.write(to: url)
        return url
    }

    func testPE32DynamicOpenGLUsesUnifiedOpenGLLayer() throws {
        let executable = try makePE32(named: "deadcells_gl.exe", marker: "Failed to init SDL: OpenGL Error")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let manager = WineManager()

        XCTAssertTrue(manager.isExecutable32Bit(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .opengl)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .dxmt)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path), [.dxmt])
    }

    func testPE32SDL2OpenGLDisablesLegacyRetinaScaling() throws {
        let executable = try makePE32(named: "pixel-engine.exe", marker: "opengl32.dll SDL2.dll")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("SDL2".utf8).write(to: directory.appendingPathComponent("SDL2.dll"))

        let manager = WineManager()

        XCTAssertTrue(manager.usesLegacySDL2OpenGLScaling(executable.path))
    }

    func testSDL2OpenGLScalingRuleDoesNotAffect64BitGames() throws {
        let executable = try makePE64(named: "modern-engine.exe", marker: "opengl32.dll SDL2.dll")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("SDL2".utf8).write(to: directory.appendingPathComponent("SDL2.dll"))

        let manager = WineManager()

        XCTAssertFalse(manager.usesLegacySDL2OpenGLScaling(executable.path))
    }

    func testUnusedSiblingSDL2DoesNotTriggerLegacyScaling() throws {
        let executable = try makePE32(named: "unrelated-tool.exe", marker: "opengl32.dll")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("SDL2".utf8).write(to: directory.appendingPathComponent("SDL2.dll"))

        let manager = WineManager()

        XCTAssertFalse(manager.usesLegacySDL2OpenGLScaling(executable.path))
    }

    func testNWJSUsesOnlyDXMTDespiteDynamicImportsOrStaleOverride() throws {
        let executable = try makePE64(named: "Melvor Idle.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("ANGLE d3d11 dxgi d3d9.dll".utf8).write(to: directory.appendingPathComponent("nw.dll"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("package.nw"),
            withIntermediateDirectories: true
        )
        try Data(#"{"main":"index.html"}"#.utf8)
            .write(to: directory.appendingPathComponent("package.nw/package.json"))

        let manager = WineManager()
        var stale = EffectiveLaunchConfig()
        stale.graphicsOverride = .gcenx

        XCTAssertTrue(manager.isNWJSGame(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d11)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path, effective: stale), .dxmt)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path, effective: stale), [.dxmt])
        XCTAssertTrue(manager.needsExeAdjacentD3D9Support(executable.path))
    }

    func testNWJSAutomaticEngineArgumentsSurviveEveryLaunchRouteWithoutUserInput() throws {
        let executable = try makePE64(named: "CrossCode.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("ANGLE d3d11 dxgi".utf8).write(to: directory.appendingPathComponent("nw.dll"))
        try Data(#"{"main":"index.html"}"#.utf8)
            .write(to: directory.appendingPathComponent("package.json"))

        let manager = WineManager()
        var config = EffectiveLaunchConfig()
        config.launchArgs = ["--language=es"]

        let detected = manager.resolvedLaunchArguments(
            forExecutable: executable.path,
            requested: [],
            effective: config
        )
        XCTAssertEqual(detected, ["--language=es", "--in-process-gpu"])

        config.launchArgs.append("--IN-PROCESS-GPU")
        let alreadyPresent = manager.resolvedLaunchArguments(
            forExecutable: executable.path,
            requested: [],
            effective: config
        )
        XCTAssertEqual(
            alreadyPresent.filter { $0.caseInsensitiveCompare("--in-process-gpu") == .orderedSame }.count,
            1
        )

        try Data(#"{"main":"index.html","chromium-args":"--ignore-gpu-blocklist --in-process-gpu"}"#.utf8)
            .write(to: directory.appendingPathComponent("package.json"))
        let providedByRuntime = manager.resolvedLaunchArguments(
            forExecutable: executable.path,
            requested: [],
            effective: EffectiveLaunchConfig()
        )
        XCTAssertFalse(providedByRuntime.contains {
            $0.caseInsensitiveCompare("--in-process-gpu") == .orderedSame
        })
    }

    func testForcedDXMTIsReportedAsDXMTForDynamic64BitGame() throws {
        let executable = try makePE64(named: "dynamic.exe")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let manager = WineManager()
        var config = EffectiveLaunchConfig()
        config.graphicsOverride = .dxmt

        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .other)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path, effective: config), .dxmt)
    }

    func testSiblingEngineDLLRoutesMinimalLauncherToD3D11() throws {
        let executable = try makePE64(named: "Hades.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        // `makePE64` crea su propio directorio; copiamos la DLL al lado del launcher, como en Hades.
        let engineSource = try makePE64(named: "EngineWin64s.dll", marker: "dxgi.dll d3d11.dll D3DCOMPILER_47.dll")
        defer { try? FileManager.default.removeItem(at: engineSource.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: engineSource,
            to: directory.appendingPathComponent("EngineWin64s.dll")
        )

        let manager = WineManager()
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d11)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .dxmt)
    }

    func testSiblingEngineDLLConfirmsNativeVulkanRenderer() throws {
        let executable = try makePE64(named: "Hades.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engineSource = try makePE64(
            named: "EngineWin64sv.dll",
            marker: "vulkan-1.dll Running Vulkan renderer/vulkan"
        )
        defer { try? FileManager.default.removeItem(at: engineSource.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: engineSource,
            to: directory.appendingPathComponent("EngineWin64sv.dll")
        )

        let manager = WineManager()
        XCTAssertTrue(manager.isNativeVulkanGame(executable.path))
    }

    func testEOSCompatibilityEngineIsScopedToUnity() throws {
        let executable = try makePE64(named: "Hades.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("EOSSDK-Win64-Shipping.dll"))

        let manager = WineManager()
        XCTAssertTrue(manager.usesEpicOnlineServices(executable.path))
        XCTAssertFalse(manager.needsLegacyUnityEOSWine(executable.path))

        try Data().write(to: directory.appendingPathComponent("UnityPlayer.dll"))
        XCTAssertTrue(manager.needsLegacyUnityEOSWine(executable.path))
    }

    func testLaunchAgentProcessPatternCannotMatchItsOwnWatcher() throws {
        let pattern = WineManager.selfExcludingProcessPattern("Hades")
        let regex = try NSRegularExpression(pattern: pattern)

        let realProcess = #"/wine64-preloader Z:\\Games\\Hades\\x64Vk\\Hades.exe"#
        let watcher = "while /usr/bin/pgrep -f '\(pattern)' >/dev/null; do sleep 5; done"

        XCTAssertNotNil(regex.firstMatch(
            in: realProcess,
            range: NSRange(realProcess.startIndex..., in: realProcess)
        ))
        XCTAssertNil(regex.firstMatch(
            in: watcher,
            range: NSRange(watcher.startIndex..., in: watcher)
        ))
    }

    func testManagedRuntimeOnlyReenablesMSCoree() {
        XCTAssertEqual(
            WineManager.enablingManagedRuntime(
                in: "mscoree,mshtml=d;winegstreamer=d;d3d9,d3d8,ddraw=b"
            ),
            "mshtml=d;winegstreamer=d;d3d9,d3d8,ddraw=b"
        )
        XCTAssertEqual(
            WineManager.enablingManagedRuntime(in: "mscoree=d;winemenubuilder.exe=d"),
            "winemenubuilder.exe=d"
        )
    }

    func testEpicLaunchArgumentsAreRedacted() {
        let arguments = [
            "/Games/Melvor Idle.exe",
            "-AUTH_LOGIN=unused",
            "-AUTH_PASSWORD=super-secret-exchange-code",
            "-epicuserid=123456789",
            "--in-process-gpu"
        ]
        let redacted = WineManager.redactedArgumentsForLogging(arguments)
        let joined = redacted.joined(separator: " ")

        XCTAssertTrue(joined.contains("-AUTH_PASSWORD=<redactado>"))
        XCTAssertTrue(joined.contains("--in-process-gpu"))
        XCTAssertFalse(joined.contains("super-secret-exchange-code"))
        XCTAssertFalse(joined.contains("123456789"))
    }

    func testCrashpadReportsOnlyCountNewChromiumDumps() throws {
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-crashpad-test-\(UUID().uuidString)", isDirectory: true)
        let reports = prefix.appendingPathComponent(
            "drive_c/users/vessel/AppData/Local/Game/Crashpad/reports",
            isDirectory: true
        )
        let unrelated = prefix.appendingPathComponent("drive_c/users/vessel/Desktop", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        let old = reports.appendingPathComponent("old.dmp")
        let first = reports.appendingPathComponent("first.dmp")
        let second = reports.appendingPathComponent("second.dmp")
        try Data().write(to: old)
        try Data().write(to: first)
        try Data().write(to: second)
        try Data().write(to: unrelated.appendingPathComponent("not-crashpad.dmp"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: old.path
        )

        XCTAssertEqual(
            LaunchDiagnostics.crashpadReportCount(
                prefix: prefix.path,
                since: Date().addingTimeInterval(-10)
            ),
            2
        )
    }

    func testSteamRealAutoRepairRequiresDirectSteamEvidence() {
        let genericFailure = LaunchDiagnostics.Failure(
            category: .crash,
            title: "Fallo de motor",
            body: "El proceso se cerró"
        )
        let steamFailure = LaunchDiagnostics.Failure(
            category: .steam,
            title: "Falta Steam Input",
            body: "La interfaz no está disponible"
        )

        XCTAssertFalse(LaunchDiagnostics.shouldRetryWithRealSteam(nil))
        XCTAssertFalse(LaunchDiagnostics.shouldRetryWithRealSteam(genericFailure))
        XCTAssertTrue(LaunchDiagnostics.shouldRetryWithRealSteam(steamFailure))
    }

    func testHeadlessProcessCannotBeLearnedAsSuccessfulEngine() {
        XCTAssertTrue(LaunchDiagnostics.startupFailed(
            crashed: false,
            failureDetected: false,
            isRunning: true,
            everRunning: true,
            requiresVisibleWindow: true,
            everVisible: false
        ))
        XCTAssertFalse(LaunchDiagnostics.startupFailed(
            crashed: false,
            failureDetected: false,
            isRunning: false,
            everRunning: true,
            requiresVisibleWindow: true,
            everVisible: true
        ))
    }

    func testLegacyManualLaunchArgumentsNeverBecomeACompatibilityRequirement() {
        var user = GameConfig()
        user.launchArguments = "-windowed -novid"

        let effective = CompatService.shared.effectiveConfig(profile: nil, user: user)

        XCTAssertTrue(effective.launchArgs.isEmpty)
    }
}
