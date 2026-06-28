import Foundation

/// Gestiona el motor **GPTK / D3DMetal** (Apple Game Porting Toolkit) que Vessel
/// usa para juegos **Direct3D 12** en Apple Silicon — la misma vía que CrossOver,
/// Whisky y Mythic. D3DMetal traduce D3D12/D3D11/D3D10 → Metal de forma nativa,
/// a diferencia de vkd3d/DXVK (que pasan por Vulkan→MoltenVK y no soportan muchos
/// juegos D3D12 AAA con DirectX 12 Agility SDK, como Final Fantasy Tactics).
///
/// El binario se obtiene del **Mythic Engine** (fork de CrossOver + libs de GPTK
/// ya extraídas), descargable sin login de Apple. La licencia de Apple permite
/// redistribuir D3DMetal con fines NO comerciales en Macs; Vessel es open-source
/// y gratuito, por lo que cumple. Estructura instalada en `Engines/gptk-mythic/`:
///
///   wine/bin/wine                         (CrossOver 9.0, ARM64 nativo)
///   wine/lib/external/D3DMetal.framework  (traductor D3D→Metal de Apple)
///   wine/lib/external/libd3dshared.dylib  (lógica compartida; inspecciona WINEESYNC)
///   wine/lib/wine/x86_64-windows/{d3d12,d3d11,dxgi,...}.dll  (builtins D3DMetal)
@MainActor
final class GPTKManager {
    /// Carpeta del motor dentro de `Engines/`.
    static let engineName = "gptk-mythic"

    /// Catálogo de versiones del Mythic Engine (se sirve por https aunque las URLs
    /// internas vengan como http: forzamos https para cumplir ATS).
    static let streamPlistURL = URL(string: "https://dl.getmythic.app/engine/EngineUpdateStream.plist")!

    private let dependencyManager = DependencyManager()

    struct EngineRelease {
        let version: String
        let downloadURL: URL
        let gptkVersion: String
    }

    // MARK: - Localización

    var engineRootPath: String { "\(VesselPaths.enginesDirectory)/\(Self.engineName)" }

    /// Binario `wine` real (CrossOver 9.0). El `wine64` del engine es solo un script
    /// que reenvía a este; usamos el binario directo.
    var wineBinaryPath: String? {
        let candidate = "\(engineRootPath)/wine/bin/wine"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// Carpeta con `D3DMetal.framework` + `libd3dshared.dylib`. El binario wine ya
    /// la resuelve por rpath (`@executable_path/../lib/external`), pero la pasamos
    /// también por `DYLD_FALLBACK_LIBRARY_PATH` como cinturón y tirantes.
    var externalLibsPath: String { "\(engineRootPath)/wine/lib/external" }

    var isInstalled: Bool {
        wineBinaryPath != nil
            && FileManager.default.fileExists(atPath: "\(externalLibsPath)/D3DMetal.framework")
    }

    /// Versión instalada (de `Properties.plist`), o nil si no está.
    var installedVersion: String? {
        let plistPath = "\(engineRootPath)/Properties.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["version"] as? [String: Any] else { return nil }
        let major = version["major"] as? Int ?? 0
        let minor = version["minor"] as? Int ?? 0
        let patch = version["patch"] as? Int ?? 0
        return "\(major).\(minor).\(patch)"
    }

    // MARK: - Instalación

    /// Asegura que GPTK/D3DMetal está instalado. Si no, descarga la ÚLTIMA versión
    /// disponible del catálogo de Mythic. Idempotente.
    func ensureInstalled(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        if isInstalled { return }
        try await install(progress: progress)
        guard isInstalled else {
            throw NSError(domain: "Vessel", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "GPTK/D3DMetal se instaló pero no se pudo autodetectar."
            ])
        }
    }

    func install(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        progress("Buscando última versión de GPTK/D3DMetal…", 0.02)
        let release = try await resolveLatestEngine()
        try await dependencyManager.installMythicEngine(
            from: release.downloadURL,
            version: release.version,
            progress: progress
        )
    }

    /// Descarga el catálogo y elige la versión MÁS RECIENTE (mayor semver) de todos
    /// los canales (incluye preview, que en macOS 26 es GPTK 3.0).
    func resolveLatestEngine() async throws -> EngineRelease {
        let (data, response) = try await URLSession.shared.data(from: Self.streamPlistURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Vessel", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "No se pudo leer el catálogo de GPTK (HTTP \(http.statusCode))."
            ])
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let channels = plist["channels"] as? [[String: Any]] else {
            throw NSError(domain: "Vessel", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Catálogo de GPTK con formato inesperado."
            ])
        }

        var releases: [EngineRelease] = []
        for channel in channels {
            guard let list = channel["releases"] as? [[String: Any]] else { continue }
            for entry in list {
                guard let version = entry["version"] as? String,
                      let urlString = entry["downloadURL"] as? String else { continue }
                // Forzar https para cumplir App Transport Security.
                let secure = urlString.replacingOccurrences(of: "http://", with: "https://")
                guard let url = URL(string: secure) else { continue }
                releases.append(EngineRelease(
                    version: version,
                    downloadURL: url,
                    gptkVersion: entry["targetGPTKVersion"] as? String ?? version
                ))
            }
        }

        guard let latest = releases.max(by: { Self.isVersion($0.version, olderThan: $1.version) }) else {
            throw NSError(domain: "Vessel", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "El catálogo de GPTK no contenía ninguna versión."
            ])
        }
        return latest
    }

    /// Compara dos strings de versión tipo "3.0.0" / "2.6.1". true si `lhs` < `rhs`.
    nonisolated static func isVersion(_ lhs: String, olderThan rhs: String) -> Bool {
        func components(_ v: String) -> [Int] {
            v.split(whereSeparator: { $0 == "." || $0 == "-" })
                .map { Int($0) ?? 0 }
        }
        let a = components(lhs), b = components(rhs)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    // MARK: - Entorno D3DMetal

    /// Entorno para lanzar un juego D3D12 con D3DMetal. CLAVE: `WINEESYNC=1` es
    /// imprescindible aunque no se use esync — `libd3dshared.dylib` lo inspecciona
    /// internamente y, sin él, D3DMetal falla bajo msync. NO se ponen overrides de
    /// d3d: los builtins de D3DMetal del propio engine ya tienen prioridad máxima
    /// y, por diseño, ignoran el `D3D12Core.dll` del Agility SDK que traen muchos
    /// juegos (la causa del crash con vkd3d).
    func d3dMetalEnvironment(prefix: String) -> [String: String] {
        var env: [String: String] = [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "WINEMSYNC": "1",
            "WINEESYNC": "1",
            "MVK_CONFIG_LOG_LEVEL": "0",
            "MTL_HUD_ENABLED": "0",
            // Silenciar el instalador de Mono/Gecko al re-sincronizar el prefijo.
            "WINEDLLOVERRIDES": "mscoree,mshtml=d",
            // El rpath del wine ya carga D3DMetal; reforzamos por si acaso.
            "DYLD_FALLBACK_LIBRARY_PATH": externalLibsPath
        ]
        // Exponer AVX a Rosetta (algunos juegos comprueban CPUID y crashean sin él).
        // Solo válido/seguro en macOS 15+.
        if #available(macOS 15, *) {
            env["ROSETTA_ADVERTISE_AVX"] = "1"
        }
        return env
    }
}
