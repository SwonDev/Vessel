import Testing
@testable import Vessel

@Suite("Centro de descargas de la biblioteca")
struct LibraryTransferSnapshotTests {
    @Test("Incluye solo operaciones activas, ordena y normaliza el progreso")
    func buildsActiveSnapshot() {
        let games = [
            StoreGame(id: "z", title: "Zeta"),
            StoreGame(id: "a", title: "Ábaco"),
            StoreGame(id: "idle", title: "Inactivo")
        ]

        let items = LibraryTransferSnapshot.items(
            games: games,
            activeIDs: ["z", "a"],
            progressFor: { $0 == "z" ? "  Descargando  " : "" },
            percentFor: { $0 == "z" ? 1.4 : -0.2 }
        )

        #expect(items.map(\.id) == ["a", "z"])
        #expect(items.map(\.message) == ["Preparando…", "Descargando"])
        #expect(items.map(\.fractionCompleted) == [0, 1])
        #expect(LibraryTransferSnapshot.overallProgress(for: items) == 0.5)
    }

    @Test("El progreso conjunto es indeterminado si alguna fase no ofrece porcentaje")
    func keepsMixedProgressIndeterminate() {
        let items = [
            LibraryTransferItem(id: "1", title: "Uno", message: "Descargando", fractionCompleted: 0.4),
            LibraryTransferItem(id: "2", title: "Dos", message: "Verificando", fractionCompleted: nil)
        ]

        #expect(LibraryTransferSnapshot.overallProgress(for: items) == nil)
        #expect(LibraryTransferSnapshot.overallProgress(for: []) == nil)
    }

    @Test("Respeta el orden real de la cola y excluye pausas del progreso conjunto")
    func reflectsQueueOrderAndActiveProgress() {
        let games = [
            StoreGame(id: "a", title: "Alfa"),
            StoreGame(id: "b", title: "Beta"),
            StoreGame(id: "c", title: "Charlie")
        ]
        let positions = ["a": 2, "b": 0, "c": 1]
        let phases: [String: LibraryTransferPhase] = ["a": .paused, "b": .running, "c": .queued]

        let items = LibraryTransferSnapshot.items(
            games: games,
            activeIDs: Set(games.map(\.id)),
            progressFor: { _ in "Preparando" },
            percentFor: { $0 == "b" ? 0.75 : nil },
            phaseFor: { phases[$0] ?? .queued },
            positionFor: { positions[$0] }
        )

        #expect(items.map(\.id) == ["b", "c", "a"])
        #expect(LibraryTransferSnapshot.overallProgress(for: items) == 0.75)
    }
}
