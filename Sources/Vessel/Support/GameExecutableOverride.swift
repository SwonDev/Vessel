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
        guard let configuredPath, !configuredPath.isEmpty else { return fallback }
        guard case .success(let executable) = validate(
            configuredPath,
            installRoot: installRoot,
            fileManager: fileManager
        ) else { return fallback }
        return executable
    }
}
