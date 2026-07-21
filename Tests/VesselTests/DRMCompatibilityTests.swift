import Foundation
import Testing
@testable import Vessel

@Suite("Compatibilidad de anti-cheat")
struct DRMCompatibilityTests {
    private func pe64Fixture(imports: [String], markers: [String] = []) -> Data {
        var pe = Data(repeating: 0, count: 0x1000)
        let peOffset = 0x80
        let optionalOffset = peOffset + 24
        let optionalSize = 0xF0
        let directoryOffset = optionalOffset + 112
        let sectionOffset = optionalOffset + optionalSize
        let rawSectionOffset = 0x200

        pe[0] = 0x4D
        pe[1] = 0x5A
        pe.writeUInt32LE(UInt32(peOffset), at: 0x3C)
        pe[peOffset] = 0x50
        pe[peOffset + 1] = 0x45
        pe.writeUInt16LE(0x8664, at: peOffset + 4)
        pe.writeUInt16LE(1, at: peOffset + 6)
        pe.writeUInt16LE(UInt16(optionalSize), at: peOffset + 20)
        pe.writeUInt16LE(0x020B, at: optionalOffset)
        pe.writeUInt32LE(16, at: optionalOffset + 108)
        pe.writeUInt32LE(0x200, at: optionalOffset + 60)

        pe.replaceSubrange(sectionOffset..<(sectionOffset + 8), with: Data(".rdata\0\0".utf8))
        pe.writeUInt32LE(0x800, at: sectionOffset + 8)
        pe.writeUInt32LE(0x1000, at: sectionOffset + 12)
        pe.writeUInt32LE(0x800, at: sectionOffset + 16)
        pe.writeUInt32LE(UInt32(rawSectionOffset), at: sectionOffset + 20)

        if !imports.isEmpty {
            pe.writeUInt32LE(0x1000, at: directoryOffset + 8)
            pe.writeUInt32LE(UInt32((imports.count + 1) * 20), at: directoryOffset + 12)
            var nameOffset = 0x400
            for (index, library) in imports.enumerated() {
                let descriptor = rawSectionOffset + index * 20
                pe.writeUInt32LE(UInt32(0x1000 + nameOffset - rawSectionOffset), at: descriptor + 12)
                let bytes = Data(library.utf8) + Data([0])
                pe.replaceSubrange(nameOffset..<(nameOffset + bytes.count), with: bytes)
                nameOffset += bytes.count
            }
        }

        var markerOffset = 0x700
        for marker in markers {
            let bytes = Data(marker.utf8) + Data([0])
            pe.replaceSubrange(markerOffset..<(markerOffset + bytes.count), with: bytes)
            markerOffset += bytes.count
        }
        return pe
    }

    private func enigmaFixture(opaqueSections: Bool) -> Data {
        var pe = Data(repeating: 0, count: 0x1000)
        pe[0] = 0x4D
        pe[1] = 0x5A
        pe.writeUInt32LE(0x80, at: 0x3C)
        pe[0x80] = 0x50
        pe[0x81] = 0x45
        pe.writeUInt16LE(8, at: 0x86)
        pe.writeUInt16LE(0xF0, at: 0x94)
        let sectionTable = 0x80 + 24 + 0xF0
        let normalNames = [".text", ".rdata", ".data", ".pdata", ".idata", ".tls", ".reloc", ".rsrc"]
        for index in 0..<8 where !opaqueSections || index == 7 {
            let name = opaqueSections ? ".rsrc" : normalNames[index]
            pe.replaceSubrange(
                (sectionTable + index * 40)..<(sectionTable + index * 40 + name.utf8.count),
                with: Data(name.utf8)
            )
        }
        pe.replaceSubrange(0x700..<(0x700 + "Enigma Protector".utf8.count),
                           with: Data("Enigma Protector".utf8))
        return pe
    }

    @Test("Solo Denied y Broken con anti-cheat conocido bloquean macOS")
    func blockingStatuses() {
        var verdict = DRMDatabase.Verdict(appId: "1")
        verdict.antiCheats = ["Easy Anti-Cheat"]

        verdict.antiCheatStatus = "Denied"
        #expect(verdict.antiCheatBlocksMacOS)
        verdict.antiCheatStatus = "Broken"
        #expect(verdict.antiCheatBlocksMacOS)
        verdict.antiCheatStatus = "Unknown"
        #expect(!verdict.antiCheatBlocksMacOS)
        verdict.antiCheats = []
        verdict.antiCheatStatus = "Denied"
        #expect(!verdict.antiCheatBlocksMacOS)
    }

