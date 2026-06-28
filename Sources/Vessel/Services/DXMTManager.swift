import Foundation

/// Gestiona la instalación y registro de DXMT (D3D11 → Metal nativo) en un bottle.
///
/// ## Por qué DXMT en vez de (o además de) DXVK
///
/// DXVK traduce D3D9/10/11 → Vulkan, y requiere MoltenVK para ejecutar Vulkan en macOS.
/// Desafortunadamente, MoltenVK 0.2.2209 (incluido con el motor wine-osx64 de Gcenx)
/// **no soporta `geometryShader`**, un feature que D3D11 feature level 11_0 exige.
/// Esto hace que juegos Unity D3D11 fallen con `InitializeEngineGraphics failed`.
///
/// DXMT traduce D3D10/D3D11/DXGI directamente a Metal, sin pasar por Vulkan.
/// En Apple Silicon, DXMT es la capa correcta para D3D11 porque usa Metal nativo.
///
/// ## Estrategia
///
/// - **D3D11/D3D10/DXGI**: DXMT (Metal nativo) — para juegos D3D11
/// - **D3D9/D3D8**: DXVK 1.10.3 (Vulkan → MoltenVK) — para juegos legacy
/// - **CEF Steam UI**: wrapper `--disable-gpu --single-process` (software rendering)
///
/// DXMT y DXVK coexisten: DXMT reemplaza `d3d11.dll`, `dxgi.dll`, `d3d10core.dll`,
/// `d3d10.dll`, `d3d10_1.dll`, `winemetal.dll`; DXVK mantiene `d3d8.dll`, `d3d9.dll`.
@MainActor
@Observable
final class DXMTManager {
    enum DXMTError: LocalizedError {
        case downloadFailed(String)
        case extractionFailed(String)
        case invalidArchive
        case wineUnavailable

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let msg): return "Descarga de DXMT falló: \(msg)"
            case .extractionFailed(let msg): return "Extracción de DXMT falló: \(msg)"
            case .invalidArchive: return "El archivo de DXMT no contiene las DLLs esperadas."
            case .wineUnavailable: return "No se encontró el binario de Wine para registrar las DLLs."
            }
        }
    }

    /// Versión pinneada de DXMT. Último release estable de 3Shain/dxmt.
    static let pinnedVersion = "v0.80"
    static let pinnedDownloadURL = URL(string: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz")!
    static let pinnedAssetName = "dxmt-v0.80-builtin.tar.gz"

    private let cacheDirectory: String

    init(cacheDirectory: String = VesselPaths.cacheDirectory) {
        self.cacheDirectory = "\(cacheDirectory)/dxmt"
        try? FileManager.default.createDirectory(
            atPath: self.cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    func cachedArchivePath() -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: cacheDirectory) else { return nil }
        if let pinned = files.first(where: { $0 == Self.pinnedAssetName }) {
            return "\(cacheDirectory)/\(pinned)"
        }
        return files
            .filter { $0.hasSuffix(".tar.gz") || $0.hasSuffix(".tar.xz") }
            .sorted()
            .last
            .map { "\(cacheDirectory)/\($0)" }
    }

    /// Comprueba si DXMT está instalado en el bottle.
    /// DXMT provee `winemetal.dll` que DXVK no tiene — es el marcador distintivo.
    func isInstalled(in bottle: Bottle) -> Bool {
        let system32 = "\(bottle.prefixPath)/drive_c/windows/system32"
        let required: [String] = ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"]
        let fm = FileManager.default

        for dll in required {
            let path = "\(system32)/\(dll)"
            guard fm.fileExists(atPath: path),
                  let size = try? fm.attributesOfItem(atPath: path)[.size] as? UInt64,
                  size > 500_000
            else {
                return false
            }
        }
        return true
    }

    /// Descarga DXMT (versión pinneada), lo extrae, copia DLLs x64/x32 al bottle,
    /// copia `winemetal.so` al motor de Wine, y registra overrides.
    func install(in bottle: Bottle, progress: @escaping @Sendable (String, Double) -> Void = { _, _ in }) async throws {
        try FileManager.default.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)

        let archivePath: String
        if let cached = cachedArchivePath() {
            progress("DXMT \(Self.pinnedVersion) cacheado detectado", 0.2)
            archivePath = cached
        } else {
            archivePath = try await downloadPinnedRelease(progress: progress)
        }

        let extractedRoot = try await extractArchive(at: archivePath, progress: progress)
        progress("Instalando DXMT en el bottle…", 0.75)
        try copyDLLs(from: extractedRoot, to: bottle, progress: progress)
        progress("Copiando winemetal.so al motor Wine…", 0.85)
        try copyWineMetalSO(from: extractedRoot, to: bottle)
        progress("Registrando overrides de DLL…", 0.9)
        try await registerDllOverrides(in: bottle)
        progress("✓ DXMT \(Self.pinnedVersion) instalado", 1.0)
    }

    // MARK: - Integración en el BUILTIN del motor (fix raíz de juegos D3D11)

    /// Devuelve el directorio raíz de un motor a partir de su binario `bin/wine`.
    private func engineRoot(forWine winePath: String) -> URL {
        URL(fileURLWithPath: winePath)
            .deletingLastPathComponent()   // …/bin
            .deletingLastPathComponent()   // …/<motor>
    }

    /// ¿El motor ya tiene la `d3d11` de DXMT en su builtin? (DXMT ~5 MB; wined3d ~0,4 MB)
    func isInstalledInEngine(engineWinePath: String) -> Bool {
        let d11 = engineRoot(forWine: engineWinePath)
            .appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll").path
        if let size = try? FileManager.default.attributesOfItem(atPath: d11)[.size] as? UInt64 {
            return size > 1_000_000
        }
        return false
    }

    /// Integra los DLLs de DXMT (d3d11/dxgi/d3d10*/winemetal/nvapi) en el **builtin**
    /// del motor (`lib/wine/x86_64-windows` y `i386-windows`), reemplazando wined3d.
    ///
    /// ## Por qué (causa raíz validada)
    ///
    /// El wine-dxmt de 3Shain solo aporta los **símbolos macdrv + `winemetal.so`**
    /// (lo que permite crear la Metal view), pero **su `d3d11` builtin sigue siendo
    /// `wined3d`**. Si no se integra aquí la `d3d11` de DXMT, los juegos D3D11 usan
    /// wined3d→OpenGL y fallan con `InitializeEngineGraphics failed`.
    ///
    /// Con la `d3d11` de DXMT **dentro del builtin** + los macdrv del motor, DXMT
    /// crea la Metal view y el juego renderiza (feature level 11_0/11_1). En Gcenx
    /// no funciona aunque se integre, porque su Wine no exporta esos símbolos macdrv.
    ///
    /// Idempotente: si ya está integrado, no hace nada. Es una operación de motor
    /// (una vez por motor), no por bottle.
    func installIntoEngine(
        engineWinePath: String,
        progress: @escaping @Sendable (String, Double) -> Void = { _, _ in }
    ) async throws {
        if isInstalledInEngine(engineWinePath: engineWinePath) {
            progress("DXMT ya integrado en el motor", 1.0)
            return
        }

        let root = engineRoot(forWine: engineWinePath)
        let x64Dir = root.appendingPathComponent("lib/wine/x86_64-windows").path
        let x32Dir = root.appendingPathComponent("lib/wine/i386-windows").path
        let unixDir = root.appendingPathComponent("lib/wine/x86_64-unix").path
        let fm = FileManager.default

        progress("Preparando DXMT \(Self.pinnedVersion) para el motor…", 0.2)
        let archivePath: String
        if let cached = cachedArchivePath() {
            archivePath = cached
        } else {
            archivePath = try await downloadPinnedRelease(progress: progress)
        }
        let extractedRoot = try await extractArchive(at: archivePath, progress: progress)
        let srcX64 = "\(extractedRoot)/x86_64-windows"
        let srcX32 = "\(extractedRoot)/i386-windows"

        progress("Integrando DXMT en el builtin del motor…", 0.7)
        for (srcDir, dstDir) in [(srcX64, x64Dir), (srcX32, x32Dir)] {
            for dll in Self.x64DLLs where dstDir == x64Dir || Self.x32DLLs.contains(dll) {
                let src = "\(srcDir)/\(dll)"
                let dst = "\(dstDir)/\(dll)"
                guard fm.fileExists(atPath: src) else { continue }
                let backup = "\(dst).wined3d-bak"
                if fm.fileExists(atPath: dst), !fm.fileExists(atPath: backup) {
                    try? fm.copyItem(atPath: dst, toPath: backup)
                }
                try? fm.removeItem(atPath: dst)
                try fm.copyItem(atPath: src, toPath: dst)
            }
        }

        // `winemetal.so` (lado unix) ya viene en el motor 3Shain; si faltara, copiarlo.
        let soSrc = "\(extractedRoot)/x86_64-unix/winemetal.so"
        let soDst = "\(unixDir)/winemetal.so"
        if fm.fileExists(atPath: soSrc), !fm.fileExists(atPath: soDst) {
            try? fm.copyItem(atPath: soSrc, toPath: soDst)
        }
        progress("✓ DXMT integrado en el motor", 1.0)
    }

    // MARK: - Descarga

    private func downloadPinnedRelease(progress: @escaping @Sendable (String, Double) -> Void) async throws -> String {
        progress("Descargando DXMT \(Self.pinnedVersion)…", 0.2)
        let (tempURL, response) = try await URLSession.shared.download(from: Self.pinnedDownloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DXMTError.downloadFailed("HTTP \(http.statusCode) descargando \(Self.pinnedAssetName)")
        }

        let finalPath = "\(cacheDirectory)/\(Self.pinnedAssetName)"
        try? FileManager.default.removeItem(atPath: finalPath)
        try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: finalPath))
        return finalPath
    }

    // MARK: - Extracción

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
        progress("Extrayendo DXMT…", 0.5)
        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw DXMTError.extractionFailed(output.isEmpty ? "tar terminó con código \(task.terminationStatus)" : output)
        }

        // DXMT extrae como `v0.80/x86_64-windows`, `v0.80/i386-windows`, `v0.80/x86_64-unix`.
        guard let contents = try? fm.contentsOfDirectory(atPath: extractRoot) else {
            throw DXMTError.extractionFailed("No se pudo listar el contenido extraído.")
        }

        for candidate in contents {
            let dir = "\(extractRoot)/\(candidate)"
            let x64 = "\(dir)/x86_64-windows"
            let x32 = "\(dir)/i386-windows"
            if fm.fileExists(atPath: x64) && fm.fileExists(atPath: x32) {
                return dir
            }
        }

        // Algunas releases no tienen subdirectorio
        let directX64 = "\(extractRoot)/x86_64-windows"
        let directX32 = "\(extractRoot)/i386-windows"
        if fm.fileExists(atPath: directX64) && fm.fileExists(atPath: directX32) {
            return extractRoot
        }

        throw DXMTError.invalidArchive
    }

    // MARK: - Copia de DLLs

    /// DLLs de DXMT que reemplazan a DXVK (D3D11/D3D10/DXGI → Metal nativo).
    private static let x64DLLs = [
        "d3d10.dll",
        "d3d10_1.dll",
        "d3d10core.dll",
        "d3d11.dll",
        "dxgi.dll",
        "winemetal.dll",
        "nvapi64.dll",
        "nvngx.dll",
    ]

    private static let x32DLLs = [
        "d3d10.dll",
        "d3d10_1.dll",
        "d3d10core.dll",
        "d3d11.dll",
        "dxgi.dll",
        "winemetal.dll",
    ]

    private func copyDLLs(from extractedRoot: String, to bottle: Bottle, progress: @escaping @Sendable (String, Double) -> Void) throws {
        let fm = FileManager.default
        let x64Src = "\(extractedRoot)/x86_64-windows"
        let x32Src = "\(extractedRoot)/i386-windows"
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

    /// Copia `winemetal.so` al directorio `lib/wine/x86_64-unix/` del motor Wine.
    /// DXMT necesita este `.so` para integrarse con el runtime de Wine en macOS.
    private func copyWineMetalSO(from extractedRoot: String, to bottle: Bottle) throws {
        let fm = FileManager.default
        let soSrc = "\(extractedRoot)/x86_64-unix/winemetal.so"
        guard fm.fileExists(atPath: soSrc) else { return }

        // Resolver el directorio lib del motor Wine a partir del winePath del bottle.
        let wineURL = URL(fileURLWithPath: bottle.winePath)
        let binDir = wineURL.deletingLastPathComponent()
        let engineRoot = binDir.deletingLastPathComponent()
        let targetSO = "\(engineRoot.path)/lib/wine/x86_64-unix/winemetal.so"

        try? fm.createDirectory(
            atPath: (targetSO as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? fm.removeItem(atPath: targetSO)
        try fm.copyItem(atPath: soSrc, toPath: targetSO)
    }

    // MARK: - Registro de overrides

    private func registerDllOverrides(in bottle: Bottle) async throws {
        let wineBin: String
        if let portable = WineEngineLocator.findPortableWineBinary(enginesDirectory: VesselPaths.enginesDirectory),
           FileManager.default.isExecutableFile(atPath: portable) {
            wineBin = portable
        } else if FileManager.default.isExecutableFile(atPath: bottle.winePath) {
            wineBin = bottle.winePath
        } else {
            throw DXMTError.wineUnavailable
        }
        try await runRegAdd(winePath: wineBin, prefix: bottle.prefixPath)
    }

    private func runRegAdd(winePath: String, prefix: String) async throws {
        let dlls = ["d3d10", "d3d10_1", "d3d10core", "d3d11", "dxgi", "winemetal", "nvapi64", "nvngx"]
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
