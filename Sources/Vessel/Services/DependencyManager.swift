import Foundation

@MainActor
@Observable
final class DependencyManager {
    struct WineRelease: Codable {
        let tagName: String
        let assets: [WineReleaseAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    struct WineReleaseAsset: Codable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum Dependency: String, CaseIterable, Identifiable {
        case winePortable = "Wine (motor portable)"
        case gptk = "Game Porting Toolkit"
        case rosetta = "Rosetta 2 (traducción x86_64)"
        case dxmt = "DXMT (D3D → Metal nativo)"
        case dxvk = "DXVK (D3D → Vulkan)"

        var id: String { rawValue }
    }

    struct CheckResult {
        let dependency: Dependency
        let installed: Bool
        let path: String?
        let version: String?
        let note: String?
    }

    /// Directorio de engines portables de Vessel — todo auto-gestionado.
    let enginesDirectory = VesselPaths.enginesDirectory

    func checkAll() async -> [CheckResult] {
        var results: [CheckResult] = []
        for dep in Dependency.allCases {
            results.append(await check(dep))
        }
        return results
    }

    func check(_ dep: Dependency) async -> CheckResult {
        switch dep {
        case .winePortable:
            return await findWinePortable()
        case .gptk:
            return await findGPTK()
        case .rosetta:
            return await checkRosetta()
        case .dxmt:
            let path = await findDXMT()
            return CheckResult(dependency: dep, installed: path != nil, path: path, version: path != nil ? "0.80" : nil, note: nil)
        case .dxvk:
            return CheckResult(dependency: dep, installed: true, path: "Bundled con Wine", version: nil, note: nil)
        }
    }

    // MARK: - Wine portable (descargado por Vessel, no de Homebrew)

    private func findWinePortable() async -> CheckResult {
        try? FileManager.default.createDirectory(atPath: enginesDirectory, withIntermediateDirectories: true)

        if let winePath = WineEngineLocator.findPortableWineBinary(enginesDirectory: enginesDirectory) {
            let version = await runCapture(executable: winePath, arguments: ["--version"])
            return CheckResult(
                dependency: .winePortable,
                installed: true,
                path: winePath,
                version: version?.split(separator: "\n").first.map(String.init),
                note: "Auto-instalado por Vessel"
            )
        }

        return CheckResult(dependency: .winePortable, installed: false, path: nil, version: nil, note: nil)
    }

    func ensureWinePortableInstalled(progress: @escaping @Sendable (String, Double) -> Void) async throws -> String {
        let current = await check(.winePortable)
        if let path = current.path, current.installed {
            // Auto-reparación: crear el motor con fix del ratón si falta (p. ej. si el
            // usuario ya tenía Wine instalado de una versión anterior de Vessel).
            await ensureMousefixEngine(progress: progress)
            return path
        }

        try await installWinePortable(progress: progress)

        let verified = await check(.winePortable)
        if let path = verified.path, verified.installed {
            return path
        }

        throw NSError(
            domain: "Vessel",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Wine se instaló, pero no se pudo autodetectar. Revisa los logs de Vessel."]
        )
    }

    /// Instala los DOS motores que Vessel necesita (arquitectura de doble motor):
    ///  - **Gcenx wine-osx64** (Wine completo): motor del CLIENTE de Steam y apps.
    ///  - **wine-dxmt** (3Shain, con símbolos macdrv): motor de JUEGOS D3D11, con
    ///    la `d3d11` de DXMT integrada en su builtin (sin eso los juegos usarían
    ///    wined3d y fallarían con "InitializeEngineGraphics failed").
    ///
    /// Idempotente: salta los motores ya presentes. Auto-descargable de cero.
    func installWinePortable(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        try FileManager.default.createDirectory(atPath: enginesDirectory, withIntermediateDirectories: true)

        // 1) Motor del CLIENTE de Steam: Gcenx wine-osx64.
        let gcenxDir = "\(enginesDirectory)/\(WineEngineLocator.portableEngineName)"
        if !FileManager.default.isExecutableFile(atPath: "\(gcenxDir)/bin/wine")
            && !FileManager.default.isExecutableFile(atPath: "\(gcenxDir)/bin/wine64") {
            progress("Instalando motor del cliente (Gcenx)…", 0.05)
            try await installGcenxWine(progress: progress)
        }

        // 2) Motor de JUEGOS preferido: el UNIFICADO propio (DXMT sobre WineHQ 11.10, con
        //    soporte 32-bit + freetype/gnutls). Un solo motor moderno para juegos D3D11 por
        //    Metal a pantalla completa. Best-effort: si la descarga falla (red o release aún
        //    no publicado), Vessel sigue con el doble motor (wine-dxmt) como fallback.
        let unifiedDir = "\(enginesDirectory)/\(WineEngineLocator.unifiedEngineName)"
        if !FileManager.default.isExecutableFile(atPath: "\(unifiedDir)/bin/wine") {
            progress("Instalando motor unificado (DXMT/WineHQ 11.10)…", 0.3)
            do {
                try await installWineUnified(progress: progress)
            } catch {
                LogStore.shared.log("Motor unificado no disponible (\(error.localizedDescription)); se usa el doble motor wine-dxmt.", level: .warn)
            }
        }

        // 3) Motor de JUEGOS D3D11 fallback: wine-dxmt (3Shain). Se mantiene aunque exista el
        //    unificado, como red de seguridad (WineEngineLocator prefiere el unificado si está).
        let dxmtEngineDir = "\(enginesDirectory)/\(WineEngineLocator.dxmtEngineName)"
        if !FileManager.default.isExecutableFile(atPath: "\(dxmtEngineDir)/bin/wine") {
            progress("Instalando motor de juegos (wine-dxmt)…", 0.4)
            try await installWineDXMT(progress: progress)
        }

        // 3) Integrar DXMT en el builtin del motor de juegos (fix gráfico D3D11).
        if let gameWine = WineEngineLocator.gameWineBinary(enginesDirectory: enginesDirectory) {
            progress("Integrando DXMT en el motor de juegos…", 0.85)
            do {
                try await DXMTManager().installIntoEngine(engineWinePath: gameWine, progress: progress)
            } catch {
                // NO damos éxito en falso: si la descarga/integración de DXMT falla (red), los
                // motores ya están pero los juegos D3D11 usarían wined3d y fallarían. La
                // auto-reparación `ensureGameEngineDXMT` lo reintegrará en el primer lanzamiento.
                LogStore.shared.log("No se pudo integrar DXMT en el motor de juegos: \(error.localizedDescription). Se reintentará al lanzar el primer juego D3D11.", level: .warn)
            }
        }

        // 4) Motor con el fix del ratón de Unity 6 (wine-dxmt-mousefix): copia de
        //    wine-dxmt + win32u.so parcheado. Best-effort (fallback: wine-dxmt).
        await ensureMousefixEngine(progress: progress)

        progress("✓ Motores listos (cliente + juegos D3D11)", 1.0)
    }

    /// Crea o repara el motor `wine-dxmt-mousefix`: una COPIA de `wine-dxmt` con el
    /// `win32u.so` parcheado (fix del ratón de Unity 6, `EnableMouseInPointer`→`WM_POINTER`).
    /// En APFS `copyItem` hace un clon COW (instantáneo, sin gastar espacio). El motor real
    /// `wine-dxmt` queda intacto como fallback.
    ///
    /// **Guarda de versión**: el `win32u.so` parcheado se compiló desde Wine 9.9, así que
    /// solo se aplica si el `wine-dxmt` instalado reporta 9.9 (mismo ABI de la tabla de
    /// syscalls de win32u). Si 3Shain publica otra versión, se omite (y se borra un mousefix
    /// obsoleto) → los juegos usan `wine-dxmt` normal, sin el fix, pero sin romperse.
    ///
    /// Idempotente y auto-reparable: recrea el motor si falta, si su `win32u.so` no es el
    /// parcheado, o si quedó más viejo que `wine-dxmt` (tras actualizar el motor de juegos).
    func ensureMousefixEngine(progress: (@Sendable (String, Double) -> Void)? = nil) async {
        let fm = FileManager.default
        let dxmtDir = "\(enginesDirectory)/\(WineEngineLocator.dxmtEngineName)"
        let dxmtWine = "\(dxmtDir)/bin/wine"
        let mfDir = "\(enginesDirectory)/\(WineEngineLocator.mousefixEngineName)"
        let mfWine = "\(mfDir)/bin/wine"
        let mfWin32u = "\(mfDir)/lib/wine/x86_64-unix/win32u.so"

        // Sin wine-dxmt no hay base sobre la que construir.
        guard fm.isExecutableFile(atPath: dxmtWine) else { return }

        // win32u.so parcheado bundleado en Resources/mousefix/.
        guard let patched = Bundle.main.resourceURL?
            .appendingPathComponent("mousefix/win32u.so").path,
              fm.fileExists(atPath: patched) else {
            LogStore.shared.log("No se encontró el win32u.so parcheado en Resources; se omite el motor con fix del ratón.", level: .warn)
            return
        }

        // Guarda de versión: el parche es de Wine 9.9.
        let version = (await runCapture(executable: dxmtWine, arguments: ["--version"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard version.contains("wine-9.9") else {
            LogStore.shared.log("wine-dxmt reporta '\(version)' (no 9.9): se omite el motor con fix del ratón para no romper el ABI. Los juegos usan wine-dxmt normal.", level: .warn)
            try? fm.removeItem(atPath: mfDir)   // limpiar un mousefix de otra versión
            return
        }

        // Idempotente: ¿ya existe, con el win32u.so parcheado, y no más viejo que wine-dxmt?
        if fm.isExecutableFile(atPath: mfWine) {
            let patchedSize = (try? fm.attributesOfItem(atPath: patched))?[.size] as? Int
            let curSize = (try? fm.attributesOfItem(atPath: mfWin32u))?[.size] as? Int
            let dxmtDate = (try? fm.attributesOfItem(atPath: dxmtWine))?[.modificationDate] as? Date
            let mfDate = (try? fm.attributesOfItem(atPath: mfWine))?[.modificationDate] as? Date
            if let ps = patchedSize, let cs = curSize, ps == cs, ps > 0,
               let dd = dxmtDate, let md = mfDate, md >= dd {
                return  // al día
            }
        }

        progress?("Preparando fix del ratón de Unity 6…", 0.95)
        do {
            try? fm.removeItem(atPath: mfDir)
            // Copia (clon COW en APFS: instantánea) de wine-dxmt → wine-dxmt-mousefix.
            try fm.copyItem(atPath: dxmtDir, toPath: mfDir)
            // Swap del win32u.so por el parcheado.
            try? fm.removeItem(atPath: mfWin32u)
            try fm.copyItem(atPath: patched, toPath: mfWin32u)
            await stripQuarantineRecursive(at: mfDir)
            LogStore.shared.log("Motor 'wine-dxmt-mousefix' listo (fix del ratón de Unity 6).", level: .info)
        } catch {
            LogStore.shared.log("No se pudo crear el motor con fix del ratón: \(error.localizedDescription). Los juegos usarán wine-dxmt normal.", level: .warn)
            try? fm.removeItem(atPath: mfDir)   // no dejar a medias
        }
    }

    /// Descarga 3Shain/wine v9.9-mingw con soporte DXMT integrado.
    private func installWineDXMT(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        progress("Descargando Wine-DXMT (3Shain v9.9, ~311 MB)…", 0.05)
        let downloadURL = URL(string: "https://github.com/3Shain/wine/releases/download/v9.9-mingw/wine.tar.gz")!
        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Vessel", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Descarga Wine-DXMT falló: HTTP \(http.statusCode)"])
        }

        progress("Extrayendo Wine-DXMT…", 0.50)
        let finalEngineDir = "\(enginesDirectory)/\(WineEngineLocator.dxmtEngineName)"
        let stagingDir = "\(enginesDirectory)/wine-dxmt-installing-\(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: stagingDir)
        try FileManager.default.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: stagingDir)
            try? FileManager.default.removeItem(at: tempURL)
        }

