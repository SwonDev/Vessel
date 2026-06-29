import Foundation

/// Caché en disco genérica para las bibliotecas de las tiendas. Permite **carga
/// instantánea** (mostrar lo cacheado al abrir) y **refresco en segundo plano**
/// (actualizar cuando la CLI/red responde), el patrón que usa Heroic. Guarda arrays
/// `Codable` como JSON en `…/Application Support/Vessel/Cache/library-<clave>.json`.
enum LibraryCache {
    private static func fileURL(_ key: String) -> URL {
        URL(fileURLWithPath: "\(VesselPaths.cacheDirectory)/library-\(key).json")
    }

    /// Devuelve los elementos cacheados, o `nil` si no hay caché válida.
    static func load<T: Codable>(_ key: String, as type: [T].Type) -> [T]? {
        guard let data = try? Data(contentsOf: fileURL(key)),
              let items = try? JSONDecoder().decode([T].self, from: data),
              !items.isEmpty else { return nil }
        return items
    }

    /// Persiste los elementos (escritura atómica). Crea el directorio si falta.
    static func save<T: Codable>(_ key: String, _ items: [T]) {
        guard !items.isEmpty, let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(
            atPath: VesselPaths.cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(key), options: .atomic)
    }
}
