import Foundation
import Testing
@testable import Vessel

struct LibraryQuickOpenSearchTests {
    @Test("La búsqueda ignora mayúsculas y diacríticos y prioriza coincidencias exactas")
    func ranksMatches() {
        let games = [
            StoreGame(id: "1", title: "Pokémon Mundo", installed: true),
            StoreGame(id: "2", title: "Mundo Pokémon", installed: true),
            StoreGame(id: "3", title: "Pokemon", installed: false),
            StoreGame(id: "4", title: "Otro juego", installed: true)
        ]

        let results = LibraryQuickOpenSearch.results(in: games, matching: "POKEMON", favorites: [])
        #expect(results.map(\.id) == ["3", "1", "2"])
    }

    @Test("Sin consulta sugiere recientes y después favoritos")
    func suggestsRecentAndFavorites() {
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 200)
        let games = [
            StoreGame(id: "favorite", title: "Favorito", installed: true),
            StoreGame(id: "old", title: "Antiguo", installed: true, lastPlayed: old),
            StoreGame(id: "recent", title: "Reciente", installed: true, lastPlayed: recent)
        ]

        let results = LibraryQuickOpenSearch.results(
            in: games,
            matching: "",
            favorites: ["favorite"]
        )
        #expect(results.map(\.id) == ["recent", "old", "favorite"])
    }
}
