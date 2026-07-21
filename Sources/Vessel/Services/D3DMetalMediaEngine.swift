import CryptoKit
import Darwin
import Foundation

/// Sustitución de directorios mediante `rename(2)`. Al estar staging y destino en el mismo
/// directorio, APFS garantiza una activación atómica y evita la ruta copy+delete que Foundation
/// puede elegir para árboles con symlinks de frameworks.
enum AtomicDirectoryReplacement {
    nonisolated static func replace(
        staging: URL,
        final: URL,
        backupPrefix: String
    ) throws {
        guard staging.deletingLastPathComponent().standardizedFileURL
            == final.deletingLastPathComponent().standardizedFileURL else {
            throw NSError(
                domain: "Vessel.AtomicDirectoryReplacement",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Staging y destino deben estar en el mismo directorio para activar de forma atómica."
                ]
            )
        }

        let fm = FileManager.default
        let backup = final.deletingLastPathComponent()
            .appendingPathComponent(".\(backupPrefix)-backup-\(UUID().uuidString)")
        var movedOldInstallation = false
        if fm.fileExists(atPath: final.path) {
            try renameItem(final, to: backup)
            movedOldInstallation = true
        }
        do {
            try renameItem(staging, to: final)
            if movedOldInstallation { try? fm.removeItem(at: backup) }
        } catch {
            if movedOldInstallation, !fm.fileExists(atPath: final.path) {
                try? renameItem(backup, to: final)
            }
            throw error
        }
    }

    private nonisolated static func renameItem(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No se pudo activar \(destination.lastPathComponent): \(String(cString: strerror(code)))."
                ]
            )
        }
    }
}

