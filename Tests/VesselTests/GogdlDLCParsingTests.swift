import Foundation
import Testing
@testable import Vessel

@Suite("Contenido adicional de GOG")
struct GogdlDLCParsingTests {
    @Test("Lee DLC poseídos y distingue los ya instalados")
    func parsesOwnedAndInstalledDLCs() {
        let output = #"""
        [GOGDL] INFO: Calculando tamaño
        {"buildId":"42","dlcs":[{"title":"Banda sonora","id":"1001"},{"title":"Expansión","id":1002}]}
        """#

        let dlcs = GogdlManager.parseOwnedDLCs(infoOutput: output, installedIDs: ["1002"])
        #expect(dlcs.map(\.id) == ["1001", "1002"])
        #expect(dlcs.map(\.installed) == [false, true])
    }

    @Test("Admite manifiestos de gogdl con objetos y con identificadores simples")
    func parsesInstalledManifest() {
        let data = Data(#"{"HGLdlcs":[{"title":"Uno","id":"10"},{"id":20},"30"]}"#.utf8)

        #expect(GogdlManager.installedDLCIDs(manifestData: data) == ["10", "20", "30"])
    }
}
