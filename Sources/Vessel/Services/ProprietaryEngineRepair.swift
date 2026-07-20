import Foundation

/// Reparaciones de configuración para motores propietarios sin una familia pública reutilizable.
/// Cada regla exige una firma estrecha de binario + AppID + esquema de configuración para no afectar
/// a otro juego que comparta una DLL o un nombre de fichero genérico.
enum ProprietaryEngineRepair {
    struct Report: Equatable {
        var repairedFiles: [String] = []
        var backupFiles: [String] = []
        var didRepair: Bool { !repairedFiles.isEmpty }
    }

    private static let cubeWorldAppID = "1128000"
    private static let cubeWorldRequiredImports: Set<String> = [
        "steam_api64.dll", "xaudio2_8.dll", "d3d11.dll", "dinput8.dll",
        "xinput1_4.dll", "glu32.dll", "freeimage.dll"
    ]
    private static let backupSuffix = ".vessel-msaa-backup"

    @discardableResult
    nonisolated static func repairBeforeLaunch(
        appId: String?,
        executable: String,
        fileManager: FileManager = .default
    ) -> Report {
        let optionsPath = "\((executable as NSString).deletingLastPathComponent)/options.cfg"
        let imports = PEImportScanner.importedLibraries(atPath: executable)
        guard isCubeWorldEngine(
            appId: appId,
            executableName: (executable as NSString).lastPathComponent,
            imports: imports,
            hasOptions: fileManager.fileExists(atPath: optionsPath)
        ), let original = try? String(contentsOfFile: optionsPath, encoding: .utf8),
           let repaired = repairedCubeWorldOptions(original) else {
            return Report()
        }

        let backupPath = optionsPath + backupSuffix
        var report = Report()
        if !fileManager.fileExists(atPath: backupPath) {
            do {
                try fileManager.copyItem(atPath: optionsPath, toPath: backupPath)
                report.backupFiles.append(backupPath)
            } catch {
                return Report()
            }
        }
        do {
            try Data(repaired.utf8).write(to: URL(fileURLWithPath: optionsPath), options: .atomic)
            report.repairedFiles.append(optionsPath)
        } catch {
            return Report()
        }
        return report
    }

    nonisolated static func isCubeWorldEngine(
        appId: String?, executableName: String, imports: Set<String>, hasOptions: Bool
    ) -> Bool {
        appId == cubeWorldAppID
            && executableName.caseInsensitiveCompare("cubeworld.exe") == .orderedSame
            && cubeWorldRequiredImports.isSubset(of: Set(imports.map { $0.lowercased() }))
            && hasOptions
    }

    /// El motor Plasma propio de Cube World consulta `CheckMultisampleQualityLevels` incluso cuando
    /// el antialiasing principal figura desactivado. Su valor histórico de 8 muestras devuelve
    /// `E_INVALIDARG` bajo la traducción D3D11→Metal y aborta antes de crear la ventana. Una muestra
    /// equivale a “sin MSAA” y conserva el resto de preferencias literalmente.
    nonisolated static func repairedCubeWorldOptions(_ original: String) -> String? {
        var foundSamples = false
        var changed = false
        // En Swift, CRLF es un único `Character`; `split(separator: "\n")` no lo separa y convierte
        // todo el fichero de Windows en una sola línea. Detectar y conservar el delimitador exacto.
        let newline = original.contains("\r\n") ? "\r\n" : original.contains("\n") ? "\n" : "\r"
        let keptTrailingNewline = original.hasSuffix(newline)
        let lines = original.components(separatedBy: newline).map { line -> String in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { return line }
            if parts[0].caseInsensitiveCompare("antiAliasingSamples") == .orderedSame,
               let samples = Int(parts[1]) {
                foundSamples = true
                if samples > 1 {
                    changed = true
                    return "antiAliasingSamples 1"
                }
            }
            return line
        }
        guard foundSamples, changed else { return nil }
        var result = lines.joined(separator: newline)
        if keptTrailingNewline, !result.hasSuffix(newline) { result += newline }
        return result
    }
}
