import SwiftUI
import AppKit
import Shimmer
import CryptoKit

/// Caché de carátulas de DOS niveles: **memoria** (`NSCache`) + **disco** (persistente entre
/// arranques, en `Cache/Covers/`). Con **cascada de URLs**: prueba las candidatas en orden y
/// cachea la primera que cargue. A diferencia de `AsyncImage`, la descarga **no se cancela** al
/// reciclar celdas, así que en grids de miles de juegos no quedan carátulas "a medio cargar".
///
/// Objetivo: **cero cargas visibles**. Tras la primera vez, la carátula se sirve desde disco de
/// forma instantánea (sin red) en el siguiente arranque; el grid la pinta en el primer frame.
@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, NSImage>()
    private let diskDir: URL

    private init() {
        cache.countLimit = 3000
        diskDir = URL(fileURLWithPath: VesselPaths.cacheDirectory).appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    /// Imagen ya disponible SIN red: primero memoria, luego DISCO. Rápida y síncrona (NSImage
    /// difiere el decodificado hasta el pintado), así que el grid puede pintarla en el primer frame.
    func cached(_ key: String) -> NSImage? {
        if let img = cache.object(forKey: key as NSString) { return img }
        let file = diskFile(key)
        if let img = NSImage(contentsOf: file) {
            cache.setObject(img, forKey: key as NSString)
            return img
        }
        return nil
    }

    /// Devuelve la primera imagen que cargue de `candidates` (memoria → disco → red). Al bajarla de
    /// la red la PERSISTE en disco para que en el siguiente arranque sea instantánea. `nil` si todas
    /// fallan (se queda el placeholder).
    func load(_ key: String, candidates: [URL]) async -> NSImage? {
        if let img = cached(key) { return img }
        for url in candidates {
            guard let (data, resp) = try? await URLSession.shared.data(from: url) else { continue }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
            if let img = NSImage(data: data) {
                cache.setObject(img, forKey: key as NSString)
                try? data.write(to: diskFile(key), options: .atomic)   // persistir para futuros arranques
                return img
            }
        }
        return nil
    }

    /// Nombre de fichero ESTABLE (hash SHA256 del key). No usar `hashValue`: en Swift es aleatorio
    /// por proceso y no serviría entre arranques.
    private func diskFile(_ key: String) -> URL {
        let hex = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(hex)
    }
}

/// Carátula de juego **robusta y fluida**: muestra el `placeholder` y, encima, la primera imagen
/// de `candidates` que cargue (caché memoria+disco). Si ya está cacheada, aparece en el PRIMER
/// frame (sin shimmer ni parpadeo). Si todas fallan, se queda el placeholder — nunca un hueco.
struct GameCoverImage<Placeholder: View>: View {
    let cacheKey: String
    let candidates: [URL]
    let placeholder: () -> Placeholder

    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(cacheKey: String, candidates: [URL], @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.cacheKey = cacheKey
        self.candidates = candidates
        self.placeholder = placeholder
        // Precarga SÍNCRONA desde caché (memoria/disco) → las cacheadas se pintan al instante,
        // sin shimmer ni retardo. Solo las nuevas (sin caché) pasan por `load()` en el `.task`.
        _image = State(initialValue: CoverCache.shared.cached(cacheKey))
    }

    var body: some View {
        // `placeholder` (flexible) fija el tamaño; la imagen va como overlay y se recorta a él.
        placeholder()
            // Brillo premium SOLO mientras se descarga una carátula nueva (no cacheada).
            .shimmering(active: image == nil && !reduceMotion)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: cacheKey) {
                // Re-derivar para el `cacheKey` ACTUAL (cubre el reuso de celda con otro key):
                // si está en caché (memoria/disco) se pinta al instante; si no, se descarga.
                if let hit = CoverCache.shared.cached(cacheKey) { image = hit; return }
                image = nil   // no cacheada aún → placeholder + shimmer mientras baja
                let loaded = await CoverCache.shared.load(cacheKey, candidates: candidates)
                guard !Task.isCancelled else { return }
                if reduceMotion { image = loaded }
                else { withAnimation(.easeOut(duration: 0.22)) { image = loaded } }
            }
    }
}
