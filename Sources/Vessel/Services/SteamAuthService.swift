import Foundation

/// Cliente del flujo de autenticación **oficial** de Steam (`IAuthenticationService`),
/// el mismo que usa el cliente de Steam para el login por **QR**. Genera el código QR
/// para Steam Guard, espera la aprobación en la app móvil y obtiene los tokens
/// (`refresh_token`/`access_token`). Con ellos se carga la biblioteca (sin pedir la
/// clave Web API) y se valida SteamCMD para instalar. Sustituye al formulario propio
/// por el cuadro de login oficial. Ver [[vessel-seccion-tienda-plan]].
///
/// Protocolo basado en protobuf; aquí se construye/parsea a mano (mensajes simples).
@MainActor
@Observable
final class SteamAuthService {
    struct QRSession {
        let clientID: UInt64
        let requestID: Data
        let challengeURL: String   // contenido del QR (se renderiza como imagen)
        let interval: Double
    }

    struct Tokens {
        let accountName: String
        let accessToken: String
        let refreshToken: String
    }

    private let host = "https://api.steampowered.com"

    // MARK: - QR login

    /// Inicia una sesión de login por QR. `challengeURL` es lo que se pinta en el QR.
    func beginQR() async throws -> QRSession {
        // CAuthentication_BeginAuthSessionViaQR_Request:
        //   device_friendly_name (1, string), platform_type (2, varint=3 SteamClient),
        //   device_details (9, message) { device_friendly_name(1), platform_type(2), os_type(4) }
        var details = Data()
        details.append(ProtoWriter.string(field: 1, "Vessel"))
        details.append(ProtoWriter.varint(field: 2, 3))           // EAuthTokenPlatformType_SteamClient
        details.append(ProtoWriter.varint(field: 4, UInt64(bitPattern: -500)))  // os_type macOS (aprox)
        var body = Data()
        body.append(ProtoWriter.string(field: 1, "Vessel"))
        body.append(ProtoWriter.varint(field: 2, 3))
        body.append(ProtoWriter.message(field: 9, details))

        let data = try await post("IAuthenticationService/BeginAuthSessionViaQR/v1/", protobuf: body)
        let fields = ProtoReader.parse(data)
        guard let clientID = fields.varint(1),
              let challenge = fields.string(2),
              let requestID = fields.bytes(3) else {
            throw NSError(domain: "Vessel", code: 50, userInfo: [NSLocalizedDescriptionKey: "Respuesta de Steam inesperada al iniciar el QR."])
        }
        let interval = fields.float(4) ?? 5.0
        return QRSession(clientID: clientID, requestID: requestID, challengeURL: challenge, interval: Double(interval))
    }

    /// Sondea el estado de la sesión. Devuelve los tokens cuando el usuario aprueba el
    /// login en la app de Steam; nil si aún está pendiente.
    func poll(session: QRSession) async throws -> Tokens? {
        var body = Data()
        body.append(ProtoWriter.varint(field: 1, session.clientID))   // client_id (fixed64 en proto, pero el server acepta varint)
        body.append(ProtoWriter.bytes(field: 2, session.requestID))   // request_id
        let data = try await post("IAuthenticationService/PollAuthSessionStatus/v1/", protobuf: body)
        let fields = ProtoReader.parse(data)
        // refresh_token (4), access_token (5), account_name (3) aparecen al aprobar.
        guard let refresh = fields.string(4), !refresh.isEmpty else { return nil }
        let access = fields.string(5) ?? ""
        let account = fields.string(3) ?? ""
        return Tokens(accountName: account, accessToken: access, refreshToken: refresh)
    }

    // MARK: - HTTP

    private func post(_ path: String, protobuf: Data) async throws -> Data {
        guard let url = URL(string: "\(host)/\(path)") else {
            throw NSError(domain: "Vessel", code: 51)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let b64 = protobuf.base64EncodedString()
        let encoded = b64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? b64
        request.httpBody = "input_protobuf_encoded=\(encoded)".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "Vessel", code: 52, userInfo: [NSLocalizedDescriptionKey: "Steam respondió con error de autenticación."])
        }
        return data
    }
}

// MARK: - Protobuf mínimo (wire format)

enum ProtoWriter {
    static func varint(field: Int, _ value: UInt64) -> Data {
        var d = tag(field, 0)
        d.append(encodeVarint(value))
        return d
    }
    static func string(field: Int, _ value: String) -> Data {
        bytes(field: field, Data(value.utf8))
    }
    static func bytes(field: Int, _ value: Data) -> Data {
        var d = tag(field, 2)
        d.append(encodeVarint(UInt64(value.count)))
        d.append(value)
        return d
    }
    static func message(field: Int, _ value: Data) -> Data { bytes(field: field, value) }

    private static func tag(_ field: Int, _ wire: UInt8) -> Data {
        encodeVarint(UInt64(field) << 3 | UInt64(wire))
    }
    private static func encodeVarint(_ v: UInt64) -> Data {
        var value = v
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }
}

struct ProtoReader {
    enum Value { case varint(UInt64); case bytes(Data); case fixed32(UInt32); case fixed64(UInt64) }
    private var map: [Int: [Value]] = [:]

    static func parse(_ data: Data) -> ProtoReader {
        var reader = ProtoReader()
        var i = data.startIndex
        while i < data.endIndex {
            guard let (key, ni) = readVarint(data, i) else { break }
            i = ni
            let field = Int(key >> 3)
            let wire = key & 0x7
            switch wire {
            case 0:
                guard let (v, ni2) = readVarint(data, i) else { return reader }
                i = ni2; reader.map[field, default: []].append(.varint(v))
            case 2:
                guard let (len, ni2) = readVarint(data, i) else { return reader }
                i = ni2
                let end = data.index(i, offsetBy: Int(len), limitedBy: data.endIndex) ?? data.endIndex
                reader.map[field, default: []].append(.bytes(data.subdata(in: i..<end)))
                i = end
            case 5:
                let end = data.index(i, offsetBy: 4, limitedBy: data.endIndex) ?? data.endIndex
                if end - i == 4 { reader.map[field, default: []].append(.fixed32(data.subdata(in: i..<end).withUnsafeBytes { $0.load(as: UInt32.self) })) }
                i = end
            case 1:
                let end = data.index(i, offsetBy: 8, limitedBy: data.endIndex) ?? data.endIndex
                if end - i == 8 { reader.map[field, default: []].append(.fixed64(data.subdata(in: i..<end).withUnsafeBytes { $0.load(as: UInt64.self) })) }
                i = end
            default:
                return reader
            }
        }
        return reader
    }

    func varint(_ field: Int) -> UInt64? {
        for v in map[field] ?? [] {
            if case .varint(let x) = v { return x }
            if case .fixed64(let x) = v { return x }
            if case .fixed32(let x) = v { return UInt64(x) }
        }
        return nil
    }
    func string(_ field: Int) -> String? {
        if let d = bytes(field) { return String(data: d, encoding: .utf8) }
        return nil
    }
    func bytes(_ field: Int) -> Data? {
        for v in map[field] ?? [] { if case .bytes(let d) = v { return d } }
        return nil
    }
    func float(_ field: Int) -> Float? {
        for v in map[field] ?? [] {
            if case .fixed32(let x) = v { return Float(bitPattern: x) }
        }
        return nil
    }

    private static func readVarint(_ data: Data, _ start: Data.Index) -> (UInt64, Data.Index)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < data.endIndex {
            let byte = data[i]
            result |= UInt64(byte & 0x7F) << shift
            i = data.index(after: i)
            if byte & 0x80 == 0 { return (result, i) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}
