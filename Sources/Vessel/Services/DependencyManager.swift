import Foundation
import CryptoKit

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
            // Y el motor OpenGL específico (winemac.so forward-compat GL) para HoH2 y similares.
            await ensureUnifiedOpenGLEngine(progress: progress)
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

    /// Asegura el motor del cliente Steam **interactivo** y devuelve exactamente su binario.
    ///
    /// `ensureWinePortableInstalled` conserva su contrato histórico y puede devolver el motor DXMT
    /// preferido por el inventario general. Para login, tienda y EULA eso no es suficiente: la ruta
    /// validada visualmente es Gcenx (`wine-osx64`) con el wrapper de composición por software.
    /// Separar el contrato impide seleccionar por accidente un motor de juego para la interfaz.
    func ensureInteractiveSteamEngineInstalled(
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws -> String {
        if let wine = WineEngineLocator.interactiveSteamWineBinary() {
            return wine
        }

        try await installGcenxWine(progress: progress)
        guard let wine = WineEngineLocator.interactiveSteamWineBinary() else {
            throw NSError(
                domain: "Vessel",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "El motor interactivo de Steam se instaló, pero no se pudo verificar."
                ]
            )
        }
        return wine
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

        // 5) Motor OpenGL específico (wine-unified-opengl): clon del unificado con el winemac.so
        //    parcheado (forward-compat GL, CW Hack 24834) para HoH2 y juegos GL, sin tocar el
        //    unificado compartido. Best-effort (fallback: unificado normal).
        await ensureUnifiedOpenGLEngine(progress: progress)

        // 6) Motor DEDICADO del cliente de Steam (wine-steam): clon del unificado con el winemac.so
        //    de la TIENDA (CW HACK 22435), para "Abrir Steam" con cliente + biblioteca + tienda, sin
        //    tocar los motores de juegos. Best-effort (fallback: unificado sin tienda).
        await ensureSteamEngine(progress: progress)

        progress("✓ Motores listos (cliente + juegos D3D11 + OpenGL + Steam)", 1.0)
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

    /// Crea/repara `gptk-mythic-mousefix`: clon COW del **gptk-mythic** (CrossOver 9.0) con SOLO el
    /// `win32u.so` parcheado (fix del ratón de Unity 6, `EnableMouseInPointer`→`WM_POINTER`). Es el
    /// mismo parche que `wine-dxmt-mousefix` pero compilado desde **Wine 9.0** para casar el ABI de
    /// gptk (validado: carga y ejecuta sin fork-bomb; Ancient Kingdoms responde al ratón). Todos los
    /// juegos gptk (Unity 6, D3D12) lo heredan vía `GPTKManager.launchEngineRootPath`; es inerte para
    /// los que no llaman a EnableMouseInPointer. El gptk base queda intacto como fallback.
    ///
    /// **Guarda de versión**: el win32u parcheado se compiló desde Wine 9.0. Si gptk reportara otra
    /// versión, se omite (y se borra un mousefix obsoleto) para no romper el ABI. Idempotente/auto-
    /// reparable: recrea si falta, si el win32u.so no es el parcheado (por tamaño), o si quedó más
    /// viejo que el gptk base.
    func ensureGptkMousefixEngine(progress: (@Sendable (String, Double) -> Void)? = nil) async {
        let fm = FileManager.default
        let gptkDir = "\(enginesDirectory)/\(GPTKManager.engineName)"
        let gptkWine = "\(gptkDir)/wine/bin/wine"
        let mfDir = "\(enginesDirectory)/\(GPTKManager.mousefixEngineName)"
        let mfWine = "\(mfDir)/wine/bin/wine"
        let mfWin32u = "\(mfDir)/wine/lib/wine/x86_64-unix/win32u.so"

        guard fm.isExecutableFile(atPath: gptkWine) else { return }

        guard let patched = Bundle.main.resourceURL?
            .appendingPathComponent("mousefix-gptk/win32u.so").path,
              fm.fileExists(atPath: patched) else {
            LogStore.shared.log("No se encontró el win32u.so (gptk) parcheado en Resources; Unity 6 usará gptk normal.", level: .warn)
            return
        }

        // Guarda de versión: el parche se compiló desde Wine 9.0 (gptk = CrossOver 9.0).
        let version = (await runCapture(executable: gptkWine, arguments: ["--version"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard version.contains("wine-9.0") else {
            LogStore.shared.log("gptk reporta '\(version)' (no 9.0): se omite el gptk-mousefix para no romper el ABI. Unity 6 usará gptk normal.", level: .warn)
            try? fm.removeItem(atPath: mfDir)
            return
        }

        // Idempotente: ¿ya existe, con el win32u.so parcheado, y no más viejo que gptk?
        if fm.isExecutableFile(atPath: mfWine) {
            let patchedSize = (try? fm.attributesOfItem(atPath: patched))?[.size] as? Int
            let curSize = (try? fm.attributesOfItem(atPath: mfWin32u))?[.size] as? Int
            let gptkDate = (try? fm.attributesOfItem(atPath: gptkWine))?[.modificationDate] as? Date
            let mfDate = (try? fm.attributesOfItem(atPath: mfWine))?[.modificationDate] as? Date
            if let ps = patchedSize, let cs = curSize, ps == cs, ps > 0,
               let gd = gptkDate, let md = mfDate, md >= gd {
                return  // al día
            }
        }

        progress?("Preparando fix del ratón de Unity 6 (gptk)…", 0.95)
        do {
            try? fm.removeItem(atPath: mfDir)
            try fm.copyItem(atPath: gptkDir, toPath: mfDir)      // clon COW (APFS)
            try? fm.removeItem(atPath: mfWin32u)
            try fm.copyItem(atPath: patched, toPath: mfWin32u)   // swap del win32u parcheado
            await stripQuarantineRecursive(at: mfDir)
            LogStore.shared.log("Motor 'gptk-mythic-mousefix' listo (fix del ratón de Unity 6 en gptk).", level: .info)
        } catch {
            LogStore.shared.log("No se pudo crear el gptk-mousefix: \(error.localizedDescription). Unity 6 usará gptk normal.", level: .warn)
            try? fm.removeItem(atPath: mfDir)
        }
    }

    /// Crea/repara el motor `wine-unified-opengl`: clon COW de `wine-unified` con SOLO el
    /// `winemac.so` reemplazado por la versión parcheada (CW Hack 24834, forward-compat GL) que va
    /// bundleada en `Resources/opengl-engine/`. Aísla el parche de OpenGL del motor unificado
    /// COMPARTIDO (que corre el cliente Steam y los juegos D3D11): así reparar los juegos OpenGL
    /// (Heroes of Hammerwatch II y similares) no pisa nada de lo que ya funciona. Idempotente y
    /// auto-reparable (se recrea si falta, si el winemac.so no es el parcheado, o si quedó más viejo
    /// que el unificado). Se llama tras instalar/verificar el motor unificado.
    func ensureUnifiedOpenGLEngine(progress: (@Sendable (String, Double) -> Void)? = nil) async {
        let fm = FileManager.default
        let uniDir = "\(enginesDirectory)/\(WineEngineLocator.unifiedEngineName)"
        let uniWine = "\(uniDir)/bin/wine"
        let oglDir = "\(enginesDirectory)/\(WineEngineLocator.unifiedOpenGLEngineName)"
        let oglWine = "\(oglDir)/bin/wine"
        let oglWinemac = "\(oglDir)/lib/wine/x86_64-unix/winemac.so"

        guard fm.isExecutableFile(atPath: uniWine) else { return }

        guard let patched = Bundle.main.resourceURL?
            .appendingPathComponent("opengl-engine/winemac.so").path,
              fm.fileExists(atPath: patched) else {
            LogStore.shared.log("No se encontró el winemac.so (OpenGL) parcheado en Resources; los juegos OpenGL usarán el motor unificado normal.", level: .warn)
            return
        }

        // Guarda de versión: el winemac.so parcheado se compiló contra WineHQ 11.x.
        let version = (await runCapture(executable: uniWine, arguments: ["--version"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard version.contains("wine-11") else {
            LogStore.shared.log("wine-unified reporta '\(version)' (no 11.x): se omite el motor OpenGL para no romper el ABI del winemac.so. Los juegos OpenGL usarán el unificado normal.", level: .warn)
            try? fm.removeItem(atPath: oglDir)
            return
        }

        // Idempotente: ¿ya existe, con el winemac.so parcheado, y no más viejo que el unificado?
        if fm.isExecutableFile(atPath: oglWine) {
            let patchedSize = (try? fm.attributesOfItem(atPath: patched))?[.size] as? Int
            let curSize = (try? fm.attributesOfItem(atPath: oglWinemac))?[.size] as? Int
            let uniDate = (try? fm.attributesOfItem(atPath: uniWine))?[.modificationDate] as? Date
            let oglDate = (try? fm.attributesOfItem(atPath: oglWine))?[.modificationDate] as? Date
            if let ps = patchedSize, let cs = curSize, ps == cs, ps > 0,
               let ud = uniDate, let od = oglDate, od >= ud {
                return  // al día
            }
        }

        progress?("Preparando motor OpenGL (Heroes of Hammerwatch II y similares)…", 0.95)
        do {
            try? fm.removeItem(atPath: oglDir)
            try fm.copyItem(atPath: uniDir, toPath: oglDir)      // clon COW (APFS)
            try? fm.removeItem(atPath: oglWinemac)
            try fm.copyItem(atPath: patched, toPath: oglWinemac) // swap del winemac.so parcheado
            await stripQuarantineRecursive(at: oglDir)
            LogStore.shared.log("Motor 'wine-unified-opengl' listo (forward-compat GL para juegos OpenGL).", level: .info)
        } catch {
            LogStore.shared.log("No se pudo crear el motor OpenGL: \(error.localizedDescription). Los juegos OpenGL usarán el unificado normal.", level: .warn)
            try? fm.removeItem(atPath: oglDir)
        }
    }

    /// Crea o autorrepara el motor OpenGL legado/core. A diferencia del motor OpenGL genérico,
    /// este reemplaza conjuntamente `winemac.so` y `opengl32.so`: ambos se compilan desde WineHQ
    /// 11.10 y forman una unidad ABI. La ruta de juego que lo usa tiene prefijo propio, de modo que
    /// su registro Retina y su wineserver nunca se mezclan con Steam ni con motores ya validados.
    ///
    /// No existe fallback silencioso: si falta un recurso, la base no coincide con Wine 11.10 o la
    /// copia no verifica byte a byte, se lanza un error y Vessel puede mostrar un fallo real en vez
    /// de ejecutar el juego con un motor que sabemos incompatible.
    func ensureUnifiedLegacyOpenGLEngine(
        progress: (@Sendable (String, Double) -> Void)? = nil
    ) async throws -> String {
        let fm = FileManager.default
        let baseDirectory = "\(enginesDirectory)/\(WineEngineLocator.unifiedEngineName)"
        let baseWine = "\(baseDirectory)/bin/wine"
        let engineDirectory = "\(enginesDirectory)/\(WineEngineLocator.unifiedLegacyOpenGLEngineName)"
        let engineWine = "\(engineDirectory)/bin/wine"
        let unixDirectory = "\(engineDirectory)/lib/wine/x86_64-unix"
        let installedWinemac = "\(unixDirectory)/winemac.so"
        let installedOpenGL = "\(unixDirectory)/opengl32.so"

        guard fm.isExecutableFile(atPath: baseWine) else {
            throw NSError(
                domain: "Vessel",
                code: 81,
                userInfo: [NSLocalizedDescriptionKey: "El motor base Wine 11.10 no está instalado."]
            )
        }

        guard let resources = Bundle.main.resourceURL?.appendingPathComponent(
            "legacy-opengl-engine",
            isDirectory: true
        ) else {
            throw NSError(
                domain: "Vessel",
                code: 82,
                userInfo: [NSLocalizedDescriptionKey: "No se encontró el adaptador OpenGL legado incluido en Vessel."]
            )
        }
        let resourceWinemac = resources.appendingPathComponent("winemac.so").path
        let resourceOpenGL = resources.appendingPathComponent("opengl32.so").path
        guard fm.fileExists(atPath: resourceWinemac),
              fm.fileExists(atPath: resourceOpenGL) else {
            throw NSError(
                domain: "Vessel",
                code: 83,
                userInfo: [NSLocalizedDescriptionKey: "El adaptador OpenGL legado está incompleto."]
            )
        }

        let version = (await runCapture(executable: baseWine, arguments: ["--version"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard version.contains("wine-11.10") else {
            throw NSError(
                domain: "Vessel",
                code: 84,
                userInfo: [NSLocalizedDescriptionKey: "El adaptador OpenGL requiere Wine 11.10; el motor instalado reporta «\(version)»."]
            )
        }

        let baseDate = (try? fm.attributesOfItem(atPath: baseWine))?[.modificationDate] as? Date
        let engineDate = (try? fm.attributesOfItem(atPath: engineWine))?[.modificationDate] as? Date
        let matchesResources = Self.filesHaveSameSHA256(resourceWinemac, installedWinemac)
            && Self.filesHaveSameSHA256(resourceOpenGL, installedOpenGL)
        if fm.isExecutableFile(atPath: engineWine), matchesResources,
           let baseDate, let engineDate, engineDate >= baseDate {
            return engineWine
        }

        progress?("Preparando motor OpenGL legado aislado…", 0.94)
        do {
            try? fm.removeItem(atPath: engineDirectory)
            try fm.copyItem(atPath: baseDirectory, toPath: engineDirectory)
            try? fm.removeItem(atPath: installedWinemac)
            try? fm.removeItem(atPath: installedOpenGL)
            try fm.copyItem(atPath: resourceWinemac, toPath: installedWinemac)
            try fm.copyItem(atPath: resourceOpenGL, toPath: installedOpenGL)
            await stripQuarantineRecursive(at: engineDirectory)

            guard fm.isExecutableFile(atPath: engineWine),
                  Self.filesHaveSameSHA256(resourceWinemac, installedWinemac),
                  Self.filesHaveSameSHA256(resourceOpenGL, installedOpenGL) else {
                throw NSError(
                    domain: "Vessel",
                    code: 85,
                    userInfo: [NSLocalizedDescriptionKey: "La verificación del motor OpenGL legado no coincide."]
                )
            }
            LogStore.shared.log(
                "Motor '\(WineEngineLocator.unifiedLegacyOpenGLEngineName)' listo y verificado.",
                level: .info
            )
            return engineWine
        } catch {
            try? fm.removeItem(atPath: engineDirectory)
            throw error
        }
    }

    /// Crea/repara el motor DEDICADO del cliente de Steam `wine-steam`: clon COW de `wine-unified` (el
    /// único motor que renderiza el CEF: cliente + biblioteca) con SOLO el `winemac.so` reemplazado por
    /// la versión con **CW HACK 22435** (una superficie Metal por cada swapchain del compositor CEF → la
    /// **TIENDA** de Steam también se compone, no sale negra), bundleada en `Resources/steam-engine/`. Es
    /// EXCLUSIVO del cliente de Steam; NO toca los motores de juegos del modo Vessel (solo se une con
    /// ellos en la biblioteca instalada). Se basa en el unificado (SIN D3DMetal) a PROPÓSITO: en
    /// `wine-d3dmetal` el `dxgi`/D3DMetal hace que el proceso GPU del webhelper CRASHEE en bucle (~87
    /// steamwebhelper); en el unificado el CEF va estable. Idempotente y auto-reparable (se recrea si
    /// falta, si el winemac.so no es el de la tienda, o si quedó más viejo que el unificado).
    func ensureSteamEngine(progress: (@Sendable (String, Double) -> Void)? = nil) async {
        let fm = FileManager.default
        let uniDir = "\(enginesDirectory)/\(WineEngineLocator.unifiedEngineName)"
        let uniWine = "\(uniDir)/bin/wine"
        let steamDir = "\(enginesDirectory)/\(WineEngineLocator.steamEngineName)"
        let steamWine = "\(steamDir)/bin/wine"
        let steamWinemac = "\(steamDir)/lib/wine/x86_64-unix/winemac.so"

        guard fm.isExecutableFile(atPath: uniWine) else { return }

        guard let patched = Bundle.main.resourceURL?
            .appendingPathComponent("steam-engine/winemac.so").path,
              fm.fileExists(atPath: patched) else {
            LogStore.shared.log("No se encontró el winemac.so (tienda) en Resources; el cliente Steam usará el unificado (sin la tienda).", level: .warn)
            return
        }

        // Guarda de versión: el winemac.so con CW HACK 22435 se compiló contra WineHQ 11.x.
        let version = (await runCapture(executable: uniWine, arguments: ["--version"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard version.contains("wine-11") else {
            LogStore.shared.log("wine-unified reporta '\(version)' (no 11.x): se omite el motor Steam para no romper el ABI del winemac.so.", level: .warn)
            try? fm.removeItem(atPath: steamDir)
            return
        }

        // Idempotente: ¿ya existe, con el winemac.so de la tienda, y no más viejo que el unificado?
        if fm.isExecutableFile(atPath: steamWine) {
            let patchedSize = (try? fm.attributesOfItem(atPath: patched))?[.size] as? Int
            let curSize = (try? fm.attributesOfItem(atPath: steamWinemac))?[.size] as? Int
            let uniDate = (try? fm.attributesOfItem(atPath: uniWine))?[.modificationDate] as? Date
            let steamDate = (try? fm.attributesOfItem(atPath: steamWine))?[.modificationDate] as? Date
            if let ps = patchedSize, let cs = curSize, ps == cs, ps > 0,
               let ud = uniDate, let sd = steamDate, sd >= ud {
                return  // al día
            }
        }

        progress?("Preparando motor de Steam (cliente + biblioteca + tienda)…", 0.96)
        do {
            try? fm.removeItem(atPath: steamDir)
            try fm.copyItem(atPath: uniDir, toPath: steamDir)          // clon COW (APFS)
            try? fm.removeItem(atPath: steamWinemac)
            try fm.copyItem(atPath: patched, toPath: steamWinemac)     // swap del winemac.so (CW HACK 22435)
            // NO re-firmar: el `winemac.so` de Resources ya viene firmado ad-hoc (build_and_run firma la
            // .app con `--deep`); re-firmarlo cambiaría su tamaño y rompería la guarda de idempotencia
            // de arriba (que compara tamaños) → recrearía el motor en cada arranque. Igual que el OpenGL.
            await stripQuarantineRecursive(at: steamDir)
            LogStore.shared.log("Motor 'wine-steam' listo (cliente Steam + biblioteca + TIENDA).", level: .info)
        } catch {
            LogStore.shared.log("No se pudo crear el motor Steam: \(error.localizedDescription). El cliente usará el unificado (sin tienda).", level: .warn)
            try? fm.removeItem(atPath: steamDir)
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
            await applyCryptoFix()                 // motor v3: gnutls 3.8.13 + freetype 2.14.3 (drop-in)
            Task { await self.ensureWineMono() }   // .NET Framework, en 2º plano (idempotente)
            return
        }
        try await installWineUnified(progress: progress)
        await applySteamRenderFix()
        await applyCryptoFix()                     // motor v3: gnutls 3.8.13 + freetype 2.14.3 (drop-in)
        Task { await self.ensureWineMono() }
    }

    /// Asegura el motor COMPLETO (`wine-full`) para las rutas de juegos que lo necesitan
    /// (UE4, FNA/XNA, Source, Godot-Vulkan, D3D9 32-bit, Unity 32-bit, DirectDraw clásico).
    ///
    /// **Tarea #47**: desde la 0.0.4 `wine-full` es una **build propia de Vessel de las fuentes
    /// FOSS de CrossOver 26.2.0** (wine-11.0 + CW HACKs: msync, winemac, wined3d; LGPL) publicada
    /// en `SwonDev/Vessel-Engines` — redistribuible y autónoma. Antes era una copia manual del
    /// CrossOver instalado localmente (licencia), que los usuarios sin CrossOver no tenían y por
    /// tanto esas rutas les fallaban. **NUNCA pisa un wine-full existente**: si el usuario tiene
    /// el CrossOver real copiado a mano, manda ese (es la referencia; además es el único que
    /// corre el CEF del cliente Steam — ver `WineEngineLocator.isRealCrossOverFullEngine`).
    /// Idempotente: si ya hay motor, retorna al instante.
    func ensureFullEngine(progress: @escaping @Sendable (String, Double) -> Void = { _, _ in }) async throws {
        guard !WineEngineLocator.isFullEngineInstalled(enginesDirectory: enginesDirectory) else { return }
        try await installWineFull(progress: progress)
    }

    /// Asegura el perfil aislado para juegos D3D12 que reproducen vídeo mediante Media Foundation.
    ///
    /// La combinación se construye solo con dependencias ya gestionadas por Vessel: núcleo FOSS de
    /// `wine-full`, D3DMetal del motor GPTK, winegstreamer de Gcenx y GStreamer oficial con SHA-256.
    /// Ninguna pieza se aplica sobre los motores compartidos, de modo que una reparación multimedia
    /// no puede introducir regresiones en juegos que ya funcionan.
    func ensureD3DMetalMediaEngine(
        progress: @escaping @Sendable (String, Double) -> Void = { _, _ in }
    ) async throws -> String {
        try await ensureFullEngine(progress: progress)
        guard let baseWine = WineEngineLocator.fullWineBinary(
            enginesDirectory: enginesDirectory
        ), let baseEngine = WineEngineLocator.engineRoot(
            forWineExecutable: URL(fileURLWithPath: baseWine)
        ) else {
            throw NSError(
                domain: "Vessel",
                code: 104,
                userInfo: [NSLocalizedDescriptionKey: "No se pudo localizar el núcleo Wine FOSS para el motor multimedia."]
            )
        }

        let gptk = GPTKManager()
        try await gptk.ensureInstalled(progress: progress)
        let gptkWineRoot = URL(fileURLWithPath: gptk.engineRootPath, isDirectory: true)
            .appendingPathComponent("wine", isDirectory: true)

        let gcenxWine = try await ensureInteractiveSteamEngineInstalled(progress: progress)
        guard let gcenxEngine = WineEngineLocator.engineRoot(
            forWineExecutable: URL(fileURLWithPath: gcenxWine)
        ) else {
            throw NSError(
                domain: "Vessel",
                code: 105,
                userInfo: [NSLocalizedDescriptionKey: "No se pudo localizar winegstreamer en el motor de Steam."]
            )
        }

        _ = try await ManagedGStreamerRuntime.shared.ensureInstalled(
            enginesDirectory: enginesDirectory,
            progress: progress
        )
        let finalEngine = URL(fileURLWithPath: enginesDirectory, isDirectory: true)
            .appendingPathComponent(WineEngineLocator.d3dmetalMediaEngineName, isDirectory: true)
        return try await D3DMetalMediaEngineProvisioner.ensureInstalled(
            baseEngine: baseEngine,
            gptkWineRoot: gptkWineRoot,
            gcenxEngine: gcenxEngine,
            finalEngine: finalEngine,
            progress: progress
        )
    }

    /// Descarga la build propia de `wine-full` (fuentes CrossOver 26.2.0) de Vessel-Engines.
    private func installWineFull(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        progress("Descargando motor completo (wine-full, fuentes CrossOver 26.2.0)…", 0.05)
        let downloadURL = URL(string: "https://github.com/SwonDev/Vessel-Engines/releases/download/engine-full-v2/wine-full.tar.zst")!
        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Vessel", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Descarga del motor completo falló: HTTP \(http.statusCode)"])
        }

        progress("Extrayendo motor completo…", 0.55)
        let finalEngineDir = "\(enginesDirectory)/\(WineEngineLocator.fullEngineName)"
        let stagingDir = "\(enginesDirectory)/wine-full-installing-\(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: stagingDir)
        try FileManager.default.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: stagingDir)
            try? FileManager.default.removeItem(at: tempURL)
        }

        try await extractTar(at: tempURL, to: URL(fileURLWithPath: stagingDir))

        // El tarball contiene la carpeta `wine-full/` en la raíz → normalizar a finalEngineDir.
        let extractedRoot = "\(stagingDir)/\(WineEngineLocator.fullEngineName)"
        let sourceDir = FileManager.default.isExecutableFile(atPath: "\(extractedRoot)/bin/wine")
            ? extractedRoot : stagingDir
        // Por si una instalación previa dejó algo a medias (el guard de arriba ya cubre el caso sano).
        try? FileManager.default.removeItem(atPath: finalEngineDir)
        try FileManager.default.moveItem(atPath: sourceDir, toPath: finalEngineDir)

        await stripQuarantineRecursive(at: finalEngineDir)
        progress("Firmando el motor completo…", 0.90)
        await adhocSignBinaries(in: finalEngineDir)

        guard FileManager.default.isExecutableFile(atPath: "\(finalEngineDir)/bin/wine") else {
            throw NSError(domain: "Vessel", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Motor completo instalado pero bin/wine no es ejecutable"])
        }
        await applyNet48Fix()   // drop-in: setupapi sin el cuelgue de mscoree/NGen (prefijos .NET real)
        progress("✓ Motor completo (wine-full) listo", 1.0)
    }

    /// Instala **wine-mono** (el runtime de .NET Framework de Wine) en el motor unificado si falta, para
    /// que los juegos .NET Framework arranquen: Wine lo auto-instala en el prefijo desde
    /// `share/wine/mono/`. wine-mono es INDEPENDIENTE de la arquitectura del motor (son ensamblados
    /// .NET/PE de Windows), así que sirve igual para el motor x86_64. Descarga la última estable
    /// (Regla #1: stack a la última) del repo oficial. Idempotente (salta si ya está esa versión) y NO
    /// bloqueante (se lanza en segundo plano: la primera vez baja ~60 MB sin frenar la apertura de Steam).
    func ensureWineMono(version: String = "11.2.0") async {
        let fm = FileManager.default
        let engineDir = "\(enginesDirectory)/\(WineEngineLocator.unifiedEngineName)"
        // Solo si el motor ya está instalado.
        guard fm.fileExists(atPath: "\(engineDir)/lib/wine/x86_64-unix") else { return }
        let monoParent = "\(engineDir)/share/wine/mono"
        let monoDir = "\(monoParent)/wine-mono-\(version)"
        if fm.fileExists(atPath: monoDir) { return }   // ya instalado
        guard let url = URL(string: "https://github.com/wine-mono/wine-mono/releases/download/wine-mono-\(version)/wine-mono-\(version)-x86.tar.xz") else { return }
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            defer { try? fm.removeItem(at: tmp) }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                LogStore.shared.log("No se pudo descargar wine-mono \(version) (HTTP \(http.statusCode)).", level: .warn); return
            }
            try? fm.createDirectory(atPath: monoParent, withIntermediateDirectories: true)
            // Extraer el .tar.xz en share/wine/mono/ (crea wine-mono-<version>/). tar de macOS lee xz.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xJf", tmp.path, "-C", monoParent]
            try p.run(); p.waitUntilExit()
            if fm.fileExists(atPath: monoDir) {
                LogStore.shared.log("wine-mono \(version) instalado en el motor (juegos .NET Framework).", level: .info)
            }
        } catch {
            LogStore.shared.log("wine-mono no se pudo instalar: \(error.localizedDescription)", level: .warn)
        }
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
        let engineDir = "\(enginesDirectory)/\(WineEngineLocator.unifiedEngineName)"
        let unixDir = "\(engineDir)/lib/wine/x86_64-unix"
        guard fm.fileExists(atPath: "\(unixDir)/win32u.so") else { return }
        guard let resDir = Bundle.main.resourceURL?.appendingPathComponent("engine-steamfix").path,
              fm.fileExists(atPath: "\(resDir)/win32u.so") else { return }
        // Marcador de VERSIÓN (no tamaño): el `winemac.so` con el fix de fullscreen de juegos pesa
        // casi lo mismo que el original, así que un chequeo por tamaño no lo detectaría. Con el
        // marcador re-aplicamos solo cuando cambia la versión del fix (o si el motor se re-descarga
        // y pierde el marcador). Bump de versión = obliga a re-aplicar en instalaciones existentes.
        let marker = "\(engineDir)/.vessel-steam-render-fix"
        let fixVersion = "v2-winemac-game-fullscreen"
        let current = (try? String(contentsOfFile: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == fixVersion { return }

        var applied = false
        // win32u (render CEF por DXMT) + bcrypt/secur32 (login ECDSA) + winemac (fullscreen de
        // juegos: reescala el client_view Metal al ir la ventana a pantalla completa).
        for so in ["win32u.so", "bcrypt.so", "secur32.so", "winemac.so"] {
            let src = "\(resDir)/\(so)", dst = "\(unixDir)/\(so)"
            guard fm.fileExists(atPath: src) else { continue }
            try? fm.removeItem(atPath: dst)
            if (try? fm.copyItem(atPath: src, toPath: dst)) != nil { applied = true }
        }
        if applied {
            await stripQuarantineRecursive(at: unixDir)
            await adhocSignBinaries(in: unixDir)
            try? fixVersion.write(toFile: marker, atomically: true, encoding: .utf8)
            LogStore.shared.log("Fix de render/conexión de Steam + fullscreen de juegos aplicado al motor unificado.", level: .info)
        }
    }

    /// **Repara el lanzador (`bin/wine`) del motor completo** para que winetricks pueda usarlo.
    ///
    /// El `bin/wine` de `wine-full` es un shim: traduce `wine <args>` →
    /// `wineloader winewrapper.exe --run -- <args>`. Le faltaban dos cosas que winetricks da por
    /// hechas, y sin ellas **no instalaba NADA** en este motor — que es justo el de los juegos de
    /// 32-bit, D3D9, DirectDraw y Unity. O sea: la auto-reparación de runtimes (VC++/.NET) estaba
    /// muerta ahí, en silencio.
    ///
    ///  1. **`wine --version`**: el shim se lo pasaba al winewrapper, que no es quien responde eso.
    ///     winetricks no obtenía versión ("Your version of wine  is no longer supported") y se
    ///     rendía. Ahora se responde con el formato real (`wine-11.0`), vía el wineserver del motor.
    ///  2. **Rutas relativas**: el winewrapper NO resuelve un `.exe` relativo contra el directorio
    ///     actual (`cannot execute`). winetricks hace `cd` a su caché y llama al instalador por su
    ///     nombre, así que fallaba siempre. Con la ruta absoluta, el MISMO instalador arranca.
    ///  3. **`bin/wine64`**: en un prefijo de 64 bits winetricks usa `<dir>/wine64`, que no existía
    ///     → comando vacío → abortaba. En el WoW64 moderno `wine` y `wine64` son el mismo loader,
    ///     así que basta un enlace.
    ///
    /// Verificado end-to-end: con esto `winetricks dotnet48` instala el .NET Framework 4.8 REAL
    /// (mscorlib de 5,4 MB, no los 752 KB de wine-mono) y FEZ renderiza.
    func repairFullEngineShim() async {
        let fm = FileManager.default
        let engineDir = "\(enginesDirectory)/\(WineEngineLocator.fullEngineName)"
        let shim = "\(engineDir)/bin/wine"
        guard fm.fileExists(atPath: "\(engineDir)/bin/wineloader"), fm.fileExists(atPath: shim) else { return }

        let marker = "\(engineDir)/.vessel-shim-version"
        let version = "v2-version-y-rutas-relativas"
        if (try? String(contentsOfFile: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == version { return }

        let script = """
        #!/bin/sh
        # Lanzador del motor Wine COMPLETO de Vessel. Traduce `wine <args>` →
        # `wineloader winewrapper.exe --run -- <args>` y fija el entorno del motor. La raíz se deriva
        # de $0 con expansión de parámetros (builtin), SIN `dirname`: cuando Vessel lanza con `env -i`
        # no hay PATH y `dirname` no se encontraría.
        SELF="$0"
        BIN_DIR="${SELF%/*}"
        HERE="${BIN_DIR%/*}"
        export WINELOADER="$HERE/bin/wineloader"
        export WINESERVER="$HERE/bin/wineserver"
        export WINEDLLPATH="$HERE/lib/wine/x86_64-windows:$HERE/lib/wine/i386-windows:$HERE/lib/wine"

        # `--version` es una pregunta al motor, no un programa: no puede ir al winewrapper. winetricks
        # arranca preguntándola y, sin respuesta, se rinde sin instalar nada.
        case "$1" in
            --version|-v)
                v=$("$HERE/bin/wineserver" --version 2>/dev/null | sed 's/^Wine /wine-/')
                echo "${v:-wine-11.0}"
                exit 0
                ;;
        esac

        # El winewrapper no resuelve rutas relativas contra el directorio actual (`cannot execute`).
        # Solo se toca el primer argumento, y solo si de verdad es un archivo de este directorio:
        # `wine cmd.exe /c …` y `wine C:\\ruta\\x.exe` siguen intactos (los resuelve el wrapper).
        prog="$1"
        case "$prog" in
            -*|"") ;;
            /*)    ;;
            *)     if [ -f "$PWD/$prog" ]; then shift; set -- "$PWD/$prog" "$@"; fi ;;
        esac

        exec "$HERE/bin/wineloader" "$HERE/lib/wine/x86_64-windows/winewrapper.exe" --run -- "$@"
        """
        // El original se guarda una vez, por si hubiera que volver atrás sin re-descargar el motor.
        let backup = "\(shim).vessel-orig"
        if !fm.fileExists(atPath: backup) { try? fm.copyItem(atPath: shim, toPath: backup) }
        guard (try? script.write(toFile: shim, atomically: true, encoding: .utf8)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim)
        // `wine64`: mismo loader (WoW64 moderno). winetricks lo exige en prefijos de 64 bits.
        let wine64 = "\(engineDir)/bin/wine64"
        if !fm.fileExists(atPath: wine64) {
            try? fm.createSymbolicLink(atPath: wine64, withDestinationPath: "wine")
        }
        try? version.write(toFile: marker, atomically: true, encoding: .utf8)
        LogStore.shared.log("Motor completo: lanzador reparado (winetricks ya puede instalar runtimes en él).", level: .info)
    }

    /// **Motor v3** — actualiza en caliente la cadena crypto + fuentes del motor unificado a la
    /// última versión, SIN re-descargar el motor entero (~2 GB). Igual que `applySteamRenderFix`,
    /// copia unas librerías bundleadas (`Resources/engine-cryptofix/`, ~8 MB) al `lib/` del motor,
    /// gated por un marcador de versión (bump = re-aplica en instalaciones existentes). Todas son
    /// x86_64 con deps `@loader_path` (drop-in) y fueron validadas: gnutls 3.8.13 negocia TLS 1.3 +
    /// ECDHE real contra los servidores de Steam, y freetype 2.14.3 carga en el motor.
    ///
    /// - **gnutls 3.8.13** (+ **nettle 4.0** / **hogweed**): TLS/seguridad al día para el login de
    ///   Steam (Wine la usa vía `bcrypt`/`secur32`). nettle 4.0 (`libnettle.9`/`libhogweed.7`) se
    ///   **añade** junto a la vieja 3.9 del motor, sin pisarla (coexisten por soname).
    /// - **freetype 2.14.3**: render de fuentes del cliente CEF y de las apps Windows. ABI estable
    ///   (soname 6), misma feature set que la 2.13.3 previa (zlib+bz2+png+brotli, sin harfbuzz).
    /// **Fix de DirectDraw** — instala en `wine-full` una `ddraw.dll` parcheada que no le quita sus
    /// superficies a un juego que manda en la pantalla. Drop-in de ~6 MB con marcador de versión,
    /// igual que `applyCryptoFix`: llega a las instalaciones existentes sin re-subir el motor.
    ///
    /// El bug (WineHQ 11.10, `dlls/ddraw/ddraw.c`): `SetDisplayMode` marcaba el device como
    /// `NOT_RESTORED` **siempre**, incluso cuando el cambio de modo salía bien y aunque la app
    /// tuviera nivel de cooperación EXCLUSIVO. El siguiente `CreateSurface` daba entonces por
    /// perdidas las superficies YA creadas, y todo `Flip` devolvía `DDERR_SURFACELOST`. Un juego que
    /// nunca llama a `Restore()` —normal en los 90, porque en Windows nadie le quitaba nada— se
    /// queda en **negro para siempre**. Reproducido con War Wind (1996): crea sus superficies a
    /// 640×480 y cambia a 320×240 para su intro. Parcheado, su menú aparece y responde.
    ///
    /// El parche (`docs/wine-patches/0002-*`) solo conserva el comportamiento antiguo **fuera** de
    /// modo exclusivo, que es donde tiene sentido: ahí manda el escritorio, no la app.
    func applyDDrawFix() async {
        let fm = FileManager.default
        let engineDir = "\(enginesDirectory)/\(WineEngineLocator.fullEngineName)"
        guard fm.fileExists(atPath: "\(engineDir)/lib/wine/i386-windows/ddraw.dll") else { return }
        guard let resDir = Bundle.main.resourceURL?.appendingPathComponent("engine-ddrawfix").path,
              fm.fileExists(atPath: "\(resDir)/i386-windows/ddraw.dll") else { return }

        let marker = "\(engineDir)/.vessel-ddraw-fix"
        let fixVersion = "v1-setdisplaymode-no-pierde-superficies"
        let current = (try? String(contentsOfFile: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if current == fixVersion { return }

        var applied = false
        for arch in ["i386-windows", "x86_64-windows"] {
            let src = "\(resDir)/\(arch)/ddraw.dll"
            let dst = "\(engineDir)/lib/wine/\(arch)/ddraw.dll"
            guard fm.fileExists(atPath: src), fm.fileExists(atPath: dst) else { continue }
            // El original se guarda una sola vez: si algo saliera mal, el motor es recuperable
            // sin volver a descargarlo.
            let backup = "\(dst).vessel-orig"
            if !fm.fileExists(atPath: backup) { try? fm.copyItem(atPath: dst, toPath: backup) }
            try? fm.removeItem(atPath: dst)
            if (try? fm.copyItem(atPath: src, toPath: dst)) != nil { applied = true }
        }
        if applied {
            await stripQuarantineRecursive(at: engineDir)
            try? fixVersion.write(toFile: marker, atomically: true, encoding: .utf8)
            LogStore.shared.log("DirectDraw: instalada la ddraw parcheada (los juegos de los 90 ya no se quedan en negro).", level: .info)
        }
    }

    /// **Fix NGen/mscorsvw (prefijos .NET real)** — instala en `wine-full` una `setupapi.dll`
    /// parcheada que NO llama a `DllRegisterServer` de un `mscoree.dll` NATIVO (el de Microsoft
    /// que deja `winetricks dotnet4x`). Drop-in con marcador de versión, como `applyDDrawFix`.
    ///
    /// El bug (verificado en vivo, también con el CrossOver real): `wineboot -u` re-registra
    /// las DLL del prefijo en Wow64Install; al llegar a `mscoree.dll` nativo, su
    /// `DllRegisterServer` arranca el servicio de optimización del CLR (`mscorsvw.exe`, NGen),
    /// que nunca queda listo bajo Wine → `wineboot -u` se BLOQUEA para siempre y cada lanzamiento
    /// FNA/XNA tardaba el timeout (~1 min) con "prefijo en mal estado", dejaba servicios zombi
    /// y a veces el juego (FEZ) ni abría ventana. Con la `setupapi` parcheada, `wineboot -u`
    /// completa en ~23 s y FEZ/Terraria abren al instante. El `mscoree` BUILTIN de Wine (el de
    /// wine-mono) sí se sigue registrando. Parche: `docs/wine-patches/0003-…`. Verificado con
    /// FEZ y Terraria (prefijo `__net48` con dotnet48 real).
    func applyNet48Fix() async {
        let fm = FileManager.default
        let engineDir = "\(enginesDirectory)/\(WineEngineLocator.fullEngineName)"
        guard fm.fileExists(atPath: "\(engineDir)/lib/wine/i386-windows/setupapi.dll") else { return }
        guard let resDir = Bundle.main.resourceURL?.appendingPathComponent("engine-net48fix").path,
              fm.fileExists(atPath: "\(resDir)/i386-windows/setupapi.dll") else { return }

        let marker = "\(engineDir)/.vessel-net48-fix"
        let fixVersion = "v1-setupapi-no-registrar-mscoree-nativo"
        let current = (try? String(contentsOfFile: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if current == fixVersion { return }

        var applied = false
        for arch in ["i386-windows", "x86_64-windows"] {
            let src = "\(resDir)/\(arch)/setupapi.dll"
            let dst = "\(engineDir)/lib/wine/\(arch)/setupapi.dll"
            guard fm.fileExists(atPath: src), fm.fileExists(atPath: dst) else { continue }
            // El original se guarda una sola vez: si algo saliera mal, el motor es recuperable
            // sin volver a descargarlo.
            let backup = "\(dst).vessel-orig"
            if !fm.fileExists(atPath: backup) { try? fm.copyItem(atPath: dst, toPath: backup) }
            try? fm.removeItem(atPath: dst)
            if (try? fm.copyItem(atPath: src, toPath: dst)) != nil { applied = true }
        }
        if applied {
            await stripQuarantineRecursive(at: engineDir)
            try? fixVersion.write(toFile: marker, atomically: true, encoding: .utf8)
            LogStore.shared.log("Prefijos .NET real: setupapi parcheada (wineboot ya no se cuelga registrando el mscoree de Microsoft).", level: .info)
        }
    }

    func applyCryptoFix() async {
        let fm = FileManager.default
        let engineDir = "\(enginesDirectory)/\(WineEngineLocator.unifiedEngineName)"
        let libDir = "\(engineDir)/lib"
        guard fm.fileExists(atPath: "\(libDir)/libgnutls.30.dylib") else { return }  // solo si el motor está
        guard let resDir = Bundle.main.resourceURL?.appendingPathComponent("engine-cryptofix").path,
              fm.fileExists(atPath: "\(resDir)/libgnutls.30.dylib") else { return }

        let marker = "\(engineDir)/.vessel-crypto-fix"
        let fixVersion = "v3-gnutls3.8.13-nettle4.0-freetype2.14.3"
        let current = (try? String(contentsOfFile: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == fixVersion { return }

        var applied = false
        // gnutls/freetype REEMPLAZAN los del motor; nettle.9/hogweed.7 se AÑADEN (nettle 4.0).
        for dylib in ["libgnutls.30.dylib", "libgnutls.dylib",
                      "libnettle.9.dylib", "libhogweed.7.dylib",
                      "libfreetype.6.dylib", "libfreetype.dylib"] {
            let src = "\(resDir)/\(dylib)", dst = "\(libDir)/\(dylib)"
            guard fm.fileExists(atPath: src) else { continue }
            try? fm.removeItem(atPath: dst)
            if (try? fm.copyItem(atPath: src, toPath: dst)) != nil { applied = true }
        }
        if applied {
            await stripQuarantineRecursive(at: libDir)
            await adhocSignBinaries(in: libDir)
            try? fixVersion.write(toFile: marker, atomically: true, encoding: .utf8)
            LogStore.shared.log("Motor v3: cadena crypto (gnutls 3.8.13 + nettle 4.0) y freetype 2.14.3 aplicadas al motor unificado.", level: .info)
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

    private nonisolated static func filesHaveSameSHA256(_ first: String, _ second: String) -> Bool {
        guard let firstData = try? Data(contentsOf: URL(fileURLWithPath: first), options: .mappedIfSafe),
              let secondData = try? Data(contentsOf: URL(fileURLWithPath: second), options: .mappedIfSafe)
        else { return false }
        return SHA256.hash(data: firstData) == SHA256.hash(data: secondData)
    }

    private func runCapture(executable: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { cont in
            // SIEMPRE fuera del hilo principal: `waitUntilExit()` corre un runloop anidado que, en el
            // main thread, puede interferir con el ciclo de render de SwiftUI → EXC_BAD_ACCESS.
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
