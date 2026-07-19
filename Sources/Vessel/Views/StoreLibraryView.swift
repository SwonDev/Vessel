import SwiftUI
import AppKit
import DockProgress

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
    var executablePath: String? = nil // ejecutable detectado; permite un override avanzado seguro
    var installSizeBytes: Int64? = nil
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

/// Resuelve el valor que debe consumir una ficha ya abierta cuando la tienda publica una versión
/// nueva de su biblioteca. Se mantiene como regla pura para cubrir las transiciones de instalación
/// sin depender de cambiar de selección ni de una ventana SwiftUI.
enum StoreGameStateResolver {
    static func currentSelection(selected: StoreGame?, availableGames: [StoreGame]) -> StoreGame? {
        guard let selected else { return nil }
        return availableGames.first(where: { $0.id == selected.id }) ?? selected
    }
}

enum StoreSortOrder: String, CaseIterable, Identifiable {
    case nombre = "Nombre"
    case recientes = "Recientes"
    case masJugado = "Más jugado"
    case metacritic = "Metacritic"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .nombre:    return "textformat"
        case .recientes: return "clock"
        case .masJugado: return "hourglass"
        case .metacritic: return "star.leadinghalf.filled"
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

enum LibraryCompatibilityFilter: String, CaseIterable, Identifiable {
    case cualquiera = "Cualquiera"
    case excelente = "Excelente"
    case jugable = "Jugable"
    case noFunciona = "No funciona"
    case sinDatos = "Sin datos"
    var id: String { rawValue }

    func matches(_ rating: CompatProfile.Rating?) -> Bool {
        switch self {
        case .cualquiera: return true
        case .excelente: return rating == .platinum || rating == .gold
        case .jugable: return rating == .silver || rating == .bronze
        case .noFunciona: return rating == .borked
        case .sinDatos: return rating == nil
        }
    }
}

enum LibrarySizeFilter: String, CaseIterable, Identifiable {
    case cualquiera = "Cualquier tamaño"
    case pequeño = "Menos de 10 GB"
    case mediano = "De 10 a 50 GB"
    case grande = "Más de 50 GB"
    case sinDatos = "Tamaño desconocido"
    var id: String { rawValue }

