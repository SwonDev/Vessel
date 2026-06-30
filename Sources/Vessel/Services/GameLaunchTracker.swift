import Foundation

/// Rastrea el **estado de lanzamiento de cada juego** (clave = id de `StoreGame`) para dar
/// FEEDBACK VISUAL real: `iniciando` mientras se prepara el prefijo y arranca Wine (puede
/// tardar segundos), y `ejecutándose` mientras el proceso del juego vive. La ficha y la
/// tarjeta lo observan (es `@Observable`) y muestran spinner / "Ejecutándose" en consecuencia.
@MainActor
@Observable
final class GameLaunchTracker {
    static let shared = GameLaunchTracker()
    private init() {}

    enum State: Equatable { case idle, launching, running }

    private var states: [String: State] = [:]
    private var processes: [String: Process] = [:]

    func state(_ id: String) -> State { states[id] ?? .idle }
    func isBusy(_ id: String) -> Bool { state(id) != .idle }

    /// Lanza un juego rastreando su estado. `body` prepara y arranca el juego y devuelve su
    /// `Process`. Pone `.launching` antes, `.running` al obtener el proceso, y vuelve a `.idle`
    /// cuando el proceso termina. No relanza: registra el error. Evita doble lanzamiento.
    func track(_ id: String, _ body: () async throws -> Process) async {
        guard state(id) == .idle else { return }
        states[id] = .launching
        do {
            let proc = try await body()
            processes[id] = proc
            states[id] = .running
            proc.terminationHandler = { _ in
                Task { @MainActor in GameLaunchTracker.shared.finish(id) }
            }
        } catch {
            states[id] = .idle
            LogStore.shared.log("No se pudo iniciar el juego: \(error.localizedDescription)", level: .error)
        }
    }

    /// Detiene el juego en ejecución (envía terminación al proceso lanzado).
    func stop(_ id: String) {
        processes[id]?.terminate()
    }

    private func finish(_ id: String) {
        states[id] = .idle
        processes[id] = nil
    }
}