    @Test("SteamStub con entry point en .bind exige el cliente real")
    func detectsSteamStubBindEntryPoint() throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vessel-SteamStub-\(UUID().uuidString).exe")
        defer { try? FileManager.default.removeItem(at: executable) }

        var pe = Data(repeating: 0, count: 0x800)
        pe[0] = 0x4D
        pe[1] = 0x5A
        pe.writeUInt32LE(0x80, at: 0x3C)              // e_lfanew
        pe[0x80] = 0x50
        pe[0x81] = 0x45
        pe.writeUInt16LE(1, at: 0x86)                 // NumberOfSections
        pe.writeUInt16LE(0xF0, at: 0x94)              // SizeOfOptionalHeader (PE32+)
        pe.writeUInt32LE(0x2000, at: 0xA8)             // AddressOfEntryPoint

        let section = 0x80 + 24 + 0xF0
        pe.replaceSubrange(section..<(section + 5), with: Data(".bind".utf8))
        pe.writeUInt32LE(0x200, at: section + 8)       // VirtualSize
        pe.writeUInt32LE(0x2000, at: section + 12)     // VirtualAddress
        pe.writeUInt32LE(0x200, at: section + 16)      // SizeOfRawData
        pe.writeUInt32LE(0x400, at: section + 20)      // PointerToRawData
        try pe.write(to: executable)

