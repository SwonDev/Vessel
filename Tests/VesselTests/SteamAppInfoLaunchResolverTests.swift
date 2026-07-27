import Foundation
import XCTest
@testable import Vessel

final class SteamAppInfoLaunchResolverTests: XCTestCase {
    private struct LaunchEntry {
        let index: Int
        let executable: String
        let osList: String?
    }

    private struct EULAEntry {
        let index: Int
        let id: String
        let name: String
        let version: String
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

    private func makeVersion41AppInfo(
        appID: UInt32,
        entries: [LaunchEntry],
        eulas: [EULAEntry] = []
    ) -> Data {
        var keys = [
            "appinfo", "common", "eulas", "id", "name", "version",
            "config", "launch", "executable", "oslist"
        ]
        for key in entries.map({ String($0.index) }) + eulas.map({ String($0.index) })
        where !keys.contains(key) {
            keys.append(key)
        }
        let keyIndexes = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, $0.offset) })

        func appendKey(_ type: UInt8, _ key: String, to data: inout Data) {
            data.append(type)
            appendUInt32(UInt32(keyIndexes[key]!), to: &data)
        }

        var keyValues = Data()
        appendKey(0, "appinfo", to: &keyValues)
        if !eulas.isEmpty {
            appendKey(0, "common", to: &keyValues)
            appendKey(0, "eulas", to: &keyValues)
            for eula in eulas.sorted(by: { $0.index < $1.index }) {
                appendKey(0, String(eula.index), to: &keyValues)
                appendKey(1, "id", to: &keyValues)
                appendCString(eula.id, to: &keyValues)
                appendKey(1, "name", to: &keyValues)
                appendCString(eula.name, to: &keyValues)
                appendKey(1, "version", to: &keyValues)
                appendCString(eula.version, to: &keyValues)
                keyValues.append(8)
            }
            keyValues.append(8)
            keyValues.append(8)
        }
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

    func testReadsOrderedSteamEULAMetadataAlongsideLaunchData() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appInfo = directory.appendingPathComponent("appinfo.vdf")
        try makeVersion41AppInfo(
            appID: 1_687_950,
            entries: [LaunchEntry(index: 0, executable: "P5R.exe", osList: "windows")],
            eulas: [
                EULAEntry(index: 1, id: "1687950_eula_1", name: "Online Terms", version: "3"),
                EULAEntry(index: 0, id: "1687950_eula_0", name: "Persona 5 Royal EULA", version: "1")
            ]
        ).write(to: appInfo)

        XCTAssertEqual(
            SteamAppInfoLaunchResolver.eulas(appID: "1687950", appInfoPath: appInfo.path),
            [
                .init(id: "1687950_eula_0", name: "Persona 5 Royal EULA", version: "1"),
                .init(id: "1687950_eula_1", name: "Online Terms", version: "3")
            ]
        )
        XCTAssertEqual(
            SteamAppInfoLaunchResolver.defaultWindowsExecutable(
                appID: "1687950",
                appInfoPath: appInfo.path
            ),
            "P5R.exe"
        )
    }

    func testReturnsEmptyEULACollectionForAValidAppWithoutLicenses() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appInfo = directory.appendingPathComponent("appinfo.vdf")
        try makeVersion41AppInfo(
            appID: 42,
            entries: [LaunchEntry(index: 0, executable: "Game.exe", osList: "windows")]
        ).write(to: appInfo)

        XCTAssertEqual(
            SteamAppInfoLaunchResolver.eulas(appID: "42", appInfoPath: appInfo.path),
            []
        )
    }

    func testEULAPreflightFindsPendingLicenseBeforeStartingSilentSteam() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let steam = directory.appendingPathComponent("Steam", isDirectory: true)
        let appCache = steam.appendingPathComponent("appcache", isDirectory: true)
        let accountConfig = steam
            .appendingPathComponent("userdata/121123806/config", isDirectory: true)
        try FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: accountConfig, withIntermediateDirectories: true)
        let appInfo = appCache.appendingPathComponent("appinfo.vdf")
        try makeVersion41AppInfo(
            appID: 1_687_950,
            entries: [LaunchEntry(index: 0, executable: "P5R.exe", osList: "windows")],
            eulas: [
                EULAEntry(
                    index: 0,
                    id: "1687950_eula_0",
                    name: "Persona 5 Royal EULA",
                    version: "1"
                )
            ]
        ).write(to: appInfo)
        try Data(localConfig(appID: "1687950", eulaID: nil, version: nil).utf8)
            .write(to: accountConfig.appendingPathComponent("localconfig.vdf"))

        XCTAssertEqual(
            SteamEULAPreflight.pendingEULAs(
                appID: "1687950",
                appInfoPath: appInfo.path,
                steamDirectory: steam.path
            ),
            [.init(id: "1687950_eula_0", name: "Persona 5 Royal EULA", version: "1")]
        )
    }

    func testEULAPreflightRecognizesAcceptedOrNewerVersionAcrossAccounts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let steam = directory.appendingPathComponent("Steam", isDirectory: true)
        let appCache = steam.appendingPathComponent("appcache", isDirectory: true)
        let firstAccount = steam.appendingPathComponent("userdata/1/config", isDirectory: true)
        let secondAccount = steam.appendingPathComponent("userdata/2/config", isDirectory: true)
        try FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: firstAccount, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondAccount, withIntermediateDirectories: true)
        let appInfo = appCache.appendingPathComponent("appinfo.vdf")
        try makeVersion41AppInfo(
            appID: 1_687_950,
            entries: [LaunchEntry(index: 0, executable: "P5R.exe", osList: "windows")],
            eulas: [
                EULAEntry(index: 0, id: "1687950_eula_0", name: "EULA", version: "2")
            ]
        ).write(to: appInfo)
        try Data(localConfig(appID: "1687950", eulaID: "1687950_eula_0", version: "1").utf8)
            .write(to: firstAccount.appendingPathComponent("localconfig.vdf"))
        try Data(localConfig(appID: "1687950", eulaID: "1687950_eula_0", version: "3").utf8)
            .write(to: secondAccount.appendingPathComponent("localconfig.vdf"))

        XCTAssertEqual(
            SteamEULAPreflight.pendingEULAs(
                appID: "1687950",
                appInfoPath: appInfo.path,
                steamDirectory: steam.path
            ),
            []
        )
    }

    func testEULAPreflightDoesNotAcceptAnUnrelatedAppBlock() {
        let data = Data(localConfig(
            appID: "42",
            eulaID: "1687950_eula_0",
            version: "1"
        ).utf8)

        XCTAssertNil(SteamEULAPreflight.acceptedVersion(
            appID: "1687950",
            eulaID: "1687950_eula_0",
            in: data
        ))
        XCTAssertTrue(SteamEULAPreflight.satisfies(
            requiredVersion: "2",
            acceptedVersion: "3"
        ))
        XCTAssertFalse(SteamEULAPreflight.satisfies(
            requiredVersion: "3",
            acceptedVersion: "2"
        ))
    }

    private func localConfig(appID: String, eulaID: String?, version: String?) -> String {
        let eulaLine: String
        if let eulaID, let version {
            eulaLine = "\t\t\t\t\t\t\"\(eulaID)\"\t\t\"\(version)\""
        } else {
            eulaLine = ""
        }
        return """
        "UserLocalConfigStore"
        {
        \t"Software"
        \t{
        \t\t"Valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        \t\t\t\t"apps"
        \t\t\t\t{
        \t\t\t\t\t"\(appID)"
        \t\t\t\t\t{
        \(eulaLine)
        \t\t\t\t\t}
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t}
        }
        """
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

    func testImporterFollowsVerifiedPayloadDeclaredByOfficialLauncher() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let steam = directory.appendingPathComponent("Steam", isDirectory: true)
        let appCache = steam.appendingPathComponent("appcache", isDirectory: true)
        let depot = directory.appendingPathComponent("Modern Edition", isDirectory: true)
        let edition = depot.appendingPathComponent("edition", isDirectory: true)
        try FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: edition, withIntermediateDirectories: true)
        try Data("classic".utf8).write(to: depot.appendingPathComponent("Classic.exe"))
        try Data("launcher".utf8).write(to: edition.appendingPathComponent("ModernLauncher.exe"))
        try Data("payload".utf8).write(to: edition.appendingPathComponent("ModernGame.exe"))
        try Data("ApplicationPath=ModernGame.exe\n".utf8).write(
            to: edition.appendingPathComponent("Modern.ini")
        )
        try makeVersion41AppInfo(
            appID: 42,
            entries: [
                LaunchEntry(index: 0, executable: "edition\\ModernLauncher.exe", osList: "windows")
            ]
        ).write(to: appCache.appendingPathComponent("appinfo.vdf"))

        XCTAssertEqual(
            SteamLibraryImporter.mainGameExecutable(
                in: depot.path,
                appID: "42",
                steamDirectory: steam.path
            ),
            edition.appendingPathComponent("ModernGame.exe").path
        )
    }

    func testImporterKeepsOfficialLauncherWithoutVerifiedPayloadContract() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let steam = directory.appendingPathComponent("Steam", isDirectory: true)
        let appCache = steam.appendingPathComponent("appcache", isDirectory: true)
        let depot = directory.appendingPathComponent("Online Game", isDirectory: true)
        try FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depot, withIntermediateDirectories: true)
        try Data("launcher".utf8).write(to: depot.appendingPathComponent("OnlineLauncher.exe"))
        try Data("client".utf8).write(to: depot.appendingPathComponent("Client.exe"))
        try makeVersion41AppInfo(
            appID: 43,
            entries: [
                LaunchEntry(index: 0, executable: "OnlineLauncher.exe", osList: "windows")
            ]
        ).write(to: appCache.appendingPathComponent("appinfo.vdf"))

        XCTAssertEqual(
            SteamLibraryImporter.mainGameExecutable(
                in: depot.path,
                appID: "43",
                steamDirectory: steam.path
            ),
            depot.appendingPathComponent("OnlineLauncher.exe").path
        )
    }

    func testImporterFollowsRootJSONPayloadDeclaredByOfficialSteamLauncher() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let steam = directory.appendingPathComponent("Steam", isDirectory: true)
        let appCache = steam.appendingPathComponent("appcache", isDirectory: true)
        let depot = directory.appendingPathComponent("REDengine Game", isDirectory: true)
        let payloadDirectory = depot.appendingPathComponent("bin/x64", isDirectory: true)
        let launcher = depot.appendingPathComponent("REDprelauncher.exe")
        let payload = payloadDirectory.appendingPathComponent("Game.exe")
        try FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        try Data("launcher".utf8).write(to: launcher)
        try Data("payload".utf8).write(to: payload)
        try JSONSerialization.data(
            withJSONObject: [
                "executablePath": #"bin\x64\Game.exe"#,
                "gameId": "structural-game-id",
                "platform": "steam"
            ],
            options: [.sortedKeys]
        ).write(to: depot.appendingPathComponent("launcher-configuration.json"))
        try makeVersion41AppInfo(
            appID: 45,
            entries: [
                LaunchEntry(index: 0, executable: "REDprelauncher.exe", osList: "windows")
            ]
        ).write(to: appCache.appendingPathComponent("appinfo.vdf"))

        XCTAssertEqual(
            SteamLibraryImporter.mainGameExecutable(
                in: depot.path,
                appID: "45",
                steamDirectory: steam.path
            ),
            payload.path
        )
    }

    func testImporterRejectsRootJSONForAnotherPlatform() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let steam = directory.appendingPathComponent("Steam", isDirectory: true)
        let appCache = steam.appendingPathComponent("appcache", isDirectory: true)
        let depot = directory.appendingPathComponent("Launcher Game", isDirectory: true)
        let launcher = depot.appendingPathComponent("GameLauncher.exe")
        let payload = depot.appendingPathComponent("Game.exe")
        try FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depot, withIntermediateDirectories: true)
        try Data("launcher".utf8).write(to: launcher)
        try Data("payload".utf8).write(to: payload)
        try JSONSerialization.data(
            withJSONObject: [
                "executablePath": "Game.exe",
                "gameId": "other-store",
                "platform": "gog"
            ],
            options: [.sortedKeys]
        ).write(to: depot.appendingPathComponent("launcher-configuration.json"))
        try makeVersion41AppInfo(
            appID: 46,
            entries: [
                LaunchEntry(index: 0, executable: "GameLauncher.exe", osList: "windows")
            ]
        ).write(to: appCache.appendingPathComponent("appinfo.vdf"))

        XCTAssertEqual(
            SteamLibraryImporter.mainGameExecutable(
                in: depot.path,
                appID: "46",
                steamDirectory: steam.path
            ),
            launcher.path
        )
    }

    func testImporterRejectsDeclaredPayloadSymlinkOutsideDepot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let steam = directory.appendingPathComponent("Steam", isDirectory: true)
        let appCache = steam.appendingPathComponent("appcache", isDirectory: true)
        let depot = directory.appendingPathComponent("Safe Game", isDirectory: true)
        let launcherDirectory = depot.appendingPathComponent("launcher", isDirectory: true)
        let launcher = launcherDirectory.appendingPathComponent("SafeLauncher.exe")
        let outside = directory.appendingPathComponent("outside.exe")
        try FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try Data("launcher".utf8).write(to: launcher)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: launcherDirectory.appendingPathComponent("Payload.exe"),
            withDestinationURL: outside
        )
        try Data("ApplicationPath=Payload.exe\n".utf8).write(
            to: launcherDirectory.appendingPathComponent("Safe.ini")
        )
        try makeVersion41AppInfo(
            appID: 44,
            entries: [
                LaunchEntry(index: 0, executable: "launcher\\SafeLauncher.exe", osList: "windows")
            ]
        ).write(to: appCache.appendingPathComponent("appinfo.vdf"))

        XCTAssertEqual(
            SteamLibraryImporter.mainGameExecutable(
                in: depot.path,
                appID: "44",
                steamDirectory: steam.path
            ),
            launcher.path
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
