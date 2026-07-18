import Foundation

enum LibraryOperationKind: String, Codable, Sendable {
    case install
    case update
    case verify
    case uninstall
    case dlc

    var initialMessage: String {
        switch self {
        case .install: return "Preparando la instalación…"
        case .update: return "En cola para actualizar…"
        case .verify: return "En cola para verificar…"
        case .uninstall: return "En cola para desinstalar…"
        case .dlc: return "En cola para instalar el contenido…"
        }
    }

    var supportsPausing: Bool {
        switch self {
        case .install, .update, .verify, .dlc: return true
        case .uninstall: return false
        }
    }

    var supportsCancellation: Bool { self != .uninstall }
}

enum LibraryOperationPhase: String, Codable, Sendable {
    case queued
    case running
    case pausing
    case paused
    case cancelling
    case failed
}

/// Cola serial y persistente para operaciones de tienda. Serializar evita que SteamCMD,
/// Legendary o gogdl compitan por red/disco; las operaciones pausadas se conservan entre
/// aperturas y reanudan desde el staging propio de cada backend.
@MainActor
@Observable
final class LibraryOperationQueue {
    struct Operation: Identifiable, Codable, Equatable, Sendable {
        let gameID: String
        var title: String
        var kind: LibraryOperationKind
        /// Identificador del contenido secundario (por ejemplo un DLC). `nil` para operaciones
        /// sobre el juego base. Se persiste para poder reconstruir la operación tras reiniciar.
        var targetID: String?
        let enqueuedAt: Date

        var id: String { gameID }
    }

    struct Item: Identifiable, Codable, Equatable, Sendable {
        var operation: Operation
        var phase: LibraryOperationPhase
        var message: String
        var fractionCompleted: Double?

        var id: String { operation.id }
    }

    typealias Executor = @MainActor (Operation) async throws -> Void

    private(set) var items: [Item]

    private let storageKey: String
    private let activityStore: LibraryActivityStore?
    private let activityStoreID: String?
    private var executors: [String: Executor] = [:]
    private var workerTask: Task<Void, Never>?
    private var activeTask: Task<Void, Error>?
    private var pauseRequests: Set<String> = []
    private var cancellationRequests: Set<String> = []

    init(
        storageKey: String,
        activityStore: LibraryActivityStore? = .shared,
        activityStoreID: String? = nil
    ) {
        self.storageKey = "vessel.operationQueue.\(storageKey)"
        let knownStoreIDs: Set<String> = ["steam", "epic", "gog"]
        self.activityStoreID = activityStoreID
            ?? (knownStoreIDs.contains(storageKey) ? storageKey : nil)
        self.activityStore = activityStore
        if let data = UserDefaults.standard.data(forKey: self.storageKey),
           let stored = try? JSONDecoder().decode([Item].self, from: data) {
            self.items = stored.map { item in
                var restored = item
                if [.running, .pausing, .cancelling].contains(restored.phase) {
                    restored.phase = .queued
                    restored.message = "Pendiente de reanudar…"
                    restored.fractionCompleted = nil
                }
                return restored
            }
        } else {
            self.items = []
        }
    }

    var itemIDs: Set<String> { Set(items.map(\.id)) }
    var hasItems: Bool { !items.isEmpty }

    func item(for gameID: String) -> Item? { items.first { $0.id == gameID } }
    func position(of gameID: String) -> Int? { items.firstIndex { $0.id == gameID } }
    func message(for gameID: String) -> String? { item(for: gameID)?.message }
    func fraction(for gameID: String) -> Double? { item(for: gameID)?.fractionCompleted }
    func phase(for gameID: String) -> LibraryOperationPhase? { item(for: gameID)?.phase }
    func kind(for gameID: String) -> LibraryOperationKind? { item(for: gameID)?.operation.kind }
    func title(for gameID: String) -> String? { item(for: gameID)?.operation.title }

