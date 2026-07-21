import Foundation

/// Compatibilidad automática para juegos modernos de Adventure Game Studio basados en SDL2.
///
/// AGS 3.6 todavía distribuye D3D9 como backend predeterminado en algunos paquetes. Bajo el motor
/// completo de Vessel esa ruta funciona, pero mantiene el bucle de presentación de wined3d activo y
/// consume varias veces más CPU que el renderer OpenGL incluido por el propio AGS. La detección es
/// estructural y exige simultáneamente el PE de AGS, SDL2, sus datos y `acsetup.cfg`; no depende del
/// título, la tienda ni el AppID.
enum AdventureGameStudioCompatibility {
    struct Report: Equatable {
        var detected = false
        var repairedFiles: [String] = []
        var backupFiles: [String] = []

        var didRepair: Bool { !repairedFiles.isEmpty }
    }

    private static let requiredMarkers: Set<String> = [
        "Adventure Game Studio run-time engine",
        "Adventure Game Studio v%s Interpreter",
        "--gfxdriver"
    ]
    private static let backupSuffix = ".vessel-ags-d3d9-backup"

    @discardableResult
    nonisolated static func repairBeforeLaunch(
        executable: String,
        fileManager: FileManager = .default
    ) -> Report {
        let directory = (executable as NSString).deletingLastPathComponent
        guard let children = try? fileManager.contentsOfDirectory(atPath: directory),
              let configName = children.first(where: {
                  $0.caseInsensitiveCompare("acsetup.cfg") == .orderedSame
              }) else {
            return Report()
        }

        let lowercasedChildren = Set(children.map { $0.lowercased() })
        let imports = PEImportScanner.importedLibraries(atPath: executable)
        let markers = engineMarkers(in: executable)
        guard isModernAGSSDL2(
            imports: imports,
            markers: markers,
            hasConfig: true,
            hasGameData: children.contains(where: {
                ($0 as NSString).pathExtension.caseInsensitiveCompare("ags") == .orderedSame
            }),
            hasSDL2Runtime: lowercasedChildren.contains("sdl2.dll")
        ) else {
            return Report()
        }

        let configPath = "\(directory)/\(configName)"
        // El paquete solo puede autorreparar su fichero directo; nunca sigue un enlace que saque la
        // escritura fuera de la instalación del juego.
        guard (try? fileManager.destinationOfSymbolicLink(atPath: configPath)) == nil else {
            return Report()
        }
        return repairConfig(
            at: configPath,
            fileManager: fileManager
        )
    }

    /// Aplica la reparación una vez confirmada la firma del motor. Se mantiene separada para probar
    /// el backup y la escritura atómica sin fabricar un PE falso en la suite unitaria.
    nonisolated static func repairConfig(
        at configPath: String,
        fileManager: FileManager = .default
    ) -> Report {
        var report = Report(detected: true)
        guard let originalData = fileManager.contents(atPath: configPath),
              let original = String(data: originalData, encoding: .isoLatin1),
              let repaired = repairedGraphicsConfig(original),
              let repairedData = repaired.data(using: .isoLatin1) else {
            return report
        }

        let backupPath = configPath + backupSuffix
        if !fileManager.fileExists(atPath: backupPath) {
            do {
                try fileManager.copyItem(atPath: configPath, toPath: backupPath)
                report.backupFiles.append(backupPath)
            } catch {
                // Sin una copia recuperable no se modifica la configuración distribuida.
                return report
            }
        }

        do {
            try repairedData.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            report.repairedFiles.append(configPath)
        } catch {
            return report
        }
        return report
    }

    /// Evidencia mínima para el perfil probado de AGS 3.6/SDL2. Mantenerla en una función pura hace
    /// comprobable que una DLL, un `.ags` o una cadena aislados jamás activen la reparación.
    nonisolated static func isModernAGSSDL2(
        imports: Set<String>,
        markers: Set<String>,
        hasConfig: Bool,
        hasGameData: Bool,
        hasSDL2Runtime: Bool
    ) -> Bool {
        let normalizedImports = Set(imports.map { $0.lowercased() })
        return normalizedImports.contains("sdl2.dll")
            && requiredMarkers.isSubset(of: markers)
            && hasConfig
            && hasGameData
            && hasSDL2Runtime
    }

    /// Cambia únicamente `driver=D3D9` dentro de `[graphics]`. Respeta CRLF, comentarios, VSync,
    /// escala, modo de ventana, traducción y cualquier valor elegido por el usuario.
    nonisolated static func repairedGraphicsConfig(_ original: String) -> String? {
        guard !original.isEmpty else { return nil }
        // Las herramientas de Windows, Wine y algunos launchers pueden dejar CRLF, LF y CR
        // mezclados en el mismo fichero. Tokenizar cada terminador conserva los bytes y evita que
        // una línea reparable quede pegada a la anterior por asumir un único delimitador global.
        var records: [(content: String, terminator: String)] = []
        var cursor = original.startIndex
        while cursor < original.endIndex {
            if let newline = original.range(
                of: #"\r\n|\n|\r"#,
                options: .regularExpression,
                range: cursor..<original.endIndex
            ) {
                records.append((
                    String(original[cursor..<newline.lowerBound]),
                    String(original[newline])
                ))
                cursor = newline.upperBound
            } else {
                records.append((String(original[cursor...]), ""))
                cursor = original.endIndex
            }
        }

        var inGraphicsSection = false
        var changed = false

        let repairedRecords = records.map { record -> (content: String, terminator: String) in
            let sourceLine = record.content
            let trimmed = sourceLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                inGraphicsSection = trimmed.caseInsensitiveCompare("[graphics]") == .orderedSame
                return record
            }
            guard inGraphicsSection,
                  let equals = sourceLine.firstIndex(of: "=") else {
                return record
            }

            let key = sourceLine[..<equals].trimmingCharacters(in: .whitespaces)
            guard key.caseInsensitiveCompare("driver") == .orderedSame else {
                return record
            }

            let afterEquals = sourceLine.index(after: equals)
            let valueSlice = sourceLine[afterEquals...]
            guard let valueStart = valueSlice.firstIndex(where: { $0 != " " && $0 != "\t" }),
                  let valueEnd = valueSlice.lastIndex(where: { $0 != " " && $0 != "\t" }) else {
                return record
            }
            let value = sourceLine[valueStart...valueEnd]
            guard value.caseInsensitiveCompare("D3D9") == .orderedSame else {
                return record
            }

            var repairedLine = sourceLine
            repairedLine.replaceSubrange(valueStart...valueEnd, with: "OGL")
            changed = true
            return (repairedLine, record.terminator)
        }

        guard changed else { return nil }
        return repairedRecords.map { $0.content + $0.terminator }.joined()
    }

    private nonisolated static func engineMarkers(in executable: String) -> Set<String> {
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: executable),
            options: .mappedIfSafe
        ) else { return [] }

        return Set(requiredMarkers.filter { marker in
            data.range(of: Data(marker.utf8)) != nil
        })
    }
}
