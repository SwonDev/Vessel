import Testing
@testable import Vessel

@Suite("Sincronización de la ficha con la biblioteca")
struct StoreGameStateResolverTests {
    @Test("Una instalación terminada cambia la acción primaria a Jugar sin navegar")
    func completedInstallRefreshesOpenDetail() {
        let selectedBeforeInstall = StoreGame(
            id: "212680",
            title: "FTL: Faster Than Light",
            steamAppId: "212680",
            installed: false
        )
        let installedLibraryGame = StoreGame(
            id: "212680",
            title: "FTL: Faster Than Light",
            steamAppId: "212680",
            installed: true,
            installPath: "/Bottle/Steam/steamapps/common/FTL"
        )

        let current = StoreGameStateResolver.currentSelection(
            selected: selectedBeforeInstall,
            availableGames: [installedLibraryGame]
        )

        #expect(current?.installed == true)
        #expect(current?.installPath == installedLibraryGame.installPath)
    }

    @Test("Conserva temporalmente la selección si una recarga todavía no devuelve el juego")
    func keepsSelectionDuringTransientReload() {
        let selected = StoreGame(id: "42", title: "Juego", installed: true)

        let current = StoreGameStateResolver.currentSelection(
            selected: selected,
            availableGames: []
        )

        #expect(current == selected)
    }
}