        try await extractTar(at: tempURL, to: URL(fileURLWithPath: stagingDir))

        // El tarball extrae como bin/, lib/, share/ directamente
        try? FileManager.default.removeItem(atPath: finalEngineDir)
        try FileManager.default.moveItem(atPath: stagingDir, toPath: finalEngineDir)

        // Quitar quarantine de TODO el motor antes de firmar (igual que Gcenx/Mythic): si el
        // tarball venía marcado, los archivos no-Mach-O (dylibs de datos, scripts) quedarían
        // bloqueados por Gatekeeper aunque `codesign` reescriba los Mach-O.
        await stripQuarantineRecursive(at: finalEngineDir)
        progress("Firmando binarios Wine-DXMT…", 0.90)
        await adhocSignBinaries(in: finalEngineDir)

        guard FileManager.default.isExecutableFile(atPath: "\(finalEngineDir)/bin/wine") else {
            throw NSError(domain: "Vessel", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Wine-DXMT instalado pero bin/wine no es ejecutable"])
        }

        progress("✓ Wine-DXMT v9.9 listo", 1.0)
    }

    /// Descarga el motor UNIFICADO propio de Vessel: **DXMT compilado sobre WineHQ 11.10**
    /// (`--enable-archs=i386,x86_64`) con freetype/gnutls, las 50 fuentes bitmap y el parche
    /// propio `macdrv_dxmt_get_client_view` (arregla la pantalla negra de DXMT en Wine 11).
    /// UN solo motor que corre juegos D3D11 por DXMT/Metal (64-bit) a pantalla completa Y
    /// apps de 32-bit. Trae DXMT ya integrado en su builtin (no hay que reintegrarlo) y sus
    /// libs externas (freetype/gnutls) en `lib/` — `WineManager` le pasa
    /// `DYLD_FALLBACK_LIBRARY_PATH` a esa carpeta. Best-effort: si la descarga falla (red o
    /// release aún no publicado), Vessel sigue con el doble motor (Gcenx + wine-dxmt).
    /// Asegura que el motor unificado está instalado; si falta, lo descarga e instala.
    /// Idempotente y seguro de llamar desde cualquier flujo (p. ej. al abrir el cliente
    /// de Steam): si ya está, retorna al instante.
    func ensureUnifiedEngine(progress: @escaping @Sendable (String, Double) -> Void = { _, _ in }) async throws {
        if WineEngineLocator.engineHasWineBinary(
            WineEngineLocator.unifiedEngineName, enginesDirectory: enginesDirectory
        ) {
            await applySteamRenderFix()
            return
        }
        try await installWineUnified(progress: progress)
        await applySteamRenderFix()
    }

