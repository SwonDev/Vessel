import Foundation

/// Resuelve el ejecutable alternativo elegido por el usuario sin permitir que un ajuste guardado
/// escape de la carpeta del juego. El valor inválido nunca bloquea el arranque: se vuelve al
/// ejecutable detectado automáticamente.
enum GameExecutableOverride {
    enum ValidationError: LocalizedError, Equatable {
        case missingInstallRoot
        case outsideInstallRoot
        case notExecutable
        case missingFile

        var errorDescription: String? {
            switch self {
            case .missingInstallRoot:
                return "No se conoce la carpeta de instalación del juego."
            case .outsideInstallRoot:
                return "El ejecutable debe estar dentro de la carpeta del juego."
            case .notExecutable:
                return "Selecciona un archivo de Windows con extensión .exe."
            case .missingFile:
                return "El ejecutable seleccionado ya no existe."
            }
        }
    }

    static func validate(
        _ path: String,
        installRoot: String?,
        fileManager: FileManager = .default
    ) -> Result<String, ValidationError> {
        guard let installRoot, !installRoot.isEmpty else { return .failure(.missingInstallRoot) }
        guard (path as NSString).pathExtension.caseInsensitiveCompare("exe") == .orderedSame else {
            return .failure(.notExecutable)
        }
        guard PathSafety.isStrictDescendant(path, of: installRoot) else {
            return .failure(.outsideInstallRoot)
        }
        let canonical = PathSafety.canonical(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonical, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .failure(.missingFile)
        }
        return .success(canonical)
    }

    static func resolve(
        configuredPath: String?,
        installRoot: String?,
        fallback: String,
        fileManager: FileManager = .default
    ) -> String {
        let automatic = AutomaticGameExecutableResolver.resolve(
            officialExecutable: fallback,
            installRoot: installRoot,
            fileManager: fileManager
        )
        guard let configuredPath, !configuredPath.isEmpty else { return automatic }
        guard case .success(let executable) = validate(
            configuredPath,
            installRoot: installRoot,
            fileManager: fileManager
        ) else { return automatic }
        return executable
    }
}

/// Convierte launchers oficiales en el payload gráfico real cuando el propio árbol de instalación
/// demuestra inequívocamente la relación. No usa títulos, IDs de tienda ni argumentos persistidos.
enum AutomaticGameExecutableResolver {
    static func resolve(
        officialExecutable: String,
        installRoot: String?,
        fileManager: FileManager = .default
    ) -> String {
        guard let installRoot, !installRoot.isEmpty,
              PathSafety.isContained(officialExecutable, in: installRoot) else {
            return officialExecutable
        }

        if let payload = managedDualRendererPayload(
            forAppHost: officialExecutable,
            installRoot: installRoot,
            fileManager: fileManager
        ) {
            return payload
        }

        guard PEImportScanner.hasCLRRuntimeHeader(atPath: officialExecutable) else {
            return officialExecutable
        }

        let directory = (officialExecutable as NSString).deletingLastPathComponent
        let officialName = (officialExecutable as NSString).lastPathComponent
        let stem = (officialName as NSString).deletingPathExtension
        guard !directory.isEmpty, !stem.isEmpty,
              let names = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return officialExecutable
        }

        let localFiles = Dictionary(
            names.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        func sibling(suffix: String) -> String? {
            let expected = "\(stem)\(suffix).exe".lowercased()
            guard let actual = localFiles[expected] else { return nil }
            let path = (directory as NSString).appendingPathComponent(actual)
            guard PathSafety.isContained(path, in: installRoot),
                  fileManager.fileExists(atPath: path) else { return nil }
            return PathSafety.canonical(path)
        }

        // Exigimos la pareja completa y que cada payload llegue a su API mediante dependencias
        // locales enlazadas de verdad. Un nombre `_DX12` aislado nunca puede secuestrar el arranque.
        guard let dx11 = sibling(suffix: "_DX11"),
              let dx12 = sibling(suffix: "_DX12"),
              PEImportScanner.importedLibrariesFromDirectSiblingDependencies(atPath: dx11)
                .contains("d3d11.dll"),
              PEImportScanner.importedLibrariesFromDirectSiblingDependencies(atPath: dx12)
                .contains("d3d12.dll") else {
            return officialExecutable
        }

        // Vessel incluye D3DMetal como ruta nativa D3D12→Metal. Elegir el payload moderno evita el
        // selector .NET y permite que WineManager prepare desde el principio el motor correcto.
        return dx12
    }

