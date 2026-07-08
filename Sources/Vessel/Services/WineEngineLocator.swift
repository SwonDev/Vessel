import Foundation

enum WineEngineLocator {
    static let portableEngineName = "wine-osx64"
    /// Motor Wine con soporte DXMT (3Shain/wine v9.9-mingw). Necesario para
    /// que juegos D3D11 rendericen en Apple Silicon via Metal nativo.
    static let dxmtEngineName = "wine-dxmt"
    /// Variante de `wine-dxmt` con el parche del ratón de Unity 6
    /// (`EnableMouseInPointer` → `WM_POINTER`). Es un `wine-dxmt` IDÉNTICO con
    /// SOLO `win32u.so` reemplazado por una versión parcheada compilada desde la
    /// MISMA versión de Wine (9.9) → mismo ABI, todas las piezas de DXMT
    /// (winemetal/d3d11) intactas. Sin el fix, los juegos Unity 6 llaman a
    /// `EnableMouseInPointer`, Wine lo tiene como stub y el ratón queda muerto
    /// (caen a `Windows.Gaming.Input`). El parche es inerte para juegos que NO
    /// llaman a esa API, así que es seguro usarlo como motor de juegos por
    /// defecto. Se prefiere si está presente; si no, se usa `wine-dxmt`.
    static let mousefixEngineName = "wine-dxmt-mousefix"

    /// Motor UNIFICADO propio de Vessel: **DXMT compilado sobre WineHQ Wine 11.10**
    /// (build propio, x86_64 bajo Rosetta). A diferencia de `wine-dxmt` (3Shain,
    /// Wine 9.9), es Wine MODERNO con `winemac.drv` completo + DXMT integrado en su
    /// builtin (`d3d11`/`dxgi`/`winemetal`), y con el parche propio
    /// `macdrv_dxmt_get_client_view` que arregla la pantalla negra de DXMT en Wine 11
    /// (el `client_view` del área cliente es perezoso en Wine 11 → se crea/engancha
    /// bajo demanda). Objetivo: un solo motor libre que corra el CEF de Steam Y los
    /// juegos por Metal (lo que hace CrossOver con Wine propietario). Si está
    /// instalado se prefiere para juegos D3D11. Requiere `RetinaMode` para render a
    /// resolución física completa en pantallas Retina (ver `WineManager`).
    static let unifiedEngineName = "wine-unified"

    /// Variante del motor UNIFICADO para juegos **OpenGL** (p. ej. Heroes of Hammerwatch II,
    /// motor BGFX/GL propio). Es un clon COW de `wine-unified` IDÉNTICO con SOLO `winemac.so`
    /// reemplazado por una versión parcheada (backport de **CW Hack 24834**): Wine-macOS rechaza
    /// los contextos GL 3.2 core sin `WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB` (→ `ERROR_INVALID_VERSION_ARB`
    /// `0x2095`); el parche inyecta el bit cuando el juego pide `CX_FWD_COMPAT_GL_CTX=1`. El parche
    /// solo actúa con ESA env var → inerte para el resto, PERO `winemac.so` lo carga TODA ventana Wine
    /// (incluido el CEF de Steam), así que se AÍSLA en su propio motor para NO tocar el `wine-unified`
    /// compartido que ya corre el cliente Steam y los juegos D3D11. Se recrea desde `wine-unified` con
    /// `DependencyManager.ensureUnifiedOpenGLEngine` (clon COW + swap del `winemac.so` de Resources).
    static let unifiedOpenGLEngineName = "wine-unified-opengl"