        #expect(SteamDRMScanner.hasSteamStub(executable.path))
    }

    @Test("Una sección .bind sin confirmación no fuerza Steam real")
    func ignoresUnconfirmedBindSection() throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vessel-PlainBind-\(UUID().uuidString).exe")
        defer { try? FileManager.default.removeItem(at: executable) }

        var pe = Data(repeating: 0, count: 0x800)
        pe[0] = 0x4D
        pe[1] = 0x5A
        pe.writeUInt32LE(0x80, at: 0x3C)
        pe[0x80] = 0x50
        pe[0x81] = 0x45
        pe.writeUInt16LE(1, at: 0x86)
        pe.writeUInt16LE(0xF0, at: 0x94)
        pe.writeUInt32LE(0x1000, at: 0xA8)             // Fuera de .bind, sin magic

        let section = 0x80 + 24 + 0xF0
        pe.replaceSubrange(section..<(section + 5), with: Data(".bind".utf8))
        pe.writeUInt32LE(0x200, at: section + 8)
        pe.writeUInt32LE(0x2000, at: section + 12)
        pe.writeUInt32LE(0x200, at: section + 16)
        pe.writeUInt32LE(0x400, at: section + 20)
        try pe.write(to: executable)

        #expect(!SteamDRMScanner.hasSteamStub(executable.path))
    }

    @Test("Enigma moderno con secciones opacas conserva el cliente Steam oficial")
    @MainActor
    func detectsOpaqueModernEnigmaAndRequiresOfficialSteam() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vessel-Enigma-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("ProtectedGame.exe")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try enigmaFixture(opaqueSections: true).write(to: executable)
        try Data("steamworks".utf8).write(to: root.appendingPathComponent("steam_api64.dll"))

        let report = DRMAnalyzer.analyze(folder: root.path, executable: executable.path)
        let manager = WineManager()
        #expect(report.protections.contains(.enigma))
        #expect(report.social.contains(.steamworks))
        #expect(manager.officialSteamClientProtection(executable.path) == .enigma)
        #expect(WineManager.requiresOfficialSteamAppLaunch(
            builtInProtection: manager.requiresSteamAppLaunch(executable.path),
            thirdPartyProtection: .enigma,
            directLaunchException: manager.usesProtectedDirectLaunchWithConnectedSteam(executable.path)
        ))
        #expect(WineManager.shouldUseFullWineForSteamAppLaunch(
            required: true,
            graphicsAPI: manager.detectGraphicsAPI(forExecutable: executable.path)
        ))
    }

    @Test("Una mención a Enigma dentro de un PE normal no fuerza Steam")
    @MainActor
    func ignoresEnigmaTextWithoutOpaqueSectionLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vessel-Enigma-Control-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("OrdinaryGame.exe")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try enigmaFixture(opaqueSections: false).write(to: executable)
        try Data("steamworks".utf8).write(to: root.appendingPathComponent("steam_api64.dll"))

        let report = DRMAnalyzer.analyze(folder: root.path, executable: executable.path)
        let manager = WineManager()
        #expect(!report.protections.contains(.enigma))
        #expect(manager.officialSteamClientProtection(executable.path) == nil)
        #expect(!WineManager.requiresOfficialSteamAppLaunch(
            builtInProtection: manager.requiresSteamAppLaunch(executable.path),
            thirdPartyProtection: nil,
            directLaunchException: manager.usesProtectedDirectLaunchWithConnectedSteam(executable.path)
        ))
    }

    @Test("Enigma con Steamworks y D3D12 delega el AppID sin abandonar D3DMetal")
    @MainActor
    func keepsD3D12ProtectedSteamLaunchOnD3DMetal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vessel-Enigma-D3D12-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("ProtectedGame.exe")
        let agility = root.appendingPathComponent("D3D12", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: agility, withIntermediateDirectories: true)
        try enigmaFixture(opaqueSections: true).write(to: executable)
        try Data("steamworks".utf8).write(to: root.appendingPathComponent("steam_api64.dll"))
        try Data("agility".utf8).write(to: agility.appendingPathComponent("D3D12Core.dll"))

        let manager = WineManager()
        let protection = manager.officialSteamClientProtection(executable.path)
        let graphicsAPI = manager.detectGraphicsAPI(forExecutable: executable.path)
        let requiresAppLaunch = WineManager.requiresOfficialSteamAppLaunch(
            builtInProtection: manager.requiresSteamAppLaunch(executable.path),
            thirdPartyProtection: protection,
            directLaunchException: manager.usesProtectedDirectLaunchWithConnectedSteam(executable.path)
        )

        #expect(protection == .enigma)
        #expect(requiresAppLaunch)
        #expect(graphicsAPI == .d3d12)
        #expect(!WineManager.shouldUseFullWineForSteamAppLaunch(
            required: requiresAppLaunch,
            graphicsAPI: graphicsAPI
        ))
    }

    @Test("Un módulo de ticket del editor conserva Steam oficial y D3DMetal")
    @MainActor
    func detectsPublisherSteamTicketModuleStructurally() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vessel-Publisher-Ticket-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("DragonGame.exe")
        let moduleDirectory = root.appendingPathComponent("data/crm/steam", isDirectory: true)
        let module = moduleDirectory.appendingPathComponent("crm_module_w64.dll")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: moduleDirectory, withIntermediateDirectories: true)
        try pe64Fixture(imports: ["d3d12.dll"]).write(to: executable)
        try Data("steamworks".utf8).write(to: root.appendingPathComponent("steam_api64.dll"))
        try pe64Fixture(
            imports: ["steam_api64.dll", "winhttp.dll"],
            markers: ["SetSteamEncryptedAppTicket", "SteamUser023"]
        ).write(to: module)

        let report = DRMAnalyzer.analyze(folder: root.path, executable: executable.path)
        let manager = WineManager()
        let protection = manager.officialSteamClientProtection(executable.path)
        let graphicsAPI = manager.detectGraphicsAPI(forExecutable: executable.path)
        let requiresAppLaunch = WineManager.requiresOfficialSteamAppLaunch(
            builtInProtection: manager.requiresSteamAppLaunch(executable.path),
            thirdPartyProtection: protection,
            directLaunchException: manager.usesProtectedDirectLaunchWithConnectedSteam(executable.path)
        )

        #expect(report.protections.contains(.publisherSteamTicket))
        #expect(report.social.contains(.steamworks))
        #expect(protection == .publisherSteamTicket)
        #expect(requiresAppLaunch)
        #expect(graphicsAPI == .d3d12)
        #expect(!WineManager.shouldUseFullWineForSteamAppLaunch(
            required: requiresAppLaunch,
            graphicsAPI: graphicsAPI
        ))
    }

    @Test("El nombre CRM sin imports y símbolos de ticket no fuerza Steam real")
    func ignoresUnconfirmedPublisherTicketModule() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vessel-Publisher-Ticket-Control-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("OrdinaryGame.exe")
        let moduleDirectory = root.appendingPathComponent("data/crm", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: moduleDirectory, withIntermediateDirectories: true)
        try pe64Fixture(imports: ["d3d11.dll"]).write(to: executable)
        try Data("steamworks".utf8).write(to: root.appendingPathComponent("steam_api64.dll"))
        try pe64Fixture(
            imports: ["kernel32.dll"],
            markers: ["SetSteamEncryptedAppTicket", "SteamUser023"]
        ).write(to: moduleDirectory.appendingPathComponent("crm_module_w64.dll"))

        let report = DRMAnalyzer.analyze(folder: root.path, executable: executable.path)
        #expect(!report.protections.contains(.publisherSteamTicket))
    }
}

private extension Data {
    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
