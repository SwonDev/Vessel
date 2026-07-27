import Foundation
import CryptoKit

/// Instala y mantiene el wrapper de `steamwebhelper.exe` en un bottle.
///
/// ## Problema
///
/// Steam CEF (Chromium Embedded Framework) en Wine macOS pinta la ventana
/// de negro porque ANGLE no puede inicializar EGL vía DXVK (`CreateDevice1`
/// falla con `DXGI_ERROR_SDK_COMPONENT_MISSING`), y el proceso renderer
/// separado abre su propio swapchain D3D11 que sufre el bug de cross-process
/// de DXMT Issue #141.
///
/// ## Solución
///
/// Un wrapper PE32+ muy pequeño (~150KB) compilado con mingw-w64 que:
/// 1. Resuelve su propio directorio vía `GetModuleFileNameW`
/// 2. Construye `"<dir>\steamwebhelper_real.exe" --disable-gpu --single-process <args>`
/// 3. Lanza el binario real con `CreateProcessW`, espera y devuelve exit code
///
/// `--disable-gpu` fuerza CPU rasterización (Skia), suficiente para la UI 2D de Steam.
/// `--single-process` colapsa renderer/utility/gpu en el browser process, evitando
/// el swapchain cross-process y los errores de winsock TLS del NetworkService.
///
/// ## Instalación
///
/// Por cada `cef.win*` dir bajo `Steam/bin/cef/`:
/// 1. Si `steamwebhelper.exe` es grande (>500KB, es el original de Valve):
///    - Respaldar como `steamwebhelper_real.exe`
/// 2. Copiar el wrapper como `steamwebhelper.exe`
///
/// ## Referencias
///
/// - https://github.com/notpop/steam-on-m1-wine (wrapper original, MIT)
/// - https://github.com/3Shain/dxmt/issues/141 (cross-process swapchain)
@MainActor
@Observable
final class SteamWebHelperWrapperInstaller {
    enum WrapperError: LocalizedError {
        case wrapperBinaryNotFound
        case wrapperIntegrityFailed
        case steamCEFDirectoryNotFound
        case installationFailed(String)

        var errorDescription: String? {
            switch self {
            case .wrapperBinaryNotFound:
                return "La instalación de Vessel no contiene el reparador gráfico verificado de Steam. Reinstala Vessel."
            case .wrapperIntegrityFailed:
                return "El reparador gráfico de Steam no supera la verificación de integridad. Reinstala Vessel."
            case .steamCEFDirectoryNotFound: return "No se encontró el directorio CEF de Steam en el bottle."
            case .installationFailed(let msg): return "Instalación del wrapper falló: \(msg)"
            }
        }
    }

    /// Umbral para distinguir el wrapper (<500KB) del binario de Valve (>5MB).
    private static let wrapperSizeCeiling: UInt64 = 500_000
    /// SHA-256 del PE64 reproducible que distribuye Vessel. Actualizar únicamente al recompilar
    /// `Resources/wrapper/steamwebhelper-wrapper.c` y validar de nuevo Steam CEF.
    private nonisolated static let expectedWrapperSHA256 = "dcb623bd8db4ffdffffc0e1686bdfb3f9595ddaa2474f0d62d1c451957026bf5"

    /// Resuelve el wrapper precompilado únicamente dentro del bundle en ejecución. No se permite
    /// caer al checkout del repositorio: eso podría ocultar un paquete distribuido incompleto en el
    /// Mac de desarrollo y fallar después en un equipo limpio.
    private static var bundledWrapperPath: String? {
        Bundle.main.url(forResource: "steamwebhelper-wrapper", withExtension: "exe")?.path
    }

    // MARK: - Obtención del wrapper

    /// Devuelve exclusivamente el wrapper verificado que distribuye Vessel. Una app de producción
    /// nunca compila ejecutables descargables en el Mac del usuario ni depende de Homebrew.
    func ensureWrapperCompiled() async throws -> String {
        guard let bundled = Self.bundledWrapperPath,
              FileManager.default.fileExists(atPath: bundled) else {
            throw WrapperError.wrapperBinaryNotFound
        }
        guard Self.isTrustedWrapper(atPath: bundled) else {
            throw WrapperError.wrapperIntegrityFailed
        }
        return bundled
    }

    nonisolated static func isTrustedWrapper(atPath path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == expectedWrapperSHA256
    }

    // MARK: - Instalación en bottle

