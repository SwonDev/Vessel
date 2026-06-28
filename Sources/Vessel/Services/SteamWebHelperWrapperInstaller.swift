import Foundation

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
        case mingwNotInstalled
        case compilationFailed(String)
        case steamCEFDirectoryNotFound
        case installationFailed(String)

        var errorDescription: String? {
            switch self {
            case .mingwNotInstalled: return "mingw-w64 no está instalado. Instálalo con: brew install mingw-w64"
            case .compilationFailed(let msg): return "Compilación del wrapper falló: \(msg)"
            case .steamCEFDirectoryNotFound: return "No se encontró el directorio CEF de Steam en el bottle."
            case .installationFailed(let msg): return "Instalación del wrapper falló: \(msg)"
            }
        }
    }

    /// Umbral para distinguir el wrapper (<500KB) del binario de Valve (>5MB).
    private static let wrapperSizeCeiling: UInt64 = 500_000

    /// Resuelve la ruta al wrapper precompilado bundle en la app.
    /// Busca en Bundle.main/Contents/Resources/steamwebhelper-wrapper.exe
    /// y fallback al path del repo en desarrollo.
    private static var bundledWrapperPath: String {
        if let url = Bundle.main.url(forResource: "steamwebhelper-wrapper", withExtension: "exe") {
            return url.path
        }
        // Fallback para desarrollo: path del repo
        return "/Users/vesseldeveloper0000/Documents/vessel-mac/Resources/steamwebhelper-wrapper.exe"
    }

    /// Ruta al código fuente del wrapper (solo para recompilación si el bundle falta).
    private static let sourcePath = "/Users/vesseldeveloper0000/Documents/vessel-mac/Resources/wrapper/steamwebhelper-wrapper.c"

    /// Ruta donde se cachea el wrapper compilado en runtime.
    private var wrapperBinaryPath: String {
        "\(VesselPaths.cacheDirectory)/steamwebhelper-wrapper/steamwebhelper.exe"
    }

    /// Ruta al compilador mingw-w64 (opcional, solo para recompilación).
    private static let mingwPath = "/opt/homebrew/bin/x86_64-w64-mingw32-gcc"

    // MARK: - Obtención del wrapper

    /// Devuelve la ruta al wrapper, prefiriendo el bundle en Resources.
    /// Si el bundle no existe (app distribuida sin Resources), intenta compilar
    /// con mingw-w64. Si tampoco hay mingw, usa el cache si existe.
    func ensureWrapperCompiled() async throws -> String {
        let fm = FileManager.default

        // 1. Preferir el wrapper bundle en Resources (siempre disponible en el .app)
        let bundled = Self.bundledWrapperPath
        if fm.fileExists(atPath: bundled) {
            return bundled
        }

        // 2. Si no está bundle, intentar el cache
        if fm.fileExists(atPath: wrapperBinaryPath) {
            return wrapperBinaryPath
        }

        // 3. Intentar compilar con mingw-w64 (fallback para desarrollo)
        return try await compileWrapper()
    }

    /// Compila el wrapper con mingw-w64.
    private func compileWrapper() async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.mingwPath) else {
            throw WrapperError.mingwNotInstalled
        }

        guard FileManager.default.fileExists(atPath: Self.sourcePath) else {
            throw WrapperError.compilationFailed("Código fuente del wrapper no encontrado en \(Self.sourcePath)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.mingwPath)
        process.arguments = [
            "-municode", "-O2", "-Wall", "-Wextra",
            "-static", "-lshell32", "-mwindows",
            "-o", wrapperBinaryPath,
            Self.sourcePath
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw WrapperError.compilationFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw WrapperError.compilationFailed(output.isEmpty ? "gcc terminó con código \(process.terminationStatus)" : output)
        }

        guard FileManager.default.fileExists(atPath: wrapperBinaryPath) else {
            throw WrapperError.compilationFailed("El compilador no produjo el binario")
        }

        return wrapperBinaryPath
    }

    // MARK: - Instalación en bottle

    /// Instala el wrapper en todos los dirs `cef.win*` del bottle.
    /// Idempotente: si el wrapper ya está instalado, lo refresca.
    func install(in bottle: Bottle) async throws {
        let wrapperPath = try await ensureWrapperCompiled()
        let cefRoot = "\(bottle.prefixPath)/drive_c/Program Files (x86)/Steam/bin/cef"

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

    /// Comprueba si el wrapper está instalado en el bottle.
    func isInstalled(in bottle: Bottle) -> Bool {
        let cefRoot = "\(bottle.prefixPath)/drive_c/Program Files (x86)/Steam/bin/cef"
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
