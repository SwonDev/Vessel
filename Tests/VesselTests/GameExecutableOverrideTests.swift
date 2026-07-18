import Foundation
import Testing
@testable import Vessel

@Suite("Ejecutable alternativo seguro")
struct GameExecutableOverrideTests {
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
}
