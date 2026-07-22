import Foundation
import Network

/// Estado de red compartido para decisiones de lanzamiento que deben ser automáticas.
///
/// `NWPathMonitor` empieza a informar en cuanto se crea la tienda Epic. Mientras todavía no haya
/// entregado su primer estado se asume conectividad: es preferible dejar que Legendary muestre un
/// error real a forzar por accidente el modo offline de un juego que requiere autenticación.
actor NetworkReachability {
    static let shared = NetworkReachability()

    private let monitor: NWPathMonitor
    private var status: NWPath.Status?
    private var epicAccessibility: (isAccessible: Bool, checkedAt: Date)?
    private var activeEpicProbe: Task<Bool, Never>?

    private init() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.update(path.status) }
        }
        monitor.start(queue: DispatchQueue(label: "com.swondev.vessel.network-reachability"))
    }

    /// Comprueba el servicio de Epic, no solo que el Mac tenga una ruta de red. Es la misma
    /// distinción que usa Mythic: si Internet funciona pero Epic está caído, Legendary debe lanzar
    /// automáticamente con `--offline` cuando el juego lo permita.
    func isEpicAccessible() async -> Bool {
        if status == .unsatisfied { return false }
        if let cached = epicAccessibility,
           Date().timeIntervalSince(cached.checkedAt) < 30 {
            return cached.isAccessible
        }
        if let activeEpicProbe {
            return await activeEpicProbe.value
        }

        let probe = Task { await Self.probeEpic() }
        activeEpicProbe = probe
        let isAccessible = await probe.value
        activeEpicProbe = nil

        guard status != .unsatisfied else {
            epicAccessibility = (false, Date())
            return false
        }
        epicAccessibility = (isAccessible, Date())
        return isAccessible
    }

    private func update(_ status: NWPath.Status) {
        self.status = status
        epicAccessibility = status == .unsatisfied ? (false, Date()) : nil
        if status == .unsatisfied {
            activeEpicProbe?.cancel()
            activeEpicProbe = nil
        }
    }

    nonisolated private static func probeEpic() async -> Bool {
        guard let url = URL(string: "https://epicgames.com") else { return false }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 5
        )
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { return false }
            return (200...299).contains(response.statusCode)
        } catch {
            return false
        }
    }
}