    /// Aplica el fix de RENDER + CONEXIÓN del cliente de Steam al motor unificado (idempotente y
    /// auto-reparable). El tarball publicado trae un `win32u.so` que hace `dlopen` DIRECTO de
    /// MoltenVK → el proceso GPU del CEF de la build moderna crashea (0x80000003) y la ventana sale
    /// NEGRA. Se sustituye por el `win32u.so` del build **wow64** (con el wrapper `--single-process`
    /// el CEF renderiza por **DXMT→Metal**, D3D11 FL 11_1). Además asegura `bcrypt.so`/`secur32.so`
    /// **con gnutls** (verificación de firmas ECDSA del login TLS de Steam; sin ellas el login se
    /// cuelga en "Iniciando sesión"). Los 3 van bundleados en `Resources/engine-steamfix/`.
    /// Verificado in-vivo (2026-07-02): Steam pinta la UI Y conecta (`Logged On`). Idempotente por
    /// tamaño: solo copia y re-firma si el fichero del motor difiere del bundleado.
    func applySteamRenderFix() async {
        let fm = FileManager.default
        let unixDir = "\(enginesDirectory)/\(WineEngineLocator.unifiedEngineName)/lib/wine/x86_64-unix"
        guard fm.fileExists(atPath: "\(unixDir)/win32u.so") else { return }
        guard let resDir = Bundle.main.resourceURL?.appendingPathComponent("engine-steamfix").path,
              fm.fileExists(atPath: "\(resDir)/win32u.so") else { return }
        var applied = false
        for so in ["win32u.so", "bcrypt.so", "secur32.so"] {
            let src = "\(resDir)/\(so)", dst = "\(unixDir)/\(so)"
            guard fm.fileExists(atPath: src) else { continue }
            let srcSize = (try? fm.attributesOfItem(atPath: src))?[.size] as? Int
            let dstSize = (try? fm.attributesOfItem(atPath: dst))?[.size] as? Int
            if srcSize != dstSize || dstSize == nil {
                try? fm.removeItem(atPath: dst)
                if (try? fm.copyItem(atPath: src, toPath: dst)) != nil { applied = true }
            }
        }
        if applied {
            await stripQuarantineRecursive(at: unixDir)
            await adhocSignBinaries(in: unixDir)
            LogStore.shared.log("Fix de render/conexión del cliente de Steam aplicado al motor unificado.", level: .info)
        }
    }

