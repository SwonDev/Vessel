import Foundation
import XCTest
@testable import Vessel

@MainActor
final class DXVKManagerTests: XCTestCase {
    func testGameLocalD3D9IsIsolatedAndRestoresOriginalDLL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-dxvk-local-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = root.appendingPathComponent("dxvk", isDirectory: true)
        let extracted = cache
            .appendingPathComponent("extracted-1.10.3/dxvk-1.10.3", isDirectory: true)
        let x32 = extracted.appendingPathComponent("x32", isDirectory: true)
        let x64 = extracted.appendingPathComponent("x64", isDirectory: true)
        let game = root.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: x32, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: x64, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try Data("dxvk32".utf8).write(to: x32.appendingPathComponent("d3d9.dll"))
        try Data("dxvk64".utf8).write(to: x64.appendingPathComponent("d3d9.dll"))

        let executable = game.appendingPathComponent("engine.exe")
        let localDLL = game.appendingPathComponent("d3d9.dll")
        try Data("engine".utf8).write(to: executable)
        try Data("original".utf8).write(to: localDLL)

        let manager = DXVKManager(cacheDirectory: root.path)
        let installed = try await manager.installGameLocalD3D9(
            forExecutable: executable.path,
            is64Bit: true
        )

        XCTAssertEqual(installed, localDLL.path)
        XCTAssertEqual(try Data(contentsOf: localDLL), Data("dxvk64".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDLL.path + ".vessel-dxvk"))
        XCTAssertTrue(manager.removeGameLocalD3D9(forExecutable: executable.path))
        XCTAssertEqual(try Data(contentsOf: localDLL), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: localDLL.path + ".vessel-dxvk"))
    }

    func testChowdrenD3D9UsesItsIsolatedBackendAndPreservesOriginalDLL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-dxvk-chowdren-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let game = root.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let executable = game.appendingPathComponent("converted-runtime.exe")
        let localDLL = game.appendingPathComponent("d3d9.dll")
        let backend = root.appendingPathComponent("chowdren-d3d9.dll")
        try Data("engine".utf8).write(to: executable)
        try Data("original-game-dll".utf8).write(to: localDLL)
        try Data("vessel-chowdren-backend".utf8).write(to: backend)

        let manager = DXVKManager(
            cacheDirectory: root.path,
            chowdrenLocalSourcePath: backend.path
        )
        let installed = try await manager.installGameLocalChowdrenD3D9(
            forExecutable: executable.path
        )

        XCTAssertEqual(installed, localDLL.path)
        XCTAssertEqual(try Data(contentsOf: localDLL), Data("vessel-chowdren-backend".utf8))
        XCTAssertEqual(
            try String(contentsOfFile: localDLL.path + ".vessel-dxvk", encoding: .utf8),
            DXVKManager.chowdrenVersion
        )
        XCTAssertTrue(manager.removeGameLocalD3D9(forExecutable: executable.path))
        XCTAssertEqual(try Data(contentsOf: localDLL), Data("original-game-dll".utf8))
    }
}
