import Testing
@testable import Vessel

@Suite("Búsqueda tolerante de títulos")
struct LibraryTitleSearchTests {
    @Test("Ignora diacríticos, mayúsculas y puntuación")
    func normalizesHumanInput() {
        #expect(LibraryTitleSearch.matches(title: "Pokémon: Edición Áurea", query: "pokemon aurea"))
        #expect(LibraryTitleSearch.matches(title: "NieR:Automata", query: "nierauto"))
        #expect(LibraryTitleSearch.matches(title: "AK-xolotl: Together", query: "akx"))
    }

    @Test("Acepta abreviaturas y fragmentos de varias palabras")
    func matchesAcronymsAndTerms() {
        #expect(LibraryTitleSearch.matches(title: "Cassette Beasts", query: "cb"))
        #expect(LibraryTitleSearch.matches(title: "The Elder Scrolls Online", query: "elder onl"))
        #expect(!LibraryTitleSearch.matches(title: "PC Building Simulator", query: "cb"))
        #expect(!LibraryTitleSearch.matches(title: "Cassette Beasts", query: "core keeper"))
    }

    @Test("Las coincidencias exactas se ordenan antes que prefijos y abreviaturas")
    func ranksSpecificMatchesFirst() {
        let exact = LibraryTitleSearch.score(title: "FEZ", query: "fez")
        let prefix = LibraryTitleSearch.score(title: "Fez II", query: "fez")
        let acronym = LibraryTitleSearch.score(title: "Final Epic Zone", query: "fez")

        #expect(exact == 0)
        #expect(prefix == 1)
        #expect(acronym == 5)
    }
}
