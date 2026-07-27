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

    /// Variante OpenGL legado/core aislada para motores que mezclan APIs de compatibilidad
    /// (GL_QUADS, VAO 0 y formatos ALPHA/LUMINANCE) con GLSL moderno. Es un clon COW del
    /// `wine-unified` con `winemac.so` y `opengl32.so` compilados desde la misma WineHQ 11.10.
    /// Los adaptadores permanecen completamente inertes salvo que el lanzamiento estructural
    /// active `VESSEL_FORCE_CORE_GL_CTX=1`, por lo que nunca se aplica a otro juego ni al cliente
    /// de Steam. `DependencyManager.ensureUnifiedLegacyOpenGLEngine` lo crea y autorrepara.
    static let unifiedLegacyOpenGLEngineName = "wine-unified-opengl-legacy"

    /// Motor D3DMetal propio: el UNIFICADO (WineHQ 11.10) **+ D3DMetal de Apple trasplantado**
    /// (D3D12→Metal) sobre el modelo de `%gs` de CrossOver (nunca mueve el GSBASE; TEB por
    /// indirección `%gs:0x30`) para que los hilos nativos de D3DMetal no crasheen bajo Rosetta,
    /// + la tabla `macdrv_functions` portada al `winemac.so` (para que D3DMetal presente a ventana).
    /// Resultado: UN solo motor libre que corre **a la vez** el CEF de Steam (login), los juegos
    /// **D3D12 por D3DMetal** y los D3D11 por DXMT — exactamente lo que hace CrossOver con su Wine
    /// propietario. Se prefiere para juegos **D3D12 + DRM real de Steam** (Steam y juego en el MISMO
    /// wineserver). Si no está instalado, se cae a GPTK/D3DMetal (que no corre el CEF moderno).
    static let d3dmetalEngineName = "wine-d3dmetal"

    /// Variante aislada para juegos D3D12 que importan Media Foundation. Parte del núcleo FOSS
    /// `wine-full`, superpone el par PE/Unix de D3DMetal y añade winegstreamer con un GStreamer
    /// privado verificado. No modifica `wine-d3dmetal` ni ningún motor compartido.
    static let d3dmetalMediaEngineName = "wine-d3dmetal-media"

    /// Motor experimental y aislado del cliente Steam, conservado como laboratorio del compositor
    /// CEF. La ruta de producción interactiva usa `wine-osx64`: la build moderna de Steam quedó
    /// validada píxel a píxel con Gcenx + `--disable-gpu --single-process`, mientras este clon del
    /// unificado reinicia `steamwebhelper` con `0x80000003`. No se usa para el DRM de los juegos.
    static let steamEngineName = "wine-steam"

    /// Motor Wine **COMPLETO** y autocontenido de Vessel (`wine-full`): un único Wine moderno
    /// (wine-11.0 + CW HACKs: msync, winemac, wined3d) para las rutas que lo necesitan
    /// (UE4, FNA/XNA con .NET real, Source, Godot+Vulkan, D3D9/Unity de 32-bit, DirectDraw).
    ///
    /// Se descarga exclusivamente desde `SwonDev/Vessel-Engines` y contiene el loader Mach-O
    /// estándar de Wine. Una copia de un runtime externo no se considera una instalación válida:
    /// Vessel nunca lo invoca ni depende de que otra aplicación esté instalada en el Mac.
    static let fullEngineName = "wine-full"

    /// Únicas raíces de Wine que una referencia persistida puede seleccionar. Las variantes GPTK
    /// contienen el loader en un subdirectorio `wine/`, pero siguen estando encapsuladas bajo una
    /// de estas raíces directas de `Engines/`.
    private static let managedWineEngineNames: Set<String> = [
        portableEngineName,
        dxmtEngineName,
        mousefixEngineName,
        unifiedEngineName,
        unifiedOpenGLEngineName,
        unifiedLegacyOpenGLEngineName,
        d3dmetalEngineName,
        d3dmetalMediaEngineName,
        steamEngineName,
        fullEngineName,
        "gptk-mythic",
        "gptk-mythic-mousefix"
    ]

    /// True si la ruta pertenece al motor Wine COMPLETO (`wine-full`), que se lanza vía `wineloader`.
    static func isFullEngine(_ winePath: String) -> Bool {
        winePath.contains("/\(fullEngineName)/")
    }

    /// Raíz del motor COMPLETO (`wine-full`), exista o no.
    static func fullEngineDir(enginesDirectory: String = VesselPaths.enginesDirectory) -> String {
        URL(fileURLWithPath: enginesDirectory).appendingPathComponent(fullEngineName).path
    }

    /// Binario `wine` nativo del motor COMPLETO (`wine-full`), o `nil` si no está instalado o si la
    /// carpeta contiene marcadores de un runtime externo no redistribuible.
    static func fullWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        guard !containsExternalFullEngineRuntime(enginesDirectory: enginesDirectory) else { return nil }
        let p = URL(fileURLWithPath: fullEngineDir(enginesDirectory: enginesDirectory))
            .appendingPathComponent("bin/wine").path
        return FileManager.default.isExecutableFile(atPath: p)
            && isManagedRuntimePath(p, enginesDirectory: enginesDirectory) ? p : nil
    }

    /// True si el motor COMPLETO está instalado (tiene el shim `bin/wine`).
    static func isFullEngineInstalled(enginesDirectory: String = VesselPaths.enginesDirectory) -> Bool {
        fullWineBinary(enginesDirectory: enginesDirectory) != nil
    }

    /// Detecta una copia heredada de un runtime externo. `winewrapper.exe` no forma parte de las
    /// fuentes públicas ni del motor de Vessel; su presencia invalida la carpeta completa para
    /// impedir que una instalación local de terceros se convierta en una dependencia accidental.
    static func containsExternalFullEngineRuntime(
        enginesDirectory: String = VesselPaths.enginesDirectory
    ) -> Bool {
        let wrapper = URL(fileURLWithPath: fullEngineDir(enginesDirectory: enginesDirectory))
            .appendingPathComponent("lib/wine/x86_64-windows/winewrapper.exe").path
        return FileManager.default.fileExists(atPath: wrapper)
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
        wineBinary(in: name, enginesDirectory: enginesDirectory) != nil
    }

    /// True si la ruta de Wine pertenece al motor unificado propio (`wine-unified`) o a sus
    /// variantes OpenGL (`wine-unified-opengl` y `wine-unified-opengl-legacy`). Comparten base
    /// (WineHQ 11.10 + DXMT) y el mismo modelo de entorno (MF off, `WINEMSYNC=0`), así que para el
    /// gating de entorno cuentan igual.
    static func isUnifiedEngine(_ winePath: String) -> Bool {
        winePath.contains("/\(unifiedEngineName)/") || winePath.contains("/\(unifiedOpenGLEngineName)/")
            || winePath.contains("/\(unifiedLegacyOpenGLEngineName)/")
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

    /// Binario Wine del motor OpenGL legado/core, o `nil` si aún no se ha preparado.
    static func legacyOpenGLGameWineBinary(
        enginesDirectory: String = VesselPaths.enginesDirectory
    ) -> String? {
        guard engineHasWineBinary(
            unifiedLegacyOpenGLEngineName,
            enginesDirectory: enginesDirectory
        ) else { return nil }
        return wineBinary(
            in: unifiedLegacyOpenGLEngineName,
            enginesDirectory: enginesDirectory
        )
    }

    /// True si la ruta de Wine pertenece a uno de los motores D3DMetal propios.
    static func isD3DMetalEngine(_ winePath: String) -> Bool {
        winePath.contains("/\(d3dmetalEngineName)/")
            || winePath.contains("/\(d3dmetalMediaEngineName)/")
    }

    /// True únicamente para el perfil D3DMetal con Media Foundation funcional.
    static func isD3DMetalMediaEngine(_ winePath: String) -> Bool {
        winePath.contains("/\(d3dmetalMediaEngineName)/")
    }

    /// True si la ruta de Wine pertenece al **GPTK/D3DMetal de Apple** (`gptk-mythic` o su
    /// variante `gptk-mythic-mousefix`). Mismo modelo de contexto que DXMT/D3DMetal: desde la
    /// app (hijo directo con herencia de bundle) el device Metal no se crea y el juego muere
    /// al instante — necesita el lanzamiento con entorno LIMPIO. Verificado con Dwarven Realms
    /// (UE5): a mano y vía env -i abre hasta el menú; desde la app moría sin dejar log.
    static func isGPTKEngine(_ winePath: String) -> Bool {
        winePath.contains("/gptk-mythic/") || winePath.contains("/gptk-mythic-mousefix/")
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

    /// Binario del motor D3DMetal + multimedia, o `nil` si aún no se ha aprovisionado.
    static func d3dmetalMediaWineBinary(
        enginesDirectory: String = VesselPaths.enginesDirectory
    ) -> String? {
        wineBinary(in: d3dmetalMediaEngineName, enginesDirectory: enginesDirectory)
    }

    /// Binario Wine del motor DEDICADO del cliente de Steam (`wine-steam`), o `nil` si no está.
    /// Es el que usa `openSteamClient` para abrir Steam APARTE (cliente + biblioteca + tienda), sin
    /// tocar los motores de juegos. Si falta, `openSteamClient` cae a `clientWineBinary` (unificado).
    static func steamDedicatedWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        wineBinary(in: steamEngineName, enginesDirectory: enginesDirectory)
    }

    /// Motor del cliente Steam que el usuario debe poder VER y manejar (login, EULA, tienda).
    ///
    /// Es deliberadamente distinto de `clientWineBinary`: el cliente invisible de DRM debe correr
    /// en el mismo wineserver que cada juego, pero CEF solo ha quedado validado con píxeles completos
    /// en Gcenx (`wine-osx64`) y composición por software. Mantener esta resolución explícita evita
    /// que instalar `wine-unified` cambie silenciosamente el motor de la interfaz y reintroduzca una
    /// ventana negra o un webhelper en bucle.
    static func interactiveSteamWineBinary(
        enginesDirectory: String = VesselPaths.enginesDirectory
    ) -> String? {
        wineBinary(in: portableEngineName, enginesDirectory: enginesDirectory)
    }

    /// Binario Wine del motor del CLIENTE de Steam (unificado si está, si no Gcenx).
    static func clientWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        wineBinary(in: resolvedClientEngineName(enginesDirectory: enginesDirectory), enginesDirectory: enginesDirectory)
    }

    /// Binario Wine del motor de JUEGOS D3D11 (prefiere `wine-dxmt-mousefix`).
    static func gameWineBinary(enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        wineBinary(in: resolvedGameEngineName(enginesDirectory: enginesDirectory), enginesDirectory: enginesDirectory)
    }

    /// Ruta por defecto para una botella nueva. Siempre pertenece al inventario privado de Vessel;
    /// si todavía no hay un motor instalado devuelve el destino canónico que aprovisionará
    /// `DependencyManager`, nunca una instalación global de Wine.
    static func defaultManagedWinePath(
        enginesDirectory: String = VesselPaths.enginesDirectory
    ) -> String {
        gameWineBinary(enginesDirectory: enginesDirectory)
            ?? clientWineBinary(enginesDirectory: enginesDirectory)
            ?? URL(fileURLWithPath: enginesDirectory, isDirectory: true)
                .appendingPathComponent(unifiedEngineName, isDirectory: true)
                .appendingPathComponent("bin/wine")
                .path
    }

    /// Normaliza rutas persistidas por versiones antiguas. Cualquier Wine fuera de `Engines/`
    /// convertiría la disponibilidad de Homebrew, CrossOver u otra app en una dependencia implícita.
    /// La migración solo cambia la referencia guardada; no borra ni modifica datos externos.
    static func repairedStoredWinePath(
        _ storedPath: String,
        enginesDirectory: String = VesselPaths.enginesDirectory
    ) -> String {
        guard isManagedRuntimePath(storedPath, enginesDirectory: enginesDirectory) else {
            return defaultManagedWinePath(enginesDirectory: enginesDirectory)
        }
        return storedPath
    }

    /// Comprueba pertenencia real al inventario privado de Vessel. Resuelve enlaces simbólicos para
    /// que una ruta con apariencia de `Engines/wine-*/...` no pueda escapar a otra aplicación, y
    /// exige que el primer componente sea una familia de motor conocida (nunca una copia de respaldo
    /// ni `ExternalRuntimeQuarantine`). También acepta destinos canónicos aún no aprovisionados.
    static func isManagedRuntimePath(
        _ path: String,
        enginesDirectory: String = VesselPaths.enginesDirectory
    ) -> Bool {
        let enginesRoot = URL(fileURLWithPath: enginesDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootComponents = enginesRoot.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            return false
        }
        return managedWineEngineNames.contains(candidateComponents[rootComponents.count])
    }

    /// Resuelve el binario `wine`/`wine64` dentro de un motor por nombre.
    static func wineBinary(in engineName: String, enginesDirectory: String = VesselPaths.enginesDirectory) -> String? {
        guard managedWineEngineNames.contains(engineName) else { return nil }
        let base = URL(fileURLWithPath: enginesDirectory).appendingPathComponent(engineName)
        for sub in ["bin/wine64", "bin/wine"] {
            let path = base.appendingPathComponent(sub).path
            if FileManager.default.isExecutableFile(atPath: path),
               isManagedRuntimePath(path, enginesDirectory: enginesDirectory) {
                return path
            }
        }
        guard let nested = findExecutable(named: ["wine64", "wine"], under: base),
              isManagedRuntimePath(nested, enginesDirectory: enginesDirectory) else {
            return nil
        }
        return nested
    }

    /// True si la ruta de Wine pertenece a un motor de juegos DXMT
    /// (`wine-dxmt` o su variante parcheada `wine-dxmt-mousefix`).
    static func isGameEngine(_ winePath: String) -> Bool {
        winePath.contains("/\(mousefixEngineName)/") || winePath.contains("/\(dxmtEngineName)/")
            || winePath.contains("/\(unifiedEngineName)/") || winePath.contains("/\(unifiedOpenGLEngineName)/")
            || winePath.contains("/\(unifiedLegacyOpenGLEngineName)/")
            || winePath.contains("/\(d3dmetalMediaEngineName)/")
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
            if FileManager.default.isExecutableFile(atPath: path),
               isManagedRuntimePath(path, enginesDirectory: enginesDirectory) {
                return path
            }
        }

        guard let nested = findExecutable(
            named: ["wine64", "wine"],
            under: portableEngineDirectory(enginesDirectory: enginesDirectory)
        ), isManagedRuntimePath(nested, enginesDirectory: enginesDirectory) else {
            return nil
        }
        return nested
    }

    static func detectWineInstallations(
        enginesDirectory: String = VesselPaths.enginesDirectory,
        homeDirectory: String = NSHomeDirectory()
    ) -> [(name: String, path: String, version: String)] {
        // `homeDirectory` se conserva para mantener estable la API usada por diagnósticos y tests.
        // El inventario de producción solo expone motores gestionados por Vessel: ni Homebrew, ni
        // GPTK instalado globalmente, ni runtimes contenidos en otras aplicaciones pueden convertirse
        // en una dependencia accidental o cambiar el comportamiento entre dos Macs.
        _ = homeDirectory
        var results: [(name: String, path: String, version: String)] = []
        var seen: Set<String> = []

        if let portable = findPortableWineBinary(enginesDirectory: enginesDirectory) {
            results.append(("Wine (Vessel portable)", portable, "Auto"))
            seen.insert(portable)
        }

        let managedCandidates: [(String, String)] = [
            ("Wine unificado de Vessel", unifiedEngineName),
            ("Wine DXMT de Vessel", mousefixEngineName),
            ("Wine DXMT de Vessel", dxmtEngineName),
            ("Wine D3DMetal de Vessel", d3dmetalEngineName),
            ("Wine D3DMetal multimedia de Vessel", d3dmetalMediaEngineName),
            ("Wine OpenGL de Vessel", unifiedOpenGLEngineName),
            ("Wine OpenGL legado de Vessel", unifiedLegacyOpenGLEngineName),
            ("Wine Steam de Vessel", steamEngineName),
            ("Wine completo de Vessel", fullEngineName),
            ("GPTK de Vessel", "gptk-mythic-mousefix"),
            ("GPTK de Vessel", "gptk-mythic")
        ]
        for (name, engineName) in managedCandidates {
            let path = engineName == fullEngineName
                ? fullWineBinary(enginesDirectory: enginesDirectory)
                : wineBinary(in: engineName, enginesDirectory: enginesDirectory)
            guard let path, seen.insert(path).inserted else { continue }
            results.append((name, path, "Gestionado"))
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