/// Runtime privado y reproducible de GStreamer para los juegos que usan Media Foundation.
///
/// No instala nada en `/Library` ni confía en un framework que el usuario tenga por casualidad.
/// Descarga el paquete runtime oficial, verifica su SHA-256 y extrae únicamente los componentes
/// LGPL necesarios para reproducir vídeo (incluidos `applemedia`, ISO/MP4 y `deinterlace`).
actor ManagedGStreamerRuntime {
    static let shared = ManagedGStreamerRuntime()

    nonisolated static let version = "1.28.2"
    nonisolated static let packageSHA256 =
        "964ff693002aaa69b2908f79967609b424ddc61210849e1afe5e8d8810f68b91"
    nonisolated static let packageURL = URL(
        string: "https://gstreamer.freedesktop.org/pkg/macos/1.28.2/gstreamer-1.0-1.28.2-universal.pkg"
    )!
    nonisolated static let directoryName = "gstreamer-1.28.2"

    /// Componentes oficiales deliberadamente limitados: no se incluyen paquetes GPL ni los
    /// etiquetados por upstream como restricted. `effects` contiene el `deinterlace` que exige
    /// winegstreamer; sin él, Media Foundation crea el pipeline y deja el juego en negro.
    nonisolated static let componentPackages = [
        "base-system-1.0-1.28.2-universal.pkg",
        "base-crypto-1.28.2-universal.pkg",
        "gstreamer-1.0-core-1.28.2-universal.pkg",
        "gstreamer-1.0-system-1.28.2-universal.pkg",
        "gstreamer-1.0-playback-1.28.2-universal.pkg",
        "gstreamer-1.0-codecs-1.28.2-universal.pkg",
        "gstreamer-1.0-effects-1.28.2-universal.pkg"
    ]

    private nonisolated static let frameworkPackage = "osx-framework-1.28.2-universal.pkg"
    private nonisolated static let markerName = ".vessel-gstreamer-runtime.json"

    struct Manifest: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let runtimeVersion: String
        let packageSHA256: String
        let components: [String]
    }

    nonisolated static var currentManifest: Manifest {
        Manifest(
            schemaVersion: 1,
            runtimeVersion: version,
            packageSHA256: packageSHA256,
            components: componentPackages
        )
    }

    nonisolated static func installationDirectory(
        enginesDirectory: String = VesselPaths.enginesDirectory
    ) -> URL {
        URL(fileURLWithPath: enginesDirectory, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    nonisolated static func frameworkRoot(
        enginesDirectory: String = VesselPaths.enginesDirectory
    ) -> URL {
        installationDirectory(enginesDirectory: enginesDirectory)
            .appendingPathComponent("GStreamer.framework", isDirectory: true)
    }

    nonisolated static func runtimeRoot(
        enginesDirectory: String = VesselPaths.enginesDirectory
    ) -> URL {
        frameworkRoot(enginesDirectory: enginesDirectory)
            .appendingPathComponent("Versions/1.0", isDirectory: true)
    }

    nonisolated static func isInstallationValid(
        at installationDirectory: URL
    ) -> Bool {
        let fm = FileManager.default
        let marker = installationDirectory.appendingPathComponent(markerName)
        guard let data = try? Data(contentsOf: marker),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest == currentManifest else {
            return false
        }

        let root = installationDirectory
            .appendingPathComponent("GStreamer.framework/Versions/1.0", isDirectory: true)
        let requiredFiles = [
            "lib/libgstreamer-1.0.0.dylib",
            "lib/libgstvideo-1.0.0.dylib",
            "lib/gstreamer-1.0/libgstapplemedia.dylib",
            "lib/gstreamer-1.0/libgstdeinterlace.dylib",
            "lib/gstreamer-1.0/libgstisomp4.dylib",
            "libexec/gstreamer-1.0/gst-plugin-scanner",
            "bin/gst-inspect-1.0"
        ]
        return requiredFiles.allSatisfy {
            fm.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    func ensureInstalled(
        enginesDirectory: String = VesselPaths.enginesDirectory,
        packageFile: URL? = nil,
        progress: @escaping @Sendable (String, Double) -> Void = { _, _ in }
    ) async throws -> String {
        let fm = FileManager.default
        let finalDirectory = Self.installationDirectory(enginesDirectory: enginesDirectory)
        if Self.isInstallationValid(at: finalDirectory) {
            return Self.runtimeRoot(enginesDirectory: enginesDirectory).path
        }

        try fm.createDirectory(atPath: enginesDirectory, withIntermediateDirectories: true)
        let package: URL
        let ownsPackage: Bool
        if let packageFile {
            package = packageFile
            ownsPackage = false
        } else {
            progress("Descargando runtime multimedia oficial de GStreamer…", 0.06)
            let (downloadedPackage, response) = try await URLSession.shared.download(
                from: Self.packageURL
            )
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw Self.error(
                    91,
                    "La descarga de GStreamer falló con HTTP \(http.statusCode)."
                )
            }
            package = downloadedPackage
            ownsPackage = true
        }

        progress("Verificando GStreamer…", 0.30)
        let actualHash = try await Task.detached(priority: .utility) {
            try Self.sha256Hex(of: package)
        }.value
        guard actualHash == Self.packageSHA256 else {
            throw Self.error(
                92,
                "La huella del runtime GStreamer no coincide; no se instalará un paquete no verificado."
            )
        }

        let token = UUID().uuidString
        let workDirectory = URL(fileURLWithPath: enginesDirectory, isDirectory: true)
            .appendingPathComponent(".gstreamer-work-\(token)", isDirectory: true)
        let expandedDirectory = workDirectory.appendingPathComponent("expanded", isDirectory: true)
        let stagingDirectory = URL(fileURLWithPath: enginesDirectory, isDirectory: true)
            .appendingPathComponent(".\(Self.directoryName)-installing-\(token)", isDirectory: true)
        defer {
            try? fm.removeItem(at: workDirectory)
            try? fm.removeItem(at: stagingDirectory)
            if ownsPackage { try? fm.removeItem(at: package) }
        }

        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        progress("Extrayendo runtime multimedia privado…", 0.42)
        _ = try await Self.runTool(
            "/usr/sbin/pkgutil",
            arguments: ["--expand-full", package.path, expandedDirectory.path]
        )

        let framework = stagingDirectory
            .appendingPathComponent("GStreamer.framework", isDirectory: true)
        let frameworkPayload = expandedDirectory
            .appendingPathComponent(Self.frameworkPackage, isDirectory: true)
            .appendingPathComponent("Payload", isDirectory: true)
        guard fm.fileExists(atPath: frameworkPayload.path) else {
            throw Self.error(93, "El paquete oficial de GStreamer no contiene su framework.")
        }
        try await Task.detached(priority: .utility) {
            try FileManager.default.copyItem(at: frameworkPayload, to: framework)
        }.value

        let versionRoot = framework.appendingPathComponent("Versions/1.0", isDirectory: true)
        for (index, component) in Self.componentPackages.enumerated() {
            let payload = expandedDirectory
                .appendingPathComponent(component, isDirectory: true)
                .appendingPathComponent("Payload", isDirectory: true)
            guard fm.fileExists(atPath: payload.path) else {
                throw Self.error(94, "Falta el componente multimedia oficial \(component).")
            }
            progress(
                "Preparando códecs multimedia…",
                0.50 + (Double(index + 1) / Double(Self.componentPackages.count)) * 0.30
            )
            _ = try await Self.runTool(
                "/usr/bin/ditto",
                arguments: [payload.path, versionRoot.path]
            )
        }

        let marker = stagingDirectory.appendingPathComponent(Self.markerName)
        let markerData = try JSONEncoder.vesselPretty.encode(Self.currentManifest)
        try markerData.write(to: marker, options: .atomic)
        _ = try? await Self.runTool(
            "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", stagingDirectory.path]
        )

        guard Self.isInstallationValid(at: stagingDirectory) else {
            throw Self.error(95, "El runtime multimedia quedó incompleto después de extraerlo.")
        }

        progress("Activando runtime multimedia…", 0.92)
        try await Task.detached(priority: .utility) {
            try AtomicDirectoryReplacement.replace(
                staging: stagingDirectory,
                final: finalDirectory,
                backupPrefix: Self.directoryName
            )
        }.value
        guard Self.isInstallationValid(at: finalDirectory) else {
            throw Self.error(96, "GStreamer se instaló, pero su verificación final falló.")
        }
        progress("Runtime multimedia listo", 1.0)
        return Self.runtimeRoot(enginesDirectory: enginesDirectory).path
    }

    nonisolated static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    nonisolated static func runTool(
        _ executable: String,
        arguments: [String]
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: output, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw Self.error(
                    Int(process.terminationStatus),
                    "Falló \((executable as NSString).lastPathComponent): \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
            return text
        }.value
    }

    private nonisolated static func error(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "Vessel.ManagedGStreamerRuntime",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

/// Construye el motor aislado `wine-d3dmetal-media` a partir de piezas ya gestionadas por Vessel.
/// El motor base nunca se modifica: toda la operación ocurre en staging y se activa al final.
enum D3DMetalMediaEngineProvisioner {
    nonisolated static let manifestName = ".vessel-d3dmetal-media.json"
    nonisolated static let d3dMetalLibraries = ["d3d11", "d3d12", "dxgi", "atidxx64", "nvapi64"]
    nonisolated static let relativeGStreamerRPath =
        "@loader_path/../../../../\(ManagedGStreamerRuntime.directoryName)/GStreamer.framework/Versions/1.0/lib"

    struct SourceIdentity: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let baseWineSHA256: String
        let d3dMetalFrameworkSHA256: String
        let d3dSharedSHA256: String
        let d3dMetalWindowsSHA256: [String: String]
        let wineGStreamerUnixSHA256: String
        let wineGStreamerWindowsSHA256: String
        let gstreamerPackageSHA256: String
    }

    struct Manifest: Codable, Equatable, Sendable {
        let source: SourceIdentity
        let installedWineGStreamerSHA256: String
    }

    nonisolated static func sourceIdentity(
        baseEngine: URL,
        gptkWineRoot: URL,
        gcenxEngine: URL
    ) throws -> SourceIdentity {
        SourceIdentity(
            schemaVersion: 2,
            baseWineSHA256: try ManagedGStreamerRuntime.sha256Hex(
                of: baseEngine.appendingPathComponent("bin/wine")
            ),
            d3dMetalFrameworkSHA256: try ManagedGStreamerRuntime.sha256Hex(
                of: gptkWineRoot.appendingPathComponent(
                    "lib/external/D3DMetal.framework/D3DMetal"
                )
            ),
            d3dSharedSHA256: try ManagedGStreamerRuntime.sha256Hex(
                of: gptkWineRoot.appendingPathComponent("lib/external/libd3dshared.dylib")
            ),
            d3dMetalWindowsSHA256: try Dictionary(uniqueKeysWithValues: d3dMetalLibraries.map {
                (
                    $0,
                    try ManagedGStreamerRuntime.sha256Hex(
                        of: gptkWineRoot.appendingPathComponent(
                            "lib/wine/x86_64-windows/\($0).dll"
                        )
                    )
                )
            }),
            wineGStreamerUnixSHA256: try ManagedGStreamerRuntime.sha256Hex(
                of: gcenxEngine.appendingPathComponent("lib/wine/x86_64-unix/winegstreamer.so")
            ),
            wineGStreamerWindowsSHA256: try ManagedGStreamerRuntime.sha256Hex(
                of: gcenxEngine.appendingPathComponent("lib/wine/x86_64-windows/winegstreamer.dll")
            ),
            gstreamerPackageSHA256: ManagedGStreamerRuntime.packageSHA256
        )
    }

    nonisolated static func isInstallationValid(
        at engine: URL,
        expectedSource: SourceIdentity
    ) -> Bool {
        let fm = FileManager.default
        let marker = engine.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: marker),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.source == expectedSource else {
            return false
        }
        let unixWineGStreamer = engine
            .appendingPathComponent("lib/wine/x86_64-unix/winegstreamer.so")
        let installedWine = engine.appendingPathComponent("bin/wine")
        let installedFramework = engine.appendingPathComponent(
            "lib64/apple_gptk/external/D3DMetal.framework/D3DMetal"
        )
        let installedD3DShared = engine.appendingPathComponent(
            "lib64/apple_gptk/external/libd3dshared.dylib"
        )
        let installedWindowsWineGStreamer = engine.appendingPathComponent(
            "lib/wine/x86_64-windows/winegstreamer.dll"
        )
        guard let installedHash = try? ManagedGStreamerRuntime.sha256Hex(of: unixWineGStreamer),
              installedHash == manifest.installedWineGStreamerSHA256,
              fm.isExecutableFile(atPath: installedWine.path),
              (try? ManagedGStreamerRuntime.sha256Hex(of: installedWine))
                == expectedSource.baseWineSHA256,
              (try? ManagedGStreamerRuntime.sha256Hex(of: installedFramework))
                == expectedSource.d3dMetalFrameworkSHA256,
              (try? ManagedGStreamerRuntime.sha256Hex(of: installedD3DShared))
                == expectedSource.d3dSharedSHA256,
              (try? ManagedGStreamerRuntime.sha256Hex(of: installedWindowsWineGStreamer))
                == expectedSource.wineGStreamerWindowsSHA256 else {
            return false
        }

        let forbiddenCXCompat = [
            "lib/wine/x86_64-unix/cxcompatdb.so",
            "lib64/wine/x86_64-unix/cxcompatdb.so"
        ]
        guard forbiddenCXCompat.allSatisfy({
            !fm.fileExists(atPath: engine.appendingPathComponent($0).path)
        }) else {
            return false
        }

        let unixDirectory = engine.appendingPathComponent("lib/wine/x86_64-unix")
        let windowsDirectory = engine.appendingPathComponent("lib/wine/x86_64-windows")
        return d3dMetalLibraries.allSatisfy { library in
            let pe = windowsDirectory.appendingPathComponent("\(library).dll")
            let unix = unixDirectory.appendingPathComponent("\(library).so")
            guard let expectedPEHash = expectedSource.d3dMetalWindowsSHA256[library],
                  (try? ManagedGStreamerRuntime.sha256Hex(of: pe)) == expectedPEHash,
                  let destination = try? fm.destinationOfSymbolicLink(atPath: unix.path) else {
                return false
            }
            return destination == "../../../lib64/apple_gptk/external/libd3dshared.dylib"
        }
    }

    static func ensureInstalled(
        baseEngine: URL,
        gptkWineRoot: URL,
        gcenxEngine: URL,
        finalEngine: URL,
        progress: @escaping @Sendable (String, Double) -> Void = { _, _ in }
    ) async throws -> String {
        let fm = FileManager.default
        let identity = try await Task.detached(priority: .utility) {
            try sourceIdentity(
                baseEngine: baseEngine,
                gptkWineRoot: gptkWineRoot,
                gcenxEngine: gcenxEngine
            )
        }.value
        if isInstallationValid(at: finalEngine, expectedSource: identity) {
            return preferredWineBinary(in: finalEngine)
        }

        let staging = finalEngine.deletingLastPathComponent()
            .appendingPathComponent(".wine-d3dmetal-media-installing-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        progress("Creando motor D3D12 multimedia aislado…", 0.72)
        try await Task.detached(priority: .utility) {
            try FileManager.default.copyItem(at: baseEngine, to: staging)
            try applyOverlayFiles(
                to: staging,
                gptkWineRoot: gptkWineRoot,
                gcenxEngine: gcenxEngine
            )
        }.value

        let installedWineGStreamer = staging
            .appendingPathComponent("lib/wine/x86_64-unix/winegstreamer.so")
        try await patchWineGStreamerRPath(installedWineGStreamer)
        _ = try? await ManagedGStreamerRuntime.runTool(
            "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", staging.path]
        )
        let installedHash = try await Task.detached(priority: .utility) {
            try ManagedGStreamerRuntime.sha256Hex(of: installedWineGStreamer)
        }.value
        let manifest = Manifest(
            source: identity,
            installedWineGStreamerSHA256: installedHash
        )
        try JSONEncoder.vesselPretty.encode(manifest).write(
            to: staging.appendingPathComponent(manifestName),
            options: .atomic
        )
        guard isInstallationValid(at: staging, expectedSource: identity) else {
            throw error(102, "El motor D3D12 multimedia quedó incompleto durante su preparación.")
        }

        progress("Activando motor D3D12 multimedia…", 0.96)
        try await Task.detached(priority: .utility) {
            try AtomicDirectoryReplacement.replace(
                staging: staging,
                final: finalEngine,
                backupPrefix: "wine-d3dmetal-media"
            )
        }.value
        guard isInstallationValid(at: finalEngine, expectedSource: identity) else {
            throw error(103, "El motor D3D12 multimedia no superó su verificación final.")
        }
        progress("Motor D3D12 multimedia listo", 1.0)
        return preferredWineBinary(in: finalEngine)
    }

    /// Separado del parche Mach-O para poder caracterizar y probar el layout sin binarios reales.
    nonisolated static func applyOverlayFiles(
        to engine: URL,
        gptkWineRoot: URL,
        gcenxEngine: URL
    ) throws {
        let fm = FileManager.default
        let gptkExternal = gptkWineRoot.appendingPathComponent("lib/external", isDirectory: true)
        let targetExternal = engine
            .appendingPathComponent("lib64/apple_gptk/external", isDirectory: true)
        let gptkWindows = gptkWineRoot
            .appendingPathComponent("lib/wine/x86_64-windows", isDirectory: true)
        let targetWindows = engine
            .appendingPathComponent("lib/wine/x86_64-windows", isDirectory: true)
        let targetUnix = engine
            .appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)

        let requiredSources = [
            gptkExternal.appendingPathComponent("D3DMetal.framework").path,
            gptkExternal.appendingPathComponent("libd3dshared.dylib").path,
            gcenxEngine.appendingPathComponent(
                "lib/wine/x86_64-unix/winegstreamer.so"
            ).path,
            gcenxEngine.appendingPathComponent(
                "lib/wine/x86_64-windows/winegstreamer.dll"
            ).path
        ] + d3dMetalLibraries.map {
            gptkWindows.appendingPathComponent("\($0).dll").path
        }
        guard requiredSources.allSatisfy(fm.fileExists) else {
            throw error(100, "Faltan piezas verificadas de D3DMetal o winegstreamer.")
        }

        try fm.createDirectory(at: targetExternal, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetWindows, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetUnix, withIntermediateDirectories: true)
        try copyReplacing(
            gptkExternal.appendingPathComponent("D3DMetal.framework"),
            to: targetExternal.appendingPathComponent("D3DMetal.framework")
        )
        try copyReplacing(
            gptkExternal.appendingPathComponent("libd3dshared.dylib"),
            to: targetExternal.appendingPathComponent("libd3dshared.dylib")
        )

        for library in d3dMetalLibraries {
            try copyReplacing(
                gptkWindows.appendingPathComponent("\(library).dll"),
                to: targetWindows.appendingPathComponent("\(library).dll")
            )
            let unix = targetUnix.appendingPathComponent("\(library).so")
            try? fm.removeItem(at: unix)
            try fm.createSymbolicLink(
                atPath: unix.path,
                withDestinationPath: "../../../lib64/apple_gptk/external/libd3dshared.dylib"
            )
        }

        try copyReplacing(
            gcenxEngine.appendingPathComponent("lib/wine/x86_64-unix/winegstreamer.so"),
            to: targetUnix.appendingPathComponent("winegstreamer.so")
        )
        try copyReplacing(
            gcenxEngine.appendingPathComponent("lib/wine/x86_64-windows/winegstreamer.dll"),
            to: targetWindows.appendingPathComponent("winegstreamer.dll")
        )
        let sourceI386 = gcenxEngine
            .appendingPathComponent("lib/wine/i386-windows/winegstreamer.dll")
        if fm.fileExists(atPath: sourceI386.path) {
            let targetI386 = engine.appendingPathComponent("lib/wine/i386-windows")
            try fm.createDirectory(at: targetI386, withIntermediateDirectories: true)
            try copyReplacing(
                sourceI386,
                to: targetI386.appendingPathComponent("winegstreamer.dll")
            )
        }

        // Nunca activar la base de compatibilidad propietaria en este perfil. Las piezas D3DMetal
        // cargan mediante el par PE + Unix probado arriba, sin `cxcompatdb.so`.
        for relativePath in [
            "lib/wine/x86_64-unix/cxcompatdb.so",
            "lib64/wine/x86_64-unix/cxcompatdb.so"
        ] {
            try? fm.removeItem(at: engine.appendingPathComponent(relativePath))
        }
    }

    nonisolated static func mediaEnvironment(
        winePath: String,
        prefix: String,
        enginesDirectory: String = VesselPaths.enginesDirectory
    ) -> [String: String] {
        let wineURL = URL(fileURLWithPath: winePath)
        let engine = WineEngineLocator.engineRoot(forWineExecutable: wineURL)
            ?? wineURL.deletingLastPathComponent().deletingLastPathComponent()
        let runtime = ManagedGStreamerRuntime.runtimeRoot(
            enginesDirectory: enginesDirectory
        )
        let runtimeLibrary = runtime.appendingPathComponent("lib").path
        let plugins = runtime.appendingPathComponent("lib/gstreamer-1.0").path
        let external = engine.appendingPathComponent("lib64/apple_gptk/external").path
        let libraryPath = [
            external,
            engine.appendingPathComponent("lib64").path,
            engine.appendingPathComponent("lib").path,
            runtimeLibrary
        ].joined(separator: ":")
        return [
            "WINEPREFIX": prefix,
            "WINEDEBUG": "-all",
            "WINEMSYNC": "1",
            "WINEESYNC": "1",
            "WINEFSYNC": "1",
            "MVK_CONFIG_LOG_LEVEL": "0",
            "MTL_HUD_ENABLED": "0",
            "WINEDLLOVERRIDES": "mscoree,mshtml=d",
            "DYLD_FALLBACK_LIBRARY_PATH": libraryPath,
            "GST_PLUGIN_SYSTEM_PATH": plugins,
            "GST_PLUGIN_PATH": plugins,
            "GST_PLUGIN_SCANNER": runtime
                .appendingPathComponent("libexec/gstreamer-1.0/gst-plugin-scanner").path,
            "GST_REGISTRY": URL(fileURLWithPath: prefix, isDirectory: true)
                .appendingPathComponent(".vessel-gstreamer-\(ManagedGStreamerRuntime.version).bin")
                .path,
            "GIO_EXTRA_MODULES": runtime.appendingPathComponent("lib/gio/modules").path
        ]
    }

    private static func patchWineGStreamerRPath(_ binary: URL) async throws {
        let output = try await ManagedGStreamerRuntime.runTool(
            "/usr/bin/otool",
            arguments: ["-l", binary.path]
        )
        let rpaths = output.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("path "),
                  let end = trimmed.range(of: " (offset") else { return nil }
            return String(trimmed.dropFirst(5)[..<end.lowerBound])
        }
        for path in rpaths where path.contains("GStreamer.framework") {
            _ = try await ManagedGStreamerRuntime.runTool(
                "/usr/bin/install_name_tool",
                arguments: ["-delete_rpath", path, binary.path]
            )
        }
        if !rpaths.contains(relativeGStreamerRPath) {
            _ = try await ManagedGStreamerRuntime.runTool(
                "/usr/bin/install_name_tool",
                arguments: ["-add_rpath", relativeGStreamerRPath, binary.path]
            )
        }
        _ = try await ManagedGStreamerRuntime.runTool(
            "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", binary.path]
        )
    }

    private nonisolated static func copyReplacing(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: source, to: destination)
    }

    private nonisolated static func preferredWineBinary(in engine: URL) -> String {
        for relativePath in ["bin/wine64", "bin/wine"] {
            let candidate = engine.appendingPathComponent(relativePath)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return engine.appendingPathComponent("bin/wine").path
    }

    private nonisolated static func error(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "Vessel.D3DMetalMediaEngine",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private extension JSONEncoder {
    static var vesselPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
