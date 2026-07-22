import Foundation
import CoreGraphics

/// Repara estados de pantalla conocidos que el propio juego o una sincronización antigua pueden
/// restaurar y que, bajo Wine + Retina, dejan la ventana fuera de escala.
///
/// Las reglas son deliberadamente estrechas: las reparaciones persistentes exigen un AppID y una
/// combinación comprobada en vivo; las decisiones de escala por motor exigen varias huellas
/// estructurales independientes. No cambia una preferencia de ventana válida del usuario.
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

    /// Liquid Engine crea su ventana D3D11 con coordenadas físicas aun cuando Wine expone un
    /// escritorio Retina en puntos. En una pantalla 2×, una superficie de 3024×1964 termina así
    /// ocupando 3024×1964 puntos sobre un escritorio lógico de 1512×982. La detección no depende
    /// del título ni de la tienda: exige un PE64 D3D11 y tres huellas independientes del renderer.
    private nonisolated static func isLiquidEngineD3D11Executable(
        _ executable: String,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: executable),
              let data = try? Data(
                contentsOf: URL(fileURLWithPath: executable),
                options: .mappedIfSafe
              ),
              isPE64(data),
              containsAnyASCII(data, ["d3d11.dll", "D3D11.dll", "D3D11.DLL"])
        else { return false }

        let rendererMarkers = [
            #"\liquidengine\core\coreconfig.h"#,
            #"\liquidengine\engine\liquidrenderer.cpp"#,
            #"\liquidengine\engine\renderwindowmanager.cpp"#,
            "LiquidRenderer::Init"
        ]
        let matches = rendererMarkers.reduce(into: 0) { count, marker in
            if data.range(of: Data(marker.utf8)) != nil { count += 1 }
        }
        return matches >= 3
    }

    private nonisolated static func containsAnyASCII(_ data: Data, _ needles: [String]) -> Bool {
        needles.contains { data.range(of: Data($0.utf8)) != nil }
    }

    private nonisolated static func isPE64(_ data: Data) -> Bool {
        guard data.count >= 0x40,
              data[0] == 0x4d,
              data[1] == 0x5a,
              let peOffset = littleEndianUInt32(data, at: 0x3c).map(Int.init),
              peOffset >= 0,
              peOffset + 6 <= data.count,
              data[peOffset] == 0x50,
              data[peOffset + 1] == 0x45,
              data[peOffset + 2] == 0,
              data[peOffset + 3] == 0,
              littleEndianUInt16(data, at: peOffset + 4) == 0x8664
        else { return false }
        return true
    }

    private nonisolated static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private nonisolated static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    /// Determina si el motor necesita coordenadas 1×. Liquid Engine se reconoce por su estructura
    /// binaria; la excepción de RE Engine se limita a la build y AppID comprobados en vivo.
    nonisolated static func requiresOneXWindowCoordinates(
        appId: String?,
        executable: String,
        fileManager: FileManager = .default
    ) -> Bool {
        if isLiquidEngineD3D11Executable(executable, fileManager: fileManager) {
            return true
        }
        guard appId == kunitsuGamiDemoAppID,
              (executable as NSString).lastPathComponent
                .caseInsensitiveCompare(kunitsuGamiDemoExecutable) == .orderedSame
        else { return false }
        guard isKunitsuGamiDemoInstallation(
            executable: executable,
            fileManager: fileManager
        ) else { return false }

        let gameDirectory = (executable as NSString).deletingLastPathComponent
        let configPath = "\(gameDirectory)/\(kunitsuGamiConfigName)"
        guard let config = try? String(contentsOfFile: configPath, encoding: .utf8),
              let section = iniSectionRange(named: "RenderConfig", in: config) else {
            return true
        }
        if let mode = iniValue(for: "WindowMode", in: config, section: section),
           mode.caseInsensitiveCompare("Normal") != .orderedSame {
            return false
        }
        if let fullScreen = iniValue(for: "FullScreenMode", in: config, section: section),
           fullScreen.caseInsensitiveCompare("true") == .orderedSame {
            return false
        }
        return true
    }

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
        guard isKunitsuGamiDemoInstallation(
            executable: executable,
            fileManager: fileManager
        ) else { return Report() }

        let gameDirectory = (executable as NSString).deletingLastPathComponent
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

    private nonisolated static func isKunitsuGamiDemoInstallation(
        executable: String,
        fileManager: FileManager
    ) -> Bool {
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
              ) != nil else { return false }
        return true
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
