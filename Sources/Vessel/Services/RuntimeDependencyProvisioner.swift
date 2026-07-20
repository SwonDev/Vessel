import Foundation

/// Detecta runtimes de Windows a partir de evidencia real de la instalación y prepara una
/// reparación idempotente. No instala una lista genérica «por si acaso»: inspecciona el ejecutable,
/// DLLs cercanas y archivos de configuración, y devuelve únicamente los verbos compatibles con esa
/// evidencia. Las descargas y su verificación criptográfica siguen centralizadas en `WineManager`.
enum RuntimeDependencyProvisioner {
    enum Dependency: String, CaseIterable, Sendable {
        case visualCpp
        case dotNet
        case directX9Helper
        case d3dCompiler
        case directX10Helper
        case directX11Helper
        case xinput
        case xaudio
        case xact
        case xna
        case openAL
        case physX
        case gdiPlus
        case directShow

        fileprivate var markers: [String] {
            switch self {
            case .visualCpp:
                return ["msvcp60", "msvcp71", "msvcp80", "msvcp90", "msvcp100", "msvcp110",
                        "msvcp120", "msvcp140", "msvcr71", "msvcr80", "msvcr90", "msvcr100",
                        "msvcr110", "msvcr120", "vcruntime140", "concrt140", "api-ms-win-crt",
                        "mfc42", "mfc71", "mfc80", "mfc90", "mfc100", "mfc110", "mfc120", "mfc140",
                        "vcomp110", "vcomp120"]
            case .dotNet:
                return ["mscoree.dll", "v2.0.50727", "v4.0.30319", "microsoft.netcore.app",
                        "microsoft.windowsdesktop.app"]
            case .directX9Helper:  return ["d3dx9_"]
            case .d3dCompiler:     return ["d3dcompiler_"]
            case .directX10Helper: return ["d3dx10_"]
            case .directX11Helper: return ["d3dx11_"]
            case .xinput:          return ["xinput1_", "xinput9_"]
            case .xaudio:          return ["xaudio2_"]
            case .xact:            return ["xactengine", "x3daudio"]
            case .xna:             return ["microsoft.xna.framework", "xna framework"]
            case .openAL:          return ["openal32.dll"]
            case .physX:           return ["physxloader.dll", "physx3", "physxcooking"]
            case .gdiPlus:         return ["gdiplus.dll"]
            case .directShow:      return ["quartz.dll", "qedit.dll"]
            }
        }

        var label: String {
            switch self {
            case .visualCpp:       return "Visual C++ Runtime"
            case .dotNet:          return ".NET / Windows Desktop Runtime"
            case .directX9Helper:  return "DirectX 9 (D3DX9)"
            case .d3dCompiler:     return "D3DCompiler"
            case .directX10Helper: return "DirectX 10 (D3DX10)"
            case .directX11Helper: return "DirectX 11 (D3DX11)"
            case .xinput:          return "XInput (mandos)"
            case .xaudio:          return "XAudio2"
            case .xact:            return "XACT / X3DAudio"
            case .xna:             return "Microsoft XNA Framework"
            case .openAL:          return "OpenAL"
            case .physX:           return "NVIDIA PhysX"
            case .gdiPlus:         return "GDI+"
            case .directShow:      return "DirectShow"
            }
        }
    }

    struct RepairPlan: Equatable, Sendable {
        let dependencies: [Dependency]
        let winetricksVerbs: [String]
        /// Nombres, no rutas completas: útiles para diagnóstico sin exponer la carpeta del usuario.
        let evidenceFiles: [String]
    }

    private struct ScanSnapshot {
        let files: [URL]
        /// Índice compacto de cadenas ASCII imprimibles, ya normalizadas a minúsculas. Se construye
        /// una sola vez para no recorrer cada binario completo por cada marcador conocido.
        let searchIndex: Data

        func contains(_ marker: String) -> Bool {
            guard let bytes = marker.lowercased().data(using: .utf8), !bytes.isEmpty else { return false }
            return searchIndex.range(of: bytes) != nil
        }

