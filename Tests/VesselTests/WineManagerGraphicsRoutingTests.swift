import Foundation
import CoreGraphics
import XCTest
@testable import Vessel

@MainActor
final class WineManagerGraphicsRoutingTests: XCTestCase {
    func testDisabledWineDebuggerPolicySkipsCrashPromptInBothRegistryViews() throws {
        let commands = WineManager.disabledAutoDebuggerRegistryCommands

        XCTAssertEqual(commands.count, 4)
        XCTAssertEqual(Set(commands.compactMap { command in
            guard let keyIndex = command.firstIndex(of: "add"),
                  command.indices.contains(keyIndex + 1) else { return nil }
            return command[keyIndex + 1]
        }), [
            #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug"#,
            #"HKLM\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug"#
        ])

        let debuggerCommands = commands.filter { $0.contains("Debugger") }
        let autoCommands = commands.filter { $0.contains("Auto") }
        XCTAssertEqual(debuggerCommands.count, 2)
        XCTAssertEqual(autoCommands.count, 2)
        for command in debuggerCommands {
            let dataIndex = try XCTUnwrap(command.firstIndex(of: "/d"))
            XCTAssertEqual(command[dataIndex + 1], "")
        }
        for command in autoCommands {
            let dataIndex = try XCTUnwrap(command.firstIndex(of: "/d"))
            XCTAssertEqual(command[dataIndex + 1], "1")
        }
    }

    func testKleiDataBundleEngineKeepsBin64WorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-klei-working-dir-\(UUID().uuidString)", isDirectory: true)
        let executableDirectory = root.appendingPathComponent("bin64", isDirectory: true)
        let bundles = root.appendingPathComponent("data/databundles", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundles, withIntermediateDirectories: true)
        for file in ["hashes.txt", "shaders.zip", "scripts.zip"] {
            try Data(file.utf8).write(to: bundles.appendingPathComponent(file))
        }
        let executable = executableDirectory.appendingPathComponent("custom-klei-engine.exe")
        try writePE(
            to: executable,
            is64Bit: true,
            imports: ["libEGL.dll", "libGLESv2.dll"],
            marker: "DataBundleFileHashes Mounting file system databundles/shaders.zip"
        )

