import Foundation
import Observation

/// Colecciones manuales de la biblioteca, equivalentes a las colecciones de Steam.
///
/// Se guardan como JSON local y solo contienen identificadores de juegos y la tienda a la que
/// pertenecen. Nunca modifican los archivos de los juegos ni sincronizan datos personales.
@MainActor
@Observable
final class LibraryCollectionsStore {
    struct Collection: Codable, Identifiable, Hashable {
        let id: UUID
        var name: String
        let storeID: String
        var gameIDs: Set<String>
        let createdAt: Date

        init(id: UUID = UUID(), name: String, storeID: String,
             gameIDs: Set<String> = [], createdAt: Date = Date()) {
            self.id = id
            self.name = name
            self.storeID = storeID
            self.gameIDs = gameIDs
            self.createdAt = createdAt
        }
    }

    static let shared = LibraryCollectionsStore()

    private(set) var collections: [Collection] = []
    private let fileURL: URL

    init(fileURL: URL = URL(fileURLWithPath: VesselPaths.appSupport, isDirectory: true)
        .appendingPathComponent("library-collections.json")) {
        self.fileURL = fileURL
        load()
    }

    func collections(for storeID: String) -> [Collection] {
        collections
            .filter { $0.storeID == storeID }
            .sorted { lhs, rhs in
                let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return result == .orderedSame ? lhs.createdAt < rhs.createdAt : result == .orderedAscending
            }
    }

    func collection(id: UUID) -> Collection? {
        collections.first { $0.id == id }
    }

    @discardableResult
    func create(name: String, storeID: String, including gameID: String? = nil) -> UUID? {
        let cleaned = Self.sanitizedName(name)
        guard !cleaned.isEmpty,
              !collections.contains(where: {
                  $0.storeID == storeID &&
                  $0.name.localizedCaseInsensitiveCompare(cleaned) == .orderedSame
              }) else { return nil }

        let collection = Collection(
            name: cleaned,
            storeID: storeID,
            gameIDs: gameID.map { Set([$0]) } ?? []
        )
        collections.append(collection)
        save()
        return collection.id
    }

    @discardableResult
    func rename(_ id: UUID, to name: String) -> Bool {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return false }
        let cleaned = Self.sanitizedName(name)
        guard !cleaned.isEmpty,
              !collections.contains(where: {
                  $0.id != id && $0.storeID == collections[index].storeID &&
                  $0.name.localizedCaseInsensitiveCompare(cleaned) == .orderedSame
              }) else { return false }
        collections[index].name = cleaned
        save()
        return true
    }

    func delete(_ id: UUID) {
        collections.removeAll { $0.id == id }
        save()
    }

    func contains(gameID: String, in collectionID: UUID) -> Bool {
        collection(id: collectionID)?.gameIDs.contains(gameID) == true
    }

    /// Añade un juego sin alternar su estado. Es idempotente para que soltar dos veces la misma
    /// carátula nunca la retire accidentalmente de la colección.
    @discardableResult
    func add(gameID: String, to collectionID: UUID) -> Bool {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return false }
        let inserted = collections[index].gameIDs.insert(gameID).inserted
        if inserted { save() }
        return inserted
    }

    func toggle(gameID: String, in collectionID: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if collections[index].gameIDs.contains(gameID) {
            collections[index].gameIDs.remove(gameID)
        } else {
            collections[index].gameIDs.insert(gameID)
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Collection].self, from: data) else { return }
        collections = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(collections).write(to: fileURL, options: .atomic)
        } catch {
            LogStore.shared.log("No se pudieron guardar las colecciones: \(error.localizedDescription)", level: .error)
        }
    }

    static func sanitizedName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
    }
}
