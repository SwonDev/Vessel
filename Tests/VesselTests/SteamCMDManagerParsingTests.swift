import Testing
@testable import Vessel

@Suite("Detección de actualizaciones de Steam")
struct SteamCMDManagerParsingTests {
    @Test("Extrae la build pública de cada bloque app_info_print")
    func parsesPublicBuildIDs() {
        let output = #"""
        AppID : 620, change number : 123/0, last change : Thu Jul 16 17:02:56 2026
        "depots"
        {
            "branches"
            {
                "public"
                {
                    "buildid"        "23973718"
                }
                "preview"
                {
                    "buildid"        "100"
                }
            }
        }
        AppID : 400, change number : 456/0, last change : Thu Jul 16 17:02:56 2026
        "depots"
        {
            "branches"
            {
                "public"
                {
                    "buildid"        "987654"
                }
            }
        }
        """#

        #expect(SteamCMDManager.publicBuildIDs(in: output) == [
            "620": "23973718",
            "400": "987654"
        ])
    }

    @Test("Ignora aplicaciones sin rama pública utilizable")
    func ignoresMalformedBlocks() {
        let output = #"""
        AppID : 10, change number : 1/0
        "branches" { "beta" { "buildid" "123" } }
        AppID : 20, change number : 2/0
        "branches" { "public" { "buildid" "456" } }
        """#

        #expect(SteamCMDManager.publicBuildIDs(in: output) == ["20": "456"])
    }

    @Test("Prioriza el manifiesto que SteamCMD actualiza dentro del juego")
    func prefersSteamCMDManagedManifest() {
        let installPath = "/Bottle/Steam/steamapps/common/Aethermancer"
        let steamDirectory = "/Bottle/Steam"
        let managed = "\(installPath)/steamapps/appmanifest_2288470.acf"
        let client = "\(steamDirectory)/steamapps/appmanifest_2288470.acf"
        let manifests = [
            managed: manifest(buildID: "24207221", stateFlags: 4),
            client: manifest(buildID: "23869583", stateFlags: 6)
        ]

        let installed = SteamCMDManager.installedBuildID(
            appID: "2288470",
            installPath: installPath,
            steamDirectory: steamDirectory,
            contentsAtPath: { manifests[$0] }
        )

        #expect(installed == "24207221")
    }

    @Test("Descarta el staging parcial y cae al manifiesto completo de Steam")
    func fallsBackFromIncompleteSteamCMDManifest() {
        let installPath = "/Bottle/Steam/steamapps/common/Game"
        let steamDirectory = "/Bottle/Steam"
        let paths = SteamCMDManager.appManifestPaths(
            appID: "10",
            installPath: installPath,
            steamDirectory: steamDirectory
        )
        let manifests = [
            paths[0]: manifest(buildID: "200", stateFlags: 2),
            paths[1]: manifest(buildID: "100", stateFlags: 4)
        ]

        let installed = SteamCMDManager.installedBuildID(
            appID: "10",
            installPath: installPath,
            steamDirectory: steamDirectory,
            contentsAtPath: { manifests[$0] }
        )

        #expect(installed == "100")
    }

    @Test("Acepta una actualización que SteamCMD confirma ya al día")
    func acceptsAlreadyUpToDateAsSuccess() {
        let output = #"Success! App '207350' already up to date."#

        #expect(SteamCMDManager.appUpdateSucceeded(in: output, exitCode: 0))
    }

    @Test("Acepta una instalación completada")
    func acceptsFullyInstalledAsSuccess() {
        let output = #"Success! App '207530' fully installed."#

        #expect(SteamCMDManager.appUpdateSucceeded(in: output, exitCode: 0))
    }

    @Test("No confunde el código cero de SteamCMD con una operación correcta")
    func rejectsFalseZeroExitSuccess() {
        let output = "ERROR! Failed to install app '207350' (No subscription)"

        #expect(!SteamCMDManager.appUpdateSucceeded(in: output, exitCode: 0))
        #expect(!SteamCMDManager.appUpdateSucceeded(
            in: #"Success! App '207350' already up to date."#,
            exitCode: 1
        ))
    }

    @Test("Detecta solo la misma instalación SteamCMD ya activa")
    func matchesOnlyTheExactLiveInstall() {
        let installDir = "/Bottle/Steam/steamapps/common/DOOM"
        let matching = """
        /Cache/steamcmd/steamcmd +@sSteamCmdForcePlatformType windows \
        +force_install_dir \(installDir) +login testuser +app_update 379720 validate +quit
        """

        #expect(SteamCMDManager.hasLiveInstallProcess(
            appId: "379720",
            installDir: installDir,
            processCommands: matching
        ))
        #expect(!SteamCMDManager.hasLiveInstallProcess(
            appId: "37972",
            installDir: installDir,
            processCommands: matching
        ))
        #expect(!SteamCMDManager.hasLiveInstallProcess(
            appId: "379720",
            installDir: "/Bottle/Steam/steamapps/common/Another Game",
            processCommands: matching
        ))
        #expect(!SteamCMDManager.hasLiveInstallProcess(
            appId: "379720",
            installDir: installDir,
            processCommands: "/Applications/Steam.app/Contents/MacOS/steam_osx -silent"
        ))
    }

    private func manifest(buildID: String, stateFlags: Int) -> String {
        #"""
        "AppState"
        {
            "appid"        "2288470"
            "StateFlags"   "\#(stateFlags)"
            "buildid"      "\#(buildID)"
        }
        """#
    }
}
