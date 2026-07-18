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
