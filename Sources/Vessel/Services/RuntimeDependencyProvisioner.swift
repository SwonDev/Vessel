import Foundation

/// Detecta las dependencias de runtime de Windows que un juego necesita (Visual C++, .NET,
/// helpers de DirectX, XInput…) escaneando la tabla de imports de su `.exe`, y provisiona las que
/// Vessel PUEDE satisfacer de forma segura (sin ejecutar instaladores frágiles que cuelguen).
///
/// Filosofía: el motor Wine ya trae *builtins* de la mayoría (msvcp140/vcruntime140, mscoree→Mono,
/// xinput…), así que aquí solo **copiamos los DLLs que empaquetamos** (los helpers de DirectX 9,
/// cuyo builtin de Wine es incompleto para los efectos `.fx`) y **detectamos/registramos** el resto
/// para que el diagnóstico de fallos sea preciso. Nada de descargas ni `.exe` de instalación.
enum RuntimeDependencyProvisioner {
    enum Dependency: String, CaseIterable {
        case visualCpp          // msvcp140 / vcruntime140 / msvcr120 / msvcr100 …
        case dotNet             // mscoree (.NET Framework) — Wine usa Mono
        case directX9Helper     // d3dx9_* — lo empaquetamos (builtin incompleto para .fx)
        case d3dCompiler        // d3dcompiler_* — lo empaquetamos
        case directX11Helper    // d3dx11_*
        case xinput             // mandos — Wine builtin
        case xaudio             // xaudio2_* — Wine builtin

        /// Subcadenas (nombres de DLL) cuya presencia en los imports del `.exe` indica la dependencia.
        var importMarkers: [String] {
            switch self {
            case .visualCpp:       return ["msvcp140", "vcruntime140", "msvcp120", "msvcr120", "msvcp100", "msvcr100", "concrt140"]
            case .dotNet:          return ["mscoree.dll"]
            case .directX9Helper:  return ["d3dx9_"]
            case .d3dCompiler:     return ["d3dcompiler_"]
            case .directX11Helper: return ["d3dx11_"]
            case .xinput:          return ["xinput1_", "xinput9_"]
            case .xaudio:          return ["xaudio2_"]
            }
        }

        var label: String {
            switch self {
            case .visualCpp:       return "Visual C++ Runtime"
            case .dotNet:          return ".NET Framework"
            case .directX9Helper:  return "DirectX 9 (d3dx9)"
            case .d3dCompiler:     return "D3DCompiler"
            case .directX11Helper: return "DirectX 11 (d3dx11)"
            case .xinput:          return "XInput (mandos)"
            case .xaudio:          return "XAudio2"
            }
        }
    }

    /// Escanea los imports del `.exe` (buscando los nombres de DLL como ASCII en el binario, igual
    /// que hace `WineManager.exeImports`) y devuelve las dependencias detectadas.
    nonisolated static func detect(executable: String) -> [Dependency] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe) else {
            return []
        }
        return Dependency.allCases.filter { dep in
            dep.importMarkers.contains { marker in
                containsASCII(data, marker.lowercased()) || containsASCII(data, marker.uppercased())
            }
        }
    }

    /// Resumen legible de las dependencias detectadas, para logs y para el diagnóstico de fallos.
    /// `nil` si no se detecta ninguna reseñable.
    nonisolated static func summary(executable: String) -> String? {
        let deps = detect(executable: executable)
        guard !deps.isEmpty else { return nil }
        return deps.map(\.label).joined(separator: ", ")
    }

    /// Provisiona en la carpeta del juego los DLLs que Vessel empaqueta y el juego necesita: los
    /// helpers de DirectX 9 (`d3dx9_43/42`, `d3dcompiler_43`), cuyo builtin de Wine no compila los
    /// efectos `.fx`. Wine busca DLLs primero junto al `.exe`, así que copiarlos ahí GARANTIZA que
    /// se usen los nativos de Microsoft. Idempotente y silencioso (best-effort).
    ///
    /// El resto de dependencias (Visual C++, .NET, XInput…) las cubre el builtin del motor Wine;
    /// aquí solo se registran para el diagnóstico. Devuelve las dependencias detectadas.
    @discardableResult
    @MainActor
    static func provision(executable: String) -> [Dependency] {
        let deps = detect(executable: executable)
        guard let redist = redistD3DX9Directory() else { return deps }
        let gameDir = (executable as NSString).deletingLastPathComponent
        let fm = FileManager.default
        let is32 = executableIs32Bit(executable)
        let archSub = is32 ? "x32" : "x64"
        let needsD3DX9 = deps.contains(.directX9Helper) || deps.contains(.d3dCompiler)
        if needsD3DX9 {
            for dll in ["d3dx9_43.dll", "d3dx9_42.dll", "d3dcompiler_43.dll"] {
                let src = "\(redist)/\(archSub)/\(dll)"
                let dst = "\(gameDir)/\(dll)"
                guard fm.fileExists(atPath: src), !fm.fileExists(atPath: dst) else { continue }
                try? fm.copyItem(atPath: src, toPath: dst)
            }
            LogStore.shared.log("Dependencias: provisionados helpers de DirectX 9 (d3dx9/d3dcompiler) junto al juego.", level: .debug)
        }
        if let s = summary(executable: executable) {
            LogStore.shared.log("Dependencias detectadas en el juego: \(s).", level: .debug)
        }
        return deps
    }

    // MARK: - Internos

    private nonisolated static func redistD3DX9Directory() -> String? {
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("redist/d3dx9").path,
              FileManager.default.fileExists(atPath: res) else { return nil }
        return res
    }

    /// Lee el header PE para saber si el `.exe` es de 32 bits (máquina i386) o 64.
    private nonisolated static func executableIs32Bit(_ executable: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe),
              data.count > 0x40 else { return false }
        let peOffset = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0x3C, as: UInt32.self) })
        guard peOffset > 0, data.count > peOffset + 6,
              data[data.startIndex + peOffset] == 0x50,        // 'P'
              data[data.startIndex + peOffset + 1] == 0x45     // 'E'
        else { return false }
        let machine = UInt16(data[data.startIndex + peOffset + 4]) | (UInt16(data[data.startIndex + peOffset + 5]) << 8)
        return machine == 0x014c   // IMAGE_FILE_MACHINE_I386
    }

    private nonisolated static func containsASCII(_ data: Data, _ needle: String) -> Bool {
        guard let n = needle.data(using: .ascii), !n.isEmpty else { return false }
        return data.range(of: n) != nil
    }
}
