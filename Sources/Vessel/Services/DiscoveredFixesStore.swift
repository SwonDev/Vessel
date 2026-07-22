import Foundation

/// Registra los ARREGLOS que Vessel DESCUBRE automáticamente: cuando un juego que fallaba con su
/// motor por defecto ARRANCA tras el fallback de `LaunchDiagnostics` (o al activar el modo Steam
/// real), se guarda aquí {juego, capa ganadora, modo Steam real}.
///
/// Sirve para **cerrar el loop local→comunidad**: hoy `persistWinningLayer` guardaba el arreglo solo
/// en el `GameConfig` LOCAL del usuario, así que cada usuario redescubría el mismo fix. Ahora, además,
/// el usuario puede **compartir** estos arreglos como perfiles de compatibilidad para `SwonDev/Vessel_DB`
/// (Ajustes › Compatibilidad). Es la vía ABIERTA de escalar la cobertura hacia el volumen del
/// `cxcompatdb` propietario de CrossOver, sin curación manual: cada reparación real alimenta la BD.
///
/// Persiste en App Support (JSON), dedup por id de juego. Solo REGISTRA; compartir es acción del usuario.
@MainActor
@Observable
final class DiscoveredFixesStore {
    static let shared = DiscoveredFixesStore()

    struct Fix: Codable, Identifiable, Equatable {
        var id: String              // trackId / id del juego en su tienda
        var title: String
        var store: String           // "steam" | "gog" | "epic"
        var storeId: String?        // AppID de Steam / product id de GOG / appName de Epic
        var graphicsLayer: String   // capa ganadora (dxmt/gptk/gcenx)
        var useRealSteam: Bool
        var date: Date
        var shared: Bool = false    // el usuario ya lo compartió con la comunidad
    }

    private(set) var fixes: [Fix] = []
    private let fileURL = URL(fileURLWithPath: "\(VesselPaths.appSupport)/discovered-fixes.json")

    private init() { load() }

    /// Registra (o actualiza) el arreglo descubierto para un juego. Idempotente por `id`.
    func record(id: String, title: String, store: String, storeId: String?,
                graphicsLayer: String, useRealSteam: Bool) {
        if let idx = fixes.firstIndex(where: { $0.id == id }) {
            // Ya existía: actualiza la capa ganadora (conserva el flag `shared` si no cambió nada).
            let changed = fixes[idx].graphicsLayer != graphicsLayer || fixes[idx].useRealSteam != useRealSteam
            fixes[idx].graphicsLayer = graphicsLayer
            fixes[idx].useRealSteam = useRealSteam
            fixes[idx].date = Date()
            if changed { fixes[idx].shared = false }
        } else {
            fixes.insert(Fix(id: id, title: title, store: store, storeId: storeId,
                             graphicsLayer: graphicsLayer, useRealSteam: useRealSteam, date: Date()), at: 0)
            LogStore.shared.log("Vessel aprendió un arreglo para «\(title)» (\(graphicsLayer)\(useRealSteam ? ", Steam real" : "")). Compártelo en Ajustes › Compatibilidad para ayudar a la comunidad.", level: .info)
        }
        save()
    }

    /// Marca un arreglo como ya compartido (tras abrir el issue de la comunidad).
    func markShared(_ id: String) {
        guard let idx = fixes.firstIndex(where: { $0.id == id }) else { return }
        fixes[idx].shared = true
        save()
    }

    /// Elimina un arreglo que una firma estructural posterior ha demostrado inválido.
    /// No afecta a otros juegos ni a configuraciones elegidas explícitamente por el usuario.
    func remove(id: String) {
        guard let idx = fixes.firstIndex(where: { $0.id == id }) else { return }
        fixes.remove(at: idx)
        save()
    }

    /// Nº de arreglos aún sin compartir (para el badge de Ajustes).
    var unsharedCount: Int { fixes.filter { !$0.shared }.count }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let decoded = try? dec.decode([Fix].self, from: data) { fixes = decoded }
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(fixes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
