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
              PathSafety.isContained(officialExecutable, in: installRoot),
              PEImportScanner.hasCLRRuntimeHeader(atPath: officialExecutable) else {
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
}
