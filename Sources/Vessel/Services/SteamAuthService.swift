import Foundation
import Security

/// Cliente del flujo de autenticación **oficial** de Steam (`IAuthenticationService`),
/// el mismo que usan la app y el cliente de Steam. Soporta login por **QR** (Steam
/// Guard desde el móvil) y por **usuario/contraseña** (con cifrado RSA de la
/// contraseña, igual que el login oficial), con opción de **recordar sesión**.
/// Obtiene `refresh_token`/`access_token`: con ellos se carga la biblioteca y se
/// valida SteamCMD. Ver [[vessel-seccion-tienda-plan]]. Validado contra los servidores
/// reales de Steam (eresult=1). Cero manipulación: es Steam real, seguro.
@MainActor
@Observable
final class SteamAuthService {
    struct PollHandle {
        let clientID: UInt64
        let requestID: Data
        let interval: Double
    }
    struct QRSession {
        let handle: PollHandle
        let challengeURL: String   // contenido del QR
    }
    struct Tokens {
        let accountName: String
        let accessToken: String
        let refreshToken: String
    }
    enum CredentialsResult {
        case session(PollHandle)                                   // login directo
        case needsGuard(PollHandle, steamID: UInt64, codeType: Int)
        case badPassword
        case failed(String)
    }

    private let host = "https://api.steampowered.com"

    // MARK: - QR login

    func beginQR() async throws -> QRSession {
        var details = Data()
        details.append(ProtoWriter.string(field: 1, "Vessel"))
        details.append(ProtoWriter.varint(field: 2, 2))           // EAuthTokenPlatformType_WebBrowser
        var body = Data()
        body.append(ProtoWriter.string(field: 1, "Vessel"))
        body.append(ProtoWriter.varint(field: 2, 2))
        body.append(ProtoWriter.message(field: 3, details))       // device_details
        body.append(ProtoWriter.string(field: 4, "Community"))    // website_id

        let data = try await post("IAuthenticationService/BeginAuthSessionViaQR/v1/", protobuf: body)
        let f = ProtoReader.parse(data)
        guard let clientID = f.varint(1), let challenge = f.string(2), let requestID = f.bytes(3) else {
            throw err("Respuesta inesperada de Steam al iniciar el QR.")
        }
        return QRSession(handle: PollHandle(clientID: clientID, requestID: requestID, interval: Double(f.float(4) ?? 5)), challengeURL: challenge)
    }

    // MARK: - Usuario/contraseña

    func loginWithCredentials(accountName: String, password: String, rememberLogin: Bool) async throws -> CredentialsResult {
        let rsa = try await getRSAKey(accountName: accountName)
        guard let encrypted = rsaEncrypt(password, modHex: rsa.mod, expHex: rsa.exp) else {
            return .failed("No se pudo cifrar la contraseña.")
        }
        var details = Data()
        details.append(ProtoWriter.string(field: 1, "Vessel"))
        details.append(ProtoWriter.varint(field: 2, 2))
        var body = Data()
        body.append(ProtoWriter.string(field: 1, "Vessel"))                       // device_friendly_name
        body.append(ProtoWriter.string(field: 2, accountName))
        body.append(ProtoWriter.string(field: 3, encrypted))                      // encrypted_password
        body.append(ProtoWriter.varint(field: 4, rsa.timestamp))                  // encryption_timestamp
        body.append(ProtoWriter.varint(field: 5, rememberLogin ? 1 : 0))          // remember_login
        body.append(ProtoWriter.varint(field: 6, 2))                              // platform_type
        body.append(ProtoWriter.varint(field: 7, rememberLogin ? 1 : 0))          // persistence (1=persistent)
        body.append(ProtoWriter.string(field: 8, "Community"))                    // website_id
        body.append(ProtoWriter.message(field: 9, details))

        let data = try await post("IAuthenticationService/BeginAuthSessionViaCredentials/v1/", protobuf: body)
        let f = ProtoReader.parse(data)
        guard let clientID = f.varint(1), let requestID = f.bytes(2) else { return .badPassword }
        let handle = PollHandle(clientID: clientID, requestID: requestID, interval: Double(f.float(3) ?? 5))
        let steamID = f.varint(5) ?? 0
        // allowed_confirmations (campo 4, repetido). confirmation_type != 1 (None) => pide código.
        var codeType = 0
        for value in f.all(4) {
            if case .bytes(let conf) = value {
                let cf = ProtoReader.parse(conf)
                if let t = cf.varint(1), t != 1 { codeType = Int(t); break }
            }
        }
        return codeType != 0 ? .needsGuard(handle, steamID: steamID, codeType: codeType) : .session(handle)
    }

