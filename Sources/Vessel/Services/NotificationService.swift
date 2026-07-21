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

    static let shared = NotificationService()
    private init() {}

    /// Pide permiso de notificaciones una vez (al arrancar). Idempotente.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Publica una notificación inmediata. Si el usuario denegó el permiso, el sistema la ignora.
    func notify(title: String, body: String) {
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
        action: LaunchAlertAction? = nil
    ) {
        notify(title: title, body: body)
        var userInfo: [String: Any] = ["title": title, "body": body]
        if let actionTitle, let action {
            userInfo["actionTitle"] = actionTitle
            userInfo["action"] = action.rawValue
        }
        NotificationCenter.default.post(
            name: .launchMessage,
            object: nil,
            userInfo: userInfo
        )
    }

    func perform(_ action: LaunchAlertAction) {
        switch action {
        case .showSteamClient:
            guard let steam = Self.steamClientApplication() else {
                LogStore.shared.log(
                    "No se encontró la aplicación visible del cliente Steam para traerla al frente.",
                    level: .warn
                )
                return
            }
            // La cesión y la activación coordinada forman una única transacción de foco. Ambas
            // deben ocurrir dentro de la acción del botón, mientras Vessel todavía es la
            // aplicación activa; una notificación del sistema puede ocupar el primer plano en el
            // siguiente ciclo del run loop e invalidar ese contexto.
            NSApp.yieldActivation(to: steam)
            // Es importante usar la petición sin opciones: es el par exacto de
            // `yieldActivation(to:)` para la activación cooperativa moderna. Wine ya expone una
            // única ventana principal y `activateAllWindows` puede hacer que AppKit rechace un
            // proceso sin bundle nativo.
            if steam.activate() || Self.activateUnbundledSteamFromUserAction(steam) {
                LogStore.shared.log(
                    "Cliente Steam traído al frente para revisar la licencia.",
                    level: .debug
                )
            } else {
                LogStore.shared.log(
                    "macOS no pudo traer al frente la ventana Wine del cliente Steam.",
                    level: .warn
                )
            }
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
