import SwiftUI
import AppKit

// MARK: - Ámbito rápido de biblioteca

/// Cápsula de filtro con cristal neutro. La selección usa solo un velo y borde de acento,
/// respetando el contrato Liquid Glass de `DESIGN.md` sin convertir el cristal en un relleno plano.
struct LibraryScopeChip: View {
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
                if selected { shape.fill(tint.opacity(0.12)) }
            }
            // El cristal se aplica a etiqueta + superficie como una unidad. Dentro de un
            // GlassEffectContainer, aplicarlo a un `Color.clear` de fondo puede elevar esa capa
            // por encima del texto y difuminarlo en macOS 26.
            .liquidGlass(in: shape, interactive: true)
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
struct LibraryCollectionScopeMenu: View {
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
                if selected != nil || dropTargeted {
                    shape.fill(tint.opacity(dropTargeted ? 0.20 : 0.12))
                }
            }
            .liquidGlass(in: shape, interactive: true)
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

// MARK: - Actividad reciente

/// Estantería compacta equivalente a «Novedades» de Steam, alimentada únicamente por operaciones
/// que Vessel ha observado de verdad. No inventa notas de parche ni depende de una API desigual
/// entre tiendas: muestra la continuidad local común a Steam, Epic y GOG.
struct LibraryActivitySection: View {
    let events: [LibraryActivityStore.Event]
    let games: [StoreGame]
    let tint: Color
    let onOpen: (StoreGame) -> Void

    private var gamesByID: [String: StoreGame] {
        Dictionary(games.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Actividad reciente")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(events) { event in
                        LibraryActivityCard(
                            event: event,
                            game: gamesByID[event.gameID],
                            tint: tint,
                            onOpen: gamesByID[event.gameID].map { game in { onOpen(game) } }
                        )
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollClipDisabled()
            .accessibilityLabel("Actividad reciente de la biblioteca")
        }
    }
}

