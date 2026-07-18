import SwiftUI
import AppKit
import Shimmer

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
struct StoreDLC: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let coverURL: URL?
    /// Identificador que espera el backend para instalarlo. Puede diferir del ID de catálogo.
    var installID: String? = nil
    /// ¿El usuario lo POSEE? Los que no, se atenúan para que no destaquen. `true` por defecto
    /// (o si no hay datos de sesión → no atenuar sin saber).
    var owned: Bool = true
    /// `nil` cuando la tienda no expone instalación individual; GOG informa el estado real de su
    /// manifiesto local para ofrecer un botón Instalar solo cuando procede.
    var installed: Bool? = nil
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

/// Reglas puras de desplazamiento de la ficha. Se mantienen fuera de SwiftUI para poder probar el
/// umbral de la barra contextual sin depender de una ventana o de la física del trackpad.
enum GameDetailScrollBehavior {
    static let stickyActionThreshold: CGFloat = 410

    static func showsStickyActionBar(contentOffsetY: CGFloat, topInset: CGFloat) -> Bool {
        contentOffsetY + topInset > stickyActionThreshold
    }

    static func screenshotIndex(current: Int?, movingBy delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max((current ?? 0) + delta, 0), count - 1)
    }
}

struct GameDetailView: View {
    let game: StoreGame
    let tint: Color
    var store: StoreKind = .steam
    var artworkTransitionNamespace: Namespace.ID? = nil
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
    var loadStoreDLCs: @MainActor () async -> [StoreDLC] = { [] }
    var onInstallDLC: ((StoreDLC) -> Void)? = nil
    var onToggleFavorite: () -> Void = {}
    var onToggleHidden: () -> Void = {}
    var hasNote: Bool = false
    var onOpenNotes: () -> Void = {}
    var onBack: () -> Void = {}
    /// Fase de la transferencia en curso (si la hay) y acciones de pausa/reanudación, para que el
    /// usuario pueda pausar la descarga también desde la ficha (antes solo en el centro de descargas).
    var transferPhase: LibraryTransferPhase = .running
    var onPauseTransfer: (() -> Void)? = nil
    var onResumeTransfer: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingSettings = false
    /// Detener un juego en ejecución puede perder progreso no guardado: pide confirmación.
    @State private var stopConfirmationPresented = false
    @State private var details: SteamGameDetails?
    @State private var loadingDetails = false
    @State private var detailsLoadFailed = false
    /// Índice de la captura abierta en el visor ampliado (nil = cerrado).
    @State private var lightboxIndex: Int?
    /// Captura alineada en el carrusel; permite snapping, flechas y teclado con una sola fuente.
    @State private var visibleScreenshotIndex: Int?
    @State private var mediaHovering = false
    /// Aparece al superar hero + acciones y conserva la acción primaria siempre al alcance.
    @State private var showsStickyActionBar = false
    /// DLCs resueltos (nombre + carátula) del juego.
    @State private var dlcs: [StoreDLC] = []
    /// Estado REAL de logros (desbloqueado/bloqueado) del usuario, si hay credencial de Steam.
    @State private var achievements: SteamAchievementsService.Progress?
    /// Veredicto vivo de protección. Solo se usa para afirmar «No funciona» cuando la fuente
    /// específica de macOS declara el anti-cheat como Denied/Broken.
    @State private var drmVerdict: DRMDatabase.Verdict?
    /// Mostrar todos los logros (o solo un avance).
    @State private var showAllAchievements = false
    /// Observa la Web API key: si el usuario la pega en Ajustes con la ficha abierta, recargamos los
    /// logros para mostrar también los bloqueados (schema) sin tener que reabrir el juego.
    @AppStorage("steam.webApiKey") private var steamApiKeyObserver = ""
    private let steamGreen = Theme.play
    private let runningRed = Theme.destructive

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
                    .padding(.top, -Theme.Space.heroActionOverlap)
                    .zIndex(1)
                if details?.genres.isEmpty == false {
                    genreChips.padding(.horizontal, Theme.Space.page).padding(.bottom, 6)
                }
                if details?.screenshots.isEmpty == false || loadingDetails { mediaSection }
                content
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            GameDetailScrollBehavior.showsStickyActionBar(
                contentOffsetY: geometry.contentOffset.y,
                topInset: geometry.contentInsets.top
            )
        } action: { _, shouldShow in
            guard shouldShow != showsStickyActionBar else { return }
            if reduceMotion {
                showsStickyActionBar = shouldShow
            } else {
                withAnimation(.snappy(duration: 0.24)) {
                    showsStickyActionBar = shouldShow
                }
            }
        }
        .vesselBackground(tint: tint)
        .overlay(alignment: .top) {
            if showsStickyActionBar {
                stickyActionBar
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) { backButton }
        .overlay { if let idx = lightboxIndex { screenshotLightbox(idx) } }
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: lightboxIndex)
        .sheet(isPresented: $showingSettings) {
            GameSettingsView(game: game, tint: tint, installPath: game.installPath, store: store) {
                showingSettings = false
            }
        }
        .confirmationDialog("¿Detener «\(game.title)»?", isPresented: $stopConfirmationPresented) {
            Button("Detener el juego", role: .destructive) { GameLaunchTracker.shared.stop(game.id) }
            Button("Seguir jugando", role: .cancel) { }
        } message: {
            Text("Se forzará el cierre del juego. Podrías perder el progreso no guardado.")
        }
        .task(id: game.id) { await loadDetails() }
        .task(id: game.steamAppId) { await loadDRMVerdict() }
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
                LightboxImage(cacheKey: "shotfull-\(game.id)-\(idx)", url: url)
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
                        .keyboardShortcut(.escape, modifiers: [])
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
        .buttonStyle(.plain)
        .keyboardShortcut(icon.contains("left") ? .leftArrow : .rightArrow, modifiers: [])
        .opacity(enabled ? 1 : 0.25).disabled(!enabled)
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
                        // Con caché (memoria+disco): sin ella, `AsyncImage` re-descargaba el hero en
                        // CADA visita a la ficha — parpadeo y continuidad carátula→hero rota.
                        GameCoverImage(cacheKey: "hero-\(game.id)", candidates: [url]) {
                            LinearGradient(colors: [tint.opacity(0.35), Theme.navyDeep], startPoint: .top, endPoint: .bottom)
                        }
                    } else {
                        LinearGradient(colors: [tint.opacity(0.35), Theme.navyDeep], startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(width: geo.size.width, height: 380 + parallax.overscan)
                .offset(y: parallax.offset)
                .gameArtworkTransition(
                    gameID: game.id,
                    namespace: artworkTransitionNamespace,
                    isSource: false
                )
                .clipped()
                LinearGradient(colors: [.clear, .clear, Theme.navyDeep], startPoint: .top, endPoint: .bottom)
                Text(game.title)
                    .font(.system(size: 36, weight: .heavy)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 8, y: 3)
                    .padding(.horizontal, Theme.Space.page)
                    .padding(.bottom, Theme.Space.heroTitleInset)
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
        .padding(.horizontal, Theme.Space.page).padding(.vertical, 18)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: launchState)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: installing)
    }

    /// Toolbar flotante de contexto, equivalente a conservar Jugar/Instalar visible en Steam.
    /// Cada control es su propia superficie de cristal dentro de un `GlassEffectContainer`; no hay
    /// un panel de cristal exterior que apile materiales y reduzca el contraste.
    private var stickyActionBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                GameCoverImage(cacheKey: "sticky-\(game.id)", candidates: game.coverCandidates) {
                    ZStack {
                        game.placeholderColor
                        Text(game.initials)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: 26, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                Text(game.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: 250, alignment: .leading)
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .liquidGlass(in: Capsule())

            stickyPrimaryButton
            gameActionsMenu
        }
        .vesselGlassContainer(spacing: 8)
        .padding(.top, 12)
        .padding(.leading, 64)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(0.30), radius: 16, y: 7)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var stickyPrimaryButton: some View {
        switch launchState {
        case .launching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Iniciando…")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .liquidGlass(in: Capsule())
            .accessibilityLabel("Iniciando \(game.title)")
        case .running:
            Button { stopConfirmationPresented = true } label: {
                Label("Detener", systemImage: "stop.fill")
                    .font(.callout.weight(.bold))
                    .padding(.horizontal, 5)
                    .frame(height: 28)
            }
            .vesselButton(tint: runningRed)
            .vesselHelp("Detener \(game.title)")
        case .idle:
            if installing {
                HStack(spacing: 8) {
                    if let percent {
                        ProgressView(value: percent)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(tint)
                    } else {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text(progress ?? "Instalando…")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(maxWidth: 220, minHeight: 46)
                .liquidGlass(in: Capsule())
                .accessibilityLabel(progress ?? "Instalando \(game.title)")
            } else if game.installed {
                Button(action: onPlay) {
                    Label("Jugar", systemImage: "play.fill")
                        .font(.callout.weight(.bold))
                        .padding(.horizontal, 5)
                        .frame(height: 28)
                }
                .vesselButton(tint: steamGreen)
                .vesselHelp("Jugar a \(game.title)", shortcut: "⌘↩")
            } else {
                Button(action: onInstall) {
                    Label("Instalar", systemImage: "arrow.down.circle.fill")
                        .font(.callout.weight(.bold))
                        .padding(.horizontal, 5)
                        .frame(height: 28)
                }
                .vesselButton(tint: tint)
                .vesselHelp("Instalar \(game.title)", shortcut: "⌘↩")
            }
        }
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
        // «Últimas 2 semanas» (estilo Steam): sale del registro de sesiones de PlayStatsStore.
        if let twoWeeks = PlayStatsStore.shared.minutesPlayed(inLastDays: 14, key: "\(store.rawValue):\(game.id)") {
            stat("calendar", "Últimas 2 semanas",
                 twoWeeks >= 60 ? "\(twoWeeks / 60) h \(twoWeeks % 60) min" : "\(twoWeeks) min")
        }
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
        iconButton(isFavorite ? "star.fill" : "star",
                   label: isFavorite ? "Quitar de favoritos" : "Añadir a favoritos",
                   tinted: isFavorite, accent: .yellow, action: onToggleFavorite)
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
                      systemImage: isFavorite ? "star.slash" : "star")
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
            Button { stopConfirmationPresented = true } label: {
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
                        // Pausa/reanudación también desde la ficha (antes solo en el centro de descargas).
                        if transferPhase == .paused, let onResumeTransfer {
                            Button(action: onResumeTransfer) {
                                Image(systemName: "play.fill").font(.callout.weight(.bold))
                                    .frame(width: 30, height: 24)
                            }
                            .vesselButton(tint: steamGreen)
                            .accessibilityLabel("Reanudar la descarga")
                            .vesselHelp("Reanudar la descarga")
                        } else if transferPhase == .running, let onPauseTransfer {
                            Button(action: onPauseTransfer) {
                                Image(systemName: "pause.fill").font(.callout.weight(.bold))
                                    .frame(width: 30, height: 24)
                            }
                            .vesselButton(tint: steamGreen)
                            .accessibilityLabel("Pausar la descarga")
                            .vesselHelp("Pausar la descarga")
                        }
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
                    // Estilo Steam: el tamaño de la descarga va junto a la acción cuando se conoce.
                    if let size = game.installSizeBytes, size > 0 {
                        Label("Instalar — \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))",
                              systemImage: "arrow.down.circle.fill")
                            .font(.title2.weight(.bold)).frame(minWidth: 170).frame(height: 28)
                    } else {
                        Label("Instalar", systemImage: "arrow.down.circle.fill")
                            .font(.title2.weight(.bold)).frame(minWidth: 170).frame(height: 28)
                    }
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
                if let verdict = drmVerdict, verdict.antiCheatBlocksMacOS {
                    blockedAntiCheatSection(verdict)
                } else if let p = profile {
                    compatSection(p)
                }
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
            if store == .steam, detailsLoadFailed {
                cardSection("Acerca de") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("No se pudieron cargar los detalles del juego.", systemImage: "exclamationmark.icloud")
                            .font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                        Text("Comprueba tu conexión a internet y vuelve a intentarlo.")
                            .font(.caption).foregroundStyle(.white.opacity(0.5))
                        Button {
                            Task { await loadDetails() }
                        } label: {
                            Label("Reintentar", systemImage: "arrow.clockwise").font(.callout.weight(.semibold))
                        }
                        .vesselButton(false, tint: tint)
                        .accessibilityLabel("Reintentar la carga de detalles")
                    }
                }
            } else {
                cardSection("Acerca de") {
                    Text("Sin descripción disponible para este juego.")
                        .font(.callout).foregroundStyle(.white.opacity(0.5))
                }
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
                HStack(spacing: 10) {
                    Text("CAPTURAS")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                    Spacer()
                    Text("\((visibleScreenshotIndex ?? 0) + 1) / \(shots.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.46))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 32)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(shots.enumerated()), id: \.element) { idx, url in
                            Button { lightboxIndex = idx } label: {
                                // Con caché (memoria+disco): las capturas no se re-descargan al
                                // volver a la ficha ni al reciclar celdas del carrusel.
                                GameCoverImage(cacheKey: "shot-\(game.id)-\(idx)", candidates: [url]) {
                                    Theme.surface
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
                            .id(idx)
                            .accessibilityLabel("Ampliar captura \(idx + 1)")
                            .vesselHelp("Ampliar captura \(idx + 1)")
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 32).padding(.vertical, 4)
                }
                .scrollPosition(id: $visibleScreenshotIndex, anchor: .leading)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                .scrollClipDisabled()
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) {
                    moveScreenshot(by: -1, count: shots.count)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    moveScreenshot(by: 1, count: shots.count)
                    return .handled
                }
                .onKeyPress(.return) {
                    lightboxIndex = min(visibleScreenshotIndex ?? 0, shots.count - 1)
                    return .handled
                }
                .onHover { mediaHovering = $0 }
                .overlay {
                    if shots.count > 1 {
                        HStack {
                            carouselArrow(
                                "chevron.left",
                                enabled: (visibleScreenshotIndex ?? 0) > 0
                            ) { moveScreenshot(by: -1, count: shots.count) }
                            Spacer()
                            carouselArrow(
                                "chevron.right",
                                enabled: (visibleScreenshotIndex ?? 0) < shots.count - 1
                            ) { moveScreenshot(by: 1, count: shots.count) }
                        }
                        .vesselGlassContainer(spacing: 8)
                        .padding(.horizontal, 12)
                        .opacity(mediaHovering ? 1 : 0.58)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: mediaHovering)
                    }
                }
                .onAppear {
                    if visibleScreenshotIndex == nil { visibleScreenshotIndex = 0 }
                }
                .onChange(of: shots.count) { _, count in
                    guard count > 0 else { visibleScreenshotIndex = nil; return }
                    visibleScreenshotIndex = min(visibleScreenshotIndex ?? 0, count - 1)
                }
                .accessibilityLabel("Carrusel de capturas")
                .accessibilityHint("Usa las flechas izquierda y derecha para recorrer las capturas; pulsa Intro para ampliar la seleccionada.")
            }
            .padding(.bottom, 22)
        }
    }

    private func moveScreenshot(by delta: Int, count: Int) {
        guard let next = GameDetailScrollBehavior.screenshotIndex(
            current: visibleScreenshotIndex,
            movingBy: delta,
            count: count
        ) else { return }
        if reduceMotion {
            visibleScreenshotIndex = next
        } else {
            withAnimation(.snappy(duration: 0.26)) {
                visibleScreenshotIndex = next
            }
        }
    }

    private func carouselArrow(
        _ icon: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .liquidGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.25)
        .accessibilityLabel(icon.contains("left") ? "Captura anterior" : "Captura siguiente")
        .vesselHelp(icon.contains("left") ? "Captura anterior" : "Captura siguiente",
                    shortcut: icon.contains("left") ? "←" : "→")
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
                                    GameCoverImage(cacheKey: "ach-\(game.id)-\(url.lastPathComponent)", candidates: [url]) {
                                        Theme.surface
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
                GameCoverImage(cacheKey: "achst-\(url.lastPathComponent)", candidates: [url]) {
                    Color.white.opacity(0.06)
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
                            GameCoverImage(cacheKey: "dlc-\(game.id)-\(dlc.id)", candidates: dlc.coverURL.map { [$0] } ?? []) {
                                Theme.surface
                            }
                            .frame(width: 66, height: 25)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .saturation(dlc.owned ? 1 : 0.1)   // los no poseídos, apagados
                            Text(dlc.title).font(.caption)
                                .foregroundStyle(.white.opacity(dlc.owned ? 0.85 : 0.5)).lineLimit(1)
                            Spacer(minLength: 0)
                            if dlc.installed == true {
                                Label("Instalado", systemImage: "checkmark.circle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(steamGreen.opacity(0.9))
                            } else if dlc.owned, dlc.installed == false, let onInstallDLC {
                                Button("Instalar") { onInstallDLC(dlc) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(tint)
                                    .disabled(installing)
                            } else if dlc.owned {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2).foregroundStyle(steamGreen.opacity(0.9))
                            }
                        }
                        .opacity(dlc.owned ? 1 : 0.5)   // atenúa el que no tienes para que no destaque
                    }
                    Text(store == .gog ? "Puedes instalar por separado el contenido que posees."
                        : (store == .epic ? "Contenido adicional disponible para este juego."
                           : "Los DLC marcados (✓) están en tu cuenta y se instalan junto al juego."))
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
                if let antiCheat = p.thirdPartyAntiCheat, !antiCheat.isEmpty {
                    Label("Usa anti-cheat de terceros: \(antiCheat). Los modos con controlador de kernel no son compatibles con Wine en macOS.",
                          systemImage: "exclamationmark.shield.fill")
                        .font(.caption).foregroundStyle(.orange.opacity(0.9))
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

    private func blockedAntiCheatSection(_ verdict: DRMDatabase.Verdict) -> some View {
        cardSection("Compatibilidad en Mac") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: CompatProfile.Rating.borked.systemImage)
                        .font(.title3).foregroundStyle(CompatProfile.Rating.borked.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("No funciona").font(.callout.bold()).foregroundStyle(.white)
                        Text("Bloqueado por anti-cheat en macOS")
                            .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    }
                }
                Label(verdict.antiCheats.joined(separator: " · "), systemImage: "shield.slash.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(CompatProfile.Rating.borked.color)
                Text("La base específica de macOS lo clasifica como \(verdict.antiCheatStatus?.lowercased() ?? "bloqueado"). Vessel no intenta desactivar ni eludir la protección; el modo multijugador protegido no puede iniciarse bajo Wine.")
                    .font(.caption).foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
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
    @MainActor private func loadDRMVerdict() async {
        drmVerdict = nil
        guard let appId = game.steamAppId, !appId.isEmpty else { return }
        let verdict = await DRMDatabase.shared.lookup(steamAppId: appId)
        guard !Task.isCancelled else { return }
        drmVerdict = verdict
    }

    @MainActor private func loadDetails() async {
        details = nil; dlcs = []; achievements = nil; detailsLoadFailed = false
        if let appId = game.steamAppId, !appId.isEmpty {
            await loadSteamDetails(appId)
            await loadAchievements(appId)
        } else if store == .gog {
            await loadGogDetails(game.id)
            dlcs = await loadStoreDLCs()
        } else if store == .epic {
            await loadEpicDetails(game.id)
            let ownedDLCs = await loadStoreDLCs()
            if !ownedDLCs.isEmpty { dlcs = ownedDLCs }
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
        guard let det = await Self.fetchSteamDetails(appId: appId) else {
            // Fallo de red/petición: antes quedaba indistinguible de "sin datos" y sin reintento.
            detailsLoadFailed = true
            return
        }
        detailsLoadFailed = false
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
    /// Con CACHÉ EN DISCO por DLC (`dlcmeta-<id>`): nombre y carátula no cambian, así que solo
    /// la primera visita a una ficha hace las ~12 peticiones; las siguientes son instantáneas.
    /// La posesión (`owned`) NO se cachea: depende de la cuenta y se recalcula siempre.
    @MainActor private func loadDLCs(_ ids: [Int]) async {
        dlcs = []
        guard !ids.isEmpty else { return }
        // Qué DLC posee el usuario (juegos+DLC de rgOwnedApps vía la sesión web). Vacío = sin datos
        // → no atenuamos (no sabemos). Se hace UNA vez para todos los DLC.
        let ownedApps = await SteamWebSession.shared.ownedAppIDs()
        func withOwnership(_ dlc: StoreDLC, id: Int) -> StoreDLC {
            var d = dlc
            d.owned = ownedApps.isEmpty || ownedApps.contains(id)
            return d
        }
        var resolved: [StoreDLC] = []
        var missing: [Int] = []
        for id in ids.prefix(12) {
            if let cached = LibraryCache.load("dlcmeta-\(id)", as: [StoreDLC].self)?.first {
                resolved.append(withOwnership(cached, id: id))
            } else {
                missing.append(id)
            }
        }
        if !missing.isEmpty {
            let fetched = await withTaskGroup(of: (Int, StoreDLC?)?.self) { group -> [(Int, StoreDLC?)] in
                for id in missing {
                    group.addTask {
                        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(id)&filters=basic&l=spanish"),
                              let (data, _) = try? await URLSession.shared.data(from: url),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let entry = obj["\(id)"] as? [String: Any],
                              (entry["success"] as? Bool) == true,
                              let d = entry["data"] as? [String: Any],
                              let name = d["name"] as? String else { return (id, nil) }
                        // La carátula: `header_image` REAL de appdetails (muchos DLC —packs de armadura,
                        // sombreros— NO tienen `capsule_231x87.jpg` → daba 404 y salía el hueco). Con el
                        // header_image cargan todos. Fallback al capsule por si acaso.
                        let cover = (d["header_image"] as? String).flatMap { URL(string: $0) }
                            ?? URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/capsule_231x87.jpg")
                        return (id, StoreDLC(id: "\(id)", title: name, coverURL: cover))
                    }
                }
                var out: [(Int, StoreDLC?)] = []
                for await pair in group { if let pair { out.append(pair) } }
                return out
            }
            for (id, dlc) in fetched {
                guard let dlc else { continue }
                LibraryCache.save("dlcmeta-\(id)", [dlc])
                resolved.append(withOwnership(dlc, id: id))
            }
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
                            accent: Color? = nil, badgeIcon: String? = nil,
                            action: @escaping () -> Void) -> some View {
        // Acento por defecto: el tinte de la tienda (el rosa anterior no está en la paleta de DESIGN.md).
        let accent = accent ?? tint
        return Button(action: action) {
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

/// Imagen del lightbox de capturas a resolución completa CON caché (memoria+disco) y
/// `scaledToFit`: `GameCoverImage` recorta (`scaledToFill`), inaceptable para ver una
/// captura entera. Misma caché compartida → navegar entre capturas es instantáneo.
private struct LightboxImage: View {
    let cacheKey: String
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: cacheKey) {
            guard let url else { return }
            if let hit = CoverCache.shared.cached(cacheKey) { image = hit; return }
            image = await CoverCache.shared.load(cacheKey, candidates: [url])
        }
    }
}
