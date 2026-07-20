import Foundation
import Testing
@testable import Vessel

@Suite("Compatibilidad de anti-cheat")
struct DRMCompatibilityTests {
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
        #expect(report.protections.contains(.enigma))
        #expect(report.social.contains(.steamworks))
        #expect(WineManager().officialSteamClientProtection(executable.path) == .enigma)
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
        #expect(!report.protections.contains(.enigma))
        #expect(WineManager().officialSteamClientProtection(executable.path) == nil)
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
