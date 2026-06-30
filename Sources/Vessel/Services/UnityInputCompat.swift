import Foundation

/// Detecta —y AVISA de— el problema CONOCIDO de input en juegos **Unity 6** bajo Wine:
/// Unity 6 usa `EnableMouseInPointer()` para recibir eventos `WM_POINTER`, una API que Wine
/// no implementa en ninguna versión → el ratón se mueve pero los clicks/teclas se ignoran.
///
/// No ejecuta nada: se basa en la EVIDENCIA real que el propio juego escribe en su `Player.log`
/// (`EnableMouseInPointer failed with the following error: Call not implemented.`). Si la
/// encuentra, Vessel avisa al usuario con claridad en vez de dejar un juego "mudo" sin explicación.
///
/// El fix de raíz es un parche al motor Wine (portado y listo), pendiente de integrarse upstream
/// en el motor; cuando llegue, Vessel auto-actualizará y este aviso dejará de dispararse.
@MainActor
enum UnityInputCompat {
    private static let marker = "EnableMouseInPointer failed"

    /// `true` si algún `Player.log` RECIENTE del prefijo contiene el fallo (juego afectado).
    static func isAffected(prefix: String) -> Bool {
        let fm = FileManager.default
        let usersDir = "\(prefix)/drive_c/users"
        guard let users = try? fm.contentsOfDirectory(atPath: usersDir) else { return false }
        for user in users {
            let lowDir = "\(usersDir)/\(user)/AppData/LocalLow"
            guard let walker = fm.enumerator(atPath: lowDir) else { continue }
            for case let rel as String in walker where rel.hasSuffix("Player.log") {
                let path = "\(lowDir)/\(rel)"
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mod = attrs[.modificationDate] as? Date,
                      Date().timeIntervalSince(mod) < 180,                 // solo el arranque reciente
                      let data = fm.contents(atPath: path),
                      let text = String(data: data, encoding: .utf8) else { continue }
                if text.contains(marker) { return true }
            }
        }
        return false
    }

    /// Avisa (notificación + log) si el juego resulta afectado. Pensado para llamarse unos
    /// segundos DESPUÉS del arranque, cuando el juego ya ha escrito su `Player.log`.
    static func warnIfAffected(prefix: String, gameTitle: String) {
        guard isAffected(prefix: prefix) else { return }
        LogStore.shared.log("⚠️ \(gameTitle): ratón/teclado afectados por una limitación de Wine con juegos Unity 6 (EnableMouseInPointer). No es un fallo de tu equipo; fix pendiente de integración en el motor.", level: .warn)
        NotificationService.shared.notify(
            title: "Compatibilidad: \(gameTitle)",
            body: "Este juego usa Unity 6 y, por una limitación actual de Wine, el ratón/teclado pueden no responder. No es un fallo de tu Mac ni del juego — lo estamos resolviendo."
        )
    }
}
