import Foundation

/// **Siembra la sesión del cliente de Steam para auto-login por JWT — SIN CEF.**
///
/// Los juegos con DRM de Steamworks (Grim Dawn, FFT…) exigen el cliente de Steam abierto y
/// LOGUEADO. El cliente auto-loguea por JWT si tiene una sesión guardada, pero para un usuario
/// NUEVO el primer login pasa por el CEF de Steam, que en el M5 no renderiza bien. Este servicio
/// resuelve ese primer login usando el login NATIVO de Vessel (`SteamAuthService`, que ya obtiene
/// un `refresh_token`) para **sembrar** directamente la sesión del cliente.
///
/// Formato verificado in-vivo (2026-07-03) para Steam+Wine de este proyecto:
///  - Fichero `…/AppData/Local/Steam/local.vdf`:
///    `MachineUserConfigStore > Software > Valve > Steam > ConnectCache > "<clave>" = "<blob-hex>"`
///  - **clave** = CRC32(login en minúsculas) en hex de 8 dígitos + dígito de **universo** (Public=1).
///  - **valor** = `refresh_token` JWT crudo (aud incluye "client" → platform_type=SteamClient)
///    cifrado con `CryptProtectData` (DPAPI de Wine), **entropía = login**, serializado en hex.
///  - Además: `config/loginusers.vdf` (RememberPassword=1, AllowAutoLogin=1, MostRecent=1) y el
///    registro `HKCU\Software\Valve\Steam\AutoLoginUser`.
///
/// El cifrado NO se reimplementa en Swift (frágil): lo hace el propio `crypt32` de Wine vía el
/// helper PE `dpapi-seal.exe`, ejecutado en el MISMO prefijo → compatibilidad byte a byte.
/// Referencias: `mutabless/Steam-Token-Login`, `darknight1050/SteamJWT`, `wine/dlls/crypt32/protectdata.c`.
@MainActor
final class SteamClientSeeder {
    static let shared = SteamClientSeeder()
    private init() {}

    private let log = LogStore.shared

    /// Siembra el auto-login del cliente de Steam. Devuelve `true` si escribió la sesión.
    /// - Parameters:
    ///   - login: nombre de cuenta de Steam (el mismo con el que se logueó en Vessel).
    ///   - steamID64: SteamID de 64 bits del usuario.
    ///   - personaName: nombre visible (para `loginusers.vdf`; cosmético).
    ///   - refreshToken: `refresh_token` JWT de tipo **SteamClient** (aud incluye "client").
    ///   - bottle: bottle donde vive el cliente de Steam.
    ///   - wine: binario wine del motor con el que corre el cliente (para sellar en su prefijo).
    func seed(login: String, steamID64: UInt64, personaName: String,
              refreshToken: String, in bottle: Bottle, wine: String) async -> Bool {
        let account = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, steamID64 > 0, !refreshToken.isEmpty else {
            log.log("Seeding de Steam: datos insuficientes (login/steamID/token).", level: .warn)
            return false
        }
        guard let sealExe = Self.dpapiSealExecutable() else {
            log.log("Seeding de Steam: falta dpapi-seal.exe en el bundle; no se puede sembrar.", level: .error)
            return false
        }

        // 1) Sellar el token con el DPAPI de Wine (entropía = login), en el MISMO prefijo.
        guard let sealedHex = await sealToken(refreshToken, entropy: account,
                                              sealExe: sealExe, bottle: bottle, wine: wine),
              sealedHex.count > 32 else {
            log.log("Seeding de Steam: el sellado DPAPI falló.", level: .error)
            return false
        }

        // 2) Clave ConnectCache = CRC32(login minúsculas) hex(8) + universo.
        let crc = String(format: "%08x", Self.crc32(Array(account.lowercased().utf8)))
        let universe = (steamID64 >> 56) & 0xFF                 // Public = 1
        let cacheKey = "\(crc)\(universe)"

        // 3) Rutas del prefijo.
        let userDir = Self.prefixUserDirectory(in: bottle)
        let localSteamDir = "\(userDir)/AppData/Local/Steam"
        let localVdf = "\(localSteamDir)/local.vdf"
        let steamConfigDir = "\(bottle.steamDirectory)/config"
        let loginUsersVdf = "\(steamConfigDir)/loginusers.vdf"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: localSteamDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: steamConfigDir, withIntermediateDirectories: true)

        // 4) Escribir local.vdf (ConnectCache) — respaldando el previo por si acaso.
        if fm.fileExists(atPath: localVdf) {
            try? fm.removeItem(atPath: "\(localVdf).vessel-bak")
            try? fm.copyItem(atPath: localVdf, toPath: "\(localVdf).vessel-bak")
        }
        let localContent = Self.localVdf(cacheKey: cacheKey, sealedHex: sealedHex)
        do { try localContent.write(toFile: localVdf, atomically: true, encoding: .utf8) }
        catch { log.log("Seeding de Steam: no se pudo escribir local.vdf: \(error.localizedDescription)", level: .error); return false }

        // 5) loginusers.vdf (cuenta recordada + auto-login).
        let persona = personaName.isEmpty ? account : personaName
        let now = Int(Date().timeIntervalSince1970)
        let usersContent = Self.loginUsersVdf(steamID64: steamID64, account: account, persona: persona, timestamp: now)
        try? usersContent.write(toFile: loginUsersVdf, atomically: true, encoding: .utf8)

