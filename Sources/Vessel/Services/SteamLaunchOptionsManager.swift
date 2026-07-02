import Foundation

/// Inyecta Launch Options en el `localconfig.vdf` de Steam para que los juegos
/// D3D11 (Unity) arranquen con los flags correctos bajo DXMT.
///
/// ## Problema
///
/// Cuando Steam lanza un juego, hereda el entorno de `steam.exe` (incluido
/// `WINEDLLOVERRIDES`), pero NO inyecta automáticamente los flags de línea
/// de comandos que algunos motores (Unity) necesitan para funcionar con DXMT:
///
/// - `-force-d3d11-no-singlethreaded`: Unity crea el device D3D11 en multi-threaded
///   mode, necesario para DXMT.
/// - `-screen-fullscreen 0`: fuerza windowed mode, evita crashes de fullscreen
///   con D3DMetal.
///
/// Sin estos flags, juegos Unity D3D11 fallan con:
/// ```
/// Failed to initialize graphics.
/// InitializeEngineGraphics failed
/// ```
///
/// ## Solución
///
/// Modificar `localconfig.vdf` de Steam para añadir `LaunchOptions` a cada
/// juego instalado. Steam lee estas launch options al lanzar el juego y las
/// pasa como argumentos de línea de comandos.
///
/// ## Formato de localconfig.vdf
///
/// El archivo VDF (Valve Data Format) tiene una sección `apps` con un bloque
/// por cada AppID instalado. Añadimos `"LaunchOptions" "-force-d3d11-no-singlethreaded -screen-fullscreen 0"`
/// dentro de cada bloque de app.
@MainActor
@Observable
final class SteamLaunchOptionsManager {
    /// Flags de Unity para DXMT. Seguros para juegos no-Unity (se ignoran).
    static let unityDXMTFlags = "-force-d3d11-no-singlethreaded -screen-fullscreen 0"

    /// AppIDs conocidos que necesitan flags especiales. Por ahora, todos los
    /// juegos D3D11 reciben los flags de Unity (son ignorados si no son Unity).
    /// Esto es seguro porque los flags no reconocidos son simplemente ignorados
    /// por motores que no son Unity.

    /// Encuentra el `localconfig.vdf` del primer usuario de Steam en el bottle.
    func findLocalConfig(in bottle: Bottle) -> String? {
        let userDataRoot = "\(bottle.steamDirectory)/userdata"
        let fm = FileManager.default
        guard let userDirs = try? fm.contentsOfDirectory(atPath: userDataRoot) else {
            return nil
        }
        for userDir in userDirs {
            let configPath = "\(userDataRoot)/\(userDir)/config/localconfig.vdf"
            if fm.fileExists(atPath: configPath) {
                return configPath
            }
        }
        return nil
    }

    /// Inyecta Launch Options en todos los juegos instalados en el bottle.
    /// Idempotente: si ya tienen LaunchOptions, las actualiza.
    func injectLaunchOptions(in bottle: Bottle) async throws {
        guard let configPath = findLocalConfig(in: bottle) else {
            // No hay usuario de Steam configurado todavía. Es normal si Steam
            // no se ha abierto nunca. No es un error.
            return
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath) else { return }

        // Leer el archivo
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return
        }

        // Hacer backup
        let backupPath = "\(configPath).vessel-bak"
        if !fm.fileExists(atPath: backupPath) {
            try? fm.copyItem(atPath: configPath, toPath: backupPath)
        }

        // Parsear e inyectar LaunchOptions en cada app de la sección apps
        let modified = try Self.injectLaunchOptionsIntoVDF(content: content, launchOptions: Self.unityDXMTFlags)

        if modified != content {
            try modified.write(toFile: configPath, atomically: true, encoding: .utf8)
            LogStore.shared.log("Launch Options inyectadas en localconfig.vdf", level: .info)
        }
    }

    /// Parsea el VDF e inyecta LaunchOptions en cada bloque de app.
    /// Usa un parser de VDF basado en líneas (suficiente para localconfig.vdf).
    nonisolated static func injectLaunchOptionsIntoVDF(content: String, launchOptions: String) throws -> String {
        var lines = content.components(separatedBy: .newlines)
        var inAppsSection = false
        var inAppBlock = false
        var appBlockStart = -1
        var appBlockDepth = 0
        var modified = false

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detectar sección "apps"
            if trimmed == "\"apps\"" {
                inAppsSection = true
                i += 1
                continue
            }

            // Si estamos en la sección apps, buscar bloques de apps
            if inAppsSection {
                // Detectar inicio de bloque de app: una línea con solo un AppID entre comillas
                // seguida de una línea con '{'
                if !inAppBlock && line.contains("\"") && !line.contains("{") && !line.contains("}") {
                    // Verificar si la siguiente línea es '{'
                    if i + 1 < lines.count && lines[i + 1].trimmingCharacters(in: .whitespaces) == "{" {
                        inAppBlock = true
                        appBlockStart = i
                        appBlockDepth = 1
                        i += 2 // saltar el AppID y el '{'
                        continue
                    }
                }

                if inAppBlock {
                    appBlockDepth += line.count { $0 == "{" } - line.count { $0 == "}" }

                    if appBlockDepth == 0 {
                        // Fin del bloque de app. Buscar si ya tiene LaunchOptions.
                        let blockText = lines[appBlockStart...i].joined(separator: "\n")
                        let indent = detectIndent(from: lines, at: appBlockStart)

                        if blockText.contains("LaunchOptions") {
                            // Actualizar LaunchOptions existente
                            for k in appBlockStart...i {
                                if lines[k].contains("LaunchOptions") {
                                    lines[k] = "\(indent)\"LaunchOptions\"\t\t\"\(launchOptions)\""
                                    modified = true
                                    break
                                }
                            }
                        } else {
                            // Insertar LaunchOptions antes del cierre
                            lines.insert("\(indent)\"LaunchOptions\"\t\t\"\(launchOptions)\"", at: i)
                            modified = true
                            i += 1 // ajustar por la inserción
                        }

                        inAppBlock = false
                        appBlockStart = -1
                    }
                }

                // Detectar fin de sección apps
                if trimmed == "}" && !inAppBlock && appBlockDepth == 0 {
                    inAppsSection = false
                }
            }

            i += 1
        }

        return modified ? lines.joined(separator: "\n") : content
    }

    /// Detecta la indentación de un bloque de app para que LaunchOptions encaje.
    nonisolated static func detectIndent(from lines: [String], at index: Int) -> String {
        // La indentación de LaunchOptions es un nivel más profunda que el AppID
        let line = lines[index]
        let currentIndent = line.prefix(while: { $0 == "\t" || $0 == " " })
        return String(currentIndent) + "\t"
    }
}
