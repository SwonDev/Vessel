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
        case graphics, missingLibrary, dotNet, crash, vulkan, mouse, steam
        /// ¿Se puede intentar arreglar reintentando con OTRO motor/capa gráfica?
        var isEngineRetryable: Bool {
            switch self {
            case .graphics, .crash, .vulkan: return true
            case .missingLibrary, .dotNet, .mouse, .steam: return false
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
        // API de Steam: el juego usa Steamworks y `SteamAPI_Init` devolvió false (no había cliente
        // conectado NI Goldberg aplicado en el sitio correcto). Va PRIMERO porque es muy específico
        // y su mensaje debe ser exacto (antes lo pillaba la firma .NET/Mono por error). Auto-repara:
        // Vessel aplica Goldberg (ahora recursivo, cubre Unity) o el modo Steam-real según el juego.
        Signature(
            markers: ["SteamApi_Init returned false", "SteamAPI_Init() failed", "Platform init Steam failed",
                      "Steam must be running", "Unable to initialize SteamAPI", "Steamworks is not initialized"],
            category: .steam,
            title: "El juego necesita la API de Steam",
            body: "El juego usa Steamworks y no pudo inicializar su API. Vessel aplica la emulación (Goldberg) automáticamente; si el juego tiene DRM estricto, actívalo en modo «Steam real» en Ajustes. Prueba «Verificar / reparar»."),
        Signature(
            markers: ["InitializeEngineGraphics failed", "Failed to initialize graphics",
                      "D3D11CreateDevice failed", "Direct3D 11 device creation failed",
                      "no usable GPU adapter", "GfxDevice: no device", "Failed to create D3D",
                      // Unreal Engine / Unity: no obtuvieron un device D3D11 con Feature Level 11.0
                      // (usaron wined3d en vez de DXMT). El reintento con DXMT lo resuelve. Común en
                      // juegos Unreal cuyo exe REAL vive en `Binaries/Win64` (ver SteamLibraryImporter).
                      "A D3D11-compatible GPU", "is required to run the engine",
                      "Feature Level 11.0, Shader Model 5.0"],
            category: .graphics,
            title: "No se pudieron iniciar los gráficos",
            body: "El juego no logró inicializar Direct3D 11 (Metal). Lo reintentamos con otra capa gráfica automáticamente; si persiste, prueba «Verificar / reparar»."),
        Signature(
            markers: ["c0000135", "could not load kernel32", "was not found", "The program can't start",
                      "api-ms-win", "VCRUNTIME140", "MSVCP140", "vcruntime"],
            category: .missingLibrary,
            title: "Falta una librería del sistema",
            body: "El juego pide una dependencia que no está en el entorno (normalmente Visual C++ o .NET). Prueba a «Verificar / reparar»."),
        Signature(
            // OJO: NO usar "Mono path" ni "il2cpp" como marcadores — TODOS los juegos Unity los
            // imprimen normalmente (no son errores) y daban un falso positivo de ".NET/Mono missing"
            // (visto en Core Keeper, cuyo fallo real era SteamAPI). Solo marcadores de ERROR reales.
            markers: ["mscoree.dll", "clr.dll", ".NET Framework not found",
                      "Could not load type", "FileNotFoundException: Could not load file or assembly",
                      "Failed to load mono", "mono_jit_init failed"],
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
        fallbackLayers: [GameConfig.GraphicsLayer] = [],
        usesRealSteam: Bool = false,
        isRunning: @escaping @MainActor () -> Bool = { false },
        relaunch: @escaping @MainActor (GameConfig.GraphicsLayer) async -> Void
    ) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            let failure = detect(prefix: prefix)
            let alive = isRunning()

            // Juego en modo "Steam real" (DRM real): el motor es el unificado FIJO, así que si se
            // cerró NO es un problema de capa gráfica → reintentar con otra capa es INÚTIL y provoca
            // el bucle "ejecutándose→jugar→ejecutándose". Avisamos UNA vez con acción clara (alerta
            // in-app visible) y NO reintentamos; el cliente de Steam queda abierto para lanzar desde ahí.
            if usesRealSteam {
                if !alive {
                    NotificationService.shared.alert(
                        title: "\(gameTitle): no arrancó del todo",
                        body: "El juego se cerró al arrancar. Steam corre en segundo plano para el DRM (no tienes que abrir nada): vuelve a pulsar Jugar. Si es la primera vez, inicia sesión en Steam desde Vessel (botón de Steam, arriba) una sola vez.")
                    LogStore.shared.log("⚠️ \(gameTitle): el juego (Steam real) se cerró al arrancar; se avisó al usuario para reintentar (Steam sigue en segundo plano).", level: .warn)
                }
                return
            }

            @MainActor func retry(_ next: GameConfig.GraphicsLayer, reason: String) async {
                LogStore.shared.log("\(gameTitle): \(reason) con la capa \(currentLayer.rawValue). Reintentando con \(next.rawValue)…", level: .info)
                NotificationService.shared.notify(title: "Reintentando: \(gameTitle)",
                                                  body: "\(reason). Probando con otra capa gráfica…")
                GameLaunchTracker.shared.stop(gameId)
                try? await Task.sleep(for: .seconds(2))
                await relaunch(next)
            }

            // 1) Fallo con firma CONOCIDA y recuperable → reintentar con la siguiente capa.
            if let failure, failure.category.isEngineRetryable, attempt < 2, let next = nextSensibleLayer(after: currentLayer, in: fallbackLayers) {
                await retry(next, reason: "falló el arranque (\(failure.title))"); return
            }
            // 2) SALIDA SILENCIOSA: el juego ya NO corre y no hay firma (ni de éxito ni de fallo
            //    conocido). Típico de juegos que importan D3D11 pero renderizan por D3D9 (Grim Dawn):
            //    wine-dxmt cierra al instante sin log. Probamos la siguiente capa (hasta Gcenx/D3D9).
            if failure == nil, !alive, attempt < 2, let next = nextSensibleLayer(after: currentLayer, in: fallbackLayers) {
                await retry(next, reason: "se cerró sin renderizar"); return
            }
            // 3) Fallo no recuperable (o ya sin más capas): avisar.
            if let failure { report(failure, gameTitle: gameTitle) }
        }
    }

    private static func report(_ f: Failure, gameTitle: String) {
        LogStore.shared.log("⚠️ \(gameTitle): \(f.title). \(f.body)", level: .warn)
        NotificationService.shared.notify(title: "\(f.title) — \(gameTitle)", body: f.body)
    }

    /// Siguiente capa a probar RESPETANDO la lista de capas con sentido para ESTE juego
    /// (`WineManager.fallbackLayers`): devuelve la capa que sigue a `layer` en `allowed`, o `nil`
    /// si ya se agotaron. Así un Unity D3D11 (`allowed = [.dxmt]`) NO salta a GPTK/Gcenx —
    /// arregla el churn por capas incompatibles. Si `allowed` viene vacía (llamador sin actualizar),
    /// cae al ciclo antiguo `nextLayer` para no desactivar el fallback por accidente.
    private static func nextSensibleLayer(after layer: GameConfig.GraphicsLayer,
                                          in allowed: [GameConfig.GraphicsLayer]) -> GameConfig.GraphicsLayer? {
        guard !allowed.isEmpty else { return nextLayer(after: layer) }
        guard let idx = allowed.firstIndex(of: layer) else { return allowed.first { $0 != layer } }
        let next = idx + 1
        return next < allowed.count ? allowed[next] : nil
    }

    /// Siguiente capa gráfica a probar tras un fallo. Las 3 vías de 64-bit de Vessel forman un
    /// CICLO: DXMT (D3D11→Metal) → GPTK (D3D12→Metal) → Gcenx (D3D9/wined3d→Vulkan) → DXMT…
    /// Como el llamante pasa la capa REAL de arranque (`resolvedGraphicsLayer`, no `.auto`) y el
    /// reintento se corta a los 2 intentos (`attempt < 2`), desde CUALQUIER motor de arranque se
    /// prueban los 3 distintos sin repetir. Clave en Apple Silicon nuevo (M5): si wined3d/Vulkan
    /// (Gcenx) casca con la GPU, el ciclo alcanza DXMT/Metal, que sí la soporta.
    private static func nextLayer(after layer: GameConfig.GraphicsLayer) -> GameConfig.GraphicsLayer? {
        switch layer {
        case .dxmt:  return .gptk
        case .gptk:  return .gcenx
        case .gcenx: return .dxmt
        case .auto:  return .gptk   // defensivo: `usedLayer` ya llega resuelto a un motor concreto
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