        XCTAssertEqual(
            WineManager().gameWorkingDirectory(forExecutable: executable.path),
            executableDirectory.path
        )
    }

    func testShiningRockDualRendererEngineIsDetectedStructurally() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-shining-rock-\(UUID().uuidString)", isDirectory: true)
        let dataDirectory = root.appendingPathComponent("WinData", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        let executable = root.appendingPathComponent("Application-steam-x32.exe")
        try writePE(to: executable, is64Bit: false, imports: ["steam_api.dll"], marker: "")
        for name in [
            "Runtime-steam-x32.dll",
            "VideoDX9-steam-x32.dll",
            "VideoDX11-steam-x32.dll"
        ] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        try Data("package-0".utf8).write(to: dataDirectory.appendingPathComponent("data0.pkg"))
        try Data("package-1".utf8).write(to: dataDirectory.appendingPathComponent("data1.pkg"))

        XCTAssertTrue(WineManager().isShiningRockDualRendererEngine(executable.path))
    }

    func testShiningRockInitialDisplayFitsVisibleMacArea() {
        XCTAssertEqual(
            WineManager.shiningRockDisplaySize(for: CGSize(width: 1512, height: 870)),
            CGSize(width: 1280, height: 800)
        )
        XCTAssertEqual(
            WineManager.shiningRockDisplaySize(for: CGSize(width: 1366, height: 768)),
            CGSize(width: 1120, height: 704)
        )
    }

    func testAlmostHumanLuaJITD3D9EngineIsDetectedStructurally() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-almost-human-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("custom-dungeon-engine.exe")
        try writePE(
            to: executable,
            is64Bit: false,
            imports: ["d3d9.dll"],
            marker: "Direct3DCreate9 LuaJIT 2.0.0-beta9 shaders/d3d9/mesh.hlsl XAudio2Create"
        )
        try Data("FreeImage".utf8).write(to: root.appendingPathComponent("FreeImage.dll"))

        XCTAssertTrue(WineManager().isAlmostHumanLuaJITD3D9Engine(executable.path))
    }

    func testHPL3UsesMatchingOfficialNoSteamExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-hpl3-\(UUID().uuidString)", isDirectory: true)
        let shaderDirectory = root.appendingPathComponent("_shadersource", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: shaderDirectory, withIntermediateDirectories: true)
        try Data("api".utf8).write(to: root.appendingPathComponent("hps_api.hps"))
        try Data("materials".utf8).write(to: root.appendingPathComponent("materials.cfg"))
        try Data("shaders".utf8).write(
            to: shaderDirectory.appendingPathComponent("shadercache.xml")
        )

        let marker = """
        -------- THE HPL ENGINE LOG ------------
        HPLJobThread_
        Failed to create OpenGL main thread context
         Init Glew...
        """
        let engineImports = [
            "OPENGL32.dll", "glew32.dll", "SDL2.dll", "newton.dll",
            "fmodex64.dll", "fmod_event64.dll"
        ]
        let main = root.appendingPathComponent("CustomHPLGame.exe")
        let noSteam = root.appendingPathComponent("CustomHPLGame_NoSteam.exe")
        try writePE(
            to: main,
            is64Bit: true,
            imports: engineImports + ["steam_api64.dll"],
            marker: marker
        )
        try writePE(to: noSteam, is64Bit: true, imports: engineImports, marker: marker)

        let manager = WineManager()
        XCTAssertTrue(manager.isLegacyHPL3OpenGLEngine(main.path))
        XCTAssertTrue(manager.isLegacyHPL3OpenGLEngine(noSteam.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: main.path), .opengl)
        let preferred = try XCTUnwrap(manager.preferredLegacyHPL3Executable(for: main.path))
        XCTAssertEqual(
            URL(fileURLWithPath: preferred).resolvingSymlinksInPath(),
            noSteam.resolvingSymlinksInPath()
        )
        XCTAssertNil(manager.preferredLegacyHPL3Executable(for: noSteam.path))
        let tracking = manager.launchTrackingTarget(
            for: main.path,
            basePrefix: "/tmp/Vessel/Bottles/HPL3"
        )
        XCTAssertEqual(
            URL(fileURLWithPath: tracking.executable).resolvingSymlinksInPath(),
            noSteam.resolvingSymlinksInPath()
        )
        XCTAssertEqual(tracking.prefix, "/tmp/Vessel/Bottles/HPL3__opengl-legacy")
    }

    func testHPLMarkersWithoutResourceContractDoNotChangeOpenGLRouting() throws {
        let executable = try makePE64(
            named: "generic-opengl.exe",
            marker: """
            -------- THE HPL ENGINE LOG ------------
            HPLJobThread_ Failed to create OpenGL main thread context Init Glew...
            """,
            imports: [
                "OPENGL32.dll", "glew32.dll", "SDL2.dll", "newton.dll",
                "fmodex64.dll", "fmod_event64.dll"
            ]
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let manager = WineManager()
        XCTAssertFalse(manager.isLegacyHPL3OpenGLEngine(executable.path))
        XCTAssertNil(manager.preferredLegacyHPL3Executable(for: executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .opengl)
    }

    func testLegacyOpenGLEngineParticipatesInUnifiedEnvironmentOnlyByPath() {
        let path = "/tmp/Vessel/Engines/wine-unified-opengl-legacy/bin/wine"

        XCTAssertTrue(WineEngineLocator.isUnifiedEngine(path))
        XCTAssertTrue(WineEngineLocator.isGameEngine(path))
        XCTAssertFalse(WineEngineLocator.isUnifiedEngine("/tmp/Vessel/Engines/wine-full/bin/wine"))
    }

    func testNihonFalcomYsOriginEngineUsesNativePointScaling() throws {
        let executable = try makePE32(
            named: "custom-falcom-engine.exe",
            marker: #"SOFTWARE\Falcom\YSO_WIN Release\data.nya failed: Subsys D3D::Initialize"#,
            imports: ["d3d9.dll", "d3dx9_43.dll", "dsound.dll", "dinput8.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        let release = directory.appendingPathComponent("release", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        for package in ["data.nya", "data.ni", "data.na"] {
            try Data(package.utf8).write(to: release.appendingPathComponent(package))
        }

        let manager = WineManager()
        XCTAssertTrue(manager.isNihonFalcomYsOriginD3D9Engine(executable.path))
        XCTAssertTrue(manager.usesLegacyD3D9NativeScaling(executable.path))
        XCTAssertTrue(manager.usesFullCompatibilityEngineForD3D9(executable.path))
    }

    func testFalcomMarkersWithoutResourceTrioDoNotChangeD3D9Scaling() throws {
        let executable = try makePE32(
            named: "generic-d3d9.exe",
            marker: #"SOFTWARE\Falcom\YSO_WIN Release\data.nya failed: Subsys D3D::Initialize"#,
            imports: ["d3d9.dll", "d3dx9_43.dll", "dsound.dll", "dinput8.dll"]
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let manager = WineManager()
        XCTAssertFalse(manager.isNihonFalcomYsOriginD3D9Engine(executable.path))
        XCTAssertFalse(manager.usesLegacyD3D9NativeScaling(executable.path))
    }

    func testPlaydeadLegacyD3D9EngineUsesOpenGLCompatibleNativeScaling() throws {
        let executable = try makePE32(
            named: "custom-playdead-runtime.exe",
            marker: """
            GetBackBufferSize():vector2i
            Background and foreground rendered in low resolution
            AKSound::AKSound(): Could not create the Sound Engine.
            Custom backbuffer size: %s, %s
            """,
            imports: ["d3d9.dll", "d3dx9_43.dll", "dinput8.dll", "xinput1_3.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("boot".utf8).write(to: directory.appendingPathComponent("CUSTOM_BOOT.PKG"))
        try Data("runtime".utf8).write(
            to: directory.appendingPathComponent("custom_runtime.pkg")
        )
        try Data("""
        backbufferheight = 720
        windowedmode = false
        use8bitrender = false
        """.utf8).write(to: directory.appendingPathComponent("SETTINGS.TXT"))

        let manager = WineManager()

        XCTAssertTrue(manager.isPlaydeadLegacyD3D9Engine(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d9)
        XCTAssertTrue(manager.usesLegacyD3D9NativeScaling(executable.path))
        XCTAssertTrue(manager.usesFullCompatibilityEngineForD3D9(executable.path))
    }

    func testPlaydeadMarkersWithoutMatchingPackagePairKeepDefaultD3D9Policy() throws {
        let executable = try makePE32(
            named: "generic-d3d9-runtime.exe",
            marker: """
            GetBackBufferSize():vector2i
            Background and foreground rendered in low resolution
            AKSound::AKSound(): Could not create the Sound Engine.
            Custom backbuffer size: %s, %s
            """,
            imports: ["d3d9.dll", "d3dx9_43.dll", "dinput8.dll", "xinput1_3.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("boot".utf8).write(to: directory.appendingPathComponent("alpha_boot.pkg"))
        try Data("runtime".utf8).write(
            to: directory.appendingPathComponent("beta_runtime.pkg")
        )
        try Data("""
        backbufferheight = 720
        windowedmode = false
        use8bitrender = false
        """.utf8).write(to: directory.appendingPathComponent("settings.txt"))

        let manager = WineManager()

        XCTAssertFalse(manager.isPlaydeadLegacyD3D9Engine(executable.path))
        XCTAssertFalse(manager.usesLegacyD3D9NativeScaling(executable.path))
    }

    func testClassicPopCapSteamEngineRequiresNativePointScaling() throws {
        let executable = try makePE32(
            named: "generic-sexyapp-runtime.exe",
            marker: """
            ?AVSexyAppBase@Sexy@@
            PopCapDRM_EnableLocking
            PopCapDrm_IPC_Response
            SteamStartup
            SteamBlockingCall
            SteamIsAppSubscribed
            Unable to load Steam.dll
            !popcapdrmprotect!
            """
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["MAIN.PAK", "Bass.DLL", "J2K-CODEC.DLL"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        let properties = directory.appendingPathComponent("properties", isDirectory: true)
        try FileManager.default.createDirectory(at: properties, withIntermediateDirectories: true)
        try Data("""
        <Properties>
        <Boolean id="NoReg">true</Boolean>
        <Boolean id="DefaultWindowed">false</Boolean>
        <String id="PartnerName">Steam</String>
        <String id="ProdName">GenericPopCapProduct</String>
        <Integer id="SteamId">1234</Integer>
        </Properties>
        """.utf8).write(to: properties.appendingPathComponent("PARTNER.XML"))

        let manager = WineManager()

        XCTAssertTrue(manager.isClassicPopCapSteamEngine(executable.path))
        XCTAssertEqual(
            manager.classicPopCapSteamProductName(executable.path),
            "GenericPopCapProduct"
        )
        XCTAssertTrue(manager.usesLegacyD3D9NativeScaling(executable.path))
        XCTAssertFalse(SteamDRMScanner.hasSteamStub(executable.path))
        XCTAssertTrue(manager.requiresSteamAppLaunch(executable.path))
        let trackingTarget = manager.launchTrackingTarget(
            for: executable.path,
            basePrefix: "/tmp/vessel-popcap-prefix"
        )
        XCTAssertEqual(
            trackingTarget.executable,
            "/tmp/vessel-popcap-prefix/drive_c/ProgramData/PopCap Games/GenericPopCapProduct/popcapgame1.exe"
        )
        XCTAssertEqual(trackingTarget.prefix, "/tmp/vessel-popcap-prefix")
    }

    func testPopCapLayoutWithoutLegacySteamPartnerKeepsDefaultPolicy() throws {
        let executable = try makePE32(
            named: "generic-sexyapp-runtime.exe",
            marker: """
            ?AVSexyAppBase@Sexy@@
            PopCapDRM_EnableLocking
            PopCapDrm_IPC_Response
            SteamStartup
            SteamBlockingCall
            SteamIsAppSubscribed
            Unable to load Steam.dll
            !popcapdrmprotect!
            """
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["main.pak", "bass.dll", "j2k-codec.dll"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        let properties = directory.appendingPathComponent("properties", isDirectory: true)
        try FileManager.default.createDirectory(at: properties, withIntermediateDirectories: true)
        try Data("""
        <Properties>
        <Boolean id="NoReg">true</Boolean>
        <Boolean id="DefaultWindowed">false</Boolean>
        <String id="PartnerName">Retail</String>
        <String id="ProdName">GenericPopCapProduct</String>
        <Integer id="SteamId">1234</Integer>
        </Properties>
        """.utf8).write(to: properties.appendingPathComponent("partner.xml"))

        let manager = WineManager()

        XCTAssertFalse(manager.isClassicPopCapSteamEngine(executable.path))
        XCTAssertFalse(manager.usesLegacyD3D9NativeScaling(executable.path))
        XCTAssertFalse(manager.requiresSteamAppLaunch(executable.path))
        XCTAssertEqual(
            manager.launchTrackingTarget(
                for: executable.path,
                basePrefix: "/tmp/vessel-popcap-prefix"
            ).executable,
            executable.path
        )
    }

    func testLegacyValveRunMeContractRequiresSteamAppLaunch() throws {
        let executable = try makePE32(named: "CustomClassicGame.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePE(
            to: directory.appendingPathComponent("RUNME.EXE"),
            is64Bit: false,
            imports: [],
            marker: #"u:\valve_main\src\utils\runme\Release\runme.pdb runme.dat CreateProcessA WaitForSingleObject"#
        )
        try Data("customclassicgame.exe\r\n".utf8).write(
            to: directory.appendingPathComponent("RunMe.Dat")
        )

        XCTAssertTrue(SteamDRMScanner.hasLegacyValveRunMeBootstrap(executable.path))
        XCTAssertFalse(SteamDRMScanner.hasSteamStub(executable.path))
        XCTAssertTrue(WineManager().requiresSteamAppLaunch(executable.path))
    }

    func testUnrelatedRunMeFilesDoNotChangeSteamLaunchPolicy() throws {
        let executable = try makePE32(named: "CustomClassicGame.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePE(
            to: directory.appendingPathComponent("runme.exe"),
            is64Bit: false,
            imports: [],
            marker: #"u:\valve_main\src\utils\runme\Release\runme.pdb runme.dat CreateProcessA WaitForSingleObject"#
        )
        try Data("another-game.exe\r\n".utf8).write(
            to: directory.appendingPathComponent("runme.dat")
        )

        XCTAssertFalse(SteamDRMScanner.hasLegacyValveRunMeBootstrap(executable.path))
        XCTAssertFalse(WineManager().requiresSteamAppLaunch(executable.path))
    }

    func testUnrealEngine1RepairsFactoryRendererAndViewportInIsolation() throws {
        let executable = try makePE32(named: "CustomUE1Game.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        for component in [
            "Core.dll", "Core.u", "Engine.dll", "Engine.u", "Render.dll",
            "WinDrv.dll", "OpenGlDrv.dll", "D3DDrv.dll", "SoftDrv.dll"
        ] {
            try Data(component.utf8).write(to: directory.appendingPathComponent(component))
        }
        let config = """
        [Engine.Engine]
        GameRenderDevice=GlideDrv.GlideRenderDevice
        WindowedRenderDevice=SoftDrv.SoftwareRenderDevice
        RenderDevice=GlideDrv.GlideRenderDevice
        ViewportManager=WinDrv.WindowsClient
        OtherPreference=KeepMe

        [WinDrv.WindowsClient]
        WindowedViewportX=640
        WindowedViewportY=480
        WindowedColorBits=16
        FullscreenViewportX=640
        FullscreenViewportY=480
        FullscreenColorBits=16
        UseDirectDraw=True
        StartupFullscreen=True
        """
        try Data(config.utf8).write(
            to: directory.appendingPathComponent("customue1game.INI")
        )

        let manager = WineManager()
        XCTAssertTrue(manager.isUnrealEngine1Game(executable.path))
        XCTAssertTrue(manager.usesLegacy32BitNativeScaling(executable.path))
        XCTAssertTrue(manager.usesLegacyD3D9NativeScaling(executable.path))
        let recoveryMarker = directory.appendingPathComponent("RUNNING.INI")
        try Data().write(to: recoveryMarker)
        XCTAssertTrue(manager.clearUnrealEngine1RecoveryMarker(executable: executable.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryMarker.path))
        let repaired = try XCTUnwrap(WineManager.repairedUnrealEngine1Config(
            existing: config,
            screenSize: CGSize(width: 1512, height: 982)
        ))

        XCTAssertEqual(
            repaired.components(separatedBy: "OpenGLDrv.OpenGLRenderDevice").count - 1,
            3
        )
        XCTAssertTrue(repaired.contains("WindowedViewportX=1512"))
        XCTAssertTrue(repaired.contains("WindowedViewportY=982"))
        XCTAssertTrue(repaired.contains("FullscreenViewportX=1512"))
        XCTAssertTrue(repaired.contains("FullscreenViewportY=982"))
        XCTAssertTrue(repaired.contains("WindowedColorBits=32"))
        XCTAssertTrue(repaired.contains("FullscreenColorBits=32"))
        XCTAssertTrue(repaired.contains("UseDirectDraw=False"))
        XCTAssertTrue(repaired.contains("OtherPreference=KeepMe"))
        XCTAssertTrue(repaired.contains("StartupFullscreen=True"))
    }

    func testUnrealEngine1PreservesValidPlayerDisplayPreferences() {
        let config = """
        [Engine.Engine]
        GameRenderDevice=OpenGLDrv.OpenGLRenderDevice
        WindowedRenderDevice=OpenGLDrv.OpenGLRenderDevice
        RenderDevice=OpenGLDrv.OpenGLRenderDevice
        ViewportManager=WinDrv.WindowsClient

        [WinDrv.WindowsClient]
        WindowedViewportX=1280
        WindowedViewportY=720
        WindowedColorBits=32
        FullscreenViewportX=1280
        FullscreenViewportY=720
        FullscreenColorBits=32
        UseDirectDraw=False
        StartupFullscreen=False
        """

        XCTAssertNil(WineManager.repairedUnrealEngine1Config(
            existing: config,
            screenSize: CGSize(width: 1512, height: 982)
        ))
    }

    func testUnrealEngine1RepairsSectionNamesCaseInsensitively() throws {
        let config = """
        [engine.engine]
        GameRenderDevice=GlideDrv.GlideRenderDevice
        WindowedRenderDevice=GlideDrv.GlideRenderDevice
        RenderDevice=GlideDrv.GlideRenderDevice
        ViewportManager=WinDrv.WindowsClient

        [windrv.windowsclient]
        WindowedViewportX=640
        WindowedViewportY=480
        FullscreenViewportX=640
        FullscreenViewportY=480
        UseDirectDraw=True
        """

        let repaired = try XCTUnwrap(WineManager.repairedUnrealEngine1Config(
            existing: config,
            screenSize: CGSize(width: 1512, height: 982)
        ))
        XCTAssertTrue(repaired.contains("GameRenderDevice=OpenGLDrv.OpenGLRenderDevice"))
        XCTAssertTrue(repaired.contains("WindowedViewportX=1512"))
        XCTAssertEqual(
            repaired.lowercased().components(separatedBy: "[engine.engine]").count - 1,
            1
        )
        XCTAssertEqual(
            repaired.lowercased().components(separatedBy: "[windrv.windowsclient]").count - 1,
            1
        )
    }

    func testUnrealEngine1ReplacesSoftwareFallbackWithBundledOpenGLRenderer() throws {
        let config = """
        [Engine.Engine]
        GameRenderDevice=SoftDrv.SoftwareRenderDevice
        WindowedRenderDevice=SoftDrv.SoftwareRenderDevice
        RenderDevice=SoftDrv.SoftwareRenderDevice
        ViewportManager=WinDrv.WindowsClient

        [WinDrv.WindowsClient]
        WindowedViewportX=640
        WindowedViewportY=480
        WindowedColorBits=16
        FullscreenViewportX=640
        FullscreenViewportY=480
        FullscreenColorBits=16
        UseDirectDraw=False
        """

        let repaired = try XCTUnwrap(WineManager.repairedUnrealEngine1Config(
            existing: config,
            screenSize: CGSize(width: 1512, height: 982)
        ))
        XCTAssertFalse(repaired.contains("SoftDrv.SoftwareRenderDevice"))
        XCTAssertEqual(
            repaired.components(separatedBy: "OpenGLDrv.OpenGLRenderDevice").count - 1,
            3
        )
        XCTAssertTrue(repaired.contains("FullscreenViewportX=1512"))
        XCTAssertTrue(repaired.contains("FullscreenViewportY=982"))
    }

    func testDeusExUE1SignatureDoesNotBroadenGenericRendererInstall() throws {
        let executable = try makePE32(named: "DeusEx.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        for component in [
            "Core.dll", "Core.u", "Engine.dll", "Engine.u", "Render.dll",
            "WinDrv.dll", "OpenGlDrv.dll", "D3DDrv.dll", "SoftDrv.dll",
            "DeusEx.dll", "DeusEx.u", "DeusExText.dll", "Extension.dll",
            "Extension.u", "ConSys.dll", "ConSys.u"
        ] {
            try Data(component.utf8).write(to: directory.appendingPathComponent(component))
        }
        let config = """
        [URL]
        MapExt=dx
        [Engine.Engine]
        GameRenderDevice=GlideDrv.GlideRenderDevice
        GameEngine=DeusEx.DeusExGameEngine
        WindowedRenderDevice=SoftDrv.SoftwareRenderDevice
        RenderDevice=GlideDrv.GlideRenderDevice
        ViewportManager=WinDrv.WindowsClient
        Root=DeusEx.DeusExRootWindow
        [WinDrv.WindowsClient]
        WindowedViewportX=640
        WindowedViewportY=480
        FullscreenViewportX=640
        FullscreenViewportY=480
        """
        try Data(config.utf8).write(to: directory.appendingPathComponent("DEUSEX.INI"))

        let manager = WineManager()
        XCTAssertTrue(manager.isUnrealEngine1Game(executable.path))
        XCTAssertTrue(manager.isDeusExUnrealEngine1Game(executable.path))
    }

    func testDeusExUE1ForcesModernOpenGLAndSafeWindowWithoutOverflow() throws {
        let config = """
        [FirstRun]
        FirstRun=0

        [Engine.Engine]
        GameRenderDevice=D3DDrv.D3DRenderDevice
        WindowedRenderDevice=D3DDrv.D3DRenderDevice
        RenderDevice=D3DDrv.D3DRenderDevice
        ViewportManager=WinDrv.WindowsClient
        OtherPreference=KeepMe

        [WinDrv.WindowsClient]
        WindowedViewportX=1512
        WindowedViewportY=982
        WindowedColorBits=32
        FullscreenViewportX=1512
        FullscreenViewportY=982
        FullscreenColorBits=32
        UseDirectDraw=False
        StartupFullscreen=True

        [OpenGLDrv.OpenGLRenderDevice]
        UsePalette=True
        UseAlphaPalette=True
        UseTrilinear=False
        MaxAnisotropy=0
        """
        let safeWindow = WineManager.safeUnrealEngine1WindowSize(
            visibleSize: CGSize(width: 1512, height: 870)
        )
        XCTAssertEqual(safeWindow, CGSize(width: 1440, height: 810))

        let repaired = try XCTUnwrap(WineManager.repairedUnrealEngine1Config(
            existing: config,
            screenSize: CGSize(width: 1512, height: 982),
            windowedSize: safeWindow,
            forceModernOpenGL: true,
            forceSafeWindowedMode: true
        ))
        XCTAssertEqual(
            repaired.components(separatedBy: "OpenGLDrv.OpenGLRenderDevice").count - 1,
            4
        )
        XCTAssertTrue(repaired.contains("WindowedViewportX=1440"))
        XCTAssertTrue(repaired.contains("WindowedViewportY=810"))
        XCTAssertTrue(repaired.contains("FullscreenViewportX=1512"))
        XCTAssertTrue(repaired.contains("FullscreenViewportY=982"))
        XCTAssertTrue(repaired.contains("StartupFullscreen=False"))
        XCTAssertTrue(repaired.contains("FirstRun=1100"))
        XCTAssertTrue(repaired.contains("UsePalette=False"))
        XCTAssertTrue(repaired.contains("UseBGRATextures=True"))
        XCTAssertTrue(repaired.contains("FrameRateLimit=60"))
        XCTAssertTrue(repaired.contains("OtherPreference=KeepMe"))
    }

    func testDeusExRendererIsVerifiedBackedUpAndSelfRepairsAfterSteamVerify() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-deus-renderer-\(UUID().uuidString)", isDirectory: true)
        let game = root.appendingPathComponent("System", isDirectory: true)
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)

        var stock = Data([0x4D, 0x5A])
        stock.append(Data(repeating: 0x11, count: 110_590))
        var modern = Data([0x4D, 0x5A])
        modern.append(Data(repeating: 0x22, count: 191_998))
        let destination = game.appendingPathComponent("OpenGlDrv.dll")
        let local = root.appendingPathComponent("OpenGlDrv-modern.dll")
        try stock.write(to: destination)
        try modern.write(to: local)

        let manager = UnrealEngine1RendererManager(
            cacheDirectory: cache.path,
            localRendererPath: local.path,
            rendererSHA256: UnrealEngine1RendererManager.sha256(modern),
            stockRendererSHA256: UnrealEngine1RendererManager.sha256(stock)
        )
        let executable = game.appendingPathComponent("DeusEx.exe").path
        let first = try await manager.installModernDeusExOpenGL(forExecutable: executable)
        XCTAssertEqual(first.status, .installedPinned)
        XCTAssertEqual(try Data(contentsOf: destination), modern)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: destination.path + ".vessel-original")),
            stock
        )

        let second = try await manager.installModernDeusExOpenGL(forExecutable: executable)
        XCTAssertEqual(second.status, .alreadyPinned)

        try stock.write(to: destination, options: .atomic)
        let repaired = try await manager.installModernDeusExOpenGL(forExecutable: executable)
        XCTAssertEqual(repaired.status, .installedPinned)
        XCTAssertEqual(try Data(contentsOf: destination), modern)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: destination.path + ".vessel-original")),
            stock
        )
    }

    func testDeusExRendererPreservesUnknownModernCustomDLL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-deus-custom-renderer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var custom = Data([0x4D, 0x5A])
        custom.append(Data(repeating: 0x33, count: 180_000))
        let destination = root.appendingPathComponent("OpenGlDrv.dll")
        try custom.write(to: destination)

        let manager = UnrealEngine1RendererManager(
            cacheDirectory: root.appendingPathComponent("Cache").path,
            localRendererPath: root.appendingPathComponent("missing.dll").path,
            rendererSHA256: String(repeating: "0", count: 64),
            stockRendererSHA256: String(repeating: "1", count: 64)
        )
        let result = try await manager.installModernDeusExOpenGL(
            forExecutable: root.appendingPathComponent("DeusEx.exe").path
        )
        XCTAssertEqual(result.status, .existingCustom)
        XCTAssertEqual(try Data(contentsOf: destination), custom)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.path + ".vessel-original"
        ))
    }

    func testDeusExRendererPreservesUnknownSmallCustomDLL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-deus-small-renderer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var custom = Data([0x4D, 0x5A])
        custom.append(Data(repeating: 0x44, count: 90_000))
        let destination = root.appendingPathComponent("OpenGlDrv.dll")
        try custom.write(to: destination)

        let manager = UnrealEngine1RendererManager(
            cacheDirectory: root.appendingPathComponent("Cache").path,
            localRendererPath: root.appendingPathComponent("missing.dll").path,
            rendererSHA256: String(repeating: "0", count: 64),
            stockRendererSHA256: String(repeating: "1", count: 64)
        )
        let result = try await manager.installModernDeusExOpenGL(
            forExecutable: root.appendingPathComponent("DeusEx.exe").path
        )
        XCTAssertEqual(result.status, .existingCustom)
        XCTAssertEqual(try Data(contentsOf: destination), custom)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.path + ".vessel-original"
        ))
    }

    func testFalcomFirstRunConfigUsesLogicalFullscreenResolution() throws {
        let config = try XCTUnwrap(WineManager.repairedFalcomYsOriginConfig(
            existing: nil,
            screenSize: CGSize(width: 1512, height: 982)
        ))

        XCTAssertTrue(config.contains("BackBufferWidth=1512"))
        XCTAssertTrue(config.contains("BackBufferHeight=982"))
        XCTAssertTrue(config.contains("Windowed=0"))
        XCTAssertTrue(config.contains(#"Assign{KEY_ACTION}="Z""#))
    }

    func testFalcomFullscreenRepairPreservesUnrelatedPreferences() throws {
        let existing = """
        IniVersion=0x100
        [game]
        Language=3
        [graphics]
        BackBufferWidth=960
        BackBufferHeight=600
        Windowed=0
        WaitVSync=0
        [sound]
        BgmVolume=321
        """
        let repaired = try XCTUnwrap(WineManager.repairedFalcomYsOriginConfig(
            existing: existing,
            screenSize: CGSize(width: 1512, height: 982)
        ))

        XCTAssertTrue(repaired.contains("BackBufferWidth=1512"))
        XCTAssertTrue(repaired.contains("BackBufferHeight=982"))
        XCTAssertTrue(repaired.contains("Windowed=0"))
        XCTAssertTrue(repaired.contains("Language=3"))
        XCTAssertTrue(repaired.contains("WaitVSync=0"))
        XCTAssertTrue(repaired.contains("BgmVolume=321"))
    }

    func testFalcomValidWindowedPreferenceIsNotOverridden() {
        let existing = """
        [graphics]
        BackBufferWidth=1280
        BackBufferHeight=800
        Windowed=1
        """

        XCTAssertNil(WineManager.repairedFalcomYsOriginConfig(
            existing: existing,
            screenSize: CGSize(width: 1512, height: 982)
        ))
    }

    func testGenericTopLevelX64DirectoryStillUsesGameRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-root-working-dir-\(UUID().uuidString)", isDirectory: true)
        let executableDirectory = root.appendingPathComponent("x64", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executable = executableDirectory.appendingPathComponent("generic-engine.exe")
        try writePE(to: executable, is64Bit: true, imports: ["d3d11.dll"], marker: "")

        XCTAssertEqual(
            WineManager().gameWorkingDirectory(forExecutable: executable.path),
            root.path
        )
    }

    func testWineProcessLookupDisablesLsofNameResolution() {
        XCTAssertEqual(
            WineManager.lsofProcessLookupArguments(processID: 42),
            ["-nP", "-a", "-p", "42", "-Fn"]
        )
    }

    func testWineChildEnvironmentNeverInheritsDevelopmentCredentials() {
        let input = [
            "HOME": "/Users/example",
            "PATH": "/usr/bin:/bin",
            "LANG": "es_ES.UTF-8",
            "GITHUB_PERSONAL_ACCESS_TOKEN": "placeholder-secret",
            "OPENAI_API_KEY": "placeholder-secret",
            "AWS_SESSION_TOKEN": "placeholder-secret",
            "SSH_AUTH_SOCK": "/private/tmp/agent.sock"
        ]

        let sanitized = WineManager.sanitizedInheritedEnvironment(input)

        XCTAssertEqual(sanitized["HOME"], "/Users/example")
        XCTAssertEqual(sanitized["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(sanitized["LANG"], "es_ES.UTF-8")
        XCTAssertNil(sanitized["GITHUB_PERSONAL_ACCESS_TOKEN"])
        XCTAssertNil(sanitized["OPENAI_API_KEY"])
        XCTAssertNil(sanitized["AWS_SESSION_TOKEN"])
        XCTAssertNil(sanitized["SSH_AUTH_SOCK"])
    }

    func testFullEngineControlCommandsMatchSteamSynchronization() {
        let environment = WineManager.wineControlEnvironment(
            prefix: "/tmp/vessel-prefix",
            wine: "/tmp/Vessel/Engines/wine-full/bin/wine"
        )

        XCTAssertEqual(environment["WINEPREFIX"], "/tmp/vessel-prefix")
        XCTAssertEqual(environment["WINEMSYNC"], "1")
        XCTAssertEqual(environment["WINEESYNC"], "1")
        XCTAssertEqual(environment["WINEFSYNC"], "1")
        XCTAssertEqual(
            environment["WINESERVER"],
            "/tmp/Vessel/Engines/wine-full/bin/wineserver"
        )
    }

    func testOtherEngineControlCommandsKeepTheirLaunchSynchronizationUndecided() {
        let environment = WineManager.wineControlEnvironment(
            prefix: "/tmp/vessel-prefix",
            wine: "/tmp/Vessel/Engines/wine-unified/bin/wine"
        )

        XCTAssertNil(environment["WINEMSYNC"])
        XCTAssertNil(environment["WINEESYNC"])
        XCTAssertNil(environment["WINEFSYNC"])
        XCTAssertNil(environment["WINESERVER"])
    }

    func testLaunchAgentKeepsItsPrivateCommandAcrossRecoveryKickstarts() {
        let script = WineManager.selfRemovingLaunchAgentScript(
            commandFile: "/tmp/Vessel's private launch.sh",
            workingDirectory: "/tmp/Game Folder",
            command: "exec /usr/bin/env -i WINEPREFIX='/tmp/prefix' wine game.exe"
        )

        XCTAssertTrue(script.hasPrefix(
            "(/bin/sleep 90; /bin/rm -f '/tmp/Vessel'\\''s private launch.sh' '/tmp/Vessel'\\''s private launch.sh.started') >/dev/null 2>&1 &\n"
        ))
        XCTAssertTrue(script.contains("/usr/bin/touch '/tmp/Vessel'\\''s private launch.sh.started'\n"))
        XCTAssertTrue(script.contains("cd '/tmp/Game Folder'\n"))
        XCTAssertTrue(script.hasSuffix("wine game.exe\n"))
    }

    func testLaunchAgentChecksAttemptMarkerWithExistingMacOSTestBinary() {
        XCTAssertEqual(
            WineManager.launchAttemptMarkerCheckCommand("/tmp/Vessel's private launch.sh.started"),
            "/bin/test -f '/tmp/Vessel'\\''s private launch.sh.started'"
        )
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "/bin/test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/usr/bin/test"))
    }

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

    private func writePE(
        to url: URL,
        is64Bit: Bool,
        imports: [String],
        marker: String,
        exports: [String] = []
    ) throws {
        var data = Data(repeating: 0, count: 0x800)
        let peOffset = 0x80
        let optionalOffset = peOffset + 24
        let optionalSize = is64Bit ? 0xf0 : 0xe0
        let directoryOffset = optionalOffset + (is64Bit ? 112 : 96)
        let sectionOffset = optionalOffset + optionalSize
        let rawSectionOffset = 0x200

        data[0] = 0x4d
        data[1] = 0x5a
        writeUInt32(UInt32(peOffset), to: &data, at: 0x3c)
        data[peOffset] = 0x50
        data[peOffset + 1] = 0x45
        writeUInt16(is64Bit ? 0x8664 : 0x014c, to: &data, at: peOffset + 4)
        writeUInt16(1, to: &data, at: peOffset + 6)
        writeUInt16(UInt16(optionalSize), to: &data, at: peOffset + 20)
        writeUInt16(is64Bit ? 0x020b : 0x010b, to: &data, at: optionalOffset)
        if is64Bit {
            writeUInt64(0x0000_0001_4000_0000, to: &data, at: optionalOffset + 24)
            writeUInt32(16, to: &data, at: optionalOffset + 108)
        } else {
            writeUInt32(0x0040_0000, to: &data, at: optionalOffset + 28)
            writeUInt32(16, to: &data, at: optionalOffset + 92)
        }
        writeUInt32(0x200, to: &data, at: optionalOffset + 60) // SizeOfHeaders

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
                let nameRVA = UInt32(0x1000 + nameOffset - rawSectionOffset)
                writeUInt32(nameRVA, to: &data, at: descriptor + 12)
                let bytes = Data(library.utf8) + Data([0])
                data.replaceSubrange(nameOffset..<(nameOffset + bytes.count), with: bytes)
                nameOffset += bytes.count
            }
        }

        if !exports.isEmpty {
            let exportDirectoryOffset = 0x300
            let functionTableOffset = 0x340
            let nameTableOffset = 0x380
            let ordinalTableOffset = 0x3c0
            writeUInt32(0x1100, to: &data, at: directoryOffset)
            writeUInt32(0x100, to: &data, at: directoryOffset + 4)
            writeUInt32(UInt32(exports.count), to: &data, at: exportDirectoryOffset + 20)
            writeUInt32(UInt32(exports.count), to: &data, at: exportDirectoryOffset + 24)
            writeUInt32(0x1140, to: &data, at: exportDirectoryOffset + 28)
            writeUInt32(0x1180, to: &data, at: exportDirectoryOffset + 32)
            writeUInt32(0x11c0, to: &data, at: exportDirectoryOffset + 36)

            var exportNameOffset = 0x600
            for (index, symbol) in exports.enumerated() {
                writeUInt32(0x1000, to: &data, at: functionTableOffset + index * 4)
                writeUInt32(
                    UInt32(0x1000 + exportNameOffset - rawSectionOffset),
                    to: &data,
                    at: nameTableOffset + index * 4
                )
                writeUInt16(UInt16(index), to: &data, at: ordinalTableOffset + index * 2)
                let bytes = Data(symbol.utf8) + Data([0])
                data.replaceSubrange(
                    exportNameOffset..<(exportNameOffset + bytes.count),
                    with: bytes
                )
                exportNameOffset += bytes.count
            }
        }

        data.append(Data(marker.utf8))
        try data.write(to: url)
    }

    private func makePE32(
        named name: String,
        marker: String = "",
        imports: [String] = []
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-graphics-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try writePE(to: url, is64Bit: false, imports: imports, marker: marker)
        return url
    }

    private func makePE64(
        named name: String,
        marker: String = "",
        imports: [String] = []
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-graphics-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try writePE(to: url, is64Bit: true, imports: imports, marker: marker)
        return url
    }

    private func makeRTsoftProtonExecutable(
        imports: [String]? = nil,
        marker: String? = nil,
        includeTexture: Bool = true,
        includeFont: Bool = true
    ) throws -> URL {
        let requiredImports = [
            "OPENGL32.dll", "fmod.dll", "zlibwapi.dll", "DINPUT8.dll", "libcurl-x64.dll"
        ]
        let requiredMarkers = [
            #"d:\projects\proton\shared\audio\audiomanagerfmodstudio.cpp"#,
            "protoncurl-agent/1.0",
            "proton_temp.tmp",
            "Error initializing GL extensions. Update your GL drivers!"
        ].joined(separator: " ")
        let executable = try makePE64(
            named: "rtsoft-runtime.exe",
            marker: marker ?? requiredMarkers,
            imports: imports ?? requiredImports
        )
        let root = executable.deletingLastPathComponent()
        for library in ["fmod.dll", "zlibwapi.dll", "libcurl-x64.dll"] {
            try Data(library.utf8).write(to: root.appendingPathComponent(library))
        }
        let interface = root.appendingPathComponent("interface", isDirectory: true)
        try FileManager.default.createDirectory(at: interface, withIntermediateDirectories: true)
        if includeTexture {
            try Data("texture".utf8).write(to: interface.appendingPathComponent("skin.rttex"))
        }
        if includeFont {
            try Data("font".utf8).write(to: interface.appendingPathComponent("ui.rtfont"))
        }
        return executable
    }

    func testPE32DynamicOpenGLUsesUnifiedOpenGLLayer() throws {
        let executable = try makePE32(named: "deadcells_gl.exe", marker: "Failed to init SDL: OpenGL Error")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let manager = WineManager()

        XCTAssertTrue(manager.isExecutable32Bit(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .opengl)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .dxmt)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path), [.dxmt])
    }

    func testRendererNameOutsideImportTableCannotMisrouteOpenGLAsD3D9() throws {
        let executable = try makePE32(
            named: "moai-game.exe",
            marker: "Optional renderer list: D3D9.DLL",
            imports: ["OPENGL32.dll"]
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let manager = WineManager()

        XCTAssertEqual(manager.peImportedLibraries(forExecutable: executable.path), ["opengl32.dll"])
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .opengl)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .dxmt)
    }

    func testLegacyANGLE1SiblingDLLsRouteOpenGLESRuntimeToD3D9() throws {
        let executable = try makePE32(
            named: "custom-engine.exe",
            imports: ["libEGL.dll", "libGLESv2.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePE(
            to: directory.appendingPathComponent("libEGL.dll"),
            is64Bit: false,
            imports: ["d3d9.dll", "libGLESv2.dll"],
            marker: "ANGLE"
        )
        try writePE(
            to: directory.appendingPathComponent("libGLESv2.dll"),
            is64Bit: false,
            imports: ["d3d9.dll"],
            marker: "OpenGL ES 2.0 (ANGLE 1.0.0.2245) Direct3D9Ex"
        )

        let manager = WineManager()

        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d9)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .gcenx)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path), [.gcenx])
        XCTAssertTrue(manager.usesLegacyD3D9NativeScaling(executable.path))
    }

    func testClickteamMultimediaFusion2UsesNativePointScaling() throws {
        let executable = try makePE32(
            named: "packed-runtime.exe",
            marker: "mmfs2.dll kcmouse.mfx kcwctrl.mfx clickteam-movement-controller.mfx"
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("packed game data".utf8).write(
            to: directory.appendingPathComponent("PACKED-RUNTIME.WGM")
        )

        let manager = WineManager()

        XCTAssertTrue(manager.isClickteamMultimediaFusion2DirectDrawEngine(executable.path))
        XCTAssertTrue(manager.usesLegacy32BitNativeScaling(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .other)
    }

    func testClickteamMarkersWithoutMatchingDataContainerKeepRetina() throws {
        let executable = try makePE32(
            named: "unrelated-loader.exe",
            marker: "mmfs2.dll kcmouse.mfx kcwctrl.mfx"
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("different payload".utf8).write(
            to: directory.appendingPathComponent("other-game.wgm")
        )

        let manager = WineManager()

        XCTAssertFalse(manager.isClickteamMultimediaFusion2DirectDrawEngine(executable.path))
        XCTAssertFalse(manager.usesLegacy32BitNativeScaling(executable.path))
    }

    func testClassicVirtoolsDX7EngineUsesIsolatedVirtualDesktopRoute() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-virtools-\(UUID().uuidString)", isDirectory: true)
        let dlls = root.appendingPathComponent("Dlls", isDirectory: true)
        let cmo = root.appendingPathComponent("Cmo", isDirectory: true)
        let data = root.appendingPathComponent("Data/Animations", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [root, dlls, cmo, data] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let executable = root.appendingPathComponent("payload.exe")
        try writePE(
            to: executable,
            is64Bit: false,
            imports: ["CK2.dll", "VxMath.dll", "USER32.dll"],
            marker: "SetVirtoolsVersion CKRenderContext Vx3D_D3DR "
                + "Creating full-screen render context\0Classic Adventure Saves\0"
        )
        // El payload real puede conservar SteamStub: OEP dentro de `.bind`. El perfil Virtools
        // debe mantener el cliente oficial conectado pero lanzar este payload directamente para
        // poder envolverlo en el escritorio virtual.
        var protectedPayload = try Data(contentsOf: executable)
        writeUInt32(0x1000, to: &protectedPayload, at: 0xa8)
        protectedPayload.replaceSubrange(0x178..<0x180, with: Data(".bind\0\0\0".utf8))
        try protectedPayload.write(to: executable)
        for file in ["CK2.dll", "VxMath.dll"] {
            try Data(file.utf8).write(to: root.appendingPathComponent(file))
        }
        for file in ["CKDX7Rasterizer.dll", "VirtoolsLoaderR.dll"] {
            try Data(file.utf8).write(to: dlls.appendingPathComponent(file))
        }
        try Data("scene".utf8).write(to: cmo.appendingPathComponent("Main.cmo"))
        try Data("animation".utf8).write(to: data.appendingPathComponent("Walk.nmo"))

        let manager = WineManager()
        XCTAssertTrue(manager.isClassicVirtoolsDirectDrawEngine(executable.path))
        XCTAssertTrue(SteamDRMScanner.hasSteamStub(executable.path))
        XCTAssertTrue(manager.usesProtectedDirectLaunchWithConnectedSteam(executable.path))
        XCTAssertFalse(WineManager.requiresOfficialSteamAppLaunch(
            builtInProtection: manager.requiresSteamAppLaunch(executable.path),
            thirdPartyProtection: nil,
            directLaunchException: manager.usesProtectedDirectLaunchWithConnectedSteam(executable.path)
        ))
        XCTAssertEqual(
            manager.classicVirtoolsSaveFolderName(executable.path),
            "Classic Adventure Saves"
        )
        XCTAssertTrue(manager.usesLegacy32BitNativeScaling(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .other)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .gcenx)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path), [])
    }

    func testVirtoolsMarkersWithoutCompiledContentKeepGenericRouting() throws {
        let executable = try makePE32(
            named: "unrelated-runtime.exe",
            marker: "SetVirtoolsVersion CKRenderContext Vx3D_D3DR Creating full-screen render context",
            imports: ["CK2.dll", "VxMath.dll"]
        )
        let root = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("core".utf8).write(to: root.appendingPathComponent("CK2.dll"))
        try Data("math".utf8).write(to: root.appendingPathComponent("VxMath.dll"))

        let manager = WineManager()
        XCTAssertFalse(manager.isClassicVirtoolsDirectDrawEngine(executable.path))
        XCTAssertFalse(manager.usesLegacy32BitNativeScaling(executable.path))
    }

    func testClassicVirtoolsConfigOnlyRepairsColorDepth() throws {
        let created = try XCTUnwrap(
            WineManager.repairedClassicVirtoolsConfig(existing: nil)
        )
        XCTAssertEqual(created.count, 28)
        XCTAssertEqual(Array(created[16..<20]), [32, 0, 0, 0])

        var legacy = created
        legacy.replaceSubrange(4..<8, with: Data([7, 0, 0, 0]))
        legacy.replaceSubrange(16..<20, with: Data([16, 0, 0, 0]))
        let repaired = try XCTUnwrap(
            WineManager.repairedClassicVirtoolsConfig(existing: legacy)
        )

        XCTAssertEqual(Array(repaired[4..<8]), [7, 0, 0, 0])
        XCTAssertEqual(Array(repaired[16..<20]), [32, 0, 0, 0])
        XCTAssertNil(WineManager.repairedClassicVirtoolsConfig(existing: repaired))
        XCTAssertNil(WineManager.repairedClassicVirtoolsConfig(existing: Data(repeating: 0, count: 28)))
    }

    func testLegacyANGLE1PE64SiblingDLLsRouteOpenGLESRuntimeToD3D9() throws {
        let executable = try makePE64(
            named: "custom-engine-x64.exe",
            imports: ["libEGL.dll", "libGLESv2.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePE(
            to: directory.appendingPathComponent("libEGL.dll"),
            is64Bit: true,
            imports: ["d3d9.dll", "libGLESv2.dll"],
            marker: "1.4 (ANGLE 1.0.0.2249)"
        )
        try writePE(
            to: directory.appendingPathComponent("libGLESv2.dll"),
            is64Bit: true,
            imports: ["d3d9.dll"],
            marker: "OpenGL ES 2.0 (ANGLE 1.0.0.2249) Direct3DCreate9Ex"
        )

        let manager = WineManager()

        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d9)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .gcenx)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path), [.gcenx])
        XCTAssertTrue(manager.usesLegacyD3D9NativeScaling(executable.path))
        XCTAssertTrue(manager.usesFullCompatibilityEngineForD3D9(executable.path))
        XCTAssertTrue(manager.usesIsolatedDXVKForLegacyANGLE64(executable.path))
    }

    func testLegacyANGLE1PE64PrefersMatchingOfficialPE32Sibling() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-angle-architectures-\(UUID().uuidString)", isDirectory: true)
        let bin64 = root.appendingPathComponent("bin64", isDirectory: true)
        let bin32 = root.appendingPathComponent("bin", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: bin64, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin32, withIntermediateDirectories: true)

        let executable64 = bin64.appendingPathComponent("custom-engine_x64.exe")
        let executable32 = bin32.appendingPathComponent("custom-engine.exe")
        try writePE(to: executable64, is64Bit: true, imports: ["libEGL.dll", "libGLESv2.dll"], marker: "")
        try writePE(to: executable32, is64Bit: false, imports: ["libEGL.dll", "libGLESv2.dll"], marker: "")
        for (directory, is64Bit) in [(bin64, true), (bin32, false)] {
            try writePE(
                to: directory.appendingPathComponent("libEGL.dll"),
                is64Bit: is64Bit,
                imports: ["d3d9.dll", "libGLESv2.dll"],
                marker: "ANGLE"
            )
            try writePE(
                to: directory.appendingPathComponent("libGLESv2.dll"),
                is64Bit: is64Bit,
                imports: ["d3d9.dll"],
                marker: "OpenGL ES 2.0 (ANGLE 1.0.0.2249)"
            )
        }

        let preferred = try XCTUnwrap(
            WineManager().preferredLegacyANGLE1Executable(for: executable64.path)
        )
        XCTAssertTrue(
            FileManager.default.contentsEqual(atPath: preferred, andPath: executable32.path)
        )
    }

    func testSteamNetworkingStackRequiresRealSteamClient() throws {
        let executable = try makePE32(
            named: "online-engine.exe",
            marker: "SteamNetworking006 SteamMatchMaking009 SteamGameServer014",
            imports: ["steam_api.dll"]
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        XCTAssertTrue(WineManager().requiresRealSteamNetworking(executable.path))
    }

    func testPeerToPeerLobbyWithoutDedicatedServerRequiresRealSteamClient() throws {
        let executable = try makePE64(
            named: "peer-to-peer-engine.exe",
            marker: "SteamNetworking006 SteamMatchMaking009",
            imports: ["steam_api64.dll"]
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        XCTAssertTrue(WineManager().requiresRealSteamNetworking(executable.path))
    }

    func testSteamNetworkingWithoutMatchmakingDoesNotRequireRealSteamClient() throws {
        let executable = try makePE64(
            named: "telemetry-engine.exe",
            marker: "SteamNetworking006 SteamUserStats012",
            imports: ["steam_api64.dll"]
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        XCTAssertFalse(WineManager().requiresRealSteamNetworking(executable.path))
    }

    func testSteamAchievementsAloneDoNotRequireRealSteamClient() throws {
        let executable = try makePE32(
            named: "single-player-engine.exe",
            marker: "SteamUserStats012 SteamUser021",
            imports: ["steam_api.dll"]
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        XCTAssertFalse(WineManager().requiresRealSteamNetworking(executable.path))
    }

    func testModernPE64D3D9KeepsGcenxCompatibilityEngine() throws {
        let executable = try makePE64(named: "modern-d3d9-x64.exe", imports: ["d3d9.dll"])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let manager = WineManager()

        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d9)
        XCTAssertFalse(manager.usesLegacyD3D9NativeScaling(executable.path))
        XCTAssertFalse(manager.usesFullCompatibilityEngineForD3D9(executable.path))
        XCTAssertFalse(manager.usesIsolatedDXVKForLegacyANGLE64(executable.path))
    }

    func testChowdrenSDL2D3D9UsesOnlyItsStructuralRuntimeSignature() throws {
        let executable = try makePE32(
            named: "converted-runtime.exe",
            marker: "CHOWDREN_SDL_DEBUG CHOWDREN_SDL_LOG SDL_CreateRenderer SDL_Direct3D9GetAdapterIndex",
            imports: ["d3d9.dll", "steam_api.dll"]
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let manager = WineManager()

        XCTAssertTrue(manager.isChowdrenSDL2D3D9Engine(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d9)
        XCTAssertTrue(manager.usesFullCompatibilityEngineForD3D9(executable.path))
        XCTAssertFalse(manager.usesIsolatedDXVKForLegacyANGLE64(executable.path))
    }

    func testGenericSDL2D3D9DoesNotInheritChowdrenBackend() throws {
        let executable = try makePE32(
            named: "generic-sdl-game.exe",
            marker: "SDL_CreateRenderer SDL_Direct3D9GetAdapterIndex",
            imports: ["d3d9.dll"]
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        XCTAssertFalse(WineManager().isChowdrenSDL2D3D9Engine(executable.path))
    }

    func testChowdrenMarkersWithoutD3D9ImportDoNotSelectD3D9Backend() throws {
        let executable = try makePE32(
            named: "chowdren-opengl.exe",
            marker: "CHOWDREN_SDL_DEBUG CHOWDREN_SDL_LOG SDL_CreateRenderer SDL_Direct3D9GetAdapterIndex",
            imports: ["opengl32.dll"]
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        XCTAssertFalse(WineManager().isChowdrenSDL2D3D9Engine(executable.path))
    }

    func testFrozenbyteStorm3DD3D9UsesNativePointScaling() throws {
        let executable = try makePE64(
            named: "custom-frozen-engine.exe",
            marker: "IStorm3D_Scene fb::animation::AnimationComponent "
                + "#define FB_LUA_EXPRESSION_STRING_COUNT",
            imports: ["d3d9.dll", "lua_x64.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        for package in ["shader1.fbq", "script1.fbq", "model1.fbq"] {
            try Data(package.utf8).write(to: directory.appendingPathComponent(package))
        }

        let manager = WineManager()

        XCTAssertTrue(manager.isFrozenbyteStorm3DD3D9Engine(executable.path))
        XCTAssertTrue(manager.usesLegacyD3D9NativeScaling(executable.path))
        XCTAssertFalse(manager.usesFullCompatibilityEngineForD3D9(executable.path))
    }

    func testFrozenbyteOptionsFolderComesFromPackagedManifest() throws {
        let executable = try makePE64(
            named: "custom-frozen-engine.exe",
            marker: "IStorm3D_Scene fb::animation::AnimationComponent",
            imports: ["d3d9.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        let config = directory.appendingPathComponent("config", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data("Options are stored in %APPDATA%\\CustomFrozen\\\r\n".utf8)
            .write(to: config.appendingPathComponent("readme_info.txt"))

        XCTAssertEqual(
            WineManager().frozenbyteOptionsFolderName(forExecutable: executable.path),
            "CustomFrozen"
        )
    }

    func testFrozenbyteFirstRunOptionsUseNativeBorderlessResolution() throws {
        let repaired = try XCTUnwrap(WineManager.repairedFrozenbyteDisplayOptions(
            existing: nil,
            screenSize: CGSize(width: 1512, height: 982)
        ))

        XCTAssertTrue(repaired.contains("\"ScreenWidth\", 1512"))
        XCTAssertTrue(repaired.contains("\"ScreenHeight\", 982"))
        XCTAssertTrue(repaired.contains("\"Windowed\", true"))
        XCTAssertTrue(repaired.contains("\"MaximizeWindow\", true"))
        XCTAssertTrue(repaired.contains("\"WindowTitleBar\", false"))
    }

    func testFrozenbyteMaximizedViewportRepairPreservesOtherPreferences() throws {
        let existing = """
        setOption(audioModule, "MasterVolume", 0.35)
        setOption(renderingModule, "ScreenWidth", 1280)
        setOption(renderingModule, "ScreenHeight", 720)
        setOption(renderingModule, "Windowed", true)
        setOption(renderingModule, "MaximizeWindow", true)
        setOption(renderingModule, "WindowTitleBar", false)
        """
        let repaired = try XCTUnwrap(WineManager.repairedFrozenbyteDisplayOptions(
            existing: existing,
            screenSize: CGSize(width: 1512, height: 982)
        ))

        XCTAssertTrue(repaired.contains("\"MasterVolume\", 0.35"))
        XCTAssertTrue(repaired.contains("\"ScreenWidth\", 1512"))
        XCTAssertTrue(repaired.contains("\"ScreenHeight\", 982"))
        XCTAssertTrue(repaired.contains("\"Windowed\", true"))
    }

    func testFrozenbyteUserWindowPreferenceIsNotOverridden() {
        let existing = """
        setOption(renderingModule, "ScreenWidth", 1280)
        setOption(renderingModule, "ScreenHeight", 720)
        setOption(renderingModule, "Windowed", false)
        setOption(renderingModule, "MaximizeWindow", false)
        """

        XCTAssertNil(WineManager.repairedFrozenbyteDisplayOptions(
            existing: existing,
            screenSize: CGSize(width: 1512, height: 982)
        ))
    }

    func testModernDirectD3D9DoesNotInheritLegacyNativeScaling() throws {
        let executable = try makePE32(
            named: "modern-d3d9.exe",
            imports: ["d3d9.dll"]
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        XCTAssertFalse(WineManager().usesLegacyD3D9NativeScaling(executable.path))
    }

    func testMoaiAKUSDLPE32UsesOnlyTheFullCompatibilityEngine() throws {
        let executable = try makePE32(
            named: "moai-game.exe",
            marker: "MOAIEnvironment MOAISim AKUSDL",
            imports: ["OPENGL32.dll"]
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let manager = WineManager()

        XCTAssertTrue(manager.isLegacyMoaiOpenGLGame(executable.path))
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .gcenx)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path), [])
    }

    func testRTsoftProtonSDKUsesItsDeterministicOpenGLRoute() throws {
        let executable = try makeRTsoftProtonExecutable()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let manager = WineManager()

        XCTAssertTrue(manager.isRTsoftProtonOpenGLEngine(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .opengl)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .gcenx)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path), [])
    }

    func testRTsoftProtonSDKRequiresEveryInternalMarker() throws {
        let marker = [
            #"d:\projects\proton\shared\audio\audiomanagerfmodstudio.cpp"#,
            "protoncurl-agent/1.0",
            "Error initializing GL extensions. Update your GL drivers!"
        ].joined(separator: " ")
        let executable = try makeRTsoftProtonExecutable(marker: marker)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        XCTAssertFalse(WineManager().isRTsoftProtonOpenGLEngine(executable.path))
    }

    func testRTsoftProtonSDKRequiresItsInterfaceAssets() throws {
        let executable = try makeRTsoftProtonExecutable(includeFont: false)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        XCTAssertFalse(WineManager().isRTsoftProtonOpenGLEngine(executable.path))
    }

    func testRTsoftProtonSDKRequiresEveryImportedRuntime() throws {
        let executable = try makeRTsoftProtonExecutable(imports: [
            "OPENGL32.dll", "fmod.dll", "zlibwapi.dll", "DINPUT8.dll"
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        XCTAssertFalse(WineManager().isRTsoftProtonOpenGLEngine(executable.path))
    }

    func testRTsoftProtonSDKAddsWindowModeOnce() {
        XCTAssertEqual(
            WineManager.rtsoftProtonLaunchArguments(["-language", "es"]),
            ["-language", "es", "-window"]
        )
        XCTAssertEqual(WineManager.rtsoftProtonLaunchArguments(["-WINDOW"]), ["-WINDOW"])
        XCTAssertEqual(WineManager.rtsoftProtonLaunchArguments(["-Windowed"]), ["-Windowed"])
    }

    func testLegacyOgreUsesTheRendererSelectedInPluginsConfig() throws {
        let executable = try makePE32(named: "ogre-game.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("OGRE".utf8).write(to: directory.appendingPathComponent("OgreMain.dll"))
        try writePE(
            to: directory.appendingPathComponent("RenderSystem_Direct3D9.dll"),
            is64Bit: false,
            imports: ["d3d9.dll", "d3dx9_39.dll"],
            marker: "OGRE D3D9 RenderSystem"
        )
        try writePE(
            to: directory.appendingPathComponent("RenderSystem_GL.dll"),
            is64Bit: false,
            imports: ["opengl32.dll"],
            marker: "OGRE GL RenderSystem"
        )
        try Data("Plugin=RenderSystem_Direct3D9\r\n#Plugin=RenderSystem_GL\r\n".utf8)
            .write(to: directory.appendingPathComponent("Plugins.cfg"))
        let manager = WineManager()

        XCTAssertTrue(manager.isLegacyOgreD3D9Game(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d9)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .gcenx)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path), [.gcenx])
    }

    func testLegacyOgreIgnoresACommentedD3D9Plugin() throws {
        let executable = try makePE32(named: "ogre-game.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("OGRE".utf8).write(to: directory.appendingPathComponent("OgreMain.dll"))
        try writePE(
            to: directory.appendingPathComponent("RenderSystem_Direct3D9.dll"),
            is64Bit: false,
            imports: ["d3d9.dll"],
            marker: "OGRE D3D9 RenderSystem"
        )
        try Data("#Plugin=RenderSystem_Direct3D9\nPlugin=RenderSystem_GL\n".utf8)
            .write(to: directory.appendingPathComponent("Plugins.cfg"))
        let manager = WineManager()

        XCTAssertFalse(manager.isLegacyOgreD3D9Game(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .other)
    }

    func testFullEngineExposesBundledMoltenVKWithoutForcingBackend() {
        let environment = WineManager.fullEngineEnvironment(
            prefix: "/tmp/vessel-bottle",
            engineRoot: "/tmp/vessel-wine-full"
        )

        XCTAssertEqual(environment["WINEPREFIX"], "/tmp/vessel-bottle")
        XCTAssertEqual(
            environment["DYLD_FALLBACK_LIBRARY_PATH"],
            "/tmp/vessel-wine-full/lib"
        )
        XCTAssertNil(environment["CX_GRAPHICS_BACKEND"])
    }

    func testModernMoltenVKOverlayKeepsTheFullEngineLibrariesIsolated() {
        let environment = WineManager.modernMoltenVKEnvironment(
            from: [
                "WINEPREFIX": "/tmp/vessel-bottle",
                "DYLD_FALLBACK_LIBRARY_PATH": "/tmp/vessel-wine-full/lib"
            ],
            libraryDirectory: "/tmp/moltenvk/1.4.1",
            useMetalArgumentBuffers: true
        )

        let libraries = "/tmp/moltenvk/1.4.1:/tmp/vessel-wine-full/lib"
        XCTAssertEqual(environment["WINEPREFIX"], "/tmp/vessel-bottle")
        XCTAssertEqual(environment["DYLD_FALLBACK_LIBRARY_PATH"], libraries)
        XCTAssertEqual(environment["DYLD_LIBRARY_PATH"], libraries)
        XCTAssertEqual(environment["VK_ICD_FILENAMES"], "/tmp/moltenvk/1.4.1/MoltenVK_icd.json")
        XCTAssertEqual(environment["VK_DRIVER_FILES"], "/tmp/moltenvk/1.4.1/MoltenVK_icd.json")
        XCTAssertEqual(environment["CX_ACTIVE_GRAPHICS_BACKEND"], "wined3d")
        XCTAssertEqual(environment["CX_LIBVULKAN"], "/tmp/moltenvk/1.4.1/libMoltenVK.dylib")
        XCTAssertEqual(environment["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS"], "1")
    }

    func testFullEngineCleanEnvironmentPreservesIsolatedGraphicsRuntimeOnly() {
        let environment = [
            "HOME": "/Users/example",
            "WINEPREFIX": "/tmp/vessel-bottle",
            "WINESERVER": "/tmp/wine-full/bin/wineserver",
            "DYLD_FALLBACK_LIBRARY_PATH": "/tmp/moltenvk:/tmp/wine-full/lib",
            "DYLD_LIBRARY_PATH": "/tmp/moltenvk",
            "VK_ICD_FILENAMES": "/tmp/moltenvk/MoltenVK_icd.json",
            "VK_DRIVER_FILES": "/tmp/moltenvk/MoltenVK_icd.json",
            "CX_ACTIVE_GRAPHICS_BACKEND": "wined3d",
            "CX_LIBVULKAN": "/tmp/moltenvk/libMoltenVK.dylib",
            "DXVK_LOG_LEVEL": "info",
            "DXVK_LOG_PATH": "/tmp/game",
            "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS": "1",
            "GST_PLUGIN_SYSTEM_PATH": "/tmp/gstreamer/plugins",
            "GST_PLUGIN_SCANNER": "/tmp/gstreamer/scanner",
            "GST_REGISTRY": "/tmp/bottle/gstreamer.bin",
            "GITHUB_PERSONAL_ACCESS_TOKEN": "placeholder-secret",
            "OPENAI_API_KEY": "placeholder-secret"
        ]

        let clean = WineManager.fullEngineCleanEnvironment(from: environment)

        XCTAssertEqual(clean["WINESERVER"], "/tmp/wine-full/bin/wineserver")
        XCTAssertEqual(clean["DYLD_LIBRARY_PATH"], "/tmp/moltenvk")
        XCTAssertEqual(clean["VK_ICD_FILENAMES"], "/tmp/moltenvk/MoltenVK_icd.json")
        XCTAssertEqual(clean["VK_DRIVER_FILES"], "/tmp/moltenvk/MoltenVK_icd.json")
        XCTAssertEqual(clean["CX_ACTIVE_GRAPHICS_BACKEND"], "wined3d")
        XCTAssertEqual(clean["CX_LIBVULKAN"], "/tmp/moltenvk/libMoltenVK.dylib")
        XCTAssertEqual(clean["DXVK_LOG_LEVEL"], "info")
        XCTAssertEqual(clean["DXVK_LOG_PATH"], "/tmp/game")
        XCTAssertEqual(clean["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS"], "1")
        XCTAssertEqual(clean["GST_PLUGIN_SYSTEM_PATH"], "/tmp/gstreamer/plugins")
        XCTAssertEqual(clean["GST_PLUGIN_SCANNER"], "/tmp/gstreamer/scanner")
        XCTAssertEqual(clean["GST_REGISTRY"], "/tmp/bottle/gstreamer.bin")
        XCTAssertNil(clean["GITHUB_PERSONAL_ACCESS_TOKEN"])
        XCTAssertNil(clean["OPENAI_API_KEY"])
    }

    func testFullEngineUsesIndependentLaunchAgentsForSteamAndGames() {
        XCTAssertEqual(
            WineManager.fullEngineLaunchAgentLabel(arguments: ["/tmp/prefix/drive_c/Steam/steam.exe"]),
            "com.swondev.vessel.steamlauncher"
        )
        XCTAssertEqual(
            WineManager.fullEngineLaunchAgentLabel(arguments: ["/tmp/games/online-engine.exe"]),
            "com.swondev.vessel.fullgamelauncher"
        )
    }

    func testManagedMediaEngineDetachesOnlyItsSteamClient() {
        let mediaWine = "/tmp/Vessel/Engines/wine-d3dmetal-media/bin/wine64"
        let fullWine = "/tmp/Vessel/Engines/wine-full/bin/wine64"

        XCTAssertTrue(WineManager.requiresDetachedSteamLaunchContext(
            winePath: mediaWine,
            arguments: ["/tmp/prefix/drive_c/Steam/steam.exe", "-silent"]
        ))
        XCTAssertFalse(WineManager.requiresDetachedSteamLaunchContext(
            winePath: mediaWine,
            arguments: ["reg", "add", #"HKCU\\Software\\Wine"#]
        ))
        XCTAssertTrue(WineManager.requiresDetachedSteamLaunchContext(
            winePath: fullWine,
            arguments: ["reg", "add", #"HKCU\\Software\\Wine"#]
        ))
    }

    func testManagedMediaControlCommandsMatchThePersistentSteamWineserver() {
        let environment = WineManager.wineControlEnvironment(
            prefix: "/tmp/vessel-bottle",
            wine: "/tmp/Vessel/Engines/wine-d3dmetal-media/bin/wine64"
        )

        XCTAssertEqual(environment["WINEMSYNC"], "1")
        XCTAssertEqual(environment["WINEESYNC"], "1")
        XCTAssertEqual(environment["WINEFSYNC"], "1")
    }

    func testSystemNotificationsRequireAnApplicationBundle() {
        XCTAssertTrue(NotificationService.canPostSystemNotifications(
            bundleURL: URL(fileURLWithPath: "/Applications/Vessel.app", isDirectory: true)
        ))
        XCTAssertFalse(NotificationService.canPostSystemNotifications(
            bundleURL: URL(fileURLWithPath: "/tmp/VesselPackageTests.xctest")
        ))
        XCTAssertFalse(NotificationService.canPostSystemNotifications(
            bundleURL: URL(fileURLWithPath: "/tmp/Vessel")
        ))
    }

    func testPE32SDL2OpenGLDisablesLegacyRetinaScaling() throws {
        let executable = try makePE32(
            named: "pixel-engine.exe",
            marker: "SDL2.dll",
            imports: ["opengl32.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("SDL2".utf8).write(to: directory.appendingPathComponent("SDL2.dll"))

        let manager = WineManager()

        XCTAssertTrue(manager.usesLegacySDL2OpenGLScaling(executable.path))
    }

    func testSDL2OpenGLScalingRuleDoesNotAffect64BitGames() throws {
        let executable = try makePE64(
            named: "modern-engine.exe",
            marker: "SDL2.dll",
            imports: ["opengl32.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("SDL2".utf8).write(to: directory.appendingPathComponent("SDL2.dll"))

        let manager = WineManager()

        XCTAssertFalse(manager.usesLegacySDL2OpenGLScaling(executable.path))
    }

    func testLiquidEngineD3D11RequiresOneXWindowCoordinates() throws {
        let executable = try makePE64(
            named: "proprietary-city-builder.exe",
            marker: #"d:\game\liquidengine\core\coreconfig.h"#
                + "\0"
                + #"d:\game\liquidengine\engine\liquidrenderer.cpp"#
                + "\0"
                + #"d:\game\liquidengine\engine\renderwindowmanager.cpp"#
                + "\0LiquidRenderer::Init",
            imports: ["d3d11.dll", "dxgi.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(GameDisplayStateRepair.requiresOneXWindowCoordinates(
            appId: nil,
            executable: executable.path
        ))
    }

    func testLiquidEngineScalingRuleRejectsWeakOrNonD3D11Markers() throws {
        let weakExecutable = try makePE64(
            named: "unrelated-d3d11.exe",
            marker: #"liquidengine\engine\liquidrenderer.cpp"#,
            imports: ["d3d11.dll"]
        )
        let weakDirectory = weakExecutable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: weakDirectory) }

        let nonD3D11Executable = try makePE64(
            named: "offline-tool.exe",
            marker: #"d:\tool\liquidengine\core\coreconfig.h"#
                + "\0"
                + #"d:\tool\liquidengine\engine\liquidrenderer.cpp"#
                + "\0"
                + #"d:\tool\liquidengine\engine\renderwindowmanager.cpp"#
                + "\0LiquidRenderer::Init",
            imports: ["opengl32.dll"]
        )
        let nonD3D11Directory = nonD3D11Executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: nonD3D11Directory) }

        XCTAssertFalse(GameDisplayStateRepair.requiresOneXWindowCoordinates(
            appId: nil,
            executable: weakExecutable.path
        ))
        XCTAssertFalse(GameDisplayStateRepair.requiresOneXWindowCoordinates(
            appId: nil,
            executable: nonD3D11Executable.path
        ))
    }

    func testContentDrivenSDL2FMODStudioEngineDisablesRetinaAt64Bit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-content-fmod-\(UUID().uuidString)", isDirectory: true)
        let executableDirectory = root.appendingPathComponent(
            "_windowsnosteam/win64",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executable = executableDirectory.appendingPathComponent("proprietary-engine.exe")
        try writePE(
            to: executable,
            is64Bit: true,
            imports: ["opengl32.dll", "SDL2.dll", "fmod64.dll", "fmodstudio64.dll"],
            marker: "SDL2 content engine"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("SDL2".utf8).write(to: executable.deletingLastPathComponent().appendingPathComponent("SDL2.dll"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("audio", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("shared/options", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: root.appendingPathComponent("audio/base.app.load_order.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("shared/options/options.value_definitions.json"))

        let manager = WineManager()

        XCTAssertTrue(manager.usesLegacySDL2OpenGLScaling(executable.path))
    }

    func testMKXPRGSS64BitUsesOpenGLAndNativeScaling() throws {
        let executable = try makePE64(
            named: "runtime.exe",
            marker: "MKXP\0RGSS_VERSION\0$RGSS_SCRIPTS"
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("SDL2".utf8).write(to: directory.appendingPathComponent("SDL2.dll"))
        try Data("Ruby 2.5 runtime".utf8)
            .write(to: directory.appendingPathComponent("x64-vcruntime140-ruby250.dll"))

        let manager = WineManager()

        XCTAssertTrue(manager.isMKXPRGSSGame(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .opengl)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .dxmt)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path), [.dxmt])
        XCTAssertTrue(manager.usesLegacySDL2OpenGLScaling(executable.path))
    }

    func testSteamShimMKXPBootstrapperIsDetectedAndKeepsOpenGLRouting() throws {
        let executable = try makePE64(
            named: "oneshot.exe",
            marker: "MKXP\0RGSS_VERSION\0$RGSS_SCRIPTS"
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("SDL2".utf8).write(to: directory.appendingPathComponent("SDL2.dll"))
        try Data("Ruby 2.5 runtime".utf8)
            .write(to: directory.appendingPathComponent("x64-vcruntime140-ruby250.dll"))
        let shim = directory.appendingPathComponent("steamshim.exe")
        try writePE(
            to: shim,
            is64Bit: true,
            imports: ["steam_api64.dll"],
            marker: "STEAMSHIM_READHANDLE\0STEAMSHIM_WRITEHANDLE\0SteamAPI_Init"
        )

        let manager = WineManager()

        XCTAssertTrue(manager.isSteamShimBootstrapper(shim.path))
        XCTAssertEqual(manager.steamShimBootstrapper(forPayload: executable.path), shim.path)
        XCTAssertEqual(manager.steamShimPayload(forBootstrapper: shim.path), executable.path)
        XCTAssertTrue(manager.isMKXPRGSSGame(shim.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: shim.path), .opengl)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: shim.path), .dxmt)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: shim.path), [.dxmt])
        XCTAssertTrue(manager.usesLegacySDL2OpenGLScaling(shim.path))
    }

    func testSteamShimNameAndImportWithoutIPCHandlesIsRejected() throws {
        let shim = try makePE64(
            named: "steamshim.exe",
            marker: "SteamAPI_Init",
            imports: ["steam_api64.dll"]
        )
        let directory = shim.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = WineManager()

        XCTAssertFalse(manager.isSteamShimBootstrapper(shim.path))
        XCTAssertNil(manager.steamShimPayload(forBootstrapper: shim.path))
    }

    func testNativeUCRTRejectsWineBuiltinAndGlobalOverrideIsDetectedSeparately() throws {
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vessel-UCRT-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        let ucrt = system32.appendingPathComponent("ucrtbase.dll")
        try Data("Wine builtin DLL".utf8).write(to: ucrt)
        let manager = WineManager()

        XCTAssertFalse(manager.hasNativeUCRT2019(in: prefix.path))
        XCTAssertFalse(manager.hasGlobalUCRTOverride(in: prefix.path))

        try Data("Microsoft Corporation Universal CRT".utf8).write(to: ucrt)

        try #"[Software\\Wine\\DllOverrides] "ucrtbase"="native,builtin""#
            .write(to: prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)

        XCTAssertTrue(manager.hasNativeUCRT2019(in: prefix.path))
        XCTAssertTrue(manager.hasGlobalUCRTOverride(in: prefix.path))
    }

    func testUnusedSiblingSDL2DoesNotTriggerLegacyScaling() throws {
        let executable = try makePE32(named: "unrelated-tool.exe", imports: ["opengl32.dll"])
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("SDL2".utf8).write(to: directory.appendingPathComponent("SDL2.dll"))

        let manager = WineManager()

        XCTAssertFalse(manager.usesLegacySDL2OpenGLScaling(executable.path))
    }

    func testNWJSUsesOnlyDXMTDespiteDynamicImportsOrStaleOverride() throws {
        let executable = try makePE64(named: "Melvor Idle.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePE(
            to: directory.appendingPathComponent("nw.dll"),
            is64Bit: true,
            imports: ["d3d9.dll"],
            marker: "ANGLE d3d11 dxgi"
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("package.nw"),
            withIntermediateDirectories: true
        )
        try Data(#"{"main":"index.html"}"#.utf8)
            .write(to: directory.appendingPathComponent("package.nw/package.json"))

        let manager = WineManager()
        var stale = EffectiveLaunchConfig()
        stale.graphicsOverride = .gcenx

        XCTAssertTrue(manager.isNWJSGame(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d11)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path, effective: stale), .dxmt)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path, effective: stale), [.dxmt])
        XCTAssertTrue(manager.needsExeAdjacentD3D9Support(executable.path))
    }

    func testNWJSAutomaticEngineArgumentsSurviveEveryLaunchRouteWithoutUserInput() throws {
        let executable = try makePE64(named: "CrossCode.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("ANGLE d3d11 dxgi".utf8).write(to: directory.appendingPathComponent("nw.dll"))
        try Data(#"{"main":"index.html"}"#.utf8)
            .write(to: directory.appendingPathComponent("package.json"))

        let manager = WineManager()
        var config = EffectiveLaunchConfig()
        config.launchArgs = ["--language=es"]

        let detected = manager.resolvedLaunchArguments(
            forExecutable: executable.path,
            requested: [],
            effective: config
        )
        XCTAssertEqual(detected, ["--language=es", "--in-process-gpu"])

        config.launchArgs.append("--IN-PROCESS-GPU")
        let alreadyPresent = manager.resolvedLaunchArguments(
            forExecutable: executable.path,
            requested: [],
            effective: config
        )
        XCTAssertEqual(
            alreadyPresent.filter { $0.caseInsensitiveCompare("--in-process-gpu") == .orderedSame }.count,
            1
        )

        try Data(#"{"main":"index.html","chromium-args":"--ignore-gpu-blocklist --in-process-gpu"}"#.utf8)
            .write(to: directory.appendingPathComponent("package.json"))
        let providedByRuntime = manager.resolvedLaunchArguments(
            forExecutable: executable.path,
            requested: [],
            effective: EffectiveLaunchConfig()
        )
        XCTAssertFalse(providedByRuntime.contains {
            $0.caseInsensitiveCompare("--in-process-gpu") == .orderedSame
        })
    }

    func testZomboidJavaEngineUsesOfficialNoSteamModeAutomatically() throws {
        let executable = try makePE64(named: "ProjectZomboid64.exe", imports: ["steam_api64.dll"])
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("jre/bin"),
            withIntermediateDirectories: true
        )
        try Data("java".utf8).write(to: directory.appendingPathComponent("jre/bin/java.exe"))
        let manifest: [String: Any] = [
            "mainClass": "zombie/gameStates/MainScreenState",
            "classpath": [".", "lwjgl.jar", "lwjgl-opengl.jar"],
            "vmArgs": ["-Djava.awt.headless=true", "-Dzomboid.steam=1"]
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("ProjectZomboid64.json"))

        let manager = WineManager()
        XCTAssertTrue(manager.isJavaGame(executable.path))
        XCTAssertTrue(manager.isZomboidJavaEngine(executable.path))
        XCTAssertNil(manager.processTrackingDirectory(forExecutable: executable.path))
        XCTAssertEqual(manager.automaticEngineArguments(forExecutable: executable.path), ["-nosteam"])
        XCTAssertEqual(
            manager.resolvedLaunchArguments(
                forExecutable: executable.path,
                requested: [],
                effective: EffectiveLaunchConfig()
            ),
            ["-nosteam"]
        )
    }

    func testUnrelatedJavaLWJGLGameDoesNotReceiveNoSteamArgument() throws {
        let executable = try makePE64(named: "JavaGame.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("jre/bin"),
            withIntermediateDirectories: true
        )
        try Data("java".utf8).write(to: directory.appendingPathComponent("jre/bin/java.exe"))
        let manifest: [String: Any] = [
            "mainClass": "com.example.Main",
            "classpath": ["lwjgl-opengl.jar"],
            "vmArgs": ["-Dzomboid.steam=1"]
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("JavaGame.json"))

        let manager = WineManager()
        XCTAssertTrue(manager.isJavaGame(executable.path))
        XCTAssertFalse(manager.isZomboidJavaEngine(executable.path))
        XCTAssertEqual(
            manager.processTrackingDirectory(forExecutable: executable.path),
            directory.path
        )
        XCTAssertFalse(manager.automaticEngineArguments(forExecutable: executable.path).contains("-nosteam"))
    }

    func testElevatedWineWindowCountsAsUsableForItsExactGameProcess() {
        let ownerPID: pid_t = 12_345
        let window: [String: Any] = [
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowLayer as String: 21,
            kCGWindowAlpha as String: 1.0,
            kCGWindowBounds as String: ["Width": 1512.0, "Height": 982.0]
        ]

        XCTAssertTrue(WineManager.isUsableGameWindow(window, ownedBy: [ownerPID]))
        XCTAssertFalse(WineManager.isUsableGameWindow(window, ownedBy: [54_321]))
    }

    func testInvisibleOrTinyWineSurfaceDoesNotCountAsUsable() {
        let ownerPID: pid_t = 12_345
        let invisible: [String: Any] = [
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowLayer as String: 21,
            kCGWindowAlpha as String: 0.0,
            kCGWindowBounds as String: ["Width": 1512.0, "Height": 982.0]
        ]
        let tiny: [String: Any] = [
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1.0,
            kCGWindowBounds as String: ["Width": 120.0, "Height": 80.0]
        ]

        XCTAssertFalse(WineManager.isUsableGameWindow(invisible, ownedBy: [ownerPID]))
        XCTAssertFalse(WineManager.isUsableGameWindow(tiny, ownedBy: [ownerPID]))
    }

    func testDiagnosticWineWindowsNeverCountAsRenderedGames() {
        let ownerPID: pid_t = 12_345
        func window(title: String, width: Double, height: Double) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: ownerPID,
                kCGWindowName as String: title,
                kCGWindowLayer as String: 0,
                kCGWindowAlpha as String: 1.0,
                kCGWindowBounds as String: ["Width": width, "Height": height]
            ]
        }

        XCTAssertFalse(WineManager.isUsableGameWindow(
            window(title: "DOOM Console", width: 271, height: 254),
            ownedBy: [ownerPID]
        ))
        XCTAssertFalse(WineManager.isUsableGameWindow(
            window(title: "DOOM Unhandled Exception", width: 640, height: 480),
            ownedBy: [ownerPID]
        ))
        XCTAssertTrue(WineManager.isUsableGameWindow(
            window(title: "Legitimate Retro Game", width: 320, height: 240),
            ownedBy: [ownerPID]
        ))
    }

    func testForcedDXMTIsReportedAsDXMTForDynamic64BitGame() throws {
        let executable = try makePE64(named: "dynamic.exe")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let manager = WineManager()
        var config = EffectiveLaunchConfig()
        config.graphicsOverride = .dxmt

        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .other)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path, effective: config), .dxmt)
    }

    func testSiblingEngineDLLRoutesMinimalLauncherToD3D11() throws {
        let executable = try makePE64(named: "Hades.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        // `makePE64` crea su propio directorio; copiamos la DLL al lado del launcher, como en Hades.
        let engineSource = try makePE64(
            named: "EngineWin64s.dll",
            marker: "D3DCOMPILER_47.dll",
            imports: ["dxgi.dll", "d3d11.dll"]
        )
        defer { try? FileManager.default.removeItem(at: engineSource.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: engineSource,
            to: directory.appendingPathComponent("EngineWin64s.dll")
        )

        let manager = WineManager()
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d11)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .dxmt)
    }

    func testCryEngineGameModuleRoutesMinimalLauncherToD3D12() throws {
        let executable = try makePE64(
            named: "CustomLauncher.exe",
            marker: """
            Unable to locate CryEngine root folder
            CryEngine root path is to long
            """
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moduleSource = try makePE64(
            named: "ProjectGame.dll",
            marker: "EngineModule_CryRenderer",
            imports: ["d3d12.dll", "dxgi.dll"]
        )
        defer { try? FileManager.default.removeItem(at: moduleSource.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: moduleSource,
            to: directory.appendingPathComponent("ProjectGame.dll")
        )

        let manager = WineManager()
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d12)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .gptk)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path), [.gptk])
    }

    func testDecimaDynamicD3D12ContractRoutesToGPTK() throws {
        let executable = try makePE64(
            named: "ProprietaryGame.exe",
            marker: """
            DecimaTexture
            DecimaLogo
            OnFinishDecimaLogo
            d3d12.dll
            D3D12SerializeRootSignature
            CreateDXGIFactory2
            ED3D12CommandListType
            """,
            imports: ["KERNEL32.dll", "USER32.dll", "D3DCOMPILER_47.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        for library in [
            "dxcompiler.dll",
            "d3dcompiler_47.dll",
            "oo2core_8_win64.dll",
            "bink2w64.dll"
        ] {
            try Data(library.utf8).write(to: directory.appendingPathComponent(library))
        }

        let manager = WineManager()
        XCTAssertTrue(manager.isDecimaD3D12Engine(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d12)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .gptk)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path), [.gptk])
    }

    func testIncompleteDecimaContractCannotChangeGraphicsRouting() throws {
        let executable = try makePE64(
            named: "IncompleteEngine.exe",
            marker: """
            DecimaTexture
            DecimaLogo
            OnFinishDecimaLogo
            d3d12.dll
            D3D12SerializeRootSignature
            CreateDXGIFactory2
            ED3D12CommandListType
            """,
            imports: ["KERNEL32.dll", "D3DCOMPILER_47.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Falta el runtime Oodle: los textos internos por sí solos no habilitan la ruta D3D12.
        for library in ["dxcompiler.dll", "d3dcompiler_47.dll", "bink2w64.dll"] {
            try Data(library.utf8).write(to: directory.appendingPathComponent(library))
        }

        let manager = WineManager()
        XCTAssertFalse(manager.isDecimaD3D12Engine(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .other)
    }

    func testGenericDynamicD3D12BundleIsNotMistakenForDecima() throws {
        let executable = try makePE64(
            named: "GenericDynamicGame.exe",
            marker: """
            d3d12.dll
            D3D12SerializeRootSignature
            CreateDXGIFactory2
            ED3D12CommandListType
            """,
            imports: ["KERNEL32.dll", "D3DCOMPILER_47.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        for library in [
            "dxcompiler.dll",
            "d3dcompiler_47.dll",
            "oo2core_7_win64.dll",
            "bink2w64.dll"
        ] {
            try Data(library.utf8).write(to: directory.appendingPathComponent(library))
        }

        let manager = WineManager()
        XCTAssertFalse(manager.isDecimaD3D12Engine(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .other)
    }

    func testUnverifiedCryEngineSiblingCannotChangeGraphicsRouting() throws {
        let executable = try makePE64(
            named: "CustomLauncher.exe",
            marker: """
            Unable to locate CryEngine root folder
            CryEngine root path is to long
            """
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moduleSource = try makePE64(
            named: "OptionalGame.dll",
            marker: "unrelated optional renderer",
            imports: ["d3d12.dll", "dxgi.dll"]
        )
        defer { try? FileManager.default.removeItem(at: moduleSource.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: moduleSource,
            to: directory.appendingPathComponent("OptionalGame.dll")
        )

        XCTAssertEqual(WineManager().detectGraphicsAPI(forExecutable: executable.path), .other)
    }

    func testDirectlyImportedSiblingModuleRoutesNorthlightPayloadToD3D12() throws {
        let executable = try makePE64(
            named: "NorthlightGame_DX12.exe",
            imports: ["d3d_rmdwin10_f.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moduleSource = try makePE64(
            named: "d3d_rmdwin10_f.dll",
            imports: ["dxgi.dll", "d3d12.dll"]
        )
        defer { try? FileManager.default.removeItem(at: moduleSource.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: moduleSource,
            to: directory.appendingPathComponent("d3d_rmdwin10_f.dll")
        )

        let manager = WineManager()
        XCTAssertEqual(
            PEImportScanner.importedLibrariesFromDirectSiblingDependencies(atPath: executable.path),
            ["dxgi.dll", "d3d12.dll"]
        )
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d12)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .gptk)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path), [.gptk])
    }

    func testUnlinkedOptionalSiblingCannotChangeGraphicsRouting() throws {
        let executable = try makePE64(named: "StableGame.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moduleSource = try makePE64(
            named: "optional_renderer.dll",
            imports: ["d3d12.dll"]
        )
        defer { try? FileManager.default.removeItem(at: moduleSource.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: moduleSource,
            to: directory.appendingPathComponent("optional_renderer.dll")
        )

        let manager = WineManager()
        XCTAssertTrue(
            PEImportScanner.importedLibrariesFromDirectSiblingDependencies(atPath: executable.path)
                .isEmpty
        )
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .other)
    }

    func testDirectD3D12ImportWinsOverLocalTranslationDependency() throws {
        let executable = try makePE64(
            named: "ExplicitD3D12Game.exe",
            imports: ["d3d12.dll", "dxgi.dll"]
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moduleSource = try makePE64(
            named: "dxgi.dll",
            imports: ["d3d11.dll"]
        )
        defer { try? FileManager.default.removeItem(at: moduleSource.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: moduleSource,
            to: directory.appendingPathComponent("dxgi.dll")
        )

        let manager = WineManager()
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .d3d12)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .gptk)
    }

    func testDeclaredX64PayloadRoutesMinimalLauncherToD3D12() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-declared-payload-\(UUID().uuidString)", isDirectory: true)
        let x64 = root.appendingPathComponent("x64", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: x64, withIntermediateDirectories: true)

        let launcher = root.appendingPathComponent("CustomLauncher.exe")
        try writePE(
            to: launcher,
            is64Bit: true,
            imports: ["KERNEL32.dll", "USER32.dll"],
            marker: "x64/"
        )
        try writePE(
            to: x64.appendingPathComponent("CustomGame.exe"),
            is64Bit: true,
            imports: ["d3d11.dll", "d3d12.dll", "dxgi.dll"],
            marker: ""
        )
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <startup><cmdline>CustomGame.exe</cmdline></startup>
        """.utf8).write(to: root.appendingPathComponent("CustomLauncher.xml"))

        let manager = WineManager()
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: launcher.path), .d3d12)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: launcher.path), .gptk)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: launcher.path), [.gptk])
        XCTAssertEqual(
            manager.trackedProcessFamilyImageNames(forExecutable: launcher.path),
            ["CustomLauncher.exe", "CustomGame.exe"]
        )

        let processPattern = manager.launchSupervisorProcessPattern(
            forExecutable: launcher.path
        )
        let regex = try NSRegularExpression(pattern: processPattern, options: [.caseInsensitive])
        for process in [
            #"/wine64-preloader Z:\Games\CustomLauncher.exe"#,
            #"/wine64-preloader Z:\Games\x64\CustomGame.exe"#
        ] {
            XCTAssertNotNil(regex.firstMatch(
                in: process,
                range: NSRange(process.startIndex..., in: process)
            ))
        }
        let watcher = "while /usr/bin/pgrep -i -f '\(processPattern)' >/dev/null; do sleep 5; done"
        XCTAssertNil(regex.firstMatch(
            in: watcher,
            range: NSRange(watcher.startIndex..., in: watcher)
        ))
    }

    func testDeclaredX64PayloadRejectsEscapingCommandLine() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-unsafe-payload-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("Game", isDirectory: true)
        let x64 = root.appendingPathComponent("x64", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: x64, withIntermediateDirectories: true)

        let launcher = root.appendingPathComponent("CustomLauncher.exe")
        try writePE(to: launcher, is64Bit: true, imports: [], marker: "x64/")
        try writePE(
            to: parent.appendingPathComponent("Outside.exe"),
            is64Bit: true,
            imports: ["d3d12.dll"],
            marker: ""
        )
        try Data("""
        <startup><cmdline>../Outside.exe</cmdline></startup>
        """.utf8).write(to: root.appendingPathComponent("CustomLauncher.xml"))

        XCTAssertEqual(WineManager().detectGraphicsAPI(forExecutable: launcher.path), .other)
    }

    func testDeclaredX64PayloadRequiresLauncherMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-unmarked-payload-\(UUID().uuidString)", isDirectory: true)
        let x64 = root.appendingPathComponent("x64", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: x64, withIntermediateDirectories: true)

        let launcher = root.appendingPathComponent("CustomLauncher.exe")
        try writePE(to: launcher, is64Bit: true, imports: [], marker: "")
        try writePE(
            to: x64.appendingPathComponent("CustomGame.exe"),
            is64Bit: true,
            imports: ["d3d12.dll"],
            marker: ""
        )
        try Data("""
        <startup><cmdline>CustomGame.exe</cmdline></startup>
        """.utf8).write(to: root.appendingPathComponent("CustomLauncher.xml"))

        XCTAssertEqual(WineManager().detectGraphicsAPI(forExecutable: launcher.path), .other)
    }

    func testDirectLauncherImportWinsOverDeclaredPayloadRenderer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-explicit-launcher-\(UUID().uuidString)", isDirectory: true)
        let x64 = root.appendingPathComponent("x64", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: x64, withIntermediateDirectories: true)

        let launcher = root.appendingPathComponent("CustomLauncher.exe")
        try writePE(to: launcher, is64Bit: true, imports: ["d3d11.dll"], marker: "x64/")
        try writePE(
            to: x64.appendingPathComponent("CustomGame.exe"),
            is64Bit: true,
            imports: ["d3d12.dll"],
            marker: ""
        )
        try Data("""
        <startup><cmdline>CustomGame.exe</cmdline></startup>
        """.utf8).write(to: root.appendingPathComponent("CustomLauncher.xml"))

        XCTAssertEqual(WineManager().detectGraphicsAPI(forExecutable: launcher.path), .d3d11)
    }

    func testD3D12ProcessArgumentsPreserveResolvedStoreContext() {
        XCTAssertEqual(
            WineManager.d3d12ProcessArguments(
                executable: "/Games/CustomLauncher.exe",
                engineArguments: ["-nohmd"],
                resolvedArguments: [
                    "-AUTH_LOGIN=unused",
                    "-AUTH_TYPE=exchangecode",
                    "-AUTH_PASSWORD=redacted",
                    "-EpicPortal"
                ]
            ),
            [
                "/Games/CustomLauncher.exe",
                "-nohmd",
                "-AUTH_LOGIN=unused",
                "-AUTH_TYPE=exchangecode",
                "-AUTH_PASSWORD=redacted",
                "-EpicPortal"
            ]
        )
    }

    func testSiblingEngineDLLConfirmsNativeVulkanRenderer() throws {
        let executable = try makePE64(named: "Hades.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engineSource = try makePE64(
            named: "EngineWin64sv.dll",
            marker: "Running Vulkan renderer/vulkan",
            imports: ["vulkan-1.dll"]
        )
        defer { try? FileManager.default.removeItem(at: engineSource.deletingLastPathComponent()) }
        try FileManager.default.copyItem(
            at: engineSource,
            to: directory.appendingPathComponent("EngineWin64sv.dll")
        )

        let manager = WineManager()
        XCTAssertTrue(manager.isNativeVulkanGame(executable.path))
    }

    func testNativeVulkanInvalidatesOnlyLearnedDirect3DOverride() throws {
        let executable = try makePE64(
            named: "NativeVulkan.exe",
            imports: ["vulkan-1.dll"]
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let manager = WineManager()
        var learned = EffectiveLaunchConfig()
        learned.graphicsOverride = .gptk
        learned.graphicsOverrideWasLearned = true

        XCTAssertEqual(
            manager.resolvedGraphicsLayer(forExecutable: executable.path, effective: learned),
            .gcenx
        )
        XCTAssertEqual(
            manager.fallbackLayers(forExecutable: executable.path, effective: learned),
            [.gcenx]
        )

        var manual = learned
        manual.graphicsOverrideWasLearned = false
        XCTAssertEqual(
            manager.resolvedGraphicsLayer(forExecutable: executable.path, effective: manual),
            .gptk
        )
        XCTAssertEqual(
            manager.fallbackLayers(forExecutable: executable.path, effective: manual),
            [.gptk]
        )
    }

    func testEOSCompatibilityEngineIsScopedToUnity() throws {
        let executable = try makePE64(named: "Hades.exe")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("EOSSDK-Win64-Shipping.dll"))

        let manager = WineManager()
        XCTAssertTrue(manager.usesEpicOnlineServices(executable.path))
        XCTAssertFalse(manager.needsLegacyUnityEOSWine(executable.path))

        try Data().write(to: directory.appendingPathComponent("UnityPlayer.dll"))
        XCTAssertTrue(manager.needsLegacyUnityEOSWine(executable.path))
    }

    func testLaunchAgentProcessPatternCannotMatchItsOwnWatcher() throws {
        let pattern = WineManager.selfExcludingProcessPattern("Hades")
        let regex = try NSRegularExpression(pattern: pattern)

        let realProcess = #"/wine64-preloader Z:\\Games\\Hades\\x64Vk\\Hades.exe"#
        let watcher = "while /usr/bin/pgrep -f '\(pattern)' >/dev/null; do sleep 5; done"

        XCTAssertNotNil(regex.firstMatch(
            in: realProcess,
            range: NSRange(realProcess.startIndex..., in: realProcess)
        ))
        XCTAssertNil(regex.firstMatch(
            in: watcher,
            range: NSRange(watcher.startIndex..., in: watcher)
        ))
    }

    func testLaunchAgentHelperPatternDoesNotMatchMacOSCrashReporter() throws {
        let pattern = WineManager.selfExcludingProcessPattern("CrashReport.exe")
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let gameHelper = #"C:\Games\Example\CrashReport.exe"#
        let macOSHelper = "/System/Library/CoreServices/CrashReporterSupportHelper server-init"

        XCTAssertNotNil(regex.firstMatch(
            in: gameHelper,
            range: NSRange(gameHelper.startIndex..., in: gameHelper)
        ))
        XCTAssertNil(regex.firstMatch(
            in: macOSHelper,
            range: NSRange(macOSHelper.startIndex..., in: macOSHelper)
        ))
    }

    func testWindowsProcessLookupIgnoresExecutableCapitalization() throws {
        XCTAssertEqual(
            WineManager.pgrepProcessLookupArguments(matching: "limbo.exe"),
            ["-i", "-f", "limbo\\.exe"]
        )

        let pattern = WineManager.steamProtectedProcessPattern("limbo.exe")
        let pgrep = WineManager.caseInsensitivePgrepShellCommand(matchingPattern: pattern)
        XCTAssertEqual(pgrep, "/usr/bin/pgrep -i -f '\(pattern)'")
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let realProcess = #"/wine-preloader C:\Games\LIMBO\Limbo.exe"#
        let watcher = "while \(pgrep) >/dev/null; do sleep 2; done"

        XCTAssertNotNil(regex.firstMatch(
            in: realProcess,
            range: NSRange(realProcess.startIndex..., in: realProcess)
        ))
        XCTAssertNil(regex.firstMatch(
            in: watcher,
            range: NSRange(watcher.startIndex..., in: watcher)
        ))
    }

    func testSteamProtectedProcessPatternTracksEitherOfficialArchitecture() throws {
        let pattern = WineManager.steamProtectedProcessPattern("Application-steam-x32.exe")
        let regex = try NSRegularExpression(pattern: pattern)
        let process32 = #"C:\Games\Application-steam-x32.exe"#
        let process64 = #"C:\Games\Application-steam-x64.exe"#
        let watcher = "while /usr/bin/pgrep -f '\(pattern)' >/dev/null; do sleep 2; done"

        for process in [process32, process64] {
            XCTAssertNotNil(regex.firstMatch(
                in: process,
                range: NSRange(process.startIndex..., in: process)
            ))
        }
        XCTAssertNil(regex.firstMatch(
            in: watcher,
            range: NSRange(watcher.startIndex..., in: watcher)
        ))
    }

    func testProcessFamilyImageNamesIncludesBothOfficialArchitectures() {
        XCTAssertEqual(
            WineManager.processFamilyImageNames("Application-steam-x32.exe"),
            ["Application-steam-x32.exe", "Application-steam-x64.exe"]
        )
        XCTAssertEqual(
            WineManager.processFamilyImageNames("Application-steam-x64.exe"),
            ["Application-steam-x64.exe", "Application-steam-x32.exe"]
        )
        XCTAssertEqual(
            WineManager.processFamilyImageNames("Banished.exe"),
            ["Banished.exe"]
        )
        XCTAssertEqual(
            WineManager.processFamilyImageNames("popcapgame2.exe"),
            ["popcapgame1.exe", "popcapgame2.exe", "popcapgame3.exe"]
        )
    }

    func testManagedRuntimeOnlyReenablesMSCoree() {
        XCTAssertEqual(
            WineManager.enablingManagedRuntime(
                in: "mscoree,mshtml=d;winegstreamer=d;d3d9,d3d8,ddraw=b"
            ),
            "mshtml=d;winegstreamer=d;d3d9,d3d8,ddraw=b"
        )
        XCTAssertEqual(
            WineManager.enablingManagedRuntime(in: "mscoree=d;winemenubuilder.exe=d"),
            "winemenubuilder.exe=d"
        )
    }

    func testD3D12MediaProfileIsDetectedFromPEImports() {
        XCTAssertTrue(WineManager.requiresManagedD3D12Media(
            importedLibraries: ["D3D12.dll", "MFPlat.DLL", "MFReadWrite.dll"],
            isD3D12: true
        ))
        XCTAssertTrue(WineManager.requiresManagedD3D12Media(
            importedLibraries: ["d3d12.dll", "mfplat.dll", "mf.dll"],
            isD3D12: true
        ))
    }

    func testMediaImportsDoNotRerouteD3D11OrGamesWithoutAReader() {
        XCTAssertFalse(WineManager.requiresManagedD3D12Media(
            importedLibraries: ["d3d11.dll", "mfplat.dll", "mfreadwrite.dll"],
            isD3D12: false
        ))
        XCTAssertFalse(WineManager.requiresManagedD3D12Media(
            importedLibraries: ["d3d12.dll", "mfplat.dll"],
            isD3D12: true
        ))
        XCTAssertFalse(WineManager.requiresManagedD3D12Media(
            importedLibraries: ["d3d12.dll", "mfreadwrite.dll"],
            isD3D12: true
        ))
    }

    func testMixedD3D11D3D12GPUProbeSelectsCoherentD3DMetalEngine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-gpu-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = root.appendingPathComponent("custom-dragon-engine.exe")
        try writePE(
            to: executable,
            is64Bit: true,
            imports: ["d3d12.dll"],
            marker: ""
        )
        let module = root.appendingPathComponent("gpu_info.dll")
        try writePE(
            to: module,
            is64Bit: true,
            imports: ["D3D11.dll", "D3D12.dll", "DXGI.dll"],
            marker: "",
            exports: ["GPUInfo_GetInterface"]
        )

        XCTAssertEqual(PEImportScanner.exportedSymbols(atPath: module.path), [
            "gpuinfo_getinterface"
        ])
        XCTAssertTrue(WineManager().requiresCoherentD3DMetalGPUProbeEngine(executable.path))
    }

    func testGPUProbeSignatureRejectsIncompleteOrUnrelatedModules() {
        XCTAssertFalse(WineManager.requiresCoherentD3DMetalGPUProbe(
            moduleName: "gpu_info.dll",
            importedLibraries: ["d3d11.dll", "dxgi.dll"],
            exportedSymbols: ["GPUInfo_GetInterface"],
            isD3D12: true
        ))
        XCTAssertFalse(WineManager.requiresCoherentD3DMetalGPUProbe(
            moduleName: "gpu_info.dll",
            importedLibraries: ["d3d11.dll", "d3d12.dll", "dxgi.dll"],
            exportedSymbols: ["GPUInfo_GetInterface"],
            isD3D12: false
        ))
        XCTAssertFalse(WineManager.requiresCoherentD3DMetalGPUProbe(
            moduleName: "telemetry.dll",
            importedLibraries: ["d3d11.dll", "d3d12.dll", "dxgi.dll"],
            exportedSymbols: ["GPUInfo_GetInterface"],
            isD3D12: true
        ))
    }

    func testEpicLaunchArgumentsAreRedacted() {
        let arguments = [
            "/Games/Melvor Idle.exe",
            "-AUTH_LOGIN=unused",
            "-AUTH_PASSWORD=super-secret-exchange-code",
            "-epicuserid=123456789",
            "--in-process-gpu"
        ]
        let redacted = WineManager.redactedArgumentsForLogging(arguments)
        let joined = redacted.joined(separator: " ")

        XCTAssertTrue(joined.contains("-AUTH_PASSWORD=<redactado>"))
        XCTAssertTrue(joined.contains("--in-process-gpu"))
        XCTAssertFalse(joined.contains("super-secret-exchange-code"))
        XCTAssertFalse(joined.contains("123456789"))
    }

    func testCrashpadReportsOnlyCountNewChromiumDumps() throws {
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-crashpad-test-\(UUID().uuidString)", isDirectory: true)
        let reports = prefix.appendingPathComponent(
            "drive_c/users/vessel/AppData/Local/Game/Crashpad/reports",
            isDirectory: true
        )
        let unrelated = prefix.appendingPathComponent("drive_c/users/vessel/Desktop", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        let old = reports.appendingPathComponent("old.dmp")
        let first = reports.appendingPathComponent("first.dmp")
        let second = reports.appendingPathComponent("second.dmp")
        try Data().write(to: old)
        try Data().write(to: first)
        try Data().write(to: second)
        try Data().write(to: unrelated.appendingPathComponent("not-crashpad.dmp"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: old.path
        )

        XCTAssertEqual(
            LaunchDiagnostics.crashpadReportCount(
                prefix: prefix.path,
                since: Date().addingTimeInterval(-10)
            ),
            2
        )
    }

    func testSteamRealAutoRepairRequiresDirectSteamEvidence() {
        let genericFailure = LaunchDiagnostics.Failure(
            category: .crash,
            title: "Fallo de motor",
            body: "El proceso se cerró"
        )
        let steamFailure = LaunchDiagnostics.Failure(
            category: .steam,
            title: "Falta Steam Input",
            body: "La interfaz no está disponible"
        )

        XCTAssertFalse(LaunchDiagnostics.shouldRetryWithRealSteam(nil))
        XCTAssertFalse(LaunchDiagnostics.shouldRetryWithRealSteam(genericFailure))
        XCTAssertTrue(LaunchDiagnostics.shouldRetryWithRealSteam(steamFailure))
    }

    func testSteamEULADetectionOnlyUsesLatestAppLaunch() {
        let waiting = """
        ExecCommandLine: "steam.exe -applaunch 6910"
        GameAction [AppID 6910] : LaunchApp waiting for user response to ShowEula ""
        """
        let acceptedAndRetried = waiting + """
        ExecCommandLine: "steam.exe -applaunch 6910"
        GameAction [AppID 6910] : LaunchApp changed task to SynchronizingCloud
        """

        XCTAssertTrue(LaunchDiagnostics.steamEULAPromptDetected(in: waiting))
        XCTAssertFalse(LaunchDiagnostics.steamEULAPromptDetected(in: acceptedAndRetried))
    }

    func testSteamAlertOnlyFocusesARealClientWindow() {
        XCTAssertTrue(NotificationService.isSteamClientWindow(
            ownerName: "wine",
            windowName: "Steam",
            width: 1280,
            height: 800
        ))
        // macOS puede ocultar el título sin permiso de captura; la ventana grande del único
        // proceso Wine sigue siendo identificable durante el EULA (el juego aún no existe).
        XCTAssertTrue(NotificationService.isSteamClientWindow(
            ownerName: "wine",
            windowName: "",
            width: 1280,
            height: 800
        ))
        XCTAssertTrue(NotificationService.isSteamClientWindow(
            ownerName: "wine",
            windowName: "Steam Client Bootstrapper",
            width: 1280,
            height: 800
        ))
        XCTAssertFalse(NotificationService.isSteamClientWindow(
            ownerName: "wine",
            windowName: "",
            width: 480,
            height: 320
        ))
        XCTAssertFalse(NotificationService.isSteamClientWindow(
            ownerName: "KunitsuGamiDemo",
            windowName: "Steamworks",
            width: 1280,
            height: 800
        ))
        XCTAssertFalse(NotificationService.isSteamClientWindow(
            ownerName: "wine",
            windowName: "Steam",
            width: 1,
            height: 1
        ))
    }

    func testSteamClientRolesRestartOnlyWhenTheTransitionRequiresIt() {
        XCTAssertFalse(WineManager.shouldRestartSteamClient(
            steamRunning: false,
            currentEngineID: nil,
            targetEngineID: "wine-osx64",
            role: .interactive,
            wrapperInstalled: false
        ))
        XCTAssertTrue(WineManager.shouldRestartSteamClient(
            steamRunning: true,
            currentEngineID: "wine-d3dmetal",
            targetEngineID: "wine-osx64",
            role: .interactive,
            wrapperInstalled: false
        ))
        XCTAssertTrue(WineManager.shouldRestartSteamClient(
            steamRunning: true,
            currentEngineID: "wine-osx64",
            targetEngineID: "wine-osx64",
            role: .interactive,
            wrapperInstalled: false
        ))
        XCTAssertFalse(WineManager.shouldRestartSteamClient(
            steamRunning: true,
            currentEngineID: "wine-osx64",
            targetEngineID: "wine-osx64",
            role: .interactive,
            wrapperInstalled: true
        ))
        // Un cliente visible conectado puede servir como DRM si el juego usa el mismo motor.
        XCTAssertFalse(WineManager.shouldRestartSteamClient(
            steamRunning: true,
            currentEngineID: "wine-unified",
            targetEngineID: "wine-unified",
            role: .backgroundDRM,
            wrapperInstalled: true
        ))
    }

    func testProtectedRuntimePreflightOwnsPrefixWithoutInterruptingDownloads() {
        XCTAssertEqual(WineManager.runtimePrefixPreparationDecision(
            exclusiveRequested: true,
            hasPendingRuntimes: true,
            hasActiveSteamDownloads: false
        ), .prepareExclusively)
        XCTAssertEqual(WineManager.runtimePrefixPreparationDecision(
            exclusiveRequested: true,
            hasPendingRuntimes: true,
            hasActiveSteamDownloads: true
        ), .deferForActiveDownloads)
        XCTAssertEqual(WineManager.runtimePrefixPreparationDecision(
            exclusiveRequested: true,
            hasPendingRuntimes: false,
            hasActiveSteamDownloads: false
        ), .continueWithoutCleanup)
        XCTAssertEqual(WineManager.runtimePrefixPreparationDecision(
            exclusiveRequested: false,
            hasPendingRuntimes: true,
            hasActiveSteamDownloads: false
        ), .continueWithoutCleanup)
    }

    func testSteamAppLaunchAcknowledgementRequiresNewExactAppIDEntry() {
        let baseline = Data("""
        ExecCommandLine: "steam.exe -applaunch 6910"
        GameAction [AppID 6910, ActionID 3] : LaunchApp changed task to Completed
        """.utf8)
        XCTAssertFalse(WineManager.steamAppLaunchAcknowledged(
            in: baseline,
            after: baseline,
            appId: "6910"
        ))

        let unrelated = baseline + Data("""
        ExecCommandLine: "steam.exe -applaunch 69100"
        """.utf8)
        XCTAssertFalse(WineManager.steamAppLaunchAcknowledged(
            in: unrelated,
            after: baseline,
            appId: "6910"
        ))

        let accepted = baseline + Data("""
        ExecCommandLine: "steam.exe -applaunch 6910"
        """.utf8)
        XCTAssertTrue(WineManager.steamAppLaunchAcknowledged(
            in: accepted,
            after: baseline,
            appId: "6910"
        ))

        let rotated = Data("""
        GameAction [AppID 6910, ActionID 4] : LaunchApp changed task to CreatingProcess
        """.utf8)
        XCTAssertTrue(WineManager.steamAppLaunchAcknowledged(
            in: rotated,
            after: baseline,
            appId: "6910"
        ))
    }

    func testStaleSteamEULALogDoesNotBlockANewLaunch() throws {
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-eula-log-\(UUID().uuidString)", isDirectory: true)
        let logs = prefix.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/logs",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: prefix) }
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let console = logs.appendingPathComponent("console_log.txt")
        try Data("""
        ExecCommandLine: "steam.exe -applaunch 6910"
        GameAction [AppID 6910] : LaunchApp waiting for user response to ShowEula ""
        """.utf8).write(to: console)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)],
            ofItemAtPath: console.path
        )

        XCTAssertFalse(LaunchDiagnostics.hasRecentSteamEULAPrompt(
            prefix: prefix.path,
            since: Date()
        ))
    }

    func testHeadlessProcessCannotBeLearnedAsSuccessfulEngine() {
        XCTAssertTrue(LaunchDiagnostics.startupFailed(
            crashed: false,
            failureDetected: false,
            isRunning: true,
            everRunning: true,
            requiresVisibleWindow: true,
            everVisible: false
        ))
        XCTAssertFalse(LaunchDiagnostics.startupFailed(
            crashed: false,
            failureDetected: false,
            isRunning: false,
            everRunning: true,
            requiresVisibleWindow: true,
            everVisible: true
        ))
    }

    func testDetachedGameFamilyMayAppearAfterSlowLauncherHandoff() async throws {
        let id = "slow-launcher-\(UUID().uuidString)"
        let tracker = GameLaunchTracker.shared
        let appearsAt = Date().addingTimeInterval(2.5)
        var stopped = false

        await tracker.track(
            id,
            processFamilyIsRunning: { !stopped && Date() >= appearsAt },
            stopProcessFamily: { stopped = true }
        ) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["0.1"]
            try process.run()
            return process
        }

        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(tracker.state(id), .running)

        tracker.stop(id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(tracker.state(id), .idle)
    }

    func testLegacyManualLaunchArgumentsNeverBecomeACompatibilityRequirement() {
        var user = GameConfig()
        user.launchArguments = "-windowed -novid"

        let effective = CompatService.shared.effectiveConfig(profile: nil, user: user)

        XCTAssertTrue(effective.launchArgs.isEmpty)
    }

    func testEffectiveConfigPreservesLearnedGraphicsProvenance() {
        var user = GameConfig()
        user.graphicsLayer = .gptk
        user.graphicsLayerOrigin = .learned

        let learned = CompatService.shared.effectiveConfig(profile: nil, user: user)
        XCTAssertEqual(learned.graphicsOverride, .gptk)
        XCTAssertTrue(learned.graphicsOverrideWasLearned)

        user.graphicsLayerOrigin = .user
        let manual = CompatService.shared.effectiveConfig(profile: nil, user: user)
        XCTAssertEqual(manual.graphicsOverride, .gptk)
        XCTAssertFalse(manual.graphicsOverrideWasLearned)
    }
}