    /// Motor D3DMetal propio: el UNIFICADO (WineHQ 11.10) **+ D3DMetal de Apple trasplantado**
    /// (D3D12→Metal) sobre el modelo de `%gs` de CrossOver (nunca mueve el GSBASE; TEB por
    /// indirección `%gs:0x30`) para que los hilos nativos de D3DMetal no crasheen bajo Rosetta,
    /// + la tabla `macdrv_functions` portada al `winemac.so` (para que D3DMetal presente a ventana).
    /// Resultado: UN solo motor libre que corre **a la vez** el CEF de Steam (login), los juegos
    /// **D3D12 por D3DMetal** y los D3D11 por DXMT — exactamente lo que hace CrossOver con su Wine
    /// propietario. Se prefiere para juegos **D3D12 + DRM real de Steam** (Steam y juego en el MISMO
    /// wineserver). Si no está instalado, se cae a GPTK/D3DMetal (que no corre el CEF moderno).
    static let d3dmetalEngineName = "wine-d3dmetal"

    /// Motor DEDICADO y APARTE para "Abrir Steam (como CrossOver)": clon del unificado (mismo Wine 11
    /// que SÍ renderiza el CEF: cliente + biblioteca) con un `winemac.so` propio que compone TODAS las
    /// sub-superficies del CEF (CW HACK 22435) para que la **TIENDA** también se vea. Es EXCLUSIVO del
    /// cliente de Steam; NO toca los motores de juegos del modo Vessel. La única unión es la biblioteca
    /// instalada (steamapps del prefijo). Si no está, `openSteamClient` cae al unificado normal.
    static let steamEngineName = "wine-steam"

    /// Motor Wine **COMPLETO** de Vessel (`wine-full`): un único Wine moderno con la capa gráfica
    /// DXMT madura (D3D11→Metal, con `nvapi64`/`atidxx64` reales para la detección de GPU que muchos
    /// juegos exigen o abortan con `InitializeEngineGraphics failed`) + D3DMetal de Apple (D3D12→Metal)
    /// + `winemac` completo (fullscreen, ventanas y CEF nativo de fábrica). Corre a la vez el **cliente
    /// Steam** (CEF nativo multiproceso, SIN wrapper, SIN steam.cfg) y **TODOS los juegos** (D3D11 y
    /// D3D12), compartiendo wineserver para el DRM real de Steam. Es **autónomo** (empaquetado en Vessel,
    /// no depende de nada del sistema). ⚠️ A diferencia del resto de motores, se lanza vía
    /// `bin/wineloader` + `lib/wine/x86_64-windows/winewrapper.exe --run --` (ver
    /// `WineManager.launchWineProcess`), NO con `bin/wine`. Si está instalado, es el motor preferido para
    /// el modo Steam (cliente + tienda + juegos). Ver `isFullEngine` / `fullWineLoader` / `fullEngineDir`.
    static let fullEngineName = "wine-full"

    /// True si la ruta pertenece al motor Wine COMPLETO (`wine-full`), que se lanza vía `wineloader`.
    static func isFullEngine(_ winePath: String) -> Bool {
        winePath.contains("/\(fullEngineName)/")
    }

    /// Raíz del motor COMPLETO (`wine-full`), exista o no.
    static func fullEngineDir(enginesDirectory: String = VesselPaths.enginesDirectory) -> String {
        URL(fileURLWithPath: enginesDirectory).appendingPathComponent(fullEngineName).path
    }

    /// Binario `wine` (shim) del motor COMPLETO (`wine-full`), o `nil` si no está instalado. El shim
    /// `bin/wine` traduce `wine <args>` → `wineloader winewrapper.exe --run -- <args>` y fija el
    /// entorno del motor, así que se invoca como cualquier otro motor.
    static func fullWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        let p = URL(fileURLWithPath: fullEngineDir(enginesDirectory: enginesDirectory))
            .appendingPathComponent("bin/wine").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// True si el motor COMPLETO está instalado (tiene el shim `bin/wine`).
    static func isFullEngineInstalled(enginesDirectory: String = VesselPaths.enginesDirectory) -> Bool {
        fullWineBinary(enginesDirectory: enginesDirectory) != nil
    }

