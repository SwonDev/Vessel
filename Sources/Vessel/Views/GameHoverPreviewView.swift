import SwiftUI
import AVKit

/// Comunica al coordinador la posición de cada carátula visible sin introducir AppKit ni
/// coordenadas globales. El panel puede así elegir automáticamente el lado con más espacio.
struct GameCardBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Igual que `GameCardBoundsPreferenceKey` pero para las FILAS de la barra lateral: comunica la
/// posición de cada fila visible para anclar el panel de hover junto a ella (hacia el panel de
/// detalle), igual que hace Steam en su lista compacta.
struct GameRowBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Panel informativo estilo Steam que aparece junto a una carátula tras un hover intencional.
/// Es estrictamente informativo: el clic de la tarjeta sigue abriendo la ficha completa, por lo
/// que teclado y VoiceOver no dependen de una interacción exclusiva del ratón.
struct GameHoverPreviewView: View {
    static let panelSize = CGSize(width: 352, height: 408)

    let game: StoreGame
    let store: StoreKind
    let tint: Color
    private let loadsRemoteDetails: Bool

    @State private var details: StoreGameMetadata?
    @State private var mediaIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(game: StoreGame, store: StoreKind, tint: Color,
         initialDetails: StoreGameMetadata? = nil, loadsRemoteDetails: Bool = true) {
        self.game = game
        self.store = store
        self.tint = tint
        self.loadsRemoteDetails = loadsRemoteDetails
        _details = State(initialValue: initialDetails)
    }

    private enum Media: Hashable {
        case image(URL)
        case movie(StoreGameMovie)

        var id: String {
            switch self {
            case .image(let url): return "image:\(url.absoluteString)"
            case .movie(let movie): return "movie:\(movie.id)"
            }
        }

        var displayDuration: Duration {
            switch self {
            case .image: return .seconds(4)
            case .movie: return .seconds(7)
            }
        }
    }

    private var request: StoreGameMetadataRequest {
        StoreGameMetadataRequest(
            source: StoreGameMetadataRequest.Source(rawValue: store.rawValue) ?? .local,
            id: game.id,
            title: game.title,
            steamAppId: game.steamAppId
        )
    }

    private var media: [Media] {
        var result: [Media] = []
        var imageURLs: [URL] = []

        if let details {
            imageURLs.append(contentsOf: details.screenshotsFull)
            if imageURLs.isEmpty { imageURLs.append(contentsOf: details.screenshots) }
        }

        // Antes de cargar (o si la tienda no tiene capturas), el hero mantiene el panel útil.
        if imageURLs.isEmpty {
            if let hero = secureURL(game.heroURL) { imageURLs.append(hero) }
            if let appId = game.steamAppId,
               let hero = secureURL("https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/library_hero.jpg") {
                imageURLs.append(hero)
            }
            if let cover = game.coverCandidates.first { imageURLs.append(cover) }
        }

        imageURLs = unique(imageURLs)
        if let first = imageURLs.first { result.append(.image(first)) }

        // Con Reducir movimiento no se reproducen ni rotan vídeos automáticamente; se usa su póster.
        if let movie = details?.movies.first {
            if reduceMotion {
                if let poster = movie.thumbnailURL { result.append(.image(poster)) }
            } else {
                result.append(.movie(movie))
            }
        }
        result.append(contentsOf: imageURLs.dropFirst().prefix(5).map(Media.image))
        return result
    }

    private var currentMedia: Media? {
        guard !media.isEmpty else { return nil }
        return media[min(mediaIndex, media.count - 1)]
    }

    private var playtimeText: String {
        guard let minutes = game.playtimeMinutes, minutes > 0 else { return "Sin tiempo registrado" }
        if minutes < 60 { return "\(minutes) min jugados" }
        return "\(minutes / 60) h \(minutes % 60) min jugados"
    }

