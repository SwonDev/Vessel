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

    private init() {
        cache.countLimit = 3000
        try? FileManager.default.createDirectory(at: Self.diskDir, withIntermediateDirectories: true)
    }

    /// Directorio de disco de las carátulas (persistente entre arranques).
    nonisolated static var diskDir: URL {
        URL(fileURLWithPath: VesselPaths.cacheDirectory).appendingPathComponent("Covers", isDirectory: true)
    }

    /// Nombre de fichero ESTABLE (hash SHA256 del key). No usar `hashValue`: en Swift es aleatorio
    /// por proceso y no serviría entre arranques.
    nonisolated static func diskFile(_ key: String) -> URL {
        let hex = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(hex)
    }

    /// Imagen ya disponible SIN red: primero memoria, luego DISCO. Rápida y síncrona (NSImage
    /// difiere el decodificado hasta el pintado), así que el grid puede pintarla en el primer frame.
    func cached(_ key: String) -> NSImage? {
        if let img = cache.object(forKey: key as NSString) { return img }
        if let img = NSImage(contentsOf: Self.diskFile(key)) {
            cache.setObject(img, forKey: key as NSString)
            return img
        }
        return nil
    }

    /// Devuelve la primera imagen que cargue (memoria → disco → red). Al bajarla la PERSISTE en
    /// disco para que en el siguiente arranque sea instantánea. `nil` si no hay carátula.
    func load(_ key: String, candidates: [URL]) async -> NSImage? {
        if let img = cached(key) { return img }
        guard let data = await Self.fetchCoverData(candidates: candidates), let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: key as NSString)
        try? data.write(to: Self.diskFile(key), options: .atomic)
        return img
    }

    /// Baja los BYTES de la primera candidata que cargue. Si TODAS fallan y son URLs de Steam
    /// (juego nuevo con assets bajo una ruta HASHEADA impredecible → los patrones dan 404), pide la
    /// URL real del `header_image` a `appdetails` (API pública, gratis) y baja esa. Así ninguna
    /// carátula de Steam se queda en el placeholder.
    nonisolated static func fetchCoverData(candidates: [URL]) async -> Data? {
        for url in candidates {
            guard let (data, resp) = try? await URLSession.shared.data(from: url), !data.isEmpty else { continue }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
            return data
        }
        if let real = await steamHeaderURL(fromCandidates: candidates),
           let (data, resp) = try? await URLSession.shared.data(from: real), !data.isEmpty,
           (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true {
            return data
        }
        return nil
    }

    /// URL real del header de un juego de Steam vía `appdetails`, extrayendo el appid de una de las
    /// candidatas (`…/steam/apps/<id>/…`). `nil` si no es de Steam o no hay datos.
    nonisolated static func steamHeaderURL(fromCandidates candidates: [URL]) async -> URL? {
        guard let appId = candidates.compactMap({ steamAppId(from: $0) }).first,
              let api = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appId)&filters=basic")
        else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: api),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = obj[appId] as? [String: Any], (entry["success"] as? Bool) == true,
              let d = entry["data"] as? [String: Any],
              let header = d["header_image"] as? String else { return nil }
        return URL(string: header)
    }

    /// Extrae el appid de una URL de Steam del tipo `…/steam/apps/<id>/…`.
    private nonisolated static func steamAppId(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "apps"), i + 1 < parts.count else { return nil }
        let id = parts[i + 1]
        return id.allSatisfy(\.isNumber) && !id.isEmpty ? id : nil
    }

    /// **Pre-descarga** en segundo plano (baja prioridad) las carátulas que aún NO estén en disco,
    /// para que TODAS sean instantáneas al hacer scroll o relanzar — no solo las ya vistas. No toca
    /// la caché de memoria (evita bloat con miles de juegos): solo escribe a disco. Throttle a 6
    /// descargas en paralelo. Idempotente: salta las ya cacheadas.
    nonisolated func prefetch(_ items: [(key: String, candidates: [URL])]) {
        Task.detached(priority: .background) {
            let fm = FileManager.default
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for item in items where !item.candidates.isEmpty {
                    if fm.fileExists(atPath: Self.diskFile(item.key).path) { continue }   // ya en disco
                    if running >= 6 { await group.next(); running -= 1 }
                    group.addTask {
                        if let data = await Self.fetchCoverData(candidates: item.candidates) {
                            try? data.write(to: Self.diskFile(item.key), options: .atomic)
                        }
                    }
                    running += 1
                }
            }
        }
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
