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

    /// Normalización de nombres: ignora espacios y símbolos.
    func testNormalizedNameStripsNonAlphanumerics() {
        XCTAssertEqual(SteamLibraryImporter.normalizedName("Ancient Kingdoms"), "ancientkingdoms")
        XCTAssertEqual(SteamLibraryImporter.normalizedName("Ori & the Will"), "orithewill")
    }
}
