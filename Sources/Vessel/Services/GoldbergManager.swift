import Foundation

/// Gestiona **Goldberg / gbe_fork**, un emulador open-source de la Steamworks API.
/// Reemplaza el `steam_api(64).dll` del juego por una implementación emulada que
/// hace creer al juego que Steam está corriendo y con sesión iniciada, **sin
/// necesitar el cliente de Steam**. Es la vía robusta para el DRM de Steamworks
/// en Apple Silicon: el cliente de Steam (Chromium/CEF) es inestable bajo Wine
/// (error 0x3008) en el motor de GPTK que los juegos D3D12 necesitan, así que en
/// vez de pelear con él, emulamos la API. Legítimo para juegos que posees; es lo
/// que usan Heroic/Lutris para desacoplar el arranque del cliente.
///
/// Solo cubre el DRM de Steamworks. Juegos con DRM adicional (Denuvo, etc.) no se
/// soportan; FF Tactics solo usa Steamworks (fallaba con "Unable to initialize
/// SteamAPI", no con un error de Denuvo).
@MainActor
final class GoldbergManager {
    /// gbe_fork (fork mantenido de Goldberg). El `.7z` lo extrae `tar` (libarchive).
    static let releaseURL = URL(string: "https://github.com/Detanup01/gbe_fork/releases/download/release-2026_05_30/emu-win-release.7z")!

    private let dependencyManager = DependencyManager()

    var cacheDir: String { "\(VesselPaths.cacheDirectory)/goldberg" }
    var steamApi64Path: String { "\(cacheDir)/steam_api64.dll" }
    var steamApi32Path: String { "\(cacheDir)/steam_api.dll" }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: steamApi64Path) }

    func ensureInstalled(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        if isInstalled { return }
        try await dependencyManager.installGoldberg(from: Self.releaseURL, progress: progress)
        guard isInstalled else {
            throw NSError(domain: "Vessel", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "Goldberg se instaló pero no se pudo autodetectar."
            ])
        }
    }

    // MARK: - Aplicar/restaurar en el juego

    /// Reemplaza el/los `steam_api(64).dll` del juego por los de Goldberg
    /// (respaldando el original como `.vessel-orig`) y escribe el AppID + un usuario.
    /// Idempotente: si ya está aplicado, no rehace el respaldo. Devuelve true si el
    /// juego tenía algún `steam_api*.dll` que reemplazar.
    @discardableResult
    func applyToGame(gameExecutable: String, appId: String, accountName: String = "Vessel") -> Bool {
        let gameDir = (gameExecutable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        var applied = false
        if replaceDLL(at: "\(gameDir)/steam_api64.dll", with: steamApi64Path, fm: fm) { applied = true }
        if replaceDLL(at: "\(gameDir)/steam_api.dll", with: steamApi32Path, fm: fm) { applied = true }
        if !appId.isEmpty {
            try? appId.write(toFile: "\(gameDir)/steam_appid.txt", atomically: true, encoding: .utf8)
        }
        writeSteamSettings(inDir: gameDir, appId: appId, accountName: accountName)
        return applied
    }

    /// Restaura el `steam_api(64).dll` original del juego (revertir Goldberg).
    func restoreGame(gameExecutable: String) {
        let gameDir = (gameExecutable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        for name in ["steam_api64.dll", "steam_api.dll"] {
            let path = "\(gameDir)/\(name)"
            let backup = "\(path).vessel-orig"
            guard fm.fileExists(atPath: backup) else { continue }
            try? fm.removeItem(atPath: path)
            try? fm.copyItem(atPath: backup, toPath: path)
        }
    }

    /// Reemplaza un DLL del juego por el de Goldberg. Respalda el original una sola
    /// vez. Si el DLL del juego ya coincide en tamaño con el de Goldberg, asume que
    /// ya está aplicado y no hace nada.
    private func replaceDLL(at gamePath: String, with goldbergPath: String, fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: goldbergPath), fm.fileExists(atPath: gamePath) else { return false }
        let goldbergSize = (try? fm.attributesOfItem(atPath: goldbergPath)[.size] as? UInt64) ?? 0
        let gameSize = (try? fm.attributesOfItem(atPath: gamePath)[.size] as? UInt64) ?? 0
        if gameSize == goldbergSize { return true } // ya es Goldberg
        let backup = "\(gamePath).vessel-orig"
        if !fm.fileExists(atPath: backup) {
            try? fm.copyItem(atPath: gamePath, toPath: backup)
        }
        try? fm.removeItem(atPath: gamePath)
        do {
            try fm.copyItem(atPath: goldbergPath, toPath: gamePath)
            return true
        } catch {
            return false
        }
    }

    /// Escribe `steam_settings/` junto al exe con un usuario por defecto. La versión
    /// experimental de gbe_fork autodetecta las interfaces, así que no hace falta
    /// generar `steam_interfaces.txt`.
    private func writeSteamSettings(inDir dir: String, appId: String, accountName: String) {
        let settingsDir = "\(dir)/steam_settings"
        try? FileManager.default.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
        let userIni = """
        [user::general]
        account_name=\(accountName)
        language=spanish
        ip_country=ES
        """
        try? userIni.write(toFile: "\(settingsDir)/configs.user.ini", atomically: true, encoding: .utf8)
    }
}
