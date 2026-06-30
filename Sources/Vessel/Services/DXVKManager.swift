import Foundation

/// Gestiona la instalación y registro de DXVK en un bottle.
///
/// DXVK traduce Direct3D 9/10/11 a Vulkan. En macOS, el motor wine-osx64
/// de Gcenx ya incluye `libMoltenVK.dylib` (Vulkan → Metal), por lo que
/// DXVK permite que Steam y juegos DirectX 11 rendericen con aceleración
/// GPU en Apple Silicon.
///
/// Sin DXVK, Steam CEF detecta un DXGI Adapter inválido y deshabilita
/// el compositing de GPU, lo que produce una ventana negra.
///
/// **Importante**: usamos DXVK 1.10.3 (pinned) porque el motor wine-osx64
/// de Gcenx incluye MoltenVK 0.2.2209 que **no soporta `geometryShader`**,
/// feature que DXVK 2.x+ exige (Vulkan 1.3). DXVK 1.10.3 solo requiere
/// Vulkan 1.1 y funciona perfectamente con este MoltenVK.
@MainActor
@Observable
final class DXVKManager {
    enum DXVKError: LocalizedError {
        case downloadFailed(String)
        case extractionFailed(String)
        case invalidArchive
        case wineUnavailable

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let msg): return "Descarga de DXVK falló: \(msg)"
            case .extractionFailed(let msg): return "Extracción de DXVK falló: \(msg)"
            case .invalidArchive: return "El archivo de DXVK no contiene las DLLs esperadas."
            case .wineUnavailable: return "No se encontró el binario de Wine para registrar las DLLs."
            }
        }
    }

    /// Versión pinneada de DXVK. No usar `latest` porque DXVK 2.x+ exige
    /// Vulkan 1.3 + `geometryShader`, features que el MoltenVK 0.2.2209
    /// incluido con el motor wine-osx64 de Gcenx no soporta. DXVK 1.10.3
    /// es el último 1.x, requiere solo Vulkan 1.1 y funciona con MoltenVK viejo.
    static let pinnedVersion = "1.10.3"
    static let pinnedDownloadURL = URL(string: "https://github.com/doitsujin/dxvk/releases/download/v1.10.3/dxvk-1.10.3.tar.gz")!
    static let pinnedAssetName = "dxvk-1.10.3.tar.gz"

    private let cacheDirectory: String

    init(cacheDirectory: String = VesselPaths.cacheDirectory) {
        self.cacheDirectory = "\(cacheDirectory)/dxvk"
        try? FileManager.default.createDirectory(
            atPath: self.cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Devuelve la ruta al archivo DXVK cacheado, o nil si no existe.
    func cachedArchivePath() -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: cacheDirectory) else { return nil }
        // Preferir la versión pinneada si está cacheada.
        if let pinned = files.first(where: { $0 == Self.pinnedAssetName }) {
            return "\(cacheDirectory)/\(pinned)"
        }
        return files
            .filter { $0.hasSuffix(".tar.gz") || $0.hasSuffix(".tar.xz") }
            .sorted()
            .last
            .map { "\(cacheDirectory)/\($0)" }
    }

    /// Comprueba si DXVK está instalado en el bottle buscando las DLLs nativas
    /// de DXVK 1.10.3 (x64). Verificamos `dxgi.dll` y `d3d11.dll` que son
    /// las más críticas para Steam CEF.
    func isInstalled(in bottle: Bottle) -> Bool {
        let system32 = "\(bottle.prefixPath)/drive_c/windows/system32"
        let required: [String] = ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "d3d9.dll"]
        let fm = FileManager.default

        for dll in required {
            let path = "\(system32)/\(dll)"
            guard fm.fileExists(atPath: path),
                  let size = try? fm.attributesOfItem(atPath: path)[.size] as? UInt64,
                  size > 1_000_000
            else {
                return false
            }
        }
        return true
    }

    /// Descarga DXVK (versión pinneada), lo extrae al cache,
    /// copia las DLLs x64 a system32 y x32 a syswow64 del bottle, y registra
    /// los overrides de DLL en `user.reg` vía `wine reg add`.
    func install(in bottle: Bottle, progress: @escaping @Sendable (String, Double) -> Void = { _, _ in }) async throws {
        try FileManager.default.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)

        let archivePath: String
        if let cached = cachedArchivePath() {
            progress("DXVK \(Self.pinnedVersion) cacheado detectado", 0.2)
            archivePath = cached
        } else {
            archivePath = try await downloadPinnedRelease(progress: progress)
        }

        let extractedRoot = try await extractArchive(at: archivePath, progress: progress)
        progress("Instalando DXVK en el bottle…", 0.75)
        try copyDLLs(from: extractedRoot, to: bottle)
        progress("Registrando overrides de DLL…", 0.85)
        try await registerDllOverrides(in: bottle)
        progress("✓ DXVK \(Self.pinnedVersion) instalado", 1.0)
    }

    // MARK: - Descarga

    private func downloadPinnedRelease(progress: @escaping @Sendable (String, Double) -> Void) async throws -> String {
        progress("Descargando DXVK \(Self.pinnedVersion)…", 0.2)
        let (tempURL, response) = try await URLSession.shared.download(from: Self.pinnedDownloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DXVKError.downloadFailed("HTTP \(http.statusCode) descargando \(Self.pinnedAssetName)")
        }

        let finalPath = "\(cacheDirectory)/\(Self.pinnedAssetName)"
        try? FileManager.default.removeItem(atPath: finalPath)
        try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: finalPath))
        return finalPath
    }

    // MARK: - Extracción

    /// Extrae el tarball a `<cache>/<basename>-extracted-<uuid>/` y devuelve la ruta
    /// al directorio interno que contiene `x32/` y `x64/`.
    private func extractArchive(at archivePath: String, progress: @escaping @Sendable (String, Double) -> Void) async throws -> String {
        let fm = FileManager.default
        let extractRoot = "\(cacheDirectory)/extracted-\(UUID().uuidString)"
        try? fm.removeItem(atPath: extractRoot)
        try fm.createDirectory(atPath: extractRoot, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xf", archivePath, "-C", extractRoot]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        progress("Extrayendo DXVK…", 0.5)
        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw DXVKError.extractionFailed(output.isEmpty ? "tar terminó con código \(task.terminationStatus)" : output)
        }

        // DXVK extrae como `dxvk-<ver>/x32` y `dxvk-<ver>/x64`. Localizar.
        guard let contents = try? fm.contentsOfDirectory(atPath: extractRoot) else {
            throw DXVKError.extractionFailed("No se pudo listar el contenido extraído.")
        }

        let candidates = contents.map { "\(extractRoot)/\($0)" }
        for candidate in candidates {
            let x32 = "\(candidate)/x32"
            let x64 = "\(candidate)/x64"
            if fm.fileExists(atPath: x32) && fm.fileExists(atPath: x64) {
                return candidate
            }
        }

        // Algunas releases no tienen subdirectorio; las DLLs están sueltas.
        let directX32 = "\(extractRoot)/x32"
        let directX64 = "\(extractRoot)/x64"
        if fm.fileExists(atPath: directX32) && fm.fileExists(atPath: directX64) {
            return extractRoot
        }

        throw DXVKError.invalidArchive
    }

    // MARK: - Copia de DLLs

    /// DLLs que trae DXVK 1.10.3 (DX9/DX10/DX11; sin DX12 porque DXVK 1.x no lo soporta).
    private static let x64DLLs = [
        "d3d8.dll",
        "d3d9.dll",
        "d3d10.dll",
        "d3d10_1.dll",
        "d3d10core.dll",
        "d3d11.dll",
        "dxgi.dll",
    ]

    private static let x32DLLs = [
        "d3d8.dll",
        "d3d9.dll",
        "d3d10.dll",
        "d3d10_1.dll",
        "d3d10core.dll",
        "d3d11.dll",
        "dxgi.dll",
    ]

    private func copyDLLs(from extractedRoot: String, to bottle: Bottle) throws {
        let fm = FileManager.default
        let x64Src = "\(extractedRoot)/x64"
        let x32Src = "\(extractedRoot)/x32"
        let system32 = "\(bottle.prefixPath)/drive_c/windows/system32"
        let syswow64 = "\(bottle.prefixPath)/drive_c/windows/syswow64"

        try fm.createDirectory(atPath: system32, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: syswow64, withIntermediateDirectories: true)

        for dll in Self.x64DLLs {
            let src = "\(x64Src)/\(dll)"
            let dst = "\(system32)/\(dll)"
            guard fm.fileExists(atPath: src) else { continue }
            try? fm.removeItem(atPath: dst)
            try fm.copyItem(atPath: src, toPath: dst)
        }

        for dll in Self.x32DLLs {
            let src = "\(x32Src)/\(dll)"
            let dst = "\(syswow64)/\(dll)"
            guard fm.fileExists(atPath: src) else { continue }
            try? fm.removeItem(atPath: dst)
            try fm.copyItem(atPath: src, toPath: dst)
        }
    }

    // MARK: - Registro de overrides en user.reg

    /// Registra las DLLs DXVK como `native` en el registro Wine del prefix.
    /// Esto es complementario al `WINEDLLOVERRIDES` del entorno: lo persiste
    /// para que futuros launches sin env var también usen DXVK.
    private func registerDllOverrides(in bottle: Bottle) async throws {
        let wineBin: String
        if let portable = WineEngineLocator.findPortableWineBinary(enginesDirectory: VesselPaths.enginesDirectory),
           FileManager.default.isExecutableFile(atPath: portable) {
            wineBin = portable
        } else if FileManager.default.isExecutableFile(atPath: bottle.winePath) {
            wineBin = bottle.winePath
        } else {
            throw DXVKError.wineUnavailable
        }
        try await runRegAdd(winePath: wineBin, prefix: bottle.prefixPath)
    }

    private func runRegAdd(winePath: String, prefix: String) async throws {
        // DXVK 1.10.3 NO trae DLLs de D3D12: registrar d3d12/d3d12core como native,builtin
        // dejaba un override muerto en user.reg que luego interfería con el d3d12 builtin de
        // GPTK/D3DMetal (prioridad `native` busca en el prefijo, donde no hay nada → fallo).
        let dlls = ["d3d8", "d3d9", "d3d10", "d3d10_1", "d3d10core", "d3d11", "dxgi"]
        for dll in dlls {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: winePath)
            process.arguments = [
                "reg", "add",
                #"HKCU\Software\Wine\DllOverrides"#,
                "/v", dll,
                "/t", "REG_SZ",
                "/d", "native,builtin",
                "/f"
            ]
            process.environment = [
                "WINEPREFIX": prefix,
                "WINEDEBUG": "-all",
                "WINEDLLOVERRIDES": "winedbg.exe=d"
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // No abortar: el override vía env var ya cubre el lanzamiento.
            }
        }
    }
}