    // MARK: - Roles de motor (arquitectura de doble motor)
    //
    // Tras validación empírica en Apple Silicon:
    //  - El CLIENTE de Steam (Chromium/steamwebhelper) solo arranca en un Wine
    //    completo y moderno (Gcenx wine-osx64, p.ej. 11.x). En wine-dxmt el
    //    proceso GPU de CEF revienta (STATUS_BREAKPOINT) y da error 0x3008.
    //  - Los JUEGOS D3D11 (Unity feature level 11_0) solo funcionan con DXMT
    //    (Metal nativo) integrado en wine-dxmt. DXVK no puede (Metal no tiene
    //    geometry shaders → feature level insuficiente) y DXMT externo no carga
    //    en Gcenx por incompatibilidad de ABI del winemetal.so.
    //
    // Por eso Vessel usa DOS motores según la tarea, sobre el mismo prefijo.

    /// Motor para el CLIENTE de Steam y apps generales. Prefiere el UNIFICADO propio
    /// (WineHQ 11.10) si está instalado: corre el CEF de Steam completo (login+teclado+QR+tienda)
    /// con el wrapper SwiftShader + `WINEMSYNC=0`, VALIDADO in-vivo, ademas de los juegos por
    /// DXMT/Metal → un SOLO motor para todo, como CrossOver. Si no está, Gcenx (wine-osx64).
    static func resolvedClientEngineName(enginesDirectory: String = VesselPaths.enginesDirectory) -> String {
        if engineHasWineBinary(unifiedEngineName, enginesDirectory: enginesDirectory) {
            return unifiedEngineName
        }
        return portableEngineName
    }

    static var clientEngineName: String { resolvedClientEngineName() }

    /// Motor para JUEGOS D3D11: wine-dxmt (DXMT builtin → Metal nativo).
    static var gameEngineName: String { dxmtEngineName }

    /// Nombre del motor de JUEGOS efectivo: prefiere el motor parcheado con el fix
    /// del ratón de Unity 6 (`wine-dxmt-mousefix`) si está instalado; si no, el
    /// `wine-dxmt` normal. Ambos son 3Shain/DXMT; el parcheado solo cambia
    /// `win32u.so` (mismo ABI), así que es un reemplazo seguro.
    static func resolvedGameEngineName(enginesDirectory: String = VesselPaths.enginesDirectory) -> String {
        // 1º el motor UNIFICADO propio (WineHQ 11.10 + DXMT) si está instalado: es Wine
        // moderno y su builtin ya trae DXMT (mismo Metal, base más nueva y capaz).
        if engineHasWineBinary(unifiedEngineName, enginesDirectory: enginesDirectory) {
            return unifiedEngineName
        }
        // 2º la variante de wine-dxmt con el fix del ratón de Unity 6.
        if engineHasWineBinary(mousefixEngineName, enginesDirectory: enginesDirectory) {
            return mousefixEngineName
        }
        // 3º wine-dxmt (3Shain, Wine 9.9) base.
        return dxmtEngineName
    }

    /// True si el motor `name` tiene un binario `wine`/`wine64` ejecutable.
    static func engineHasWineBinary(_ name: String, enginesDirectory: String = VesselPaths.enginesDirectory) -> Bool {
        let base = URL(fileURLWithPath: enginesDirectory).appendingPathComponent(name)
        for bin in ["bin/wine", "bin/wine64"] {
            if FileManager.default.isExecutableFile(atPath: base.appendingPathComponent(bin).path) {
                return true
            }
        }
        return false
    }

    /// True si la ruta de Wine pertenece al motor unificado propio (`wine-unified`) o a su
    /// variante OpenGL (`wine-unified-opengl`). Ambos comparten base (WineHQ 11.10 + DXMT) y el
    /// mismo modelo de entorno (MF off, `WINEMSYNC=0`), así que para el gating de env cuentan igual.
    static func isUnifiedEngine(_ winePath: String) -> Bool {
        winePath.contains("/\(unifiedEngineName)/") || winePath.contains("/\(unifiedOpenGLEngineName)/")
            // `wine-steam` (motor DEDICADO del cliente Steam) es un CLON del unificado: hereda TODO su
            // modelo de entorno del CEF (WINEMSYNC=0, DYLD, wrapper, deps, certs). Solo cambia el
            // `winemac.so` (CW HACK 22435 para la tienda). Por eso cuenta como unificado para el gating.
            || winePath.contains("/\(steamEngineName)/")
    }