        func containsFile(named name: String) -> Bool {
            files.contains { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// Escanea el ejecutable, DLLs y metadatos cercanos. El recorrido está acotado por profundidad,
    /// número de archivos y tamaño para que una biblioteca grande nunca bloquee el lanzamiento.
    nonisolated static func detect(executable: String) -> [Dependency] {
        let snapshot = scan(executable: executable)
        return Dependency.allCases.filter { dependency in
            dependency.markers.contains(where: snapshot.contains)
        }
    }

    nonisolated static func summary(executable: String) -> String? {
        let dependencies = detect(executable: executable)
        guard !dependencies.isEmpty else { return nil }
        return dependencies.map(\.label).joined(separator: ", ")
    }

    /// Convierte la evidencia encontrada en una reparación concreta. `missingLibrary` procede del
    /// diagnóstico de Wine cuando este puede identificar el DLL exacto; se combina con el análisis
    /// estático para cubrir cargas dinámicas (`LoadLibrary`) que no aparecen en la tabla PE.
    nonisolated static func repairPlan(executable: String, missingLibrary: String? = nil) -> RepairPlan {
        let snapshot = scan(executable: executable, extraMarker: missingLibrary)
        return makeRepairPlan(
            executable: executable,
            missingLibrary: missingLibrary,
            snapshot: snapshot
        )
    }

    /// Preflight para ejecutables que Steam debe autorizar. Solo inspecciona el PE principal y sus
    /// DLL/config adyacentes: un depot puede incluir otra edición, un editor o herramientas .NET en
    /// subcarpetas, y sus runtimes no deben contaminar el prefijo compartido del juego seleccionado.
    nonisolated static func protectedSteamPreflightPlan(executable: String) -> RepairPlan {
        makeRepairPlan(
            executable: executable,
            missingLibrary: nil,
            snapshot: scan(executable: executable, includeNestedFiles: false)
        )
    }

    private nonisolated static func makeRepairPlan(
        executable: String,
        missingLibrary: String?,
        snapshot: ScanSnapshot
    ) -> RepairPlan {
        var dependencies = Dependency.allCases.filter { dependency in
            dependency.markers.contains(where: snapshot.contains)
        }
        var verbs: [String] = []

        // Visual C++ se instala por generación. Las versiones antiguas no quedan cubiertas por
        // vcrun2022 y pueden coexistir en el mismo prefijo.
        let visualCppRules: [(String, [String])] = [
            ("vcrun6sp6", ["msvcp60", "mfc42"]),
            ("vcrun2003", ["msvcp71", "msvcr71", "mfc71"]),
            ("vcrun2005", ["msvcp80", "msvcr80", "mfc80"]),
            ("vcrun2008", ["msvcp90", "msvcr90", "mfc90"]),
            ("vcrun2010", ["msvcp100", "msvcr100", "mfc100"]),
            ("vcrun2012", ["msvcp110", "msvcr110", "mfc110", "vcomp110"]),
            ("vcrun2013", ["msvcp120", "msvcr120", "mfc120", "vcomp120"]),
            ("vcrun2022", ["msvcp140", "vcruntime140", "concrt140", "mfc140", "api-ms-win-crt"])
        ]
        for (verb, markers) in visualCppRules where markers.contains(where: snapshot.contains) {
            verbs.append(verb)
        }

        // Ruby 2.x para Windows inspecciona internamente la implementación de `_isatty` de UCRT.
        // El `ucrtbase.dll` builtin de Wine expone la API, pero no el layout privado que espera
        // ese runtime y Ruby termina con «unexpected ucrtbase.dll». La combinación de la DLL Ruby,
        // imports UCRT y ese diagnóstico embebido identifica el caso sin depender del juego.
        if snapshot.contains("ruby"),
           snapshot.contains("api-ms-win-crt"),
           snapshot.contains("unexpected ucrtbase.dll") {
            verbs.append("ucrtbase2019")
        }

        // .NET moderno se identifica por runtimeconfig; .NET Framework por CLR/config. Elegimos una
        // sola familia para no mezclar instaladores incompatibles dentro del mismo prefijo.
        if let dotNetVerb = dotNetVerb(in: snapshot) {
            verbs.append(dotNetVerb)
        }

        // Los tres helpers que Vessel empaqueta no requieren descarga. Para cualquier otra versión,
        // winetricks instala exactamente el DLL pedido y no un DirectX completo indiscriminado.
        for version in 24...43 where snapshot.contains("d3dx9_\(version)") {
            if ![42, 43].contains(version), !snapshot.containsFile(named: "d3dx9_\(version).dll") {
                verbs.append("d3dx9_\(version)")
            }
        }
        for version in [42, 43, 46, 47] where snapshot.contains("d3dcompiler_\(version)") {
            if version != 43, !snapshot.containsFile(named: "d3dcompiler_\(version).dll") {
                verbs.append("d3dcompiler_\(version)")
            }
        }
        if snapshot.contains("d3dx10_43"), !snapshot.containsFile(named: "d3dx10_43.dll") {
            verbs.append("d3dx10_43")
        }
        else if snapshot.contains("d3dx10_") { verbs.append("d3dx10") }
        for version in [42, 43] where snapshot.contains("d3dx11_\(version)") {
            if !snapshot.containsFile(named: "d3dx11_\(version).dll") {
                verbs.append("d3dx11_\(version)")
            }
        }

        if (snapshot.contains("xinput1_") || snapshot.contains("xinput9_"))
            && !snapshot.files.contains(where: { $0.lastPathComponent.lowercased().hasPrefix("xinput") }) {
            verbs.append("xinput")
        }
        if snapshot.contains("xaudio2_") || snapshot.contains("xactengine") || snapshot.contains("x3daudio") {
            verbs.append(executableIs32Bit(executable) ? "xact" : "xact_x64")
        }
        if snapshot.contains("openal32.dll"), !snapshot.containsFile(named: "openal32.dll") { verbs.append("openal") }
        // Un instalador `PhysX_*.exe` junto al juego NO es el runtime: Steam puede abrirlo con UI
        // y dejar al usuario bloqueado en el contrato de licencia. Solo una DLL de runtime local
        // distinta de `PhysXLoader.dll` demuestra que el motor empaqueta PhysX de forma autónoma.
        // `PhysXLoader.dll` es precisamente el cargador de las DLL que instala el redistribuible.
        let hasLocalPhysXRuntime = snapshot.files.contains { file in
            let name = file.lastPathComponent.lowercased()
            return file.pathExtension.caseInsensitiveCompare("dll") == .orderedSame
                && name.hasPrefix("physx")
                && name != "physxloader.dll"
        }
        if (snapshot.contains("physxloader.dll") || snapshot.contains("physx3"))
            && !hasLocalPhysXRuntime {
            verbs.append("physx")
        }
        if snapshot.contains("gdiplus.dll"), !snapshot.containsFile(named: "gdiplus.dll") { verbs.append("gdiplus") }
        if (snapshot.contains("quartz.dll") || snapshot.contains("qedit.dll"))
            && !snapshot.containsFile(named: "quartz.dll") {
            verbs.append("quartz")
        }

        let usesXNA = (snapshot.contains("microsoft.xna.framework") || snapshot.contains("xna framework"))
            && !snapshot.contains("monogame") && !snapshot.contains("fna.dll")
            && !snapshot.contains("microsoft.netcore.app")
        if usesXNA {
            if !dependencies.contains(.dotNet) { dependencies.append(.dotNet) }
            let usesXNA31 = isXNA31(snapshot)
            if !verbs.contains(where: { $0.hasPrefix("dotnet") }) {
                verbs.append(usesXNA31 ? "dotnet35sp1" : "dotnet40")
            }
            verbs.append(usesXNA31 ? "xna31" : "xna40")
        } else {
            dependencies.removeAll { $0 == .xna }
        }

        // Un nombre observado solo en el log también debe reflejarse en el resumen del plan.
        if let missingLibrary {
            for dependency in Dependency.allCases
            where dependency.markers.contains(where: { missingLibrary.localizedCaseInsensitiveContains($0) })
                && !dependencies.contains(dependency) {
                dependencies.append(dependency)
            }
        }

        var resolvedVerbs = orderedUnique(verbs)
        if let missingLibrary {
            resolvedVerbs = exactRepairVerbs(
                for: missingLibrary,
                executable: executable,
                snapshot: snapshot,
                planned: resolvedVerbs
            )
        }
        return RepairPlan(
            dependencies: Dependency.allCases.filter(dependencies.contains),
            winetricksVerbs: resolvedVerbs,
            evidenceFiles: snapshot.files.map(\.lastPathComponent)
        )
    }

    /// Copia los helpers redistribuibles que sí forman parte de Vessel junto al ejecutable. Copiar
    /// solo versiones observadas evita inyectar DLL ajenos en juegos que no los necesitan.
    @discardableResult
    @MainActor
    static func provision(executable: String, includeNestedFiles: Bool = true) -> [Dependency] {
        let snapshot = scan(executable: executable, includeNestedFiles: includeNestedFiles)
        let dependencies = Dependency.allCases.filter { dependency in
            dependency.markers.contains(where: snapshot.contains)
        }
        guard let redist = redistD3DX9Directory() else { return dependencies }

        let gameDirectory = (executable as NSString).deletingLastPathComponent
        let architecture = executableIs32Bit(executable) ? "x32" : "x64"
        let bundledDLLs = ["d3dx9_42.dll", "d3dx9_43.dll", "d3dcompiler_43.dll"]
            .filter(snapshot.contains)
        var copied: [String] = []
        for dll in bundledDLLs {
            let source = "\(redist)/\(architecture)/\(dll)"
            let destination = "\(gameDirectory)/\(dll)"
            guard FileManager.default.fileExists(atPath: source),
                  !FileManager.default.fileExists(atPath: destination) else { continue }
            do {
                try FileManager.default.copyItem(atPath: source, toPath: destination)
                copied.append(dll)
            } catch {
                LogStore.shared.log("No se pudo provisionar \(dll): \(error.localizedDescription)", level: .warn)
            }
        }
        if !copied.isEmpty {
            LogStore.shared.log("Dependencias: provisionados \(copied.joined(separator: ", ")) junto al juego.", level: .debug)
        }
        if !dependencies.isEmpty {
            LogStore.shared.log("Dependencias detectadas en el juego: \(dependencies.map(\.label).joined(separator: ", ")).", level: .debug)
        }
        return dependencies
    }

    // MARK: - Escaneo acotado

    private nonisolated static func scan(
        executable: String,
        extraMarker: String? = nil,
        includeNestedFiles: Bool = true
    ) -> ScanSnapshot {
        let executableURL = URL(fileURLWithPath: executable).standardizedFileURL
        let root = executableURL.deletingLastPathComponent()
        let allowedExtensions = Set(["exe", "dll", "config", "json"])
        let adjacentExtensions = includeNestedFiles
            ? allowedExtensions
            : Set(["dll", "config", "json"])
        let excludedDirectories = Set(["_commonredist", "redist", "redistributables", "installers",
                                       "support", "directxredist", "dotnetredist", "content", "assets",
                                       "streamingassets", "modtools", "tools", "localization", "languages"])
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        var candidates: [(url: URL, size: Int, depth: Int)] = []
        var seenPaths = Set<String>()

        // Los runtimeconfig y DLL de raíz son la evidencia más valiosa. Se recogen antes de entrar
        // en subdirectorios para que una carpeta de assets enorme no agote el límite de candidatos.
        if let rootItems = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) {
            for url in rootItems {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                      adjacentExtensions.contains(url.pathExtension.lowercased()),
                      url.standardizedFileURL != executableURL else { continue }
                let standardized = url.standardizedFileURL
                candidates.append((standardized, values?.fileSize ?? 0, 1))
                seenPaths.insert(standardized.path)
            }
        }

        if includeNestedFiles, let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) {
            while let url = enumerator.nextObject() as? URL, candidates.count < 512 {
                let depth = url.pathComponents.count - root.pathComponents.count
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if depth >= 4 || excludedDirectories.contains(url.lastPathComponent.lowercased()) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let fileSize = values?.fileSize ?? 0
                guard depth <= 4, values?.isRegularFile == true, values?.isSymbolicLink != true,
                      allowedExtensions.contains(url.pathExtension.lowercased()),
                      url.standardizedFileURL != executableURL,
                      seenPaths.insert(url.standardizedFileURL.path).inserted else { continue }
                candidates.append((url.standardizedFileURL, fileSize, depth))
            }
        }

        // Prioridad: configuraciones de runtime, DLL junto al exe, DLL de motor conocidas y después
        // el resto por profundidad/tamaño. Así el presupuesto no se lo llevan assets auxiliares.
        func priority(_ item: (url: URL, size: Int, depth: Int)) -> (Int, Int, Int, String) {
            let ext = item.url.pathExtension.lowercased()
            let name = item.url.lastPathComponent.lowercased()
            let knownEngineDLLs = ["unityplayer.dll", "gameassembly.dll", "mono-2.0-bdwgc.dll",
                                   "fmod.dll", "fmodstudio.dll"]
            let group: Int
            if ext == "config" || ext == "json" { group = 0 }
            else if item.depth == 1 { group = 1 }
            else if knownEngineDLLs.contains(name) { group = 2 }
            else { group = 3 }
            return (group, item.depth, item.size, item.url.path)
        }
        candidates.sort { priority($0) < priority($1) }

        let urls = [executableURL] + candidates.prefix(127).map(\.url)
        let index = makeSearchIndex(files: urls, extraMarker: extraMarker)
        return ScanSnapshot(files: urls, searchIndex: index)
    }