    /// Resuelve un launcher .NET `apphost` que ofrece dos renderers nativos en `bin/`.
    ///
    /// El contrato está deliberadamente cerrado y no depende del juego ni de su tienda:
    /// - el ejecutable oficial vive en un directorio `Launcher` directo del juego;
    /// - es un apphost PE64 nativo que contiene `hostfxr_main` y referencia exactamente su DLL
    ///   homónima, mientras esa DLL es CLR y declara las opciones `UseDX11`/`UseVulkan`;
    /// - `bin/` contiene exactamente un PE64 D3D11 (import real) y exactamente un PE64 Vulkan
    ///   (cargador y entrypoints reales), sin candidatos ambiguos.
    ///
    /// En macOS se elige D3D11: Vessel lo traduce directamente a Metal mediante DXMT y evita tanto
    /// el launcher .NET como una ruta Vulkan menos estable. Un árbol incompleto o ambiguo conserva
    /// siempre el ejecutable oficial.
    private static func managedDualRendererPayload(
        forAppHost appHost: String,
        installRoot: String,
        fileManager: FileManager
    ) -> String? {
        guard PEImportScanner.is64BitImage(atPath: appHost),
              !PEImportScanner.hasCLRRuntimeHeader(atPath: appHost) else { return nil }

        let root = PathSafety.canonical(installRoot)
        let launcherDirectory = (PathSafety.canonical(appHost) as NSString)
            .deletingLastPathComponent
        guard (launcherDirectory as NSString).deletingLastPathComponent == root,
              (launcherDirectory as NSString).lastPathComponent
                .caseInsensitiveCompare("Launcher") == .orderedSame,
              let launcherEntries = try? fileManager.contentsOfDirectory(
                  atPath: launcherDirectory
              ) else { return nil }

        let appHostName = (appHost as NSString).lastPathComponent
        let appHostStem = (appHostName as NSString).deletingPathExtension
        guard !appHostStem.isEmpty,
              appHostStem.lowercased().contains("launcher"),
              let managedName = launcherEntries.first(where: {
                  $0.caseInsensitiveCompare("\(appHostStem).dll") == .orderedSame
              }) else { return nil }

        let managedAssembly = (launcherDirectory as NSString)
            .appendingPathComponent(managedName)
        guard PathSafety.isContained(managedAssembly, in: root),
              PEImportScanner.hasCLRRuntimeHeader(atPath: managedAssembly),
              PEImportScanner.containsASCIIStrings(
                  atPath: appHost,
                  allOf: [managedName, "hostfxr_main"]
              ),
              PEImportScanner.containsASCIIStrings(
                  atPath: managedAssembly,
                  allOf: ["UseDX11", "UseVulkan"]
              ),
              let rootEntries = try? fileManager.contentsOfDirectory(atPath: root),
              let binName = rootEntries.first(where: {
                  $0.caseInsensitiveCompare("bin") == .orderedSame
              }) else { return nil }

        let binDirectory = (root as NSString).appendingPathComponent(binName)
        var isDirectory: ObjCBool = false
        guard PathSafety.isContained(binDirectory, in: root),
              fileManager.fileExists(atPath: binDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let binEntries = try? fileManager.contentsOfDirectory(atPath: binDirectory)
        else { return nil }

        let executables = binEntries.compactMap { name -> String? in
            guard (name as NSString).pathExtension.caseInsensitiveCompare("exe") == .orderedSame
            else { return nil }
            let path = (binDirectory as NSString).appendingPathComponent(name)
            var candidateIsDirectory: ObjCBool = false
            guard PathSafety.isContained(path, in: binDirectory),
                  fileManager.fileExists(atPath: path, isDirectory: &candidateIsDirectory),
                  !candidateIsDirectory.boolValue,
                  PEImportScanner.is64BitImage(atPath: path) else { return nil }
            return PathSafety.canonical(path)
        }

        let dx11 = executables.filter { executable in
            let imports = PEImportScanner.importedLibraries(atPath: executable)
            return imports.contains("d3d11.dll")
                && !PEImportScanner.containsASCIIStrings(
                    atPath: executable,
                    allOf: ["vulkan-1.dll", "vkGetInstanceProcAddr", "vkCreateInstance"]
                )
        }
        let vulkan = executables.filter { executable in
            let imports = PEImportScanner.importedLibraries(atPath: executable)
            return !imports.contains("d3d11.dll")
                && PEImportScanner.containsASCIIStrings(
                    atPath: executable,
                    allOf: ["vulkan-1.dll", "vkGetInstanceProcAddr", "vkCreateInstance"]
                )
        }
        guard dx11.count == 1, vulkan.count == 1, dx11[0] != vulkan[0] else { return nil }
        return dx11[0]
    }
}
