import Foundation
import UserNotifications

/// Notificaciones nativas de macOS para eventos largos que ocurren cuando el usuario está en
/// OTRA app: descarga/instalación completada, actualización disponible, error. Sin fricción:
/// pide permiso una vez al arrancar y, si se deniega, `notify` no hace nada (el sistema lo
/// gestiona). No hay sonidos intrusivos por defecto más allá del estándar.
@MainActor
final class NotificationService {
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
    func alert(title: String, body: String) {
        notify(title: title, body: body)
        NotificationCenter.default.post(name: .launchMessage, object: nil,
                                        userInfo: ["title": title, "body": body])
    }

    /// Estado EN VIVO no bloqueante (banner in-app): informa de fases largas como abrir Steam,
    /// esperar el login o reiniciar el cliente. Así el usuario SIEMPRE sabe qué está pasando
    /// (cero fricción). Pasar `nil` para ocultar el banner. No emite notificación del sistema.
    func status(_ message: String?) {
        NotificationCenter.default.post(name: .launchStatus, object: nil,
                                        userInfo: message.map { ["message": $0] } ?? [:])
    }
}