    private var lastPlayedText: String {
        guard let lastPlayed = game.lastPlayed else { return "Nunca jugado" }
        let relative = lastPlayed.formatted(
            .relative(presentation: .named)
                .locale(Locale(identifier: "es_ES"))
        )
        return "Última sesión \(relative)"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            mediaArea
            information
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
        .background { shape.fill(Theme.navyDeep.opacity(0.34)) }
        .liquidGlass(in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.8) }
        .shadow(color: .black.opacity(0.38), radius: 18, y: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .task(id: request) {
            guard loadsRemoteDetails else { return }
            details = nil
            mediaIndex = 0
            details = await StoreGameMetadataService.shared.details(for: request)
        }
        .task(id: media.map(\.id)) { await rotateMedia() }
    }

    private var mediaArea: some View {
        ZStack(alignment: .bottom) {
            Theme.surface
            if let currentMedia {
                mediaView(currentMedia)
                    .id(currentMedia.id)
                    .transition(.opacity)
            } else {
                ProgressView().controlSize(.small).tint(.white)
            }
            LinearGradient(colors: [.clear, Theme.navyDeep.opacity(0.60)],
                           startPoint: .center, endPoint: .bottom)
            if media.count > 1 { pageIndicator }
        }
        .frame(height: 198)
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: mediaIndex)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func mediaView(_ item: Media) -> some View {
        switch item {
        case .image(let url):
            GameCoverImage(cacheKey: "preview-media-\(url.absoluteString)", candidates: [url]) {
                Theme.surface
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .movie(let movie):
            MutedHoverVideo(url: movie.videoURL)
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 5) {
            ForEach(Array(media.indices), id: \.self) { index in
                Capsule()
                    .fill(index == mediaIndex ? Color.white : .white.opacity(0.38))
                    .frame(width: index == mediaIndex ? 16 : 5, height: 5)
            }
        }
        .padding(.bottom, 10)
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(game.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 4)
                statusBadge
            }

            HStack(spacing: 14) {
                Label(playtimeText, systemImage: "hourglass")
                Label(lastPlayedText, systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.72))
            .lineLimit(1)

            if let description = details?.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Mantén el puntero para consultar sus datos; haz clic para abrir la ficha completa.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                ForEach(Array((details?.genres ?? []).prefix(2)), id: \.self) { genre in
                    Text(genre)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .frame(maxWidth: 96)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.07), in: Capsule())
                }
                if let score = details?.metacritic {
                    Text("Metacritic \(score)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.07), in: Capsule())
                }
                if let summary = details?.reviewSummary {
                    Text(summary)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.07), in: Capsule())
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.white.opacity(0.54))
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var statusBadge: some View {
        Label(game.updateAvailable ? "Actualizar" : (game.installed ? "Instalado" : "Por instalar"),
              systemImage: game.updateAvailable ? "arrow.down.circle.fill"
                  : (game.installed ? "checkmark.circle.fill" : "icloud.and.arrow.down"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(game.installed || game.updateAvailable ? tint : .white.opacity(0.62))
            .lineLimit(1)
    }

    private var accessibilitySummary: String {
        "\(game.title). \(game.installed ? "Instalado" : "Sin instalar"). \(playtimeText). \(lastPlayedText). Haz clic para ver todos los detalles."
    }

    @MainActor private func rotateMedia() async {
        mediaIndex = 0
        guard !reduceMotion, media.count > 1 else { return }
        while !Task.isCancelled {
            let delay = currentMedia?.displayDuration ?? .seconds(4)
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, !media.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.32)) {
                mediaIndex = (mediaIndex + 1) % media.count
            }
        }
    }

    private func secureURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    private func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.filter { seen.insert($0).inserted }
    }
}

/// Reproductor efímero del tráiler: siempre silenciado y sin controles para que un hover nunca
/// secuestre el audio, el foco ni los gestos del usuario.
private struct MutedHoverVideo: View {
    let url: URL
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .allowsHitTesting(false)
            .onAppear {
                player.isMuted = true
                player.allowsExternalPlayback = false
                player.play()
            }
            .onDisappear {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
    }
}