    func transferPhase(for gameID: String) -> LibraryTransferPhase {
        switch phase(for: gameID) {
        case .queued: return .queued
        case .running: return .running
        case .pausing: return .pausing
        case .paused: return .paused
        case .cancelling: return .cancelling
        case .failed: return .failed
        case nil: return .running
        }
    }

    func canPause(_ gameID: String) -> Bool {
        guard let item = item(for: gameID), item.operation.kind.supportsPausing else { return false }
        return [.queued, .running].contains(item.phase)
    }

    func canCancel(_ gameID: String) -> Bool {
        guard let item = item(for: gameID), item.operation.kind.supportsCancellation else { return false }
        return ![.cancelling].contains(item.phase)
    }

    func canPrioritize(_ gameID: String) -> Bool { phase(for: gameID) == .queued }
    func canRetry(_ gameID: String) -> Bool { phase(for: gameID) == .failed }

    func enqueue(
        gameID: String,
        title: String,
        kind: LibraryOperationKind,
        targetID: String? = nil,
        executor: @escaping Executor
    ) {
        // Un juego solo puede tener una operación viva. Un doble clic o "Actualizar todo" no debe
        // reiniciar una descarga, reemplazar una verificación activa ni duplicar trabajo.
        if items.contains(where: { $0.id == gameID }) {
            startIfNeeded()
            return
        }
        executors[gameID] = executor
        let operation = Operation(gameID: gameID, title: title, kind: kind,
                                  targetID: targetID, enqueuedAt: Date())
        items.append(Item(operation: operation, phase: .queued,
                          message: kind.initialMessage, fractionCompleted: nil))
        persist()
        startIfNeeded()
    }

    /// Reconecta una operación restaurada con el ejecutor de la tienda sin cambiar si estaba
    /// pausada o fallida. Las que estaban realmente en cola vuelven a arrancar automáticamente.
    func attach(gameID: String, executor: @escaping Executor) {
        guard items.contains(where: { $0.id == gameID }) else { return }
        executors[gameID] = executor
        startIfNeeded()
    }

    func report(gameID: String, message: String, fraction: Double?) {
        guard let index = items.firstIndex(where: { $0.id == gameID }),
              [.running, .pausing].contains(items[index].phase) else { return }
        items[index].message = message
        items[index].fractionCompleted = fraction.map { min(1, max(0, $0)) }
        // El porcentaje es efímero: una operación restaurada vuelve a estado indeterminado. No
        // escribimos UserDefaults por cada línea de progreso (pueden ser decenas por segundo);
        // la cola se persiste únicamente cuando cambia su estructura o fase.
    }

    func pause(_ gameID: String) {
        guard let index = items.firstIndex(where: { $0.id == gameID }),
              items[index].operation.kind.supportsPausing else { return }
        switch items[index].phase {
        case .queued:
            items[index].phase = .paused
            items[index].message = "En pausa"
            items[index].fractionCompleted = nil
        case .running:
            pauseRequests.insert(gameID)
            items[index].phase = .pausing
            items[index].message = "Pausando…"
            activeTask?.cancel()
        default:
            return
        }
        persist()
    }

    func resume(_ gameID: String) {
        guard let index = items.firstIndex(where: { $0.id == gameID }),
              [.paused, .failed].contains(items[index].phase) else { return }
        items[index].phase = .queued
        items[index].message = "En cola para reanudar…"
        items[index].fractionCompleted = nil
        persist()
        startIfNeeded()
    }

