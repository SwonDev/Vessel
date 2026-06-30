import SwiftUI
import AppKit

/// Juego genérico común a TODAS las tiendas (Steam/Epic/GOG). Cada tienda mapea
/// sus datos a este modelo y reutiliza `StoreLibraryView` — así la UI/UX (búsqueda,
/// filtros, orden, favoritos, lista, tarjeta) es idéntica en todas. Ver [[vessel-biblioteca-generica]].
struct StoreGame: Identifiable, Hashable {
    let id: String
    let title: String
    var coverURL: String? = nil      // URL directa de carátula vertical (Epic/GOG)
    var heroURL: String? = nil       // banner horizontal para la ficha del juego
    var steamAppId: String? = nil    // para la portada del CDN de Steam
    var installed: Bool = false
    var lastPlayed: Date? = nil
    var playtimeMinutes: Int? = nil
    var installPath: String? = nil   // carpeta del juego (para "Abrir carpeta")

    /// Carátula vertical 2:3 resuelta: URL directa o, si no, la del CDN de Steam.
    /// Compartida por la tarjeta del grid y la fila de la lista (sin duplicar lógica).
    var resolvedCoverURL: URL? { coverCandidates.first }

    /// **Cascada** de URLs de carátula a probar en orden (la primera que cargue gana). Para
    /// Steam evita los huecos de los juegos viejos sin `library_600x900_2x`: cae a la versión
    /// 1x y, si tampoco, al `header.jpg` (que casi siempre existe). Así una carátula carga SIEMPRE.
    var coverCandidates: [URL] {
        var urls: [URL] = []
        if let s = coverURL, let u = URL(string: s) { urls.append(u) }
        if let appId = steamAppId, !appId.isEmpty {
            let base = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)"
            for path in ["/library_600x900_2x.jpg", "/library_600x900.jpg", "/header.jpg"] {
                if let u = URL(string: base + path) { urls.append(u) }
            }
        }
        return urls
    }

    /// Iniciales para el placeholder cuando no hay carátula.
    var initials: String {
        title.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    /// Color estable derivado del id (placeholder sin carátula).
    var placeholderColor: Color {
        var h = 5381
        for c in id.unicodeScalars { h = ((h << 5) &+ h) &+ Int(c.value) }
        return Color(hue: Double(abs(h) % 360) / 360.0, saturation: 0.48, brightness: 0.42)
    }
}

enum StoreSortOrder: String, CaseIterable, Identifiable {
    case nombre = "Nombre"
    case recientes = "Recientes"
    var id: String { rawValue }
    var symbol: String { self == .nombre ? "textformat" : "clock" }
}

enum StoreLibraryFilter: String, CaseIterable, Identifiable {
    case todos = "Todos"
    case instalados = "Instalados"
    case porInstalar = "Por instalar"
    var id: String { rawValue }
}

/// Biblioteca **genérica y premium** reutilizada por todas las tiendas. Solo recibe la
/// tienda (para el color/logo), sus juegos y los callbacks; la búsqueda, el orden, los
/// filtros y los favoritos son comunes. Accesible y con reduce-motion (UI/UX Pro Max).
struct StoreLibraryView: View {
    let store: StoreKind
    let games: [StoreGame]
    var installingIDs: Set<String> = []
    var progressFor: (String) -> String? = { _ in nil }
    /// Progreso de descarga 0.0–1.0 si se conoce (Steam vía SteamCMD). `nil` = indeterminado
    /// (spinner): Epic/GOG o fases de verificación. Pinta una barra estilo Steam cuando hay %.
    var percentFor: (String) -> Double? = { _ in nil }
    var onInstall: (StoreGame) -> Void = { _ in }
    var onPlay: (StoreGame) -> Void = { _ in }
    var onUninstall: (StoreGame) -> Void = { _ in }
    var onReload: () -> Void = {}
    var onLogout: () -> Void = {}