        // 6) Registro: AutoLoginUser = login (idempotente).
        await setAutoLoginUser(account, in: bottle, wine: wine)

        log.log("Sesión de Steam sembrada para «\(account)» (auto-login por JWT, sin CEF). Clave ConnectCache \(cacheKey).", level: .info)
        return true
    }

    /// True si el prefijo ya tiene una sesión de Steam sembrada/guardada (local.vdf con ConnectCache).
    func hasSeededSession(in bottle: Bottle) -> Bool {
        let localVdf = "\(Self.prefixUserDirectory(in: bottle))/AppData/Local/Steam/local.vdf"
        guard let s = try? String(contentsOfFile: localVdf, encoding: .utf8) else { return false }
        return s.contains("ConnectCache")
    }

    // MARK: - Sellado DPAPI (vía helper PE en el prefijo)

    private func sealToken(_ token: String, entropy: String, sealExe: String,
                           bottle: Bottle, wine: String) async -> String? {
        // El helper lee el HEX del plaintext por stdin y escribe el HEX del blob por stdout.
        let tokenHex = token.utf8.map { String(format: "%02x", $0) }.joined()
        guard let engineRoot = WineEngineLocator.engineRoot(forWineExecutable: URL(fileURLWithPath: wine)) else { return nil }
        let libDir = engineRoot.appendingPathComponent("lib").path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: wine)
        proc.arguments = [sealExe, "seal", entropy]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.prefixPath
        env["WINEDEBUG"] = "-all"
        env["WINEMSYNC"] = "0"; env["WINEESYNC"] = "0"; env["WINEFSYNC"] = "0"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = libDir
        proc.environment = env

        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = Pipe()
        do { try proc.run() } catch {
            log.log("Seeding de Steam: no se pudo lanzar dpapi-seal.exe: \(error.localizedDescription)", level: .error)
            return nil
        }
        stdinPipe.fileHandleForWriting.write(Data(tokenHex.utf8))
        try? stdinPipe.fileHandleForWriting.close()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let hex = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return hex.allSatisfy { $0.isHexDigit } && !hex.isEmpty ? hex : nil
    }

    private func setAutoLoginUser(_ account: String, in bottle: Bottle, wine: String) async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: wine)
        proc.arguments = ["reg", "add", #"HKCU\Software\Valve\Steam"#,
                          "/v", "AutoLoginUser", "/t", "REG_SZ", "/d", account, "/f"]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.prefixPath
        env["WINEDEBUG"] = "-all"
        if let engineRoot = WineEngineLocator.engineRoot(forWineExecutable: URL(fileURLWithPath: wine)) {
            env["DYLD_FALLBACK_LIBRARY_PATH"] = engineRoot.appendingPathComponent("lib").path
        }
        proc.environment = env
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    // MARK: - Plantillas VDF

    private static func localVdf(cacheKey: String, sealedHex: String) -> String {
        """
        "MachineUserConfigStore"
        {
        \t"Software"
        \t{
        \t\t"Valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        \t\t\t\t"ConnectCache"
        \t\t\t\t{
        \t\t\t\t\t"\(cacheKey)"\t\t"\(sealedHex)"
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t}
        }

        """
    }

    private static func loginUsersVdf(steamID64: UInt64, account: String, persona: String, timestamp: Int) -> String {
        """
        "users"
        {
        \t"\(steamID64)"
        \t{
        \t\t"AccountName"\t\t"\(account)"
        \t\t"PersonaName"\t\t"\(persona)"
        \t\t"RememberPassword"\t\t"1"
        \t\t"WantsOfflineMode"\t\t"0"
        \t\t"SkipOfflineModeWarning"\t\t"0"
        \t\t"AllowAutoLogin"\t\t"1"
        \t\t"MostRecent"\t\t"1"
        \t\t"Timestamp"\t\t"\(timestamp)"
        \t}
        }

        """
    }

    // MARK: - Utilidades

    /// Carpeta del usuario dentro del prefijo (donde vive AppData). El cliente de Steam guarda
    /// `local.vdf` bajo el usuario de Wine; se usa el que tenga AppData, o `NSUserName()`.
    private static func prefixUserDirectory(in bottle: Bottle) -> String {
        let usersRoot = "\(bottle.prefixPath)/drive_c/users"
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: usersRoot) {
            for u in entries where u != "Public" && u != "crossover" {
                if fm.fileExists(atPath: "\(usersRoot)/\(u)/AppData/Local") { return "\(usersRoot)/\(u)" }
            }
        }
        return "\(usersRoot)/\(NSUserName())"
    }

    /// Ejecutable del helper DPAPI (bundle o, en desarrollo, `Resources/`).
    private static func dpapiSealExecutable() -> String? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("dpapi-seal.exe").path,
           fm.fileExists(atPath: res) { return res }
        // Fallback de desarrollo (ejecutando desde el checkout).
        let dev = "\(fm.currentDirectoryPath)/Resources/dpapi-seal.exe"
        return fm.fileExists(atPath: dev) ? dev : nil
    }

    /// CRC32 (IEEE 802.3) — el que usa Steam para la clave de ConnectCache.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return ~crc
    }
}
