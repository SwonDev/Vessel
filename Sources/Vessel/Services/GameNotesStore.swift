import Foundation
import Observation

/// Notas privadas por juego. Se guardan únicamente en el soporte local de Vessel y nunca se
/// incluyen en informes de compatibilidad, registros ni solicitudes de red.
@MainActor
@Observable
final class GameNotesStore {
    struct Note: Codable, Equatable {
        var text: String
        var updatedAt: Date
    }

    static let shared = GameNotesStore()
    static let maximumLength = 50_000

    private(set) var notes: [String: Note] = [:]
    private let fileURL: URL

    init(fileURL: URL = URL(fileURLWithPath: VesselPaths.appSupport, isDirectory: true)
        .appendingPathComponent("game-notes.json")) {
        self.fileURL = fileURL
        load()
    }

    func note(storeID: String, gameID: String) -> Note? {
        notes[Self.key(storeID: storeID, gameID: gameID)]
    }

    func hasNote(storeID: String, gameID: String) -> Bool {
        note(storeID: storeID, gameID: gameID) != nil
    }

    func update(storeID: String, gameID: String, text: String, now: Date = Date()) {
        let key = Self.key(storeID: storeID, gameID: gameID)
        let normalized = Self.normalizedText(text)
        if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.removeValue(forKey: key)
        } else {
            notes[key] = Note(text: normalized, updatedAt: now)
        }
        save()
    }

    func remove(storeID: String, gameID: String) {
        notes.removeValue(forKey: Self.key(storeID: storeID, gameID: gameID))
        save()
    }

    static func normalizedText(_ text: String) -> String {
        String(text.prefix(maximumLength))
    }

    private static func key(storeID: String, gameID: String) -> String {
        "\(storeID):\(gameID)"
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Note].self, from: data) else { return }
        notes = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(notes).write(to: fileURL, options: .atomic)
        } catch {
            LogStore.shared.log("No se pudieron guardar las notas: \(error.localizedDescription)", level: .error)
        }
    }
}
