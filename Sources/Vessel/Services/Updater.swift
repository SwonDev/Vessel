import Foundation
import Sparkle

/// Auto-actualización nativa de la app con **Sparkle** (firma EdDSA + delta updates), el mismo
/// framework que usa CrossOver. Sustituye al Updater casero anterior (que solo comparaba tags de
/// GitHub, sin firma ni instalación automática, y estaba sin cablear a la UI).
///
/// Piezas de configuración (todas en `build_and_run.sh`):
/// - `Sparkle.framework` embebido en `Contents/Frameworks` (firmado ad-hoc inside-out con el bundle).
/// - Info.plist: `SUFeedURL` (appcast en el repo público), `SUPublicEDKey` (clave EdDSA pública),
///   `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`.
/// - La clave privada de firma vive en el LLAVERO de quien publica (generada con `generate_keys`);
///   cada release se firma con `sign_update` y se referencia en `appcast.xml`.
///
/// Con firma ad-hoc (sin Developer ID) Sparkle se apoya en la firma EdDSA del propio update como
/// verificación de integridad (es el modelo válido para apps auto-distribuidas por GitHub).
@MainActor
final class UpdaterManager {
    static let shared = UpdaterManager()

    private let controller: SPUStandardUpdaterController

    private init() {
        // `startingUpdater: true` arranca las comprobaciones automáticas programadas según el
        // Info.plist (`SUEnableAutomaticChecks` / `SUScheduledCheckInterval`). Lee `SUFeedURL` y
        // `SUPublicEDKey` del bundle principal (presentes en el .app que monta build_and_run.sh).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Comprobación MANUAL disparada por el usuario (menú "Buscar actualizaciones…").
    /// Muestra UI aunque no haya novedades ("Ya tienes la última versión").
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Sparkle puede comprobar ahora mismo (no hay otra comprobación en curso, etc.).
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}
