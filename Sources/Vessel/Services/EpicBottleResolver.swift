import Foundation

/// Resuelve el prefijo de Epic sin compartir registro, DLL ni runtimes entre instalaciones nuevas.
///
/// Las instalaciones antiguas continúan en su prefijo real si su ruta ya vive dentro de un bottle
/// existente. Así la migración no pierde partidas locales ni rompe juegos ya validados. Un juego
/// nuevo, en cambio, recibe un bottle propio identificado por el `appName` estable de Epic.
enum EpicBottleResolver {
    static let storeIdentifier = "epic"

    static func existingBottle(
        for game: LegendaryManager.EpicGame,
        in bottles: [Bottle]
    ) -> Bottle? {
        if let installPath = game.installPath, !installPath.isEmpty,
           let containing = bottles
            .filter({ contains(path: installPath, inPrefix: $0.prefixPath) })
            .max(by: { $0.prefixPath.count < $1.prefixPath.count }) {
            return containing
        }

        if let owned = bottles.first(where: {
            $0.managedStore?.caseInsensitiveCompare(storeIdentifier) == .orderedSame
                && $0.managedGameID == game.appName
        }) {
            return owned
        }

        // Compatibilidad con la arquitectura anterior: una instalación externa o cuyo path haya
        // desaparecido seguía usando el bottle común. Solo se conserva para juegos YA instalados;
        // nunca se asigna ese prefijo contaminable a una instalación nueva.
        if game.installed {
            return bottles.first { $0.name == "Epic Games" }
        }
        return nil
    }

    static func makeBottle(
        for game: LegendaryManager.EpicGame,
        winePath: String
    ) -> Bottle {
        Bottle(
            name: "Epic · \(game.title)",
            winePath: winePath,
            managedStore: storeIdentifier,
            managedGameID: game.appName
        )
    }

    static func contains(path: String, inPrefix prefix: String) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = URL(fileURLWithPath: prefix).standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
