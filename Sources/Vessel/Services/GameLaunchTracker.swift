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
    /// Por id en curso: clave de estadística (`"<tienda>:<id>"`) e instante de arranque, para
    /// acumular el tiempo jugado en `PlayStatsStore` al terminar el proceso.
    private var statsKeys: [String: String] = [:]
    private var startTimes: [String: Date] = [:]

    func state(_ id: String) -> State { states[id] ?? .idle }
    func isBusy(_ id: String) -> Bool { state(id) != .idle }

    /// Lanza un juego rastreando su estado. `body` prepara y arranca el juego y devuelve su
    /// `Process`. Pone `.launching` antes, `.running` al obtener el proceso, y vuelve a `.idle`
    /// cuando el proceso termina. No relanza: registra el error. Evita doble lanzamiento.
    ///
    /// `statsKey` (`"<tienda>:<id>"`) activa el registro de tiempo jugado: marca "jugado ahora"
    /// al arrancar (para "Recientes" instantáneo) y suma la duración de la sesión al cerrar.
    func track(_ id: String, statsKey: String? = nil, _ body: () async throws -> Process) async {
        guard state(id) == .idle else { return }
        states[id] = .launching
        do {
            let proc = try await body()
            processes[id] = proc
            states[id] = .running
            if let statsKey {
                statsKeys[id] = statsKey
                startTimes[id] = Date()
                PlayStatsStore.shared.markPlayed(statsKey)
            }
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
        if let key = statsKeys[id], let start = startTimes[id] {
            PlayStatsStore.shared.addSession(key, seconds: Int(Date().timeIntervalSince(start)))
        }
        states[id] = .idle
        processes[id] = nil
        statsKeys[id] = nil
        startTimes[id] = nil
    }
}
