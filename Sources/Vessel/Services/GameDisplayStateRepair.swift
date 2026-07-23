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
        let visibleWidth: Int?
        let visibleHeight: Int?

        init(
            logicalWidth: Int,
            logicalHeight: Int,
            backingScale: Double,
            visibleWidth: Int? = nil,
            visibleHeight: Int? = nil
        ) {
            self.logicalWidth = logicalWidth
            self.logicalHeight = logicalHeight
            self.backingScale = backingScale
            self.visibleWidth = visibleWidth
            self.visibleHeight = visibleHeight
        }
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
    private static let fourAEnhancedConfigRelativePath = "Saved Games/metro exodus"
    private static let fourAEnhancedConfigName = "user.cfg"
    private static let displayBackupSuffix = ".vessel-display-backup"
    private static let idTechDisplayBackupSuffix = ".vessel-idtech-display-backup"

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
        displayMetrics: DisplayMetrics? = nil,
        isFourAEnhanced: Bool = false
    ) -> Report {
        if isFourAEnhanced {
            return repairFourAEnhancedProfiles(
                prefix: prefix,
                fileManager: fileManager,
                displayMetrics: displayMetrics ?? currentDisplayMetrics()
            )
        }
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

    /// 4A Enhanced conserva la resolución del framebuffer en `user.cfg`. Tras pasar Wine a
    /// coordenadas 1×, una preferencia anterior como 1920×1200 sigue dibujándose dentro de un
    /// contenedor de 1512×982 y el contenido queda recortado durante los cambios de escena. Sólo se
    /// normalizan valores que exceden la pantalla lógica actual; el modo de pantalla completa y las
    /// resoluciones válidas del usuario se conservan sin cambios.
    nonisolated static func repairedFourAEnhancedConfig(
        _ original: String,
        displayMetrics: DisplayMetrics
    ) -> String? {
        guard let width = spaceSeparatedInteger(for: "r_res_hor", in: original),
              let height = spaceSeparatedInteger(for: "r_res_vert", in: original),
              width > 0,
              height > 0 else { return nil }

        let targetWidth = max(1, displayMetrics.logicalWidth)
        let targetHeight = max(1, displayMetrics.logicalHeight)
        guard width > targetWidth || height > targetHeight else { return nil }

        var repaired = replacingSpaceSeparatedInteger(
            in: original,
            key: "r_res_hor",
            value: targetWidth
        )
        repaired = replacingSpaceSeparatedInteger(
            in: repaired,
            key: "r_res_vert",
            value: targetHeight
        )
        return repaired == original ? nil : repaired
    }

    private nonisolated static func repairFourAEnhancedProfiles(
        prefix: String,
        fileManager: FileManager,
        displayMetrics: DisplayMetrics
    ) -> Report {
        let usersDirectory = "\(prefix)/drive_c/users"
        guard let users = try? fileManager.contentsOfDirectory(atPath: usersDirectory) else {
            return Report()
        }

        var report = Report()
        for user in users.sorted() {
            let profilesDirectory = "\(usersDirectory)/\(user)/\(fourAEnhancedConfigRelativePath)"
            guard let profiles = try? fileManager.contentsOfDirectory(atPath: profilesDirectory)
            else { continue }

            for profile in profiles.sorted() {
                let path = "\(profilesDirectory)/\(profile)/\(fourAEnhancedConfigName)"
                guard let original = try? String(contentsOfFile: path, encoding: .utf8),
                      let repaired = repairedFourAEnhancedConfig(
                        original,
                        displayMetrics: displayMetrics
                      ) else { continue }

                let backupPath = path + displayBackupSuffix
                if !fileManager.fileExists(atPath: backupPath) {
                    do {
                        try fileManager.copyItem(atPath: path, toPath: backupPath)
                        report.backupFiles.append(backupPath)
                    } catch {
                        // La preferencia sólo se toca cuando existe una copia recuperable.
                        continue
                    }
                }

                do {
                    try Data(repaired.utf8).write(
                        to: URL(fileURLWithPath: path),
                        options: .atomic
                    )
                    report.repairedFiles.append(path)
                } catch {
                    continue
                }
            }
        }
        return report
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

    /// Área física que el modo borderless compuesto de id Tech puede presentar sin invadir el
    /// borde reservado por WindowServer. `visibleWidth/Height` ya excluyen barra de menú y Dock;
    /// los cuatro puntos horizontales y diecisiete verticales restantes corresponden al margen
    /// mínimo validado con la superficie Retina de WineMetalView.
    nonisolated static func safeIDTechBorderlessResolution(
        displayMetrics: DisplayMetrics
    ) -> Resolution {
        let scale = min(3, max(1, displayMetrics.backingScale))
        let visibleWidth = min(
            max(1, displayMetrics.logicalWidth),
            max(1, displayMetrics.visibleWidth ?? displayMetrics.logicalWidth)
        )
        let visibleHeight = min(
            max(1, displayMetrics.logicalHeight),
            max(1, displayMetrics.visibleHeight ?? displayMetrics.logicalHeight)
        )
        let safeWidth = max(1, visibleWidth - 4)
        let safeHeight = max(1, visibleHeight - 17)
        return Resolution(
            width: Int((Double(safeWidth) * scale).rounded()),
            height: Int((Double(safeHeight) * scale).rounded())
        )
    }

    /// Framebuffer físico completo anunciado al motor durante su inicialización. El modo de
    /// presentación efectivo sigue siendo borderless compuesto; estos valores evitan que una
    /// preferencia antigua fuerce a id Tech a reconstruir un modo exclusivo al recuperar el foco.
    nonisolated static func fullIDTechDisplayResolution(
        displayMetrics: DisplayMetrics
    ) -> Resolution {
        let scale = min(3, max(1, displayMetrics.backingScale))
        return Resolution(
            width: Int((Double(max(1, displayMetrics.logicalWidth)) * scale).rounded()),
            height: Int((Double(max(1, displayMetrics.logicalHeight)) * scale).rounded())
        )
    }

    /// Reconoce el contrato de configuración id Tech desde el propio payload Vulkan. No usa el
    /// título ni el AppID: el nombre `*x64vk.exe`, PE64 y las rutas/cvars embebidas deben derivar del
    /// mismo stem. Devolver el stem permite localizar el perfil sin una tabla por juego.
    nonisolated static func idTechConfigurationStem(
        forExecutable executable: String,
        fileManager: FileManager = .default
    ) -> String? {
        let fileName = (executable as NSString).lastPathComponent
        let executableStem = (fileName as NSString).deletingPathExtension
        let suffix = "x64vk"
        guard fileManager.fileExists(atPath: executable),
              executableStem.lowercased().hasSuffix(suffix),
              executableStem.count > suffix.count,
              let suffixRange = executableStem.range(
                  of: suffix,
                  options: [.caseInsensitive, .backwards]
              ),
              suffixRange.upperBound == executableStem.endIndex else { return nil }

        let stem = String(executableStem[..<suffixRange.lowerBound])
        guard !stem.isEmpty,
              stem.range(of: #"^[A-Za-z0-9._ -]+$"#, options: .regularExpression) != nil,
              let data = try? Data(
                  contentsOf: URL(fileURLWithPath: executable),
                  options: .mappedIfSafe
              ),
              isPE64(data) else { return nil }

        let requiredMarkers = [
            "vulkan-1.dll",
            "\(stem)Config.local",
            "\\id Software\\\(stem)",
            "r_fullscreen",
            "r_initialModeWidth",
            "r_initialModeHeight",
            "r_useFullScreenExclusive"
        ]
        guard requiredMarkers.allSatisfy({ marker in
            data.range(of: Data(marker.utf8)) != nil
        }) else { return nil }
        return stem
    }

    /// Normaliza exclusivamente los cvars de presentación administrados por Vessel. Se conserva el
    /// resto del archivo y su convención de saltos de línea; el juego puede seguir gestionando
    /// calidad, brillo, accesibilidad y cualquier otra preferencia.
    nonisolated static func repairedIDTechLocalConfig(
        _ original: String?,
        displayMetrics: DisplayMetrics
    ) -> String? {
        let base = original ?? "// Ajustes locales de presentación administrados por Vessel\r\n"
        let lineEnding = base.contains("\r\n") ? "\r\n" : "\n"
        let full = fullIDTechDisplayResolution(displayMetrics: displayMetrics)
        let borderless = safeIDTechBorderlessResolution(displayMetrics: displayMetrics)
        let managedValues = [
            ("r_windowHeight", String(borderless.height)),
            ("r_windowWidth", String(borderless.width)),
            ("r_initialModeHeight", String(full.height)),
            ("r_initialModeWidth", String(full.width)),
            ("r_mode", "-2"),
            ("r_fullscreen", "2"),
            ("r_useFullScreenExclusive", "0")
        ]

        var repaired = base
        for (key, value) in managedValues {
            repaired = settingQuotedCVar(
                repaired,
                key: key,
                value: value,
                lineEnding: lineEnding
            )
        }
        return repaired == original ? nil : repaired
    }

    /// Repara todos los perfiles Wine existentes del payload reconocido. Si es el primer arranque,
    /// crea el perfil en el usuario `crossover` —el usuario efectivo de wine-full— y conserva una
    /// copia exacta, una sola vez, antes de modificar cualquier archivo ya existente.
    @discardableResult
    nonisolated static func repairIDTechVulkanBeforeLaunch(
        executable: String,
        prefix: String,
        fileManager: FileManager = .default,
        displayMetrics: DisplayMetrics
    ) -> Report {
        guard let stem = idTechConfigurationStem(
            forExecutable: executable,
            fileManager: fileManager
        ) else { return Report() }

        let usersDirectory = (prefix as NSString).appendingPathComponent("drive_c/users")
        guard let users = try? fileManager.contentsOfDirectory(atPath: usersDirectory) else {
            return Report()
        }
        let eligibleUsers = users.sorted().filter {
            $0.caseInsensitiveCompare("Public") != .orderedSame
                && $0 != "."
                && $0 != ".."
        }
        guard !eligibleUsers.isEmpty else { return Report() }

        func configPath(for user: String) -> String {
            (usersDirectory as NSString).appendingPathComponent(
                "\(user)/Saved Games/id Software/\(stem)/base/\(stem)Config.local"
            )
        }

        let existingPaths = eligibleUsers.map(configPath).filter {
            fileManager.fileExists(atPath: $0)
        }
        let targetPaths: [String]
        if existingPaths.isEmpty {
            let targetUser = eligibleUsers.first(where: {
                $0.caseInsensitiveCompare("crossover") == .orderedSame
            }) ?? eligibleUsers[0]
            targetPaths = [configPath(for: targetUser)]
        } else {
            targetPaths = existingPaths
        }

        var report = Report()
        for path in targetPaths {
            guard PathSafety.isContained(path, in: usersDirectory) else { continue }
            let existed = fileManager.fileExists(atPath: path)
            let original = existed
                ? try? String(contentsOfFile: path, encoding: .utf8)
                : nil
            guard !existed || original != nil,
                  let repaired = repairedIDTechLocalConfig(
                      original,
                      displayMetrics: displayMetrics
                  ) else { continue }

            if existed {
                let backupPath = path + idTechDisplayBackupSuffix
                if !fileManager.fileExists(atPath: backupPath) {
                    do {
                        try fileManager.copyItem(atPath: path, toPath: backupPath)
                        report.backupFiles.append(backupPath)
                    } catch {
                        continue
                    }
                }
            } else {
                do {
                    try fileManager.createDirectory(
                        atPath: (path as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true
                    )
                } catch {
                    continue
                }
            }

            do {
                try Data(repaired.utf8).write(
                    to: URL(fileURLWithPath: path),
                    options: .atomic
                )
                report.repairedFiles.append(path)
            } catch {
                continue
            }
        }
        return report
    }

    private nonisolated static func settingQuotedCVar(
        _ original: String,
        key: String,
        value: String,
        lineEnding: String
    ) -> String {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?mi)^[ \\t]*\(escapedKey)[ \\t]+[^\\r\\n]*"
        if let range = original.range(of: pattern, options: .regularExpression) {
            var result = original
            result.replaceSubrange(range, with: "\(key) \"\(value)\"")
            return result
        }

        var result = original
        if !result.isEmpty, !result.hasSuffix("\n") { result += lineEnding }
        result += "\(key) \"\(value)\"\(lineEnding)"
        return result
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

    private nonisolated static func spaceSeparatedInteger(
        for key: String,
        in text: String
    ) -> Int? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?mi)^[ \\t]*\(escapedKey)[ \\t]+([0-9]+)[ \\t]*\\r?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[valueRange])
    }

    private nonisolated static func replacingSpaceSeparatedInteger(
        in text: String,
        key: String,
        value: Int
    ) -> String {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?mi)^([ \\t]*\(escapedKey)[ \\t]+)[0-9]+([ \\t]*\\r?)$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1\(value)$2"
        )
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