private struct LibraryActivityCard: View {
    let event: LibraryActivityStore.Event
    let game: StoreGame?
    let tint: Color
    let onOpen: (() -> Void)?

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) { content }
                    .buttonStyle(.plain)
                    .accessibilityHint("Abre los detalles del juego")
            } else {
                content
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
    }

    private var content: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return HStack(spacing: 12) {
            cover

            VStack(alignment: .leading, spacing: 6) {
                Text(event.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(event.outcome == .failed ? Color.white : statusColor)
                        .lineLimit(1)
                }

                Text(event.outcome == .failed ? (event.detail ?? relativeDate) : relativeDate)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: 292, height: 106, alignment: .leading)
        .background(shape.fill(.white.opacity(hovering ? 0.085 : 0.045)))
        .overlay { shape.strokeBorder(.white.opacity(hovering ? 0.16 : 0.08), lineWidth: 0.6) }
        .shadow(color: .black.opacity(hovering ? 0.26 : 0.14), radius: hovering ? 10 : 5, y: 4)
        .contentShape(shape)
    }

    @ViewBuilder private var cover: some View {
        if let game {
            GameCoverImage(cacheKey: "activity-\(game.id)", candidates: game.coverCandidates) {
                activityPlaceholder(initials: game.initials, color: game.placeholderColor)
            }
            .frame(width: 56, height: 82)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            activityPlaceholder(initials: initials, color: tint.opacity(0.42))
                .frame(width: 56, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func activityPlaceholder(initials: String, color: Color) -> some View {
        ZStack {
            color
            Text(initials)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.88))
        }
    }

    private var initials: String {
        event.title.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var statusIcon: String {
        if event.outcome == .failed { return "exclamationmark.triangle.fill" }
        if event.outcome == .cancelled { return "xmark.circle.fill" }
        switch event.kind {
        case .install: return "arrow.down.circle.fill"
        case .update: return "arrow.triangle.2.circlepath.circle.fill"
        case .verify: return "checkmark.shield.fill"
        case .uninstall: return "checkmark.circle.fill"
        case .dlc: return "puzzlepiece.extension.fill"
        }
    }

    private var statusText: String {
        switch event.outcome {
        case .failed:
            return "No se pudo completar"
        case .cancelled:
            return "Operación cancelada"
        case .completed:
            switch event.kind {
            case .install: return "Instalación completada"
            case .update: return "Actualización completada"
            case .verify: return "Archivos verificados"
            case .uninstall: return "Desinstalación completada"
            case .dlc: return "Contenido instalado"
            }
        }
    }

    private var statusColor: Color {
        switch event.outcome {
        case .completed: Theme.play
        case .failed: Theme.destructive
        case .cancelled: Theme.secondaryText
        }
    }

    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: event.occurredAt, relativeTo: .now)
    }

    private var accessibilitySummary: String {
        let detail = event.outcome == .failed ? event.detail : nil
        return [event.title, statusText, detail, relativeDate].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Centro de descargas

/// Acceso efímero a las operaciones activas. Replica la utilidad de la barra inferior de Steam,
/// pero desaparece por completo cuando no hay trabajo para conservar la biblioteca despejada.
struct LibraryTransferCenterButton: View {
    let items: [LibraryTransferItem]
    let games: [StoreGame]
    let tint: Color
    @Binding var isPresented: Bool
    let onOpen: (StoreGame) -> Void
    let onPause: (StoreGame) -> Void
    let onResume: (StoreGame) -> Void
    let onCancel: (StoreGame) -> Void
    let onPrioritize: (StoreGame) -> Void
    let onRetry: (StoreGame) -> Void

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
            LibraryTransferCenterPopover(
                items: items,
                games: games,
                tint: tint,
                onOpen: onOpen,
                onPause: onPause,
                onResume: onResume,
                onCancel: onCancel,
                onPrioritize: onPrioritize,
                onRetry: onRetry
            )
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

struct LibraryTransferCenterPopover: View {
    let items: [LibraryTransferItem]
    let games: [StoreGame]
    let tint: Color
    let onOpen: (StoreGame) -> Void
    let onPause: (StoreGame) -> Void
    let onResume: (StoreGame) -> Void
    let onCancel: (StoreGame) -> Void
    let onPrioritize: (StoreGame) -> Void
    let onRetry: (StoreGame) -> Void

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
                    Text("Cola de descargas")
                        .font(.headline)
                    Text("\(items.count) operación\(items.count == 1 ? "" : "es")")
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
                            LibraryTransferRow(
                                item: item,
                                game: game,
                                tint: tint,
                                onOpen: { onOpen(game) },
                                onPause: { onPause(game) },
                                onResume: { onResume(game) },
                                onCancel: { onCancel(game) },
                                onPrioritize: { onPrioritize(game) },
                                onRetry: { onRetry(game) }
                            )
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 330)

            Divider().opacity(0.14)
            Label("La cola se conserva al cerrar Vessel", systemImage: "checkmark.icloud")
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

struct LibraryTransferRow: View {
    let item: LibraryTransferItem
    let game: StoreGame
    let tint: Color
    let onOpen: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onPrioritize: () -> Void
    let onRetry: () -> Void
    @State private var hovering = false
    /// Cancelar una descarga pierde lo ya bajado: pide confirmación antes de llamar a `onCancel`.
    @State private var cancelConfirmationPresented = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        HStack(spacing: 8) {
            Button(action: onOpen) {
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

                        HStack(spacing: 5) {
                            phaseIcon
                            Text(item.message)
                                .font(.caption)
                                .foregroundStyle(item.phase == .failed ? Color.primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if let fraction = item.fractionCompleted {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .tint(tint)
                        } else if [.running, .pausing, .cancelling].contains(item.phase) {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(tint)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            transferControls
        }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                if hovering { shape.fill(.white.opacity(0.055)) }
            }
            .contentShape(shape)
        .onHover { hovering = $0 }
        .accessibilityLabel(game.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Abre los detalles o gestiona la operación")
    }

    @ViewBuilder private var phaseIcon: some View {
        switch item.phase {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(tint)
        case .pausing, .cancelling:
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        case .paused:
            Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.destructive.opacity(0.92))
        }
    }

    @ViewBuilder private var transferControls: some View {
        HStack(spacing: 3) {
            if item.canRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Reintentar")
                .vesselHelp("Reintentar")
            } else if item.phase == .paused {
                Button(action: onResume) {
                    Image(systemName: "play.fill")
                }
                .accessibilityLabel("Reanudar")
                .vesselHelp("Reanudar")
            } else if item.canPause {
                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                }
                .accessibilityLabel("Pausar")
                .vesselHelp("Pausar")
            }

            Menu {
                if item.canPrioritize {
                    Button(action: onPrioritize) {
                        Label("Priorizar", systemImage: "arrow.up.to.line")
                    }
                }
                if item.canCancel {
                    Button(role: .destructive) { cancelConfirmationPresented = true } label: {
                        Label("Cancelar", systemImage: "xmark")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(!item.canPrioritize && !item.canCancel)
            .accessibilityLabel("Más acciones de la descarga")
            .vesselHelp("Más acciones")
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .confirmationDialog("¿Cancelar la descarga de «\(game.title)»?",
                            isPresented: $cancelConfirmationPresented) {
            Button("Cancelar descarga", role: .destructive, action: onCancel)
            Button("Seguir descargando", role: .cancel) { }
        } message: {
            Text("Se perderá el progreso no escrito a disco. Podrás reanudarla más tarde desde el principio del tramo pendiente.")
        }
    }

    private var accessibilityValue: String {
        guard let fraction = item.fractionCompleted else { return item.message }
        return "\(item.message), \(fraction.formatted(.percent.precision(.fractionLength(0)))) completado"
    }
}

/// Confirmación reversible para acciones que retiran contenido de la vista. El botón interior es
/// plano a propósito: el contenedor ya es cristal y DESIGN.md prohíbe apilar cristal sobre cristal.
struct LibraryUndoBanner: View {
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

/// Aplica geometría compartida solo cuando existe un espacio de transición. Mantener la decisión
/// en un modificador evita duplicar ramas de vista y deja un fallback idéntico con Reducir movimiento.
struct GameArtworkTransitionModifier: ViewModifier {
    let gameID: String
    let namespace: Namespace.ID?
    let isSource: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(
                id: "game-artwork-\(gameID)",
                in: namespace,
                properties: .frame,
                anchor: .center,
                isSource: isSource
            )
        } else {
            content
        }
    }
}

extension View {
    func gameArtworkTransition(
        gameID: String,
        namespace: Namespace.ID?,
        isSource: Bool
    ) -> some View {
        modifier(GameArtworkTransitionModifier(
            gameID: gameID,
            namespace: namespace,
            isSource: isSource
        ))
    }
}

/// Tarjeta de juego **genérica y premium** (carátula 2:3 + título superpuesto + favorito +
/// botón Instalar/Jugar). Misma para todas las tiendas; `tint` la colorea.
struct StoreGameCard: View {
    let game: StoreGame
    let tint: Color
    var artworkTransitionNamespace: Namespace.ID? = nil
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
                    .gameArtworkTransition(
                        gameID: game.id,
                        namespace: artworkTransitionNamespace,
                        isSource: true
                    )
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
                        .tint(Theme.play)
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
                                     : (game.installed ? Theme.play : .white.opacity(0.4)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(1)
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
