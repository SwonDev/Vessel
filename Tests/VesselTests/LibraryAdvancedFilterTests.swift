import Testing
@testable import Vessel

@Suite("Filtros avanzados de biblioteca")
struct LibraryAdvancedFilterTests {
    @Test("Agrupa correctamente los niveles de compatibilidad")
    func compatibilityGroups() {
        #expect(LibraryCompatibilityFilter.excelente.matches(.platinum))
        #expect(LibraryCompatibilityFilter.excelente.matches(.gold))
        #expect(!LibraryCompatibilityFilter.excelente.matches(.silver))
        #expect(LibraryCompatibilityFilter.jugable.matches(.silver))
        #expect(LibraryCompatibilityFilter.jugable.matches(.bronze))
        #expect(LibraryCompatibilityFilter.noFunciona.matches(.borked))
        #expect(LibraryCompatibilityFilter.sinDatos.matches(nil))
    }

    @Test("Los límites de tamaño no dejan huecos")
    func sizeBoundaries() {
        #expect(LibrarySizeFilter.pequeño.matches(9_999_999_999))
        #expect(LibrarySizeFilter.mediano.matches(10_000_000_000))
        #expect(LibrarySizeFilter.mediano.matches(50_000_000_000))
        #expect(LibrarySizeFilter.grande.matches(50_000_000_001))
        #expect(LibrarySizeFilter.sinDatos.matches(nil))
    }

    @Test("El género ignora mayúsculas y conserva el caso sin selección")
    func genreMatching() {
        #expect(LibraryAdvancedFilterRules.matchesGenre(["Acción", "RPG"], selected: "acción"))
        #expect(!LibraryAdvancedFilterRules.matchesGenre(["Estrategia"], selected: "Acción"))
        #expect(LibraryAdvancedFilterRules.matchesGenre([], selected: nil))
    }

    @Test("Steam lee SizeOnDisk del manifiesto local")
    func steamManifestSize() {
        let manifest = #"""
        "AppState"
        {
            "appid"       "620"
            "SizeOnDisk"  "123456789"
        }
        """#
        #expect(SteamCMDManager.sizeOnDisk(in: manifest) == 123_456_789)
    }
}