    private func installWineUnified(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        progress("Descargando motor unificado (DXMT/WineHQ 11.10, ~540 MB)…", 0.05)
        // Repo PÚBLICO de motores (Vessel es privado; los assets de un repo privado no se
        // sirven sin autenticación). Como Whisky/Mythic, los binarios van en un repo aparte.
        // v2: motor con `bcrypt`+gnutls (verifica firmas ECDSA — validación TLS del login de
        // Steam), `win32u`+MoltenVK y `libMoltenVK` x86_64 (SwANGLE/WebGL del CEF), `winemac`
        // con el fix del foco de teclado. Es la build que corre el cliente de Steam COMPLETO
        // (login+biblioteca+instalar+jugar) en la build moderna del cliente (Chrome 126+).
        let downloadURL = URL(string: "https://github.com/SwonDev/Vessel-Engines/releases/download/engine-unified-v2/wine-unified.tar.zst")!
        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Vessel", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Descarga del motor unificado falló: HTTP \(http.statusCode)"])
        }

        progress("Extrayendo motor unificado…", 0.55)
        let finalEngineDir = "\(enginesDirectory)/\(WineEngineLocator.unifiedEngineName)"
        let stagingDir = "\(enginesDirectory)/wine-unified-installing-\(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: stagingDir)
        try FileManager.default.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: stagingDir)
            try? FileManager.default.removeItem(at: tempURL)
        }

        try await extractTar(at: tempURL, to: URL(fileURLWithPath: stagingDir))

        // El tarball contiene la carpeta `wine-unified/` en la raíz → normalizar a finalEngineDir.
        let extractedRoot = "\(stagingDir)/\(WineEngineLocator.unifiedEngineName)"
        let sourceDir = FileManager.default.isExecutableFile(atPath: "\(extractedRoot)/bin/wine")
            ? extractedRoot : stagingDir
        try? FileManager.default.removeItem(atPath: finalEngineDir)
        try FileManager.default.moveItem(atPath: sourceDir, toPath: finalEngineDir)

        await stripQuarantineRecursive(at: finalEngineDir)
        progress("Firmando el motor unificado…", 0.90)
        await adhocSignBinaries(in: finalEngineDir)

        guard FileManager.default.isExecutableFile(atPath: "\(finalEngineDir)/bin/wine") else {
            throw NSError(domain: "Vessel", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Motor unificado instalado pero bin/wine no es ejecutable"])
        }
        progress("✓ Motor unificado (DXMT/WineHQ 11.10) listo", 1.0)
    }

    /// Descarga Wine portable desde el repo oficial de Gcenx (fallback).
    private func installGcenxWine(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        progress("Buscando última versión de Wine (Gcenx)…", 0.05)
        let apiURL = URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/latest")!
        let (data, _) = try await URLSession.shared.data(from: apiURL)

        let release = try JSONDecoder().decode(WineRelease.self, from: data)
        let progress5 = progress
        let wineAsset = Self.selectWineAsset(from: release)

        guard let asset = wineAsset, let downloadURL = URL(string: asset.browserDownloadURL) else {
            throw NSError(domain: "Vessel", code: 1, userInfo: [NSLocalizedDescriptionKey: "No se encontró un build de Wine descargable en el release actual"])
        }

        progress5("Descargando Wine \(release.tagName) (~190 MB)…", 0.20)
        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Vessel", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Descarga falló con HTTP \(http.statusCode)"])
        }

        progress5("Verificando integridad del archivo…", 0.45)
        _ = await removeQuarantineIfPresent(at: tempURL.path)

        let finalEngineDir = WineEngineLocator.portableEngineDirectory(enginesDirectory: enginesDirectory)
        let stagingDir = URL(fileURLWithPath: enginesDirectory).appendingPathComponent("wine-osx64-installing-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: stagingDir)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.removeItem(at: tempURL)
        }

        progress5("Extrayendo Wine…", 0.65)
        try await extractTar(at: tempURL, to: stagingDir)

        let normalizedWinePath = try WineEngineLocator.normalizeExtractedEngine(
            stagingDirectory: stagingDir,
            finalEngineDirectory: finalEngineDir
        )

        progress5("Firmando binarios con ad-hoc…", 0.85)
        await adhocSignBinaries(in: finalEngineDir.path)

        guard FileManager.default.isExecutableFile(atPath: normalizedWinePath) else {
            throw NSError(
                domain: "Vessel",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Wine se instaló, pero el binario no es ejecutable."]
            )
        }

        progress5("✓ Wine \(release.tagName) listo", 1.0)
    }

    /// Descarga e instala el **Mythic Engine** (GPTK/D3DMetal) en
    /// `Engines/gptk-mythic`. Reutiliza el mismo flujo que el resto de motores:
    /// descarga → quita cuarentena → extrae (.tar.xz) → firma adhoc. El tarball
    /// trae `wine/`, `dxvk/` y `Properties.plist` en su raíz.
    func installMythicEngine(
        from downloadURL: URL,
        version: String,
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(atPath: enginesDirectory, withIntermediateDirectories: true)

        progress("Descargando GPTK/D3DMetal \(version) (~185 MB)…", 0.05)
        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Vessel", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Descarga de GPTK falló: HTTP \(http.statusCode)"])
        }

        progress("Verificando descarga…", 0.45)
        _ = await removeQuarantineIfPresent(at: tempURL.path)

        let finalEngineDir = "\(enginesDirectory)/\(GPTKManager.engineName)"
        let stagingDir = "\(enginesDirectory)/gptk-installing-\(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: stagingDir)
        try FileManager.default.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: stagingDir)
            try? FileManager.default.removeItem(at: tempURL)
        }

        progress("Extrayendo D3DMetal…", 0.6)
        try await extractTar(at: tempURL, to: URL(fileURLWithPath: stagingDir))

        // El tarball extrae `wine/`, `dxvk/`, `Properties.plist` en la raíz del staging.
        try? FileManager.default.removeItem(atPath: finalEngineDir)
        try FileManager.default.moveItem(atPath: stagingDir, toPath: finalEngineDir)

        progress("Quitando cuarentena…", 0.82)
        await stripQuarantineRecursive(at: finalEngineDir)

        progress("Firmando binarios D3DMetal…", 0.9)
        await adhocSignBinaries(in: finalEngineDir)

        guard FileManager.default.isExecutableFile(atPath: "\(finalEngineDir)/wine/bin/wine") else {
            throw NSError(domain: "Vessel", code: 23,
                          userInfo: [NSLocalizedDescriptionKey: "GPTK instalado pero wine/bin/wine no es ejecutable"])
        }
        progress("✓ GPTK/D3DMetal \(version) listo", 1.0)
    }

    /// Descarga e instala **Goldberg / gbe_fork** (emulador de la Steamworks API)
    /// en `Cache/goldberg`. El asset es un `.7z` que `tar` (libarchive) extrae.
    /// Copia los `steam_api(64).dll` de la build *experimental* (autodetecta
    /// interfaces, sin necesitar `steam_interfaces.txt`).
    func installGoldberg(
        from downloadURL: URL,
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws {
        let cacheDir = "\(VesselPaths.cacheDirectory)/goldberg"
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

        progress("Descargando Goldberg (emulador de Steam, ~13 MB)…", 0.1)
        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Vessel", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Descarga de Goldberg falló: HTTP \(http.statusCode)"])
        }

        let stagingDir = "\(cacheDir)/extract-\(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: stagingDir)
        try FileManager.default.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: stagingDir)
            try? FileManager.default.removeItem(at: tempURL)
        }

        progress("Extrayendo Goldberg…", 0.5)
        try await extractTar(at: tempURL, to: URL(fileURLWithPath: stagingDir))

        let base = "\(stagingDir)/release/experimental"
        let pairs = [
            ("\(base)/x64/steam_api64.dll", "\(cacheDir)/steam_api64.dll"),
            ("\(base)/x86/steam_api.dll", "\(cacheDir)/steam_api.dll")
        ]
        for (src, dst) in pairs where FileManager.default.fileExists(atPath: src) {
            try? FileManager.default.removeItem(atPath: dst)
            try FileManager.default.copyItem(atPath: src, toPath: dst)
        }

        guard FileManager.default.fileExists(atPath: "\(cacheDir)/steam_api64.dll") else {
            throw NSError(domain: "Vessel", code: 31,
                          userInfo: [NSLocalizedDescriptionKey: "Goldberg se descargó pero no se encontró steam_api64.dll en el paquete."])
        }
        progress("✓ Goldberg listo", 1.0)
    }

    /// Quita `com.apple.quarantine` recursivamente (necesario para que `dlopen`
    /// cargue las dylibs de D3DMetal sin bloqueo de Gatekeeper).
    private func stripQuarantineRecursive(at path: String) async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", path]
        task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try? task.run()
        task.waitUntilExit()
    }

    nonisolated static func selectWineAsset(from release: WineRelease) -> WineReleaseAsset? {
        release.assets.first { $0.name.contains("wine-devel") && $0.name.hasSuffix(".tar.xz") }
            ?? release.assets.first { $0.name.contains("osx64") && $0.name.hasSuffix(".tar.xz") }
    }

    private func extractTar(at archiveURL: URL, to destinationURL: URL) async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xf", archiveURL.path, "-C", destinationURL.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "Vessel",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Falló la extracción de Wine: \(output)"]
            )
        }
    }

    private func removeQuarantineIfPresent(at path: String) async -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = [path]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let attrs = String(data: data, encoding: .utf8) ?? ""
            if attrs.contains("com.apple.quarantine") {
                let rm = Process()
                rm.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                rm.arguments = ["-d", "com.apple.quarantine", path]
                try rm.run()
                rm.waitUntilExit()
                return true
            }
        } catch {}
        return false
    }

    private func adhocSignBinaries(in directory: String) async {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: directory) else { return }
        let paths: [String] = Array(enumerator.compactMap { $0 as? String })
        for path in paths {
            let full = "\(directory)/\(path)"
            if isMachOFile(atPath: full) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                task.arguments = ["--force", "--sign", "-", full]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe
                do {
                    try task.run()
                    task.waitUntilExit()
                    if task.terminationStatus != 0 {
                        LogStore.shared.log("codesign falló (código \(task.terminationStatus)) firmando \((full as NSString).lastPathComponent); macOS podría bloquear el binario.", level: .warn)
                    }
                } catch {
                    LogStore.shared.log("No se pudo ejecutar codesign sobre \((full as NSString).lastPathComponent): \(error.localizedDescription)", level: .warn)
                }
            }
        }
    }

    private func isMachOFile(atPath path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 4), data.count == 4 else {
            return false
        }

        let bytes = [UInt8](data)
        let magic = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let machOMagics: Set<UInt32> = [
            0xFEEDFACE, 0xFEEDFACF,
            0xCEFAEDFE, 0xCFFAEDFE,
            0xCAFEBABE, 0xCAFEBABF,
            0xBEBAFECA, 0xBFBAFECA
        ]
        return machOMagics.contains(magic)
    }

    // MARK: - GPTK (nativo ARM de Apple, sin Gatekeeper)

    private func findGPTK() async -> CheckResult {
        let gptk = "/Library/Apple/usr/libexec/oah/translation"
        let gptkBin = "\(gptk)/wine64"
        if FileManager.default.isExecutableFile(atPath: gptkBin) {
            return CheckResult(dependency: .gptk, installed: true, path: gptkBin, version: "Apple GPTK", note: "Nativo ARM")
        }
        if FileManager.default.fileExists(atPath: gptk) {
            return CheckResult(dependency: .gptk, installed: true, path: gptk, version: nil, note: "Directorio presente")
        }
        return CheckResult(dependency: .gptk, installed: false, path: nil, version: nil, note: "Requiere macOS Sonoma 14.2+")
    }

    // MARK: - Rosetta 2

    private func checkRosetta() async -> CheckResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        task.arguments = ["-x86_64", "true"]
        let pipe = Pipe()
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                return CheckResult(dependency: .rosetta, installed: true, path: "/usr/bin/arch", version: "Activo", note: nil)
            }
        } catch {}
        return CheckResult(dependency: .rosetta, installed: false, path: nil, version: nil, note: nil)
    }

    /// Instala Rosetta automáticamente (puede pedir contraseña del Mac).
    func installRosetta() async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/softwareupdate")
        task.arguments = ["--install-rosetta", "--agree-to-license"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw NSError(domain: "Vessel", code: Int(task.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "softwareupdate falló: \(err)"])
            }
        } catch {
            throw error
        }
    }

    // MARK: - DXMT (D3D→Metal nativo ARM)

    private func findDXMT() async -> String? {
        let candidates = [
            "\(enginesDirectory)/dxmt/dxmt64",
            "/usr/local/bin/dxmt64",
            "/opt/homebrew/bin/dxmt64",
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }

    // MARK: - Helpers

    private func runCapture(executable: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { cont in
            // SIEMPRE fuera del hilo principal: `waitUntilExit()` corre un runloop anidado que, en el
            // main thread, chocaba con el ciclo de render Metal (ColorfulX) → EXC_BAD_ACCESS.
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: executable)
                task.arguments = arguments
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe
                do { try task.run() } catch {
                    cont.resume(returning: nil); return
                }
                // Leer hasta EOF ANTES de esperar: evita el deadlock si el proceso llena el buffer del
                // pipe (readDataToEndOfFile bloquea hasta que el proceso cierra stdout, es decir sale).
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                cont.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}
