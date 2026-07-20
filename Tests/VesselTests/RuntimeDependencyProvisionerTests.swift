import Foundation
import XCTest
@testable import Vessel

final class RuntimeDependencyProvisionerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vessel-RuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testBuildsExactRepairPlanWithoutReinstallingBundledDirectXHelpers() throws {
        let executable = try writeExecutable(
            named: "game.exe",
            markers: "MSVCP120.dll d3dx9_38.dll d3dx9_43.dll d3dcompiler_43.dll OpenAL32.dll"
        )

        let plan = RuntimeDependencyProvisioner.repairPlan(executable: executable.path)

        XCTAssertTrue(plan.dependencies.contains(.visualCpp))
        XCTAssertTrue(plan.dependencies.contains(.directX9Helper))
        XCTAssertTrue(plan.dependencies.contains(.d3dCompiler))
        XCTAssertTrue(plan.dependencies.contains(.openAL))
        XCTAssertEqual(plan.winetricksVerbs, ["vcrun2013", "d3dx9_38", "openal"])
        XCTAssertFalse(plan.winetricksVerbs.contains("d3dx9_43"))
        XCTAssertFalse(plan.winetricksVerbs.contains("d3dcompiler_43"))
    }

    func testFindsXNAAndFrameworkVersionInAdjacentFiles() throws {
        let executable = try writeExecutable(named: "game.exe", markers: "MZ")
        let frameworkDirectory = temporaryDirectory.appendingPathComponent("Managed/Framework", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworkDirectory, withIntermediateDirectories: true)
        try Data("Microsoft.Xna.Framework".utf8).write(
            to: frameworkDirectory.appendingPathComponent("Microsoft.Xna.Framework.dll")
        )
        try Data("<supportedRuntime version=\"v4.0\"/>".utf8).write(
            to: temporaryDirectory.appendingPathComponent("game.exe.config")
        )

        let plan = RuntimeDependencyProvisioner.repairPlan(executable: executable.path)

        XCTAssertTrue(plan.dependencies.contains(.xna))
        XCTAssertTrue(plan.dependencies.contains(.dotNet))
        XCTAssertEqual(plan.winetricksVerbs, ["dotnet40", "xna40"])
    }

    func testDetectsWindowsDesktopRuntimeFromRuntimeConfig() throws {
        let executable = try writeExecutable(named: "managed.exe", markers: "MZ")
        let runtimeConfig = """
        { "runtimeOptions": { "framework": {
          "name": "Microsoft.WindowsDesktop.App",
          "version": "8.0.12"
        } } }
        """
        try Data(runtimeConfig.utf8).write(
            to: temporaryDirectory.appendingPathComponent("managed.runtimeconfig.json")
        )

        let plan = RuntimeDependencyProvisioner.repairPlan(executable: executable.path)

        XCTAssertTrue(plan.dependencies.contains(.dotNet))
        XCTAssertEqual(plan.winetricksVerbs, ["dotnetdesktop8"])
    }

    func testDistinguishesXNA31FromXNA40() throws {
        let executable = try writeExecutable(
            named: "legacy-xna.exe",
            markers: "Microsoft.Xna.Framework, Version=3.1.0.0"
        )

        let plan = RuntimeDependencyProvisioner.repairPlan(executable: executable.path)

        XCTAssertEqual(plan.winetricksVerbs, ["dotnet35sp1", "xna31"])
    }

    func testUses32BitXACTVerbForPE32Games() throws {
        let executable = try writePE32Executable(named: "audio.exe", markers: "XACTENGINE3_7.dll")

        let plan = RuntimeDependencyProvisioner.repairPlan(executable: executable.path)

        XCTAssertTrue(plan.dependencies.contains(.xact))
        XCTAssertEqual(plan.winetricksVerbs, ["xact"])
    }

    func testPhysXInstallerExecutableDoesNotMasqueradeAsInstalledRuntime() throws {
        let executable = try writePE32Executable(named: "game.exe", markers: "PhysXLoader.dll")
        try Data("redistributable".utf8).write(
            to: temporaryDirectory.appendingPathComponent("PhysX_9.09_SystemSoftware.exe")
        )

        let missingPlan = RuntimeDependencyProvisioner.repairPlan(executable: executable.path)
        XCTAssertTrue(missingPlan.dependencies.contains(.physX))
        XCTAssertTrue(missingPlan.winetricksVerbs.contains("physx"))

        try Data("local runtime".utf8).write(
            to: temporaryDirectory.appendingPathComponent("PhysX3Common_x86.dll")
        )
        let bundledPlan = RuntimeDependencyProvisioner.repairPlan(executable: executable.path)
        XCTAssertFalse(bundledPlan.winetricksVerbs.contains("physx"))
    }

    func testProtectedSteamPreflightIgnoresOtherEditionAndEditorRuntimes() throws {
        let executable = try writePE32Executable(
            named: "classic.exe",
            markers: "PhysXLoader.dll d3dx9_38.dll"
        )
        let otherEdition = temporaryDirectory
            .appendingPathComponent("_enchanted_edition_", isDirectory: true)
        try FileManager.default.createDirectory(at: otherEdition, withIntermediateDirectories: true)
        try Data("local modern runtime".utf8).write(
            to: otherEdition.appendingPathComponent("PhysX3Common_x64.dll")
        )
        try Data("Microsoft.WindowsDesktop.App \"version\": \"8.0.1\"".utf8).write(
            to: otherEdition.appendingPathComponent("editor.runtimeconfig.json")
        )
        // Texto incidental de una DLL nativa adyacente: no es un import CLR y no exige .NET.
        try Data("mscoree.dll v4.0.30319".utf8).write(
            to: temporaryDirectory.appendingPathComponent("steam_api.dll")
        )

        let plan = RuntimeDependencyProvisioner.protectedSteamPreflightPlan(
            executable: executable.path
        )

        XCTAssertTrue(plan.winetricksVerbs.contains("physx"))
        XCTAssertTrue(plan.winetricksVerbs.contains("d3dx9_38"))
        XCTAssertFalse(plan.dependencies.contains(.dotNet))
        XCTAssertFalse(plan.winetricksVerbs.contains("dotnetdesktop8"))
    }

    func testReadsImportsFromLargePEWithoutScanningTheWholeBinary() throws {
        let executable = try writePE32ExecutableWithImport(named: "large.exe", library: "MSVCP120.dll")

        let plan = RuntimeDependencyProvisioner.repairPlan(executable: executable.path)

        XCTAssertTrue(plan.dependencies.contains(.visualCpp))
        XCTAssertEqual(plan.winetricksVerbs, ["vcrun2013"])
    }

    func testDiagnosticMissingLibraryComplementsDynamicImports() throws {
        let executable = try writeExecutable(named: "dynamic.exe", markers: "LoadLibraryW")

        let plan = RuntimeDependencyProvisioner.repairPlan(
            executable: executable.path,
            missingLibrary: "MSVCP100.dll"
        )

        XCTAssertTrue(plan.dependencies.contains(.visualCpp))
        XCTAssertEqual(plan.winetricksVerbs, ["vcrun2010"])
    }

    func testDiagnosticRepairsOnlyTheMissingLibrary() throws {
        let executable = try writeExecutable(
            named: "mixed.exe",
            markers: "MSVCP140.dll d3dx9_38.dll OpenAL32.dll"
        )

        let plan = RuntimeDependencyProvisioner.repairPlan(
            executable: executable.path,
            missingLibrary: "OpenAL32.dll"
        )

        XCTAssertEqual(plan.winetricksVerbs, ["openal"])
    }

    func testUnknownMissingGameFileDoesNotInstallSpeculativeRuntime() throws {
        let executable = try writeExecutable(named: "mixed.exe", markers: "MSVCP140.dll")

        let plan = RuntimeDependencyProvisioner.repairPlan(
            executable: executable.path,
            missingLibrary: "GameAssets.dll"
        )

        XCTAssertTrue(plan.winetricksVerbs.isEmpty)
    }

    func testMonoGameOnDotNetDoesNotInstallLegacyXNA() throws {
        let executable = try writeExecutable(
            named: "monogame.exe",
            markers: "Microsoft.Xna.Framework MonoGame Microsoft.NETCore.App \"version\": \"8.0.1\""
        )

        let plan = RuntimeDependencyProvisioner.repairPlan(executable: executable.path)

        XCTAssertFalse(plan.dependencies.contains(.xna))
        XCTAssertEqual(plan.winetricksVerbs, ["dotnet8"])
    }

    func testUnknownExecutableProducesNoSpeculativePlan() throws {
        let executable = try writeExecutable(named: "unknown.exe", markers: "MZ harmless")

        let plan = RuntimeDependencyProvisioner.repairPlan(executable: executable.path)

        XCTAssertTrue(plan.dependencies.isEmpty)
        XCTAssertTrue(plan.winetricksVerbs.isEmpty)
    }

    func testRubyUCRTLayoutFailureAddsNativeUCRT2019Repair() throws {
        let executable = try writeExecutable(
            named: "mkxp.exe",
            markers: "x64-vcruntime140-ruby250.dll api-ms-win-crt-runtime-l1-1-0.dll unexpected ucrtbase.dll"
        )

        let plan = RuntimeDependencyProvisioner.repairPlan(executable: executable.path)

        XCTAssertTrue(plan.dependencies.contains(.visualCpp))
        XCTAssertEqual(plan.winetricksVerbs, ["vcrun2022", "ucrtbase2019"])
    }

    func testExtractsOnlyDLLFromActualMissingLibraryLine() {
        let output = """
        0024:trace:loaddll:build_module Loaded L"C:\\windows\\system32\\kernel32.dll"
        0024:err:module:import_dll Library MSVCP100.dll (which is needed by L"game.exe") not found
        """

        XCTAssertEqual(LaunchDiagnostics.missingLibraryName(in: output), "MSVCP100.dll")
    }

    func testIgnoresHealthyDLLLoadLines() {
        let output = "0024:trace:loaddll:build_module Loaded L\"C:\\windows\\system32\\kernel32.dll\""

        XCTAssertNil(LaunchDiagnostics.missingLibraryName(in: output))
    }

    func testIgnoresRedistributableInstallerPayloads() throws {
        let executable = try writeExecutable(named: "native.exe", markers: "MZ harmless")
        let redistributables = temporaryDirectory
            .appendingPathComponent("_CommonRedist/vcredist", isDirectory: true)
        try FileManager.default.createDirectory(at: redistributables, withIntermediateDirectories: true)
        try Data("MSVCP100.dll".utf8).write(to: redistributables.appendingPathComponent("payload.dll"))

        let plan = RuntimeDependencyProvisioner.repairPlan(executable: executable.path)

        XCTAssertTrue(plan.dependencies.isEmpty)
        XCTAssertTrue(plan.winetricksVerbs.isEmpty)
    }

    private func writeExecutable(named name: String, markers: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data(markers.utf8).write(to: url)
        return url
    }

    private func writePE32Executable(named name: String, markers: String) throws -> URL {
        var data = Data(repeating: 0, count: 0x90)
        data[0] = 0x4d
        data[1] = 0x5a
        data[0x3c] = 0x80
        data[0x80] = 0x50
        data[0x81] = 0x45
        data[0x84] = 0x4c
        data[0x85] = 0x01
        data.append(Data(markers.utf8))
        let url = temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func writePE32ExecutableWithImport(named name: String, library: String) throws -> URL {
        var data = Data(repeating: 0, count: 1_100_000)
        data[0] = 0x4d
        data[1] = 0x5a
        writeUInt32(0x80, at: 0x3c, in: &data)

        let pe = 0x80
        data[pe] = 0x50
        data[pe + 1] = 0x45
        writeUInt16(0x014c, at: pe + 4, in: &data)
        writeUInt16(1, at: pe + 6, in: &data)
        writeUInt16(0x00e0, at: pe + 20, in: &data)

        let optional = pe + 24
        writeUInt16(0x010b, at: optional, in: &data)
        writeUInt32(0x1000, at: optional + 104, in: &data) // Import Directory RVA.

        let section = optional + 0x00e0
        writeUInt32(0x1000, at: section + 8, in: &data)
        writeUInt32(0x1000, at: section + 12, in: &data)
        writeUInt32(0x1000, at: section + 16, in: &data)
        writeUInt32(0x0400, at: section + 20, in: &data)

        writeUInt32(0x1100, at: 0x0400 + 12, in: &data)
        data.replaceSubrange(0x0500..<(0x0500 + library.utf8.count), with: library.utf8)

        let url = temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func writeUInt16(_ value: UInt16, at offset: Int, in data: inout Data) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private func writeUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    @MainActor
    func testLiveVesselSteamRuntimeInventoryWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["VESSEL_RUN_LIVE_RUNTIME_SCAN"] == "1" else {
            throw XCTSkip("El inventario real de la biblioteca solo se ejecuta bajo demanda.")
        }
        let bottleNames = try FileManager.default.contentsOfDirectory(atPath: VesselPaths.bottlesDirectory)
        guard let common = bottleNames.lazy
            .map({ "\(VesselPaths.bottlesDirectory)/\($0)/drive_c/Program Files (x86)/Steam/steamapps/common" })
            .first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("No hay una biblioteca Steam de Vessel instalada.")
        }
        let targets = try FileManager.default.contentsOfDirectory(atPath: common)
            .filter { FileManager.default.fileExists(atPath: "\(common)/\($0)") }
            .sorted()
            .prefix(6)
        var scanned = 0
        for target in targets {
            let folder = "\(common)/\(target)"
            let resolveStart = Date()
            guard let executable = SteamLibraryImporter.mainGameExecutable(in: folder) else { continue }
            let planStart = Date()
            let plan = RuntimeDependencyProvisioner.repairPlan(executable: executable)
            let resolveMS = Int(planStart.timeIntervalSince(resolveStart) * 1_000)
            let planMS = Int(Date().timeIntervalSince(planStart) * 1_000)
            print("VESSEL_RUNTIME_SCAN|\(target)|\((executable as NSString).lastPathComponent)|resolve=\(resolveMS)ms|plan=\(planMS)ms|\(plan.dependencies.map(\.rawValue).joined(separator: ","))|\(plan.winetricksVerbs.joined(separator: ","))")
            XCTAssertLessThan(planMS, 2_000, "El inventario no debe bloquear el lanzamiento de \(target)")
            scanned += 1
        }
        XCTAssertGreaterThan(scanned, 0)
    }
}