    /// Instala el wrapper en todos los dirs `cef.win*` del bottle.
    /// Idempotente: si el wrapper ya está instalado, lo refresca.
    func install(in bottle: Bottle) async throws {
        let wrapperPath = try await ensureWrapperCompiled()
        let cefRoot = "\(bottle.steamDirectory)/bin/cef"

        guard FileManager.default.fileExists(atPath: cefRoot) else {
            throw WrapperError.steamCEFDirectoryNotFound
        }

        let fm = FileManager.default
        let cefDirs = (try? fm.contentsOfDirectory(atPath: cefRoot)) ?? []
        let winDirs = cefDirs.filter { $0.hasPrefix("cef.win") }

        guard !winDirs.isEmpty else {
            throw WrapperError.steamCEFDirectoryNotFound
        }

        var installed = 0
        for dir in winDirs {
            let cefDir = "\(cefRoot)/\(dir)"
            let target = "\(cefDir)/steamwebhelper.exe"
            let real = "\(cefDir)/steamwebhelper_real.exe"

            guard fm.fileExists(atPath: target) else { continue }

            let targetSize = (try? fm.attributesOfItem(atPath: target)[.size] as? UInt64) ?? 0

            if targetSize >= Self.wrapperSizeCeiling {
                // target es el binario de Valve (grande). Respaldar como real.
                if !fm.fileExists(atPath: real) || isWrapperSize(atPath: real) {
                    try? fm.removeItem(atPath: real)
                    try fm.copyItem(atPath: target, toPath: real)
                } else {
                    // real ya existe y es de Valve. Si target difiere (Steam actualizó), refrescar real.
                    let realSize = (try? fm.attributesOfItem(atPath: real)[.size] as? UInt64) ?? 0
                    if realSize < Self.wrapperSizeCeiling {
                        try? fm.removeItem(atPath: real)
                        try fm.copyItem(atPath: target, toPath: real)
                    }
                }
            } else {
                // target es un wrapper previo. Si no hay real, error.
                if !fm.fileExists(atPath: real) {
                    continue
                }
            }

            // Instalar wrapper como target.
            try? fm.removeItem(atPath: target)
            try fm.copyItem(atPath: wrapperPath, toPath: target)
            installed += 1
        }

        guard installed > 0 else {
            throw WrapperError.installationFailed("No se instaló el wrapper en ningún dir CEF")
        }
    }

    /// Restaura los `steamwebhelper.exe` ORIGINALES de Valve (deshace el wrapper) en
    /// todos los dirs CEF del bottle. Necesario antes de dejar que Steam verifique o
    /// actualice sus ficheros: con el wrapper puesto, la verificación lo detecta como
    /// "corrupto". Idempotente; conserva el respaldo `steamwebhelper_real.exe`.
    func restoreRealWebHelpers(in bottle: Bottle) {
        let fm = FileManager.default
        let cefRoot = "\(bottle.steamDirectory)/bin/cef"
        guard let cefDirs = try? fm.contentsOfDirectory(atPath: cefRoot) else { return }
        for dir in cefDirs where dir.hasPrefix("cef.win") {
            let target = "\(cefRoot)/\(dir)/steamwebhelper.exe"
            let real = "\(cefRoot)/\(dir)/steamwebhelper_real.exe"
            guard isWrapperSize(atPath: target),
                  fm.fileExists(atPath: real), !isWrapperSize(atPath: real) else { continue }
            try? fm.removeItem(atPath: target)
            try? fm.copyItem(atPath: real, toPath: target)
        }
    }

    /// Comprueba si el wrapper está instalado en el bottle.
    func isInstalled(in bottle: Bottle) -> Bool {
        let cefRoot = "\(bottle.steamDirectory)/bin/cef"
        guard let cefDirs = try? FileManager.default.contentsOfDirectory(atPath: cefRoot) else {
            return false
        }
        for dir in cefDirs where dir.hasPrefix("cef.win") {
            let target = "\(cefRoot)/\(dir)/steamwebhelper.exe"
            let real = "\(cefRoot)/\(dir)/steamwebhelper_real.exe"
            // Wrapper instalado = target es pequeño Y real existe.
            if isWrapperSize(atPath: target), FileManager.default.fileExists(atPath: real) {
                return true
            }
        }
        return false
    }

    private func isWrapperSize(atPath path: String) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64 else {
            return false
        }
        return size < Self.wrapperSizeCeiling
    }
}
