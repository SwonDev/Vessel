import Foundation
import XCTest
@testable import Vessel

final class ProprietaryEngineRepairTests: XCTestCase {
    func testCubeWorldSignatureIsStrict() {
        let imports: Set<String> = [
            "steam_api64.dll", "xaudio2_8.dll", "d3d11.dll", "dinput8.dll",
            "xinput1_4.dll", "glu32.dll", "freeimage.dll"
        ]
        XCTAssertTrue(ProprietaryEngineRepair.isCubeWorldEngine(
            appId: "1128000", executableName: "cubeworld.exe", imports: imports, hasOptions: true
        ))
        XCTAssertFalse(ProprietaryEngineRepair.isCubeWorldEngine(
            appId: "1128001", executableName: "cubeworld.exe", imports: imports, hasOptions: true
        ))
        XCTAssertFalse(ProprietaryEngineRepair.isCubeWorldEngine(
            appId: "1128000", executableName: "other.exe", imports: imports, hasOptions: true
        ))
        XCTAssertFalse(ProprietaryEngineRepair.isCubeWorldEngine(
            appId: "1128000", executableName: "cubeworld.exe", imports: ["d3d11.dll"], hasOptions: true
        ))
    }

    func testCubeWorldRepairOnlyNormalizesUnsupportedMSAA() throws {
        let original = "fullscreen 1\nresolutionX 1512\nantiAliasing 0\nantiAliasingSamples 8\nvsync 1\n"
        let repaired = try XCTUnwrap(ProprietaryEngineRepair.repairedCubeWorldOptions(original))
        XCTAssertEqual(
            repaired,
            "fullscreen 1\nresolutionX 1512\nantiAliasing 0\nantiAliasingSamples 1\nvsync 1\n"
        )
        XCTAssertNil(ProprietaryEngineRepair.repairedCubeWorldOptions(repaired))

        let windowsOriginal = original.replacingOccurrences(of: "\n", with: "\r\n")
        let windowsRepaired = try XCTUnwrap(
            ProprietaryEngineRepair.repairedCubeWorldOptions(windowsOriginal)
        )
        XCTAssertEqual(
            windowsRepaired,
            repaired.replacingOccurrences(of: "\n", with: "\r\n")
        )
    }

    func testLiveCubeWorldSignatureWhenEnabled() throws {
        guard let executable = ProcessInfo.processInfo.environment["VESSEL_CUBE_WORLD_EXE"] else {
            throw XCTSkip("El inventario real de Cube World es optativo.")
        }
        let imports = PEImportScanner.importedLibraries(atPath: executable)
        XCTAssertTrue(
            ProprietaryEngineRepair.isCubeWorldEngine(
                appId: "1128000",
                executableName: (executable as NSString).lastPathComponent,
                imports: imports,
                hasOptions: FileManager.default.fileExists(
                    atPath: "\((executable as NSString).deletingLastPathComponent)/options.cfg"
                )
            ),
            "Imports leídos por Vessel: \(imports.sorted())"
        )
        let options = try String(
            contentsOfFile: "\((executable as NSString).deletingLastPathComponent)/options.cfg",
            encoding: .utf8
        )
        if let candidate = ProprietaryEngineRepair.repairedCubeWorldOptions(options) {
            XCTAssertTrue(candidate.contains("antiAliasingSamples 1"))
        } else {
            // Tras una ejecución real de Vessel, el fichero ya debe estar reparado. La prueba en
            // vivo es idempotente y acepta tanto el estado inicial de 8× como el estado sano de 1×.
            XCTAssertTrue(
                options.contains("antiAliasingSamples 1"),
                "El options.cfg real no expuso ni el MSAA reparable ni el valor compatible."
            )
        }
    }
}