    @State private var search = ""
    @State private var sortOrder: StoreSortOrder = .nombre
    @State private var filter: StoreLibraryFilter = .todos
    @State private var showFavoritesOnly = false
    @State private var favorites: Set<String> = []
    @State private var selectedGame: StoreGame?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { store.tint }
    private var favKey: String { "favorites.\(store.rawValue)" }
    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 200), spacing: Theme.Space.gameGrid)]

    private func isFav(_ id: String) -> Bool { favorites.contains(id) }
    private func toggleFav(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites), forKey: favKey)
    }

    private var filtered: [StoreGame] {
        var list = games
        switch filter {
        case .instalados:  list = list.filter { $0.installed }
        case .porInstalar: list = list.filter { !$0.installed }
        case .todos:       break
        }
        if showFavoritesOnly { list = list.filter { isFav($0.id) } }
        if !search.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(search) }
        }
        list.sort { a, b in
            if a.installed != b.installed { return a.installed }   // instalados primero (como Steam)
            switch sortOrder {
            case .nombre:    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .recientes: return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast)
            }
        }
        return list
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
            detailPane
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: selectedGame)
        }
        .vesselBackground(tint: tint)
        .onAppear { favorites = Set(UserDefaults.standard.stringArray(forKey: favKey) ?? []) }
    }

    // MARK: - Panel principal: ficha del juego seleccionado o grid "home"

    @ViewBuilder private var detailPane: some View {
        if let game = selectedGame {
            GameDetailView(
                game: game, tint: tint,
                installing: installingIDs.contains(game.id),
                progress: progressFor(game.id),
                percent: percentFor(game.id),
                isFavorite: isFav(game.id),
                onInstall: { onInstall(game) },
                onPlay: { onPlay(game) },
                onUninstall: { onUninstall(game) },
                onToggleFavorite: { toggleFav(game.id) },
                onBack: { selectedGame = nil }
            )
            .id(game.id)
            .transition(.opacity)
        } else {
            homeGrid.transition(.opacity)
        }
    }

    /// "Home" del panel principal: grid de carátulas (instalados primero) cuando no hay
    /// ningún juego seleccionado en la lista lateral.
    private var homeGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                if !recentlyPlayed.isEmpty { recentlyPlayedSection }
                HStack(alignment: .firstTextBaseline) {
                    Text("Todos los juegos").font(.title.bold()).foregroundStyle(.white)
                    Spacer()
                    Text("\(filtered.count) juego\(filtered.count == 1 ? "" : "s")")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.5))
                }
                grid
            }
            .padding(Theme.Space.page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesselBackground(tint: tint)
    }

    /// Juegos jugados recientemente (los que tienen `lastPlayed`), más recientes primero.
    private var recentlyPlayed: [StoreGame] {
        games.filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(8).map { $0 }
    }

    /// Carrusel horizontal "Jugados recientemente" (estilo Steam) con cápsulas apaisadas.
    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jugados recientemente").font(.title2.bold()).foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(recentlyPlayed) { game in
                        RecentlyPlayedCard(game: game, tint: tint) { selectedGame = game }
                    }
                }
                .padding(.vertical, 4).padding(.horizontal, 2)
            }
        }
    }

    // MARK: - Sidebar: lista de juegos buscable (estilo Steam)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            searchBar
            filterBar
            gameList
        }
        .background(Theme.navyDeep.opacity(0.45))
    }

    /// Cabecera compacta de la sidebar: logo + nombre de la tienda + contador + menú
    /// (actualizar / cerrar sesión).
    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            StoreLogoTile(store: store, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.displayName).font(.headline).foregroundStyle(.white)
                Text("\(games.count) juego\(games.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Menu {
                Button { onReload() } label: { Label("Actualizar biblioteca", systemImage: "arrow.clockwise") }
                Divider()
                Button(role: .destructive) { onLogout() } label: {
                    Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6)).frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Opciones de \(store.displayName)")
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Buscar…", text: $search).textFieldStyle(.plain).font(.callout)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).accessibilityLabel("Borrar búsqueda")
            }
        }
        .padding(8)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    /// Filtro (Todos/Instalados/Por instalar), orden y favoritos — compactos para la lista.
    private var filterBar: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Mostrar", selection: $filter) {
                    ForEach(StoreLibraryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(filter.rawValue, systemImage: "line.3.horizontal.decrease")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(filter == .todos ? .white.opacity(0.6) : tint)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Filtrar por estado")

            Menu {
                Picker("Ordenar", selection: $sortOrder) {
                    ForEach(StoreSortOrder.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.caption)
                    .foregroundStyle(sortOrder == .nombre ? .white.opacity(0.6) : tint)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Ordenar")

            Spacer()

            Button { showFavoritesOnly.toggle() } label: {
                Image(systemName: showFavoritesOnly ? "star.fill" : "star").font(.caption)
                    .foregroundStyle(showFavoritesOnly ? .yellow : .white.opacity(0.6))
            }
            .buttonStyle(.plain).accessibilityLabel("Mostrar solo favoritos")
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    @ViewBuilder private var gameList: some View {
        if filtered.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: showFavoritesOnly ? "star.slash" : "magnifyingglass")
                    .font(.system(size: 30)).foregroundStyle(.white.opacity(0.25))
                Text(search.isEmpty && !showFavoritesOnly ? "Sin juegos." : "Sin resultados.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedGame) {
                ForEach(filtered) { game in
                    StoreGameRow(game: game, isFavorite: isFav(game.id))
                        .tag(game)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .listRowBackground(Color.clear)
                        .contextMenu { rowContextMenu(game) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .tint(tint)
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: filtered.count)
        }
    }

    @ViewBuilder private func rowContextMenu(_ game: StoreGame) -> some View {
        if game.installed {
            Button { onPlay(game) } label: { Label("Jugar", systemImage: "play.fill") }
            Button(role: .destructive) { onUninstall(game) } label: { Label("Desinstalar", systemImage: "trash") }
        } else if !installingIDs.contains(game.id) {
            Button { onInstall(game) } label: { Label("Instalar", systemImage: "arrow.down.circle") }
        }
        Divider()
        Button { toggleFav(game.id) } label: {
            Label(isFav(game.id) ? "Quitar de favoritos" : "Añadir a favoritos",
                  systemImage: isFav(game.id) ? "star.slash" : "star")
        }
    }

    // MARK: - Grid

    @ViewBuilder private var grid: some View {
        if filtered.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: showFavoritesOnly ? "star.slash" : "magnifyingglass")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.30))
                Text(search.isEmpty && !showFavoritesOnly
                     ? "No hay juegos que mostrar."
                     : "Sin resultados con los filtros actuales.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            LazyVGrid(columns: columns, spacing: Theme.Space.gameGrid) {
                ForEach(filtered) { game in
                    StoreGameCard(
                        game: game,
                        tint: tint,
                        isFavorite: isFav(game.id),
                        installing: installingIDs.contains(game.id),
                        progress: progressFor(game.id),
                        percent: percentFor(game.id),
                        onInstall: { onInstall(game) },
                        onPlay: { onPlay(game) },
                        onToggleFavorite: { toggleFav(game.id) },
                        onUninstall: { onUninstall(game) },
                        onOpen: { selectedGame = game }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: filtered.count)
        }
    }
}

