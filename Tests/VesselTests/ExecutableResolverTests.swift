import Foundation
import XCTest
@testable import Vessel

/// Verifica el resolutor del ejecutable PRINCIPAL (cliente) de un juego instalado.
/// Regresión real: un MMO de Steam (Ancient Kingdoms, Unity) trae un `server/server.exe`
/// headless; la heurística antigua ("ruta más corta") lo elegía y el juego se quedaba
/// "Ejecutándose" sin ventana. El resolutor nuevo debe elegir SIEMPRE el cliente.
@MainActor
final class ExecutableResolverTests: XCTestCase {

    private func makeTree(_ root: String, files: [String], dirs: [String]) throws {
        let fm = FileManager.default
        for d in dirs {
            try fm.createDirectory(atPath: "\(root)/\(d)", withIntermediateDirectories: true)
        }
        for f in files {
            let full = "\(root)/\(f)"
            try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: full, contents: Data("x".utf8))
        }
    }

    private func tempDir(_ name: String) -> String {
        let base = NSTemporaryDirectory() + "vessel-exe-test-\(UUID().uuidString)/\(name)"
        return base
    }

    private func steamStubFixture() -> Data {
        var pe = Data(repeating: 0, count: 0x800)
        pe[0] = 0x4D
        pe[1] = 0x5A
        pe[0x3C] = 0x80                              // e_lfanew
        pe[0x80] = 0x50
        pe[0x81] = 0x45
        pe[0x86] = 1                                 // NumberOfSections
        pe[0x94] = 0xF0                              // SizeOfOptionalHeader (PE32+)
        pe[0xA8] = 0x00                              // AddressOfEntryPoint = 0x2000
        pe[0xA9] = 0x20

        let section = 0x80 + 24 + 0xF0
        pe.replaceSubrange(section..<(section + 5), with: Data(".bind".utf8))
        pe[section + 9] = 0x02                       // VirtualSize = 0x200
        pe[section + 13] = 0x20                      // VirtualAddress = 0x2000
        pe[section + 17] = 0x02                      // SizeOfRawData = 0x200
        pe[section + 21] = 0x04                      // PointerToRawData = 0x400
        return pe
    }

    /// Caso MMO: cliente Unity en la raíz (con su `_Data`) + servidor headless en `server/`.
    /// El nombre del exe ("ancientkingdoms") NO coincide literalmente con la carpeta
    /// ("Ancient Kingdoms") por el espacio → la normalización debe igualarlos.
    func testPicksUnityClientOverDedicatedServer() throws {
        let dir = tempDir("Ancient Kingdoms")
        try makeTree(dir,
            files: [
                "ancientkingdoms.exe",
                "UnityCrashHandler64.exe",
                "server/server.exe",
                "server/UnityCrashHandler64.exe"
            ],
            dirs: ["ancientkingdoms_Data", "server/server_Data"]
        )
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }

        let exe = SteamLibraryImporter.mainGameExecutable(in: dir)
        XCTAssertEqual((exe as NSString?)?.lastPathComponent, "ancientkingdoms.exe",
                       "Debe elegir el cliente, no el server.exe headless")
        XCTAssertFalse(exe?.contains("/server/") ?? true, "No debe estar dentro de la carpeta server/")
    }

    /// Caso launcher de terceros: prefiere el juego real, no el launcher.
    func testPrefersGameOverThirdPartyLauncher() throws {
        let dir = tempDir("Some Game")
        try makeTree(dir,
            files: ["SomeGame.exe", "Launcher.exe"],
            dirs: ["SomeGame_Data"]
        )
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }

        let exe = SteamLibraryImporter.mainGameExecutable(in: dir)
        XCTAssertEqual((exe as NSString?)?.lastPathComponent, "SomeGame.exe")
    }

    /// Caso simple: un único exe en la raíz, sin pistas extra.
    func testPicksRootExeWhenUnambiguous() throws {
        let dir = tempDir("Tiny")
        try makeTree(dir, files: ["tiny.exe", "tools/helper.exe"], dirs: [])
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }

        let exe = SteamLibraryImporter.mainGameExecutable(in: dir)
        XCTAssertEqual((exe as NSString?)?.lastPathComponent, "tiny.exe")
    }

    /// Los paneles de configuración no son payloads jugables aunque estén en la raíz. Regresión
    /// real de Ys Origin: `config.exe` era más corto que `yso_win.exe`, ganaba el desempate y el
    /// botón Jugar abría siempre los ajustes con `-c`.
    func testIgnoresAuxiliaryConfigExecutable() throws {
        let dir = tempDir("Ys Origin")
        try makeTree(dir, files: ["config.exe", "yso_win.exe"], dirs: [])
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }

        let exe = SteamLibraryImporter.mainGameExecutable(in: dir)
        XCTAssertEqual((exe as NSString?)?.lastPathComponent, "yso_win.exe")
    }

    /// Un depot parcial que solo contenga el configurador no debe aparecer como juego instalado.
    func testRejectsInstallContainingOnlyConfigExecutable() throws {
        let dir = tempDir("Partial Game")
        try makeTree(dir, files: ["config.exe"], dirs: [])
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }

        XCTAssertNil(SteamLibraryImporter.mainGameExecutable(in: dir))
    }

    /// Cuando el juego ofrece un renderer OpenGL real junto al ejecutable base, debe preferirse la
    /// variante explícita. Regresión de Dead Cells: el empate elegía `deadcells.exe` por ser más corto
    /// y ocultaba `deadcells_gl.exe`, que es la ruta compatible con el motor OpenGL de Vessel.
    func testPrefersConfirmedOpenGLSibling() throws {
        let dir = tempDir("Dead Cells")
        try makeTree(dir, files: ["deadcells.exe", "deadcells_gl.exe"], dirs: [])
        try Data("binary padding… Failed to init SDL … OpenGL Error".utf8)
            .write(to: URL(fileURLWithPath: "\(dir)/deadcells_gl.exe"))
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }

        let exe = SteamLibraryImporter.mainGameExecutable(in: dir)
        XCTAssertEqual((exe as NSString?)?.lastPathComponent, "deadcells_gl.exe")
    }

    /// Un sufijo `_gl` sin evidencia dentro del binario no basta para alterar el ejecutable elegido.
    func testDoesNotPreferUnconfirmedOpenGLSibling() throws {
        let dir = tempDir("Stable Game")
        try makeTree(dir, files: ["stablegame.exe", "stablegame_gl.exe"], dirs: [])
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }

        let exe = SteamLibraryImporter.mainGameExecutable(in: dir)
        XCTAssertEqual((exe as NSString?)?.lastPathComponent, "stablegame.exe")
    }

    /// Cuando el juego distribuye renderers paralelos y la DLL de la carpeta `x64Vk` confirma
    /// Vulkan, Vessel debe elegirla automáticamente para el motor completo con MoltenVK, sin
    /// parámetros del usuario.
    func testPrefersConfirmedVulkanRendererDirectory() throws {
        let dir = tempDir("Hades")
        try makeTree(dir,
            files: [
                "x64/Hades.exe", "x64/EngineWin64s.dll",
                "x64Vk/Hades.exe", "x64Vk/EngineWin64sv.dll"
            ],
            dirs: []
        )
        try Data("vulkan-1.dll … Running Vulkan … renderer/vulkan".utf8)
            .write(to: URL(fileURLWithPath: "\(dir)/x64Vk/EngineWin64sv.dll"))
        try Data("dxgi.dll … d3d11.dll".utf8)
            .write(to: URL(fileURLWithPath: "\(dir)/x64/EngineWin64s.dll"))
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }

        let exe = SteamLibraryImporter.mainGameExecutable(in: dir)
        XCTAssertEqual(exe, "\(dir)/x64Vk/Hades.exe")
    }

    /// Un depot puede traer el mismo motor en dos árboles: uno envuelto con SteamStub y otro
    /// standalone oficial. Vessel debe escoger este último automáticamente para no abrir Steam.
    func testPrefersMirroredOfficialNoSteamVariantOverSteamStub() throws {
        let dir = tempDir("Proprietary Engine")
        try makeTree(dir,
            files: [
                "_windows/win64/Proprietary.exe",
                "_windowsnosteam/win64/Proprietary.exe"
            ],
            dirs: []
        )
        try steamStubFixture().write(
            to: URL(fileURLWithPath: "\(dir)/_windows/win64/Proprietary.exe")
        )
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }

        let exe = SteamLibraryImporter.mainGameExecutable(in: dir)
        XCTAssertEqual(exe, "\(dir)/_windowsnosteam/win64/Proprietary.exe")
        XCTAssertFalse(SteamDRMScanner.hasSteamStub(exe ?? ""))
    }

    /// Una carpeta llamada `nosteam` sin un ejecutable espejo protegido no demuestra que sea una
    /// edición oficial y no debe alterar la heurística general.
    func testDoesNotTrustStandaloneFolderNameWithoutProtectedMirror() throws {
        let dir = tempDir("Stable Game")
        try makeTree(dir,
            files: [
                "_windows/win64/StableGame.exe",
                "_windowsnosteam/win64/StableGame.exe"
            ],
            dirs: []
        )
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }

        let exe = SteamLibraryImporter.mainGameExecutable(in: dir)
        XCTAssertEqual(exe, "\(dir)/_windows/win64/StableGame.exe")
    }

    /// Un launcher oficial puede declarar su payload en un INI. Esa relación explícita debe ganar
    /// a una edición antigua de la raíz para que «Jugar» abra el juego moderno directamente.
    func testPrefersPayloadDeclaredByAdjacentLauncherINI() throws {
        let dir = tempDir("Trine")
        try makeTree(dir,
            files: [
                "trine.exe",
                "_enchanted_edition_/trine1_launcher.exe",
                "_enchanted_edition_/trine1_game.exe",
                "_enchanted_edition_/trine1.ini"
            ],
            dirs: []
        )
        try Data("ApplicationPath=trine1_game.exe\n".utf8).write(
            to: URL(fileURLWithPath: "\(dir)/_enchanted_edition_/trine1.ini")
        )
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }

        let exe = SteamLibraryImporter.mainGameExecutable(in: dir)
        XCTAssertEqual(exe, "\(dir)/_enchanted_edition_/trine1_game.exe")
    }

    /// Una clave `ApplicationPath` aislada no basta: sin un launcher hermano verificable se conserva
    /// la heurística normal y ningún fichero INI arbitrario puede secuestrar la selección.
    func testDoesNotTrustApplicationPathWithoutAdjacentLauncher() throws {
        let dir = tempDir("Stable Game")
        try makeTree(dir,
            files: ["stablegame.exe", "alternate/other.exe", "alternate/settings.ini"],
            dirs: []
        )
        try Data("ApplicationPath=other.exe\n".utf8).write(
            to: URL(fileURLWithPath: "\(dir)/alternate/settings.ini")
        )
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }

        let exe = SteamLibraryImporter.mainGameExecutable(in: dir)
        XCTAssertEqual(exe, "\(dir)/stablegame.exe")
    }

    /// Normalización de nombres: ignora espacios y símbolos.
    func testNormalizedNameStripsNonAlphanumerics() {
        XCTAssertEqual(SteamLibraryImporter.normalizedName("Ancient Kingdoms"), "ancientkingdoms")
        XCTAssertEqual(SteamLibraryImporter.normalizedName("Ori & the Will"), "orithewill")
    }
}
