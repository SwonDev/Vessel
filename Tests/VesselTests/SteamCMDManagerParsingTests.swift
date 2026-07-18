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
}
