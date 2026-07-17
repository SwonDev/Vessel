import SwiftUI

/// Acciones del juego seleccionado expuestas al menú nativo de macOS. Mantenerlas como
/// `FocusedValue` evita estado global y hace que los comandos actúen solo sobre la ventana activa.
struct LibraryFocusedActions {
    var primaryTitle: String?
    var performPrimary: (() -> Void)?
    var favoriteTitle: String?
    var toggleFavorite: (() -> Void)?
    var hiddenTitle: String?
    var toggleHidden: (() -> Void)?
    var revealInFinder: (() -> Void)?
    var copyTitle: (() -> Void)?
    var backToLibrary: (() -> Void)?
}

private struct LibraryFocusedActionsKey: FocusedValueKey {
    typealias Value = LibraryFocusedActions
}

extension FocusedValues {
    var libraryActions: LibraryFocusedActions? {
        get { self[LibraryFocusedActionsKey.self] }
        set { self[LibraryFocusedActionsKey.self] = newValue }
    }
}

struct LibraryGameCommands: Commands {
    @FocusedValue(\.libraryActions) private var actions

    var body: some Commands {
        CommandMenu("Juego") {
            Button(actions?.primaryTitle ?? "Jugar o instalar la selección") {
                actions?.performPrimary?()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(actions?.performPrimary == nil)

            Button(actions?.favoriteTitle ?? "Añadir a favoritos") {
                actions?.toggleFavorite?()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(actions?.toggleFavorite == nil)

            Button(actions?.hiddenTitle ?? "Ocultar de la biblioteca") {
                actions?.toggleHidden?()
            }
            .disabled(actions?.toggleHidden == nil)

            Divider()

            Button("Mostrar en Finder") {
                actions?.revealInFinder?()
            }
            .disabled(actions?.revealInFinder == nil)

            Button("Copiar nombre del juego") {
                actions?.copyTitle?()
            }
            .disabled(actions?.copyTitle == nil)

            Divider()

            Button("Volver a la biblioteca") {
                actions?.backToLibrary?()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(actions?.backToLibrary == nil)
        }
    }
}
