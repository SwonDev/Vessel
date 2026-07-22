import Foundation
import XCTest
@testable import Vessel

final class GameDisplayStateRepairTests: XCTestCase {
    private let brokenOptions = #"{"postprocessing":2.0,"fullscreen":0.0,"volumeMaster":0.7,"hardwareMouse":false,"resolution":6.0}"#
    private let retinaDisplay = GameDisplayStateRepair.DisplayMetrics(
        logicalWidth: 1512,
        logicalHeight: 982,
        backingScale: 2
    )

    func testRepairsOnlyThePathologicalFullscreenValue() throws {
        let repaired = try XCTUnwrap(GameDisplayStateRepair.repairedTinkerlandsOptions(brokenOptions))

        XCTAssertEqual(
            repaired,
            #"{"postprocessing":2.0,"fullscreen":1.0,"volumeMaster":0.7,"hardwareMouse":false,"resolution":6.0}"#
        )
    }

    func testRespectsValidWindowedAndFullscreenPreferences() {
        XCTAssertNil(GameDisplayStateRepair.repairedTinkerlandsOptions(
            #"{"fullscreen":0.0,"resolution":4.0}"#
        ))
        XCTAssertNil(GameDisplayStateRepair.repairedTinkerlandsOptions(
            #"{"fullscreen":1.0,"resolution":6.0}"#
        ))
        XCTAssertNil(GameDisplayStateRepair.repairedTinkerlandsOptions("not-json"))
    }

    func testRepairsEveryWineUserAndCreatesOneTimeBackups() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-tinkerlands-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appendingPathComponent("Bottle", isDirectory: true)
        let game = prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steamapps/common/Tinkerlands",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try Data().write(to: game.appendingPathComponent("tinkerlands.exe"))
        try Data().write(to: game.appendingPathComponent("data.win"))

