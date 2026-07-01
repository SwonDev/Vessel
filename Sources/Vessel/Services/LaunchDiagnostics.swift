import Foundation

/// Diagnóstico POST-LANZAMIENTO: unos segundos después de arrancar un juego, revisa la
/// EVIDENCIA que el propio juego/Wine escriben en sus logs (el `Player.log` de Unity y el
/// `game-launch.log` de Vessel) buscando firmas de fallo CONOCIDAS. Si encuentra una, avisa al
/// usuario con una causa clara y una acción concreta —en vez de dejar un juego que "no arranca"
/// o "no responde" sin explicación—.
///
/// No ejecuta nada ni cambia nada: solo lee logs recientes. Es aditivo y seguro. Cuando el
/// problema tiene arreglo automático en Vessel (p. ej. el fix del ratón de Unity 6), el aviso
/// deja de dispararse solo porque la firma ya no aparece en el log.
@MainActor
enum LaunchDiagnostics {
    /// Una firma de fallo: subcadena a buscar en los logs + título y cuerpo del aviso.
    private struct Signature {
        let markers: [String]        // cualquiera de estas subcadenas dispara la firma
        let title: String
        let body: String
        let logLevel: LogStore.Level
    }

    /// Firmas en ORDEN DE PRIORIDAD (la primera que casa es la que se reporta). Las más
    /// específicas/graves van antes.
    private static let signatures: [Signature] = [
        // Gráficos: DXMT/D3D11 no inicializó (juego cae a wined3d→OpenGL o el swapchain revienta).
        Signature(
            markers: ["InitializeEngineGraphics failed", "Failed to initialize graphics",
                      "D3D11CreateDevice failed", "Direct3D 11 device creation failed",
                      "no usable GPU adapter", "GfxDevice: no device"],
            title: "No se pudieron iniciar los gráficos",
            body: "El juego no logró inicializar Direct3D (Metal). Prueba a «Verificar / reparar» el juego o abre sus Ajustes y cambia la capa gráfica. Si acaba de instalarse, reintentar suele bastar.",
            logLevel: .warn
        ),
        // Falta una DLL: dependencia de sistema (VC++ / .NET) o archivo del juego dañado.
        Signature(
            markers: ["c0000135", "could not load kernel32", "was not found", "The program can't start",
                      "api-ms-win", "VCRUNTIME140", "MSVCP140", "vcruntime"],
            title: "Falta una librería del sistema",
            body: "El juego pide una dependencia que no está en el entorno (normalmente Visual C++ o .NET). Prueba a «Verificar / reparar» el juego; si persiste, es posible que necesite un runtime que aún no instalamos automáticamente.",
            logLevel: .warn
        ),
        // .NET / Mono ausente o versión incorrecta.
        Signature(
            markers: ["mscoree.dll", "clr.dll", ".NET Framework", "Mono path", "il2cpp",
                      "Could not load type", "FileNotFoundException: Could not load file or assembly"],
            title: "Falta el runtime .NET/Mono",
            body: "El juego necesita .NET o Mono y no está disponible en el entorno. «Verificar / reparar» puede ayudar; algunos juegos requieren instalarlo manualmente por ahora.",
            logLevel: .warn
        ),
        // Crash del runtime de Unity al cargar (típico de 32-bit con Mono bajo new-WoW64).
        Signature(
            markers: ["Crash!!!", "Crash: SIGSEGV", "Obtained 0 stack frames", "========== OUTPUTTING STACK TRACE"],
            title: "El juego crasheó al cargar",
            body: "El juego se cerró nada más arrancar (posible incompatibilidad del runtime, frecuente en juegos de 32-bit). Prueba a abrir sus Ajustes y cambiar la capa gráfica, o «Verificar / reparar».",
            logLevel: .warn
        ),
        // Vulkan/MoltenVK: el DXVK del motor no encaja con el MoltenVK disponible.
        Signature(
            markers: ["VK_ERROR", "Failed to create device", "DxvkAdapter", "VK_ERROR_FEATURE_NOT_PRESENT",
                      "vkCreateDevice"],
            title: "Error de Vulkan/Metal",
            body: "La capa gráfica Vulkan (MoltenVK) falló para este juego. Prueba a cambiar la capa gráfica en los Ajustes del juego.",
            logLevel: .warn
        ),
        // Ratón muerto de Unity 6: si el juego se enrutó al motor con el fix esto NO debe aparecer.
        // Si aparece, es que corrió con un motor sin el parche (p. ej. GPTK/D3D12).
        Signature(
            markers: ["EnableMouseInPointer failed"],
            title: "Ratón/teclado sin responder (Unity 6)",
            body: "Este juego Unity 6 no recibió el fix del ratón (corrió con un motor sin parche). Ciérralo y vuelve a lanzarlo desde Vessel para que use el motor correcto; si persiste, reinicia Vessel.",
            logLevel: .warn
        )
    ]

    /// Revisa los logs recientes del prefijo + el `game-launch.log` y, si detecta una firma de
    /// fallo, avisa al usuario. Pensado para llamarse unos segundos DESPUÉS del arranque.
    static func diagnose(prefix: String, gameTitle: String) {
        let haystack = recentLogText(prefix: prefix)
        guard !haystack.isEmpty else { return }
        for sig in signatures {
            if sig.markers.contains(where: { haystack.contains($0) }) {
                LogStore.shared.log("⚠️ \(gameTitle): \(sig.title). \(sig.body)", level: sig.logLevel)
                NotificationService.shared.notify(title: "\(sig.title) — \(gameTitle)", body: sig.body)
                return   // solo el primer (más grave) hallazgo
            }
        }
    }

    /// Junta el texto de los `Player.log` RECIENTES del prefijo (Unity) + el `game-launch.log`
    /// global de Vessel. Solo mira ficheros modificados en los últimos 3 min (el arranque actual).
    private static func recentLogText(prefix: String) -> String {
        let fm = FileManager.default
        var parts: [String] = []

        // Player.log de Unity en cada usuario del prefijo.
        let usersDir = "\(prefix)/drive_c/users"
        if let users = try? fm.contentsOfDirectory(atPath: usersDir) {
            for user in users {
                let lowDir = "\(usersDir)/\(user)/AppData/LocalLow"
                guard let walker = fm.enumerator(atPath: lowDir) else { continue }
                for case let rel as String in walker where rel.hasSuffix("Player.log") {
                    let path = "\(lowDir)/\(rel)"
                    if let t = recentContents(atPath: path, maxAge: 180) { parts.append(t) }
                }
            }
        }

        // Log de Wine del último lanzamiento (stdout del proceso del juego).
        let launchLog = "\(NSHomeDirectory())/Library/Logs/Vessel/game-launch.log"
        if let t = recentContents(atPath: launchLog, maxAge: 180) { parts.append(t) }

        return parts.joined(separator: "\n")
    }

    /// Contenido del fichero SOLO si se modificó hace menos de `maxAge` segundos (evita falsos
    /// positivos de un arranque anterior). Devuelve `nil` si es viejo o ilegible.
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