    private nonisolated static func dotNetVerb(in snapshot: ScanSnapshot) -> String? {
        let desktop = snapshot.contains("microsoft.windowsdesktop.app")
        let core = snapshot.contains("microsoft.netcore.app")
        if desktop || core {
            for major in [9, 8, 7, 6] where snapshot.contains("\"version\":\"\(major).")
                || snapshot.contains("\"version\": \"\(major).") {
                return desktop ? "dotnetdesktop\(major)" : "dotnet\(major)"
            }
        }
        if snapshot.contains("xna framework") || snapshot.contains("microsoft.xna.framework") {
            return isXNA31(snapshot) ? "dotnet35sp1" : "dotnet40"
        }
        if snapshot.contains("v1.1.4322") { return "dotnet11sp1" }
        if snapshot.contains("v2.0.50727") { return "dotnet35sp1" }
        if snapshot.contains("v4.0.30319") || snapshot.contains("supportedruntime version=\"v4.0") {
            return "dotnet48"
        }
        // `mscoree.dll` sin versión suele ser un ejecutable .NET Framework 4.x. Este fallback solo
        // se consume tras un fallo real de runtime, nunca durante un lanzamiento sano.
        if snapshot.contains("mscoree.dll") { return "dotnet48" }
        return nil
    }

    private nonisolated static func isXNA31(_ snapshot: ScanSnapshot) -> Bool {
        snapshot.contains("microsoft.xna.framework, version=3.")
            || snapshot.contains("xna framework redistributable 3.1")
    }

