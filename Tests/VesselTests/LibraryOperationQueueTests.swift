import Foundation
import Testing
@testable import Vessel

@MainActor
private final class OperationRecorder {
    var values: [String] = []
}

@Suite("Cola persistente de operaciones")
struct LibraryOperationQueueTests {
    @Test("Ejecuta en serie, prioriza pendientes y evita duplicados")
    @MainActor
    func serializesAndPrioritizes() async {
        let suffix = UUID().uuidString
        let defaultsKey = "vessel.operationQueue.tests-\(suffix)"
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        let recorder = OperationRecorder()
        let queue = LibraryOperationQueue(storageKey: "tests-\(suffix)")
        queue.enqueue(gameID: "a", title: "Alfa", kind: .install) { operation in
            recorder.values.append(operation.id)
            try await Task.sleep(for: .milliseconds(80))
        }
        await waitUntil { queue.phase(for: "a") == .running }

        queue.enqueue(gameID: "b", title: "Beta", kind: .update) { operation in
            recorder.values.append(operation.id)
        }
        queue.enqueue(gameID: "c", title: "Charlie", kind: .verify) { operation in
            recorder.values.append(operation.id)
        }
        queue.enqueue(gameID: "b", title: "Beta duplicado", kind: .verify) { _ in
            recorder.values.append("duplicado")
        }
        queue.prioritize("c")

        await waitUntil { !queue.hasItems }
        #expect(recorder.values == ["a", "c", "b"])
    }

    @Test("Conserva una operación pausada al reconstruir la cola")
    @MainActor
    func restoresPausedOperation() {
        let suffix = UUID().uuidString
        let defaultsKey = "vessel.operationQueue.tests-\(suffix)"
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        let first = LibraryOperationQueue(storageKey: "tests-\(suffix)")
        first.enqueue(gameID: "persistente", title: "Persistente", kind: .install) { _ in }
        first.pause("persistente")

        let restored = LibraryOperationQueue(storageKey: "tests-\(suffix)")
        #expect(restored.itemIDs == ["persistente"])
        #expect(restored.phase(for: "persistente") == .paused)
        #expect(restored.kind(for: "persistente") == .install)
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