    func matches(_ bytes: Int64?) -> Bool {
        let tenGB: Int64 = 10 * 1_000_000_000
        let fiftyGB: Int64 = 50 * 1_000_000_000
        switch self {
        case .cualquiera: return true
        case .pequeño: return bytes.map { $0 < tenGB } ?? false
        case .mediano: return bytes.map { $0 >= tenGB && $0 <= fiftyGB } ?? false
        case .grande: return bytes.map { $0 > fiftyGB } ?? false
        case .sinDatos: return bytes == nil
        }
    }
}

enum LibraryAdvancedFilterRules {
    static func matchesGenre(_ genres: [String], selected: String?) -> Bool {
        guard let selected else { return true }
        return genres.contains { $0.localizedCaseInsensitiveCompare(selected) == .orderedSame }
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
    /// Sustitución determinista solo para el escenario Debug de revisión visual.
    var activityEventsOverride: [LibraryActivityStore.Event]? = nil
    /// Punto de entrada opcional para deep links y escenarios de revisión. La navegación normal
    /// conserva su selección persistida; cuando se proporciona, no sobrescribe esa preferencia.
    var initiallySelectedGameID: String? = nil
    var installingIDs: Set<String> = []
    var progressFor: (String) -> String? = { _ in nil }
    /// Progreso de descarga 0.0–1.0 si se conoce (Steam vía SteamCMD). `nil` = indeterminado
    /// (spinner): Epic/GOG o fases de verificación. Pinta una barra estilo Steam cuando hay %.
    var percentFor: (String) -> Double? = { _ in nil }
    var transferTitleFor: (String) -> String? = { _ in nil }
    var transferPhaseFor: (String) -> LibraryTransferPhase = { _ in .running }
    var transferPositionFor: (String) -> Int? = { _ in nil }
    var canPauseTransfer: (String) -> Bool = { _ in false }
    var canCancelTransfer: (String) -> Bool = { _ in false }
    var canPrioritizeTransfer: (String) -> Bool = { _ in false }
    var canRetryTransfer: (String) -> Bool = { _ in false }
    var onPauseTransfer: ((StoreGame) -> Void)? = nil
    var onResumeTransfer: ((StoreGame) -> Void)? = nil
    var onCancelTransfer: ((StoreGame) -> Void)? = nil
    var onPrioritizeTransfer: ((StoreGame) -> Void)? = nil
    var onRetryTransfer: ((StoreGame) -> Void)? = nil
    var onInstall: (StoreGame) -> Void = { _ in }
    var onPlay: (StoreGame) -> Void = { _ in }
    var onUninstall: (StoreGame) -> Void = { _ in }
    /// Verificar/reparar integridad de un juego instalado (re-descarga lo dañado). Reusa el
    /// feedback de instalación (`installingIDs`/`progressFor`/`percentFor`).
    var onVerify: (StoreGame) -> Void = { _ in }
    /// Aplicar la actualización de un juego instalado (mismo feedback que instalar/verificar).
    var onUpdate: (StoreGame) -> Void = { _ in }
    /// Encola todas las actualizaciones disponibles en el orden visible de la biblioteca.
    var onUpdateAll: (([StoreGame]) -> Void)? = nil
    /// Contenido adicional propio de la tienda. Steam conserva su fuente pública interna; GOG
    /// aporta aquí sus DLC reales y su estado de instalación mediante gogdl.
    var dlcsFor: @MainActor (StoreGame) async -> [StoreDLC] = { _ in [] }
    var onInstallDLC: ((StoreGame, StoreDLC) -> Void)? = nil
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
    /// Estado de carga EXTERNO de la biblioteca, aportado por la tienda dueña (Steam). Mientras
    /// carga por primera vez se muestra un indicador real en vez del falso vacío; si falla,
    /// un error con reintento. Por defecto inactivo (Epic/GOG/DRM-free no cambian nada).
    var externalLibraryLoading = false
    var externalLibraryError: String? = nil
    var onRetryLibraryLoad: () -> Void = { }

    @State private var search = ""
    /// Foco del buscador (para el atajo ⌘F). Se aplica a ambos buscadores (sidebar y cabecera);
    /// solo enfoca el visible.
    @FocusState private var searchFocused: Bool
    @State private var sortOrder: StoreSortOrder = .nombre
    @State private var filter: StoreLibraryFilter = .todos
    @State private var compatibilityFilter: LibraryCompatibilityFilter = .cualquiera
    @State private var sizeFilter: LibrarySizeFilter = .cualquiera
    @State private var selectedGenre: String?
    @State private var indexedMetadata: [String: StoreGameMetadata] = [:]
    @State private var metadataIndexProgress: (completed: Int, total: Int)?
    @State private var metadataIndexTask: Task<Void, Never>?
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
    @State private var activityStore = LibraryActivityStore.shared
    @State private var selectedCollectionID: UUID?
    @State private var collectionEditorRequest: CollectionEditorRequest?
    @State private var collectionPendingDeletion: LibraryCollectionsStore.Collection?
    @State private var gamePendingUninstall: StoreGame?
    @State private var logoutConfirmationPresented = false
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
    /// Origen del hover que abrió el panel (grid o fila de la sidebar): sin él, al compartir
    /// `previewedGame` entre ambos overlays un juego con carátula Y fila visibles mostraba el
    /// panel DUPLICADO (uno por cada ancla). Cada overlay solo se pinta para su origen.
    @State private var previewOriginRow = false
    @State private var hoverPresentationTask: Task<Void, Never>?
    /// Elemento alineado en la estantería reciente para conservar snapping y navegación por teclado.
    @State private var recentlyPlayedScrollID: String?
    /// Tooltip de "Abrir Steam" sobre el logo: se muestra una vez y se auto-oculta.
    @State private var showSteamHint = false
    /// Task cancelable del auto-ocultado del hint de Steam (reemplaza al asyncAfter sin cancelación).
    @State private var steamHintTask: Task<Void, Never>?
    /// Carátula a la que volver al salir de una ficha (restauración del scroll del home).
    @State private var gridScrollID: String?
    /// Último juego cuya ficha se abrió; al volver al home se usa como ancla de scroll.
    @State private var lastDetailGameID: String?
    @State private var steamHintDisplayed = false
    /// Geometría compartida entre la carátula de la portada y el hero de la ficha. Al vivir en el
    /// coordinador común, la continuidad funciona igual en Steam, Epic, GOG y DRM-free.
    @Namespace private var gameDetailTransitionNamespace
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
            percentFor: percentFor,
            titleFor: transferTitleFor,
            phaseFor: transferPhaseFor,
            positionFor: transferPositionFor,
            canPauseFor: canPauseTransfer,
            canCancelFor: canCancelTransfer,
            canPrioritizeFor: canPrioritizeTransfer,
            canRetryFor: canRetryTransfer
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
        recomputeDerivedCaches()
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
        recomputeDerivedCaches()
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
        guard selectedCollectionID == nil, !advancedFiltersActive else { return nil }
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
        compatibilityFilter = .cualquiera
        sizeFilter = .cualquiera
        selectedGenre = nil
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
        if let raw = defaults.string(forKey: "\(preferencePrefix).compatibility"),
           let stored = LibraryCompatibilityFilter(rawValue: raw) {
            compatibilityFilter = stored
        }
        if let raw = defaults.string(forKey: "\(preferencePrefix).size"),
           let stored = LibrarySizeFilter(rawValue: raw) {
            sizeFilter = stored
        }
        selectedGenre = defaults.string(forKey: "\(preferencePrefix).genre")
        showFavoritesOnly = defaults.bool(forKey: "\(preferencePrefix).favoritesOnly")
        if let raw = defaults.string(forKey: "\(preferencePrefix).collection"),
           let id = UUID(uuidString: raw), collectionsStore.collection(id: id) != nil {
            selectedCollectionID = id
        }
        if let initiallySelectedGameID,
           let game = games.first(where: { $0.id == initiallySelectedGameID }),
           !isHidden(initiallySelectedGameID) {
            selectedGame = enrichedGame(game)
        } else if let gameID = defaults.string(forKey: selectionKey),
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
        defaults.set(compatibilityFilter.rawValue, forKey: "\(preferencePrefix).compatibility")
        defaults.set(sizeFilter.rawValue, forKey: "\(preferencePrefix).size")
        if let selectedGenre {
            defaults.set(selectedGenre, forKey: "\(preferencePrefix).genre")
        } else {
            defaults.removeObject(forKey: "\(preferencePrefix).genre")
        }
        defaults.set(showFavoritesOnly, forKey: "\(preferencePrefix).favoritesOnly")
        if let selectedCollectionID {
            defaults.set(selectedCollectionID.uuidString, forKey: "\(preferencePrefix).collection")
        } else {
            defaults.removeObject(forKey: "\(preferencePrefix).collection")
        }
    }

