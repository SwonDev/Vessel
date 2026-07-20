import Foundation
import CoreGraphics

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
        /// DLL concreto extraído del error de Wine, si aparece. Permite reparar cargas dinámicas
        /// que no se observan en la tabla de imports del ejecutable.
        let missingLibrary: String?

        init(category: Category, title: String, body: String, missingLibrary: String? = nil) {
            self.category = category
            self.title = title
            self.body = body
            self.missingLibrary = missingLibrary
        }
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
                      "Steam must be running", "Unable to initialize SteamAPI", "Steamworks is not initialized",
                      // Interfaces de Steam que Goldberg NO implementa (Steam Input/Controller): el
                      // juego las pide y muere. Solo el cliente Steam REAL las provee → auto-repair las
                      // enruta a modo Steam-real. Visto en CaveBlazers (GetSteamController →
                      // STEAMUNIFIEDMESSAGES_INTERFACE_VERSION001).
                      "STEAMUNIFIEDMESSAGES", "GetSteamController", "Missing interface",
                      "SteamInput", "STEAMINPUT_INTERFACE_VERSION"],
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
            // OJO: NO usar "mscoree.dll" ni "clr.dll" como marcadores — aparecen en el `loaddll`
            // NORMAL de cualquier juego .NET (y "clr.dll" casa como subcadena con "coreCLR.dll" de
            // los .NET Core self-contained → falso positivo ".NET/Mono falta" en juegos que traen su
            // PROPIO runtime, como Romestead). Solo cadenas de ERROR reales.
            // Solo el crash FATAL de .NET (con "Unhandled exception"), NO el probing normal de
            // assemblies que .NET registra y CAPTURA (daría un reintento falso en juegos .NET sanos).
            markers: [".NET Framework not found", "You must install .NET",
                      "Unhandled exception. System.IO.FileNotFoundException",
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
            return Failure(
                category: sig.category,
                title: sig.title,
                body: sig.body,
                missingLibrary: sig.category == .missingLibrary ? missingLibraryName(in: haystack) : nil
            )
        }
        return nil
    }

    /// Steam puede detener el primer `-applaunch` en un EULA de terceros. Solo se considera la
    /// orden más reciente: una licencia histórica en el mismo log no debe contaminar lanzamientos
    /// posteriores una vez aceptada o cancelada.
    nonisolated static func steamEULAPromptDetected(in consoleLog: String) -> Bool {
        guard let latestCommand = consoleLog.range(
            of: "ExecCommandLine:",
            options: .backwards
        ) else { return false }
        let currentLaunch = consoleLog[latestCommand.lowerBound...]
        return currentLaunch.localizedCaseInsensitiveContains("-applaunch")
            && currentLaunch.contains("LaunchApp waiting for user response to ShowEula")
    }

    /// Comprueba únicamente el log modificado por el intento actual. La ventana pertenece a Steam
    /// y debe dejar que el usuario revise la licencia; Vessel nunca la acepta silenciosamente.
    nonisolated static func hasRecentSteamEULAPrompt(prefix: String, since: Date) -> Bool {
        let log = URL(fileURLWithPath: prefix)
            .appendingPathComponent("drive_c/Program Files (x86)/Steam/logs/console_log.txt")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: log.path),
              let modified = attributes[.modificationDate] as? Date,
              modified >= since.addingTimeInterval(-2),
              let contents = try? String(contentsOf: log, encoding: .utf8) else { return false }
        return steamEULAPromptDetected(in: contents)
    }

    /// Avisa (notificación + log) si hay un fallo. Se usa cuando NO se va a reintentar.
    static func diagnose(prefix: String, gameTitle: String) {
        guard let f = detect(prefix: prefix) else { return }
        report(f, gameTitle: gameTitle)
    }

    /// El modo Steam real solo se aprende con evidencia directa de una interfaz/DRM de Steam.
    /// Que un juego use Steamworks o agote sus capas gráficas no demuestra esa necesidad: un fallo
    /// de DLL o del motor produciría un falso positivo persistente y ocultaría la causa verdadera.
    static func shouldRetryWithRealSteam(_ failure: Failure?) -> Bool {
        failure?.category == .steam
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
        launchStartedAt: Date? = nil,
        isRunning: @escaping @MainActor () -> Bool = { false },
        hasVisibleWindow: (@MainActor () async -> Bool)? = nil,
        persistWinningLayer: (@MainActor (GameConfig.GraphicsLayer) -> Void)? = nil,
        retryWithRealSteam: (@MainActor () async -> Void)? = nil,
        retryWithRuntimeFix: (@MainActor (String?) async -> Bool)? = nil,
        relaunch: @escaping @MainActor (GameConfig.GraphicsLayer) async -> Void
    ) {
        Task { @MainActor in
            // SONDEO CONTINUO (no un único chequeo): un juego puede crashear MUCHO después de los
            // primeros segundos (los .NET/coreclr y los motores lentos como gptk-mythic —que compila
            // shaders— tardan >20 s en llegar a los gráficos). Un chequeo único a los 15 s se los perdía.
            // Sondeamos hasta `deadline` s buscando: (a) el diálogo de CRASH de Wine (winedbg) —señal
            // universal, sirve para CUALQUIER juego, no solo Unity—, (b) una firma de fallo en logs, o
            // (c) que el proceso haya MUERTO. Cualquiera de las tres = fallo recuperable.
            let deadline = 75
            var failure: Failure? = nil
            var crashed = false
            var waitingForSteamEULA = false
            var elapsed = 0
            // Chromium/NW.js puede mantener el proceso y una ventana negra mientras su proceso GPU
            // crashea y Crashpad genera varios minidumps. Sin esta señal se aprendía una capa como
            // «ganadora» aunque el juego fuese inutilizable. Si el llamante conoce el instante real
            // del lanzamiento contamos desde él; en flujos antiguos usamos el inventario actual como
            // línea base para no considerar dumps históricos.
            let crashpadBaseline = launchStartedAt == nil
                ? crashpadReportCount(prefix: prefix, since: .distantPast)
                : 0
            // ¿El juego llegó a ESTAR CORRIENDO de verdad? Si el tracker lo marcó `.running` en algún
            // sondeo, arrancó bien; una salida POSTERIOR sin crash es un CIERRE DEL USUARIO, no un
            // fallo de arranque. Sin esto, cerrar un juego que funciona mientras el monitor vigila se
            // interpretaba como fallo → relanzar → nuevo monitor → cerrar → relanzar = bucle infinito
            // "cerrar→reabrir" (reportado con Aethermancer). El grace inicial evita falsos negativos.
            var everRunning = false
            var everVisible = false
            while elapsed < deadline {
                try? await Task.sleep(for: .seconds(3)); elapsed += 3
                if elapsed >= 9, isRunning() { everRunning = true }
                if let hasVisibleWindow, await hasVisibleWindow() { everVisible = true }
                if hasWineCrashDialog() { crashed = true; break }
                // Diálogo "Missing interface" de Steam (Steam Input/Controller) — señal directa aunque
                // el log no lo capture. El juego lo muestra y muere; solo el Steam real lo resuelve.
                if hasSteamInterfaceDialog() {
                    failure = Failure(category: .steam, title: "El juego necesita la API de Steam",
                                      body: "Usa Steam Input/Controller (interfaces que la emulación no provee). Activando modo Steam real.")
                    break
                }
                if usesRealSteam, let launchStartedAt,
                   hasRecentSteamEULAPrompt(prefix: prefix, since: launchStartedAt) {
                    waitingForSteamEULA = true
                    failure = Failure(
                        category: .steam,
                        title: "Steam necesita que revises una licencia",
                        body: "Steam ha abierto el acuerdo de licencia de este juego. Pulsa «Abrir Steam», revísalo y elige «Aceptar» o «Cancelar»; después vuelve a pulsar Jugar. Vessel nunca aceptará condiciones legales por ti."
                    )
                    break
                }
                let newCrashReports: Int
                if let launchStartedAt {
                    newCrashReports = crashpadReportCount(prefix: prefix, since: launchStartedAt)
                } else {
                    newCrashReports = max(
                        0,
                        crashpadReportCount(prefix: prefix, since: .distantPast) - crashpadBaseline
                    )
                }
                if newCrashReports >= 2 {
                    failure = Failure(
                        category: .graphics,
                        title: "El proceso gráfico se cerró repetidamente",
                        body: "El juego conservó una ventana, pero su proceso gráfico falló varias veces. Vessel evita aprender este arranque como válido y prueba únicamente una ruta compatible."
                    )
                    break
                }
                if let f = detect(prefix: prefix) { failure = f; break }
                // Solo tras una gracia inicial (el tracker tarda en marcar .running al arrancar).
                if elapsed >= 9, !isRunning() { break }
            }
            if crashed { killWineCrashUI() }                 // cerrar el diálogo winedbg colgado
            // FALLIDO si: crasheó (winedbg), hay FIRMA de fallo conocida, o salió SIN haber llegado a
            // correr (arranque fallido). Si SÍ llegó a correr (`everRunning`) y salió limpio, es que el
            // USUARIO lo cerró — NO es un fallo y NO se relanza (evita el bucle cerrar→reabrir).
            let failed = startupFailed(
                crashed: crashed,
                failureDetected: failure != nil,
                isRunning: isRunning(),
                everRunning: everRunning,
                requiresVisibleWindow: hasVisibleWindow != nil,
                everVisible: everVisible
            )
            let alive = !failed

            // Juego en modo "Steam real" (DRM real): el motor es el unificado FIJO, así que si se
            // cerró NO es un problema de capa gráfica → reintentar con otra capa es INÚTIL y provoca
            // el bucle "ejecutándose→jugar→ejecutándose". Avisamos UNA vez con acción clara (alerta
            // in-app visible) y NO reintentamos; el cliente de Steam queda abierto para lanzar desde ahí.
            if usesRealSteam {
                if !alive {
                    let title = failure?.title ?? "\(gameTitle): no arrancó del todo"
                    let body = failure?.body
                        ?? "El juego se cerró al arrancar. Steam corre en segundo plano para el DRM (no tienes que abrir nada): vuelve a pulsar Jugar. Si es la primera vez, inicia sesión en Steam desde Vessel (botón de Steam, arriba) una sola vez."
                    NotificationService.shared.alert(
                        title: title,
                        body: body,
                        actionTitle: waitingForSteamEULA ? "Abrir Steam" : nil,
                        action: waitingForSteamEULA ? .showSteamClient : nil
                    )
                    if waitingForSteamEULA {
                        GameLaunchTracker.shared.stop(gameId)
                        LogStore.shared.log(
                            "\(gameTitle): Steam espera la decisión del usuario sobre su licencia; el estado vuelve a Jugar sin cerrar el cliente.",
                            level: .info
                        )
                    } else {
                        LogStore.shared.log("⚠️ \(gameTitle): el juego (Steam real) se cerró al arrancar; se avisó al usuario para reintentar (Steam sigue en segundo plano).", level: .warn)
                    }
                }
                return
            }

            // AUTO-REPARACIÓN DE STEAM: el juego pide interfaces de Steam que la emulación (Goldberg)
            // NO implementa (Steam Input/Controller, STEAMUNIFIEDMESSAGES) → solo el cliente Steam REAL
            // las provee. Si aún NO está en modo Steam-real, se ACTIVA automáticamente y se relanza
            // (como Grim Dawn, pero solo). Validado con CaveBlazers (32-bit GameMaker, corre en el
            // motor unificado que usa Steam-real). Persistir el modo lo hace el propio `retryWithRealSteam`.
            if failed, !usesRealSteam, let retrySteam = retryWithRealSteam,
               shouldRetryWithRealSteam(failure) {
                // Solo una FIRMA de Steam permite aprender este modo. Los perfiles ya verificados
                // (p. ej. DRM estricto) entran directamente por `usesRealSteam` y no dependen de aquí.
                let why = failure!.title
                LogStore.shared.log("\(gameTitle): \(why) → activando modo Steam real (cliente conectado) y relanzando…", level: .info)
                NotificationService.shared.notify(title: "Reparando automáticamente: \(gameTitle)",
                                                  body: "El juego necesita Steam conectado. Activando el modo Steam real…")
                if crashed { killWineCrashUI() }
                killSteamInterfaceDialog()
                GameLaunchTracker.shared.stop(gameId)
                try? await Task.sleep(for: .seconds(2))
                await retrySteam()
                return
            }

            // AUTO-REPARACIÓN DE RUNTIME: falta una dependencia de Windows (missingLibrary/dotNet).
            // Cambiar de capa gráfica no lo arregla → se identifica el componente exacto, se instala
            // de forma desatendida y solo se relanza si la reparación terminó correctamente.
            if failed, attempt < 1, let retryRuntime = retryWithRuntimeFix,
               failure?.category == .missingLibrary || failure?.category == .dotNet {
                LogStore.shared.log("\(gameTitle): falta un runtime de Windows → identificándolo, instalándolo y relanzando…", level: .info)
                NotificationService.shared.notify(title: "Reparando automáticamente: \(gameTitle)",
                                                  body: "Instalando el componente de Windows que necesita el juego…")
                GameLaunchTracker.shared.stop(gameId)
                try? await Task.sleep(for: .seconds(2))
                let repaired = await retryRuntime(failure?.missingLibrary)
                if !repaired, let failure {
                    report(failure, gameTitle: gameTitle)
                }
                return
            }

            @MainActor func retry(_ next: GameConfig.GraphicsLayer, reason: String) async {
                LogStore.shared.log("\(gameTitle): \(reason) con la capa \(currentLayer.rawValue). Reintentando con \(next.rawValue)…", level: .info)
                NotificationService.shared.notify(title: "Reintentando automáticamente: \(gameTitle)",
                                                  body: "\(reason). Probando con otra capa gráfica…")
                GameLaunchTracker.shared.stop(gameId)
                try? await Task.sleep(for: .seconds(2))
                await relaunch(next)
            }

            // REINTENTO UNIVERSAL (la raíz del arreglo): si el juego NO quedó vivo —crash de Wine,
            // firma de fallo, o salida temprana— se prueba la SIGUIENTE capa con sentido, y así hasta
            // AGOTAR las capas del juego. NO se descarta por categoría: un crash bajo un motor casi
            // siempre arranca con otro (Metal/DXMT ↔ D3DMetal ↔ wined3d). Excepción: `.steam` y
            // `.mouse` tienen su propia reparación (Goldberg / relanzar), no ciclo de motores.
            let dedicatedRepair = failure?.category == .steam || failure?.category == .mouse
                || failure?.category == .missingLibrary || failure?.category == .dotNet
            let maxAttempts = max(3, fallbackLayers.count)
            if !alive, !dedicatedRepair, attempt < maxAttempts,
               let next = nextSensibleLayer(after: currentLayer, in: fallbackLayers) {
                await retry(next, reason: "falló el arranque (\(failure?.title ?? "se cerró sin renderizar"))")
                return
            }
            // ÉXITO tras auto-reparación: el juego quedó vivo en un reintento → recordar esta capa
            // como override para que la PRÓXIMA vez arranque directa (que el arreglo PERSISTA).
            if alive, attempt > 0 {
                persistWinningLayer?(currentLayer)
                LogStore.shared.log("✅ \(gameTitle): arrancó con la capa \(currentLayer.rawValue) tras la auto-reparación; se recuerda para la próxima.", level: .info)
                NotificationService.shared.notify(title: "\(gameTitle): reparado",
                                                  body: "Arrancó tras ajustar la capa gráfica automáticamente.")
                return
            }
            // Agotadas las capas (o reparación dedicada): avisar con la causa detectada.
            if let failure {
                report(failure, gameTitle: gameTitle)
            } else if !alive {
                // Incluir la CAUSA RAÍZ real si `launch()` lanzó una excepción (fallo de motor/disco/
                // permisos), en vez de un mensaje genérico de "capas agotadas".
                let cause = GameLaunchTracker.shared.lastError(gameId).map { " Causa: \($0)." } ?? ""
                report(Failure(category: .crash,
                               title: "\(gameTitle) no llegó a arrancar",
                               body: "Se probaron todas las capas gráficas y ninguna funcionó.\(cause) Prueba «Verificar / reparar»."),
                       gameTitle: gameTitle)
            }
        }
    }

    /// Regla pura de aceptación del arranque. Cuando el flujo aporta una sonda visual, una familia
    /// de procesos sin ninguna ventana real es un fallo aunque haya sobrevivido varios segundos.
    nonisolated static func startupFailed(
        crashed: Bool,
        failureDetected: Bool,
        isRunning: Bool,
        everRunning: Bool,
        requiresVisibleWindow: Bool,
        everVisible: Bool
    ) -> Bool {
        crashed
            || failureDetected
            || (!isRunning && !everRunning)
            || (requiresVisibleWindow && !everVisible)
    }

    /// ¿Hay en pantalla el diálogo de CRASH de Wine (`winedbg` / "Program Error Details")? Es la
    /// señal UNIVERSAL de que un juego crasheó al arrancar, funcione con Unity, .NET, GameMaker o lo
    /// que sea — a diferencia del `Player.log`, que solo existe en Unity. Detección por título de
    /// ventana (CGWindowList), igual que `WineManager.isSteamWebHelperHung`.
    private static func hasWineCrashDialog() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            let name = (w[kCGWindowName as String] as? String ?? "")
            if name.contains("Program Error") || name.contains("Wine Debugger")
                || name.contains("Wine-Programmfehler") || name.contains("Errore del programma") {
                return true
            }
        }
        return false
    }

    /// Cierra el diálogo de crash de Wine (mata `winedbg`) para que no quede colgado tapando la app
    /// mientras se reintenta con otra capa. El relanzado (`launch`) ya limpia el resto de procesos wine.
    private static func killWineCrashUI() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-9", "-f", "winedbg"]
        try? p.run(); p.waitUntilExit()
    }

    /// ¿Hay en pantalla el diálogo "Missing interface" de Steam? (Steam Input/Controller —
    /// STEAMUNIFIEDMESSAGES). Lo muestra el propio juego (p. ej. CaveBlazers) cuando la emulación no
    /// implementa una interfaz de Steam que necesita. Señal directa para auto-activar el Steam real.
    private static func hasSteamInterfaceDialog() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            let name = (w[kCGWindowName as String] as? String ?? "")
            if name.contains("Missing interface") || name.contains("Missing inter") { return true }
        }
        return false
    }

    /// Cierra el proceso que muestra el diálogo "Missing interface" (por el PID dueño de la ventana),
    /// para que no quede colgado mientras se relanza en modo Steam real.
    private static func killSteamInterfaceDialog() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        for w in list {
            let name = (w[kCGWindowName as String] as? String ?? "")
            if (name.contains("Missing interface") || name.contains("Missing inter")),
               let pid = w[kCGWindowOwnerPID as String] as? pid_t {
                kill(pid, SIGKILL)
            }
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

    /// Cuenta informes `.dmp` de Crashpad creados desde un instante concreto. El recorrido se limita
    /// a los perfiles de usuario del prefijo y solo acepta rutas que contengan un directorio
    /// `Crashpad`, para no confundir volcados legítimos de otros subsistemas con un crash de Chromium.
    nonisolated static func crashpadReportCount(prefix: String, since: Date) -> Int {
        let root = URL(fileURLWithPath: prefix)
            .appendingPathComponent("drive_c/users", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var count = 0
        while let url = enumerator.nextObject() as? URL, count < 256 {
            guard url.pathExtension.caseInsensitiveCompare("dmp") == .orderedSame,
                  url.pathComponents.contains(where: { $0.caseInsensitiveCompare("Crashpad") == .orderedSame }),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= since else { continue }
            count += 1
        }
        return count
    }

    /// Extrae el primer nombre `.dll` de una línea que Wine marque realmente como ausente. No toma
    /// cualquier DLL del log porque `loaddll` también registra cargas sanas y provocaría reparaciones
    /// falsas. Se deja accesible al módulo para cubrir el parser con pruebas de regresión.
    nonisolated static func missingLibraryName(in output: String) -> String? {
        let failureMarkers = ["not found", "could not load", "module not found", "status_dll_not_found",
                              "c0000135", "can't find", "cannot find"]
        for line in output.split(separator: "\n").map(String.init) {
            let lowercased = line.lowercased()
            guard failureMarkers.contains(where: lowercased.contains),
                  let dllRange = lowercased.range(of: ".dll") else { continue }
            let throughDLL = String(line[..<dllRange.upperBound])
            let delimiters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-\\/"))
            let candidate = throughDLL.components(separatedBy: delimiters.inverted).last ?? ""
            let name = candidate.components(separatedBy: CharacterSet(charactersIn: "\\/")).last ?? ""
            guard name.lowercased().hasSuffix(".dll"), name.count <= 128 else { continue }
            return name
        }
        return nil
    }
}
