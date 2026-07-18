import Foundation

/// Repara estados de pantalla conocidos que el propio juego o una sincronización antigua pueden
/// restaurar y que, bajo Wine + Retina, dejan la ventana fuera de escala.
///
/// Las reglas son deliberadamente estrechas: una corrección solo se aplica a un AppID y a una
/// combinación de valores comprobada en vivo. No cambia el motor, la capa gráfica ni una preferencia
/// de ventana válida del usuario.
enum GameDisplayStateRepair {
    struct Report: Equatable {
        var repairedFiles: [String] = []
        var backupFiles: [String] = []

        var didRepair: Bool { !repairedFiles.isEmpty }
    }

    private static let tinkerlandsAppID = "2617700"
    private static let tinkerlandsOptionsRelativePath = "AppData/Local/Tinkerlands/useroptions.conf"
    private static let backupSuffix = ".vessel-windowed-backup"

    /// Repara el estado justo antes de lanzar el juego, después de cualquier restauración de partida
    /// o sincronización previa. Es idempotente y conserva una copia exacta antes del primer cambio.
    @discardableResult
    nonisolated static func repairBeforeLaunch(
        appId: String?,
        executable: String,
        prefix: String,
        fileManager: FileManager = .default
    ) -> Report {
        guard appId == tinkerlandsAppID,
              (executable as NSString).lastPathComponent.caseInsensitiveCompare("tinkerlands.exe") == .orderedSame else {
            return Report()
        }

        let gameDirectory = (executable as NSString).deletingLastPathComponent
        guard fileManager.fileExists(atPath: "\(gameDirectory)/data.win") else { return Report() }

        let usersDirectory = "\(prefix)/drive_c/users"
        guard let users = try? fileManager.contentsOfDirectory(atPath: usersDirectory) else {
            return Report()
        }

        var report = Report()
        for user in users.sorted() {
            let path = "\(usersDirectory)/\(user)/\(tinkerlandsOptionsRelativePath)"
            guard let original = try? String(contentsOfFile: path, encoding: .utf8),
                  let repaired = repairedTinkerlandsOptions(original) else { continue }

            let backupPath = path + backupSuffix
            if !fileManager.fileExists(atPath: backupPath) {
                do {
                    try fileManager.copyItem(atPath: path, toPath: backupPath)
                    report.backupFiles.append(backupPath)
                } catch {
                    // Sin una copia recuperable no se toca el estado del usuario.
                    continue
                }
            }

            do {
                try Data(repaired.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
                report.repairedFiles.append(path)
            } catch {
                continue
            }
        }
        return report
    }

    /// Tinkerlands guarda la resolución como un índice. La combinación `fullscreen = 0` y el índice
    /// máximo `resolution = 6` crea una ventana del tamaño físico de la pantalla en puntos Retina:
    /// queda decorada, desborda el escritorio y desplaza las coordenadas de entrada. Solo esa
    /// combinación patológica se normaliza; una ventana de menor resolución se respeta.
    nonisolated static func repairedTinkerlandsOptions(_ original: String) -> String? {
        guard let data = original.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let fullscreen = root["fullscreen"] as? NSNumber,
              let resolution = root["resolution"] as? NSNumber,
              fullscreen.doubleValue == 0,
              resolution.doubleValue >= 6 else { return nil }

        let fieldPattern = #""fullscreen"\s*:\s*0(?:\.0+)?(?:[eE][+-]?0+)?"#
        guard let fieldRange = original.range(of: fieldPattern, options: .regularExpression) else {
            return nil
        }
        let field = original[fieldRange]
        guard let valueRange = field.range(
            of: #"0(?:\.0+)?(?:[eE][+-]?0+)?$"#,
            options: .regularExpression
        ) else { return nil }

        var repaired = original
        repaired.replaceSubrange(valueRange, with: "1.0")
        return repaired
    }
}
