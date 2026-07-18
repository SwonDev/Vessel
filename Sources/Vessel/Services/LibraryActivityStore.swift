import Foundation

/// Historial local y fiable de la actividad de las tiendas. A diferencia de un feed remoto de
/// noticias, cada evento procede de una operación que Vessel ejecutó realmente y puede explicarse
/// incluso sin conexión. Se conserva una ventana pequeña para aportar continuidad sin convertirse
/// en un registro técnico ni crecer indefinidamente.
@MainActor
@Observable
final class LibraryActivityStore {
    enum Outcome: String, Codable, Sendable {
        case completed
        case failed
        case cancelled
    }

    struct Event: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        let storeID: String
        let gameID: String
        let title: String
        let kind: LibraryOperationKind
        let outcome: Outcome
        let occurredAt: Date
        let detail: String?

        init(
            id: UUID = UUID(),
            storeID: String,
            gameID: String,
            title: String,
            kind: LibraryOperationKind,
            outcome: Outcome,
            occurredAt: Date = .now,
            detail: String? = nil
        ) {
            self.id = id
            self.storeID = storeID
            self.gameID = gameID
            self.title = title
            self.kind = kind
            self.outcome = outcome
            self.occurredAt = occurredAt
            self.detail = detail
        }
    }

    static let shared = LibraryActivityStore()

    private(set) var events: [Event]

    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumEventCount: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "vessel.libraryActivity",
        maximumEventCount: Int = 48
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maximumEventCount = max(1, maximumEventCount)
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Event].self, from: data) {
            self.events = Array(decoded.sorted { $0.occurredAt > $1.occurredAt }
                .prefix(self.maximumEventCount))
        } else {
            self.events = []
        }
    }

    func record(
        storeID: String,
        operation: LibraryOperationQueue.Operation,
        outcome: Outcome,
        detail: String? = nil,
        occurredAt: Date = .now
    ) {
        let cleanDetail = detail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(240)
            .description
        let event = Event(
            storeID: storeID,
            gameID: operation.gameID,
            title: operation.title,
            kind: operation.kind,
            outcome: outcome,
            occurredAt: occurredAt,
            detail: cleanDetail?.isEmpty == false ? cleanDetail : nil
        )
        events.append(event)
        events.sort { $0.occurredAt > $1.occurredAt }
        if events.count > maximumEventCount {
            events.removeLast(events.count - maximumEventCount)
        }
        persist()
    }

    func recent(storeID: String, limit: Int = 6) -> [Event] {
        guard limit > 0 else { return [] }
        return Array(events.lazy.filter { $0.storeID == storeID }.prefix(limit))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
