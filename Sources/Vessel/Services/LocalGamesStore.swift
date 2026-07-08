import Foundation

/// Juegos **DRM‑free / sueltos** añadidos por el usuario: itch.io, GOG DRM‑free descargado a mano,
/// instaladores standalone, o cualquier `.exe` de Windows que NO venga de las tiendas Steam/Epic/GOG.
/// Vessel los ejecuta con el **motor gráfico óptimo + auto‑reparación + backup de partidas**, igual
/// que los de tienda — el usuario es dueño de sus juegos, sin DRM. Persiste en App Support (JSON).
@MainActor
@Observable
final class LocalGamesStore {
    static let shared = LocalGamesStore()

    struct Game: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var name: String
        /// Ruta al `.exe` de Windows a lanzar (en el disco del Mac; Wine lo ejecuta bajo el prefijo).
        var executablePath: String
        /// Carátula opcional (ruta a una imagen local que el usuario haya elegido).
        var coverPath: String?
        var addedAt: Date = Date()
        var lastPlayedAt: Date?
    }

    private(set) var games: [Game] = []
    private let fileURL = URL(fileURLWithPath: "\(VesselPaths.appSupport)/local-games.json")

    private init() { load() }

    /// Añade un juego local (dedup por ruta del ejecutable). Idempotente.
    @discardableResult
    func add(name: String, executablePath: String, coverPath: String? = nil) -> Game? {
        guard !executablePath.isEmpty,
              !games.contains(where: { $0.executablePath == executablePath }) else { return nil }
        let g = Game(name: name.isEmpty ? Self.defaultName(for: executablePath) : name,
                     executablePath: executablePath, coverPath: coverPath)
        games.insert(g, at: 0)
        save()
        return g
    }

    func remove(_ id: UUID) { games.removeAll { $0.id == id }; save() }

    func markPlayed(_ id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].lastPlayedAt = Date(); save()
    }

    /// Nombre por defecto = nombre del .exe sin extensión, capitalizado.
    static func defaultName(for exe: String) -> String {
        ((exe as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private func load() {
        guard let d = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let g = try? dec.decode([Game].self, from: d) { games = g }
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(games) { try? d.write(to: fileURL, options: .atomic) }
    }
}
