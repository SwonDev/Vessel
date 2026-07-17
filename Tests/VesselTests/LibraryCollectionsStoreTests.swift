import Foundation
import Testing
@testable import Vessel

@MainActor
struct LibraryCollectionsStoreTests {
    @Test("Las colecciones se crean, renombran y persisten por tienda")
    func persistsCollectionsPerStore() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-collections-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("collections.json")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = LibraryCollectionsStore(fileURL: file)
        let id = try #require(store.create(name: "  Cooperativos  ", storeID: "steam", including: "10"))
        #expect(store.collections(for: "steam").first?.name == "Cooperativos")
        #expect(store.contains(gameID: "10", in: id))

        store.toggle(gameID: "20", in: id)
        #expect(store.contains(gameID: "20", in: id))
        #expect(store.rename(id, to: "Para el fin de semana"))

        let reloaded = LibraryCollectionsStore(fileURL: file)
        #expect(reloaded.collections(for: "steam").count == 1)
        #expect(reloaded.collection(id: id)?.name == "Para el fin de semana")
        #expect(reloaded.collection(id: id)?.gameIDs == ["10", "20"])
        #expect(reloaded.collections(for: "gog").isEmpty)
    }

    @Test("No admite nombres vacíos ni duplicados dentro de la misma tienda")
    func rejectsInvalidNames() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-collections-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("collections.json")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = LibraryCollectionsStore(fileURL: file)
        #expect(store.create(name: "   ", storeID: "steam") == nil)
        _ = try #require(store.create(name: "RPG", storeID: "steam"))
        #expect(store.create(name: "rpg", storeID: "steam") == nil)
        #expect(store.create(name: "RPG", storeID: "gog") != nil)
    }

    @Test("Soltar un juego en una colección es idempotente y persiste")
    func addsDroppedGameOnlyOnce() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-collection-drop-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("collections.json")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = LibraryCollectionsStore(fileURL: file)
        let id = try #require(store.create(name: "Para jugar", storeID: "steam"))

        #expect(store.add(gameID: "219990", to: id))
        #expect(!store.add(gameID: "219990", to: id))
        #expect(store.collection(id: id)?.gameIDs == ["219990"])

        let reloaded = LibraryCollectionsStore(fileURL: file)
        #expect(reloaded.collection(id: id)?.gameIDs == ["219990"])
    }

}