// MARK: - Tarjeta de juego genérica

/// Tarjeta de juego **genérica y premium** (carátula 2:3 + título superpuesto + favorito +
/// botón Instalar/Jugar). Misma para todas las tiendas; `tint` la colorea.
struct StoreGameCard: View {
    let game: StoreGame
    let tint: Color
    var isFavorite: Bool = false
    var installing: Bool = false
    var progress: String? = nil
    var percent: Double? = nil
    var onInstall: () -> Void = {}
    var onPlay: () -> Void = {}
    var onToggleFavorite: () -> Void = {}
    var onUninstall: () -> Void = {}
    var onOpen: () -> Void = {}

    // Reutilizan la lógica del modelo (sin duplicar): ver `StoreGame`.
    private var placeholderColor: Color { game.placeholderColor }
    private var initials: String { game.initials }

    var body: some View {
        coverArt
            .overlay {
                if installing {
                    statusOverlay(progress ?? "Instalando…", spinner: percent == nil, percent: percent)
                } else if GameLaunchTracker.shared.state(game.id) == .launching {
                    statusOverlay("Iniciando…", spinner: true)
                } else if GameLaunchTracker.shared.state(game.id) == .running {
                    statusOverlay("Ejecutándose", spinner: false, icon: "play.circle.fill")
                }
            }
            .hoverLift()
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
            .onTapGesture { onOpen() }
            .help(game.title)
            .contextMenu {
                if game.installed {
                    Button { onPlay() } label: { Label("Jugar", systemImage: "play.fill") }
                    Button { onOpen() } label: { Label("Ver detalles", systemImage: "info.circle") }
                    Divider()
                    Button(role: .destructive) { onUninstall() } label: { Label("Desinstalar", systemImage: "trash") }
                } else if !installing {
                    Button { onInstall() } label: { Label("Instalar", systemImage: "arrow.down.circle") }
                    Button { onOpen() } label: { Label("Ver detalles", systemImage: "info.circle") }
                }
                Divider()
                Button { onToggleFavorite() } label: {
                    Label(isFavorite ? "Quitar de favoritos" : "Añadir a favoritos",
                          systemImage: isFavorite ? "star.slash" : "star")
                }
            }
    }

