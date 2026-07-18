import SwiftUI
import AppKit
import DockProgress
import Shimmer

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
    var updateAvailable: Bool = false   // hay actualización pendiente (detección por tienda)
    var lastPlayed: Date? = nil
    var playtimeMinutes: Int? = nil
    var installPath: String? = nil   // carpeta del juego (para "Abrir carpeta")
    /// Etiqueta opcional sobre la carátula (p. ej. la FUENTE en DRM‑free: Steam / itch.io / Humble).
    var badge: String? = nil

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

    var steamStoreURL: URL? {
        guard let steamAppId, !steamAppId.isEmpty,
              steamAppId.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://store.steampowered.com/app/\(steamAppId)")
    }

    var protonDBURL: URL? {
        guard let steamAppId, !steamAppId.isEmpty,
              steamAppId.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://www.protondb.com/app/\(steamAppId)")
    }
}

enum StoreSortOrder: String, CaseIterable, Identifiable {
    case nombre = "Nombre"
    case recientes = "Recientes"
    case masJugado = "Más jugado"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .nombre:    return "textformat"
        case .recientes: return "clock"
        case .masJugado: return "hourglass"
        }
    }
}

enum StoreLibraryFilter: String, CaseIterable, Identifiable {
    case todos = "Todos"
    case instalados = "Instalados"
    case porInstalar = "Por instalar"
    case conActualizacion = "Con actualización"
    case sinJugar = "Sin jugar"
    case jugados = "Jugados"
    case ocultos = "Ocultos"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .todos:            return "square.grid.2x2"
        case .instalados:       return "internaldrive"
        case .porInstalar:      return "arrow.down.circle"
        case .conActualizacion: return "arrow.triangle.2.circlepath"
        case .sinJugar:         return "sparkles"
        case .jugados:          return "clock.arrow.circlepath"
        case .ocultos:          return "eye.slash"
        }
    }
}

/// Accesos directos visibles a los criterios que más se usan en una biblioteca grande.
/// Los filtros menos frecuentes siguen disponibles en el menú avanzado de la sidebar.
private enum LibraryQuickScope: String, CaseIterable, Identifiable {
    case todos = "Todos"
    case listos = "Listos para jugar"
    case actualizaciones = "Actualizaciones"
    case sinJugar = "Sin jugar"
    case favoritos = "Favoritos"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .todos:           return "square.grid.2x2"
        case .listos:          return "play.circle.fill"
        case .actualizaciones: return "arrow.triangle.2.circlepath"
        case .sinJugar:        return "sparkles"
        case .favoritos:       return "star.fill"
        }
    }
}

/// Destino interno del navegador de biblioteca. Permite atrás/adelante sin exponer rutas ni
/// añadir controles permanentes a la ventana.
private enum LibraryDestination: Equatable {
    case home
    case game(String)
}

private struct CollectionEditorRequest: Identifiable {
    enum Mode {
        case create(game: StoreGame?)
        case rename(LibraryCollectionsStore.Collection)
    }

    let id = UUID()
    let mode: Mode
}

/// Densidad del grid de carátulas (tamaño de las portadas), persistente. Como el slider de
/// tamaño de la biblioteca de Steam, aquí en 3 pasos premium — clave para navegar bibliotecas
/// de miles de juegos según prefieras densidad o tamaño.
enum GridDensity: String, CaseIterable, Identifiable {
    case compacta = "Compacta"
    case normal   = "Normal"
    case grande   = "Grande"
    var id: String { rawValue }
    /// (min, max) del ancho adaptativo de cada carátula.
    var coverRange: (min: CGFloat, max: CGFloat) {
        switch self {
        case .compacta: return (116, 148)
        case .normal:   return (158, 200)
        case .grande:   return (212, 268)
        }
    }
    var symbol: String {
        switch self {
        case .compacta: return "square.grid.4x3.fill"
        case .normal:   return "square.grid.3x2.fill"
        case .grande:   return "square.grid.2x2.fill"
        }
    }
    var help: String {
        switch self {
        case .compacta: return "Carátulas pequeñas (más por fila)"
        case .normal:   return "Carátulas normales"
        case .grande:   return "Carátulas grandes"
        }
    }
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
    /// Verificar/reparar integridad de un juego instalado (re-descarga lo dañado). Reusa el
    /// feedback de instalación (`installingIDs`/`progressFor`/`percentFor`).
    var onVerify: (StoreGame) -> Void = { _ in }
    /// Aplicar la actualización de un juego instalado (mismo feedback que instalar/verificar).
    var onUpdate: (StoreGame) -> Void = { _ in }
    var onReload: () -> Void = {}
    var onLogout: () -> Void = {}
    /// Iniciar sesión (re-login). Si se provee, aparece "Iniciar sesión" en el menú "…". Steam lo
    /// usa para relanzar el login oficial; Epic/GOG tienen su propio flujo de conexión.
    var onLogin: (() -> Void)? = nil
    /// Abrir el cliente Steam completo (solo Steam). Si se provee, aparece "Abrir Steam" en el
    /// menú "…": arranca Steam conectado en D3DMetal para jugar DESDE Steam con DRM real.
    var onOpenSteam: (() -> Void)? = nil
    /// Controles EXTRA propios de la tienda, mostrados en la cabecera del grid (junto al selector de
    /// densidad) y en la cabecera de la sidebar. Lo usa la sección DRM‑free para sus acciones
    /// (vincular itch.io/Humble, generar desde Steam, añadir .exe). `nil` en el resto de tiendas.
    var toolbarExtra: AnyView? = nil
    /// **Exportar** un juego instalado (copiar su carpeta autocontenida a un USB/disco externo). Lo
    /// usa la sección DRM‑free: los juegos generados son portables y "tuyos". Si se provee, aparece
    /// "Exportar juego…" en el menú contextual de la carátula. `nil` en el resto de tiendas.
    var onExport: ((StoreGame) -> Void)? = nil

