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
    /// Último error REAL de `launch()` por id (si lanzó una excepción antes de arrancar). Antes se
    /// tragaba solo en el log; ahora `LaunchDiagnostics` lo incluye en el aviso final para que el
    /// usuario vea la causa raíz (fallo de motor/disco/permisos) en vez de un mensaje genérico.
    private var lastErrors: [String: String] = [:]
    func lastError(_ id: String) -> String? { lastErrors[id] }
    /// Acción a ejecutar cuando el juego termina (p. ej. subir cloud saves). Por id en curso.
    private var onExits: [String: @MainActor () -> Void] = [:]

    func state(_ id: String) -> State { states[id] ?? .idle }
    func isBusy(_ id: String) -> Bool { state(id) != .idle }

    /// Lanza un juego rastreando su estado. `body` prepara y arranca el juego y devuelve su
    /// `Process`. Pone `.launching` antes, `.running` al obtener el proceso, y vuelve a `.idle`
    /// cuando el proceso termina. No relanza: registra el error. Evita doble lanzamiento.
    ///
    /// `statsKey` (`"<tienda>:<id>"`) activa el registro de tiempo jugado: marca "jugado ahora"
    /// al arrancar (para "Recientes" instantáneo) y suma la duración de la sesión al cerrar.
    func track(_ id: String, statsKey: String? = nil,
               onExit: (@MainActor () -> Void)? = nil,
               _ body: () async throws -> Process) async {
        guard state(id) == .idle else { return }
        states[id] = .launching
        lastErrors[id] = nil
        do {
            let proc = try await body()
            processes[id] = proc
            states[id] = .running
            if let statsKey {
                statsKeys[id] = statsKey
                startTimes[id] = Date()
                PlayStatsStore.shared.markPlayed(statsKey)
            }
            if let onExit { onExits[id] = onExit }
            proc.terminationHandler = { _ in
                Task { @MainActor in GameLaunchTracker.shared.finish(id) }
            }
        } catch {
            states[id] = .idle
            lastErrors[id] = error.localizedDescription
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
        onExits[id]?()            // p. ej. subir cloud saves tras cerrar el juego
        states[id] = .idle
        processes[id] = nil
        statsKeys[id] = nil
        startTimes[id] = nil
        onExits[id] = nil
    }
}
