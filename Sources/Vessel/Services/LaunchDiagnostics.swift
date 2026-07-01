import Foundation

/// Diagnóstico POST-LANZAMIENTO + **fallback automático de motor**: unos segundos después de
/// arrancar un juego, revisa la EVIDENCIA que el propio juego/Wine escriben en sus logs (el
/// `Player.log` de Unity y el `game-launch.log` de Vessel) buscando firmas de fallo CONOCIDAS.
///
/// - Si el fallo es de **gráficos/crash/Vulkan** (recuperable cambiando de motor), Vessel
///   **relanza automáticamente** el juego con la otra capa (DXMT ↔ GPTK/D3DMetal) — una sola vez —
///   y avisa. Así muchos juegos que fallan con un motor arrancan con el otro sin intervención.
/// - Si no es recuperable (falta una librería, .NET, ratón de Unity) o ya se reintentó, avisa con
///   la causa y una acción concreta.
///
/// Solo lee logs recientes; el relanzado lo hace el propio flujo `play()` de cada tienda con un
/// override de capa gráfica. Aditivo y seguro.
@MainActor
enum LaunchDiagnostics {
    /// Categoría del fallo detectado.
    enum Category {
        case graphics, missingLibrary, dotNet, crash, vulkan, mouse
        /// ¿Se puede intentar arreglar reintentando con OTRO motor/capa gráfica?
        var isEngineRetryable: Bool {
            switch self {
            case .graphics, .crash, .vulkan: return true
            case .missingLibrary, .dotNet, .mouse: return false
            }
        }
    }

    /// Un fallo detectado en los logs.
    struct Failure {
        let category: Category
        let title: String
        let body: String
    }

    private struct Signature {
        let markers: [String]
        let category: Category
        let title: String
        let body: String
    }

    /// Firmas en ORDEN DE PRIORIDAD (la primera que casa se reporta). Las más graves/específicas antes.
    private static let signatures: [Signature] = [
        Signature(
            markers: ["InitializeEngineGraphics failed", "Failed to initialize graphics",
                      "D3D11CreateDevice failed", "Direct3D 11 device creation failed",
                      "no usable GPU adapter", "GfxDevice: no device", "Failed to create D3D"],
            category: .graphics,
            title: "No se pudieron iniciar los gráficos",
            body: "El juego no logró inicializar Direct3D (Metal). Prueba a «Verificar / reparar» o cambia la capa gráfica en sus Ajustes."),
        Signature(
            markers: ["c0000135", "could not load kernel32", "was not found", "The program can't start",
                      "api-ms-win", "VCRUNTIME140", "MSVCP140", "vcruntime"],
            category: .missingLibrary,
            title: "Falta una librería del sistema",
            body: "El juego pide una dependencia que no está en el entorno (normalmente Visual C++ o .NET). Prueba a «Verificar / reparar»."),
        Signature(
            markers: ["mscoree.dll", "clr.dll", ".NET Framework", "Mono path", "il2cpp",
                      "Could not load type", "FileNotFoundException: Could not load file or assembly"],
            category: .dotNet,
            title: "Falta el runtime .NET/Mono",
            body: "El juego necesita .NET o Mono y no está disponible. «Verificar / reparar» puede ayudar."),
        Signature(
            markers: ["Crash!!!", "Crash: SIGSEGV", "Obtained 0 stack frames", "========== OUTPUTTING STACK TRACE"],
            category: .crash,
            title: "El juego crasheó al cargar",
            body: "El juego se cerró nada más arrancar. Probamos con otra capa gráfica; si persiste, «Verificar / reparar»."),
        Signature(
            markers: ["VK_ERROR", "Failed to create device", "DxvkAdapter", "VK_ERROR_FEATURE_NOT_PRESENT",
                      "vkCreateDevice"],
            category: .vulkan,
            title: "Error de Vulkan/Metal",
            body: "La capa gráfica Vulkan (MoltenVK) falló. Probamos con otra capa gráfica."),
        Signature(
            markers: ["EnableMouseInPointer failed"],
            category: .mouse,
            title: "Ratón/teclado sin responder (Unity 6)",
            body: "Este juego corrió con un motor sin el fix del ratón. Ciérralo y vuelve a lanzarlo desde Vessel; si persiste, reinicia Vessel.")
    ]