    /// Superposición de estado sobre la carátula (instalando / iniciando / ejecutándose).
    /// Si `percent` no es `nil`, pinta una barra determinada (descarga estilo Steam).
    private func statusOverlay(_ text: String, spinner: Bool, icon: String? = nil, percent: Double? = nil) -> some View {
        ZStack {
            Color.black.opacity(0.58)
            VStack(spacing: 6) {
                if let p = percent {
                    ProgressView(value: p).progressViewStyle(.linear)
                        .tint(Color(red: 0.34, green: 0.72, blue: 0.36))
                        .frame(width: 96)
                } else if spinner {
                    ProgressView().controlSize(.small).tint(.white)
                } else if let icon {
                    Image(systemName: icon).font(.title2).foregroundStyle(.white)
                }
                Text(text).font(.caption2.weight(.medium)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle).padding(.horizontal, 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
    }

    private var coverArt: some View {
        cover
            .aspectRatio(2.0/3.0, contentMode: .fit)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.9)],
                               startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                Text(game.title)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .lineLimit(2).shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.callout).foregroundStyle(isFavorite ? .yellow : .white)
                        .padding(7)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                }
                .buttonStyle(.plain).padding(7)
                .accessibilityLabel(isFavorite ? "Quitar de favoritos" : "Añadir a favoritos")
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.32), radius: 9, y: 5)
    }

    @ViewBuilder private var cover: some View {
        GameCoverImage(cacheKey: game.id, candidates: game.coverCandidates) { placeholder }
            .clipped()
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [placeholderColor, placeholderColor.opacity(0.50)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initials)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.30), radius: 4, y: 2)
        }
    }

}

// MARK: - Fila de la lista lateral

/// Fila compacta de la lista de juegos (sidebar estilo Steam): mini-carátula 2:3 + título
/// + estado. La selección la gestiona el `List` del coordinador. Reutiliza la carátula y el
/// placeholder del modelo `StoreGame` (sin duplicar).
struct StoreGameRow: View {
    let game: StoreGame
    var isFavorite: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            miniCover
                .frame(width: 30, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.callout).foregroundStyle(.white).lineLimit(1)
                Text(game.installed ? "Instalado" : "Sin instalar")
                    .font(.caption2)
                    .foregroundStyle(game.installed ? Color(red: 0.30, green: 0.85, blue: 0.55) : .white.opacity(0.4))
            }
            Spacer(minLength: 0)
            if isFavorite {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(game.title)
    }

    @ViewBuilder private var miniCover: some View {
        GameCoverImage(cacheKey: game.id, candidates: game.coverCandidates) {
            ZStack {
                game.placeholderColor
                Text(game.initials)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .clipped()
    }
}

// MARK: - Tarjeta "Jugados recientemente" (cápsula apaisada)

/// Cápsula apaisada para el carrusel "Jugados recientemente" del home (estilo Steam):
/// banner horizontal (header de Steam o hero) + título + tiempo de juego.
struct RecentlyPlayedCard: View {
    let game: StoreGame
    let tint: Color
    var onOpen: () -> Void = {}

    private var bannerURL: URL? {
        if let appId = game.steamAppId, !appId.isEmpty {
            return URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/header.jpg")
        }
        if let s = game.heroURL, let u = URL(string: s) { return u }
        return game.resolvedCoverURL
    }

    private var playtimeText: String? {
        guard let m = game.playtimeMinutes, m > 0 else { return nil }
        return m >= 60 ? "\(m / 60) h \(m % 60) min jugados" : "\(m) min jugados"
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                game.placeholderColor
                if let url = bannerURL {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image { img.resizable().scaledToFill() } else { Color.clear }
                    }
                }
            }
            .frame(width: 280, height: 130).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.2), .black.opacity(0.8)],
                           startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.callout.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                if let pt = playtimeText {
                    Text(pt).font(.caption2).foregroundStyle(.white.opacity(0.75))
                } else if let last = game.lastPlayed {
                    Text("Última vez: \(last.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(10)
        }
        .frame(width: 280, height: 130)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.32), radius: 8, y: 4)
        .hoverLift(scale: 1.02)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onTapGesture { onOpen() }
        .help(game.title)
    }
}