    @State private var search = ""
    /// Foco del buscador (para el atajo ⌘F). Se aplica a ambos buscadores (sidebar y cabecera);
    /// solo enfoca el visible.
    @FocusState private var searchFocused: Bool
    @State private var sortOrder: StoreSortOrder = .nombre
    @State private var filter: StoreLibraryFilter = .todos
    @State private var showFavoritesOnly = false
    /// Sidebar colapsada (persistente): más espacio para el grid/ficha. Estilo Steam.
    @AppStorage("vessel.sidebarCollapsed") private var sidebarCollapsed = false
    /// Tamaño de las carátulas del grid (persistente). Como el slider de tamaño de Steam.
    @AppStorage("vessel.gridDensity") private var gridDensity: GridDensity = .normal
    @State private var favorites: Set<String> = []
    /// Juegos archivados por el usuario. Es una preferencia local, reversible y separada por
    /// tienda: nunca borra archivos, estadísticas, favoritos ni copias de partida.
    @State private var hiddenGames: Set<String> = []
    @State private var selectedGame: StoreGame?
    @State private var collectionsStore = LibraryCollectionsStore.shared
    @State private var notesStore = GameNotesStore.shared
    @State private var selectedCollectionID: UUID?
    @State private var collectionEditorRequest: CollectionEditorRequest?
    @State private var collectionPendingDeletion: LibraryCollectionsStore.Collection?
    @State private var quickOpenPresented = false
    @State private var notesEditorGame: StoreGame?
    @State private var transferCenterPresented = false
    /// Historial de navegación estilo Steam/navegador. Se limita para no retener una sesión
    /// indefinidamente y solo guarda identificadores, nunca modelos ni datos remotos.
    @State private var backHistory: [LibraryDestination] = []
    @State private var forwardHistory: [LibraryDestination] = []
    /// Acción reversible al ocultar: evita que un clic accidental haga "desaparecer" un juego.
    @State private var undoHiddenGame: StoreGame?
    @State private var undoHiddenTask: Task<Void, Never>?
    /// Hover intencional del grid. Se separa el candidato de la vista presentada para poder
    /// aplicar retardo, cancelar al cruzar huecos y evitar parpadeos en bibliotecas grandes.
    @State private var hoverCandidateID: String?
    @State private var previewedGame: StoreGame?
    @State private var hoverPresentationTask: Task<Void, Never>?
    /// Tooltip de "Abrir Steam" sobre el logo: se muestra una vez y se auto-oculta.
    @State private var showSteamHint = false
    @State private var steamHintDisplayed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { store.tint }
    private var favKey: String { "favorites.\(store.rawValue)" }
    private var hiddenKey: String { "hiddenGames.\(store.rawValue)" }
    private var preferencePrefix: String { "vessel.library.\(store.rawValue)" }
    private var selectionKey: String { "\(preferencePrefix).selectedGame" }
    private var storeCollections: [LibraryCollectionsStore.Collection] {
        collectionsStore.collections(for: store.rawValue)
    }
    private var selectedCollection: LibraryCollectionsStore.Collection? {
        guard let selectedCollectionID else { return nil }
        return collectionsStore.collection(id: selectedCollectionID)
    }
    private var activeTransferGames: [StoreGame] {
        games.lazy
            .filter { installingIDs.contains($0.id) }
            .map(enrichedGame)
    }
    private var activeTransfers: [LibraryTransferItem] {
        LibraryTransferSnapshot.items(
            games: activeTransferGames,
            activeIDs: installingIDs,
            progressFor: progressFor,
            percentFor: percentFor
        )
    }
    /// Columnas adaptativas según la densidad elegida (tamaño de carátula).
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: gridDensity.coverRange.min, maximum: gridDensity.coverRange.max),
                  spacing: Theme.Space.gameGrid)]
    }

    private func isFav(_ id: String) -> Bool { favorites.contains(id) }
    private func toggleFav(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites), forKey: favKey)
    }

    private func isHidden(_ id: String) -> Bool { hiddenGames.contains(id) }

    private func toggleHidden(_ id: String) {
        if hiddenGames.contains(id) {
            hiddenGames.remove(id)
            if undoHiddenGame?.id == id { dismissUndoHidden() }
        } else {
            hiddenGames.insert(id)
            if let game = games.first(where: { $0.id == id }) {
                presentUndoHidden(for: enrichedGame(game))
            }
            if selectedGame?.id == id { navigate(to: .home, recordingHistory: true) }
        }
        UserDefaults.standard.set(Array(hiddenGames), forKey: hiddenKey)
    }

    private func presentUndoHidden(for game: StoreGame) {
        undoHiddenTask?.cancel()
        undoHiddenGame = game
        undoHiddenTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard !Task.isCancelled, undoHiddenGame?.id == game.id else { return }
            undoHiddenGame = nil
        }
    }

    private func dismissUndoHidden() {
        undoHiddenTask?.cancel()
        undoHiddenTask = nil
        undoHiddenGame = nil
    }

    private func undoHidden() {
        guard let game = undoHiddenGame else { return }
        hiddenGames.remove(game.id)
        UserDefaults.standard.set(Array(hiddenGames), forKey: hiddenKey)
        dismissUndoHidden()
        openGame(game)
    }

    private func copyGameTitle(_ game: StoreGame) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(game.title, forType: .string)
    }

    /// Doble clic en la lista, como Steam: ejecuta la acción primaria sin añadir ningún control.
    /// Un juego que ya está arrancando o ejecutándose se ignora para evitar cierres accidentales.
    private func performDoubleClickAction(for game: StoreGame) {
        guard !installingIDs.contains(game.id),
              GameLaunchTracker.shared.state(game.id) == .idle else { return }
        if game.installed { onPlay(game) } else { onInstall(game) }
    }

    /// Soltar sobre "Colecciones" crea una nueva; si ya se está viendo una colección, añade el
    /// juego a ella. La carga incluye la tienda para impedir cruces accidentales entre catálogos.
    private func handleCollectionDrop(_ payload: LibraryGameDragPayload) -> Bool {
        guard payload.storeID == store.rawValue,
              let game = games.first(where: { $0.id == payload.gameID }) else { return false }
        dismissHoverPreview(immediately: true)
        if let selectedCollectionID {
            _ = collectionsStore.add(gameID: game.id, to: selectedCollectionID)
        } else {
            requestNewCollection(including: enrichedGame(game))
        }
        return true
    }

    private var currentDestination: LibraryDestination {
        selectedGame.map { .game($0.id) } ?? .home
    }

    private func openGame(_ game: StoreGame) {
        navigate(to: .game(game.id), recordingHistory: true)
    }

    private func navigateHome() {
        navigate(to: .home, recordingHistory: true)
    }

    private func navigate(to destination: LibraryDestination, recordingHistory: Bool) {
        guard destination != currentDestination else { return }
        if recordingHistory {
            backHistory.append(currentDestination)
            if backHistory.count > 50 { backHistory.removeFirst(backHistory.count - 50) }
            forwardHistory.removeAll(keepingCapacity: true)
        }
        switch destination {
        case .home:
            selectedGame = nil
        case .game(let id):
            selectedGame = games.first(where: { $0.id == id })
        }
    }

    private func navigateBack() {
        guard let destination = backHistory.popLast() else { return }
        forwardHistory.append(currentDestination)
        navigate(to: destination, recordingHistory: false)
    }

    private func navigateForward() {
        guard let destination = forwardHistory.popLast() else { return }
        backHistory.append(currentDestination)
        navigate(to: destination, recordingHistory: false)
    }

    private func navigateBackOrHome() {
        if backHistory.isEmpty { navigateHome() } else { navigateBack() }
    }

    private func toggleCollection(_ collectionID: UUID, for game: StoreGame) {
        collectionsStore.toggle(gameID: game.id, in: collectionID)
    }

    private func requestNewCollection(including game: StoreGame? = nil) {
        collectionEditorRequest = CollectionEditorRequest(mode: .create(game: game))
    }

    private func requestRenameSelectedCollection() {
        guard let selectedCollection else { return }
        collectionEditorRequest = CollectionEditorRequest(mode: .rename(selectedCollection))
    }

    private func openNotes(for game: StoreGame) {
        dismissHoverPreview(immediately: true)
        notesEditorGame = enrichedGame(game)
    }

    private var activeQuickScope: LibraryQuickScope? {
        guard selectedCollectionID == nil else { return nil }
        if showFavoritesOnly && filter == .todos { return .favoritos }
        guard !showFavoritesOnly else { return nil }
        switch filter {
        case .todos:            return .todos
        case .instalados:       return .listos
        case .conActualizacion: return .actualizaciones
        case .sinJugar:         return .sinJugar
        case .porInstalar, .jugados, .ocultos: return nil
        }
    }

    private func apply(_ scope: LibraryQuickScope) {
        selectedCollectionID = nil
        switch scope {
        case .todos:
            filter = .todos
            showFavoritesOnly = false
        case .listos:
            filter = .instalados
            showFavoritesOnly = false
        case .actualizaciones:
            filter = .conActualizacion
            showFavoritesOnly = false
        case .sinJugar:
            filter = .sinJugar
            showFavoritesOnly = false
        case .favoritos:
            filter = .todos
            showFavoritesOnly = true
        }
    }

    private func resetQuery() {
        search = ""
        filter = .todos
        showFavoritesOnly = false
        selectedCollectionID = nil
    }

    /// Steam conserva la forma de explorar cada biblioteca. Vessel hace lo mismo por tienda,
    /// sin persistir el texto buscado (evita sorpresas y no almacena consultas del usuario).
    private func restoreLibraryPreferences() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "\(preferencePrefix).filter"),
           let stored = StoreLibraryFilter(rawValue: raw) {
            filter = stored
        }
        if let raw = defaults.string(forKey: "\(preferencePrefix).sort"),
           let stored = StoreSortOrder(rawValue: raw) {
            sortOrder = stored
        }
        showFavoritesOnly = defaults.bool(forKey: "\(preferencePrefix).favoritesOnly")
        if let raw = defaults.string(forKey: "\(preferencePrefix).collection"),
           let id = UUID(uuidString: raw), collectionsStore.collection(id: id) != nil {
            selectedCollectionID = id
        }
        if let gameID = defaults.string(forKey: selectionKey),
           let game = games.first(where: { $0.id == gameID }),
           !isHidden(gameID) {
            selectedGame = enrichedGame(game)
        } else {
            defaults.removeObject(forKey: selectionKey)
        }
    }

    private func persistLibraryPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(filter.rawValue, forKey: "\(preferencePrefix).filter")
        defaults.set(sortOrder.rawValue, forKey: "\(preferencePrefix).sort")
        defaults.set(showFavoritesOnly, forKey: "\(preferencePrefix).favoritesOnly")
        if let selectedCollectionID {
            defaults.set(selectedCollectionID.uuidString, forKey: "\(preferencePrefix).collection")
        } else {
            defaults.removeObject(forKey: "\(preferencePrefix).collection")
        }
    }

    private func persistSelectedGame() {
        if let selectedGame {
            UserDefaults.standard.set(selectedGame.id, forKey: selectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectionKey)
        }
    }

    /// Clave de estadística de juego (`"<tienda>:<id>"`), la misma que escribe el
    /// `GameLaunchTracker` al jugar. Une lectura (aquí) y escritura (al lanzar).
    private func statsKey(_ game: StoreGame) -> String { "\(store.rawValue):\(game.id)" }

    /// Juegos enriquecidos con las estadísticas persistidas (`PlayStatsStore`): última sesión y
    /// tiempo jugado. La UI (orden Recientes/Más jugado, carrusel, ficha) ya espera estos campos
    /// en `StoreGame`; aquí es donde se rellenan, en UN solo sitio, sin tocar las 3 tiendas.
    /// Un juego con sus estadísticas persistidas (última sesión + tiempo jugado) resueltas EN VIVO
    /// desde `PlayStatsStore` (@Observable). O(1): para el juego seleccionado, sin reconstruir toda
    /// la biblioteca (la ficha usaba `enriched.first`, que rehacía los ~miles de juegos para sacar 1).
    private func enrichedGame(_ g: StoreGame) -> StoreGame {
        var e = g
        let k = statsKey(g)
        if let lp = PlayStatsStore.shared.lastPlayed(k) { e.lastPlayed = lp }
        if let pm = PlayStatsStore.shared.playtimeMinutes(k) { e.playtimeMinutes = pm }
        return e
    }

    private var enriched: [StoreGame] { games.map(enrichedGame) }

    /// Resuelve la versión más reciente del seleccionado, porque instalar/actualizar puede cambiar
    /// el modelo mientras su ficha sigue abierta.
    private var currentSelectedGame: StoreGame? {
        guard let selectedGame else { return nil }
        return enrichedGame(games.first(where: { $0.id == selectedGame.id }) ?? selectedGame)
    }

    /// Menú Juego y atajos nativos. No añade controles visibles: ofrece las acciones de Steam a
    /// usuarios de teclado y mantiene los comandos desactivados cuando no existe una selección.
    private var libraryFocusedActions: LibraryFocusedActions {
        let navigationBack: (() -> Void)?
        let navigationForward: (() -> Void)?
        if backHistory.isEmpty { navigationBack = nil } else { navigationBack = { navigateBack() } }
        if forwardHistory.isEmpty { navigationForward = nil } else { navigationForward = { navigateForward() } }
        guard let game = currentSelectedGame else {
            return LibraryFocusedActions(
                navigateBack: navigationBack,
                navigateForward: navigationForward
            )
        }

        let launchState = GameLaunchTracker.shared.state(game.id)
        let primary: (String?, (() -> Void)?)
        if installingIDs.contains(game.id) || launchState == .launching {
            primary = (nil, nil)
        } else if launchState == .running {
            primary = ("Detener \(game.title)", { GameLaunchTracker.shared.stop(game.id) })
        } else if game.installed {
            primary = ("Jugar a \(game.title)", { onPlay(game) })
        } else {
            primary = ("Instalar \(game.title)", { onInstall(game) })
        }

        let reveal: (() -> Void)? = game.installPath.flatMap { path in
            guard !path.isEmpty else { return nil }
            return { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }

        return LibraryFocusedActions(
            primaryTitle: primary.0,
            performPrimary: primary.1,
            favoriteTitle: isFav(game.id) ? "Quitar \(game.title) de favoritos" : "Añadir \(game.title) a favoritos",
            toggleFavorite: { toggleFav(game.id) },
            hiddenTitle: isHidden(game.id) ? "Mostrar \(game.title) en la biblioteca" : "Ocultar \(game.title) de la biblioteca",
            toggleHidden: { toggleHidden(game.id) },
            revealInFinder: reveal,
            copyTitle: { copyGameTitle(game) },
            notesTitle: notesStore.hasNote(storeID: store.rawValue, gameID: game.id)
                ? "Editar notas de \(game.title)…" : "Añadir notas a \(game.title)…",
            openNotes: { openNotes(for: game) },
            navigateBack: navigationBack,
            navigateForward: navigationForward
        )
    }

    /// Lista mostrada (filtrada + ordenada) MEMOIZADA: se recalcula solo cuando cambian las
    /// entradas (juegos/búsqueda/filtro/orden/favoritos), NO en cada render — así con miles de
    /// juegos el tecleo y los cambios de estado son fluidos.
    @State private var displayed: [StoreGame] = []

    private func computeFiltered() -> [StoreGame] {
        var list = enriched
        if filter == .ocultos {
            list = list.filter { isHidden($0.id) }
        } else {
            // Los juegos ocultos no reaparecen accidentalmente al cambiar otro filtro. Solo se
            // muestran desde su ámbito explícito, igual que en Steam.
            list = list.filter { !isHidden($0.id) }
            switch filter {
            case .instalados:       list = list.filter { $0.installed }
            case .porInstalar:      list = list.filter { !$0.installed }
            case .conActualizacion: list = list.filter { $0.updateAvailable }
            case .sinJugar:         list = list.filter { $0.lastPlayed == nil && ($0.playtimeMinutes ?? 0) == 0 }
            case .jugados:          list = list.filter { $0.lastPlayed != nil || ($0.playtimeMinutes ?? 0) > 0 }
            case .todos, .ocultos:  break
            }
        }
        if let selectedCollection {
            list = list.filter { selectedCollection.gameIDs.contains($0.id) }
        }
        if showFavoritesOnly { list = list.filter { isFav($0.id) } }
        if !search.isEmpty {
            list = list.filter { LibraryTitleSearch.matches(title: $0.title, query: search) }
        }
        list.sort { a, b in
            if a.installed != b.installed { return a.installed }   // instalados primero (como Steam)
            switch sortOrder {
            case .nombre:    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .recientes: return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast)
            case .masJugado: return (a.playtimeMinutes ?? 0) > (b.playtimeMinutes ?? 0)
            }
        }
        return list
    }

    /// Ancho de la sidebar (persistente y arrastrable). Al colapsar se lleva a 0 con animación
    /// suave (deslizándose), lo que da la transición premium que `HSplitView` no permitía.
    @AppStorage("vessel.sidebarWidth") private var sidebarWidthRaw: Double = 244
    @State private var sidebarDragStart: Double? = nil
    /// Ancho EN VIVO durante el arrastre: en memoria (`@State`), para NO escribir en `UserDefaults`
    /// (@AppStorage) en cada frame — esa I/O síncrona por frame era una de las causas del stutter.
    /// Se persiste una sola vez al soltar. `nil` = no se está arrastrando (manda el persistido).
    @State private var liveSidebarWidth: Double? = nil
    private var sidebarWidth: CGFloat { CGFloat(min(360, max(200, liveSidebarWidth ?? sidebarWidthRaw))) }

    var body: some View { libraryPresentationLayer }

    /// Separar layout, estado, comandos y presentaciones reduce drásticamente el trabajo del
    /// type-checker de SwiftUI en esta vista coordinadora de gran tamaño.
    private var libraryLayout: some View {
        HStack(spacing: 0) {
            // Sidebar con ancho ANIMADO: el contenido va a ancho fijo dentro de un marco que se
            // encoge a 0 y recorta → colapsa/expande deslizándose, fluido y premium. (HSplitView,
            // al ser NSSplitView, no animaba la inserción/eliminación del panel: saltaba en seco.)
            sidebar
                .frame(width: sidebarWidth)
                .frame(width: sidebarCollapsed ? 0 : sidebarWidth, alignment: .leading)
                .clipped()
                .opacity(sidebarCollapsed ? 0 : 1)
                .allowsHitTesting(!sidebarCollapsed)
            // Divisor arrastrable entre lista y panel (redimensiona la lista); se pliega con ella.
            sidebarDivider
                .frame(width: sidebarCollapsed ? 0 : 8)
                .opacity(sidebarCollapsed ? 0 : 1)
                .allowsHitTesting(!sidebarCollapsed)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: selectedGame)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.38), value: sidebarCollapsed)
        // Botón para MOSTRAR la lista cuando está colapsada (en el grid; en la ficha manda "atrás").
        .overlay(alignment: .topLeading) {
            if sidebarCollapsed && selectedGame == nil {
                Button { sidebarCollapsed = false } label: {
                    Image(systemName: "sidebar.left").font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85)).frame(width: 32, height: 32)
                        .liquidGlass(in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain).padding(.top, 12).padding(.leading, 12)
                .vesselHelp("Mostrar la lista", shortcut: "⌘L")
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !activeTransfers.isEmpty {
                LibraryTransferCenterButton(
                    items: activeTransfers,
                    games: activeTransferGames,
                    tint: tint,
                    isPresented: $transferCenterPresented,
                    onOpen: { game in
                        transferCenterPresented = false
                        openGame(game)
                    }
                )
                .padding(.trailing, 18)
                .padding(.bottom, 16)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .zIndex(200)
            }
        }
        .focusedSceneValue(\.libraryActions, libraryFocusedActions)
        .vesselBackground(tint: tint)
    }

    private var libraryStateLayer: some View {
        libraryLayout
        // Esc: volver de la ficha; si no, limpiar la búsqueda; si no, soltar el foco.
        .onExitCommand {
            if selectedGame != nil {
                if backHistory.isEmpty { selectedGame = nil } else { navigateBack() }
            }
            else if !search.isEmpty { search = "" }
            else { searchFocused = false }
        }
        .onAppear {
            favorites = Set(UserDefaults.standard.stringArray(forKey: favKey) ?? [])
            hiddenGames = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
            restoreLibraryPreferences()
            displayed = computeFiltered()
            updateDockProgress()
        }
        // Recalcular la lista mostrada SOLO al cambiar una entrada (no en cada render).
        .onChange(of: search) { _, _ in refreshDisplayed() }
        .onChange(of: filter) { _, _ in persistLibraryPreferences(); refreshDisplayed() }
        .onChange(of: sortOrder) { _, _ in persistLibraryPreferences(); refreshDisplayed() }
        .onChange(of: showFavoritesOnly) { _, _ in persistLibraryPreferences(); refreshDisplayed() }
        .onChange(of: favorites) { _, _ in refreshDisplayed() }
        .onChange(of: hiddenGames) { _, _ in refreshDisplayed() }
        .onChange(of: collectionsStore.collections) { _, _ in
            if let selectedCollectionID,
               collectionsStore.collection(id: selectedCollectionID) == nil {
                self.selectedCollectionID = nil
            }
            persistLibraryPreferences()
            refreshDisplayed()
        }
        .onChange(of: selectedCollectionID) { _, _ in
            persistLibraryPreferences()
            refreshDisplayed()
        }
        .onChange(of: selectedGame) { _, selected in
            if selected != nil { dismissHoverPreview(immediately: true) }
            persistSelectedGame()
        }
        .onChange(of: dockProgressSnapshot) { _, _ in updateDockProgress() }
        .onChange(of: installingIDs) { _, activeIDs in
            if activeIDs.isEmpty { transferCenterPresented = false }
        }
        // Pre-descarga TODAS las carátulas de la tienda a disco en 2º plano (cuando la lista carga),
        // para que ninguna cargue de red al hacer scroll: instantáneas siempre. Idempotente.
        // `id: games` (no `games.count`): al instalar/actualizar un juego el TOTAL no cambia, pero
        // sí su estado (installed/updateAvailable/título) — como StoreGame es Equatable, esto
        // recalcula la lista y refresca ficha/grid/sidebar (antes seguía diciendo "Sin instalar").
        .task(id: games) {
            refreshDisplayed()
            CoverCache.shared.prefetch(games.map { ($0.id, $0.coverCandidates) })
        }
        .onDisappear(perform: cancelTransientTasks)
    }

    private var libraryCommandLayer: some View {
        libraryStateLayer
        .onReceive(NotificationCenter.default.publisher(for: .libraryFind)) { _ in
            if sidebarCollapsed { sidebarCollapsed = false }
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryQuickOpen)) { _ in
            dismissHoverPreview(immediately: true)
            quickOpenPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryToggleSidebar)) { _ in
            sidebarCollapsed.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryShowAll)) { _ in
            resetQuery()
            navigateHome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryShowHidden)) { _ in
            search = ""
            filter = .ocultos
            showFavoritesOnly = false
            selectedCollectionID = nil
            navigateHome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryRefresh)) { _ in
            onReload()
        }
    }

    private var libraryPresentationLayer: some View {
        libraryCommandLayer
        .sheet(item: $collectionEditorRequest, content: collectionEditor)
        .sheet(isPresented: $quickOpenPresented) {
            LibraryQuickOpenView(
                store: store,
                games: enriched,
                favorites: favorites,
                tint: tint,
                onOpen: openGame
            )
        }
        .sheet(item: $notesEditorGame) { game in
            let note = notesStore.note(storeID: store.rawValue, gameID: game.id)
            GameNotesEditorView(
                game: game,
                store: store,
                tint: tint,
                initialText: note?.text ?? "",
                updatedAt: note?.updatedAt,
                onSave: { text in
                    notesStore.update(storeID: store.rawValue, gameID: game.id, text: text)
                },
                onDelete: {
                    notesStore.remove(storeID: store.rawValue, gameID: game.id)
                }
            )
        }
        .confirmationDialog(
            "¿Eliminar la colección «\(collectionPendingDeletion?.name ?? "")»?",
            isPresented: collectionDeletionPresented
        ) {
            Button("Eliminar colección", role: .destructive, action: deletePendingCollection)
            Button("Cancelar", role: .cancel) { collectionPendingDeletion = nil }
        } message: {
            Text("Los juegos y sus archivos no se eliminarán.")
        }
        .overlay(alignment: .bottom) { undoHiddenOverlay }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: undoHiddenGame?.id)
    }

    private func cancelTransientTasks() {
        hoverPresentationTask?.cancel()
        hoverPresentationTask = nil
        undoHiddenTask?.cancel()
        undoHiddenTask = nil
    }

    @ViewBuilder
    private func collectionEditor(_ request: CollectionEditorRequest) -> some View {
        switch request.mode {
        case .create(let game):
            LibraryCollectionEditorView(
                title: "Nueva colección",
                subtitle: game.map { "Organiza «\($0.title)» sin mover ni modificar sus archivos." }
                    ?? "Crea una colección local para organizar esta biblioteca.",
                actionTitle: "Crear",
                tint: tint
            ) { name in
                guard let id = collectionsStore.create(
                    name: name,
                    storeID: store.rawValue,
                    including: game?.id
                ) else { return false }
                if game == nil {
                    filter = .todos
                    showFavoritesOnly = false
                    selectedCollectionID = id
                    navigateHome()
                }
                return true
            }
        case .rename(let collection):
            LibraryCollectionEditorView(
                title: "Renombrar colección",
                subtitle: "El cambio solo afecta a la organización local de Vessel.",
                actionTitle: "Guardar",
                initialName: collection.name,
                tint: tint
            ) { name in
                collectionsStore.rename(collection.id, to: name)
            }
        }
    }

    private var collectionDeletionPresented: Binding<Bool> {
        Binding(
            get: { collectionPendingDeletion != nil },
            set: { if !$0 { collectionPendingDeletion = nil } }
        )
    }

    private func deletePendingCollection() {
        guard let collectionPendingDeletion else { return }
        collectionsStore.delete(collectionPendingDeletion.id)
        self.collectionPendingDeletion = nil
    }

    @ViewBuilder private var undoHiddenOverlay: some View {
        if let undoHiddenGame {
            LibraryUndoBanner(
                message: "«\(undoHiddenGame.title)» se ha ocultado",
                tint: tint,
                onUndo: undoHidden
            )
            .padding(.bottom, 26)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Divisor vertical arrastrable entre la lista y el panel: fina línea de cristal dentro de una
    /// zona de agarre ancha, con cursor de redimensionado. Ajusta `sidebarWidthRaw` en vivo (sin
    /// animación, para que el arrastre sea 1:1 con el cursor).
    private var sidebarDivider: some View {
        ZStack {
            Color.clear
            Rectangle().fill(.white.opacity(0.09)).frame(width: 1)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
        // Coordenadas GLOBALES: el divisor vive DENTRO del HStack que se redimensiona, así que en
        // coordenadas locales su espacio se desplaza al moverlo → la `translation` se realimenta y
        // el arrastre VIBRA. En global, la `translation` es estable (espacio de pantalla) → 1:1 fluido.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if sidebarDragStart == nil { sidebarDragStart = sidebarWidthRaw }
                    let base = sidebarDragStart ?? sidebarWidthRaw
                    liveSidebarWidth = Double(min(360, max(200, CGFloat(base) + value.translation.width)))
                }
                .onEnded { _ in
                    if let w = liveSidebarWidth { sidebarWidthRaw = w }  // persistir UNA vez, al soltar
                    liveSidebarWidth = nil
                    sidebarDragStart = nil
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Ancho de la lista de juegos")
        .accessibilityValue("\(Int(sidebarWidth)) puntos")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: sidebarWidthRaw = min(360, sidebarWidthRaw + 20)
            case .decrement: sidebarWidthRaw = max(200, sidebarWidthRaw - 20)
            @unknown default: break
            }
        }
        .vesselHelp("Redimensionar la lista", detail: "Arrastra a izquierda o derecha para cambiar su anchura.")
    }

    /// Progreso AGREGADO (0–1) de las instalaciones/actualizaciones en curso, para el icono del
    /// Dock. `-1` = nada en curso; `0.03` = hay instalación(es) sin % conocido (indeterminado).
    private var dockProgressSnapshot: Double {
        let known = installingIDs.compactMap { percentFor($0) }
        if !known.isEmpty { return known.reduce(0, +) / Double(known.count) }
        return installingIDs.isEmpty ? -1 : 0.03
    }

    /// Refleja `dockProgressSnapshot` en el icono del Dock (barra de progreso estilo Mythic).
    private func updateDockProgress() {
        let v = dockProgressSnapshot
        if v < 0 { DockProgress.resetProgress() } else { DockProgress.progress = min(1, max(0, v)) }
    }

    // MARK: - Panel principal: ficha del juego seleccionado o grid "home"

    @ViewBuilder private var detailPane: some View {
        if let selected = selectedGame {
            // Enriquecer SOLO el seleccionado (O(1)): la ficha refleja el tiempo jugado y la última
            // sesión EN VIVO al cerrar el juego (PlayStatsStore es @Observable) sin reconstruir toda
            // la biblioteca en cada render.
            let game = enrichedGame(selected)
            GameDetailView(
                game: game, tint: tint, store: store,
                installing: installingIDs.contains(game.id),
                progress: progressFor(game.id),
                percent: percentFor(game.id),
                isFavorite: isFav(game.id),
                isHidden: isHidden(game.id),
                onInstall: { onInstall(game) },
                onPlay: { onPlay(game) },
                onUninstall: { onUninstall(game) },
                onVerify: { onVerify(game) },
                onUpdate: { onUpdate(game) },
                onToggleFavorite: { toggleFav(game.id) },
                onToggleHidden: { toggleHidden(game.id) },
                hasNote: notesStore.hasNote(storeID: store.rawValue, gameID: game.id),
                onOpenNotes: { openNotes(for: game) },
                onBack: navigateBackOrHome
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
                if showsRecentlyPlayed && !recentlyPlayed.isEmpty { recentlyPlayedSection }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(homeTitle)
                            .font(.title.bold()).foregroundStyle(.white)
                        // Con la sidebar colapsada, el buscador (y filtro/orden) viven en la sidebar y se
                        // ocultan → los traemos aquí para no perder la búsqueda. Estilo Steam.
                        if sidebarCollapsed {
                            headerSearchField
                            headerFilterMenu
                            headerSortMenu
                        }
                        Spacer()
                        Text("\(displayed.count) juego\(displayed.count == 1 ? "" : "s")")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.5))
                        if let toolbarExtra { toolbarExtra }
                        gridDensityToggle
                    }
                    quickScopeBar
                }
                grid
            }
            .padding(Theme.Space.page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesselBackground(tint: tint)
        .overlayPreferenceValue(GameCardBoundsPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                if let game = previewedGame, let anchor = anchors[game.id] {
                    let cardBounds = proxy[anchor]
                    GameHoverPreviewView(game: game, store: store, tint: tint)
                        .frame(width: GameHoverPreviewView.panelSize.width,
                               height: GameHoverPreviewView.panelSize.height)
                        .position(previewPosition(for: cardBounds, in: proxy.size))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .zIndex(100)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Posiciona el panel al lado de la carátula, cambia a la izquierda si no cabe y limita su
    /// centro al viewport. Los bordes nunca se salen de la ventana, incluso al hacer scroll.
    private func previewPosition(for card: CGRect, in viewport: CGSize) -> CGPoint {
        let panel = GameHoverPreviewView.panelSize
        let margin: CGFloat = 12
        let right = card.maxX + margin + panel.width / 2
        let left = card.minX - margin - panel.width / 2
        let minimumX = panel.width / 2 + margin
        let maximumX = max(minimumX, viewport.width - panel.width / 2 - margin)
        let x = right + panel.width / 2 <= viewport.width - margin ? right : max(minimumX, left)

        let minimumY = panel.height / 2 + margin
        let maximumY = max(minimumY, viewport.height - panel.height / 2 - margin)
        // Alinear los bordes superiores como Steam evita que un panel más alto que la carátula
        // invada el título y la scope bar de filtros de la primera fila.
        let topAlignedY = card.minY + panel.height / 2
        return CGPoint(x: min(maximumX, max(minimumX, x)),
                       y: min(maximumY, max(minimumY, topAlignedY)))
    }

    /// Steam espera un instante antes de abrir la tarjeta rica: recorrer el grid no provoca red
    /// ni paneles fugaces. Una vez abierta, cambiar de juego es más rápido para sentirse continuo.
    private func handleGridHover(_ hovering: Bool, game: StoreGame) {
        hoverPresentationTask?.cancel()

        if hovering {
            hoverCandidateID = game.id
            let delay: Duration = previewedGame == nil ? .milliseconds(420) : .milliseconds(130)
            hoverPresentationTask = Task { @MainActor in
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled, hoverCandidateID == game.id else { return }
                let enriched = enrichedGame(game)
                if reduceMotion { previewedGame = enriched }
                else { withAnimation(.smooth(duration: 0.20)) { previewedGame = enriched } }
            }
        } else {
            guard hoverCandidateID == game.id else { return }
            hoverCandidateID = nil
            hoverPresentationTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard !Task.isCancelled, hoverCandidateID == nil,
                      previewedGame?.id == game.id else { return }
                dismissHoverPreview(immediately: false)
            }
        }
    }

    private func dismissHoverPreview(immediately: Bool) {
        hoverPresentationTask?.cancel()
        hoverPresentationTask = nil
        hoverCandidateID = nil
        if immediately || reduceMotion { previewedGame = nil }
        else { withAnimation(.smooth(duration: 0.16)) { previewedGame = nil } }
    }

    /// Los cambios de consulta/orden pueden retirar o desplazar la carátula ancla. Cierra antes
    /// el panel para que nunca reaparezca al restaurar un filtro sin un hover nuevo.
    private func refreshDisplayed() {
        dismissHoverPreview(immediately: true)
        displayed = computeFiltered()
    }

    /// Juegos jugados recientemente (los que tienen `lastPlayed`), más recientes primero.
    private var recentlyPlayed: [StoreGame] {
        enriched.filter { $0.lastPlayed != nil && !isHidden($0.id) }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(8).map { $0 }
    }

    /// La estantería global solo pertenece a la portada sin restricciones. Al entrar en una
    /// colección o aplicar una consulta, ocultarla evita mezclar juegos ajenos al resultado.
    private var showsRecentlyPlayed: Bool {
        selectedCollectionID == nil && filter == .todos && !showFavoritesOnly && search.isEmpty
    }

    private var homeTitle: String {
        if let selectedCollection { return selectedCollection.name }
        return filter == .ocultos ? "Juegos ocultos" : "Todos los juegos"
    }

    /// Carrusel horizontal "Jugados recientemente" (estilo Steam) con cápsulas apaisadas.
    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jugados recientemente").font(.title2.bold()).foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(recentlyPlayed) { game in
                        RecentlyPlayedCard(game: game, tint: tint) { openGame(game) }
                            .draggable(LibraryGameDragPayload(storeID: store.rawValue, gameID: game.id))
                    }
                }
                .padding(.vertical, 4).padding(.horizontal, 2)
            }
        }
    }

    /// Barra de ámbitos siempre visible. Es el equivalente ligero a las colecciones dinámicas de
    /// Steam y a una scope bar de macOS: un clic aplica el criterio y el contador anticipa el resultado.
    private var quickScopeBar: some View {
        let source = enriched.filter { !isHidden($0.id) }
        let counts: [LibraryQuickScope: Int] = [
            .todos: source.count,
            .listos: source.count(where: \.installed),
            .actualizaciones: source.count(where: \.updateAvailable),
            .sinJugar: source.count { $0.lastPlayed == nil && ($0.playtimeMinutes ?? 0) == 0 },
            .favoritos: source.count { favorites.contains($0.id) }
        ]

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryQuickScope.allCases) { scope in
                    LibraryScopeChip(
                        title: scope.rawValue,
                        symbol: scope.symbol,
                        count: counts[scope, default: 0],
                        selected: activeQuickScope == scope,
                        tint: tint
                    ) {
                        apply(scope)
                    }
                }

                LibraryCollectionScopeMenu(
                    collections: storeCollections,
                    selectedID: selectedCollectionID,
                    tint: tint,
                    onSelect: { id in
                        search = ""
                        filter = .todos
                        showFavoritesOnly = false
                        selectedCollectionID = id
                        navigateHome()
                    },
                    onClear: {
                        resetQuery()
                        navigateHome()
                    },
                    onCreate: { requestNewCollection() },
                    onRenameSelected: requestRenameSelectedCollection,
                    onDeleteSelected: {
                        collectionPendingDeletion = selectedCollection
                    },
                    onDropGame: handleCollectionDrop
                )

                if activeQuickScope == nil && selectedCollectionID == nil {
                    LibraryScopeChip(
                        title: activeConstraintLabel,
                        symbol: "xmark",
                        count: nil,
                        selected: true,
                        tint: tint,
                        action: resetQuery
                    )
                }
            }
            .vesselGlassContainer(spacing: 8)
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
        .accessibilityLabel("Filtros rápidos de la biblioteca")
    }

    private var activeConstraintLabel: String {
        var parts: [String] = []
        if let selectedCollection { parts.append(selectedCollection.name) }
        if filter != .todos { parts.append(filter.rawValue) }
        if showFavoritesOnly { parts.append("Favoritos") }
        return parts.isEmpty ? "Filtros activos" : parts.joined(separator: " · ")
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

    /// Contenido del popover que aparece una vez sobre el logo de Steam para indicar que, haciendo
    /// click en él, se abre el cliente de Steam. Se auto-oculta a los pocos segundos. Va dentro de un
    /// `.popover` nativo (se posiciona solo, con flecha, sin desbordar la sidebar).
    private var steamHintTooltip: some View {
        HStack(spacing: 11) {
            Image(systemName: "play.rectangle.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Abrir Steam").font(.callout.weight(.semibold))
                Text("Haz click en el logo para jugar desde Steam,\ncon la nube y los logros nativos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .presentationCompactAdaptation(.popover)
    }

    /// Logo de la tienda. En Steam es CLICKABLE (click izquierdo → abre el cliente de Steam para jugar
    /// desde ahí) y muestra una vez el tooltip que lo indica; en el resto, el logo normal.
    @ViewBuilder
    private var steamLogo: some View {
        if let onOpenSteam {
            Button { onOpenSteam() } label: {
                StoreLogoTile(store: store, size: 32)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .vesselHelp("Abrir Steam", detail: "Juega desde Steam con la nube y los logros nativos.")
            .popover(isPresented: $showSteamHint, arrowEdge: .bottom) {
                steamHintTooltip
            }
            .onAppear(perform: maybeShowSteamHint)
        } else {
            StoreLogoTile(store: store, size: 32)
        }
    }

    /// Muestra el tooltip de Steam brevemente al abrir la vista y lo oculta solo.
    private func maybeShowSteamHint() {
        guard onOpenSteam != nil, !steamHintDisplayed else { return }
        steamHintDisplayed = true
        // Retardo breve para que el logo esté montado antes de anclar el popover; se auto-oculta.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { showSteamHint = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { showSteamHint = false }
    }

    /// Cabecera compacta de la sidebar: logo (clickable en Steam → abre Steam) + nombre + contador + menú.
    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            steamLogo
            VStack(alignment: .leading, spacing: 1) {
                Text(store.displayName).font(.headline).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("\(games.count) juego\(games.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            Button { sidebarCollapsed = true } label: {
                Image(systemName: "sidebar.left").font(.body.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55)).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .vesselHelp("Ocultar la lista", shortcut: "⌘L")
            Menu {
                Button { onReload() } label: { Label("Actualizar biblioteca", systemImage: "arrow.clockwise") }
                Button { requestNewCollection() } label: {
                    Label("Nueva colección…", systemImage: "square.stack.3d.up.badge.plus")
                }
                if let onLogin {
                    Button { onLogin() } label: { Label("Iniciar sesión", systemImage: "person.crop.circle.badge.plus") }
                }
                if let onOpenSteam {
                    Button { onOpenSteam() } label: { Label("Abrir Steam (jugar desde Steam)", systemImage: "arrowshape.turn.up.forward") }
                }
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
            .vesselHelp("Opciones de \(store.displayName)", detail: "Actualiza la biblioteca o gestiona la sesión.")
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Buscar en \(store.displayName)…", text: $search)
                .textFieldStyle(.plain).font(.callout).focused($searchFocused)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Borrar búsqueda")
                .vesselHelp("Borrar búsqueda")
            }
        }
        .padding(8)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .vesselHelp("Buscar en \(store.displayName)",
                    detail: "Busca por título, fragmentos o abreviaturas; ignora tildes y signos.", shortcut: "⌘F")
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    /// Filtro (Todos/Instalados/Por instalar), orden y favoritos — compactos para la lista.
    private var filterBar: some View {
        HStack(spacing: 12) {
            filterMenu
            sortMenu
            Spacer()
            favoritesButton
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    /// Menú de filtro por estado (reutilizado por la sidebar y la cabecera del grid al colapsar).
    private var filterMenu: some View {
        Menu {
            Picker("Mostrar", selection: $filter) {
                ForEach(StoreLibraryFilter.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(filter.rawValue, systemImage: "line.3.horizontal.decrease")
                .font(.caption.weight(.medium))
                .foregroundStyle(filter == .todos ? .white.opacity(0.6) : tint)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Filtrar por estado")
        .vesselHelp("Filtrar juegos por estado")
    }

    /// Menú de orden (reutilizado por la sidebar y la cabecera del grid al colapsar).
    private var sortMenu: some View {
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
        .vesselHelp("Ordenar la biblioteca")
    }

    /// Botón de solo-favoritos (reutilizado).
    private var favoritesButton: some View {
        Button { showFavoritesOnly.toggle() } label: {
            Image(systemName: showFavoritesOnly ? "star.fill" : "star").font(.caption)
                .foregroundStyle(showFavoritesOnly ? .yellow : .white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showFavoritesOnly ? "Mostrar todos los juegos" : "Mostrar solo favoritos")
        .vesselHelp(showFavoritesOnly ? "Mostrar todos los juegos" : "Mostrar solo favoritos")
    }

    // MARK: - Controles en la cabecera del grid (visibles al colapsar la sidebar)

    /// Buscador compacto en la cabecera del grid (cuando la sidebar, y con ella su buscador, se ocultan).
    private var headerSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Buscar en \(store.displayName)…", text: $search)
                .textFieldStyle(.plain).font(.callout).frame(width: 180).focused($searchFocused)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Borrar búsqueda")
                .vesselHelp("Borrar búsqueda")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .liquidGlass(in: Capsule())
        .vesselHelp("Buscar en \(store.displayName)",
                    detail: "Busca por título, fragmentos o abreviaturas; ignora tildes y signos.", shortcut: "⌘F")
    }

    /// Filtro + favoritos en cristal, para la cabecera del grid al colapsar.
    private var headerFilterMenu: some View {
        HStack(spacing: 10) { filterMenu; favoritesButton }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .liquidGlass(in: Capsule())
    }

    /// Orden en cristal, para la cabecera del grid al colapsar.
    private var headerSortMenu: some View {
        sortMenu
            .padding(.horizontal, 12).padding(.vertical, 8)
            .liquidGlass(in: Capsule())
    }

    @ViewBuilder private var gameList: some View {
        if displayed.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: filter == .ocultos ? "eye.slash" : (showFavoritesOnly ? "star.slash" : "magnifyingglass"))
                    .font(.system(size: 30)).foregroundStyle(.white.opacity(0.25))
                Text(emptyStateTitle(compact: true))
                    .font(.caption).foregroundStyle(.secondary)
                if !search.isEmpty || filter != .todos || showFavoritesOnly {
                    Button("Mostrar todos", action: resetQuery)
                        .vesselButton(false, tint: tint)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Selección MANUAL (no el binding del List): así el resaltado es un cristal Liquid
            // Glass tintado (premium), no el azul sólido del sistema. Ver DESIGN.md §7.
            List {
                ForEach(displayed) { game in
                    Button { openGame(game) } label: {
                        StoreGameRow(game: game, tint: tint,
                                     isFavorite: isFav(game.id),
                                     isSelected: selectedGame?.id == game.id)
                    }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        .listRowBackground(Color.clear)
                        .accessibilityLabel(game.title)
                        .accessibilityValue(game.installed ? "Instalado" : "Sin instalar")
                        .accessibilityHint(game.installed
                            ? "Abre los detalles; haz doble clic para jugar"
                            : "Abre los detalles; haz doble clic para instalar")
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            performDoubleClickAction(for: game)
                        })
                        .draggable(LibraryGameDragPayload(storeID: store.rawValue, gameID: game.id))
                        .contextMenu { rowContextMenu(game) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .tint(tint)
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: displayed.count)
        }
    }

    @ViewBuilder private func rowContextMenu(_ game: StoreGame) -> some View {
        Button { openGame(game) } label: { Label("Ver detalles", systemImage: "info.circle") }
        if game.installed {
            Button { onPlay(game) } label: { Label("Jugar", systemImage: "play.fill") }
            if !installingIDs.contains(game.id) {
                Button { onUpdate(game) } label: {
                    Label(game.updateAvailable ? "Actualizar (disponible)" : "Actualizar",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                Button { onVerify(game) } label: { Label("Verificar / reparar", systemImage: "checkmark.shield") }
            }
            if let path = game.installPath, !path.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: { Label("Mostrar en Finder", systemImage: "folder") }
            }
            if let onExport {
                Button { onExport(game) } label: {
                    Label("Exportar juego…", systemImage: "externaldrive.badge.plus")
                }
            }
            Button(role: .destructive) { onUninstall(game) } label: { Label("Desinstalar", systemImage: "trash") }
        } else if !installingIDs.contains(game.id) {
            Button { onInstall(game) } label: { Label("Instalar", systemImage: "arrow.down.circle") }
        }
        Divider()
        if let url = game.steamStoreURL {
            Button { NSWorkspace.shared.open(url) } label: {
                Label("Ver en Steam", systemImage: "storefront")
            }
        }
        Button { copyGameTitle(game) } label: { Label("Copiar nombre", systemImage: "doc.on.doc") }
        Button { openNotes(for: game) } label: {
            Label(notesStore.hasNote(storeID: store.rawValue, gameID: game.id)
                  ? "Editar notas…" : "Añadir notas…", systemImage: "note.text")
        }
        collectionContextMenu(for: game)
        Button { toggleFav(game.id) } label: {
            Label(isFav(game.id) ? "Quitar de favoritos" : "Añadir a favoritos",
                  systemImage: isFav(game.id) ? "star.slash" : "star")
        }
        Button { toggleHidden(game.id) } label: {
            Label(isHidden(game.id) ? "Mostrar en la biblioteca" : "Ocultar de la biblioteca",
                  systemImage: isHidden(game.id) ? "eye" : "eye.slash")
        }
    }

    private func collectionContextMenu(for game: StoreGame) -> some View {
        Menu {
            ForEach(storeCollections) { collection in
                let included = collection.gameIDs.contains(game.id)
                Button { toggleCollection(collection.id, for: game) } label: {
                    Label(collection.name, systemImage: included ? "checkmark" : "square.stack.3d.up")
                }
            }
            if !storeCollections.isEmpty { Divider() }
            Button { requestNewCollection(including: game) } label: {
                Label("Nueva colección…", systemImage: "plus")
            }
        } label: {
            Label("Colecciones", systemImage: "square.stack.3d.up")
        }
    }

    // MARK: - Grid

    /// Segmentado premium (Liquid Glass) para elegir el tamaño de las carátulas. Estilo Steam.
    private var gridDensityToggle: some View {
        HStack(spacing: 2) {
            ForEach(GridDensity.allCases) { d in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { gridDensity = d }
                } label: {
                    Image(systemName: d.symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(gridDensity == d ? Color.white : .white.opacity(0.42))
                        .frame(width: 28, height: 22)
                        .background {
                            if gridDensity == d {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(tint.opacity(0.32))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .vesselHelp(d.help)
            }
        }
        .padding(3)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("Tamaño de las carátulas")
    }

    @ViewBuilder private var grid: some View {
        if displayed.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: filter == .ocultos ? "eye.slash" : (showFavoritesOnly ? "star.slash" : "magnifyingglass"))
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.30))
                Text(emptyStateTitle(compact: false))
                    .font(.callout).foregroundStyle(.secondary)
                if !search.isEmpty || filter != .todos || showFavoritesOnly {
                    Button {
                        resetQuery()
                    } label: {
                        Label("Mostrar todos los juegos", systemImage: "arrow.counterclockwise")
                    }
                    .vesselButton(false, tint: tint)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            LazyVGrid(columns: columns, spacing: Theme.Space.gameGrid) {
                ForEach(displayed) { game in
                    StoreGameCard(
                        game: game,
                        tint: tint,
                        isFavorite: isFav(game.id),
                        isHidden: isHidden(game.id),
                        installing: installingIDs.contains(game.id),
                        progress: progressFor(game.id),
                        percent: percentFor(game.id),
                        onInstall: { onInstall(game) },
                        onPlay: { onPlay(game) },
                        onToggleFavorite: { toggleFav(game.id) },
                        onToggleHidden: { toggleHidden(game.id) },
                        onUninstall: { onUninstall(game) },
                        onOpen: { openGame(game) },
                        collections: storeCollections,
                        collectionIDs: Set(storeCollections.filter { $0.gameIDs.contains(game.id) }.map(\.id)),
                        onToggleCollection: { toggleCollection($0, for: game) },
                        onCreateCollection: { requestNewCollection(including: game) },
                        onOpenNotes: { openNotes(for: game) },
                        onHoverChanged: { handleGridHover($0, game: game) },
                        onExport: onExport.map { cb in { cb(game) } }
                    )
                    .draggable(LibraryGameDragPayload(storeID: store.rawValue, gameID: game.id))
                    .anchorPreference(key: GameCardBoundsPreferenceKey.self, value: .bounds) {
                        [game.id: $0]
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: displayed.count)
            .animation(reduceMotion ? nil : .snappy(duration: 0.30), value: gridDensity)
        }
    }

    private func emptyStateTitle(compact: Bool) -> String {
        if let selectedCollection, search.isEmpty {
            return compact ? "Colección vacía." : "«\(selectedCollection.name)» todavía no tiene juegos."
        }
        if filter == .ocultos && search.isEmpty { return compact ? "No hay juegos ocultos." : "Tu biblioteca no tiene juegos ocultos." }
        if search.isEmpty && !showFavoritesOnly { return compact ? "Sin juegos." : "No hay juegos que mostrar." }
        return compact ? "Sin resultados." : "Sin resultados con los filtros actuales."
    }
}

// MARK: - Ámbito rápido de biblioteca

/// Cápsula de filtro con cristal neutro. La selección usa solo un velo y borde de acento,
/// respetando el contrato Liquid Glass de `DESIGN.md` sin convertir el cristal en un relleno plano.
private struct LibraryScopeChip: View {
    let title: String
    let symbol: String
    let count: Int?
    let selected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        let shape = Capsule(style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.medium))
                if let count {
                    Text(count, format: .number)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(selected ? 0.72 : 0.46))
                }
            }
            .foregroundStyle(selected ? Color.white : .white.opacity(0.68))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background {
                ZStack {
                    Color.clear.liquidGlass(in: shape, interactive: true)
                    if selected { shape.fill(tint.opacity(0.12)) }
                }
            }
            .overlay {
                shape.strokeBorder(tint.opacity(selected ? 0.45 : 0.10), lineWidth: 0.8)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .vesselHelp(count == nil ? "Quitar los filtros activos" : "Mostrar \(title.lowercased())")
    }

    private var accessibilityLabel: String {
        guard let count else { return "Quitar filtros: \(title)" }
        return "\(title), \(count) juego\(count == 1 ? "" : "s")"
    }
}

/// Menú de colecciones integrado en la scope bar. También es un destino de arrastre: al soltar
/// sobre una colección activa añade el juego; sobre el estado general inicia una colección nueva.
private struct LibraryCollectionScopeMenu: View {
    let collections: [LibraryCollectionsStore.Collection]
    let selectedID: UUID?
    let tint: Color
    let onSelect: (UUID) -> Void
    let onClear: () -> Void
    let onCreate: () -> Void
    let onRenameSelected: () -> Void
    let onDeleteSelected: () -> Void
    let onDropGame: (LibraryGameDragPayload) -> Bool
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: LibraryCollectionsStore.Collection? {
        collections.first { $0.id == selectedID }
    }

    var body: some View {
        let shape = Capsule(style: .continuous)
        Menu {
            if selectedID != nil {
                Button { onClear() } label: {
                    Label("Mostrar todos los juegos", systemImage: "square.grid.2x2")
                }
                Divider()
            }
            ForEach(collections) { collection in
                Button { onSelect(collection.id) } label: {
                    Label {
                        Text("\(collection.name)  \(collection.gameIDs.count)")
                    } icon: {
                        Image(systemName: selectedID == collection.id ? "checkmark" : "square.stack.3d.up")
                    }
                }
            }
            Divider()
            Button(action: onCreate) {
                Label("Nueva colección…", systemImage: "plus")
            }
            if selected != nil {
                Button(action: onRenameSelected) {
                    Label("Renombrar colección…", systemImage: "pencil")
                }
                Button(role: .destructive, action: onDeleteSelected) {
                    Label("Eliminar colección…", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.caption.weight(.semibold))
                Text(selected?.name ?? "Colecciones")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .leading)
                if let selected {
                    Text(selected.gameIDs.count, format: .number)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .foregroundStyle(selected == nil ? .white.opacity(0.68) : Color.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background {
                ZStack {
                    Color.clear.liquidGlass(in: shape, interactive: true)
                    if selected != nil || dropTargeted {
                        shape.fill(tint.opacity(dropTargeted ? 0.20 : 0.12))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    tint.opacity(dropTargeted ? 0.72 : (selected == nil ? 0.10 : 0.45)),
                    lineWidth: dropTargeted ? 1.2 : 0.8
                )
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(selected.map { "Colección \($0.name), \($0.gameIDs.count) juegos" } ?? "Colecciones")
        .vesselHelp(
            selected == nil ? "Mostrar colecciones" : "Colección: \(selected?.name ?? "")",
            detail: selected == nil
                ? "Crea o gestiona colecciones. Suelta aquí un juego para crear una nueva."
                : "Suelta aquí un juego para añadirlo a esta colección."
        )
        .dropDestination(for: LibraryGameDragPayload.self) { payloads, _ in
            payloads.contains(where: onDropGame)
        } isTargeted: { targeted in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) { dropTargeted = targeted }
        }
    }
}

// MARK: - Centro de descargas

/// Acceso efímero a las operaciones activas. Replica la utilidad de la barra inferior de Steam,
/// pero desaparece por completo cuando no hay trabajo para conservar la biblioteca despejada.
private struct LibraryTransferCenterButton: View {
    let items: [LibraryTransferItem]
    let games: [StoreGame]
    let tint: Color
    @Binding var isPresented: Bool
    let onOpen: (StoreGame) -> Void

    private var overallProgress: Double? {
        LibraryTransferSnapshot.overallProgress(for: items)
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                Text("Descargas")
                    .font(.caption.weight(.semibold))
                Text(items.count, format: .number)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                progressIndicator
            }
            .padding(.horizontal, 4)
        }
        .vesselButton(false, tint: tint)
        .accessibilityLabel("Descargas activas")
        .accessibilityValue(accessibilityValue)
        .vesselHelp(
            "Ver descargas activas",
            detail: "Muestra instalaciones, actualizaciones y verificaciones en curso."
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            LibraryTransferCenterPopover(items: items, games: games, tint: tint, onOpen: onOpen)
        }
    }

    @ViewBuilder private var progressIndicator: some View {
        if let overallProgress {
            ProgressView(value: overallProgress)
                .progressViewStyle(.linear)
                .tint(tint)
                .frame(width: 58)
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.mini)
                .tint(tint)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityValue: String {
        let count = "\(items.count) operación\(items.count == 1 ? "" : "es")"
        guard let overallProgress else { return "\(count), progreso indeterminado" }
        return "\(count), \(overallProgress.formatted(.percent.precision(.fractionLength(0)))) completado"
    }
}

private struct LibraryTransferCenterPopover: View {
    let items: [LibraryTransferItem]
    let games: [StoreGame]
    let tint: Color
    let onOpen: (StoreGame) -> Void

    private var gamesByID: [String: StoreGame] {
        Dictionary(games.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Descargas activas")
                        .font(.headline)
                    Text("\(items.count) operación\(items.count == 1 ? "" : "es") en curso")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider().opacity(0.14)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(items) { item in
                        if let game = gamesByID[item.id] {
                            LibraryTransferRow(item: item, game: game, tint: tint) {
                                onOpen(game)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 330)

            Divider().opacity(0.14)
            Label("El progreso se actualiza en tiempo real", systemImage: "bolt.horizontal.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
        }
        .frame(width: 400)
        .vesselBackground(tint: tint)
        .accessibilityElement(children: .contain)
    }

}

private struct LibraryTransferRow: View {
    let item: LibraryTransferItem
    let game: StoreGame
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                GameCoverImage(cacheKey: "transfer-\(game.id)", candidates: game.coverCandidates) {
                    ZStack {
                        game.placeholderColor
                        Text(game.initials)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 38, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(game.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let fraction = item.fractionCompleted {
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(tint)
                        }
                    }

                    Text(item.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let fraction = item.fractionCompleted {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(tint)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(tint)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                if hovering { shape.fill(.white.opacity(0.055)) }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(game.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Abre los detalles del juego")
    }

    private var accessibilityValue: String {
        guard let fraction = item.fractionCompleted else { return item.message }
        return "\(item.message), \(fraction.formatted(.percent.precision(.fractionLength(0)))) completado"
    }
}

/// Confirmación reversible para acciones que retiran contenido de la vista. El botón interior es
/// plano a propósito: el contenedor ya es cristal y DESIGN.md prohíbe apilar cristal sobre cristal.
private struct LibraryUndoBanner: View {
    let message: String
    let tint: Color
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash.fill")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Divider().frame(height: 18)
            Button("Deshacer", action: onUndo)
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .vesselHelp("Volver a mostrar el juego")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .liquidGlass(in: Capsule())
        .shadow(color: .black.opacity(0.34), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Tarjeta de juego genérica

/// Tarjeta de juego **genérica y premium** (carátula 2:3 + título superpuesto + favorito +
/// botón Instalar/Jugar). Misma para todas las tiendas; `tint` la colorea.
struct StoreGameCard: View {
    let game: StoreGame
    let tint: Color
    var isFavorite: Bool = false
    var isHidden: Bool = false
    var installing: Bool = false
    var progress: String? = nil
    var percent: Double? = nil
    var onInstall: () -> Void = {}
    var onPlay: () -> Void = {}
    var onToggleFavorite: () -> Void = {}
    var onToggleHidden: () -> Void = {}
    var onUninstall: () -> Void = {}
    var onOpen: () -> Void = {}
    var collections: [LibraryCollectionsStore.Collection] = []
    var collectionIDs: Set<UUID> = []
    var onToggleCollection: (UUID) -> Void = { _ in }
    var onCreateCollection: () -> Void = {}
    var onOpenNotes: () -> Void = {}
    var onHoverChanged: (Bool) -> Void = { _ in }
    /// Exportar (copiar a USB/disco). Si es `nil`, no se muestra la opción. Lo usa DRM‑free.
    var onExport: (() -> Void)? = nil

    // Reutilizan la lógica del modelo (sin duplicar): ver `StoreGame`.
    private var placeholderColor: Color { game.placeholderColor }
    private var initials: String { game.initials }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                coverArt
            }
            .buttonStyle(.plain)
            .accessibilityLabel(game.title)
            .accessibilityValue(accessibilityStatus)
            .accessibilityHint("Abre los detalles del juego")

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.callout).foregroundStyle(isFavorite ? .yellow : .white)
                    .padding(7)
                    .liquidGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .padding(7)
            .accessibilityLabel(isFavorite ? "Quitar de favoritos" : "Añadir a favoritos")
            .vesselHelp(isFavorite ? "Quitar de favoritos" : "Añadir a favoritos")
        }
            .overlay {
                if installing {
                    statusOverlay(progress ?? "Instalando…", spinner: percent == nil, percent: percent)
                        .allowsHitTesting(false)
                } else if GameLaunchTracker.shared.state(game.id) == .launching {
                    statusOverlay("Iniciando…", spinner: true)
                        .allowsHitTesting(false)
                } else if GameLaunchTracker.shared.state(game.id) == .running {
                    statusOverlay("Ejecutándose", spinner: false, icon: "play.circle.fill")
                        .allowsHitTesting(false)
                }
            }
            .hoverLift()
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
            .onHover(perform: onHoverChanged)
            .contextMenu {
                if game.installed {
                    Button { onPlay() } label: { Label("Jugar", systemImage: "play.fill") }
                    Button { onOpen() } label: { Label("Ver detalles", systemImage: "info.circle") }
                    if let path = game.installPath, !path.isEmpty {
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Label("Abrir carpeta", systemImage: "folder") }
                    }
                    if let onExport {
                        Button { onExport() } label: { Label("Exportar juego… (copiar a USB)", systemImage: "externaldrive.badge.plus") }
                    }
                    Divider()
                    Button(role: .destructive) { onUninstall() } label: { Label("Desinstalar", systemImage: "trash") }
                } else if !installing {
                    Button { onInstall() } label: { Label("Instalar", systemImage: "arrow.down.circle") }
                    Button { onOpen() } label: { Label("Ver detalles", systemImage: "info.circle") }
                }
                Divider()
                if let url = game.steamStoreURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("Ver en Steam", systemImage: "storefront")
                    }
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(game.title, forType: .string)
                } label: { Label("Copiar nombre", systemImage: "doc.on.doc") }
                Button(action: onOpenNotes) {
                    Label("Notas del juego…", systemImage: "note.text")
                }
                Menu {
                    ForEach(collections) { collection in
                        Button { onToggleCollection(collection.id) } label: {
                            Label(collection.name,
                                  systemImage: collectionIDs.contains(collection.id) ? "checkmark" : "square.stack.3d.up")
                        }
                    }
                    if !collections.isEmpty { Divider() }
                    Button(action: onCreateCollection) {
                        Label("Nueva colección…", systemImage: "plus")
                    }
                } label: {
                    Label("Colecciones", systemImage: "square.stack.3d.up")
                }
                Button { onToggleFavorite() } label: {
                    Label(isFavorite ? "Quitar de favoritos" : "Añadir a favoritos",
                          systemImage: isFavorite ? "star.slash" : "star")
                }
                Button { onToggleHidden() } label: {
                    Label(isHidden ? "Mostrar en la biblioteca" : "Ocultar de la biblioteca",
                          systemImage: isHidden ? "eye" : "eye.slash")
                }
            }
    }

    private var accessibilityStatus: String {
        if installing { return progress ?? "Instalando" }
        if game.updateAvailable { return "Actualización disponible" }
        return game.installed ? "Instalado" : "Sin instalar"
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
            .overlay(alignment: .topLeading) {
                if game.badge != nil || game.updateAvailable {
                    VStack(alignment: .leading, spacing: 6) {
                        if let badge = game.badge {
                            coverBadge(badge)
                        }
                        if game.updateAvailable {
                            Label("Actualizar", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .liquidGlass(in: Capsule())
                        }
                    }
                    .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.32), radius: 9, y: 5)
    }

    private func coverBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .liquidGlass(in: Capsule())
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
    var tint: Color = Theme.accent
    var isFavorite: Bool = false
    var isSelected: Bool = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            miniCover
                .frame(width: 30, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.callout).foregroundStyle(.white).lineLimit(1)
                Text(game.updateAvailable ? "Actualización disponible"
                                          : (game.installed ? "Instalado" : "Sin instalar"))
                    .font(.caption2)
                    .foregroundStyle(game.updateAvailable ? tint
                                     : (game.installed ? Color(red: 0.30, green: 0.85, blue: 0.55) : .white.opacity(0.4)))
            }
            Spacer(minLength: 0)
            if game.updateAvailable {
                Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(tint)
            }
            if isFavorite {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background { rowBackground }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Fondo de la fila: **cristal Liquid Glass tintado** si está seleccionada (premium, no el
    /// azul sólido del sistema); un velo sutil en hover; nada en reposo.
    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if isSelected {
            // Cristal NEUTRO + velo de color mínimo + borde tintado (premium), no azul sólido.
            ZStack {
                Color.clear.liquidGlass(in: shape)
                shape.fill(tint.opacity(0.12))
            }
            .overlay { shape.strokeBorder(tint.opacity(0.45), lineWidth: 0.8) }
        } else if hovering {
            shape.fill(.white.opacity(0.06))
        }
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

    /// Cascada de banners horizontales (el primero que cargue gana). Se sirve por `GameCoverImage`
    /// (caché memoria+disco) en vez de `AsyncImage`, que re-descargaba de red cada vez que el home
    /// se reconstruía → parpadeo gris. Así el banner es instantáneo, como las carátulas del grid.
    private var bannerCandidates: [URL] {
        var urls: [URL] = []
        if let appId = game.steamAppId, !appId.isEmpty,
           let u = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/header.jpg") { urls.append(u) }
        if let s = game.heroURL, let u = URL(string: s) { urls.append(u) }
        if let c = game.resolvedCoverURL { urls.append(c) }
        return urls
    }

    private var playtimeText: String? {
        guard let m = game.playtimeMinutes, m > 0 else { return nil }
        return m >= 60 ? "\(m / 60) h \(m % 60) min jugados" : "\(m) min jugados"
    }

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                GameCoverImage(cacheKey: "\(game.id)-banner", candidates: bannerCandidates) {
                    game.placeholderColor
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
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.32), radius: 8, y: 4)
        .hoverLift(scale: 1.02)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityLabel(game.title)
        .accessibilityValue(playtimeText ?? "Jugado recientemente")
        .accessibilityHint("Abre los detalles del juego")
    }
}

// MARK: - Ficha de juego (estilo Steam)

/// Alias conservado para la ficha existente. El modelo compartido reúne únicamente metadatos
/// públicos (descripción, géneros, capturas, vídeos, estudio, fecha y puntuaciones), nunca datos
/// personales. Ver `StoreGameMetadataService`.
typealias SteamGameDetails = StoreGameMetadata

/// Símbolos utilizados en las acciones de la ficha. Se mantienen centralizados para poder
/// comprobar su disponibilidad real en macOS y evitar botones vacíos si un nombre no existe.
enum GameDetailSymbols {
    static let note = "note.text"
    static let savedNoteBadge = "checkmark.circle.fill"
}

/// Un DLC resuelto (nombre + carátula) para mostrarlo en la ficha.
struct StoreDLC: Identifiable, Hashable {
    let id: String
    let title: String
    let coverURL: URL?
    /// ¿El usuario lo POSEE? Los que no, se atenúan para que no destaquen. `true` por defecto
    /// (o si no hay datos de sesión → no atenuar sin saber).
    var owned: Bool = true
}

/// Ficha de juego al estilo Steam: banner hero + botón Jugar/Instalar + tiempo jugado y
/// última sesión. Genérica para todas las tiendas (cada una pasa su color y sus datos).
enum GameDetailParallax {
    struct Metrics: Equatable {
        let overscan: CGFloat
        let offset: CGFloat
    }

    static func metrics(scrollY: CGFloat, reduceMotion: Bool) -> Metrics {
        guard !reduceMotion else { return Metrics(overscan: 0, offset: 0) }
        let overscan: CGFloat = 60
        let progress = min(max(-scrollY / 320, 0), 1)
        return Metrics(overscan: overscan, offset: (-overscan / 2) + (progress * 30))
    }
}

struct GameDetailView: View {
    let game: StoreGame
    let tint: Color
    var store: StoreKind = .steam
    var installing: Bool = false
    var progress: String? = nil
    var percent: Double? = nil
    var isFavorite: Bool = false
    var isHidden: Bool = false
    var onInstall: () -> Void = {}
    var onPlay: () -> Void = {}
    var onUninstall: () -> Void = {}
    var onVerify: () -> Void = {}
    var onUpdate: () -> Void = {}
    var onToggleFavorite: () -> Void = {}
    var onToggleHidden: () -> Void = {}
    var hasNote: Bool = false
    var onOpenNotes: () -> Void = {}
    var onBack: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingSettings = false
    @State private var details: SteamGameDetails?
    @State private var loadingDetails = false
    /// Índice de la captura abierta en el visor ampliado (nil = cerrado).
    @State private var lightboxIndex: Int?
    /// DLCs resueltos (nombre + carátula) del juego.
    @State private var dlcs: [StoreDLC] = []
    /// Estado REAL de logros (desbloqueado/bloqueado) del usuario, si hay credencial de Steam.
    @State private var achievements: SteamAchievementsService.Progress?
    /// Mostrar todos los logros (o solo un avance).
    @State private var showAllAchievements = false
    /// Observa la Web API key: si el usuario la pega en Ajustes con la ficha abierta, recargamos los
    /// logros para mostrar también los bloqueados (schema) sin tener que reabrir el juego.
    @AppStorage("steam.webApiKey") private var steamApiKeyObserver = ""
    private let steamGreen = Color(red: 0.34, green: 0.72, blue: 0.36)
    private let runningRed = Color(red: 0.85, green: 0.40, blue: 0.32)

    /// Perfil de compatibilidad del juego (para la sección de compatibilidad de la ficha).
    private var profile: CompatProfile? { CompatService.shared.profile(steam: game.steamAppId, title: game.title) }
    /// Tienda para el sistema de copias de partida.
    private var saveStore: SaveBackupManager.Store {
        switch store { case .steam: return .steam; case .epic: return .epic; case .gog: return .gog; case .local: return .local }
    }
    /// Identidad del juego para las copias (mismo criterio que los hooks de lanzamiento).
    private var saveId: String { game.steamAppId ?? game.id }
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
                if details?.screenshots.isEmpty == false || loadingDetails { mediaSection }
                content
            }
        }
        .vesselBackground(tint: tint)
        .overlay(alignment: .topLeading) { backButton }
        .overlay { if let idx = lightboxIndex { screenshotLightbox(idx) } }
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: lightboxIndex)
        .sheet(isPresented: $showingSettings) {
            GameSettingsView(game: game, tint: tint, installPath: game.installPath, store: store) {
                showingSettings = false
            }
        }
        .task(id: game.id) { await loadDetails() }
        .onChange(of: steamApiKeyObserver) { _, _ in
            if store == .steam, let appId = game.steamAppId, !appId.isEmpty {
                Task { await loadAchievements(appId) }
            }
        }
    }

    /// Visor de captura a tamaño grande (estilo Steam): fondo oscuro, imagen a resolución completa,
    /// navegación anterior/siguiente, contador y cierre. Reutilizable por las 3 tiendas.
    @ViewBuilder private func screenshotLightbox(_ idx: Int) -> some View {
        let full = details?.screenshotsFull ?? []
        let thumbs = details?.screenshots ?? []
        let count = max(full.count, thumbs.count)
        if count > 0, idx >= 0, idx < count {
            let url = idx < full.count ? full[idx] : (idx < thumbs.count ? thumbs[idx] : nil)
            ZStack {
                Rectangle().fill(.black.opacity(0.88)).ignoresSafeArea()
                    .onTapGesture { lightboxIndex = nil }
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFit() }
                    else if phase.error != nil { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.4)) }
                    else { ProgressView().tint(.white) }
                }
                .padding(.horizontal, 64).padding(.vertical, 48)
                .shadow(color: .black.opacity(0.6), radius: 24, y: 8)
                HStack {
                    lightboxArrow("chevron.left", enabled: idx > 0) { lightboxIndex = idx - 1 }
                    Spacer()
                    lightboxArrow("chevron.right", enabled: idx < count - 1) { lightboxIndex = idx + 1 }
                }
                .vesselGlassContainer(spacing: 12)
                .padding(.horizontal, 18)
                VStack {
                    HStack {
                        Text("\(idx + 1) / \(count)").font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 12).padding(.vertical, 6).liquidGlass(in: Capsule())
                        Spacer()
                        Button { lightboxIndex = nil } label: {
                            Image(systemName: "xmark").font(.body.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 38, height: 38).liquidGlass(in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cerrar visor")
                        .vesselHelp("Cerrar visor", shortcut: "Esc")
                    }
                    .vesselGlassContainer(spacing: 12)
                    .padding(20)
                    Spacer()
                }
            }
            .transition(.opacity)
        }
    }

    private func lightboxArrow(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2.weight(.bold)).foregroundStyle(.white)
                .frame(width: 46, height: 46).liquidGlass(in: Circle())
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : 0.25).disabled(!enabled)
        .accessibilityLabel(icon.contains("left") ? "Captura anterior" : "Captura siguiente")
        .vesselHelp(icon.contains("left") ? "Captura anterior" : "Captura siguiente")
    }

    private var hero: some View {
        GeometryReader { geo in
            let scrollY = geo.frame(in: .scrollView(axis: .vertical)).minY
            // La imagen tiene sobremuestreo vertical para desplazarse más despacio que la ficha sin
            // descubrir bordes. Título y degradado siguen el scroll normal: dos planos, como en la
            // cabecera de Steam. El recorrido es corto para conservar nitidez y evitar mareo.
            let parallax = GameDetailParallax.metrics(scrollY: scrollY, reduceMotion: reduceMotion)

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
                .frame(width: geo.size.width, height: 380 + parallax.overscan)
                .offset(y: parallax.offset)
                .clipped()
                LinearGradient(colors: [.clear, .clear, Theme.navyDeep], startPoint: .top, endPoint: .bottom)
                Text(game.title)
                    .font(.system(size: 36, weight: .heavy)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 8, y: 3)
                    .padding(.horizontal, 32).padding(.bottom, 18)
            }
            .clipped()
        }
        .frame(height: 380)
    }

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            expandedActionBar
            compactActionBar
        }
        .vesselGlassContainer(spacing: 12)
        .padding(.horizontal, 32).padding(.vertical, 18)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: launchState)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: installing)
    }

    /// En ventanas amplias conserva el acceso directo estilo Steam. Si el panel se estrecha, las
    /// acciones de gestión pasan a un menú nativo en vez de comprimirse o invadir el botón Jugar.
    private var expandedActionBar: some View {
        HStack(spacing: 20) {
            primaryButton
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) { activityStats }
                EmptyView()
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) { directGameActions }
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var compactActionBar: some View {
        HStack(spacing: 14) {
            primaryButton
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { activityStats }
                EmptyView()
            }
            Spacer(minLength: 0)
            gameActionsMenu
        }
    }

    @ViewBuilder private var activityStats: some View {
        stat("clock", "Última sesión", game.lastPlayed.map {
            $0.formatted(date: .abbreviated, time: .omitted)
        } ?? "—")
        stat("hourglass", "Tiempo de juego", playtimeText)
    }

    @ViewBuilder private var directGameActions: some View {
        if game.installed && !installing {
            iconButton("arrow.triangle.2.circlepath", label: "Actualizar",
                       tinted: game.updateAvailable, action: onUpdate)
            iconButton("checkmark.shield", label: "Verificar o reparar", action: onVerify)
        }
        if game.installed {
            iconButton("trash", label: "Desinstalar", action: onUninstall)
        }
        iconButton("gearshape.fill", label: "Ajustes del juego") { showingSettings = true }
        iconButton(GameDetailSymbols.note,
                   label: hasNote ? "Editar notas del juego" : "Añadir notas del juego",
                   tinted: hasNote,
                   accent: tint,
                   badgeIcon: hasNote ? GameDetailSymbols.savedNoteBadge : nil,
                   action: onOpenNotes)
        iconButton(isFavorite ? "heart.fill" : "heart",
                   label: isFavorite ? "Quitar de favoritos" : "Añadir a favoritos",
                   tinted: isFavorite, action: onToggleFavorite)
        iconButton(isHidden ? "eye" : "eye.slash",
                   label: isHidden ? "Mostrar en la biblioteca" : "Ocultar de la biblioteca",
                   action: onToggleHidden)
    }

    private var gameActionsMenu: some View {
        Menu {
            if game.installed && !installing {
                Button(action: onUpdate) {
                    Label(game.updateAvailable ? "Actualizar ahora" : "Buscar actualizaciones",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                Button(action: onVerify) {
                    Label("Verificar o reparar", systemImage: "checkmark.shield")
                }
            }
            if game.installed {
                Button(role: .destructive, action: onUninstall) {
                    Label("Desinstalar", systemImage: "trash")
                }
            }
            Divider()
            Button { showingSettings = true } label: {
                Label("Ajustes del juego", systemImage: "gearshape.fill")
            }
            Button(action: onOpenNotes) {
                Label(hasNote ? "Editar notas" : "Añadir notas", systemImage: GameDetailSymbols.note)
            }
            Divider()
            Button(action: onToggleFavorite) {
                Label(isFavorite ? "Quitar de favoritos" : "Añadir a favoritos",
                      systemImage: isFavorite ? "heart.slash" : "heart")
            }
            Button(action: onToggleHidden) {
                Label(isHidden ? "Mostrar en la biblioteca" : "Ocultar en la biblioteca",
                      systemImage: isHidden ? "eye" : "eye.slash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 38, height: 38)
                .liquidGlass(
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous),
                    interactive: true
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Más acciones del juego")
        .vesselHelp("Más acciones del juego", detail: "Actualizar, reparar, organizar o configurar este juego.")
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
            .vesselHelp("Preparando el juego y arrancando…")
        case .running:
            Button { GameLaunchTracker.shared.stop(game.id) } label: {
                Label("Ejecutándose", systemImage: "stop.fill")
                    .font(.title3.weight(.bold)).frame(minWidth: 170).frame(height: 28)
            }
            .vesselButton(tint: runningRed)
            .vesselHelp("Detener el juego", detail: "El juego está en ejecución. Pulsa para forzar su cierre.")
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
                .vesselHelp("Jugar a \(game.title)", shortcut: "⌘↩")
            } else {
                Button(action: onInstall) {
                    Label("Instalar", systemImage: "arrow.down.circle.fill")
                        .font(.title2.weight(.bold)).frame(minWidth: 170).frame(height: 28)
                }
                .vesselButton(tint: tint)
                .vesselHelp("Instalar \(game.title)", shortcut: "⌘↩")
            }
        }
    }

    // MARK: - Contenido de la ficha (descripción + compatibilidad + detalles)

    private var content: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 20) {
                aboutSection
                featuresSection
                achievementsSection
                dlcSection
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
                // Skeleton premium: líneas de texto con shimmer mientras llega la descripción.
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.white.opacity(0.10))
                            .frame(height: 11)
                            .frame(maxWidth: i == 2 ? 200 : .infinity, alignment: .leading)
                    }
                }
                .shimmering()
                .accessibilityLabel("Cargando descripción")
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
                        Text(g).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .liquidGlass(in: Capsule())
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// Carrusel de capturas (estilo Steam), a todo el ancho. Metadatos públicos del juego.
    @ViewBuilder private var mediaSection: some View {
        if (details?.screenshots ?? []).isEmpty, loadingDetails {
            // Skeleton premium: marcos de captura con shimmer mientras llegan las imágenes.
            VStack(alignment: .leading, spacing: 10) {
                Text("CAPTURAS").font(.caption.weight(.bold)).foregroundStyle(tint)
                    .padding(.horizontal, 32)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous)
                                .fill(.white.opacity(0.08))
                                .frame(width: 300, height: 169)
                        }
                    }
                    .padding(.horizontal, 32)
                }
                .shimmering()
            }
            .accessibilityLabel("Cargando capturas")
        } else if let shots = details?.screenshots, !shots.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("CAPTURAS").font(.caption.weight(.bold)).foregroundStyle(tint)
                    .padding(.horizontal, 32)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(shots.enumerated()), id: \.element) { idx, url in
                            Button { lightboxIndex = idx } label: {
                                AsyncImage(url: url) { phase in
                                    if let img = phase.image { img.resizable().scaledToFill() }
                                    else { Theme.surface }
                                }
                                .frame(width: 300, height: 169)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous)
                                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.caption2.weight(.bold)).foregroundStyle(.white)
                                        .padding(5).background(.black.opacity(0.45), in: Circle()).padding(8)
                                }
                                .shadow(color: .black.opacity(0.30), radius: 6, y: 3)
                                .hoverLift(scale: 1.02)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Ampliar captura \(idx + 1)")
                            .vesselHelp("Ampliar captura \(idx + 1)")
                        }
                    }
                    .padding(.horizontal, 32).padding(.vertical, 4)
                }
            }
            .padding(.bottom, 22)
        }
    }

    /// Características del juego (categorías de Steam) con iconos — paridad con la tienda.
    @ViewBuilder private var featuresSection: some View {
        if let cats = details?.categories, !cats.isEmpty {
            cardSection("Características") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 280), spacing: 10, alignment: .leading)],
                          alignment: .leading, spacing: 10) {
                    ForEach(Array(cats.prefix(12)), id: \.self) { c in
                        HStack(spacing: 9) {
                            Image(systemName: Self.categoryIcon(c)).font(.callout)
                                .foregroundStyle(tint).frame(width: 20)
                            Text(c).font(.caption).foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
            }
        }
    }

    /// Mapea una característica de Steam a un SF Symbol (por palabras clave, tolerante a idioma).
    private static func categoryIcon(_ desc: String) -> String {
        let d = desc.lowercased()
        if d.contains("un jugador") || d.contains("single") { return "person.fill" }
        if d.contains("cooper") || d.contains("co-op") || d.contains("coop") { return "person.3.fill" }
        if d.contains("multijugador") || d.contains("multi-player") || d.contains("multiplayer") || d.contains("pvp") { return "person.2.fill" }
        if d.contains("logro") || d.contains("achiev") { return "trophy.fill" }
        if d.contains("mando") || d.contains("controller") { return "gamecontroller.fill" }
        if d.contains("nube") || d.contains("cloud") { return "icloud.fill" }
        if d.contains("cromo") || d.contains("trading card") { return "rectangle.stack.fill" }
        if d.contains("remote play") || d.contains("juego remoto") || d.contains("remota") { return "tv.fill" }
        if d.contains("workshop") || d.contains("taller") { return "wrench.and.screwdriver.fill" }
        if d.contains("subtítul") || d.contains("caption") { return "captions.bubble.fill" }
        if d.contains("anti") && d.contains("cheat") { return "shield.fill" }
        if d.contains("hdr") { return "sun.max.fill" }
        return "checkmark.circle.fill"
    }

    /// Logros del juego (número + iconos destacados, datos públicos de Steam).
    @ViewBuilder private var achievementsSection: some View {
        if let prog = achievements, !prog.achievements.isEmpty {
            // Estado REAL: progreso desbloqueado/bloqueado + lista con iconos, rareza y fecha.
            cardSection("Logros") { realAchievements(prog) }
        } else if let total = details?.achievementsTotal, total > 0 {
            // Fallback decorativo (sin credencial de Steam): total + iconos destacados públicos.
            cardSection("Logros") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "trophy.fill").foregroundStyle(tint)
                        Text("\(total) logro\(total == 1 ? "" : "s")").font(.callout.weight(.semibold)).foregroundStyle(.white)
                    }
                    if let icons = details?.achievementIcons, !icons.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(icons, id: \.self) { url in
                                    AsyncImage(url: url) { phase in
                                        if let img = phase.image { img.resizable().scaledToFill() } else { Theme.surface }
                                    }
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                                }
                            }.padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    /// Vista de logros con estado REAL: barra de progreso + lista (desbloqueados primero) con icono,
    /// nombre, rareza y fecha de desbloqueo.
    @ViewBuilder private func realAchievements(_ prog: SteamAchievementsService.Progress) -> some View {
        let shown = showAllAchievements ? prog.achievements : Array(prog.achievements.prefix(6))
        VStack(alignment: .leading, spacing: 14) {
            if prog.stateKnown {
                HStack(spacing: 8) {
                    Image(systemName: "trophy.fill").foregroundStyle(tint)
                    Text("\(prog.unlocked) / \(prog.total) desbloqueados")
                        .font(.callout.weight(.semibold)).foregroundStyle(.white)
                    Spacer()
                    Text("\(Int((prog.fraction * 100).rounded()))%")
                        .font(.caption.weight(.semibold)).foregroundStyle(tint)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.10))
                        Capsule().fill(Theme.gradient(tint)).frame(width: max(6, geo.size.width * prog.fraction))
                    }
                }
                .frame(height: 7)
            } else {
                // No conocemos el estado (perfil privado / sin token). Mostramos la lista completa y
                // lo decimos con honestidad, con la vía para verlo.
                HStack(spacing: 8) {
                    Image(systemName: "trophy.fill").foregroundStyle(tint)
                    Text("\(prog.total) logro\(prog.total == 1 ? "" : "s")")
                        .font(.callout.weight(.semibold)).foregroundStyle(.white)
                    Spacer()
                }
                Label("Pon tu perfil de Steam en «Detalles del juego: Público» para ver cuáles tienes desbloqueados.",
                      systemImage: "eye.slash")
                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(shown) { ach in achievementRow(ach, stateKnown: prog.stateKnown) }
            }
            if prog.achievements.count > 6 {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                        showAllAchievements.toggle()
                    }
                } label: {
                    Text(showAllAchievements ? "Ver menos" : "Ver los \(prog.achievements.count) logros")
                        .font(.caption.weight(.semibold)).foregroundStyle(tint)
                }
                .buttonStyle(.plain)
            }
            // Si solo tenemos el detalle de los desbloqueados (login sin Web API key), indicamos los
            // bloqueados restantes y cómo verlos todos.
            if prog.stateKnown, prog.achievements.count < prog.total {
                Label("Y \(prog.total - prog.achievements.count) logros por desbloquear. Añade tu Web API key en Ajustes para ver también los bloqueados con sus iconos.",
                      systemImage: "lock")
                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Fila de un logro: icono, nombre, rareza y —si conocemos el estado— desbloqueado/bloqueado.
    private func achievementRow(_ ach: SteamAchievementsService.Achievement, stateKnown: Bool) -> some View {
        let dimmed = stateKnown && !ach.unlocked
        return HStack(spacing: 12) {
            achievementIcon(ach, stateKnown: stateKnown)
            VStack(alignment: .leading, spacing: 2) {
                Text(ach.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(dimmed ? .white.opacity(0.55) : .white)
                    .lineLimit(1)
                if !ach.description.isEmpty {
                    Text(ach.description).font(.caption2).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if stateKnown {
                    if ach.unlocked {
                        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(steamGreen)
                        if let d = ach.unlockTime {
                            Text(d.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.white.opacity(0.4))
                        }
                    } else {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.white.opacity(0.35))
                    }
                }
                if let p = ach.globalPercent {
                    Text(rarityLabel(p)).font(.caption2).foregroundStyle(rarityColor(p))
                }
            }
        }
        .opacity(dimmed ? 0.82 : 1)
    }

    /// Icono del logro: imagen del schema (color si está desbloqueado o si no conocemos el estado;
    /// en gris si sabemos que está bloqueado) o un emblema con glifo cuando no hay icono (sin key).
    @ViewBuilder private func achievementIcon(_ ach: SteamAchievementsService.Achievement, stateKnown: Bool) -> some View {
        let showColor = ach.unlocked || !stateKnown
        let url = showColor ? (ach.iconUnlocked ?? ach.iconLocked) : (ach.iconLocked ?? ach.iconUnlocked)
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { Color.white.opacity(0.06) }
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(showColor ? 0.30 : 0.10))
                    Image(systemName: showColor ? "trophy.fill" : "lock.fill")
                        .font(.system(size: 16)).foregroundStyle(showColor ? tint : .white.opacity(0.4))
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .saturation(showColor ? 1 : 0)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }

    /// Etiqueta de rareza según el % global de jugadores que lo tienen.
    private func rarityLabel(_ percent: Double) -> String {
        let p = (percent * 10).rounded() / 10
        if percent < 5 { return "Ultra raro · \(p)%" }
        if percent < 20 { return "Raro · \(p)%" }
        return "\(p)%"
    }
    private func rarityColor(_ percent: Double) -> Color {
        if percent < 5 { return Color(red: 1.0, green: 0.72, blue: 0.30) }   // ámbar (muy raro)
        if percent < 20 { return tint }
        return .white.opacity(0.4)
    }

    /// Contenido descargable (DLC) del juego, con carátula y nombre. Los DLC que el usuario
    /// posee se descargan junto al juego (SteamCMD), por eso es informativo.
    @ViewBuilder private var dlcSection: some View {
        if !dlcs.isEmpty {
            cardSection("Contenido descargable (\(dlcs.count))") {
                VStack(spacing: 9) {
                    ForEach(dlcs) { dlc in
                        HStack(spacing: 10) {
                            AsyncImage(url: dlc.coverURL) { phase in
                                if let img = phase.image { img.resizable().scaledToFill() } else { Theme.surface }
                            }
                            .frame(width: 66, height: 25)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .saturation(dlc.owned ? 1 : 0.1)   // los no poseídos, apagados
                            Text(dlc.title).font(.caption)
                                .foregroundStyle(.white.opacity(dlc.owned ? 0.85 : 0.5)).lineLimit(1)
                            Spacer(minLength: 0)
                            if dlc.owned {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2).foregroundStyle(steamGreen.opacity(0.9))
                            }
                        }
                        .opacity(dlc.owned ? 1 : 0.5)   // atenúa el que no tienes para que no destaque
                    }
                    Text(store == .epic ? "Contenido adicional disponible para este juego."
                                        : "Los DLC marcados (✓) están en tu cuenta y se instalan junto al juego.")
                        .font(.caption2).foregroundStyle(.white.opacity(0.45)).padding(.top, 2)
                }
            }
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
                if let url = game.protonDBURL {
                    Divider().overlay(.white.opacity(0.06)).padding(.vertical, 2)
                    Link(destination: url) {
                        Label("Ver informes en ProtonDB", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tint)
                    .vesselHelp("Abrir los informes comunitarios de compatibilidad en ProtonDB")
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
                if let rc = details?.reviewCount, rc > 0 { detailRow("Reseñas en Steam", rc.formatted()) }
                if let appId = game.steamAppId, !appId.isEmpty { detailRow("Steam AppID", appId) }
                detailRow("Última sesión", game.lastPlayed.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                detailRow("Tiempo de juego", playtimeText)
                if let last = SaveBackupManager.shared.lastBackupDate(store: saveStore, id: saveId) {
                    detailRow("Copia de partida", last.formatted(date: .abbreviated, time: .shortened), valueColor: steamGreen)
                }
                if let url = game.steamStoreURL {
                    Divider().overlay(.white.opacity(0.06)).padding(.vertical, 4)
                    Link(destination: url) {
                        Label("Ver en Steam", systemImage: "storefront")
                            .font(.caption).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tint)
                    .vesselHelp("Abrir la página del juego en Steam")
                }
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
        details = nil; dlcs = []; achievements = nil
        if let appId = game.steamAppId, !appId.isEmpty {
            await loadSteamDetails(appId)
            await loadAchievements(appId)
        } else if store == .gog {
            await loadGogDetails(game.id)
        } else if store == .epic {
            await loadEpicDetails(game.id)
        }
    }

    /// Estado REAL de logros (desbloqueado/bloqueado) del juego de Steam para el usuario logueado.
    /// No bloquea la ficha (va tras los `details`). Si no hay credencial/datos, deja la sección con
    /// su vista decorativa (total + iconos destacados). Ver `SteamAchievementsService`.
    @MainActor private func loadAchievements(_ appId: String) async {
        guard store == .steam else { return }
        let id = SteamAccountService.currentSteamID64
        guard !id.isEmpty else { return }
        achievements = await SteamAchievementsService.shared.fetch(appId: appId, steamID64: id)
    }

    /// Enriquece la ficha de un juego de **Epic** leyendo la metadata que legendary ya cachea
    /// (`Epic/metadata/<app>.json`): descripción, desarrollador y capturas (keyImages `Screenshot`).
    /// Sin lanzar procesos. Paridad de ficha también en Epic con lo que su backend ofrece.
    @MainActor private func loadEpicDetails(_ appName: String) async {
        // `loadingDetails` mientras se enriquece con Steam (capturas) → muestra el skeleton premium.
        loadingDetails = true
        defer { loadingDetails = false }
        // legendary cachea la metadata en su LEGENDARY_CONFIG_PATH (= LegendaryManager.configDir),
        // NO en un directorio "Epic". Usar la constante real evita el desajuste que dejaba la ficha
        // de Epic sin descripción.
        let path = "\(LegendaryManager.configDir)/metadata/\(appName).json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let md = obj["metadata"] as? [String: Any] else { return }
        var det = SteamGameDetails()
        if let desc = md["description"] as? String, !desc.isEmpty { det.description = Self.stripHTML(desc) }
        if let dev = md["developer"] as? String, !dev.isEmpty { det.developers = [dev] }
        let images = (md["keyImages"] as? [[String: Any]]) ?? []
        let shots = images.filter { ($0["type"] as? String) == "Screenshot" }.prefix(12)
            .compactMap { ($0["url"] as? String).flatMap { URL(string: $0) } }
        det.screenshots = shots
        det.screenshotsFull = shots
        details = det
        // DLC de Epic (de la propia metadata): nombre + carátula.
        if let dlcList = md["dlcItemList"] as? [[String: Any]] {
            dlcs = dlcList.prefix(20).compactMap { dlc in
                guard let title = dlc["title"] as? String, !title.isEmpty else { return nil }
                let imgs = (dlc["keyImages"] as? [[String: Any]]) ?? []
                let cover = (imgs.first { ($0["type"] as? String)?.contains("Tall") == true }?["url"] as? String)
                    ?? (imgs.first?["url"] as? String)
                return StoreDLC(id: (dlc["id"] as? String) ?? title, title: title, coverURL: cover.flatMap { URL(string: $0) })
            }
        }
        // Enriquecimiento PREMIUM (paridad con Steam/GOG): Epic no expone capturas ni descripción
        // larga por su backend (ni Heroic las tiene). La mayoría de juegos de Epic están también en
        // Steam, así que buscamos el MISMO juego por título (API pública de Steam, gratis, sin clave)
        // y tomamos sus CAPTURAS reales + descripción rica, manteniendo DLCs y estudio de Epic. Solo
        // se aplica si el título coincide de forma estricta (no confunde juegos distintos).
        if det.screenshots.isEmpty,
           let steamId = await Self.steamAppId(forTitle: game.title),
           let sd = await Self.fetchSteamDetails(appId: steamId) {
            var merged = details ?? det
            if !sd.screenshots.isEmpty {
                merged.screenshots = sd.screenshots
                merged.screenshotsFull = sd.screenshotsFull
            }
            if let sdesc = sd.description, sdesc.count > (merged.description?.count ?? 0) {
                merged.description = sdesc
            }
            if merged.genres.isEmpty { merged.genres = sd.genres }
            if merged.developers.isEmpty { merged.developers = sd.developers }
            details = merged
        }
    }

    /// Enriquece la ficha de un juego de **GOG** con su API pública (descripción + capturas).
    /// Reutiliza el visor y las secciones comunes — paridad visual también en GOG.
    @MainActor private func loadGogDetails(_ id: String) async {
        loadingDetails = true
        defer { loadingDetails = false }
        details = await StoreGameMetadataService.shared.gogDetails(productID: id, title: game.title)
    }

    /// Enriquece la ficha de un juego de **Steam** con la API pública `appdetails`.
    @MainActor private func loadSteamDetails(_ appId: String) async {
        loadingDetails = true
        defer { loadingDetails = false }
        guard let det = await Self.fetchSteamDetails(appId: appId) else { return }
        details = det
        await loadDLCs(det.dlcIds)
    }

    /// Descarga y parsea los detalles públicos de un juego de Steam (`appdetails`): descripción,
    /// desarrolladores, géneros, logros, DLCs y CAPTURAS reales. Reutilizable como fuente de
    /// enriquecimiento para Epic (que no expone capturas por su backend). Sin clave ni auth.
    static func fetchSteamDetails(appId: String) async -> SteamGameDetails? {
        await StoreGameMetadataService.shared.steamDetails(appId: appId)
    }

    /// Busca en Steam el `appid` de un juego por su título (API pública `storesearch`, sin clave).
    /// Solo devuelve un match si el nombre coincide de forma estricta (normalizado) — evita
    /// enriquecer un juego de Epic con capturas de otro juego distinto de nombre parecido.
    static func steamAppId(forTitle title: String) async -> String? {
        await StoreGameMetadataService.shared.steamAppId(matching: title)
    }

    /// Normaliza un título para comparar: minúsculas, sin ™®©, sin puntuación, sin sufijos de
    /// edición y sin espacios (así "Layers of Fear" == "Layers of Fear™").
    static func normalizedTitle(_ s: String) -> String {
        StoreGameMetadataService.normalizedTitle(s)
    }

    /// Resuelve nombre + carátula de los primeros DLC (datos públicos de Steam, en paralelo).
    @MainActor private func loadDLCs(_ ids: [Int]) async {
        dlcs = []
        guard !ids.isEmpty else { return }
        // Qué DLC posee el usuario (juegos+DLC de rgOwnedApps vía la sesión web). Vacío = sin datos
        // → no atenuamos (no sabemos). Se hace UNA vez para todos los DLC.
        let ownedApps = await SteamWebSession.shared.ownedAppIDs()
        let resolved = await withTaskGroup(of: StoreDLC?.self) { group -> [StoreDLC] in
            for id in ids.prefix(12) {
                group.addTask {
                    guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(id)&filters=basic&l=spanish"),
                          let (data, _) = try? await URLSession.shared.data(from: url),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let entry = obj["\(id)"] as? [String: Any],
                          (entry["success"] as? Bool) == true,
                          let d = entry["data"] as? [String: Any],
                          let name = d["name"] as? String else { return nil }
                    // La carátula: `header_image` REAL de appdetails (muchos DLC —packs de armadura,
                    // sombreros— NO tienen `capsule_231x87.jpg` → daba 404 y salía el hueco). Con el
                    // header_image cargan todos. Fallback al capsule por si acaso.
                    let cover = (d["header_image"] as? String).flatMap { URL(string: $0) }
                        ?? URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/capsule_231x87.jpg")
                    let owned = ownedApps.isEmpty || ownedApps.contains(id)
                    return StoreDLC(id: "\(id)", title: name, coverURL: cover, owned: owned)
                }
            }
            var out: [StoreDLC] = []
            for await dlc in group { if let dlc { out.append(dlc) } }
            return out
        }
        // Poseídos primero; dentro de cada grupo, por nombre. Los no poseídos se atenúan (abajo).
        dlcs = resolved.sorted {
            if $0.owned != $1.owned { return $0.owned }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
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
        .accessibilityLabel("Atrás")
        .vesselHelp("Atrás", detail: "Vuelve al juego o a la biblioteca anterior.", shortcut: "⌘[")
    }

    private func stat(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.white.opacity(0.4))
            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased()).font(.caption2).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                Text(value).font(.callout.weight(.medium)).foregroundStyle(.white).lineLimit(1)
            }
        }
        .fixedSize()   // ancho natural: nunca parte el texto por carácter
    }

    private func iconButton(_ icon: String, label: String, tinted: Bool = false,
                            accent: Color = .pink, badgeIcon: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(tinted ? accent : .white.opacity(0.7))
                if let badgeIcon {
                    Image(systemName: badgeIcon)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(accent)
                        .offset(x: 5, y: -5)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 38, height: 38)
            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .vesselHelp(label)
    }
}
