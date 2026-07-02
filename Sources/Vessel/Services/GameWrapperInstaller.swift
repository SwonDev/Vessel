import Foundation

/// Instala y mantiene wrappers de juegos en un bottle Steam.
///
/// ## Problema
///
/// Cuando Steam lanza un juego, el proceso hijo puede no heredar correctamente
/// los `WINEDLLOVERRIDES` del entorno de `steam.exe`. Esto hace que Wine cargue
/// su `d3d11.dll` builtin en vez del DXMT nativo, causando que juegos D3D11
/// (Unity) fallen con `InitializeEngineGraphics failed`.
///
/// ## Solución
///
/// Un wrapper PE32+ (~155KB) compilado con mingw-w64 que:
/// 1. Resuelve su propio path (ej: `C:\...\TemtemSwarm.exe`)
/// 2. Deriva el binario real: `C:\...\TemtemSwarm_real.exe`
/// 3. Llama `SetEnvironmentVariableW("WINEDLLOVERRIDES", DXMT overrides)`
/// 4. Lanza el binario real con flags de Unity vía `CreateProcessW`
/// 5. El hijo hereda el entorno del wrapper (con WINEDLLOVERRIDES DXMT)
///
/// ## Instalación
///
/// Por cada juego en `steamapps/common/`:
/// 1. Identificar el .exe principal (el que coincide con el nombre del directorio,
///    o el más grande si no hay coincidencia)
/// 2. Si el .exe es >500KB (es el real, no un wrapper previo):
///    - Renombrar a `<nombre>_real.exe`
///    - Copiar el wrapper como `<nombre>.exe`
/// 3. Si el .exe es <500KB (ya es un wrapper), verificar que `_real.exe` existe
///
/// ## Idempotente
///
/// Se puede ejecutar múltiples veces. Si el wrapper ya está instalado, no hace nada.
@MainActor
@Observable
final class GameWrapperInstaller {
    enum WrapperError: LocalizedError {
        case wrapperBinaryNotFound
        case steamAppsDirectoryNotFound
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .wrapperBinaryNotFound: return "No se encontró el binario del game-wrapper."
            case .steamAppsDirectoryNotFound: return "No se encontró el directorio steamapps de Steam."
            case .installFailed(let msg): return "Instalación del wrapper falló: \(msg)"
            }
        }
    }

    /// Umbral para distinguir wrapper (<500KB) de binario real (>500KB).
    private static let wrapperSizeCeiling: UInt64 = 500_000

    /// Exclusiones conocidas: .exe que no son juegos y no deben wrappearse.
    private static let excludedNames: Set<String> = [
        "unitycrashhandler64.exe",
        "unitycrashhandler32.exe",
        "crashhandler.exe",
        "setup.exe",
        "uninstall.exe",
        "config.exe",
        "launch.exe",
        "helper.exe",
        "steam_api.dll",
    ]

    /// Resuelve la ruta al wrapper precompilado (bundle en Resources).
    private static var wrapperBinaryPath: String {
        if let url = Bundle.main.url(forResource: "game-wrapper", withExtension: "exe") {
            return url.path
        }
        return "/Users/vesseldeveloper0000/Documents/vessel-mac/Resources/game-wrapper.exe"
    }

    /// Escanea `steamapps/common/` e instala wrappers en todos los juegos detectados.
    /// Idempotente: si un juego ya tiene wrapper, lo refresca.
    func installInAllGames(in bottle: Bottle) async throws {
        let fm = FileManager.default
        let wrapperPath = Self.wrapperBinaryPath

        guard fm.fileExists(atPath: wrapperPath) else {
            throw WrapperError.wrapperBinaryNotFound
        }

        let steamApps = "\(bottle.steamDirectory)/steamapps/common"
        guard fm.fileExists(atPath: steamApps) else {
            // Steam no tiene juegos instalados todavía. No es un error.
            return
        }

        let gameDirs = (try? fm.contentsOfDirectory(atPath: steamApps)) ?? []
        var wrapped = 0

        for dir in gameDirs {
            let gameDir = "\(steamApps)/\(dir)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: gameDir, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            if try await wrapMainExecutable(in: gameDir, wrapperPath: wrapperPath) {
                wrapped += 1
            }
        }

        if wrapped > 0 {
            LogStore.shared.log("Game wrappers instalados en \(wrapped) juego(s)", level: .info)
        }
    }

    /// Identifica y wrappea el .exe principal de un directorio de juego.
    /// Devuelve `true` si se instaló o refrescó el wrapper.
    private func wrapMainExecutable(in gameDir: String, wrapperPath: String) async throws -> Bool {
        let fm = FileManager.default
        let dirName = (gameDir as NSString).lastPathComponent

        // Listar .exe en el directorio raíz del juego
        let contents = (try? fm.contentsOfDirectory(atPath: gameDir)) ?? []
        let exes = contents.filter { $0.lowercased().hasSuffix(".exe") }

        guard !exes.isEmpty else { return false }

        // Filtrar exclusiones
        let candidates = exes.filter { exe in
            let lower = exe.lowercased()
            if Self.excludedNames.contains(lower) { return false }
            // Excluir .exe que contienen "crash", "handler", "setup", "uninstall"
            if lower.contains("crash") || lower.contains("handler") { return false }
            if lower.contains("setup") || lower.contains("uninstall") { return false }
            return true
        }

        guard !candidates.isEmpty else { return false }

        // Preferir el .exe que coincide con el nombre del directorio
        let preferredName = "\(dirName).exe"
        let mainExe: String
        if candidates.contains(preferredName) {
            mainExe = preferredName
        } else if candidates.count == 1 {
            mainExe = candidates[0]
        } else {
            // Si hay varios, elegir el más grande (probablemente el juego principal)
            let sorted = candidates.sorted { a, b in
                let sizeA = (try? fm.attributesOfItem(atPath: "\(gameDir)/\(a)")[.size] as? UInt64) ?? 0
                let sizeB = (try? fm.attributesOfItem(atPath: "\(gameDir)/\(b)")[.size] as? UInt64) ?? 0
                return sizeA > sizeB
            }
            mainExe = sorted[0]
        }

        let exePath = "\(gameDir)/\(mainExe)"
        let exeBasename = (mainExe as NSString).deletingPathExtension
        let realExeName = "\(exeBasename)_real.exe"
        let realExePath = "\(gameDir)/\(realExeName)"

        // Si ya es un wrapper (<500KB) y existe _real.exe, refrescar wrapper
        let exeSize = (try? fm.attributesOfItem(atPath: exePath)[.size] as? UInt64) ?? 0

        if exeSize < Self.wrapperSizeCeiling {
            // Ya es un wrapper. Verificar que _real.exe existe.
            if fm.fileExists(atPath: realExePath) {
                // Refrescar wrapper (por si actualizamos el binario)
                try? fm.removeItem(atPath: exePath)
                try fm.copyItem(atPath: wrapperPath, toPath: exePath)
                // Asegurar symlink de data folder
                try ensureDataSymlink(gameDir: gameDir, exeBasename: exeBasename)
                return true
            } else {
                // Wrapper sin real: el real se perdió. No podemos hacer nada.
                return false
            }
        }

        // exeSize >= ceiling: es el binario real. Wrappear.
        // Respaldar como _real.exe (solo si no existe ya)
        if !fm.fileExists(atPath: realExePath) || isWrapperSize(atPath: realExePath) {
            try? fm.removeItem(atPath: realExePath)
            try fm.copyItem(atPath: exePath, toPath: realExePath)
        }

        // Instalar wrapper
        try? fm.removeItem(atPath: exePath)
        try fm.copyItem(atPath: wrapperPath, toPath: exePath)

        // Crear symlink <exeBasename>_real_Data -> <exeBasename>_Data
        // Unity busca <nombre_exe>_Data basándose en GetModuleFileName.
        // Como el real ahora se llama <nombre>_real.exe, Unity busca <nombre>_real_Data.
        try ensureDataSymlink(gameDir: gameDir, exeBasename: exeBasename)

        LogStore.shared.log("Wrapper instalado para \(mainExe)", level: .info)
        return true
    }

    /// Crea un symlink `<exeBasename>_real_Data` → `<exeBasename>_Data` para que
    /// Unity encuentre su data folder cuando el ejecutable real se llama `_real.exe`.
    /// Si el data folder no existe o el symlink ya existe, no hace nada.
    private func ensureDataSymlink(gameDir: String, exeBasename: String) throws {
        let fm = FileManager.default
        let originalData = "\(gameDir)/\(exeBasename)_Data"
        let realData = "\(gameDir)/\(exeBasename)_real_Data"

        // Solo crear el symlink si el data folder original existe
        guard fm.fileExists(atPath: originalData) else { return }

        // Si el symlink ya existe y apunta al destino correcto, no hacer nada
        if let existingDest = try? fm.destinationOfSymbolicLink(atPath: realData) {
            if existingDest == "\(exeBasename)_Data" {
                return
            }
            // El symlink apunta a otro sitio, recrearlo
            try? fm.removeItem(atPath: realData)
        }

        // Crear el symlink (relativo, como en Unix)
        try? fm.removeItem(atPath: realData)
        try fm.createSymbolicLink(
            atPath: realData,
            withDestinationPath: "\(exeBasename)_Data"
        )
    }

    private func isWrapperSize(atPath path: String) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64 else {
            return false
        }
        return size < Self.wrapperSizeCeiling
    }

    /// Comprueba si hay juegos wrappeados en el bottle.
    func hasWrappedGames(in bottle: Bottle) -> Bool {
        let steamApps = "\(bottle.steamDirectory)/steamapps/common"
        guard let gameDirs = try? FileManager.default.contentsOfDirectory(atPath: steamApps) else {
            return false
        }
        for dir in gameDirs {
            let gameDir = "\(steamApps)/\(dir)"
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: gameDir)) ?? []
            if contents.contains(where: { $0.lowercased().hasSuffix("_real.exe") }) {
                return true
            }
        }
        return false
    }
}