// MARK: - Ficha de juego (estilo Steam)

/// Metadatos **públicos** de un juego de Steam (API `appdetails`), para enriquecer la ficha
/// igual que las carátulas: solo datos públicos del juego (descripción, géneros, capturas,
/// estudio, fecha, Metacritic). Nada personal. Ver `loadDetails`.
struct SteamGameDetails {
    var description: String?
    var developers: [String] = []
    var publishers: [String] = []
    var releaseDate: String?
    var genres: [String] = []
    var metacritic: Int?
    var screenshots: [URL] = []
}

/// Ficha de juego al estilo Steam: banner hero + botón Jugar/Instalar + tiempo jugado y
/// última sesión. Genérica para todas las tiendas (cada una pasa su color y sus datos).
struct GameDetailView: View {
    let game: StoreGame
    let tint: Color
    var installing: Bool = false
    var progress: String? = nil
    var percent: Double? = nil
    var isFavorite: Bool = false
    var onInstall: () -> Void = {}
    var onPlay: () -> Void = {}
    var onUninstall: () -> Void = {}
    var onToggleFavorite: () -> Void = {}
    var onBack: () -> Void = {}

    @State private var showingSettings = false
    @State private var details: SteamGameDetails?
    @State private var loadingDetails = false
    private let steamGreen = Color(red: 0.34, green: 0.72, blue: 0.36)
    private let runningRed = Color(red: 0.85, green: 0.40, blue: 0.32)

    /// Perfil de compatibilidad del juego (para la sección de compatibilidad de la ficha).
    private var profile: CompatProfile? { CompatService.shared.profile(steam: game.steamAppId, title: game.title) }
    /// Estado de lanzamiento (idle/launching/running) para el feedback del botón.
    private var launchState: GameLaunchTracker.State { GameLaunchTracker.shared.state(game.id) }

