import Foundation

/// **Epic en el hub DRM‑free.** Epic Games Store **no impone DRM propio**: es decisión de cada
/// editor. Así que, a diferencia de GOG (todo DRM‑free) y de Steam (hay que analizar el `.exe`),
/// aquí hay que preguntar juego a juego.
///
/// Lo bueno: no hace falta adivinarlo. `legendary` guarda en su `installed.json` dos campos que
/// vienen **de la propia Epic** con los metadatos del juego:
///
/// - **`requires_ot`** — el juego exige un *Ownership Token*: un fichero de licencia que solo emite
///   el launcher de Epic al arrancarlo. Sin él no se ejecuta. Esto SÍ es DRM.
/// - **`can_run_offline`** — Epic declara si el juego puede correr sin conexión ni launcher.
///
/// Esto resuelve el punto ciego de los escáneres de ficheros: el token de propiedad **no está en el
/// disco** hasta que el launcher lo pone, así que ningún análisis del `.exe` podría deducirlo. Aquí
/// lo dice Epic directamente.
///
/// Sobre eso se sigue pasando `DRMAnalyzer`, porque un juego sin DRM *de Epic* puede llevar el DRM
/// *del editor* (Denuvo, anti‑cheat…). Solo entran al hub los que superan las dos comprobaciones.
@MainActor
enum EpicDRMFreeImporter {
    /// Estado de legendary (su `installed.json` es la fuente de verdad de lo que hay instalado).
    private static var installedJSON: String { "\(LegendaryManager.configDir)/installed.json" }

    /// Carátula vertical del juego. legendary ya se descargó los metadatos de Epic a
    /// `metadata/<appName>.json`, así que la portada sale de disco, sin red ni API.
    static func coverURL(appName: String) -> String? {
        let path = "\(LegendaryManager.configDir)/metadata/\(appName).json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = obj["metadata"] as? [String: Any],
              let images = meta["keyImages"] as? [[String: Any]] else { return nil }
        // `DieselGameBoxTall` es la vertical 2:3 (la que pide la rejilla); `DieselGameBox` es
        // horizontal y solo vale como último recurso.
        for type in ["DieselGameBoxTall", "DieselGameBox"] {
            if let url = images.first(where: { ($0["type"] as? String) == type })?["url"] as? String,
               !url.isEmpty { return url }
        }
        return nil
    }

    /// Un juego de Epic instalado, con lo que Epic declara sobre su DRM.
    struct Entry {
        let appName: String
        let title: String
        let installPath: String
        /// Nombre del ejecutable relativo a `installPath` (lo dice el propio manifiesto de Epic).
        let executable: String
        /// Epic exige un Ownership Token emitido por su launcher → NO es autónomo.
        let requiresOwnershipToken: Bool
        /// Epic declara que el juego puede correr sin conexión ni launcher.
        let canRunOffline: Bool

        var executablePath: String { "\(installPath)/\(executable)" }
        /// Lo que Epic dice: ¿puede este juego vivir por su cuenta?
        var epicSaysStandalone: Bool { !requiresOwnershipToken && canRunOffline }
    }

    /// Juegos de Epic instalados, leídos del estado de legendary. Los DLC se descartan.
    static func installedEntries() -> [Entry] {
        guard let data = FileManager.default.contents(atPath: installedJSON),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return obj.compactMap { appName, g in
            guard (g["is_dlc"] as? Bool) != true,
                  let path = g["install_path"] as? String, !path.isEmpty,
                  let exe = g["executable"] as? String, !exe.isEmpty else { return nil }
            return Entry(appName: appName,
                         title: (g["title"] as? String) ?? appName,
                         installPath: path,
                         executable: exe,
                         // Ante la duda, lo prudente es asumir DRM: si el campo falta, no lo damos
                         // por libre. Un falso "es tuyo" es peor que no listarlo.
                         requiresOwnershipToken: (g["requires_ot"] as? Bool) ?? true,
                         canRunOffline: (g["can_run_offline"] as? Bool) ?? false)
        }
    }

    /// Resultado de una entrada analizada: qué dice Epic + qué dice el binario.
    struct Analysis {
        let entry: Entry
        let report: DRMAnalyzer.Report
        /// Se puede llevar a cualquier sitio: ni Epic pide token, ni el editor metió protección.
        var isDRMFree: Bool { entry.epicSaysStandalone && report.isStandaloneCapable }
        /// Motivo legible de por qué NO entra (vacío si entra).
        var blocker: String? {
            if entry.requiresOwnershipToken { return "Epic exige un token de propiedad de su launcher" }
            if !entry.canRunOffline { return "Epic declara que necesita conexión con su launcher" }
            if !report.protections.isEmpty { return report.summary }
            return nil
        }
    }

    /// Analiza todos los juegos de Epic instalados (Epic + binario). Es trabajo de disco: llámalo
    /// fuera de un render.
    static func analyzeInstalled() -> [Analysis] {
        installedEntries().map { e in
            Analysis(entry: e,
                     report: DRMAnalyzer.analyze(folder: e.installPath, executable: e.executablePath))
        }
    }

    /// Importa al hub los juegos de Epic que son DRM‑free de verdad. Idempotente.
    /// Devuelve cuántos entraron y los que quedaron fuera con su motivo.
    @discardableResult
    static func sync() -> (imported: Int, blocked: [(title: String, reason: String)]) {
        var imported = 0
        var blocked: [(String, String)] = []
        for a in analyzeInstalled() {
            guard FileManager.default.fileExists(atPath: a.entry.executablePath) else { continue }
            if a.isDRMFree {
                LocalGamesStore.shared.upsertInstalledCopy(
                    source: .epic, sourceId: a.entry.appName, name: a.entry.title,
                    executablePath: a.entry.executablePath, installPath: a.entry.installPath,
                    coverURL: coverURL(appName: a.entry.appName))
                imported += 1
            } else if let reason = a.blocker {
                blocked.append((a.entry.title, reason))
            }
        }
        LocalGamesStore.shared.pruneMissing(source: .epic)
        return (imported, blocked)
    }
}
