import Foundation
import CoreGraphics

/// Repara estados de pantalla conocidos que el propio juego o una sincronización antigua pueden
/// restaurar y que, bajo Wine + Retina, dejan la ventana fuera de escala.
///
/// Las reglas son deliberadamente estrechas: una corrección solo se aplica a un AppID y a una
/// combinación de valores comprobada en vivo. No cambia el motor, la capa gráfica ni una preferencia
/// de ventana válida del usuario.
enum GameDisplayStateRepair {
    struct DisplayMetrics: Equatable, Sendable {
        let logicalWidth: Int
        let logicalHeight: Int
        let backingScale: Double
    }

    struct Resolution: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    struct Report: Equatable {
        var repairedFiles: [String] = []
        var backupFiles: [String] = []

        var didRepair: Bool { !repairedFiles.isEmpty }
    }

    private static let tinkerlandsAppID = "2617700"
    private static let tinkerlandsOptionsRelativePath = "AppData/Local/Tinkerlands/useroptions.conf"
    private static let tinkerlandsBackupSuffix = ".vessel-windowed-backup"
    private static let kunitsuGamiDemoAppID = "2842890"
    private static let kunitsuGamiDemoExecutable = "KunitsuGamiDemo.exe"
    private static let kunitsuGamiConfigName = "config.ini"
    private static let displayBackupSuffix = ".vessel-display-backup"

    /// Repara el estado justo antes de lanzar el juego, después de cualquier restauración de partida
    /// o sincronización previa. Es idempotente y conserva una copia exacta antes del primer cambio.
    @discardableResult
    nonisolated static func repairBeforeLaunch(
        appId: String?,
        executable: String,
        prefix: String,
        fileManager: FileManager = .default,
        displayMetrics: DisplayMetrics? = nil
    ) -> Report {
        let executableName = (executable as NSString).lastPathComponent
        if appId == tinkerlandsAppID,
           executableName.caseInsensitiveCompare("tinkerlands.exe") == .orderedSame {
            return repairTinkerlands(
                executable: executable,
                prefix: prefix,
                fileManager: fileManager
            )
        }
        if appId == kunitsuGamiDemoAppID,
           executableName.caseInsensitiveCompare(kunitsuGamiDemoExecutable) == .orderedSame {
            return repairKunitsuGamiDemo(
                executable: executable,
                fileManager: fileManager,
                displayMetrics: displayMetrics ?? currentDisplayMetrics()
            )
        }
        return Report()
    }

