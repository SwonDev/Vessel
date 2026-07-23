import Foundation
import XCTest
@testable import Vessel

final class SteamAppInfoLaunchResolverTests: XCTestCase {
    private struct LaunchEntry {
        let index: Int
        let executable: String
        let osList: String?
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private func appendUInt64(_ value: UInt64, to data: inout Data) {
        appendUInt32(UInt32(value & 0xffff_ffff), to: &data)
        appendUInt32(UInt32(value >> 32), to: &data)
    }

    private func replaceUInt32(_ value: UInt32, in data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8((value >> (index * 8)) & 0xff) }
    }

    private func replaceUInt64(_ value: UInt64, in data: inout Data, at offset: Int) {
        replaceUInt32(UInt32(value & 0xffff_ffff), in: &data, at: offset)
        replaceUInt32(UInt32(value >> 32), in: &data, at: offset + 4)
    }

    private func appendCString(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
        data.append(0)
    }

    private func makeVersion41AppInfo(appID: UInt32, entries: [LaunchEntry]) -> Data {
        let keys = ["appinfo", "config", "launch", "executable", "oslist"]
            + entries.map { String($0.index) }
        let keyIndexes = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, $0.offset) })

        func appendKey(_ type: UInt8, _ key: String, to data: inout Data) {
            data.append(type)
            appendUInt32(UInt32(keyIndexes[key]!), to: &data)
        }

        var keyValues = Data()
        appendKey(0, "appinfo", to: &keyValues)
        appendKey(0, "config", to: &keyValues)
        appendKey(0, "launch", to: &keyValues)
        for entry in entries.sorted(by: { $0.index < $1.index }) {
            appendKey(0, String(entry.index), to: &keyValues)
            appendKey(1, "executable", to: &keyValues)
            appendCString(entry.executable, to: &keyValues)
            if let osList = entry.osList {
                appendKey(0, "config", to: &keyValues)
                appendKey(1, "oslist", to: &keyValues)
                appendCString(osList, to: &keyValues)
                keyValues.append(8)
            }
            keyValues.append(8)
        }
        keyValues.append(8)
        keyValues.append(8)
        keyValues.append(8)
        keyValues.append(8)

        var file = Data()
        appendUInt32(0x07_56_44_29, to: &file)
        appendUInt32(1, to: &file)
        appendUInt64(0, to: &file) // desplazamiento de la tabla, rellenado al final

        appendUInt32(appID, to: &file)
        let sizeOffset = file.count
        appendUInt32(0, to: &file)
        file.append(Data(repeating: 0, count: 60))
        file.append(keyValues)
        replaceUInt32(UInt32(60 + keyValues.count), in: &file, at: sizeOffset)
        appendUInt32(0, to: &file) // fin de registros

        let stringTableOffset = file.count
        appendUInt32(UInt32(keys.count), to: &file)
        for key in keys { appendCString(key, to: &file) }
        replaceUInt64(UInt64(stringTableOffset), in: &file, at: 8)
        return file
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-appinfo-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testReadsSteamDefaultWindowsExecutable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appInfo = directory.appendingPathComponent("appinfo.vdf")
        try makeVersion41AppInfo(
            appID: 1_004_640,
            entries: [
                LaunchEntry(index: 0, executable: "FFT_enhanced.exe", osList: "windows"),
                LaunchEntry(index: 1, executable: "FFT_classic.exe", osList: "windows")
            ]
        ).write(to: appInfo)

        XCTAssertEqual(
            SteamAppInfoLaunchResolver.defaultWindowsExecutable(
                appID: "1004640",
                appInfoPath: appInfo.path
            ),
            "FFT_enhanced.exe"
        )
    }

    func testSkipsNonWindowsLaunchEntry() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appInfo = directory.appendingPathComponent("appinfo.vdf")
        try makeVersion41AppInfo(
            appID: 42,
            entries: [
                LaunchEntry(index: 0, executable: "Game.app", osList: "macos"),
                LaunchEntry(index: 1, executable: "bin\\Game.exe", osList: "windows,linux")
            ]
        ).write(to: appInfo)

        XCTAssertEqual(
            SteamAppInfoLaunchResolver.defaultWindowsExecutable(appID: "42", appInfoPath: appInfo.path),
            "bin\\Game.exe"
        )
    }

    func testImporterPrefersSteamDefaultOverShorterSibling() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let steam = directory.appendingPathComponent("Steam", isDirectory: true)
        let appCache = steam.appendingPathComponent("appcache", isDirectory: true)
        let depot = directory.appendingPathComponent("FINAL FANTASY TACTICS - The Ivalice Chronicles", isDirectory: true)
        try FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depot, withIntermediateDirectories: true)
        try Data("classic".utf8).write(to: depot.appendingPathComponent("FFT_classic.exe"))
        try Data("enhanced".utf8).write(to: depot.appendingPathComponent("FFT_enhanced.exe"))
        try makeVersion41AppInfo(
            appID: 1_004_640,
            entries: [
                LaunchEntry(index: 0, executable: "FFT_enhanced.exe", osList: "windows"),
                LaunchEntry(index: 1, executable: "FFT_classic.exe", osList: "windows")
            ]
        ).write(to: appCache.appendingPathComponent("appinfo.vdf"))

        XCTAssertEqual(
            SteamLibraryImporter.mainGameExecutable(
                in: depot.path,
                appID: "1004640",
                steamDirectory: steam.path
            ),
            depot.appendingPathComponent("FFT_enhanced.exe").path
        )
    }

    func testRejectsLaunchPathOutsideDepot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let depot = directory.appendingPathComponent("Game", isDirectory: true)
        try FileManager.default.createDirectory(at: depot, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: directory.appendingPathComponent("outside.exe"))

        XCTAssertNil(
            SteamAppInfoLaunchResolver.resolvedExecutable(
                relativePath: "..\\outside.exe",
                installRoot: depot.path
            )
        )
    }

    func testRejectsUnknownAppInfoVersion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appInfo = directory.appendingPathComponent("appinfo.vdf")
        var invalid = makeVersion41AppInfo(
            appID: 42,
            entries: [LaunchEntry(index: 0, executable: "Game.exe", osList: "windows")]
        )
        invalid[0] = 38
        try invalid.write(to: appInfo)

        XCTAssertNil(
            SteamAppInfoLaunchResolver.defaultWindowsExecutable(appID: "42", appInfoPath: appInfo.path)
        )
    }

}
