import Foundation
import Testing
@testable import Vessel

@Suite("Actividad reciente de la biblioteca")
struct LibraryActivityStoreTests {
    @Test("Persiste, filtra por tienda y limita el historial")
    @MainActor
    func persistsFiltersAndTrims() {
        let suiteName = "LibraryActivityStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = LibraryActivityStore(
            defaults: defaults,
            storageKey: "activity",
            maximumEventCount: 3
        )
        store.record(storeID: "steam", operation: operation("a", .install), outcome: .completed,
                     occurredAt: Date(timeIntervalSince1970: 1))
        store.record(storeID: "epic", operation: operation("b", .update), outcome: .failed,
                     detail: "Sin conexión", occurredAt: Date(timeIntervalSince1970: 2))
        store.record(storeID: "steam", operation: operation("c", .verify), outcome: .completed,
                     occurredAt: Date(timeIntervalSince1970: 3))
        store.record(storeID: "gog", operation: operation("d", .dlc), outcome: .cancelled,
                     occurredAt: Date(timeIntervalSince1970: 4))

        #expect(store.events.map(\.gameID) == ["d", "c", "b"])
        #expect(store.recent(storeID: "steam").map(\.gameID) == ["c"])
        #expect(store.recent(storeID: "epic").first?.detail == "Sin conexión")

        let restored = LibraryActivityStore(
            defaults: defaults,
            storageKey: "activity",
            maximumEventCount: 3
        )
        #expect(restored.events == store.events)
    }

    @Test("La cola registra éxitos, fallos y cancelaciones sin duplicar un fallo descartado")
    @MainActor
    func queueRecordsRealOutcomes() async {
        let suiteName = "LibraryActivityQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activity = LibraryActivityStore(defaults: defaults, storageKey: "activity")

        let successKey = "activity-success-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "vessel.operationQueue.\(successKey)") }
        let success = LibraryOperationQueue(
            storageKey: successKey,
            activityStore: activity,
            activityStoreID: "steam"
        )
        success.enqueue(gameID: "success", title: "Éxito", kind: .update) { _ in }
        await waitUntil { !success.hasItems }

        let failureKey = "activity-failure-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "vessel.operationQueue.\(failureKey)") }
        let failure = LibraryOperationQueue(
            storageKey: failureKey,
            activityStore: activity,
            activityStoreID: "epic"
        )
        failure.enqueue(gameID: "failure", title: "Fallo", kind: .verify) { _ in
            throw NSError(domain: "VesselTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Error reproducible"])
        }
        await waitUntil { failure.phase(for: "failure") == .failed }
        failure.cancel("failure")

        let cancellationKey = "activity-cancel-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "vessel.operationQueue.\(cancellationKey)") }
        let cancellation = LibraryOperationQueue(
            storageKey: cancellationKey,
            activityStore: activity,
            activityStoreID: "gog"
        )
        cancellation.enqueue(gameID: "cancel", title: "Cancelado", kind: .install) { _ in }
        cancellation.pause("cancel")
        cancellation.cancel("cancel")

        #expect(activity.events.map(\.outcome) == [.cancelled, .failed, .completed])
        #expect(activity.events.filter { $0.gameID == "failure" }.count == 1)
        #expect(activity.events.first { $0.gameID == "failure" }?.detail == "Error reproducible")
    }

    @MainActor
    private func operation(_ id: String, _ kind: LibraryOperationKind) -> LibraryOperationQueue.Operation {
        LibraryOperationQueue.Operation(
            gameID: id,
            title: id.uppercased(),
            kind: kind,
            targetID: nil,
            enqueuedAt: .now
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
