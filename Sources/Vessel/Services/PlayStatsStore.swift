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
    /// Registro acotado de sesiones (fecha + duración) para métricas tipo "últimas 2 semanas"
    /// (estilo Steam). Se poda a 30 días y 100 entradas para no crecer sin límite.
    var sessionLog: [SessionRecord] = []

    var playtimeMinutes: Int { totalSeconds / 60 }
}

struct SessionRecord: Codable, Hashable {
    var at: Date
    var seconds: Int
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
        s.sessionLog.append(SessionRecord(at: Date(), seconds: seconds))
        // Poda: solo el último mes y como mucho 100 entradas (suficiente para "2 semanas").
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        s.sessionLog = s.sessionLog.filter { $0.at >= cutoff }.suffix(100)
        stats[key] = s
        save()
    }

    /// Minutos jugados en los últimos `days` días (para el "últimas 2 semanas" de la ficha).
    /// `nil` si no hay sesiones registradas en la ventana (la UI lo muestra como "—").
    func minutesPlayed(inLastDays days: Int, key: String) -> Int? {
        guard let s = stats[key] else { return nil }
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let secs = s.sessionLog.filter { $0.at >= cutoff }.reduce(0) { $0 + $1.seconds }
        return secs > 0 ? secs / 60 : nil
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
