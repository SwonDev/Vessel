import Foundation
import XCTest
@testable import Vessel

final class GameDisplayStateRepairTests: XCTestCase {
    private let brokenOptions = #"{"postprocessing":2.0,"fullscreen":0.0,"volumeMaster":0.7,"hardwareMouse":false,"resolution":6.0}"#

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
