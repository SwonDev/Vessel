import Foundation
import XCTest
@testable import Vessel

/// Verifica el parseo del manifiesto de ludusavi (la pieza que decide DÓNDE están las partidas).
/// Crítico hacerlo bien: de aquí salen las rutas que se copian/restauran. Sin red ni Wine.
final class SaveBackupManagerTests: XCTestCase {

    /// Muestra del formato real del manifiesto: por juego, `steam.id` + `files` con `tags`.
    private let sampleYAML = """
    Hollow Knight:
      steam:
        id: 367520
      files:
        "<base>/hollow_knight_Data/Config.ini":
          tags:
            - config
        "<home>/AppData/LocalLow/Team Cherry/Hollow Knight/*.bak":
          tags:
            - save
    Some Config Only Game:
      steam:
        id: 999999
      files:
        "<base>/settings.ini":
          tags:
            - config
    AK-xolotl Together:
      files:
        "<winAppData>/AK-xolotl/saves/*":
          tags:
            - save
    """

    func testBuildIndexExtractsSaveTemplatesBySteamIdAndName() throws {
        let idx = try SaveBackupManager.buildIndex(fromYAML: Data(sampleYAML.utf8))

        // Hollow Knight: indexado por su steam appid, SOLO con la plantilla `save` (no la `config`).
        let hk = idx.bySteamId["367520"]
        XCTAssertEqual(hk?.count, 1, "Solo la ruta con tag save")
        XCTAssertEqual(hk?.first, "<home>/AppData/LocalLow/Team Cherry/Hollow Knight/*.bak")

        // Un juego con SOLO config no se indexa (no hay nada que respaldar).
        XCTAssertNil(idx.bySteamId["999999"])

        // Juego sin steam id → indexado por nombre normalizado.
        XCTAssertNotNil(idx.byName["akxolotltogether"])
        XCTAssertEqual(idx.byName["akxolotltogether"]?.first, "<winAppData>/AK-xolotl/saves/*")
    }

    func testBuildIndexHandlesEmptyManifestGracefully() throws {
        let idx = try SaveBackupManager.buildIndex(fromYAML: Data("{}".utf8))
        XCTAssertTrue(idx.bySteamId.isEmpty)
        XCTAssertTrue(idx.byName.isEmpty)
    }
}
