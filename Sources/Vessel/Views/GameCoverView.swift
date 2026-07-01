import SwiftUI
import AppKit
import Shimmer

/// Caché de carátulas en memoria (`NSCache`) con **cascada de URLs**: prueba las candidatas
/// en orden y cachea la primera que cargue. A diferencia de `AsyncImage`, la descarga **no se
/// cancela** al reciclar celdas, así que en grids de cientos/miles de juegos no quedan carátulas
/// “a medio cargar” ni placeholders por cancelación. Caché y sesión compartidas por toda la app.
@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() { cache.countLimit = 1500 }

    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    /// Devuelve la primera imagen que cargue de `candidates` (cacheada por `key`), o `nil`.
    func load(_ key: String, candidates: [URL]) async -> NSImage? {
        if let img = cache.object(forKey: key as NSString) { return img }
        for url in candidates {
            guard let (data, resp) = try? await URLSession.shared.data(from: url) else { continue }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
            if let img = NSImage(data: data) {
                cache.setObject(img, forKey: key as NSString)
                return img
            }
        }
        return nil
    }
}

/// Carátula de juego **robusta y fluida**: muestra el `placeholder` y, encima, la primera
/// imagen de `candidates` que cargue (con caché en memoria). Si todas fallan, se queda el
/// placeholder — nunca un hueco. Reutilizada por la tarjeta del grid y la fila de la lista.
struct GameCoverImage<Placeholder: View>: View {
    let cacheKey: String
    let candidates: [URL]
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // `placeholder` (flexible) fija el tamaño; la imagen va como overlay y se recorta a él.
        // Con un ZStack, la imagen apaisada impondría su tamaño y desbordaría el 2:3 de la tarjeta.
        placeholder()
            // Brillo premium mientras la carátula carga (se apaga al aparecer la imagen).
            .shimmering(active: image == nil && !reduceMotion)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: cacheKey) {
            // Caché en memoria → aparición instantánea al reusar la celda (sin parpadeo).
            if let cached = CoverCache.shared.cached(cacheKey) { image = cached; return }
            image = nil
            let loaded = await CoverCache.shared.load(cacheKey, candidates: candidates)
            guard !Task.isCancelled else { return }
            if reduceMotion { image = loaded }
            else { withAnimation(.easeOut(duration: 0.22)) { image = loaded } }
        }
    }
}
