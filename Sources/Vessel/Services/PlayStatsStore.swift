import Foundation
import Observation

/// Estadística de juego (tiempo jugado + última sesión) por título, común a Steam/Epic/GOG.
/// Es el equivalente **cross-tienda** de lo que la biblioteca ya muestra
/// (`StoreGame.lastPlayed` / `StoreGame.playtimeMinutes`, `RecentlyPlayedCard`, `GameDetailView`).
///
/// Distinto de `GameInstall` (registro de instalación de Steam, keado por UUID): aquí solo viven
/// las estadísticas de juego, keadas por **`"<tienda>:<id>"`** — el MISMO id que usa la UI
/// (`StoreGame.id`) y el `GameLaunchTracker`, para que escritura y lectura casen en las 3 tiendas.
struct PlayStat: Codable, Hashable {
    var totalSeconds: Int = 0
    var lastPlayedAt: Date? = nil
    var sessions: Int = 0

    var playtimeMinutes: Int { totalSeconds / 60 }
}

@MainActor
@Observable
final class PlayStatsStore {
    static let shared = PlayStatsStore()

    private(set) var stats: [String: PlayStat] = [:]
    private let storeURL: URL

    init() {
        storeURL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/Vessel/playstats.json")
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        load()
    }

    func stat(_ key: String) -> PlayStat? { stats[key] }
    func lastPlayed(_ key: String) -> Date? { stats[key]?.lastPlayedAt }

    /// Minutos jugados, o `nil` si nunca se ha jugado (para que la UI muestre "—" y no "0 min").
    func playtimeMinutes(_ key: String) -> Int? {
        guard let s = stats[key], s.totalSeconds > 0 else { return nil }
        return s.playtimeMinutes
    }

    /// Marca "jugado ahora" al LANZAR, para que el orden "Recientes" y el carrusel
    /// "Jugados recientemente" se actualicen al instante (sin esperar a cerrar el juego).
    func markPlayed(_ key: String) {
        guard !key.isEmpty else { return }
        var s = stats[key] ?? PlayStat()
        s.lastPlayedAt = Date()
        stats[key] = s
        save()
    }

    /// Suma la duración de una sesión al CERRAR el juego. Ignora sesiones absurdas (< 5 s,
    /// típicas de un arranque fallido) para no inflar el tiempo jugado.
    func addSession(_ key: String, seconds: Int) {
        guard !key.isEmpty, seconds >= 5 else { return }
        var s = stats[key] ?? PlayStat()
        s.totalSeconds += seconds
        s.sessions += 1
        s.lastPlayedAt = Date()
        stats[key] = s
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let decoded = try? dec.decode([String: PlayStat].self, from: data) { stats = decoded }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(stats) { try? data.write(to: storeURL, options: .atomic) }
    }
}
