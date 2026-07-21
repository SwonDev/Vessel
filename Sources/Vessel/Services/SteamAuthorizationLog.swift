import Foundation

/// Evidencia de que Steam ha llevado una autorización legal hasta su interfaz visible.
///
/// `console_log.txt` solo confirma que el backend se detuvo en `ShowEula`. La prueba de que
/// el usuario puede revisar el acuerdo está en `webhelper_js.txt`, donde SteamUI registra
/// `prompt for eula`. Mantener ambas señales separadas evita afirmar que hay un diálogo cuando
/// el CEF está negro, se ha reiniciado o todavía no ha terminado de cargar.
enum SteamAuthorizationLog {
    /// Devuelve únicamente lo escrito después de una captura. Steam puede rotar los registros;
    /// si eso ocurre, el fichero completo pertenece a la nueva generación.
    static func delta(in current: Data, after baseline: Data) -> String {
        let relevant: Data
        if current.count >= baseline.count, current.starts(with: baseline) {
            relevant = Data(current.dropFirst(baseline.count))
        } else {
            relevant = current
        }
        return String(decoding: relevant, as: UTF8.self)
    }

    static func eulaPromptRendered(
        in current: Data,
        after baseline: Data,
        appId: String
    ) -> Bool {
        let text = delta(in: current, after: baseline).lowercased()
        let id = appId.lowercased()
        return text.contains("prompt for eula \(id)_eula_")
            || text.contains("ongameactionuserrequest: \(id) launchapp showeula")
    }

    static func webHelperRestarted(in current: Data, after baseline: Data) -> Bool {
        delta(in: current, after: baseline)
            .localizedCaseInsensitiveContains("Restart webhelper process")
    }

    static func steamUIReady(in current: Data, after baseline: Data) -> Bool {
        let text = delta(in: current, after: baseline)
        return text.localizedCaseInsensitiveContains("SteamApp Init - After Login")
            || text.localizedCaseInsensitiveContains("SteamApp Init:")
    }

    /// SteamUI confirma la aceptación en `webhelper_js.txt`, incluso cuando el backend no llega a
    /// escribir inmediatamente `continues with user response` en `console_log.txt`.
    static func eulaAccepted(
        in current: Data,
        after baseline: Data,
        appId: String
    ) -> Bool {
        let text = delta(in: current, after: baseline).lowercased()
        let eulaPrefix = "\(appId.lowercased())_eula_"
        return text.contains("accepted eula \(eulaPrefix)")
            || text.contains("eulas complete \(eulaPrefix)")
    }

    /// Una respuesta explícita o el avance a otra tarea resuelve el `ShowEula`. Si no aparece
    /// ninguna de esas señales, el backend sigue esperando aunque el modal haya desaparecido.
    static func eulaResolved(
        in current: Data,
        after baseline: Data,
        appId: String
    ) -> Bool {
        let expectedPrefix = "gameaction [appid \(appId.lowercased()),"
        var waitingForEULA = false

        for rawLine in delta(in: current, after: baseline)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.lowercased()
            guard line.contains(expectedPrefix) else { continue }

            if line.contains("waiting for user response to showeula") {
                waitingForEULA = true
                continue
            }
            guard waitingForEULA else { continue }

            if line.contains("continues with user response")
                || (line.contains("changed task to") && !line.contains("showeula"))
                || line.contains("cancel") {
                return true
            }
        }
        return false
    }
}
