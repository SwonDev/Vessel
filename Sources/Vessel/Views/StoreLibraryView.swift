import SwiftUI

/// Juego genérico común a TODAS las tiendas (Steam/Epic/GOG/Amazon). Cada tienda mapea
/// sus datos a este modelo y reutiliza `StoreLibraryView` — así la UI/UX (búsqueda,
/// filtros, orden, favoritos, grid, tarjeta) es idéntica en todas. Ver [[vessel-biblioteca-generica]].
struct StoreGame: Identifiable, Hashable {
    let id: String
    let title: String
    var coverURL: String? = nil      // URL directa de carátula (Epic/GOG/Amazon)
    var steamAppId: String? = nil    // para la portada del CDN de Steam
    var installed: Bool = false
    var lastPlayed: Date? = nil
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
    var onInstall: (StoreGame) -> Void = { _ in }
    var onPlay: (StoreGame) -> Void = { _ in }
    var onReload: () -> Void = {}
    var onLogout: () -> Void = {}

    @State private var search = ""
    @State private var sortOrder: StoreSortOrder = .nombre
    @State private var filter: StoreLibraryFilter = .todos
    @State private var showFavoritesOnly = false
    @State private var favorites: Set<String> = []
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
        switch sortOrder {
        case .nombre:    list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .recientes: list.sort { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                header
                controls
                grid
            }
            .padding(Theme.Space.page)
        }
        .vesselBackground(tint: tint)
        .onAppear { favorites = Set(UserDefaults.standard.stringArray(forKey: favKey) ?? []) }
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(spacing: 16) {
            StoreLogoTile(store: store, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.displayName).font(.largeTitle.bold()).foregroundStyle(.white)
                Text("\(games.count) juego\(games.count == 1 ? "" : "s") en tu biblioteca")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button(action: onReload) { Label("Actualizar", systemImage: "arrow.clockwise") }
                .vesselButton(false)
            Button(role: .destructive, action: onLogout) {
                Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .vesselButton(false)
        }
    }

    // MARK: - Barra de controles (búsqueda + orden + filtro + favoritos)

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar en \(store.displayName)…", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Borrar búsqueda")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

            Menu {
                Picker("Ordenar", selection: $sortOrder) {
                    ForEach(StoreSortOrder.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(sortOrder == .nombre ? .secondary : tint)
                    .frame(width: 38, height: 38)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Ordenar")

            Menu {
                Picker("Mostrar", selection: $filter) {
                    ForEach(StoreLibraryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: filter == .todos ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(filter == .todos ? .secondary : tint)
                    .frame(width: 38, height: 38)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Filtrar por estado")

            Toggle(isOn: $showFavoritesOnly) {
                Image(systemName: showFavoritesOnly ? "star.fill" : "star")
                    .frame(width: 38, height: 38)
            }
            .toggleStyle(.button).tint(.yellow)
            .accessibilityLabel("Mostrar solo favoritos")
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
                        onInstall: { onInstall(game) },
                        onPlay: { onPlay(game) },
                        onToggleFavorite: { toggleFav(game.id) }
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
    var onInstall: () -> Void = {}
    var onPlay: () -> Void = {}
    var onToggleFavorite: () -> Void = {}

    private var coverURL: URL? {
        if let s = game.coverURL, let u = URL(string: s) { return u }
        if let appId = game.steamAppId, !appId.isEmpty {
            return URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/library_600x900_2x.jpg")
        }
        return nil
    }

    private var placeholderColor: Color {
        var h = 5381
        for c in game.id.unicodeScalars { h = ((h << 5) &+ h) &+ Int(c.value) }
        return Color(hue: Double(abs(h) % 360) / 360.0, saturation: 0.48, brightness: 0.42)
    }

    private var initials: String {
        game.title.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        VStack(spacing: 8) {
            coverArt
            actionButton
        }
        .hoverLift()
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
        placeholder
            .overlay {
                if let url = coverURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { Color.clear }
                    }
                }
            }
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

    @ViewBuilder private var actionButton: some View {
        if installing {
            VStack(spacing: 4) {
                ProgressView().controlSize(.small).tint(.white)
                Text(progress ?? "Instalando…")
                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
        } else if game.installed {
            Button(action: onPlay) {
                Label("Jugar", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .vesselButton(tint: tint)
        } else {
            Button(action: onInstall) {
                Label("Instalar", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
            }
            .vesselButton(false)
        }
    }
}
