import Foundation
import Testing
@testable import Vessel

@MainActor
struct GameNotesStoreTests {
    @Test("Las notas se guardan por tienda y juego")
    func persistsNotesPerGame() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-notes-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("notes.json")
        defer { try? FileManager.default.removeItem(at: folder) }

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = GameNotesStore(fileURL: file)
        store.update(storeID: "steam", gameID: "10", text: "Buscar la llave", now: date)
        store.update(storeID: "gog", gameID: "10", text: "Partida alternativa", now: date)

        let reloaded = GameNotesStore(fileURL: file)
        #expect(reloaded.note(storeID: "steam", gameID: "10")?.text == "Buscar la llave")
        #expect(reloaded.note(storeID: "steam", gameID: "10")?.updatedAt == date)
        #expect(reloaded.note(storeID: "gog", gameID: "10")?.text == "Partida alternativa")
        #expect(reloaded.note(storeID: "epic", gameID: "10") == nil)
    }

    @Test("Las notas vacías se eliminan y el tamaño queda limitado")
    func removesEmptyAndLimitsLength() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-notes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = GameNotesStore(fileURL: file)

        store.update(storeID: "steam", gameID: "20", text: String(repeating: "a", count: 60_000))
        #expect(store.note(storeID: "steam", gameID: "20")?.text.count == GameNotesStore.maximumLength)

        store.update(storeID: "steam", gameID: "20", text: " \n ")
        #expect(store.note(storeID: "steam", gameID: "20") == nil)
    }
}