    private nonisolated static func exactRepairVerbs(for library: String, executable: String,
                                                     snapshot: ScanSnapshot,
                                                     planned: [String]) -> [String] {
        let name = library.lowercased()
        let rules: [(markers: [String], verb: String)] = [
            (["msvcp60", "mfc42"], "vcrun6sp6"),
            (["msvcp71", "msvcr71", "mfc71"], "vcrun2003"),
            (["msvcp80", "msvcr80", "mfc80"], "vcrun2005"),
            (["msvcp90", "msvcr90", "mfc90"], "vcrun2008"),
            (["msvcp100", "msvcr100", "mfc100"], "vcrun2010"),
            (["msvcp110", "msvcr110", "mfc110", "vcomp110"], "vcrun2012"),
            (["msvcp120", "msvcr120", "mfc120", "vcomp120"], "vcrun2013"),
            (["msvcp140", "vcruntime140", "concrt140", "mfc140", "api-ms-win-crt"], "vcrun2022")
        ]
        if let match = rules.first(where: { $0.markers.contains(where: name.contains) }) {
            return [match.verb]
        }
        for version in 24...43 where name.contains("d3dx9_\(version)") {
            return [42, 43].contains(version) ? [] : ["d3dx9_\(version)"]
        }
        for version in [42, 43, 46, 47] where name.contains("d3dcompiler_\(version)") {
            return version == 43 ? [] : ["d3dcompiler_\(version)"]
        }
        if name.contains("d3dx10_43") { return ["d3dx10_43"] }
        if name.contains("d3dx11_42") { return ["d3dx11_42"] }
        if name.contains("d3dx11_43") { return ["d3dx11_43"] }
        if name.contains("xinput") { return ["xinput"] }
        if name.contains("xaudio2") || name.contains("xactengine") || name.contains("x3daudio") {
            return [executableIs32Bit(executable) ? "xact" : "xact_x64"]
        }
        if name.contains("openal32") { return ["openal"] }
        if name.contains("physx") { return ["physx"] }
        if name.contains("gdiplus") { return ["gdiplus"] }
        if name.contains("quartz") || name.contains("qedit") { return ["quartz"] }
        if name.contains("mscoree") || name.contains("clr.dll") {
            return planned.first(where: { $0.hasPrefix("dotnet") }).map { [$0] }
                ?? dotNetVerb(in: snapshot).map { [$0] }
                ?? ["dotnet48"]
        }
        return []
    }

