import Foundation

/// Vídeo promocional público de una tienda. Vessel solo conserva la URL HTTPS y una miniatura;
/// no descarga ni persiste el vídeo completo.
struct StoreGameMovie: Hashable, Codable, Sendable {
    let id: String
    let name: String?
    let thumbnailURL: URL?
    let videoURL: URL
}

/// Metadatos públicos compartidos por la ficha completa y la previsualización al pasar el ratón.
/// Mantenerlos fuera de la vista evita repetir parsers o peticiones entre ambas superficies.
struct StoreGameMetadata: Codable, Sendable {
    var description: String?
    var developers: [String] = []
    var publishers: [String] = []
    var releaseDate: String?
    var genres: [String] = []
    var metacritic: Int?
    var screenshots: [URL] = []
    /// Versión a resolución completa de cada captura. Paralela a `screenshots`.
    var screenshotsFull: [URL] = []
    var movies: [StoreGameMovie] = []
    var categories: [String] = []
    var reviewCount: Int?
    var achievementsTotal: Int?
    var achievementIcons: [URL] = []
    var dlcIds: [Int] = []
}
