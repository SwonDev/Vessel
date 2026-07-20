import Foundation
import AppKit
import CoreGraphics
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
            // La alerta de SwiftUI todavía está cerrándose cuando llega la acción. Darle un
            // instante evita que Vessel recupere el foco justo después de activar la ventana de
            // Steam y hace que el botón responda de forma determinista.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                if Self.activateSteamClientWindow() {
                    LogStore.shared.log(
                        "Cliente Steam traído al frente para revisar la licencia.",
                        level: .debug
                    )
                } else {
                    LogStore.shared.log(
                        "No se encontró una ventana visible del cliente Steam para traerla al frente.",
                        level: .warn
                    )
                }
            }
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

    private static func activateSteamClientWindow() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

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

            if yieldAndActivate(application) {
                return true
            }
        }

        // CGWindowList puede omitir por completo ventanas ajenas cuando Vessel no tiene permiso
        // de captura. Durante ShowEula Steam aún no ha creado el proceso del juego, de modo que la
        // única aplicación Wine regular es el cliente que el usuario acaba de pedir abrir.
        let wineApplications = NSWorkspace.shared.runningApplications.filter { application in
            application.activationPolicy == .regular
                && application.localizedName?.localizedCaseInsensitiveCompare("wine") == .orderedSame
                && !application.isTerminated
        }
        guard wineApplications.count == 1, let steam = wineApplications.first else { return false }
        return yieldAndActivate(steam)
    }

    /// En macOS moderno una aplicación activa debe ceder explícitamente el foco antes de que otra
    /// pueda solicitarlo. Sin este paso AppKit devuelve `false` para Wine aunque sea una aplicación
    /// regular y tenga una ventana visible.
    private static func yieldAndActivate(_ application: NSRunningApplication) -> Bool {
        NSApp.yieldActivation(to: application)
        return application.activate(options: [.activateAllWindows])
    }

    /// Estado EN VIVO no bloqueante (banner in-app): informa de fases largas como abrir Steam,
    /// esperar el login o reiniciar el cliente. Así el usuario SIEMPRE sabe qué está pasando
    /// (cero fricción). Pasar `nil` para ocultar el banner. No emite notificación del sistema.
    func status(_ message: String?) {
        NotificationCenter.default.post(name: .launchStatus, object: nil,
                                        userInfo: message.map { ["message": $0] } ?? [:])
    }
}