    private nonisolated static func repairTinkerlands(
        executable: String,
        prefix: String,
        fileManager: FileManager
    ) -> Report {
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

            let backupPath = path + tinkerlandsBackupSuffix
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

    /// RE Engine expresa `NormalWindowResolution` en píxeles del framebuffer. Con Retina activo,
    /// una ventana de 1352×878 puntos necesita 2704×1756 píxeles; escribir puntos produciría una
    /// ventana a media escala. Se reserva un 10,6 % vertical para barra de menú, título y Dock y se
    /// conserva la relación de aspecto del escritorio.
    nonisolated static func safeKunitsuGamiResolution(
        displayMetrics: DisplayMetrics
    ) -> Resolution {
        let logicalWidth = max(1, displayMetrics.logicalWidth)
        let logicalHeight = max(1, displayMetrics.logicalHeight)
        let reserve = min(128, max(88, Int((Double(logicalHeight) * 0.106).rounded())))
        let scale = Double(max(1, logicalHeight - reserve)) / Double(logicalHeight)

        func even(_ value: Double, minimum: Int) -> Int {
            max(minimum, Int((value / 2).rounded()) * 2)
        }

        let safeWidth = min(logicalWidth, even(Double(logicalWidth) * scale, minimum: 960))
        let safeHeight = min(logicalHeight, even(Double(logicalHeight) * scale, minimum: 600))
        let backingScale = min(3, max(1, displayMetrics.backingScale))
        return Resolution(
            width: Int((Double(safeWidth) * backingScale).rounded()),
            height: Int((Double(safeHeight) * backingScale).rounded())
        )
    }

    /// Devuelve un `config.ini` seguro únicamente si el estado normal de RE Engine desbordaría la
    /// pantalla. Los modos FullScreen/Borderless y las resoluciones normales válidas del usuario se
    /// respetan. `nil` como entrada representa el primer arranque y crea el mínimo que el propio
    /// juego genera, añadiendo solo el tamaño seguro.
    nonisolated static func repairedKunitsuGamiConfig(
        _ original: String?,
        displayMetrics: DisplayMetrics,
        recognizedPreviousBackingScale: Double? = nil
    ) -> String? {
        let base = original ?? [
            "[Render]",
            "Capability=DirectX12",
            "CentralUpdateTileMapping=Disable",
            "ForceMeshShader=Disable",
            ""
        ].joined(separator: "\r\n")
        let lineEnding = base.contains("\r\n") ? "\r\n" : "\n"
        let target = safeKunitsuGamiResolution(displayMetrics: displayMetrics)

        if let section = iniSectionRange(named: "RenderConfig", in: base) {
            if let mode = iniValue(for: "WindowMode", in: base, section: section),
               mode.caseInsensitiveCompare("Normal") != .orderedSame {
                return nil
            }
            if let fullScreen = iniValue(for: "FullScreenMode", in: base, section: section),
               fullScreen.caseInsensitiveCompare("true") == .orderedSame {
                return nil
            }
            if let value = iniValue(for: "NormalWindowResolution", in: base, section: section),
               let current = parsedResolution(value) {
                let scale = min(3, max(1, displayMetrics.backingScale))
                let logicalWidth = current.width / scale
                let logicalHeight = current.height / scale
                let isUninitialized = current.width <= 1 || current.height <= 1
                let overflows = logicalWidth > Double(displayMetrics.logicalWidth) + 1
                    || logicalHeight + 64 > Double(displayMetrics.logicalHeight)
                let isManagedPreviousScale = recognizedPreviousBackingScale.map { previousScale in
                    let previousTarget = safeKunitsuGamiResolution(
                        displayMetrics: DisplayMetrics(
                            logicalWidth: displayMetrics.logicalWidth,
                            logicalHeight: displayMetrics.logicalHeight,
                            backingScale: previousScale
                        )
                    )
                    return Int(current.width.rounded()) == previousTarget.width
                        && Int(current.height.rounded()) == previousTarget.height
                } ?? false
                guard isUninitialized || overflows || isManagedPreviousScale else { return nil }
            }
        }

        let resolution = String(
            format: "(%d.000000,%d.000000)",
            locale: Locale(identifier: "en_US_POSIX"),
            target.width,
            target.height
        )
        var repaired = setting(
            base,
            section: "RenderConfig",
            key: "NormalWindowResolution",
            value: resolution,
            lineEnding: lineEnding
        )
        repaired = setting(
            repaired,
            section: "RenderConfig",
            key: "FullScreenMode",
            value: "false",
            lineEnding: lineEnding
        )
        repaired = setting(
            repaired,
            section: "RenderConfig",
            key: "WindowMode",
            value: "Normal",
            lineEnding: lineEnding
        )
        return repaired == original ? nil : repaired
    }

    /// Reconcilia únicamente la resolución segura que Vessel ya administra cuando el estado
    /// Retina efectivo cambia. Es necesario porque Steam usa Retina 1× y el juego 2×: si Wine no
    /// acepta el cambio, una resolución física de 2704×1756 se interpreta como puntos y desborda;
    /// si Retina vuelve a estar disponible, la resolución 1× debe recuperar su equivalente 2×.
    @discardableResult
    nonisolated static func repairKunitsuGamiForEffectiveRetina(
        appId: String?,
        executable: String,
        retinaEnabled: Bool,
        fileManager: FileManager = .default,
        displayMetrics: DisplayMetrics? = nil
    ) -> Report {
        let executableName = (executable as NSString).lastPathComponent
        guard appId == kunitsuGamiDemoAppID,
              executableName.caseInsensitiveCompare(kunitsuGamiDemoExecutable) == .orderedSame
        else { return Report() }

        let physicalMetrics = displayMetrics ?? currentDisplayMetrics()
        let effectiveMetrics = DisplayMetrics(
            logicalWidth: physicalMetrics.logicalWidth,
            logicalHeight: physicalMetrics.logicalHeight,
            backingScale: retinaEnabled ? physicalMetrics.backingScale : 1
        )
        return repairKunitsuGamiDemo(
            executable: executable,
            fileManager: fileManager,
            displayMetrics: effectiveMetrics,
            recognizedPreviousBackingScale: retinaEnabled ? 1 : physicalMetrics.backingScale
        )
    }

    private nonisolated static func repairKunitsuGamiDemo(
        executable: String,
        fileManager: FileManager,
        displayMetrics: DisplayMetrics,
        recognizedPreviousBackingScale: Double? = nil
    ) -> Report {
        let gameDirectory = (executable as NSString).deletingLastPathComponent
        guard fileManager.fileExists(atPath: "\(gameDirectory)/re_chunk_000.pak"),
              fileManager.fileExists(atPath: "\(gameDirectory)/steam_api64.dll"),
              let defaults = try? String(
                contentsOfFile: "\(gameDirectory)/config_default.ini",
                encoding: .utf8
              ),
              defaults.contains("[AppRender]"),
              defaults.range(
                of: #"(?mi)^[ \t]*WindowMode[ \t]*=[ \t]*0[ \t]*\r?$"#,
                options: .regularExpression
              ) != nil else { return Report() }

        let path = "\(gameDirectory)/\(kunitsuGamiConfigName)"
        let existed = fileManager.fileExists(atPath: path)
        let original = existed ? try? String(contentsOfFile: path, encoding: .utf8) : nil
        guard !existed || original != nil,
              let repaired = repairedKunitsuGamiConfig(
                original,
                displayMetrics: displayMetrics,
                recognizedPreviousBackingScale: recognizedPreviousBackingScale
              ) else { return Report() }

        var report = Report()
        if existed {
            let backupPath = path + displayBackupSuffix
            if !fileManager.fileExists(atPath: backupPath) {
                do {
                    try fileManager.copyItem(atPath: path, toPath: backupPath)
                    report.backupFiles.append(backupPath)
                } catch {
                    return Report()
                }
            }
        }

        do {
            try Data(repaired.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            report.repairedFiles.append(path)
        } catch {
            return Report()
        }
        return report
    }

    private nonisolated static func currentDisplayMetrics() -> DisplayMetrics {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else {
            return DisplayMetrics(logicalWidth: 1512, logicalHeight: 982, backingScale: 2)
        }
        let scaleX = mode.width > 0 ? Double(mode.pixelWidth) / Double(mode.width) : 1
        let scaleY = mode.height > 0 ? Double(mode.pixelHeight) / Double(mode.height) : 1
        return DisplayMetrics(
            logicalWidth: mode.width,
            logicalHeight: mode.height,
            backingScale: max(scaleX, scaleY)
        )
    }

    private nonisolated static func iniSectionRange(
        named section: String,
        in text: String
    ) -> Range<String.Index>? {
        let headerPattern = "(?mi)^[ \\t]*\\[\(NSRegularExpression.escapedPattern(for: section))\\][ \\t]*\\r?$"
        guard let header = text.range(of: headerPattern, options: .regularExpression) else {
            return nil
        }
        let remainder = header.upperBound..<text.endIndex
        let nextPattern = #"(?mi)^[ \t]*\[[^\]\r\n]+\][ \t]*\r?$"#
        let next = text.range(of: nextPattern, options: .regularExpression, range: remainder)
        return header.upperBound..<(next?.lowerBound ?? text.endIndex)
    }

    private nonisolated static func iniValue(
        for key: String,
        in text: String,
        section: Range<String.Index>
    ) -> String? {
        let pattern = "(?mi)^[ \\t]*\(NSRegularExpression.escapedPattern(for: key))[ \\t]*=[ \\t]*([^\\r\\n]*)"
        guard let range = text.range(of: pattern, options: .regularExpression, range: section) else {
            return nil
        }
        let line = text[range]
        guard let separator = line.firstIndex(of: "=") else { return nil }
        return line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func parsedResolution(_ value: String) -> (width: Double, height: Double)? {
        let pattern = #"^\(\s*([0-9]+(?:\.[0-9]+)?)\s*,\s*([0-9]+(?:\.[0-9]+)?)\s*\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let widthRange = Range(match.range(at: 1), in: value),
              let heightRange = Range(match.range(at: 2), in: value),
              let width = Double(value[widthRange]),
              let height = Double(value[heightRange]) else { return nil }
        return (width, height)
    }

    private nonisolated static func setting(
        _ original: String,
        section: String,
        key: String,
        value: String,
        lineEnding: String
    ) -> String {
        var result = original
        if let body = iniSectionRange(named: section, in: result) {
            let pattern = "(?mi)^[ \\t]*\(NSRegularExpression.escapedPattern(for: key))[ \\t]*=[^\\r\\n]*"
            if let field = result.range(of: pattern, options: .regularExpression, range: body) {
                result.replaceSubrange(field, with: "\(key)=\(value)")
                return result
            }

            let insertion = body.upperBound
            let prefix = result[..<insertion].hasSuffix("\n") ? "" : lineEnding
            result.insert(contentsOf: "\(prefix)\(key)=\(value)\(lineEnding)", at: insertion)
            return result
        }

        if !result.isEmpty, !result.hasSuffix("\n") { result += lineEnding }
        result += "[\(section)]\(lineEnding)\(key)=\(value)\(lineEnding)"
        return result
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
