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

    func testPinnedArchiveDigestMatchesTheOfficialReleaseAsset() {
        XCTAssertEqual(
            MoltenVKManager.pinnedArchiveSHA256,
            "5ea0c259df7ded9a275444820f09cced54d6e5a7c7a31d262de62a5cdb7e15cf"
        )
        XCTAssertEqual(
            MoltenVKManager.sha256(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