    private func persistSelectedGame() {
        guard initiallySelectedGameID == nil else { return }
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

    /// Cachés derivadas de la biblioteca, memoizadas: antes `enriched` mapeaba ~1.750 juegos en
    /// CADA acceso (varios por render), la scope bar hacía 5 recorridos O(n) por render y
    /// "recientes" ordenaba por evaluación. Se recalculan solo cuando cambian sus entradas:
    /// `games`, las estadísticas de juego, favoritos u ocultos. Comportamiento idéntico.
    @State private var enrichedCache: [StoreGame] = []
    @State private var scopeCountsCache: [LibraryQuickScope: Int] = [:]
    @State private var recentlyPlayedCache: [StoreGame] = []

    private var enriched: [StoreGame] {
        enrichedCache.isEmpty && !games.isEmpty ? games.map(enrichedGame) : enrichedCache
    }

    private func recomputeDerivedCaches() {
        enrichedCache = games.map(enrichedGame)
        let visible = enrichedCache.filter { !isHidden($0.id) }
        scopeCountsCache = [
            .todos: visible.count,
            .listos: visible.count(where: \.installed),
            .actualizaciones: visible.count(where: \.updateAvailable),
            .sinJugar: visible.count { $0.lastPlayed == nil && ($0.playtimeMinutes ?? 0) == 0 },
            .favoritos: visible.count { favorites.contains($0.id) }
        ]
        recentlyPlayedCache = Array(enrichedCache
            .filter { $0.lastPlayed != nil && !isHidden($0.id) }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(8))
    }

    /// Resuelve la versión más reciente del seleccionado, porque instalar/actualizar puede cambiar
    /// el modelo mientras su ficha sigue abierta.
    private var currentSelectedGame: StoreGame? {
        guard let current = StoreGameStateResolver.currentSelection(
            selected: selectedGame,
            availableGames: games
        ) else { return nil }
        return enrichedGame(current)
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

    private var metadataRequests: [StoreGameMetadataRequest] {
        let source: StoreGameMetadataRequest.Source = switch store {
        case .steam: .steam
        case .epic: .epic
        case .gog: .gog
        case .local: .local
        }
        return games.map {
            StoreGameMetadataRequest(source: source, id: $0.id,
                                     title: $0.title, steamAppId: $0.steamAppId)
        }
    }

    /// Indexa la biblioteca en Spotlight (⌘Espacio del sistema). La función propia (en vez de una
    /// expresión inline) mantiene al type-checker de SwiftUI dentro de su presupuesto.
    private func indexLibraryForSpotlight() {
        let items: [(String, String, String)] = games.map { ($0.id, $0.title, $0.id) }
        SpotlightIndexService.shared.reindex(store: store, games: items)
    }

    private var availableGenres: [String] {
        Set(indexedMetadata.values.flatMap(\.genres))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func compatibilityProfile(for game: StoreGame) -> CompatProfile? {
        switch store {
        case .steam:
            return CompatService.shared.profile(steam: game.steamAppId ?? game.id, title: game.title)
        case .epic:
            return CompatService.shared.profile(epic: game.id, title: game.title)
        case .gog:
            return CompatService.shared.profile(gog: game.id, title: game.title)
        case .local:
            return CompatService.shared.profile(steam: game.steamAppId, title: game.title)
        }
    }

    private func matchesCompatibility(_ game: StoreGame) -> Bool {
        compatibilityFilter.matches(compatibilityProfile(for: game)?.rating)
    }

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
        if compatibilityFilter != .cualquiera {
            list = list.filter(matchesCompatibility)
        }
        if sizeFilter != .cualquiera {
            list = list.filter { sizeFilter.matches($0.installSizeBytes) }
        }
        if let selectedGenre {
            list = list.filter { game in
                LibraryAdvancedFilterRules.matchesGenre(
                    indexedMetadata[game.id]?.genres ?? [], selected: selectedGenre
                )
            }
        }
        if !search.isEmpty {
            list = list.filter { LibraryTitleSearch.matches(title: $0.title, query: search) }
        }
        list.sort { a, b in
            // «Recientes» es orden PURO por actividad (como Steam: lo último jugado arriba del
            // todo, instalado o no). Los demás criterios agrupan instalados primero.
            if sortOrder != .recientes, a.installed != b.installed { return a.installed }
            switch sortOrder {
            case .nombre:    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .recientes: return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast)
            case .masJugado: return (a.playtimeMinutes ?? 0) > (b.playtimeMinutes ?? 0)
            case .metacritic:
                // Puntuación de la metadata indexada (Steam también ordena por Metacritic);
                // sin dato, al final del grupo.
                let ma = indexedMetadata[a.id]?.metacritic ?? -1
                let mb = indexedMetadata[b.id]?.metacritic ?? -1
                if ma != mb { return ma > mb }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
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
        // Panel de hover para las FILAS de la sidebar (mismo panel rico que en el grid, anclado
        // a la fila y abierto hacia el panel de detalle, como hace Steam en su lista compacta).
        .overlayPreferenceValue(GameRowBoundsPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                if let game = previewedGame, previewOriginRow, let anchor = anchors[game.id] {
                    let rowBounds = proxy[anchor]
                    GameHoverPreviewView(game: game, store: store, tint: tint)
                        .frame(width: GameHoverPreviewView.panelSize.width,
                               height: GameHoverPreviewView.panelSize.height)
                        .position(rowPreviewPosition(for: rowBounds, in: proxy.size))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .zIndex(100)
                }
            }
            .allowsHitTesting(false)
        }
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
                    },
                    onPause: { onPauseTransfer?($0) },
                    onResume: { onResumeTransfer?($0) },
                    onCancel: { onCancelTransfer?($0) },
                    onPrioritize: { onPrioritizeTransfer?($0) },
                    onRetry: { onRetryTransfer?($0) }
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
        .onChange(of: compatibilityFilter) { _, _ in persistLibraryPreferences(); refreshDisplayed() }
        .onChange(of: sizeFilter) { _, _ in persistLibraryPreferences(); refreshDisplayed() }
        .onChange(of: selectedGenre) { _, _ in persistLibraryPreferences(); refreshDisplayed() }
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
            if let selected {
                lastDetailGameID = selected.id
            } else if let anchor = lastDetailGameID {
                // Vuelta al home: restaura el scroll junto a la carátula del juego que se visitó.
                gridScrollID = anchor
            }
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
        .task(id: games) { await refreshLibraryData() }
        // Las estadísticas (última sesión / tiempo jugado) alimentan `enriched`, «Recientes» y
        // «Seguir jugando»: al cambiar (p. ej. tras jugar), recalculamos cachés y la lista.
        .onChange(of: PlayStatsStore.shared.stats) { _, _ in
            recomputeDerivedCaches()
            refreshDisplayed()
        }
        .onDisappear(perform: cancelTransientTasks)
    }

    /// Recalcula cachés derivadas, lista, carátulas (prefetch), índice de Spotlight y metadata
    /// cacheada. Extraído del `.task(id: games)` para que el type-checker de SwiftUI no se
    /// desborde con la cadena de modificadores de esta vista coordinadora.
    private func refreshLibraryData() async {
        recomputeDerivedCaches()
        refreshDisplayed()
        CoverCache.shared.prefetch(games.map { ($0.id, $0.coverCandidates) })
        indexLibraryForSpotlight()
        indexedMetadata = await StoreGameMetadataService.shared.cachedDetails(for: metadataRequests)
        refreshDisplayed()
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
        .onReceive(NotificationCenter.default.publisher(for: .spotlightOpenGame)) { note in
            // Spotlight (⌘Espacio del sistema): abre la ficha del juego encontrado si es de ESTA
            // tienda y está en la biblioteca; si no, no hace nada (otra tienda lo recogerá).
            guard let identifier = note.userInfo?["identifier"] as? String,
                  identifier.hasPrefix("\(store.rawValue):") else { return }
            let gameId = String(identifier.dropFirst(store.rawValue.count + 1))
            if let game = games.first(where: { $0.id == gameId }) {
                openGame(game)
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .openTransferCenter)) { _ in
            if !activeTransfers.isEmpty { transferCenterPresented = true }
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
        .confirmationDialog(
            "¿Desinstalar «\(gamePendingUninstall?.title ?? "")»?",
            isPresented: Binding(
                get: { gamePendingUninstall != nil },
                set: { if !$0 { gamePendingUninstall = nil } }
            )
        ) {
            Button("Desinstalar", role: .destructive) {
                if let g = gamePendingUninstall { onUninstall(g) }
                gamePendingUninstall = nil
            }
            Button("Cancelar", role: .cancel) { gamePendingUninstall = nil }
        } message: {
            Text("Se eliminarán sus archivos del disco. Podrás volver a instalarlo cuando quieras.")
        }
        .confirmationDialog(
            "¿Cerrar sesión en \(store.displayName)?",
            isPresented: $logoutConfirmationPresented
        ) {
            Button("Cerrar sesión", role: .destructive) { onLogout() }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Se eliminarán las credenciales guardadas y la biblioteca dejará de estar disponible hasta que vuelvas a iniciar sesión.")
        }
        .overlay(alignment: .bottom) { undoHiddenOverlay }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: undoHiddenGame?.id)
    }

    /// Desinstalar pasa SIEMPRE por confirmación. Steam ya la tiene en su propio flujo
    /// (`BottleDetailView.gameToUninstall` → alert), así que ahí se delega directo; Epic,
    /// GOG y DRM-free borraban al instante desde el menú contextual — para ellas la
    /// confirmación vive aquí (acción destructiva e irreversible a un clic, ahora cubierta).
    private func requestUninstall(_ game: StoreGame) {
        if store == .steam { onUninstall(game) } else { gamePendingUninstall = game }
    }

    private func cancelTransientTasks() {
        hoverPresentationTask?.cancel()
        hoverPresentationTask = nil
        undoHiddenTask?.cancel()
        undoHiddenTask = nil
        steamHintTask?.cancel()
        steamHintTask = nil
        metadataIndexTask?.cancel()
        metadataIndexTask = nil
        metadataIndexProgress = nil
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

    /// Refleja `dockProgressSnapshot` en el icono del Dock (barra de progreso estilo Mythic) y el
    /// badge con el Nº de descargas/actualizaciones activas (como el App Store o Steam).
    private func updateDockProgress() {
        let v = dockProgressSnapshot
        if v < 0 { DockProgress.resetProgress() } else { DockProgress.progress = min(1, max(0, v)) }
        let activas = installingIDs.count
        NSApp.dockTile.badgeLabel = activas > 0 ? "\(activas)" : nil
    }

    // MARK: - Panel principal: ficha del juego seleccionado o grid "home"

    @ViewBuilder private var detailPane: some View {
        if let game = currentSelectedGame {
            // Resuelve por ID la versión ACTUAL de la biblioteca. Así la ficha cambia de Instalar a
            // Jugar en el mismo instante en que termina la operación, sin exigir otra navegación.
            GameDetailView(
                game: game, tint: tint, store: store,
                artworkTransitionNamespace: reduceMotion ? nil : gameDetailTransitionNamespace,
                installing: installingIDs.contains(game.id),
                progress: progressFor(game.id),
                percent: percentFor(game.id),
                isFavorite: isFav(game.id),
                isHidden: isHidden(game.id),
                onInstall: { onInstall(game) },
                onPlay: { onPlay(game) },
                onUninstall: { requestUninstall(game) },
                onVerify: { onVerify(game) },
                onUpdate: { onUpdate(game) },
                loadStoreDLCs: { await dlcsFor(game) },
                onInstallDLC: onInstallDLC.map { callback in { callback(game, $0) } },
                onToggleFavorite: { toggleFav(game.id) },
                onToggleHidden: { toggleHidden(game.id) },
                hasNote: notesStore.hasNote(storeID: store.rawValue, gameID: game.id),
                onOpenNotes: { openNotes(for: game) },
                onBack: navigateBackOrHome,
                transferPhase: transferPhaseFor(game.id),
                onPauseTransfer: canPauseTransfer(game.id) ? { onPauseTransfer?(game) } : nil,
                onResumeTransfer: { onResumeTransfer?(game) }
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
                if showsRecentlyPlayed {
                    continuePlayingSection
                    if !recentActivityEvents.isEmpty {
                        LibraryActivitySection(
                            events: recentActivityEvents,
                            games: games,
                            tint: tint,
                            onOpen: openGame
                        )
                    }
                    if !recentlyPlayed.isEmpty { recentlyPlayedSection }
                }
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
            .scrollTargetLayout()
        }
        // Al volver de una ficha, restaura el scroll junto a su carátula (como Steam: no pierdes
        // tu sitio en una biblioteca de miles de juegos). Si el juego no está en la consulta
        // actual, scrollPosition ignora el id (sin efecto, seguro).
        .scrollPosition(id: $gridScrollID, anchor: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesselBackground(tint: tint)
        .overlayPreferenceValue(GameCardBoundsPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                if let game = previewedGame, !previewOriginRow, let anchor = anchors[game.id] {
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

    /// Posiciona el panel junto a la carátula, cambia a la izquierda si no cabe y limita su
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

    /// Posición del panel de hover para una FILA de la sidebar: siempre hacia la derecha (el
    /// panel de detalle), con la misma alineación superior y límites al viewport que en el grid.
    private func rowPreviewPosition(for row: CGRect, in viewport: CGSize) -> CGPoint {
        let panel = GameHoverPreviewView.panelSize
        let margin: CGFloat = 12
        let minimumX = panel.width / 2 + margin
        let maximumX = max(minimumX, viewport.width - panel.width / 2 - margin)
        let x = min(maximumX, max(minimumX, row.maxX + margin + panel.width / 2))
        let minimumY = panel.height / 2 + margin
        let maximumY = max(minimumY, viewport.height - panel.height / 2 - margin)
        let topAlignedY = row.minY + panel.height / 2
        return CGPoint(x: x, y: min(maximumY, max(minimumY, topAlignedY)))
    }

    /// Steam espera un instante antes de abrir la tarjeta rica: recorrer el grid no provoca red
    /// ni paneles fugaces. Una vez abierta, cambiar de juego es más rápido para sentirse continuo.
    /// `fromRow` distingue el origen (fila de la sidebar) del grid para no duplicar el panel.
    private func handleGridHover(_ hovering: Bool, game: StoreGame, fromRow: Bool = false) {
        hoverPresentationTask?.cancel()

        if hovering {
            hoverCandidateID = game.id
            previewOriginRow = fromRow
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
    /// Memoizado en `recomputeDerivedCaches` (fallback inline idéntico en el primer frame).
    private var recentlyPlayed: [StoreGame] {
        if recentlyPlayedCache.isEmpty && !enriched.isEmpty {
            return enriched.filter { $0.lastPlayed != nil && !isHidden($0.id) }
                .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
                .prefix(8).map { $0 }
        }
        return recentlyPlayedCache
    }

    /// El último juego INSTALADO que se jugó: candidato del gran acceso «Seguir jugando» del
    /// home (estilo Steam: abre la biblioteca con el botón grande de reanudar tu último juego).
    /// Solo instalados (no se puede reanudar lo que no está), nada en plena instalación y nada
    /// que YA esté en ejecución (su botón sería un no-op: se elige el siguiente candidato).
    private var continuePlayingGame: StoreGame? {
        enriched.filter {
            $0.installed && $0.lastPlayed != nil && !isHidden($0.id)
                && !installingIDs.contains($0.id)
                && GameLaunchTracker.shared.state(statsKey($0)) == .idle
        }
        .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        .first
    }

    /// Gran tarjeta «Seguir jugando» sobre la estantería: hero del juego con la misma caché de
    /// carátulas, acción primaria verde dominante y entrada animada (anulada con Reduce Motion,
    /// pero el contenido siempre visible — nunca se quita funcionalidad ni animación al resto).
    @ViewBuilder private var continuePlayingSection: some View {
        if let game = continuePlayingGame {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
            ZStack(alignment: .bottomLeading) {
                GameCoverImage(cacheKey: "resume-\(game.id)", candidates: heroCandidates(for: game)) {
                    LinearGradient(colors: [tint.opacity(0.30), Theme.navyDeep],
                                   startPoint: .top, endPoint: .bottom)
                }
                .frame(maxWidth: .infinity).frame(height: 176)
                .clipped()
                LinearGradient(colors: [.clear, Theme.navyDeep.opacity(0.94)],
                               startPoint: .center, endPoint: .bottom)
                HStack(alignment: .bottom, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("SEGUIR JUGANDO")
                            .font(.caption.weight(.heavy)).tracking(1.4)
                            .foregroundStyle(.white.opacity(0.65))
                            .accessibilityHidden(true)
                        Text(game.title)
                            .font(.title2.bold()).foregroundStyle(.white).lineLimit(1)
                            .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                        Text(resumeSubtitle(for: game))
                            .font(.caption).foregroundStyle(.white.opacity(0.68))
                    }
                    Spacer(minLength: 8)
                    Button { onPlay(game) } label: {
                        Label("Jugar", systemImage: "play.fill")
                            .font(.title3.weight(.bold))
                            .frame(minWidth: 150).frame(height: 30)
                    }
                    .vesselButton(tint: Theme.play)
                    .vesselHelp("Seguir jugando a \(game.title)", shortcut: "⌘↩")
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .contentShape(shape)
            .onTapGesture { openGame(game) }
            .hoverLift(scale: 1.01)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Seguir jugando a \(game.title)")
            .vesselHelp("Abrir la ficha de \(game.title)")
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Hero del juego para «Seguir jugando»: su banner horizontal o, si no hay, la carátula
    /// vertical (misma cascada que la ficha, servida desde la caché compartida).
    private func heroCandidates(for game: StoreGame) -> [URL] {
        var urls: [URL] = []
        if let s = game.heroURL, let u = URL(string: s) { urls.append(u) }
        if let appId = game.steamAppId, !appId.isEmpty,
           let u = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/library_hero.jpg") {
            urls.append(u)
        }
        urls.append(contentsOf: game.coverCandidates)
        return urls
    }

    private func resumeSubtitle(for game: StoreGame) -> String {
        var parts: [String] = []
        if let lastPlayed = game.lastPlayed {
            parts.append("Última sesión \(lastPlayed.formatted(.relative(presentation: .named).locale(Locale(identifier: "es_ES"))))")
        }
        if let minutes = game.playtimeMinutes, minutes > 0 {
            parts.append(minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min jugados" : "\(minutes) min jugados")
        }
        return parts.joined(separator: " · ")
    }

    private var recentActivityEvents: [LibraryActivityStore.Event] {
        if let activityEventsOverride {
            return Array(activityEventsOverride.lazy
                .filter { $0.storeID == store.rawValue }
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(6))
        }
        return activityStore.recent(storeID: store.rawValue, limit: 6)
    }

    /// La estantería global solo pertenece a la portada sin restricciones. Al entrar en una
    /// colección o aplicar una consulta, ocultarla evita mezclar juegos ajenos al resultado.
    private var showsRecentlyPlayed: Bool {
        selectedCollectionID == nil && filter == .todos && !showFavoritesOnly
            && search.isEmpty && !advancedFiltersActive
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
                            .id(game.id)
                            .draggable(LibraryGameDragPayload(storeID: store.rawValue, gameID: game.id))
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 4).padding(.horizontal, 2)
            }
            .scrollPosition(id: $recentlyPlayedScrollID, anchor: .leading)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollClipDisabled()
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) {
                moveRecentlyPlayed(by: -1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                moveRecentlyPlayed(by: 1)
                return .handled
            }
            .onAppear {
                if recentlyPlayedScrollID == nil { recentlyPlayedScrollID = recentlyPlayed.first?.id }
            }
            .accessibilityLabel("Juegos jugados recientemente")
            .accessibilityHint("Usa las flechas izquierda y derecha para recorrer la estantería.")
        }
    }

    private func moveRecentlyPlayed(by delta: Int) {
        let ids = recentlyPlayed.map(\.id)
        guard !ids.isEmpty else { recentlyPlayedScrollID = nil; return }
        let current = recentlyPlayedScrollID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = min(max(current + delta, 0), ids.count - 1)
        if reduceMotion {
            recentlyPlayedScrollID = ids[next]
        } else {
            withAnimation(.snappy(duration: 0.26)) {
                recentlyPlayedScrollID = ids[next]
            }
        }
    }

    /// Barra de ámbitos siempre visible. Es el equivalente ligero a las colecciones dinámicas de
    /// Steam y a una scope bar de macOS: un clic aplica el criterio y el contador anticipa el resultado.
    private var quickScopeBar: some View {
        // Contadores memoizados (5 recorridos O(n) → 0 por render); en el primer frame, antes de
        // la primera recomputación, se calculan inline como antes (fallback idéntico).
        let counts: [LibraryQuickScope: Int]
        if scopeCountsCache.isEmpty && !enriched.isEmpty {
            let source = enriched.filter { !isHidden($0.id) }
            counts = [.todos: source.count,
                      .listos: source.count(where: \.installed),
                      .actualizaciones: source.count(where: \.updateAvailable),
                      .sinJugar: source.count { $0.lastPlayed == nil && ($0.playtimeMinutes ?? 0) == 0 },
                      .favoritos: source.count { favorites.contains($0.id) }]
        } else {
            counts = scopeCountsCache
        }

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

                let availableUpdates = enriched.filter { $0.updateAvailable && !installingIDs.contains($0.id) }
                if let onUpdateAll, !availableUpdates.isEmpty {
                    Button {
                        onUpdateAll(availableUpdates)
                    } label: {
                        Label("Actualizar todo", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .vesselButton(activeQuickScope == .actualizaciones, tint: tint)
                    .accessibilityValue("\(availableUpdates.count) actualizaciones")
                    .vesselHelp(
                        "Actualizar todo",
                        detail: "Añade \(availableUpdates.count) juego\(availableUpdates.count == 1 ? "" : "s") a la cola."
                    )
                }

                if let progress = metadataIndexProgress {
                    HStack(spacing: 7) {
                        ProgressView(value: Double(progress.completed),
                                     total: Double(max(1, progress.total)))
                            .progressViewStyle(.linear)
                            .tint(tint)
                            .frame(width: 62)
                        Text("Preparando géneros \(progress.completed)/\(progress.total)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .liquidGlass(in: Capsule())
                    .accessibilityLabel("Preparando filtros de género")
                    .accessibilityValue("\(progress.completed) de \(progress.total)")
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
        // Con Task (cancelable en `cancelTransientTasks`): el `asyncAfter` anterior podía mostrar
        // el popover FUERA DE TIEMPO si la vista se desmontaba antes de los 0,7 s / 5,5 s.
        steamHintTask?.cancel()
        steamHintTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard !Task.isCancelled else { return }
            showSteamHint = true
            do { try await Task.sleep(for: .milliseconds(4800)) } catch { return }
            guard !Task.isCancelled else { return }
            showSteamHint = false
        }
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
                Button(role: .destructive) { logoutConfirmationPresented = true } label: {
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
        searchField(compact: false)
            .padding(.horizontal, 12).padding(.bottom, 8)
    }

    /// Campo de búsqueda de la biblioteca, compartido por la sidebar y la cabecera del grid
    /// (antes había dos implementaciones casi idénticas). `compact` = versión en cápsula de
    /// ancho fijo para la cabecera, visible cuando la sidebar (y su buscador) se colapsa.
    @ViewBuilder private func searchField(compact: Bool) -> some View {
        let field = HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Buscar en \(store.displayName)…", text: $search)
                .textFieldStyle(.plain).font(.callout)
                .frame(width: compact ? 180 : nil)
                .focused($searchFocused)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Borrar búsqueda")
                .vesselHelp("Borrar búsqueda")
            }
        }
        if compact {
            field
                .padding(.horizontal, 10).padding(.vertical, 7)
                .liquidGlass(in: Capsule())
                .vesselHelp("Buscar en \(store.displayName)",
                            detail: "Busca por título, fragmentos o abreviaturas; ignora tildes y signos.", shortcut: "⌘F")
        } else {
            field
                .padding(8)
                .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .vesselHelp("Buscar en \(store.displayName)",
                            detail: "Busca por título, fragmentos o abreviaturas; ignora tildes y signos.", shortcut: "⌘F")
        }
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
            Divider()
            Menu("Compatibilidad") {
                Picker("Compatibilidad", selection: $compatibilityFilter) {
                    ForEach(LibraryCompatibilityFilter.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Menu("Tamaño instalado") {
                Picker("Tamaño instalado", selection: $sizeFilter) {
                    ForEach(LibrarySizeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Menu("Género") {
                Button {
                    selectedGenre = nil
                } label: {
                    if selectedGenre == nil { Label("Todos", systemImage: "checkmark") }
                    else { Text("Todos") }
                }
                ForEach(availableGenres, id: \.self) { genre in
                    Button {
                        selectedGenre = genre
                    } label: {
                        if selectedGenre == genre { Label(genre, systemImage: "checkmark") }
                        else { Text(genre) }
                    }
                }
                Divider()
                Button(metadataIndexProgress == nil ? "Preparar todos los géneros…" : "Indexando géneros…") {
                    startMetadataIndexing()
                }
                .disabled(metadataIndexProgress != nil)
            }
            if advancedFiltersActive {
                Divider()
                Button("Restablecer filtros avanzados") {
                    compatibilityFilter = .cualquiera
                    sizeFilter = .cualquiera
                    selectedGenre = nil
                }
            }
        } label: {
            Label(filter.rawValue, systemImage: "line.3.horizontal.decrease")
                .font(.caption.weight(.medium))
                .foregroundStyle(filter == .todos && !advancedFiltersActive ? .white.opacity(0.6) : tint)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Filtrar por estado")
        .vesselHelp("Filtrar juegos por estado")
    }

    private var advancedFiltersActive: Bool {
        compatibilityFilter != .cualquiera || sizeFilter != .cualquiera || selectedGenre != nil
    }

    private func startMetadataIndexing() {
        guard metadataIndexTask == nil else { return }
        let requests = metadataRequests
        metadataIndexProgress = (0, requests.count)
        metadataIndexTask = Task { @MainActor in
            let indexed = await StoreGameMetadataService.shared.indexDetails(for: requests) { completed, total in
                Task { @MainActor in metadataIndexProgress = (completed, total) }
            }
            guard !Task.isCancelled else { return }
            indexedMetadata = indexed
            metadataIndexProgress = nil
            metadataIndexTask = nil
            refreshDisplayed()
        }
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
        searchField(compact: true)
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
                    StoreGameRow(game: game, tint: tint,
                                 isFavorite: isFav(game.id),
                                 isSelected: selectedGame?.id == game.id)
                        // Doble clic = acción primaria (jugar/instalar), SIN disparar también la
                        // apertura de la ficha. Con `Button` + `simultaneousGesture` el primer
                        // clic abría la ficha Y el doble lanzaba el juego (comportamiento erróneo;
                        // Steam no navega al hacer doble clic). SwiftUI resuelve el count:2 antes
                        // que el count:1, retrasando un ápice la selección simple — lo esperado.
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { performDoubleClickAction(for: game) }
                        .onTapGesture(count: 1) { openGame(game) }
                        .onHover { handleGridHover($0, game: game, fromRow: true) }
                        .anchorPreference(key: GameRowBoundsPreferenceKey.self, value: .bounds) {
                            [game.id: $0]
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        .listRowBackground(Color.clear)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(game.title)
                        .accessibilityValue(game.installed ? "Instalado" : "Sin instalar")
                        .accessibilityHint(game.installed
                            ? "Abre los detalles; haz doble clic para jugar"
                            : "Abre los detalles; haz doble clic para instalar")
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
            Button(role: .destructive) { requestUninstall(game) } label: { Label("Desinstalar", systemImage: "trash") }
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
        if displayed.isEmpty, externalLibraryLoading {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Cargando la biblioteca de \(store.displayName)…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
            .accessibilityElement(children: .combine)
        } else if displayed.isEmpty, let libraryError = externalLibraryError {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.30))
                Text(libraryError)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                Button(action: onRetryLibraryLoad) {
                    Label("Reintentar", systemImage: "arrow.clockwise")
                }
                .vesselButton(false, tint: tint)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else if displayed.isEmpty {
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
                        artworkTransitionNamespace: reduceMotion ? nil : gameDetailTransitionNamespace,
                        isFavorite: isFav(game.id),
                        isHidden: isHidden(game.id),
                        installing: installingIDs.contains(game.id),
                        progress: progressFor(game.id),
                        percent: percentFor(game.id),
                        onInstall: { onInstall(game) },
                        onPlay: { onPlay(game) },
                        onToggleFavorite: { toggleFav(game.id) },
                        onToggleHidden: { toggleHidden(game.id) },
                        onUninstall: { requestUninstall(game) },
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