    /// Envía el código de Steam Guard (email/dispositivo) para confirmar el login.
    func submitSteamGuard(handle: PollHandle, steamID: UInt64, code: String, codeType: Int) async throws {
        var body = Data()
        body.append(ProtoWriter.varint(field: 1, handle.clientID))
        body.append(ProtoWriter.varint(field: 2, steamID))
        body.append(ProtoWriter.string(field: 3, code))
        body.append(ProtoWriter.varint(field: 4, UInt64(codeType)))
        _ = try await post("IAuthenticationService/UpdateAuthSessionWithSteamGuardCode/v1/", protobuf: body)
    }

    // MARK: - Polling (común a QR y credenciales)

    func poll(handle: PollHandle) async throws -> Tokens? {
        var body = Data()
        body.append(ProtoWriter.varint(field: 1, handle.clientID))
        body.append(ProtoWriter.bytes(field: 2, handle.requestID))
        let data = try await post("IAuthenticationService/PollAuthSessionStatus/v1/", protobuf: body)
        let f = ProtoReader.parse(data)
        guard let refresh = f.string(2), !refresh.isEmpty else { return nil }  // refresh_token=2
        let access = f.string(3) ?? ""                                          // access_token=3
        let account = f.string(5) ?? ""                                         // account_name=5
        UserDefaults.standard.set(access, forKey: "steam.accessToken")
        UserDefaults.standard.set(account, forKey: "steam.accountName")
        UserDefaults.standard.set(refresh, forKey: "steam.refreshToken")
        return Tokens(accountName: account, accessToken: access, refreshToken: refresh)
    }

    // MARK: - RSA

    private func getRSAKey(accountName: String) async throws -> (mod: String, exp: String, timestamp: UInt64) {
        var body = Data()
        body.append(ProtoWriter.string(field: 1, accountName))
        let data = try await get("IAuthenticationService/GetPasswordRSAPublicKey/v1/", protobuf: body)
        let f = ProtoReader.parse(data)
        guard let mod = f.string(1), let exp = f.string(2) else { throw err("No se pudo obtener la clave de cifrado de Steam.") }
        return (mod, exp, f.varint(3) ?? 0)
    }

