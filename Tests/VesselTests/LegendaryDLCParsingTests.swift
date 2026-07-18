import Testing
@testable import Vessel

@Suite("Contenido adicional de Epic")
struct LegendaryDLCParsingTests {
    @Test("Relaciona DLC de catálogo, app instalable y estado local")
    func parsesOwnedDLCs() {
        let output = #"""
        {
          "game": {
            "owned_dlc": [
              {
                "id": "catalog-2",
                "title": "Expansión Beta",
                "app_name": "BetaDLC",
                "installable": [{"appId": "BetaDLC"}]
              },
              {
                "id": "catalog-1",
                "title": "Contenido Alfa",
                "app_name": null,
                "installable": [{"appId": "AlphaDLC"}]
              },
              {
                "id": "catalog-3",
                "title": "Licencia integrada",
                "app_name": null,
                "installable": null
              }
            ]
          },
          "install": {
            "installed_dlc": [
              {"app_name": "BetaDLC", "title": "Expansión Beta", "install_size": 1024}
            ]
          }
        }
        """#

        let dlcs = LegendaryManager.parseDLCInfo(output)
        #expect(dlcs.map(\.title) == ["Contenido Alfa", "Expansión Beta", "Licencia integrada"])
        #expect(dlcs.map(\.appName) == ["AlphaDLC", "BetaDLC", nil])
        #expect(dlcs.map(\.installed) == [false, true, false])
        #expect(dlcs.map(\.isInstallable) == [true, true, false])
    }

    @Test("Tolera juegos sin instalación ni DLC")
    func handlesEmptyInfo() {
        #expect(LegendaryManager.parseDLCInfo(#"{"game":{"owned_dlc":[]},"install":null}"#).isEmpty)
        #expect(LegendaryManager.parseDLCInfo("respuesta inválida").isEmpty)
    }
}
