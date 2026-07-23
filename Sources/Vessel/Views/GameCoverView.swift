import SwiftUI
import AppKit
import CryptoKit

/// Caché de carátulas de DOS niveles: **memoria** (`NSCache`) + **disco** (persistente entre
/// arranques, en `Cache/Covers/`). Con **cascada de URLs**: prueba las candidatas en orden y
/// cachea la primera que cargue. A diferencia de `AsyncImage`, la descarga **no se cancela** al
/// reciclar celdas, así que en grids de miles de juegos no quedan carátulas "a medio cargar".
///
/// Objetivo: **cero red repetida**. Tras la primera vez, la carátula se sirve desde disco sin
/// bloquear el actor principal; si sigue caliente en memoria, el grid la pinta en el primer frame.
@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        // Una biblioteca grande puede tener miles de carátulas. Limitar solo por cantidad retenía
        // varios gigabytes de imágenes decodificadas; el coste en píxeles mantiene una ventana
        // caliente amplia sin competir con los juegos ni provocar presión de memoria al enfocar.
        cache.countLimit = 384
        cache.totalCostLimit = 256 * 1024 * 1024
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

    /// Consulta exclusivamente memoria. Es segura para el inicializador de una celda SwiftUI:
    /// nunca abre disco mientras se recompone una lista de miles de juegos.
    func memoryCached(_ key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    /// Devuelve la primera imagen que cargue (memoria → disco → red). Al bajarla la PERSISTE en
    /// disco para que en el siguiente arranque sea instantánea. `nil` si no hay carátula.
    func load(_ key: String, candidates: [URL]) async -> NSImage? {
        if let img = memoryCached(key) { return img }

        if let data = await Self.readDiskData(for: key), let img = NSImage(data: data) {
            insert(img, key: key, sourceByteCount: data.count)
            return img
        }

        guard let data = await Self.fetchCoverData(candidates: candidates), let img = NSImage(data: data) else { return nil }
        insert(img, key: key, sourceByteCount: data.count)
        await Self.persist(data, for: key)
        return img
    }

    private func insert(_ image: NSImage, key: String, sourceByteCount: Int) {
        let representation = image.representations.max {
            ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
        }
        let cost = Self.estimatedMemoryCost(
            pixelWidth: representation?.pixelsWide ?? 0,
            pixelHeight: representation?.pixelsHigh ?? 0,
            fallbackBytes: sourceByteCount
        )
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    nonisolated static func estimatedMemoryCost(
        pixelWidth: Int,
        pixelHeight: Int,
        fallbackBytes: Int
    ) -> Int {
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= Int.max / pixelHeight,
              pixelWidth * pixelHeight <= Int.max / 4 else {
            let positiveFallback = max(1, fallbackBytes)
            return positiveFallback > Int.max / 4 ? Int.max : positiveFallback * 4
        }
        return max(1, pixelWidth * pixelHeight * 4)
    }

    private nonisolated static func readDiskData(for key: String) async -> Data? {
        let file = diskFile(key)
        return await Task.detached(priority: .utility) {
            try? Data(contentsOf: file, options: .mappedIfSafe)
        }.value
    }

    private nonisolated static func persist(_ data: Data, for key: String) async {
        let file = diskFile(key)
        await Task.detached(priority: .utility) {
            try? data.write(to: file, options: .atomic)
        }.value
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

    /// Identidad del `.task`: el key **y** las candidatas. Si dependiera solo del key, una carátula
    /// que llega TARDE no se pintaría nunca: al sincronizar la biblioteca después del primer render
    /// (DRM‑free rellena la portada de Epic/GOG al importar, y SteamGridDB al meter la clave) cambian
    /// las candidatas pero NO el id del juego → el `.task` no se relanzaba y la tarjeta se quedaba
    /// en el placeholder hasta reabrir la app.
    private var loadID: String {
        cacheKey + "\u{1}" + candidates.map(\.absoluteString).joined(separator: "\u{2}")
    }

    init(cacheKey: String, candidates: [URL], @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.cacheKey = cacheKey
        self.candidates = candidates
        self.placeholder = placeholder
        // Solo memoria en el inicializador: abrir cientos de ficheros aquí bloqueaba el actor
        // principal cada vez que SwiftUI recomponía la biblioteca al recuperar el foco.
        let memoryImage = CoverCache.shared.memoryCached(cacheKey)
        _image = State(initialValue: memoryImage)
    }

    var body: some View {
        // `placeholder` (flexible) fija el tamaño; la imagen va como overlay y se recorta a él.
        placeholder()
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: loadID) {
                // Re-derivar para el `cacheKey` ACTUAL (cubre el reuso de celda con otro key):
                // memoria es inmediata; disco y red se leen fuera del actor principal.
                if let hit = CoverCache.shared.memoryCached(cacheKey) {
                    image = hit
                    return
                }
                guard !candidates.isEmpty else {
                    image = nil
                    return
                }
                image = nil
                let loaded = await CoverCache.shared.load(cacheKey, candidates: candidates)
                guard !Task.isCancelled else { return }
                if reduceMotion { image = loaded }
                else { withAnimation(.easeOut(duration: 0.22)) { image = loaded } }
            }
    }
}
