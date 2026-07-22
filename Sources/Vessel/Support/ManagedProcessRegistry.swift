import Foundation
import Darwin
import AppKit

/// Registro mínimo y thread-safe de procesos largos que necesitan cancelación cooperativa desde
/// Swift Concurrency. `withTaskCancellationHandler` ejecuta `onCancel` en un hilo arbitrario, por
/// eso esta pieza usa un lock muy acotado en vez de estado ligado a `MainActor`.
final class ManagedProcessRegistry: @unchecked Sendable {
    private struct Entry {
        let process: Process
        let processGroupID: pid_t?
    }

    private let lock = NSLock()
    private var processes: [String: Entry] = [:]
    private var cancellationRequests: Set<String> = []
    private var terminationObserver: NSObjectProtocol?

    init() {
        // Un `Process` no muere necesariamente con su padre: al cerrar Vessel, SteamCMD puede
        // quedar reparentado a launchd y seguir escribiendo el depot. La siguiente apertura
        // restauraría la cola y podría lanzar una segunda descarga sobre los mismos archivos.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.cancelAll()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    /// Limpia restos de una ejecución anterior antes de reutilizar el mismo identificador.
    func prepare(_ id: String) {
        lock.withLock {
            processes[id] = nil
            cancellationRequests.remove(id)
        }
    }

    /// Registra el proceso. Si la tarea se canceló justo antes de `Process.run()`, lo termina nada
    /// más quedar disponible para cerrar esa carrera sin dejar un descargador huérfano.
    func register(_ process: Process, processGroupID: pid_t? = nil, for id: String) {
        let entry = Entry(process: process, processGroupID: processGroupID)
        let shouldTerminate = lock.withLock { () -> Bool in
            guard !cancellationRequests.contains(id) else { return true }
            processes[id] = entry
            return false
        }
        if shouldTerminate { terminate(entry) }
    }

    /// Puede llamarse desde cualquier hilo, incluido el `onCancel` de una tarea Swift.
    func cancel(_ id: String) {
        let entry = lock.withLock { () -> Entry? in
            cancellationRequests.insert(id)
            return processes[id]
        }
        if let entry { terminate(entry) }
    }

    /// Finaliza todos los grupos administrados antes de que termine la aplicación. Conserva las
    /// entradas hasta que sus esperas recojan el código de salida, igual que `cancel(_:)`.
    func cancelAll() {
        let entries = lock.withLock { () -> [Entry] in
            cancellationRequests.formUnion(processes.keys)
            return Array(processes.values)
        }
        for entry in entries { terminate(entry) }
    }

    /// Retira el proceso y devuelve si su finalización fue provocada por una cancelación solicitada.
    @discardableResult
    func finish(_ id: String) -> Bool {
        lock.withLock {
            processes[id] = nil
            return cancellationRequests.remove(id) != nil
        }
    }

    private func terminate(_ entry: Entry) {
        if let processGroupID = entry.processGroupID {
            // Identificador negativo = grupo completo. SteamCMD se ejecuta mediante un script y
            // puede tener procesos hijos; finalizar solo el shell dejaría la descarga huérfana.
            _ = Darwin.kill(-processGroupID, SIGTERM)
        } else if entry.process.isRunning {
            entry.process.terminate()
        }
    }
}