    /// Revisa los logs recientes y devuelve el fallo detectado (o `nil` si el juego arrancó bien).
    static func detect(prefix: String) -> Failure? {
        let haystack = recentLogText(prefix: prefix)
        guard !haystack.isEmpty else { return nil }
        for sig in signatures where sig.markers.contains(where: { haystack.contains($0) }) {
            return Failure(category: sig.category, title: sig.title, body: sig.body)
        }
        return nil
    }

    /// Avisa (notificación + log) si hay un fallo. Se usa cuando NO se va a reintentar.
    static func diagnose(prefix: String, gameTitle: String) {
        guard let f = detect(prefix: prefix) else { return }
        report(f, gameTitle: gameTitle)
    }

    /// Monitoriza el arranque y, si detecta un fallo recuperable, **relanza con la otra capa
    /// gráfica** (una sola vez). Si no es recuperable o ya se reintentó, avisa. Llamar justo tras
    /// arrancar el juego; espera unos segundos a que el juego escriba su log.
    /// - `relaunch`: cierra el intento anterior y vuelve a lanzar con la capa indicada.
    static func monitorAndMaybeRetry(
        prefix: String, gameId: String, gameTitle: String,
        currentLayer: GameConfig.GraphicsLayer, attempt: Int,
        relaunch: @escaping @MainActor (GameConfig.GraphicsLayer) async -> Void
    ) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            guard let failure = detect(prefix: prefix) else { return }   // arrancó bien
            if failure.category.isEngineRetryable, attempt < 1, let next = nextLayer(after: currentLayer) {
                LogStore.shared.log("\(gameTitle): falló el arranque (\(failure.title)) con la capa \(currentLayer.rawValue). Reintentando automáticamente con \(next.rawValue)…", level: .info)
                NotificationService.shared.notify(
                    title: "Reintentando: \(gameTitle)",
                    body: "El primer intento no arrancó (\(failure.title)). Probando con otra capa gráfica…")
                // Cerrar el intento fallido (por si quedó un proceso colgado) antes de relanzar.
                GameLaunchTracker.shared.stop(gameId)
                try? await Task.sleep(for: .seconds(2))
                await relaunch(next)
            } else {
                report(failure, gameTitle: gameTitle)
            }
        }
    }

    private static func report(_ f: Failure, gameTitle: String) {
        LogStore.shared.log("⚠️ \(gameTitle): \(f.title). \(f.body)", level: .warn)
        NotificationService.shared.notify(title: "\(f.title) — \(gameTitle)", body: f.body)
    }

    /// Siguiente capa gráfica a probar tras un fallo. Alterna entre DXMT (D3D11→Metal) y
    /// GPTK/D3DMetal (D3D12→Metal), los dos motores de juegos de 64-bit. `auto` para Unity resuelve
    /// a DXMT, así que su fallback es GPTK.
    private static func nextLayer(after layer: GameConfig.GraphicsLayer) -> GameConfig.GraphicsLayer? {
        switch layer {
        case .auto, .dxmt: return .gptk
        case .gptk:        return .dxmt
        default:           return nil   // wined3d/dxvk/opengl: sin swap automático simple
        }
    }

    /// Junta el texto de los `Player.log` RECIENTES del prefijo (Unity) + el `game-launch.log`.
    private static func recentLogText(prefix: String) -> String {
        let fm = FileManager.default
        var parts: [String] = []
        let usersDir = "\(prefix)/drive_c/users"
        if let users = try? fm.contentsOfDirectory(atPath: usersDir) {
            for user in users {
                let lowDir = "\(usersDir)/\(user)/AppData/LocalLow"
                guard let walker = fm.enumerator(atPath: lowDir) else { continue }
                for case let rel as String in walker where rel.hasSuffix("Player.log") {
                    if let t = recentContents(atPath: "\(lowDir)/\(rel)", maxAge: 180) { parts.append(t) }
                }
            }
        }
        let launchLog = "\(NSHomeDirectory())/Library/Logs/Vessel/game-launch.log"
        if let t = recentContents(atPath: launchLog, maxAge: 180) { parts.append(t) }
        return parts.joined(separator: "\n")
    }

    private static func recentContents(atPath path: String, maxAge: TimeInterval) -> String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mod = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mod) < maxAge,
              let data = fm.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
