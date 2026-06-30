import Foundation

/// Persiste el **timestamp de última sincronización** de cloud saves de GOG, por juego y
/// ubicación. gogdl usa este `--ts` para decidir qué lado (local/nube) es más reciente y NO
/// pisar partidas. Sin persistirlo entre sesiones se arriesgaría a sobrescribir guardados.
///
/// Formato (igual que Heroic): clave `"{appId}.{locationName}"` → epoch en segundos (string).
/// La primera vez (sin sincronización previa) se usa `"0"`.
@MainActor
final class GogSaveSyncStore {
    static let shared = GogSaveSyncStore()

    private var timestamps: [String: String] = [:]
    private var path: String { "\(VesselPaths.appSupport)/gogSaveTimestamps.json" }

    private init() { load() }

    private func key(appId: String, location: String) -> String { "\(appId).\(location)" }

    /// Timestamp guardado para (juego, ubicación). `"0"` si nunca se sincronizó.
    func timestamp(appId: String, location: String) -> String {
        timestamps[key(appId: appId, location: location)] ?? "0"
    }

    /// Guarda el nuevo timestamp que devuelve gogdl por stdout tras un sync correcto.
    func setTimestamp(_ ts: String, appId: String, location: String) {
        let t = ts.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        timestamps[key(appId: appId, location: location)] = t
        save()
    }

    /// Olvida los timestamps de un juego (al desinstalar).
    func clear(appId: String) {
        let prefix = "\(appId)."
        timestamps = timestamps.filter { !$0.key.hasPrefix(prefix) }
        save()
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        timestamps = obj
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(timestamps) else { return }
        try? FileManager.default.createDirectory(atPath: VesselPaths.appSupport, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
