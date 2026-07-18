import CoreSpotlight
import UniformTypeIdentifiers

/// Indexa los juegos de la biblioteca en **Spotlight** (Core Spotlight), para que el usuario los
/// encuentre con ⌘Espacio del sistema y abra su ficha directamente en Vessel. La carátula sale de
/// la caché de disco de `CoverCache` cuando ya está descargada (sin red aquí).
///
/// Reindexar es barato pero no gratis (~1.750 ítems): se limita a 1 vez por hora por tienda salvo
/// que cambie el conjunto de ids (instalar/desinstalar sí reindexa al momento).
@MainActor
final class SpotlightIndexService {
    static let shared = SpotlightIndexService()
    private let index = CSSearchableIndex.default()
    private var indexedFingerprints: [String: Int] = [:]
    private var lastIndexAt: [String: Date] = [:]

    /// Huella del conjunto indexado por tienda: cambia si entra o sale un juego (no si cambian
    /// metadatos como el progreso, que no afectan a la búsqueda).
    private func fingerprint(_ games: [(id: String, title: String)]) -> Int {
        var h = Hasher()
        for g in games.sorted(by: { $0.id < $1.id }) { h.combine(g.id) }
        return h.finalize()
    }

    /// Reindexa la biblioteca de una tienda si procede (huella distinta o > 1 h desde la última).
    func reindex(store: StoreKind, games: [(id: String, title: String, cacheKey: String)]) {
        let storeID = store.rawValue
        let fp = fingerprint(games.map { ($0.id, $0.title) })
        let stale = lastIndexAt[storeID].map { Date().timeIntervalSince($0) > 3600 } ?? true
        guard indexedFingerprints[storeID] != fp || stale else { return }
        indexedFingerprints[storeID] = fp
        lastIndexAt[storeID] = Date()

        let items: [CSSearchableItem] = games.map { game in
            let attrs = CSSearchableItemAttributeSet(contentType: UTType.content)
            attrs.title = game.title
            attrs.contentDescription = "Juego de \(store.displayName) — abrir en Vessel"
            attrs.keywords = [game.title, store.displayName, "juego", "Vessel"]
            attrs.displayName = game.title
            // Carátula desde la caché de disco (solo si ya existe; nunca se descarga aquí).
            let coverFile = CoverCache.diskFile(game.cacheKey)
            if FileManager.default.fileExists(atPath: coverFile.path) {
                attrs.thumbnailURL = coverFile
            }
            return CSSearchableItem(
                uniqueIdentifier: "\(storeID):\(game.id)",
                domainIdentifier: storeID,
                attributeSet: attrs
            )
        }
        index.indexSearchableItems(items) { error in
            if let error {
                Task { @MainActor in
                    LogStore.shared.log("Spotlight: no se pudo indexar \(storeID): \(error.localizedDescription)", level: .warn)
                }
            }
        }
    }
}
