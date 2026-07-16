import Foundation

/// **GOG en el hub DRM‑free.** Todo el catálogo de GOG es DRM‑free *por política de la tienda*:
/// no hay activación, ni servidor de licencias, ni cliente obligatorio. El juego instalado es tuyo
/// y arranca solo. Por eso los juegos de GOG entran directos en la biblioteca DRM‑free, sin
/// análisis ni "generación" previa — a diferencia de Steam, donde hay que comprobar SteamStub
/// juego a juego porque la tienda NO garantiza nada.
///
/// Lo que aporta tenerlos aquí es lo que no da la sección de GOG: **exportarlos** (copiarlos a un
/// USB como carpeta portable o empaquetarlos como `.app` de Mac autónomo) y **verificar su
/// integridad** con un manifiesto de preservación.
///
/// Nota honesta: un puñado de juegos de GOG (los que usan servicios de Galaxy para multijugador o
/// logros) siguen funcionando en solitario, pero pierden esas funciones sin el cliente. `DRMAnalyzer`
/// los detecta como `gogGalaxy` — que es **API social, no DRM**, y por eso no bloquea nada.
@MainActor
enum GOGDRMFreeImporter {
    /// Bottle dedicado de GOG (mismo nombre que usa `GogStoreView`).
    static let bottleName = "GOG"

    /// Carpeta de instalación de un juego de GOG. **Misma convención que `GogStoreView.installDir`**:
    /// si una cambia, la otra deja de encontrar los juegos.
    static func installDir(_ bottle: Bottle, _ appId: String) -> String {
        "\(bottle.prefixPath)/drive_c/Games/GOG/\(appId)"
    }

    /// Importa al hub los juegos de GOG **ya instalados** (los que no lo están no pintan nada aquí:
    /// se instalan desde la sección de GOG). Idempotente — se puede llamar en cada refresco.
    /// Devuelve cuántos juegos de GOG quedan en el hub.
    @discardableResult
    static func sync(gogdl: GogdlManager) -> Int {
        guard let bottle = BottleStore.shared.bottles.first(where: { $0.name == bottleName }),
              let library = LibraryCache.load("gog", as: [GogdlManager.GogGame].self) else {
            return LocalGamesStore.shared.games.filter { $0.source == .gog }.count
        }
        var imported = 0
        for g in library {
            let dir = installDir(bottle, g.appId)
            // `gameRoot` resuelve la subcarpeta REAL donde gogdl dejó los archivos; `primaryExecutable`
            // sale del `goggame-<id>.info` que instala el propio GOG (la fuente oficial del juego).
            guard let root = gogdl.gameRoot(appId: g.appId, installDir: dir),
                  let exe = gogdl.primaryExecutable(appId: g.appId, installDir: dir),
                  FileManager.default.fileExists(atPath: exe) else { continue }
            LocalGamesStore.shared.upsertInstalledCopy(
                source: .gog, sourceId: g.appId, name: g.title,
                executablePath: exe, installPath: root, coverURL: g.coverURL)
            imported += 1
        }
        // Lo que se desinstaló desde la sección de GOG deja de listarse aquí (no se borra nada).
        LocalGamesStore.shared.pruneMissing(source: .gog)
        return imported
    }
}
