import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Tipo privado de Vessel: evita interpretar como juego cualquier texto arrastrado desde otra app.
    static let vesselLibraryGame = UTType(exportedAs: "com.swondev.vessel.library-game")
}

/// Referencia mínima y segura para arrastrar un juego dentro de la biblioteca.
///
/// Solo contiene identificadores locales; no serializa rutas, credenciales ni metadatos personales.
struct LibraryGameDragPayload: Codable, Hashable, Sendable, Transferable {
    let storeID: String
    let gameID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .vesselLibraryGame)
    }
}
