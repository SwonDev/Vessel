import Foundation
import Security
import CryptoKit

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

    private let cmTransport = SteamCMAuthTransport()

    // MARK: - QR login

    func beginQR() async throws -> QRSession {
        // platform_type=1 (EAuthTokenPlatformType_SteamClient): el refresh_token resultante lleva
        // `aud=[client,web,…]` → sirve PARA EL CLIENTE de Steam (auto-login sembrado por
        // SteamClientSeeder) Y para la web (biblioteca/logros). Con WebBrowser(=2) el aud es solo
        // `[web]` y NO sirve al cliente de escritorio. website_id `Unknown` (propio del cliente).
        let machineName = Self.steamMachineName()
        var details = Data()
        details.append(ProtoWriter.string(field: 1, machineName))
        details.append(ProtoWriter.varint(field: 2, 1))           // EAuthTokenPlatformType_SteamClient
        details.append(ProtoWriter.varint(field: 3, 20))          // EOSType.Win11
        details.append(ProtoWriter.varint(field: 4, 1))           // EGamingDeviceType: desktop PC
        var body = Data()
        body.append(ProtoWriter.string(field: 1, machineName))
        body.append(ProtoWriter.varint(field: 2, 1))
        body.append(ProtoWriter.message(field: 3, details))       // device_details
        body.append(ProtoWriter.string(field: 4, "Unknown"))      // website_id del cliente oficial

        let data = try await cmTransport.request(method: "BeginAuthSessionViaQR", body: body)
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
        let machineName = Self.steamMachineName()
        var details = Data()
        details.append(ProtoWriter.string(field: 1, machineName))
        details.append(ProtoWriter.varint(field: 2, 1))                           // SteamClient (ver beginQR)
        details.append(ProtoWriter.varint(field: 3, 20))                          // EOSType.Win11
        details.append(ProtoWriter.varint(field: 4, 1))                           // desktop PC
        details.append(ProtoWriter.bytes(field: 6, Self.steamMachineID(accountName: accountName)))
        var body = Data()
        body.append(ProtoWriter.string(field: 1, machineName))                     // device_friendly_name
        body.append(ProtoWriter.string(field: 2, accountName))
        body.append(ProtoWriter.string(field: 3, encrypted))                      // encrypted_password
        body.append(ProtoWriter.varint(field: 4, rsa.timestamp))                  // encryption_timestamp
        body.append(ProtoWriter.varint(field: 5, rememberLogin ? 1 : 0))          // remember_login
        body.append(ProtoWriter.varint(field: 6, 1))                              // platform_type=SteamClient
        body.append(ProtoWriter.varint(field: 7, rememberLogin ? 1 : 0))          // persistence (1=persistent)
        body.append(ProtoWriter.string(field: 8, "Unknown"))                      // website_id cliente Steam
        body.append(ProtoWriter.message(field: 9, details))

        let data = try await cmTransport.request(method: "BeginAuthSessionViaCredentials", body: body)
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
        body.append(ProtoWriter.fixed64(field: 2, steamID))
        body.append(ProtoWriter.string(field: 3, code))
        body.append(ProtoWriter.varint(field: 4, UInt64(codeType)))
        _ = try await cmTransport.request(method: "UpdateAuthSessionWithSteamGuardCode", body: body)
    }

    // MARK: - Polling (común a QR y credenciales)

    func poll(handle: PollHandle) async throws -> Tokens? {
        var body = Data()
        body.append(ProtoWriter.varint(field: 1, handle.clientID))
        body.append(ProtoWriter.bytes(field: 2, handle.requestID))
        let data = try await cmTransport.request(method: "PollAuthSessionStatus", body: body)
        let f = ProtoReader.parse(data)
        // Campos REALES de CAuthentication_PollAuthSessionStatus_Response:
        // 1=new_client_id, 2=new_challenge_url, 3=refresh_token, 4=access_token,
        // 5=had_remote_interaction, 6=account_name. (Antes se leían 2/3/5 → tokens corruptos:
        // el "refresh" era la challenge_url de 39 chars y el access_token quedaba vacío.)
        guard let refresh = f.string(3), !refresh.isEmpty else { return nil }  // refresh_token=3
        let access = f.string(4) ?? ""                                          // access_token=4
        let account = f.string(6) ?? ""                                         // account_name=6
        UserDefaults.standard.set(access, forKey: "steam.accessToken")
        UserDefaults.standard.set(account, forKey: "steam.accountName")
        UserDefaults.standard.set(refresh, forKey: "steam.refreshToken")
        UserDefaults.standard.removeObject(forKey: Self.rejectedRefreshFingerprintKey)
        // Solo una credencial emitida por este flujo CM real puede reemplazar deliberadamente
        // una sesión ConnectCache que ya funcione. La huella (no el token) queda pendiente hasta
        // que SteamClientSeeder la haya escrito con éxito en el prefijo.
        UserDefaults.standard.set(
            Self.refreshFingerprint(refresh),
            forKey: Self.clientSessionSeedPendingFingerprintKey
        )
        UserDefaults.standard.set(false, forKey: "steam.sessionNeedsReauthentication")
        // SteamID64 (claim `sub` del JWT): lo necesita SteamClientSeeder para sembrar la sesión
        // del cliente (loginusers.vdf + universo de la clave ConnectCache).
        if let sid = Self.steamID64(fromJWT: refresh) {
            UserDefaults.standard.set(String(sid), forKey: "steam.steamID64")
        }
        await cmTransport.close()
        return Tokens(accountName: account, accessToken: access, refreshToken: refresh)
    }

    /// Extrae el SteamID64 del claim `sub` del payload de un JWT (refresh/access token de Steam).
    nonisolated static func steamID64(fromJWT jwt: String) -> UInt64? {
        guard let obj = jwtPayload(jwt), let sub = obj["sub"] as? String else { return nil }
        return UInt64(sub)
    }

    /// Audiencias declaradas por Steam en el JWT. Es importante distinguirlas: desde abril de
    /// 2025 un refresh de `SteamClient` ya no puede obtener un access token mediante la Web API;
    /// Steam exige hacerlo dentro de una sesión CM autenticada. Un HTTP 200 vacío NO significa que
    /// el refresh del cliente esté revocado.
    nonisolated static func jwtAudiences(_ jwt: String) -> Set<String> {
        guard let obj = jwtPayload(jwt) else { return [] }
        if let values = obj["aud"] as? [String] { return Set(values) }
        if let value = obj["aud"] as? String { return [value] }
        return []
    }

    private nonisolated static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // MARK: - Sesión permanente (login una vez)

    /// Devuelve un **access_token válido** para autenticar como el usuario (logros y biblioteca
    /// privada). Conserva el emitido al iniciar sesión mientras esté vigente. SteamClient renueva su
    /// sesión de juego sobre CM; la Web API ya no permite derivar otro access token de ese refresh.
    /// Cadena vacía cuando no hay un access token web utilizable, sin invalidar por ello el cliente.
    static func currentAccessToken() async -> String {
        let access = UserDefaults.standard.string(forKey: "steam.accessToken") ?? ""
        if !access.isEmpty, !isJWTExpired(access) {
            // Un access token web aún vigente no rehabilita un refresh de cliente que Steam ya
            // rechazó sobre CM. Son credenciales distintas y la sesión de juego sigue inválida.
            if !storedRefreshWasRejectedRemotely {
                UserDefaults.standard.set(false, forKey: "steam.sessionNeedsReauthentication")
            }
            return access
        }
        let refresh = UserDefaults.standard.string(forKey: "steam.refreshToken") ?? ""
        guard !refresh.isEmpty, !isJWTExpired(refresh) else {
            if !refresh.isEmpty { UserDefaults.standard.set(true, forKey: "steam.sessionNeedsReauthentication") }
            return ""
        }
        // SteamClient renueva por CM, no por este endpoint Web API. Intentarlo devuelve 200 sin
        // cuerpo y NO demuestra revocación; tampoco debe invalidar el login que usa Steam Windows.
        // MobileApp sí admite la renovación HTTP documentada.
        guard jwtAudiences(refresh).contains("mobile") else { return "" }
        if let fresh = try? await SteamAuthService().generateAccessToken(refreshToken: refresh), !fresh.isEmpty {
            UserDefaults.standard.set(fresh, forKey: "steam.accessToken")
            UserDefaults.standard.set(false, forKey: "steam.sessionNeedsReauthentication")
            return fresh
        }
        // Un access token caducado nunca es un fallback útil: solo provoca 401 y hace creer a la UI
        // que la sesión sigue viva. Esta rama solo se alcanza con refresh MobileApp, cuya renovación
        // sí está admitida por la Web API.
        UserDefaults.standard.set(true, forKey: "steam.sessionNeedsReauthentication")
        return ""
    }

    /// Comprueba que la sesión guardada pertenece a un cliente Steam, está vigente y corresponde a la
    /// misma cuenta. No llama a `GenerateAccessTokenForApp`: Steam dejó de admitir refresh tokens de
    /// SteamClient por Web API y responde 200 vacío aunque el token sea nuevo y válido. La validación
    /// remota real la realiza el propio cliente Steam Windows al abrir su sesión CM.
    static func validateStoredClientSession() async -> Bool {
        let refresh = UserDefaults.standard.string(forKey: "steam.refreshToken") ?? ""
        guard !refresh.isEmpty, !isJWTExpired(refresh) else {
            if !refresh.isEmpty { UserDefaults.standard.set(true, forKey: "steam.sessionNeedsReauthentication") }
            return false
        }
        let storedSteamID = UserDefaults.standard.string(forKey: "steam.steamID64") ?? ""
        guard isClientRefreshTokenUsable(refresh, storedSteamID: storedSteamID),
              let tokenSteamID = steamID64(fromJWT: refresh) else {
            UserDefaults.standard.set(true, forKey: "steam.sessionNeedsReauthentication")
            return false
        }
        guard !storedRefreshWasRejectedRemotely else {
            UserDefaults.standard.set(true, forKey: "steam.sessionNeedsReauthentication")
            return false
        }
        if storedSteamID.isEmpty {
            UserDefaults.standard.set(String(tokenSteamID), forKey: "steam.steamID64")
        }
        UserDefaults.standard.set(false, forKey: "steam.sessionNeedsReauthentication")
        return true
    }

    /// Núcleo puro de la validación local, separado para poder cubrirlo sin tocar las credenciales
    /// reales del usuario durante las pruebas.
    nonisolated static func isClientRefreshTokenUsable(_ refresh: String, storedSteamID: String) -> Bool {
        guard !refresh.isEmpty, !isJWTExpired(refresh), jwtAudiences(refresh).contains("client"),
              let tokenSteamID = steamID64(fromJWT: refresh) else { return false }
        return storedSteamID.isEmpty || storedSteamID == String(tokenSteamID)
    }

    /// Registra sin secretos que el cliente Steam rechazó el refresh actual sobre CM. La huella
    /// evita bloquear un login posterior: cuando cambia el token, la validación vuelve a empezar.
    static func markStoredClientSessionRejectedBySteam() {
        let defaults = UserDefaults.standard
        let refresh = defaults.string(forKey: "steam.refreshToken") ?? ""
        guard !refresh.isEmpty else { return }
        defaults.set(refreshFingerprint(refresh), forKey: rejectedRefreshFingerprintKey)
        defaults.removeObject(forKey: clientSessionSeedPendingFingerprintKey)
        defaults.set(true, forKey: "steam.sessionNeedsReauthentication")
    }

    nonisolated static func refreshFingerprint(_ refresh: String) -> String {
        SHA256.hash(data: Data(refresh.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let rejectedRefreshFingerprintKey = "steam.remoteRejectedRefreshTokenSHA256"
    private static let clientSessionSeedPendingFingerprintKey = "steam.clientSessionSeedPendingRefreshTokenSHA256"
    private static let clientSessionSeededFingerprintKey = "steam.clientSessionSeededRefreshTokenSHA256"

    /// Decide de forma pura si la credencial guardada debe escribirse en ConnectCache. Una sesión
    /// existente solo se reemplaza tras un login CM nuevo y para esa misma huella; así un token
    /// heredado o todavía no confirmado nunca pisa silenciosamente una sesión real funcional.
    nonisolated static func shouldSeedStoredRefresh(
        hasExistingClientSession: Bool,
        storedRefresh: String,
        pendingFingerprint: String
    ) -> Bool {
        guard hasExistingClientSession else { return true }
        guard !storedRefresh.isEmpty, !pendingFingerprint.isEmpty else { return false }
        return refreshFingerprint(storedRefresh) == pendingFingerprint
    }

    static func shouldSeedStoredRefresh(hasExistingClientSession: Bool) -> Bool {
        let defaults = UserDefaults.standard
        return shouldSeedStoredRefresh(
            hasExistingClientSession: hasExistingClientSession,
            storedRefresh: defaults.string(forKey: "steam.refreshToken") ?? "",
            pendingFingerprint: defaults.string(forKey: clientSessionSeedPendingFingerprintKey) ?? ""
        )
    }

    /// Registra únicamente la huella del refresh que Vessel escribió realmente en el cliente.
    /// Permite atribuir un futuro Access Denied al token correcto sin invalidar credenciales web
    /// cuando el ConnectCache procedía del propio Steam o de una sesión anterior distinta.
    static func markStoredClientSessionSeeded(refreshToken: String) {
        let defaults = UserDefaults.standard
        let current = defaults.string(forKey: "steam.refreshToken") ?? ""
        guard !current.isEmpty, current == refreshToken else { return }
        let fingerprint = refreshFingerprint(refreshToken)
        defaults.set(fingerprint, forKey: clientSessionSeededFingerprintKey)
        if defaults.string(forKey: clientSessionSeedPendingFingerprintKey) == fingerprint {
            defaults.removeObject(forKey: clientSessionSeedPendingFingerprintKey)
        }
    }

    static var storedRefreshMatchesSeededClientSession: Bool {
        let defaults = UserDefaults.standard
        let refresh = defaults.string(forKey: "steam.refreshToken") ?? ""
        let seeded = defaults.string(forKey: clientSessionSeededFingerprintKey) ?? ""
        return !refresh.isEmpty && !seeded.isEmpty && refreshFingerprint(refresh) == seeded
    }

    static func clearClientSessionSeedTracking() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: clientSessionSeedPendingFingerprintKey)
        defaults.removeObject(forKey: clientSessionSeededFingerprintKey)
    }

    private static var storedRefreshWasRejectedRemotely: Bool {
        let defaults = UserDefaults.standard
        let refresh = defaults.string(forKey: "steam.refreshToken") ?? ""
        let rejected = defaults.string(forKey: rejectedRefreshFingerprintKey) ?? ""
        guard !refresh.isEmpty, !rejected.isEmpty else { return false }
        let matches = refreshFingerprint(refresh) == rejected
        if !matches {
            // El usuario ya obtuvo credenciales nuevas: el rechazo pertenecía exclusivamente al
            // token anterior y no debe contaminar la sesión recién creada.
            defaults.removeObject(forKey: rejectedRefreshFingerprintKey)
        }
        return matches
    }

    /// Mintea un access_token nuevo a partir del refresh_token (IAuthenticationService).
    func generateAccessToken(refreshToken: String) async throws -> String? {
        var body = Data()
        body.append(ProtoWriter.string(field: 1, refreshToken))              // refresh_token
        if let sid = UInt64(SteamAccountService.currentSteamID64) {
            body.append(ProtoWriter.fixed64(field: 2, sid))                  // steamid (fixed64)
        }
        let data = try await cmTransport.request(method: "GenerateAccessTokenForApp", body: body)
        return ProtoReader.parse(data).string(1)                             // access_token=1
    }

    /// ¿El JWT (access/refresh token de Steam) ha caducado? Decodifica el `exp` del payload. Si no se
    /// puede leer, lo tratamos como caducado (para forzar refresco).
    nonisolated static func isJWTExpired(_ jwt: String, margin: TimeInterval = 120) -> Bool {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return true }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double else { return true }
        return Date().timeIntervalSince1970 + margin >= exp
    }

    /// ¿Hay una sesión de Steam guardada (refresh_token)? Para la UI.
    nonisolated static var hasStoredSession: Bool {
        !(UserDefaults.standard.string(forKey: "steam.refreshToken") ?? "").isEmpty
    }

    /// ¿La sesión guardada ha CADUCADO? (refresh_token presente pero expirado). Si es `true`, los
    /// logros reales, la propiedad de DLC y el seeding del cliente degradan a "sin datos" en silencio
    /// → la UI avisa para que el usuario vuelva a iniciar sesión.
    nonisolated static var storedSessionExpired: Bool {
        let refresh = UserDefaults.standard.string(forKey: "steam.refreshToken") ?? ""
        return !refresh.isEmpty && isJWTExpired(refresh)
    }

    /// Incluye caducidad cronológica y cualquier incoherencia local confirmada al preparar el cliente.
    nonisolated static var storedSessionNeedsReauthentication: Bool {
        storedSessionExpired || UserDefaults.standard.bool(forKey: "steam.sessionNeedsReauthentication")
    }

    // MARK: - RSA

    private func getRSAKey(accountName: String) async throws -> (mod: String, exp: String, timestamp: UInt64) {
        var body = Data()
        body.append(ProtoWriter.string(field: 1, accountName))
        let data = try await cmTransport.request(method: "GetPasswordRSAPublicKey", body: body)
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

    nonisolated static func steamMachineName(hostname: String = ProcessInfo.processInfo.hostName) -> String {
        let digest = Insecure.SHA1.hash(data: Data(hostname.utf8))
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let suffix = digest.prefix(7).map { letters[Int($0) % letters.count] }
        return "DESKTOP-\(String(suffix))"
    }

    /// Formato KeyValues binario que usa Steam para identificar de forma estable la máquina sin
    /// revelar datos del Mac. Depende de la cuenta, igual que el cliente oficial.
    nonisolated static func steamMachineID(accountName: String) -> Data {
        func sha1Hex(_ value: String) -> String {
            Insecure.SHA1.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        func cString(_ value: String) -> Data { Data(value.utf8) + Data([0]) }

        var result = Data([0])
        result.append(cString("MessageObject"))
        for (name, seed) in [("BB3", "BB3"), ("FF2", "FF2"), ("3B3", "3B3")] {
            result.append(1)
            result.append(cString(name))
            result.append(cString(sha1Hex("SteamUser Hash \(seed) \(accountName)")))
        }
        result.append(contentsOf: [8, 8])
        return result
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
    static func fixed64(field: Int, _ value: UInt64) -> Data { tag(field, 1) + withUnsafeBytes(of: value.littleEndian) { Data($0) } }
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
