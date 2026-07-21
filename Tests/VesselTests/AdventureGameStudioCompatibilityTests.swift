import Foundation
import XCTest
@testable import Vessel

final class AdventureGameStudioCompatibilityTests: XCTestCase {
    private let markers: Set<String> = [
        "Adventure Game Studio run-time engine",
        "Adventure Game Studio v%s Interpreter",
        "--gfxdriver"
    ]

    func testModernAGSSignatureRequiresEveryIndependentSignal() {
        let imports: Set<String> = ["sdl2.dll", "kernel32.dll", "user32.dll"]
        XCTAssertTrue(AdventureGameStudioCompatibility.isModernAGSSDL2(
            imports: imports,
            markers: markers,
            hasConfig: true,
            hasGameData: true,
            hasSDL2Runtime: true
        ))
        XCTAssertFalse(AdventureGameStudioCompatibility.isModernAGSSDL2(
            imports: ["kernel32.dll"],
            markers: markers,
            hasConfig: true,
            hasGameData: true,
            hasSDL2Runtime: true
        ))
        XCTAssertFalse(AdventureGameStudioCompatibility.isModernAGSSDL2(
            imports: imports,
            markers: ["Adventure Game Studio run-time engine"],
            hasConfig: true,
            hasGameData: true,
            hasSDL2Runtime: true
        ))
        XCTAssertFalse(AdventureGameStudioCompatibility.isModernAGSSDL2(
            imports: imports,
            markers: markers,
            hasConfig: true,
            hasGameData: false,
            hasSDL2Runtime: true
        ))
    }

    func testRepairChangesOnlyTheGraphicsDriverAndPreservesCRLF() throws {
        let original = """
        [misc]\r
        titletext=Juego con configuración propia\r
        [graphics]\r
        driver = d3d9\r
        windowed=0\r
        fullscreen=desktop\r
        vsync=0\r
        [sound]\r
        driver=D3D9\r
        """

        let repaired = try XCTUnwrap(
            AdventureGameStudioCompatibility.repairedGraphicsConfig(original)
        )
        XCTAssertTrue(repaired.contains("[graphics]\r\ndriver = OGL\r\n"))
        XCTAssertTrue(repaired.contains("vsync=0\r\n"))
        XCTAssertTrue(repaired.contains("[sound]\r\ndriver=D3D9"))
        XCTAssertFalse(repaired.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertNil(AdventureGameStudioCompatibility.repairedGraphicsConfig(repaired))
    }

    func testRepairRespectsOpenGLSoftwareAndUnrelatedSections() {
        XCTAssertNil(AdventureGameStudioCompatibility.repairedGraphicsConfig(
            "[graphics]\ndriver=OGL\nvsync=1\n"
        ))
        XCTAssertNil(AdventureGameStudioCompatibility.repairedGraphicsConfig(
            "[graphics]\ndriver=Software\n"
        ))
        XCTAssertNil(AdventureGameStudioCompatibility.repairedGraphicsConfig(
            "[sound]\ndriver=D3D9\n"
        ))
    }

    func testRepairPreservesMixedLineTerminatorsByteForByte() throws {
        let original = "[misc]\r\ntitletext=AGS\n[graphics]\rdriver=D3D9\nvsync=0\r\n[sound]\ndriver=D3D9"
        let repaired = try XCTUnwrap(
            AdventureGameStudioCompatibility.repairedGraphicsConfig(original)
        )
        XCTAssertEqual(
            repaired,
            "[misc]\r\ntitletext=AGS\n[graphics]\rdriver=OGL\nvsync=0\r\n[sound]\ndriver=D3D9"
        )
    }

    func testRepairCreatesOneTimeBackupAndReappliesAfterAStaleRestore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-ags-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("acsetup.cfg")
        let original = "[graphics]\r\ndriver=D3D9\r\nvsync=0\r\n"
        try original.write(to: config, atomically: true, encoding: .isoLatin1)

        let first = AdventureGameStudioCompatibility.repairConfig(at: config.path)
        XCTAssertTrue(first.didRepair)
        XCTAssertEqual(first.backupFiles.count, 1)
        XCTAssertEqual(
            try String(contentsOf: config, encoding: .isoLatin1),
            "[graphics]\r\ndriver=OGL\r\nvsync=0\r\n"
        )
        let backup = URL(fileURLWithPath: config.path + ".vessel-ags-d3d9-backup")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .isoLatin1), original)

        // Una actualización o restauración puede reponer D3D9: se repara de nuevo sin sobrescribir
        // la copia inicial recuperable.
        try original.write(to: config, atomically: true, encoding: .isoLatin1)
        let second = AdventureGameStudioCompatibility.repairConfig(at: config.path)
        XCTAssertTrue(second.didRepair)
        XCTAssertTrue(second.backupFiles.isEmpty)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .isoLatin1), original)
    }

    func testLiveHeroineQuestSignatureWhenEnabled() throws {
        guard let executable = ProcessInfo.processInfo.environment["VESSEL_AGS_EXE"] else {
            throw XCTSkip("El inventario AGS real es optativo.")
        }
        let directory = (executable as NSString).deletingLastPathComponent
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
        let data = try Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe)
        let liveMarkers = Set(markers.filter { data.range(of: Data($0.utf8)) != nil })

        XCTAssertTrue(AdventureGameStudioCompatibility.isModernAGSSDL2(
            imports: PEImportScanner.importedLibraries(atPath: executable),
            markers: liveMarkers,
            hasConfig: files.contains { $0.caseInsensitiveCompare("acsetup.cfg") == .orderedSame },
            hasGameData: files.contains {
                ($0 as NSString).pathExtension.caseInsensitiveCompare("ags") == .orderedSame
            },
            hasSDL2Runtime: files.contains { $0.caseInsensitiveCompare("SDL2.dll") == .orderedSame }
        ))

        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-live-ags-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: clone) }
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        let clonedExecutable = clone.appendingPathComponent("Heroine's Quest.exe")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: executable),
            to: clonedExecutable
        )
        try Data().write(to: clone.appendingPathComponent("Heroine's Quest.ags"))
        try Data().write(to: clone.appendingPathComponent("SDL2.dll"))
        try "[graphics]\r\ndriver=D3D9\r\nvsync=0\r\n".write(
            to: clone.appendingPathComponent("acsetup.cfg"),
            atomically: true,
            encoding: .isoLatin1
        )

        let report = AdventureGameStudioCompatibility.repairBeforeLaunch(
            executable: clonedExecutable.path
        )
        XCTAssertTrue(report.detected)
        XCTAssertTrue(report.didRepair)
        XCTAssertEqual(report.backupFiles.count, 1)
    }
}
