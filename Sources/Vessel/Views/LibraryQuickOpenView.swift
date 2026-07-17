import SwiftUI

/// Búsqueda de apertura rápida para bibliotecas grandes. No sustituye al filtro visible: ofrece
/// un flujo de teclado efímero para saltar a un juego sin cambiar la consulta actual.
struct LibraryQuickOpenView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var selectedID: String?
    @FocusState private var searchFocused: Bool

    let store: StoreKind
    let games: [StoreGame]
    let favorites: Set<String>
    let tint: Color
    let onOpen: (StoreGame) -> Void

    private var results: [StoreGame] {
        LibraryQuickOpenSearch.results(in: games, matching: query, favorites: favorites)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.12)
            resultsPane
            Divider().opacity(0.12)
            footer
        }
        .frame(width: 620, height: 520)
        .vesselBackground(tint: tint)
        .onAppear {
            selectedID = results.first?.id
            searchFocused = true
        }
        .onChange(of: query) { _, _ in selectedID = results.first?.id }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "command")
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
            TextField("Buscar un juego en \(store.displayName)…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3.weight(.medium))
                .focused($searchFocused)
                .onSubmit(openSelected)
                .accessibilityLabel("Buscar y abrir un juego")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Borrar búsqueda")
                .vesselHelp("Borrar búsqueda")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    @ViewBuilder private var resultsPane: some View {
        if results.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("No hay juegos que coincidan con «\(query)»")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { game in
                            LibraryQuickOpenRow(
                                game: game,
                                selected: selectedID == game.id,
                                favorite: favorites.contains(game.id),
                                tint: tint
                            ) {
                                open(game)
                            }
                            .id(game.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: selectedID) { _, newValue in
                    guard let newValue else { return }
                    if reduceMotion { proxy.scrollTo(newValue, anchor: .center) }
                    else { withAnimation(.smooth(duration: 0.18)) { proxy.scrollTo(newValue, anchor: .center) } }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Label(query.isEmpty ? "Jugados recientemente y favoritos" : "\(results.count) resultados",
                  systemImage: query.isEmpty ? "clock" : "line.3.horizontal.decrease")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("↑↓ Seleccionar   ↩ Abrir   Esc Cerrar")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Usa flecha arriba y abajo para seleccionar, Intro para abrir y Escape para cerrar")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func openSelected() {
        guard let selectedID, let game = results.first(where: { $0.id == selectedID }) else { return }
        open(game)
    }

    private func open(_ game: StoreGame) {
        onOpen(game)
        dismiss()
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !results.isEmpty else { return }
        let index = selectedID.flatMap { id in results.firstIndex(where: { $0.id == id }) } ?? 0
        switch direction {
        case .up:
            selectedID = results[max(0, index - 1)].id
        case .down:
            selectedID = results[min(results.count - 1, index + 1)].id
        default:
            break
        }
    }
}

enum LibraryQuickOpenSearch {
    static func results(in games: [StoreGame], matching query: String,
                        favorites: Set<String>, limit: Int = 14) -> [StoreGame] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted: [StoreGame]

        if normalizedQuery.isEmpty {
            sorted = games.sorted { lhs, rhs in
                switch (lhs.lastPlayed, rhs.lastPlayed) {
                case let (left?, right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
                if favorites.contains(lhs.id) != favorites.contains(rhs.id) {
                    return favorites.contains(lhs.id)
                }
                if lhs.installed != rhs.installed { return lhs.installed }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        } else {
            sorted = games.compactMap { game -> (StoreGame, Int)? in
                guard let score = LibraryTitleSearch.score(title: game.title, query: normalizedQuery) else {
                    return nil
                }
                return (game, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.installed != rhs.0.installed { return lhs.0.installed }
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }
            .map(\.0)
        }

        return Array(sorted.prefix(max(0, limit)))
    }
}

private struct LibraryQuickOpenRow: View {
    let game: StoreGame
    let selected: Bool
    let favorite: Bool
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                GameCoverImage(cacheKey: "quick-\(game.id)", candidates: game.coverCandidates) {
                    ZStack {
                        game.placeholderColor
                        Text(game.initials).font(.caption.weight(.bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 34, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(game.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Label(game.installed ? "Instalado" : "Sin instalar",
                              systemImage: game.installed ? "checkmark.circle.fill" : "icloud.and.arrow.down")
                        if let lastPlayed = game.lastPlayed {
                            let relative = lastPlayed.formatted(
                                .relative(presentation: .named)
                                    .locale(Locale(identifier: "es_ES"))
                            )
                            Text("·")
                            Text("Jugado \(relative)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if favorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                }
                if selected {
                    Image(systemName: "return")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                ZStack {
                    if selected { Color.clear.liquidGlass(in: shape, interactive: true) }
                    if selected { shape.fill(tint.opacity(0.12)) }
                    else if hovering { shape.fill(.white.opacity(0.06)) }
                }
            }
            .overlay { shape.strokeBorder(tint.opacity(selected ? 0.42 : 0), lineWidth: 0.8) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(game.title)
        .accessibilityValue(game.installed ? "Instalado" : "Sin instalar")
        .accessibilityHint("Abre los detalles del juego")
    }
}
