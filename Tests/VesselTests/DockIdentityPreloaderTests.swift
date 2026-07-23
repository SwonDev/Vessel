import Foundation
import XCTest
@testable import Vessel

final class DockIdentityPreloaderTests: XCTestCase {
    private let sectionOffset = 512
    private let sectionCapacity = 1_024

    func testPatchesOnlyEmbeddedInfoPlistAndPreservesExecutableSize() throws {
        let source = try makeMachO()
        let identifier = "com.swondev.vessel.game.a1b2c3"

        let patched = try DockIdentityPreloader.patchedExecutableData(
            source,
            displayName: "Call of the Wild: The Angler",
            bundleIdentifier: identifier
        )

        XCTAssertEqual(patched.count, source.count)
        XCTAssertEqual(
            patched.prefix(sectionOffset),
            source.prefix(sectionOffset)
        )
        XCTAssertEqual(
            patched.suffix(from: sectionOffset + sectionCapacity),
            source.suffix(from: sectionOffset + sectionCapacity)
        )

        let plist = try embeddedPlist(in: patched)
        XCTAssertEqual(plist["CFBundleName"] as? String, "Call of the Wild: The Angler")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, identifier)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "wineloader")
        XCTAssertEqual(plist["NSPrincipalClass"] as? String, "WineApplication")
    }

    func testLongUnicodeNameFitsWithoutChangingSectionBoundaries() throws {
        let source = try makeMachO()
        let name = String(repeating: "🎮", count: 64)

        let patched = try DockIdentityPreloader.patchedExecutableData(
            source,
            displayName: name,
            bundleIdentifier: "com.swondev.vessel.game.unicode"
        )

        XCTAssertEqual(patched.count, source.count)
        XCTAssertEqual(try embeddedPlist(in: patched)["CFBundleName"] as? String, name)
    }

    func testRejectsAmbiguousInfoPlistWithoutChoosingArbitrarily() throws {
        let source = try makeMachO(sectionCount: 2)

        XCTAssertThrowsError(
            try DockIdentityPreloader.patchedExecutableData(
                source,
                displayName: "Juego",
                bundleIdentifier: "com.swondev.vessel.game.test"
            )
        ) { error in
            XCTAssertEqual(
                error as? DockIdentityPreloader.PreparationError,
                .ambiguousInfoPlist
            )
        }
    }

    func testRejectsMalformedAndUnsupportedExecutables() {
        XCTAssertThrowsError(
            try DockIdentityPreloader.patchedExecutableData(
                Data(repeating: 0, count: 128),
                displayName: "Juego",
                bundleIdentifier: "com.swondev.vessel.game.test"
            )
        ) { error in
            XCTAssertEqual(
                error as? DockIdentityPreloader.PreparationError,
                .unsupportedMachO
            )
        }
    }

    func testPrepareAliasLeavesEngineUntouchedAndCreatesPrivateExecutableCopy() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("vessel-dock-preloader-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let wine = bin.appendingPathComponent("wine", isDirectory: false)
        let preloader = bin.appendingPathComponent("wine-preloader", isDirectory: false)
        let alias = root
            .appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("DragonSword: Awakening", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("wine".utf8).write(to: wine)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let source = try makeMachO()
        try source.write(to: preloader)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: preloader.path)

        try DockIdentityPreloader.prepareAlias(
            wineExecutable: wine,
            alias: alias,
            displayName: "DragonSword: Awakening",
            fileManager: fileManager
        )

        XCTAssertEqual(try Data(contentsOf: preloader), source)
        let aliasData = try Data(contentsOf: alias)
        XCTAssertEqual(aliasData.count, source.count)
        XCTAssertEqual(
            try embeddedPlist(in: aliasData)["CFBundleName"] as? String,
            "DragonSword: Awakening"
        )
        let attributes = try fileManager.attributesOfItem(atPath: alias.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let parentAttributes = try fileManager.attributesOfItem(
            atPath: alias.deletingLastPathComponent().path
        )
        XCTAssertEqual((parentAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testPrepareAliasFindsModernWineLoaderWhenNoPreloaderExists() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("vessel-dock-modern-loader-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let wine = bin.appendingPathComponent("wine", isDirectory: false)
        let loader = root.appendingPathComponent(
            "lib/wine/x86_64-unix/wine",
            isDirectory: false
        )
        let alias = root.appendingPathComponent("private/Grim Dawn", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: loader.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("dispatcher".utf8).write(to: wine)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let source = try makeMachO()
        try source.write(to: loader)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path)

        try DockIdentityPreloader.prepareAlias(
            wineExecutable: wine,
            alias: alias,
            displayName: "Grim Dawn",
            fileManager: fileManager
        )

        XCTAssertEqual(try Data(contentsOf: loader), source)
        XCTAssertEqual(
            try embeddedPlist(in: Data(contentsOf: alias))["CFBundleName"] as? String,
            "Grim Dawn"
        )
    }

    func testBundleIdentifierIsStableAndScopedByGame() {
        let first = DockIdentityPreloader.bundleIdentifier(
            winePath: "/Engines/gptk/wine/bin/wine",
            displayName: "DOOM Eternal"
        )
        let repeated = DockIdentityPreloader.bundleIdentifier(
            winePath: "/Engines/gptk/wine/bin/wine",
            displayName: "DOOM Eternal"
        )
        let other = DockIdentityPreloader.bundleIdentifier(
            winePath: "/Engines/gptk/wine/bin/wine",
            displayName: "DragonSword: Awakening"
        )

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, other)
        XCTAssertTrue(first.hasPrefix("com.swondev.vessel.game."))
    }

    private func makeMachO(sectionCount: Int = 1) throws -> Data {
        let segmentCommandSize = 72 + sectionCount * 80
        let lastSectionEnd = sectionOffset + sectionCapacity * sectionCount
        var data = Data(repeating: 0xA5, count: lastSectionEnd + 64)

        write(UInt32(0xFEEDFACF), to: &data, at: 0)
        write(UInt32(0x01000007), to: &data, at: 4)
        write(UInt32(3), to: &data, at: 8)
        write(UInt32(2), to: &data, at: 12)
        write(UInt32(1), to: &data, at: 16)
        write(UInt32(segmentCommandSize), to: &data, at: 20)

        let commandOffset = 32
        write(UInt32(0x19), to: &data, at: commandOffset)
        write(UInt32(segmentCommandSize), to: &data, at: commandOffset + 4)
        write("__TEXT", to: &data, at: commandOffset + 8, capacity: 16)
        write(UInt32(sectionCount), to: &data, at: commandOffset + 64)

        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "wineloader",
                "CFBundleIdentifier": "com.codeweavers.CrossOver.wineloader",
                "CFBundleName": "CrossOver-Hosted Application",
                "CFBundlePackageType": "APPL",
                "LSUIElement": "1",
                "NSPrincipalClass": "WineApplication"
            ],
            format: .xml,
            options: 0
        )
        XCTAssertLessThan(plist.count, sectionCapacity)

        for index in 0..<sectionCount {
            let sectionCommandOffset = commandOffset + 72 + index * 80
            let currentSectionOffset = sectionOffset + index * sectionCapacity
            write("__info_plist", to: &data, at: sectionCommandOffset, capacity: 16)
            write("__TEXT", to: &data, at: sectionCommandOffset + 16, capacity: 16)
            write(UInt64(sectionCapacity), to: &data, at: sectionCommandOffset + 40)
            write(UInt32(currentSectionOffset), to: &data, at: sectionCommandOffset + 48)
            data.replaceSubrange(
                currentSectionOffset..<(currentSectionOffset + sectionCapacity),
                with: Data(repeating: 0, count: sectionCapacity)
            )
            data.replaceSubrange(
                currentSectionOffset..<(currentSectionOffset + plist.count),
                with: plist
            )
        }
        return data
    }

    private func embeddedPlist(in data: Data) throws -> [String: Any] {
        let section = data.subdata(
            in: sectionOffset..<(sectionOffset + sectionCapacity)
        )
        let payload: Data
        if let terminator = section.firstIndex(of: 0) {
            payload = section.prefix(upTo: terminator)
        } else {
            payload = section
        }
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: payload,
                options: [],
                format: nil
            ) as? [String: Any]
        )
    }

    private func write(_ value: UInt32, to data: inout Data, at offset: Int) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }

    private func write(_ value: UInt64, to data: inout Data, at offset: Int) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }

    private func write(_ value: Int, to data: inout Data, at offset: Int) {
        write(UInt32(value), to: &data, at: offset)
    }

    private func write(_ string: String, to data: inout Data, at offset: Int, capacity: Int) {
        var bytes = Data(string.utf8)
        XCTAssertLessThanOrEqual(bytes.count, capacity)
        bytes.append(Data(repeating: 0, count: capacity - bytes.count))
        data.replaceSubrange(offset..<(offset + capacity), with: bytes)
    }
}