    /// Binario Wine del motor OpenGL (`wine-unified-opengl`), o `nil` si no está instalado.
    static func openglGameWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        guard engineHasWineBinary(unifiedOpenGLEngineName, enginesDirectory: enginesDirectory) else { return nil }
        return wineBinary(in: unifiedOpenGLEngineName, enginesDirectory: enginesDirectory)
    }

    /// True si la ruta de Wine pertenece al motor D3DMetal propio (`wine-d3dmetal`).
    static func isD3DMetalEngine(_ winePath: String) -> Bool {
        winePath.contains("/\(d3dmetalEngineName)/")
    }

    /// True si el motor corre el **CEF moderno de Steam** con el modelo unificado
    /// (`WINEMSYNC=0` + `DYLD_FALLBACK_LIBRARY_PATH` a su `lib/` para freetype/gnutls, wrapper
    /// SwiftShader, self-update permitido). Lo cumplen tanto el unificado como el D3DMetal
    /// (que es el unificado + D3DMetal). Se usa para compartir la ruta del cliente Steam.
    static func isModernSteamEngine(_ winePath: String) -> Bool {
        isUnifiedEngine(winePath) || isD3DMetalEngine(winePath) || isFullEngine(winePath)
    }

    /// True si el motor D3DMetal propio está instalado (tiene binario `wine`).
    static func isD3DMetalEngineInstalled(enginesDirectory: String = VesselPaths.enginesDirectory) -> Bool {
        engineHasWineBinary(d3dmetalEngineName, enginesDirectory: enginesDirectory)
    }

    /// Binario Wine del motor D3DMetal propio (`wine-d3dmetal`), o `nil` si no está instalado.
    static func d3dmetalWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        wineBinary(in: d3dmetalEngineName, enginesDirectory: enginesDirectory)
    }

    /// Binario Wine del motor DEDICADO del cliente de Steam (`wine-steam`), o `nil` si no está.
    /// Es el que usa `openSteamClient` para abrir Steam APARTE (cliente + biblioteca + tienda), sin
    /// tocar los motores de juegos. Si falta, `openSteamClient` cae a `clientWineBinary` (unificado).
    static func steamDedicatedWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        wineBinary(in: steamEngineName, enginesDirectory: enginesDirectory)
    }

    /// Binario Wine del motor del CLIENTE de Steam (unificado si está, si no Gcenx).
    static func clientWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        wineBinary(in: resolvedClientEngineName(enginesDirectory: enginesDirectory), enginesDirectory: enginesDirectory)
    }

    /// Binario Wine del motor de JUEGOS D3D11 (prefiere `wine-dxmt-mousefix`).
    static func gameWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        wineBinary(in: resolvedGameEngineName(enginesDirectory: enginesDirectory), enginesDirectory: enginesDirectory)
    }

    /// Resuelve el binario `wine`/`wine64` dentro de un motor por nombre.
    static func wineBinary(in engineName: String, enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        let base = URL(fileURLWithPath: enginesDirectory).appendingPathComponent(engineName)
        for sub in ["bin/wine64", "bin/wine"] {
            let path = base.appendingPathComponent(sub).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return findExecutable(named: ["wine64", "wine"], under: base)
    }

    /// True si la ruta de Wine pertenece a un motor de juegos DXMT
    /// (`wine-dxmt` o su variante parcheada `wine-dxmt-mousefix`).
    static func isGameEngine(_ winePath: String) -> Bool {
        winePath.contains("/\(mousefixEngineName)/") || winePath.contains("/\(dxmtEngineName)/")
            || winePath.contains("/\(unifiedEngineName)/") || winePath.contains("/\(unifiedOpenGLEngineName)/")
    }

    static func portableEngineDirectory(enginesDirectory: String = VesselPaths.enginesDirectory) -> URL {
        // Preferir wine-dxmt (3Shain) si está instalado, si no, wine-osx64 (Gcenx).
        let dxmtDir = URL(fileURLWithPath: enginesDirectory).appendingPathComponent(dxmtEngineName)
        if FileManager.default.fileExists(atPath: "\(dxmtDir.path)/bin/wine") {
            return dxmtDir
        }
        return URL(fileURLWithPath: enginesDirectory).appendingPathComponent(portableEngineName)
    }

    static func knownPortableWinePaths(enginesDirectory: String = VesselPaths.enginesDirectory) -> [String] {
        let engineDir = portableEngineDirectory(enginesDirectory: enginesDirectory).path
        return [
            "\(engineDir)/bin/wine64",
            "\(engineDir)/bin/wine"
        ]
    }

    static func findPortableWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        for path in knownPortableWinePaths(enginesDirectory: enginesDirectory) {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return findExecutable(named: ["wine64", "wine"], under: portableEngineDirectory(enginesDirectory: enginesDirectory))
    }

    static func detectWineInstallations(
        enginesDirectory: String = VesselPaths.enginesDirectory,
        homeDirectory: String = NSHomeDirectory()
    ) -> [(name: String, path: String, version: String)] {
        var results: [(name: String, path: String, version: String)] = []

        if let portable = findPortableWineBinary(enginesDirectory: enginesDirectory) {
            results.append(("Wine (Vessel portable)", portable, "Auto"))
        }

        let candidates: [(String, String)] = [
            ("Homebrew Wine", "/opt/homebrew/bin/wine64"),
            ("Homebrew Wine", "/opt/homebrew/bin/wine"),
            ("Homebrew Wine Intel", "/usr/local/bin/wine64"),
            ("Homebrew Wine Intel", "/usr/local/bin/wine"),
            ("Game Porting Toolkit (Apple)", "/Library/Apple/usr/libexec/oah/translation/wine64"),
            ("CrossOver", "\(homeDirectory)/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64"),
            ("CrossOver", "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64")
        ]

        var seen = Set(results.map(\.path))
        for (name, path) in candidates where !seen.contains(path) {
            if FileManager.default.isExecutableFile(atPath: path) {
                results.append((name, path, "Auto"))
                seen.insert(path)
            }
        }

        return results
    }

    static func findExecutable(named names: [String], under directory: URL) -> String? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isExecutableKey]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            if url.pathExtension == "app",
               let bundledWine = findWineInAppBundle(url, executableNames: names) {
                return bundledWine
            }

            guard names.contains(url.lastPathComponent) else { continue }
            if fm.isExecutableFile(atPath: url.path) {
                return url.path
            }
        }

        return nil
    }

    private static func findWineInAppBundle(_ appURL: URL, executableNames: [String]) -> String? {
        let binDirectory = appURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("wine")
            .appendingPathComponent("bin")

        for name in executableNames {
            let candidate = binDirectory.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    static func engineRoot(forWineExecutable wineURL: URL) -> URL? {
        let binDirectory = wineURL.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else { return nil }
        return binDirectory.deletingLastPathComponent()
    }

    @discardableResult
    static func normalizeExtractedEngine(stagingDirectory: URL, finalEngineDirectory: URL) throws -> String {
        guard let winePath = findExecutable(named: ["wine64", "wine"], under: stagingDirectory),
              let engineRoot = engineRoot(forWineExecutable: URL(fileURLWithPath: winePath)) else {
            throw NSError(
                domain: "Vessel",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "La descarga de Wine no contenía un binario wine64/wine válido."]
            )
        }

        let fm = FileManager.default
        try? fm.removeItem(at: finalEngineDirectory)
        try fm.createDirectory(at: finalEngineDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: engineRoot, to: finalEngineDirectory)

        guard let normalizedWinePath = findPortableWineBinary(enginesDirectory: finalEngineDirectory.deletingLastPathComponent().path) else {
            throw NSError(
                domain: "Vessel",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Wine se extrajo, pero Vessel no pudo detectar el motor instalado."]
            )
        }

        return normalizedWinePath
    }
}