    private nonisolated static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private nonisolated static func redistD3DX9Directory() -> String? {
        guard let resource = Bundle.main.resourceURL?.appendingPathComponent("redist/d3dx9").path,
              FileManager.default.fileExists(atPath: resource) else { return nil }
        return resource
    }

    /// Lee el header PE para distinguir i386 de x86_64. Un archivo no PE cae conservadoramente a 64 bits.
    private nonisolated static func executableIs32Bit(_ executable: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe),
              data.count > 0x40 else { return false }
        let peOffset = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0x3C, as: UInt32.self) })
        guard peOffset > 0, data.count > peOffset + 6,
              data[data.startIndex + peOffset] == 0x50,
              data[data.startIndex + peOffset + 1] == 0x45 else { return false }
        let machine = UInt16(data[data.startIndex + peOffset + 4])
            | (UInt16(data[data.startIndex + peOffset + 5]) << 8)
        return machine == 0x014c
    }

    private nonisolated static func makeSearchIndex(files: [URL], extraMarker: String?) -> Data {
        var output: [UInt8] = []
        output.reserveCapacity(32 * 1_024)
        for (index, file) in files.enumerated() {
            appendSearchText(file.lastPathComponent, to: &output)
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            let fileExtension = file.pathExtension.lowercased()
            if fileExtension == "config" || fileExtension == "json" {
                appendPrintableASCII(from: data.prefix(2 * 1_024 * 1_024), to: &output)
                continue
            }

            // Para binarios PE se lee la tabla de imports (incluidos delay-load) en vez de barrer
            // decenas de MB por cada juego. Es la fuente exacta de los DLL que el loader necesita.
            let importedLibraries = peImportedLibraries(in: data)
            for importedLibrary in importedLibraries {
                appendSearchText(importedLibrary, to: &output)
            }

            // Los ensamblados gestionados llevan versiones/runtime en sus metadatos. El ejecutable
            // principal pequeño también puede cargar DLL dinámicamente, pero no se barren strings
            // arbitrarios de DLL nativas adyacentes: `steam_api.dll`, por ejemplo, contiene el texto
            // `mscoree.dll` sin importarlo y provocaba una instalación falsa de .NET 4.8.
            let name = file.lastPathComponent.lowercased()
            let managedPE = importedLibraries.contains { $0.caseInsensitiveCompare("mscoree.dll") == .orderedSame }
            if managedPE || name.contains("xna") || name.contains("monogame") || name == "fna.dll"
                || (index == 0 && data.count <= 1 * 1_024 * 1_024) {
                appendPrintableASCII(from: data.prefix(4 * 1_024 * 1_024), to: &output)
            }
        }
        if let extraMarker {
            appendSearchText(extraMarker, to: &output)
        }
        return Data(output)
    }

    private nonisolated static func appendSearchText(_ text: String, to output: inout [UInt8]) {
        output.append(0x0a)
        output.append(contentsOf: text.utf8.map(asciiLowercased))
        output.append(0x0a)
    }

    /// Extrae imports PE normales y diferidos sin ejecutar el binario. El parser valida todos los
    /// offsets y limita descriptores/cadenas; un archivo truncado o no PE simplemente devuelve vacío.
    private nonisolated static func peImportedLibraries(in data: Data) -> [String] {
        guard data.count >= 0x40, data[0] == 0x4d, data[1] == 0x5a,
              let peOffsetValue = uint32(in: data, at: 0x3c) else { return [] }
        let peOffset = Int(peOffsetValue)
        guard peOffset >= 0, peOffset + 24 <= data.count,
              data[peOffset] == 0x50, data[peOffset + 1] == 0x45,
              let sectionCountValue = uint16(in: data, at: peOffset + 6),
              let optionalSizeValue = uint16(in: data, at: peOffset + 20) else { return [] }

        let sectionCount = min(Int(sectionCountValue), 96)
        let optionalHeader = peOffset + 24
        let optionalSize = Int(optionalSizeValue)
        guard optionalHeader + optionalSize <= data.count,
              let magic = uint16(in: data, at: optionalHeader) else { return [] }
        let dataDirectoryOffset: Int
        switch magic {
        case 0x10b: dataDirectoryOffset = optionalHeader + 96
        case 0x20b: dataDirectoryOffset = optionalHeader + 112
        default: return []
        }
        let sectionTable = optionalHeader + optionalSize
        guard sectionTable + sectionCount * 40 <= data.count else { return [] }

        func fileOffset(forRVA rva: UInt32) -> Int? {
            guard rva != 0 else { return nil }
            for section in 0..<sectionCount {
                let base = sectionTable + section * 40
                guard let virtualSize = uint32(in: data, at: base + 8),
                      let virtualAddress = uint32(in: data, at: base + 12),
                      let rawSize = uint32(in: data, at: base + 16),
                      let rawOffset = uint32(in: data, at: base + 20) else { continue }
                let span = max(virtualSize, rawSize)
                guard rva >= virtualAddress, UInt64(rva) < UInt64(virtualAddress) + UInt64(span) else { continue }
                let result = UInt64(rawOffset) + UInt64(rva - virtualAddress)
                guard result < UInt64(data.count) else { return nil }
                return Int(result)
            }
            return nil
        }

        var result: [String] = []
        func appendDescriptors(directoryIndex: Int, stride: Int, nameOffset: Int) {
            let entry = dataDirectoryOffset + directoryIndex * 8
            guard entry + 8 <= optionalHeader + optionalSize,
                  let directoryRVA = uint32(in: data, at: entry),
                  let start = fileOffset(forRVA: directoryRVA) else { return }
            for descriptor in 0..<512 {
                let offset = start + descriptor * stride
                guard offset + stride <= data.count,
                      let nameRVA = uint32(in: data, at: offset + nameOffset) else { break }
                if nameRVA == 0 { break }
                guard let nameFileOffset = fileOffset(forRVA: nameRVA),
                      let name = asciiCString(in: data, at: nameFileOffset, maximumLength: 260),
                      name.lowercased().hasSuffix(".dll") else { continue }
                result.append(name)
            }
        }
        appendDescriptors(directoryIndex: 1, stride: 20, nameOffset: 12)  // IMAGE_IMPORT_DESCRIPTOR
        appendDescriptors(directoryIndex: 13, stride: 32, nameOffset: 4)  // ImgDelayDescr
        return orderedUnique(result)
    }

    private nonisolated static func uint16(in data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private nonisolated static func uint32(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private nonisolated static func asciiCString(in data: Data, at offset: Int,
                                                  maximumLength: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for index in offset..<min(data.count, offset + maximumLength) {
            let byte = data[index]
            if byte == 0 { break }
            guard (32...126).contains(byte) else { return nil }
            bytes.append(byte)
        }
        guard !bytes.isEmpty else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    /// Los nombres de imports, versiones de CLR y runtimeconfig son cadenas ASCII imprimibles. Se
    /// descarta el ruido binario y las secuencias menores de cuatro caracteres, reduciendo mucho el
    /// índice sin perder ninguna de las firmas utilizadas por el planificador.
    private nonisolated static func appendPrintableASCII<C: Collection>(from bytes: C,
                                                                         to output: inout [UInt8])
    where C.Element == UInt8 {
        var runStart = output.count
        for byte in bytes {
            if (32...126).contains(byte) {
                output.append(asciiLowercased(byte))
            } else {
                if output.count - runStart < 4 { output.removeSubrange(runStart..<output.count) }
                else { output.append(0x0a) }
                runStart = output.count
            }
        }
        if output.count - runStart < 4 { output.removeSubrange(runStart..<output.count) }
        else { output.append(0x0a) }
    }

    private nonisolated static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }
}
