import Foundation
import AppKit
import CoreGraphics
import Darwin
import UserNotifications

/// Notificaciones nativas de macOS para eventos largos que ocurren cuando el usuario está en
/// OTRA app: descarga/instalación completada, actualización disponible, error. Sin fricción:
/// pide permiso una vez al arrancar y, si se deniega, `notify` no hace nada (el sistema lo
/// gestiona). No hay sonidos intrusivos por defecto más allá del estándar.
@MainActor
final class NotificationService {
    enum LaunchAlertAction: String {
        case showSteamClient
    }

    typealias SteamAuthorizationResumption = @MainActor () async -> Void

    static let shared = NotificationService()
    private var steamAuthorizationResumptions: [String: SteamAuthorizationResumption] = [:]
    private init() {}

    /// `UNUserNotificationCenter.current()` aborta internamente si el proceso no pertenece a un
    /// bundle de aplicación (por ejemplo, `xctest` o una herramienta CLI). Vessel conserva en esos
    /// contextos sus banners in-app, pero no intenta publicar una notificación del sistema.
    nonisolated static func canPostSystemNotifications(
        bundleURL: URL = Bundle.main.bundleURL
    ) -> Bool {
        bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    /// Pide permiso de notificaciones una vez (al arrancar). Idempotente.
    func requestAuthorization() {
        guard Self.canPostSystemNotifications() else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Publica una notificación inmediata. Si el usuario denegó el permiso, el sistema la ignora.
    func notify(title: String, body: String) {
        guard Self.canPostSystemNotifications() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Aviso IMPORTANTE que el usuario DEBE ver (p. ej. "el juego necesita Steam"): notificación
    /// del sistema **+** alerta dentro de la app. La alerta in-app es imprescindible porque en una
    /// app firmada ad-hoc las notificaciones del sistema no siempre aparecen; así el usuario recibe
    /// SIEMPRE el mensaje y la acción a tomar (cero fricción).
    func alert(
        title: String,
        body: String,
        actionTitle: String? = nil,
        action: LaunchAlertAction? = nil,
        steamAppId: String? = nil,
        resumeAfterSteamAuthorization: SteamAuthorizationResumption? = nil
    ) {
        notify(title: title, body: body)
        var userInfo: [String: Any] = ["title": title, "body": body]
        if let actionTitle, let action {
            userInfo["actionTitle"] = actionTitle
            userInfo["action"] = action.rawValue
        }
        if let steamAppId {
            userInfo["steamAppId"] = steamAppId
            if action == .showSteamClient, let resumeAfterSteamAuthorization {
                registerSteamAuthorizationResumption(
                    appId: steamAppId,
                    action: resumeAfterSteamAuthorization
                )
            }
        }
        NotificationCenter.default.post(
            name: .launchMessage,
            object: nil,
            userInfo: userInfo
        )
    }

    func perform(_ action: LaunchAlertAction, steamAppId: String? = nil) {
        switch action {
        case .showSteamClient:
            // El backend de DRM puede estar conectado pero renderizar completamente negro. La
            // acción no intenta enfocarlo: cambia primero al rol interactivo validado y vuelve a
            // solicitar el AppID para que Steam muestre su EULA en esa interfaz.
            Task { @MainActor in
                guard let bottle = BottleStore.shared.bottles.first(where: { $0.name == "Steam" })
                    ?? BottleStore.shared.bottles.first(where: {
                        FileManager.default.fileExists(atPath: $0.steamPath)
                    }) else {
                    LogStore.shared.log(
                        "No se encontró el entorno Steam de Vessel para abrir la licencia.",
                        level: .warn
                    )
                    return
                }
                let resumption = steamAppId.flatMap {
                    self.takeSteamAuthorizationResumption(appId: $0)
                }
                await WineManager().openSteamClient(
                    in: bottle,
                    requestingAppId: steamAppId,
                    resumeAfterEULAAcceptance: resumption
                )
                Self.focusSteamClientFromUserAction()
            }
        }
    }

    /// Conserva la continuación del intento original únicamente hasta que el usuario abre el
    /// cliente interactivo. La acción es de un solo uso: aceptar puede reanudar ese intento, pero
    /// cancelar o volver a pulsar Jugar nunca debe acumular lanzamientos antiguos.
    func registerSteamAuthorizationResumption(
        appId: String,
        action: @escaping SteamAuthorizationResumption
    ) {
        steamAuthorizationResumptions[appId] = action
    }

    func takeSteamAuthorizationResumption(
        appId: String
    ) -> SteamAuthorizationResumption? {
        steamAuthorizationResumptions.removeValue(forKey: appId)
    }

    private static func focusSteamClientFromUserAction() {
        guard let steam = steamClientApplication() else {
            LogStore.shared.log(
                "No se encontró la aplicación visible del cliente Steam para traerla al frente.",
                level: .warn
            )
            return
        }
        NSApp.yieldActivation(to: steam)
        if steam.activate() || activateUnbundledSteamFromUserAction(steam) {
            LogStore.shared.log(
                "Cliente Steam interactivo traído al frente para revisar la licencia.",
                level: .debug
            )
        } else {
            LogStore.shared.log(
                "macOS no pudo traer al frente la ventana Wine del cliente Steam.",
                level: .warn
            )
        }
    }

    /// Wine es una aplicación regular pero carece de bundle identifier. En ese caso AppKit puede
    /// rechazar la activación aun después de una cesión válida. Este API público heredado es el
    /// único que permite declarar que el cambio procede del gesto directo del usuario; jamás se
    /// invoca desde arranques o notificaciones automáticas.
    private static func activateUnbundledSteamFromUserAction(
        _ application: NSRunningApplication
    ) -> Bool {
        typealias GetProcessForPIDFunction = @convention(c) (
            pid_t,
            UnsafeMutableRawPointer
        ) -> Int32
        typealias SetFrontProcessFunction = @convention(c) (
            UnsafeRawPointer,
            UInt32
        ) -> Int32

        guard let framework = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_LAZY | RTLD_LOCAL
        ) else { return false }
        defer { dlclose(framework) }
        guard let getProcessSymbol = dlsym(framework, "GetProcessForPID"),
              let setFrontSymbol = dlsym(framework, "SetFrontProcessWithOptions")
        else { return false }

        let getProcess = unsafeBitCast(getProcessSymbol, to: GetProcessForPIDFunction.self)
        let setFront = unsafeBitCast(setFrontSymbol, to: SetFrontProcessFunction.self)
        var process = (high: UInt32(0), low: UInt32(0))
        return withUnsafeMutablePointer(to: &process) { pointer in
            let raw = UnsafeMutableRawPointer(pointer)
            guard getProcess(application.processIdentifier, raw) == 0 else { return false }
            // Bits públicos de HIServices: solo la ventana frontal y acción causada por el usuario.
            let options = UInt32((1 << 0) | (1 << 1))
            return setFront(UnsafeRawPointer(raw), options) == 0
        }
    }

    nonisolated static func isSteamClientWindow(
        ownerName: String,
        windowName: String,
        width: Double,
        height: Double
    ) -> Bool {
        let owner = ownerName.lowercased()
        let title = windowName.lowercased()
        // Sin permiso de grabación macOS oculta el título de ventanas de otros procesos, pero
        // conserva propietario y geometría. Esta alternativa solo se usa al pulsar la acción del
        // EULA, cuando Steam ha detenido el juego antes de crear su propia ventana.
        let eulaSizedWineWindow = width >= 900 && height >= 600
        return (owner.contains("wine") || owner.contains("steam"))
            && (title.contains("steam") || eulaSizedWineWindow)
            && width >= 320
            && height >= 240
    }

    private static func steamClientApplication() -> NSRunningApplication? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for window in windows {
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let title = window[kCGWindowName as String] as? String ?? ""
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  isSteamClientWindow(
                    ownerName: owner,
                    windowName: title,
                    width: width,
                    height: height
                  ),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let application = NSRunningApplication(processIdentifier: pid)
            else { continue }

            return application
        }

        // CGWindowList puede omitir por completo ventanas ajenas cuando Vessel no tiene permiso
        // de captura. Durante ShowEula Steam aún no ha creado el proceso del juego, de modo que la
        // única aplicación Wine regular es el cliente que el usuario acaba de pedir abrir.
        let wineApplications = NSWorkspace.shared.runningApplications.filter { application in
            application.activationPolicy == .regular
                && application.localizedName?.localizedCaseInsensitiveCompare("wine") == .orderedSame
                && !application.isTerminated
        }
        guard wineApplications.count == 1 else { return nil }
        return wineApplications.first
    }

    /// Estado EN VIVO no bloqueante (banner in-app): informa de fases largas como abrir Steam,
    /// esperar el login o reiniciar el cliente. Así el usuario SIEMPRE sabe qué está pasando
    /// (cero fricción). Pasar `nil` para ocultar el banner. No emite notificación del sistema.
    func status(_ message: String?) {
        NotificationCenter.default.post(name: .launchStatus, object: nil,
                                        userInfo: message.map { ["message": $0] } ?? [:])
    }
}
