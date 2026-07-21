import Foundation

/// Estado observable del cliente Steam a partir de `connection_log.txt`.
///
/// El fichero se conserva entre ejecuciones. Por eso el consumidor puede pasar el tamaño que tenía
/// justo antes de arrancar Steam: solo los eventos posteriores pertenecen al intento actual.
enum SteamConnectionLogState: Equatable {
    case unknown
    case starting
    case connected
    case disconnected
    /// Steam invalida esta conexión porque la misma cuenta inició otro cliente. Este estado es
    /// terminal para el proceso actual: el propio registro dice que no intentará reconectar.
    case sessionReplaced
    case accessDenied

    /// Analiza únicamente lo escrito después de una captura previa del fichero. Comparar el
    /// contenido —no solo su tamaño— es imprescindible porque Steam rota `connection_log.txt` al
    /// arrancar: el fichero nuevo puede volver a superar rápidamente el tamaño anterior y un offset
    /// desnudo terminaría cortándolo por la mitad, perdiendo precisamente el `Logged On` actual.
    static func parse(_ data: Data, afterBaseline baseline: Data) -> Self {
        guard !baseline.isEmpty else { return parse(data) }
        if data.count >= baseline.count, data.starts(with: baseline) {
            return parse(data, afterByteOffset: baseline.count)
        }
        // Rotado, truncado o reemplazado: todo el contenido pertenece a la nueva generación.
        return parse(data)
    }

    /// Steam conserva meses de eventos en el mismo fichero. Para conocer el estado vivo basta la
    /// cola reciente, que contiene siempre la generación de arranque actual. Se descarta la primera
    /// línea parcial para no comenzar en mitad de una secuencia UTF-8 o de un evento.
    static func parseRecent(_ data: Data, maximumBytes: Int = 128 * 1_024) -> Self {
        guard maximumBytes > 0, data.count > maximumBytes else { return parse(data) }
        var recent = data.subdata(in: (data.count - maximumBytes)..<data.count)
        if let firstNewline = recent.firstIndex(of: 0x0A) {
            let next = recent.index(after: firstNewline)
            recent = recent.subdata(in: next..<recent.endIndex)
        }
        return parse(recent)
    }

    static func parse(_ data: Data, afterByteOffset byteOffset: Int? = nil) -> Self {
        let relevantData: Data
        if let byteOffset, byteOffset > 0, byteOffset <= data.count {
            relevantData = data.subdata(in: byteOffset..<data.count)
        } else {
            // Si Steam rotó o truncó el fichero, el tamaño anterior deja de ser aplicable y el
            // contenido completo ya pertenece al nuevo registro.
            relevantData = data
        }

        guard let text = String(data: relevantData, encoding: .utf8), !text.isEmpty else {
            return .unknown
        }

        var state: Self = .unknown
        // Steam escribe el registro con CRLF. En Swift, `\r\n` forma un único `Character`, por
        // lo que `split(separator: "\n")` no lo separa y todo el fichero termina tratado como una
        // sola línea: `Client version` gana siempre aunque después exista un `Logged On`. Separar
        // por cualquier carácter Unicode de nueva línea cubre CRLF, LF y los registros migrados.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.contains("Client version") {
                state = .starting
            } else if line.contains("Access Denied") || line.contains("LogonFailureReceived") {
                state = .accessDenied
            } else if line.localizedCaseInsensitiveContains("Session Replaced") {
                state = .sessionReplaced
            } else if line.contains("[Logged On,") || line.contains(" Logged On,") {
                state = .connected
            } else if line.contains("[Logged Off,")
                        || line.contains(" Logged Off,")
                        || line.contains("ConnectionDisconnected") {
                // No degradar `Access Denied` al `Logged Off` que Steam escribe inmediatamente
                // después: el rechazo remoto es la causa que necesita autorreparación explícita.
                if state != .accessDenied, state != .sessionReplaced {
                    state = .disconnected
                }
            }
        }
        return state
    }
}
