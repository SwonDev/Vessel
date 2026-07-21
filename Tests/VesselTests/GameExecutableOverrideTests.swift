import Foundation
import Testing
@testable import Vessel

@Suite("Ejecutable alternativo seguro")
struct GameExecutableOverrideTests {
    private func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8((value >> (index * 8)) & 0xff) }
    }

    private func writeUInt64(_ value: UInt64, to data: inout Data, at offset: Int) {
        for index in 0..<8 { data[offset + index] = UInt8((value >> (index * 8)) & 0xff) }
    }

    private func writePE64(
        to url: URL,
        imports: [String] = [],
        managed: Bool = false
    ) throws {
        var data = Data(repeating: 0, count: 0x800)
        let peOffset = 0x80
        let optionalOffset = peOffset + 24
        let optionalSize = 0xf0
        let directoryOffset = optionalOffset + 112
        let sectionOffset = optionalOffset + optionalSize
        let rawSectionOffset = 0x200

        data[0] = 0x4d
        data[1] = 0x5a
        writeUInt32(UInt32(peOffset), to: &data, at: 0x3c)
        data[peOffset] = 0x50
        data[peOffset + 1] = 0x45
        writeUInt16(0x8664, to: &data, at: peOffset + 4)
        writeUInt16(1, to: &data, at: peOffset + 6)
        writeUInt16(UInt16(optionalSize), to: &data, at: peOffset + 20)
        writeUInt16(0x020b, to: &data, at: optionalOffset)
        writeUInt64(0x0000_0001_4000_0000, to: &data, at: optionalOffset + 24)
        writeUInt32(0x200, to: &data, at: optionalOffset + 60)
        writeUInt32(16, to: &data, at: optionalOffset + 108)

        data.replaceSubrange(sectionOffset..<(sectionOffset + 8), with: Data(".rdata\0\0".utf8))
        writeUInt32(0x600, to: &data, at: sectionOffset + 8)
        writeUInt32(0x1000, to: &data, at: sectionOffset + 12)
        writeUInt32(0x600, to: &data, at: sectionOffset + 16)
        writeUInt32(UInt32(rawSectionOffset), to: &data, at: sectionOffset + 20)

        if !imports.isEmpty {
            writeUInt32(0x1000, to: &data, at: directoryOffset + 8)
            writeUInt32(UInt32((imports.count + 1) * 20), to: &data, at: directoryOffset + 12)
            var nameOffset = 0x400
            for (index, library) in imports.enumerated() {
                let descriptor = rawSectionOffset + index * 20
                writeUInt32(
                    UInt32(0x1000 + nameOffset - rawSectionOffset),
                    to: &data,
                    at: descriptor + 12
                )
                let bytes = Data(library.utf8) + Data([0])
                data.replaceSubrange(nameOffset..<(nameOffset + bytes.count), with: bytes)
                nameOffset += bytes.count
            }
        }

        if managed {
            writeUInt32(0x1300, to: &data, at: directoryOffset + 14 * 8)
            writeUInt32(0x48, to: &data, at: directoryOffset + 14 * 8 + 4)
        }
        try data.write(to: url)
    }

    @Test("Acepta un exe interno y rechaza rutas externas o inexistentes")
    func validatesContainment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-executable-\(UUID().uuidString)", isDirectory: true)
        let internalDirectory = root.appendingPathComponent("bin64", isDirectory: true)
        let executable = internalDirectory.appendingPathComponent("game.exe")
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).exe")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }

        try FileManager.default.createDirectory(at: internalDirectory, withIntermediateDirectories: true)
        try Data([0x4D, 0x5A]).write(to: executable)
        try Data([0x4D, 0x5A]).write(to: external)

        #expect(try GameExecutableOverride.validate(executable.path, installRoot: root.path).get()
            == PathSafety.canonical(executable.path))
        #expect(GameExecutableOverride.validate(external.path, installRoot: root.path)
            == .failure(.outsideInstallRoot))
        #expect(GameExecutableOverride.validate(root.appendingPathComponent("missing.exe").path,
                                                installRoot: root.path)
            == .failure(.missingFile))
    }

    @Test("Un ajuste obsoleto vuelve al ejecutable automático")
    func invalidOverrideFallsBack() {
        let fallback = "/Games/Test/game.exe"
        #expect(GameExecutableOverride.resolve(
            configuredPath: "/otro/launcher.exe",
            installRoot: "/Games/Test",
            fallback: fallback
        ) == fallback)
    }

    @Test("Un launcher CLR con renderers enlazados elige automáticamente el payload D3D12")
    func resolvesManagedDualRendererLauncher() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-renderer-launcher-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let launcher = root.appendingPathComponent("NorthlightGame.exe")
        let dx11 = root.appendingPathComponent("NorthlightGame_DX11.exe")
        let dx12 = root.appendingPathComponent("NorthlightGame_DX12.exe")
        try writePE64(to: launcher, managed: true)
        try writePE64(to: dx11, imports: ["render_win7.dll"])
        try writePE64(to: dx12, imports: ["render_win10.dll"])
        try writePE64(to: root.appendingPathComponent("render_win7.dll"), imports: ["d3d11.dll"])
        try writePE64(
            to: root.appendingPathComponent("render_win10.dll"),
            imports: ["dxgi.dll", "d3d12.dll"]
        )

        #expect(PEImportScanner.hasCLRRuntimeHeader(atPath: launcher.path))
        #expect(GameExecutableOverride.resolve(
            configuredPath: nil,
            installRoot: root.path,
            fallback: launcher.path
        ) == PathSafety.canonical(dx12.path))
    }

    @Test("Los nombres DX11 y DX12 sin grafo PE verificable no alteran el ejecutable oficial")
    func rejectsUnverifiedRendererNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-fake-renderers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let launcher = root.appendingPathComponent("StableGame.exe")
        try writePE64(to: launcher, managed: true)
        try writePE64(to: root.appendingPathComponent("StableGame_DX11.exe"))
        try writePE64(to: root.appendingPathComponent("StableGame_DX12.exe"))

        #expect(GameExecutableOverride.resolve(
            configuredPath: nil,
            installRoot: root.path,
            fallback: launcher.path
        ) == launcher.path)
    }
}