    private func rsaEncrypt(_ password: String, modHex: String, expHex: String) -> String? {
        guard let mod = Data(hexString: modHex), let exp = Data(hexString: expHex) else { return nil }
        let der = Self.rsaPublicKeyDER(modulus: mod, exponent: exp)
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: mod.count * 8
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil),
              let enc = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(password.utf8) as CFData, nil) else {
            return nil
        }
        return (enc as Data).base64EncodedString()
    }

    // MARK: - HTTP

    private func post(_ path: String, protobuf: Data) async throws -> Data {
        try await send(path, protobuf: protobuf, method: "POST")
    }
    private func get(_ path: String, protobuf: Data) async throws -> Data {
        let b64 = protobuf.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let url = URL(string: "\(host)/\(path)?input_protobuf_encoded=\(b64)") else { throw err("URL inválida") }
        var request = URLRequest(url: url)
        request.setValue("Vessel", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw err("Steam respondió con error.") }
        return data
    }
    private func send(_ path: String, protobuf: Data, method: String) async throws -> Data {
        guard let url = URL(string: "\(host)/\(path)") else { throw err("URL inválida") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Vessel", forHTTPHeaderField: "User-Agent")
        let b64 = protobuf.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        request.httpBody = "input_protobuf_encoded=\(b64)".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw err("Steam respondió con error de autenticación.") }
        return data
    }

    private func err(_ message: String) -> NSError {
        NSError(domain: "Vessel", code: 50, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - ASN.1 DER para la clave RSA pública

    nonisolated static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        let body = asn1Integer(modulus) + asn1Integer(exponent)
        return Data([0x30]) + asn1Length(body.count) + body
    }
    nonisolated private static func asn1Length(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var len = length, bytes: [UInt8] = []
        while len > 0 { bytes.insert(UInt8(len & 0xFF), at: 0); len >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    nonisolated private static func asn1Integer(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        let content = Data(bytes)
        return Data([0x02]) + asn1Length(content.count) + content
    }
}

extension Data {
    init?(hexString: String) {
        var data = Data()
        var hex = hexString
        if hex.count % 2 != 0 { hex = "0" + hex }
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

// MARK: - Protobuf mínimo (wire format)

enum ProtoWriter {
    static func varint(field: Int, _ value: UInt64) -> Data { tag(field, 0) + encodeVarint(value) }
    static func string(field: Int, _ value: String) -> Data { bytes(field: field, Data(value.utf8)) }
    static func bytes(field: Int, _ value: Data) -> Data { tag(field, 2) + encodeVarint(UInt64(value.count)) + value }
    static func message(field: Int, _ value: Data) -> Data { bytes(field: field, value) }
    private static func tag(_ field: Int, _ wire: UInt8) -> Data { encodeVarint(UInt64(field) << 3 | UInt64(wire)) }
    private static func encodeVarint(_ v: UInt64) -> Data {
        var value = v, out = Data()
        repeat {
            var byte = UInt8(value & 0x7F); value >>= 7
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
            let field = Int(key >> 3); let wire = key & 0x7
            switch wire {
            case 0:
                guard let (v, n2) = readVarint(data, i) else { return reader }
                i = n2; reader.map[field, default: []].append(.varint(v))
            case 2:
                guard let (len, n2) = readVarint(data, i) else { return reader }
                i = n2
                let end = data.index(i, offsetBy: Int(len), limitedBy: data.endIndex) ?? data.endIndex
                reader.map[field, default: []].append(.bytes(data.subdata(in: i..<end))); i = end
            case 5:
                let end = data.index(i, offsetBy: 4, limitedBy: data.endIndex) ?? data.endIndex
                if end - i == 4 { reader.map[field, default: []].append(.fixed32(data.subdata(in: i..<end).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })) }
                i = end
            case 1:
                let end = data.index(i, offsetBy: 8, limitedBy: data.endIndex) ?? data.endIndex
                if end - i == 8 { reader.map[field, default: []].append(.fixed64(data.subdata(in: i..<end).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })) }
                i = end
            default: return reader
            }
        }
        return reader
    }

    func all(_ field: Int) -> [Value] { map[field] ?? [] }
    func varint(_ field: Int) -> UInt64? {
        for v in all(field) {
            if case .varint(let x) = v { return x }
            if case .fixed64(let x) = v { return x }
            if case .fixed32(let x) = v { return UInt64(x) }
        }
        return nil
    }
    func string(_ field: Int) -> String? { bytes(field).flatMap { String(data: $0, encoding: .utf8) } }
    func bytes(_ field: Int) -> Data? {
        for v in all(field) { if case .bytes(let d) = v { return d } }
        return nil
    }
    func float(_ field: Int) -> Float? {
        for v in all(field) { if case .fixed32(let x) = v { return Float(bitPattern: x) } }
        return nil
    }

    private static func readVarint(_ data: Data, _ start: Data.Index) -> (UInt64, Data.Index)? {
        var result: UInt64 = 0, shift: UInt64 = 0, i = start
        while i < data.endIndex {
            let byte = data[i]; result |= UInt64(byte & 0x7F) << shift; i = data.index(after: i)
            if byte & 0x80 == 0 { return (result, i) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}
