import Foundation
import XCTest
@testable import Vessel

@MainActor
final class MoltenVKManagerTests: XCTestCase {
    func testPinnedRuntimeIsOnlyAcceptedFromItsVersionedCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-moltenvk-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let versionDirectory = root
            .appendingPathComponent("moltenvk", isDirectory: true)
            .appendingPathComponent(MoltenVKManager.pinnedVersion, isDirectory: true)
        try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x4d, count: 1_000_001)
            .write(to: versionDirectory.appendingPathComponent("libMoltenVK.dylib"))

        let manager = MoltenVKManager(cacheDirectory: root.path)

        XCTAssertEqual(manager.cachedLibraryDirectory(), versionDirectory.path)
        XCTAssertEqual(
            MoltenVKManager.archiveRuntimePath,
            "MoltenVK/MoltenVK/dynamic/dylib/macOS"
        )
    }
}