        var optionFiles: [URL] = []
        for user in ["adrianpereradelgado", "crossover"] {
            let directory = prefix.appendingPathComponent(
                "drive_c/users/\(user)/AppData/Local/Tinkerlands",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let options = directory.appendingPathComponent("useroptions.conf")
            try brokenOptions.write(to: options, atomically: true, encoding: .utf8)
            optionFiles.append(options)
        }

        let first = GameDisplayStateRepair.repairBeforeLaunch(
            appId: "2617700",
            executable: game.appendingPathComponent("tinkerlands.exe").path,
            prefix: prefix.path
        )

        XCTAssertEqual(first.repairedFiles.count, 2)
        XCTAssertEqual(first.backupFiles.count, 2)
        for options in optionFiles {
            let repaired = try String(contentsOf: options, encoding: .utf8)
            XCTAssertTrue(repaired.contains(#""fullscreen":1.0"#))
            XCTAssertTrue(repaired.contains(#""hardwareMouse":false"#))

            let backup = URL(fileURLWithPath: options.path + ".vessel-windowed-backup")
            XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), brokenOptions)
        }

        let second = GameDisplayStateRepair.repairBeforeLaunch(
            appId: "2617700",
            executable: game.appendingPathComponent("tinkerlands.exe").path,
            prefix: prefix.path
        )
        XCTAssertFalse(second.didRepair)
        XCTAssertTrue(second.backupFiles.isEmpty)
    }

    func testKunitsuSafeResolutionUsesPhysicalPixelsAndLeavesRoomForDecorations() {
        XCTAssertEqual(
            GameDisplayStateRepair.safeKunitsuGamiResolution(displayMetrics: retinaDisplay),
            GameDisplayStateRepair.Resolution(width: 2704, height: 1756)
        )
        XCTAssertEqual(
            GameDisplayStateRepair.safeKunitsuGamiResolution(
                displayMetrics: .init(logicalWidth: 1920, logicalHeight: 1080, backingScale: 1)
            ),
            GameDisplayStateRepair.Resolution(width: 1718, height: 966)
        )
    }

    func testFourAEnhancedRepairsOnlyOverflowingResolutionAndPreservesFullscreen() throws {
        let original = [
            "r_fullscreen on",
            "r_res_hor 1920",
            "r_res_vert 1200",
            "r_vsync 0",
            ""
        ].joined(separator: "\r\n")

        let repaired = try XCTUnwrap(GameDisplayStateRepair.repairedFourAEnhancedConfig(
            original,
            displayMetrics: retinaDisplay
        ))

        XCTAssertTrue(repaired.contains("r_fullscreen on\r\n"))
        XCTAssertTrue(repaired.contains("r_res_hor 1512\r\n"))
        XCTAssertTrue(repaired.contains("r_res_vert 982\r\n"))
        XCTAssertTrue(repaired.contains("r_vsync 0\r\n"))
        XCTAssertFalse(repaired.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertNil(GameDisplayStateRepair.repairedFourAEnhancedConfig(
            "r_res_hor 1280\nr_res_vert 800\n",
            displayMetrics: retinaDisplay
        ))
    }

    func testFourAEnhancedRepairIsStructuralBackedUpAndIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-foura-display-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = root.appendingPathComponent("MetroExodus.exe")
        try Data().write(to: executable)
        let configDirectory = root.appendingPathComponent(
            "drive_c/users/crossover/Saved Games/metro exodus/profile-id",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        let config = configDirectory.appendingPathComponent("user.cfg")
        let original = "r_fullscreen on\nr_res_hor 1920\nr_res_vert 1200\n"
        try original.write(to: config, atomically: true, encoding: .utf8)

        let unrelated = GameDisplayStateRepair.repairBeforeLaunch(
            appId: nil,
            executable: executable.path,
            prefix: root.path,
            displayMetrics: retinaDisplay
        )
        XCTAssertFalse(unrelated.didRepair)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)

        let first = GameDisplayStateRepair.repairBeforeLaunch(
            appId: nil,
            executable: executable.path,
            prefix: root.path,
            displayMetrics: retinaDisplay,
            isFourAEnhanced: true
        )
        XCTAssertEqual(first.repairedFiles, [config.path])
        XCTAssertEqual(first.backupFiles, [config.path + ".vessel-display-backup"])
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("r_res_hor 1512"))
        XCTAssertEqual(
            try String(
                contentsOfFile: config.path + ".vessel-display-backup",
                encoding: .utf8
            ),
            original
        )

        let second = GameDisplayStateRepair.repairBeforeLaunch(
            appId: nil,
            executable: executable.path,
            prefix: root.path,
            displayMetrics: retinaDisplay,
            isFourAEnhanced: true
        )
        XCTAssertFalse(second.didRepair)
        XCTAssertTrue(second.backupFiles.isEmpty)
    }

    func testRepairsOnlyOverflowingKunitsuNormalWindowAndPreservesCRLF() throws {
        let original = [
            "[Render]",
            "Capability=DirectX12",
            "[RenderConfig]",
            "NormalWindowResolution=(0.000000,0.000000)",
            "FullScreenDisplayMode=42",
            "FullScreenMode=false",
            "WindowMode=Normal",
            ""
        ].joined(separator: "\r\n")

        let repaired = try XCTUnwrap(GameDisplayStateRepair.repairedKunitsuGamiConfig(
            original,
            displayMetrics: retinaDisplay
        ))

        XCTAssertTrue(repaired.contains("NormalWindowResolution=(2704.000000,1756.000000)\r\n"))
        XCTAssertTrue(repaired.contains("FullScreenDisplayMode=42\r\n"))
        XCTAssertEqual(repaired.components(separatedBy: "[RenderConfig]").count, 2)
        XCTAssertFalse(repaired.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testKunitsuResolutionTracksTheEffectiveRetinaStateWithoutTouchingArbitrarySizes() throws {
        let retinaConfig = """
        [RenderConfig]
        NormalWindowResolution=(2704.000000,1756.000000)
        FullScreenMode=false
        WindowMode=Normal
        """
        let oneXMetrics = GameDisplayStateRepair.DisplayMetrics(
            logicalWidth: 1512,
            logicalHeight: 982,
            backingScale: 1
        )
        let oneX = try XCTUnwrap(GameDisplayStateRepair.repairedKunitsuGamiConfig(
            retinaConfig,
            displayMetrics: oneXMetrics,
            recognizedPreviousBackingScale: 2
        ))
        XCTAssertTrue(oneX.contains("NormalWindowResolution=(1352.000000,878.000000)"))

        let retina = try XCTUnwrap(GameDisplayStateRepair.repairedKunitsuGamiConfig(
            oneX,
            displayMetrics: retinaDisplay,
            recognizedPreviousBackingScale: 1
        ))
        XCTAssertTrue(retina.contains("NormalWindowResolution=(2704.000000,1756.000000)"))

        XCTAssertNil(GameDisplayStateRepair.repairedKunitsuGamiConfig(
            """
            [RenderConfig]
            NormalWindowResolution=(1920.000000,1200.000000)
            FullScreenMode=false
            WindowMode=Normal
            """,
            displayMetrics: retinaDisplay,
            recognizedPreviousBackingScale: 1
        ))
    }

    func testKunitsuRespectsValidWindowAndExplicitFullscreenModes() {
        let validWindow = """
        [RenderConfig]
        NormalWindowResolution=(2400.000000,1600.000000)
        FullScreenMode=false
        WindowMode=Normal
        """
        XCTAssertNil(GameDisplayStateRepair.repairedKunitsuGamiConfig(
            validWindow,
            displayMetrics: retinaDisplay
        ))

        for mode in ["Borderless", "FullScreen"] {
            XCTAssertNil(GameDisplayStateRepair.repairedKunitsuGamiConfig(
                """
                [RenderConfig]
                NormalWindowResolution=(0.000000,0.000000)
                FullScreenMode=false
                WindowMode=\(mode)
                """,
                displayMetrics: retinaDisplay
            ))
        }
        XCTAssertNil(GameDisplayStateRepair.repairedKunitsuGamiConfig(
            """
            [RenderConfig]
            NormalWindowResolution=(0.000000,0.000000)
            FullScreenMode=true
            WindowMode=Normal
            """,
            displayMetrics: retinaDisplay
        ))
    }

    func testKunitsuCreatesFirstRunConfigAndRepairsExistingConfigIdempotently() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-kunitsu-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = root.appendingPathComponent("KunitsuGamiDemo.exe")
        try Data().write(to: executable)
        try Data().write(to: root.appendingPathComponent("re_chunk_000.pak"))
        try Data().write(to: root.appendingPathComponent("steam_api64.dll"))
        try "[AppRender]\r\nWindowMode=0\r\n".write(
            to: root.appendingPathComponent("config_default.ini"),
            atomically: true,
            encoding: .utf8
        )

        let firstRun = GameDisplayStateRepair.repairBeforeLaunch(
            appId: "2842890",
            executable: executable.path,
            prefix: root.path,
            displayMetrics: retinaDisplay
        )
        let config = root.appendingPathComponent("config.ini")
        XCTAssertEqual(firstRun.repairedFiles, [config.path])
        XCTAssertTrue(firstRun.backupFiles.isEmpty)
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains(
            "NormalWindowResolution=(2704.000000,1756.000000)"
        ))

        let second = GameDisplayStateRepair.repairBeforeLaunch(
            appId: "2842890",
            executable: executable.path,
            prefix: root.path,
            displayMetrics: retinaDisplay
        )
        XCTAssertFalse(second.didRepair)

        let broken = """
        [Render]
        Capability=DirectX12
        [RenderConfig]
        NormalWindowResolution=(0.000000,0.000000)
        FullScreenMode=false
        WindowMode=Normal
        """
        try broken.write(to: config, atomically: true, encoding: .utf8)
        let repaired = GameDisplayStateRepair.repairBeforeLaunch(
            appId: "2842890",
            executable: executable.path,
            prefix: root.path,
            displayMetrics: retinaDisplay
        )
        XCTAssertEqual(repaired.repairedFiles, [config.path])
        XCTAssertEqual(repaired.backupFiles, [config.path + ".vessel-display-backup"])
        XCTAssertEqual(
            try String(contentsOfFile: config.path + ".vessel-display-backup", encoding: .utf8),
            broken
        )

        XCTAssertTrue(GameDisplayStateRepair.requiresOneXWindowCoordinates(
            appId: "2842890",
            executable: executable.path,
            fileManager: .default
        ))

        try """
        [RenderConfig]
        NormalWindowResolution=(3024.000000,1964.000000)
        FullScreenMode=false
        WindowMode=Borderless
        """.write(to: config, atomically: true, encoding: .utf8)
        XCTAssertFalse(GameDisplayStateRepair.requiresOneXWindowCoordinates(
            appId: "2842890",
            executable: executable.path,
            fileManager: .default
        ))
    }

    func testKunitsuRuleNeverTouchesAnotherAppID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-other-reengine-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["KunitsuGamiDemo.exe", "re_chunk_000.pak", "steam_api64.dll"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        try "[AppRender]\n".write(
            to: root.appendingPathComponent("config_default.ini"),
            atomically: true,
            encoding: .utf8
        )

        let report = GameDisplayStateRepair.repairBeforeLaunch(
            appId: "2510710",
            executable: root.appendingPathComponent("KunitsuGamiDemo.exe").path,
            prefix: root.path,
            displayMetrics: retinaDisplay
        )

        XCTAssertFalse(report.didRepair)
        XCTAssertFalse(GameDisplayStateRepair.requiresOneXWindowCoordinates(
            appId: "2510710",
            executable: root.appendingPathComponent("KunitsuGamiDemo.exe").path,
            fileManager: .default
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.ini").path))
    }

    func testNeverTouchesAnotherGame() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-other-game-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let options = root.appendingPathComponent("useroptions.conf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try brokenOptions.write(to: options, atomically: true, encoding: .utf8)

        let report = GameDisplayStateRepair.repairBeforeLaunch(
            appId: "999999",
            executable: root.appendingPathComponent("tinkerlands.exe").path,
            prefix: root.path
        )

        XCTAssertFalse(report.didRepair)
        XCTAssertEqual(try String(contentsOf: options, encoding: .utf8), brokenOptions)
    }
}