    private var heroURL: URL? {
        if let s = game.heroURL, let u = URL(string: s) { return u }
        if let appId = game.steamAppId, !appId.isEmpty {
            return URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/library_hero.jpg")
        }
        if let s = game.coverURL, let u = URL(string: s) { return u }
        return nil
    }
    private var playtimeText: String {
        guard let m = game.playtimeMinutes, m > 0 else { return "—" }
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                actionBar
                if details?.genres.isEmpty == false {
                    genreChips.padding(.horizontal, 32).padding(.bottom, 6)
                }
                if details?.screenshots.isEmpty == false { mediaSection }
                content
            }
        }
        .vesselBackground(tint: tint)
        .overlay(alignment: .topLeading) { backButton }
        .sheet(isPresented: $showingSettings) {
            GameSettingsView(game: game, tint: tint, installPath: game.installPath) {
                showingSettings = false
            }
        }
        .task(id: game.id) { await loadDetails() }
    }

    private var hero: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = heroURL {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else { LinearGradient(colors: [tint.opacity(0.35), Theme.navyDeep], startPoint: .top, endPoint: .bottom) }
                        }
                    } else {
                        LinearGradient(colors: [tint.opacity(0.35), Theme.navyDeep], startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(width: geo.size.width, height: 380)
                .clipped()
                LinearGradient(colors: [.clear, .clear, Theme.navyDeep], startPoint: .top, endPoint: .bottom)
                Text(game.title)
                    .font(.system(size: 36, weight: .heavy)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 8, y: 3)
                    .padding(.horizontal, 32).padding(.bottom, 18)
            }
        }
        .frame(height: 380)
    }

    private var actionBar: some View {
        HStack(spacing: 28) {
            primaryButton
            stat("clock", "Última sesión", game.lastPlayed.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
            stat("hourglass", "Tiempo de juego", playtimeText)
            Spacer(minLength: 0)
            if game.installed { iconButton("trash", action: onUninstall) }
            iconButton("gearshape.fill") { showingSettings = true }
            iconButton(isFavorite ? "heart.fill" : "heart", tinted: isFavorite, action: onToggleFavorite)
        }
        .padding(.horizontal, 32).padding(.vertical, 18)
        .animation(.snappy(duration: 0.25), value: launchState)
        .animation(.snappy(duration: 0.25), value: installing)
    }

    /// Botón principal con FEEDBACK de estado: Instalar / Instalando… / Jugar / Iniciando… /
    /// Ejecutándose (pulsable para detener). Resuelve la duda de "¿está cargando o no?".
    @ViewBuilder private var primaryButton: some View {
        switch launchState {
        case .launching:
            Button {} label: {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Iniciando…")
                }
                .font(.title3.weight(.bold)).frame(minWidth: 170).frame(height: 28)
            }
            .vesselButton(tint: steamGreen).disabled(true)
            .help("Preparando el juego y arrancando…")
        case .running:
            Button { GameLaunchTracker.shared.stop(game.id) } label: {
                Label("Ejecutándose", systemImage: "stop.fill")
                    .font(.title3.weight(.bold)).frame(minWidth: 170).frame(height: 28)
            }
            .vesselButton(tint: runningRed)
            .help("El juego está en ejecución. Pulsa para forzar su cierre.")
        case .idle:
            if installing {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        if percent == nil { ProgressView().controlSize(.small).tint(.white) }
                        Text(progress ?? "Instalando…").font(.callout.weight(.medium)).foregroundStyle(.white)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if let p = percent {
                        ProgressView(value: p).progressViewStyle(.linear)
                            .tint(steamGreen).frame(width: 230)
                    }
                }.frame(minWidth: 230, alignment: .leading).frame(minHeight: 30)
            } else if game.installed {
                Button(action: onPlay) {
                    Label("Jugar", systemImage: "play.fill")
                        .font(.title2.weight(.bold)).frame(minWidth: 170).frame(height: 28)
                }
                .vesselButton(tint: steamGreen)
            } else {
                Button(action: onInstall) {
                    Label("Instalar", systemImage: "arrow.down.circle.fill")
                        .font(.title2.weight(.bold)).frame(minWidth: 170).frame(height: 28)
                }
                .vesselButton(tint: tint)
            }
        }
    }

    // MARK: - Contenido de la ficha (descripción + compatibilidad + detalles)

    private var content: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 20) {
                aboutSection
                if let p = profile { compatSection(p) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            detailsCard.frame(width: 300)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 36)
    }

    @ViewBuilder private var aboutSection: some View {
        if let d = details?.description, !d.isEmpty {
            cardSection("Acerca de") {
                Text(d).font(.callout).foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
        } else if loadingDetails {
            cardSection("Acerca de") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Cargando descripción…").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if profile == nil {
            cardSection("Acerca de") {
                Text("Sin descripción disponible para este juego.")
                    .font(.callout).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    /// Chips de género (estilo etiquetas de Steam) en scroll horizontal.
    @ViewBuilder private var genreChips: some View {
        if let genres = details?.genres, !genres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(genres, id: \.self) { g in
                        Text(g).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.88))
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.07)))
                            .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 0.6))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// Carrusel de capturas (estilo Steam), a todo el ancho. Metadatos públicos del juego.
    @ViewBuilder private var mediaSection: some View {
        if let shots = details?.screenshots, !shots.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("CAPTURAS").font(.caption.weight(.bold)).foregroundStyle(tint)
                    .padding(.horizontal, 32)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(shots, id: \.self) { url in
                            AsyncImage(url: url) { phase in
                                if let img = phase.image { img.resizable().scaledToFill() }
                                else { Theme.surface }
                            }
                            .frame(width: 300, height: 169)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous)
                                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.30), radius: 6, y: 3)
                        }
                    }
                    .padding(.horizontal, 32).padding(.vertical, 4)
                }
            }
            .padding(.bottom, 22)
        }
    }

    private func compatSection(_ p: CompatProfile) -> some View {
        cardSection("Compatibilidad en Mac") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: p.rating.systemImage).font(.title3).foregroundStyle(p.rating.color)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(p.rating.label).font(.callout.bold()).foregroundStyle(.white)
                            if p.verified {
                                Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(p.rating.color)
                            }
                        }
                        Text(p.rating.detail).font(.caption2).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    if !p.verified {
                        Text("sin verificar").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.08)))
                    }
                }
                if let notes = p.notes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var detailsCard: some View {
        cardSection("Detalles") {
            VStack(spacing: 0) {
                detailRow("Estado", game.installed ? "Instalado" : "No instalado",
                          valueColor: game.installed ? steamGreen : .white.opacity(0.6))
                if let dev = details?.developers.first, !dev.isEmpty { detailRow("Desarrollador", dev) }
                if let pub = details?.publishers.first, !pub.isEmpty { detailRow("Editor", pub) }
                if let rel = details?.releaseDate, !rel.isEmpty { detailRow("Lanzamiento", rel) }
                if let mc = details?.metacritic { detailRow("Metacritic", "\(mc)", valueColor: metacriticColor(mc)) }
                if let appId = game.steamAppId, !appId.isEmpty { detailRow("Steam AppID", appId) }
                detailRow("Última sesión", game.lastPlayed.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                detailRow("Tiempo de juego", playtimeText)
                if let path = game.installPath, !path.isEmpty {
                    Divider().overlay(.white.opacity(0.06)).padding(.vertical, 4)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Label("Abrir carpeta", systemImage: "folder").font(.caption).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain).foregroundStyle(tint)
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String, valueColor: Color = .white) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(value).font(.caption.weight(.medium)).foregroundStyle(valueColor)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 6)
    }

    /// Tarjeta de sección con título (estilo Steam, en Liquid Glass).
    private func cardSection(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(tint)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// Color del marcador Metacritic (verde ≥75, amarillo 50–74, rojo <50), como en Steam.
    private func metacriticColor(_ score: Int) -> Color {
        switch score {
        case 75...:   return Color(red: 0.40, green: 0.80, blue: 0.40)
        case 50..<75: return Color(red: 0.95, green: 0.78, blue: 0.30)
        default:      return Color(red: 0.90, green: 0.45, blue: 0.40)
        }
    }

    /// Descarga los metadatos del juego (solo Steam, API pública `appdetails`): descripción,
    /// géneros, capturas, estudio, editor, fecha y Metacritic. Metadatos públicos del juego,
    /// igual que las carátulas; sin datos personales.
    @MainActor private func loadDetails() async {
        details = nil
        guard let appId = game.steamAppId, !appId.isEmpty,
              let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appId)&l=spanish")
        else { return }
        loadingDetails = true
        defer { loadingDetails = false }
        do {
            var req = URLRequest(url: url); req.timeoutInterval = 12
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = obj[appId] as? [String: Any],
                  (entry["success"] as? Bool) == true,
                  let d = entry["data"] as? [String: Any] else { return }
            var det = SteamGameDetails()
            if let desc = (d["short_description"] as? String) ?? (d["about_the_game"] as? String) {
                det.description = Self.stripHTML(desc)
            }
            det.developers = (d["developers"] as? [String]) ?? []
            det.publishers = (d["publishers"] as? [String]) ?? []
            det.releaseDate = (d["release_date"] as? [String: Any])?["date"] as? String
            det.genres = ((d["genres"] as? [[String: Any]]) ?? []).compactMap { $0["description"] as? String }
            det.metacritic = (d["metacritic"] as? [String: Any])?["score"] as? Int
            det.screenshots = ((d["screenshots"] as? [[String: Any]]) ?? []).prefix(8).compactMap {
                ($0["path_thumbnail"] as? String).flatMap { URL(string: $0) }
            }
            details = det
        } catch { }
    }

    private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left").font(.body.weight(.bold)).foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .liquidGlass(in: Circle())
        }
        .buttonStyle(.plain).padding(16)
        .accessibilityLabel("Volver a la biblioteca")
    }

    private func stat(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.white.opacity(0.4))
            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased()).font(.caption2).foregroundStyle(.white.opacity(0.5))
                Text(value).font(.callout.weight(.medium)).foregroundStyle(.white)
            }
        }
    }

    private func iconButton(_ icon: String, tinted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body)
                .foregroundStyle(tinted ? Color.pink : .white.opacity(0.7))
                .frame(width: 38, height: 38)
                .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