    func cancel(_ gameID: String) {
        guard let index = items.firstIndex(where: { $0.id == gameID }),
              items[index].operation.kind.supportsCancellation else { return }
        switch items[index].phase {
        case .running, .pausing:
            pauseRequests.remove(gameID)
            cancellationRequests.insert(gameID)
            items[index].phase = .cancelling
            items[index].message = "Cancelando…"
            activeTask?.cancel()
        case .queued, .paused:
            record(items[index].operation, outcome: .cancelled)
            executors[gameID] = nil
            items.remove(at: index)
        case .failed:
            // El fallo ya quedó registrado cuando ocurrió. Aquí «Cancelar» solo descarta su fila
            // del centro de descargas y no debe crear un segundo evento contradictorio.
            executors[gameID] = nil
            items.remove(at: index)
        case .cancelling:
            return
        }
        persist()
    }

    /// Mueve una operación pendiente al principio, justo detrás de la que ya está ejecutándose.
    func prioritize(_ gameID: String) {
        guard let source = items.firstIndex(where: { $0.id == gameID && $0.phase == .queued }) else { return }
        let destination = items.first.map {
            [.running, .pausing, .cancelling].contains($0.phase) ? 1 : 0
        } ?? 0
        guard source != destination else { return }
        let item = items.remove(at: source)
        items.insert(item, at: min(destination, items.count))
        persist()
    }

    private func startIfNeeded() {
        guard workerTask == nil,
              items.contains(where: { $0.phase == .queued && executors[$0.id] != nil }) else { return }
        workerTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let index = items.firstIndex(where: { $0.phase == .queued && executors[$0.id] != nil }) {
            let operation = items[index].operation
            guard let executor = executors[operation.id] else { break }

            items[index].phase = .running
            items[index].message = runningMessage(for: operation.kind)
            items[index].fractionCompleted = nil
            persist()

            let task = Task { @MainActor in
                try Task.checkCancellation()
                try await executor(operation)
                try Task.checkCancellation()
            }
            activeTask = task

            do {
                try await task.value
                record(operation, outcome: .completed)
                remove(operation.id)
            } catch is CancellationError {
                handleCancellation(of: operation.id)
            } catch {
                markFailed(operation.id, error: error)
            }
            activeTask = nil
            await Task.yield()
        }
        workerTask = nil
        startIfNeeded()
    }

    private func handleCancellation(of gameID: String) {
        if cancellationRequests.remove(gameID) != nil {
            if let operation = item(for: gameID)?.operation {
                record(operation, outcome: .cancelled)
            }
            remove(gameID)
            return
        }
        guard let index = items.firstIndex(where: { $0.id == gameID }) else { return }
        if pauseRequests.remove(gameID) != nil {
            items[index].phase = .paused
            items[index].message = "En pausa"
            items[index].fractionCompleted = nil
        } else {
            items[index].phase = .failed
            items[index].message = "La operación se interrumpió"
            items[index].fractionCompleted = nil
            record(items[index].operation, outcome: .failed, detail: items[index].message)
        }
        persist()
    }

    private func markFailed(_ gameID: String, error: Error) {
        guard let index = items.firstIndex(where: { $0.id == gameID }) else { return }
        items[index].phase = .failed
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].message = message.isEmpty ? "No se pudo completar" : message
        items[index].fractionCompleted = nil
        record(items[index].operation, outcome: .failed, detail: items[index].message)
        persist()
    }

    private func record(
        _ operation: Operation,
        outcome: LibraryActivityStore.Outcome,
        detail: String? = nil
    ) {
        guard let activityStore, let activityStoreID else { return }
        activityStore.record(
            storeID: activityStoreID,
            operation: operation,
            outcome: outcome,
            detail: detail
        )
    }

    private func remove(_ gameID: String) {
        items.removeAll { $0.id == gameID }
        executors[gameID] = nil
        pauseRequests.remove(gameID)
        cancellationRequests.remove(gameID)
        persist()
    }

    private func runningMessage(for kind: LibraryOperationKind) -> String {
        switch kind {
        case .install: return "Iniciando descarga…"
        case .update: return "Iniciando actualización…"
        case .verify: return "Iniciando verificación…"
        case .uninstall: return "Desinstalando…"
        case .dlc: return "Preparando contenido…"
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
