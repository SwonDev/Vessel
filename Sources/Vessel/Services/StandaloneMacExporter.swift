import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Exporta un juego DRM‑free como una **app de macOS autónoma** (`.app`) para **Apple Silicon**:
/// empaqueta el juego + el **motor unificado ya compilado** (Wine+DXMT) + un launcher que crea su
/// propio prefijo y arranca el juego por DXMT→Metal — **sin Vessel instalado**. Copiable a un USB y
/// ejecutable en cualquier Mac Silicon (con Rosetta 2, igual que Vessel). El juego ya trae Goldberg,
/// así que no necesita Steam.
///
/// Es grande (~2.2 GB de motor + el juego) porque incluye TODO el runtime — ese es el precio de que
/// sea 100% independiente, como pediste.
actor StandaloneMacExporter {
    static let shared = StandaloneMacExporter()

    enum ExportError: LocalizedError {
        case noEngine, noGameFolder, copyFailed(String), signFailed
        var errorDescription: String? {
            switch self {
            case .noEngine: return "No se encontró el motor unificado (instálalo jugando un juego primero)."
            case .noGameFolder: return "El juego no tiene una carpeta local que empaquetar."
            case .copyFailed(let w): return "Fallo al copiar \(w)."
            case .signFailed: return "No se pudo firmar la app exportada."
            }
        }
    }

    /// Genera `<destParent>/<Nombre>.app` autónomo. `gameFolder` es la carpeta del juego DRM‑free,
    /// `exePath` su ejecutable. `progress` = (fracción 0…1, mensaje).
    func exportMacApp(name: String, gameFolder: String, exePath: String, coverURL: String? = nil,
                      destParent: URL,
                      progress: @Sendable @escaping (Double, String) -> Void) async throws -> URL {
        let fm = FileManager.default
        let engineDir = "\(VesselPaths.enginesDirectory)/\(WineEngineLocator.unifiedEngineName)"
        guard fm.isExecutableFile(atPath: "\(engineDir)/bin/wine") else { throw ExportError.noEngine }
        guard fm.fileExists(atPath: gameFolder) else { throw ExportError.noGameFolder }

        let slug = Self.sanitize(name)
        let appURL = destParent.appendingPathComponent("\(slug).app")
        try? fm.removeItem(at: appURL)
        let contents = appURL.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        // 1) Motor (lo más pesado, ~2.2 GB) → Resources/engine, con progreso por sondeo de tamaño.
        progress(0.02, "Copiando el motor (Wine + DXMT)…")
        let engineTotal = Self.dirSize(engineDir)
        try await Self.copyTree(from: engineDir, to: resources.appendingPathComponent("engine").path,
                                totalBytes: engineTotal) { f in progress(0.02 + f * 0.78, "Copiando el motor… \(Int(f*100))%") }

        // 2) Juego → Resources/game.
        progress(0.82, "Copiando los archivos del juego…")
        let gameTotal = Self.dirSize(gameFolder)
        try await Self.copyTree(from: gameFolder, to: resources.appendingPathComponent("game").path,
                                totalBytes: gameTotal) { f in progress(0.82 + f * 0.12, "Copiando el juego… \(Int(f*100))%") }

        // Ruta relativa del ejecutable dentro de game/.
        let relExe: String
        if exePath.hasPrefix(gameFolder) {
            relExe = String(exePath.dropFirst(gameFolder.count)).drop(while: { $0 == "/" }).description
        } else {
            relExe = (exePath as NSString).lastPathComponent
        }

        // 2b) DLLs de **DXMT** junto al exe (D3D11/DXGI/D3D10 → Metal). Es lo que hace Vessel al jugar
        // (`ensureGameDXMTDLLs`): sin esto, UnityPlayer no encuentra d3d11.dll y el juego no arranca.
        // VALIDADO: con estas DLLs el juego renderiza standalone por DXMT→Metal. Solo en la copia del
        // `.app` (la exportación Windows queda limpia, porque en un PC Windows manda su propio d3d11).
        let exeDirInApp = (resources.appendingPathComponent("game").appendingPathComponent(relExe).path as NSString).deletingLastPathComponent
        let dxmtSrc = "\(engineDir)/lib/wine/x86_64-windows"
        for dll in ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "d3d10.dll", "d3d10_1.dll", "winemetal.dll"] {
            let src = "\(dxmtSrc)/\(dll)", dst = "\(exeDirInApp)/\(dll)"
            if fm.fileExists(atPath: src) { try? fm.removeItem(atPath: dst); try? fm.copyItem(atPath: src, toPath: dst) }
        }

        // 3) Icono del juego (carátula → .icns squircle). Si no hay portada (p. ej. un .exe suelto
        // añadido a mano), cae al logo DRM‑free bundleado para que el .app nunca salga sin icono.
        progress(0.95, "Creando el icono…")
        var hasIcon = false
        if let coverURL, let url = URL(string: coverURL),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            hasIcon = Self.buildAppIcon(coverData: data, into: resources.path)
        }
        if !hasIcon, let fallback = VesselPaths.bundledResource("store-local.png"),
           let data = try? Data(contentsOf: fallback) {
            hasIcon = Self.buildAppIcon(coverData: data, into: resources.path)
        }

        // 4) Launcher + Info.plist.
        progress(0.96, "Escribiendo el launcher…")
        try Self.launcherScript(appName: slug, relExe: relExe).write(
            to: macOS.appendingPathComponent("launch"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS.appendingPathComponent("launch").path)
        try Self.infoPlist(appName: slug, hasIcon: hasIcon).write(
            to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        // 5) Firma ad-hoc (deep) + quitar quarantine local.
        progress(0.98, "Firmando la app…")
        await Self.stripQuarantine(appURL.path)
        _ = await Self.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", appURL.path])

        // 6) LÉEME junto al .app (explica el aviso de Gatekeeper la 1ª vez, Rosetta y dónde van las
        // partidas). Va FUERA del .app para no alterar la firma.
        let readme = destParent.appendingPathComponent("LÉEME — Cómo abrir \(slug).txt")
        try? Self.macReadme(name: slug).write(to: readme, atomically: true, encoding: .utf8)

        progress(1.0, "Listo")
        return appURL
    }

    private static func macReadme(name: String) -> String {
        """
        \(name) — juego DRM‑free para Mac (Apple Silicon)
        Creado con Vessel · https://github.com/SwonDev/Vessel

        Este juego es TUYO y no lleva DRM: se ejecuta SIN Steam y SIN Vessel.

        CÓMO ABRIR (solo la primera vez, en otro Mac)
        1. Haz clic derecho (o Control+clic) sobre «\(name).app» y elige «Abrir».
        2. En el aviso de seguridad de macOS, pulsa «Abrir» otra vez.
           (La app va firmada localmente, no con una cuenta de desarrollador de Apple,
            así que macOS pide esta confirmación una única vez.)

        REQUISITOS
        · Mac con Apple Silicon (M1 o posterior).
        · Rosetta 2. Si falta, en la Terminal:
            softwareupdate --install-rosetta --agree-to-license

        TUS PARTIDAS se guardan en:
            ~/Library/Application Support/Vessel Games/\(name)/

        Motor incluido en la app: Wine + DXMT (Direct3D → Metal). Todo autocontenido.
        """
    }

    // MARK: - Launcher

    private static func launcherScript(appName: String, relExe: String) -> String {
        // Nota: rutas con espacios entre comillas. El motor es x86_64 → corre bajo Rosetta 2.
        """
        #!/bin/bash
        # Launcher autónomo generado por Vessel — ejecuta este juego DRM‑free en cualquier Mac Silicon
        # SIN Vessel, usando el motor Wine+DXMT empaquetado. El juego ya trae Goldberg (sin Steam).
        HERE="$(cd "$(dirname "$0")" && pwd)"
        CONTENTS="$(dirname "$HERE")"
        RES="$CONTENTS/Resources"
        ENGINE="$RES/engine"
        GAME="$RES/game"
        APPNAME="\(appName)"
        PREFIX="$HOME/Library/Application Support/Vessel Games/$APPNAME"
        WINE="$ENGINE/bin/wine"

        # Rosetta 2 es imprescindible (el motor es x86_64, como en Vessel).
        if ! /usr/bin/pgrep -q oahd && ! /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
          /usr/bin/osascript -e 'display alert "Falta Rosetta 2" message "Este juego usa un motor x86_64. Instálalo con:\\n\\nsoftwareupdate --install-rosetta --agree-to-license" as critical' >/dev/null 2>&1
          exit 1
        fi

        export WINEPREFIX="$PREFIX"
        export WINEDEBUG="-all"
        export WINEESYNC="1"
        export DYLD_FALLBACK_LIBRARY_PATH="$ENGINE/lib:/usr/lib"

        # Primera ejecución (venimos de un USB/copia): quitar quarantine de todo el runtime, o macOS
        # bloqueará las dylibs del motor. Requiere que el usuario haya abierto la app una vez (botón
        # derecho → Abrir) para pasar Gatekeeper.
        FLAG="$PREFIX/.ready"
        if [ ! -f "$FLAG" ]; then
          /usr/bin/xattr -dr com.apple.quarantine "$RES" >/dev/null 2>&1 || true
          mkdir -p "$PREFIX"
          "$WINE" wineboot --init >/dev/null 2>&1 || true
          "$ENGINE/bin/wineserver" -w >/dev/null 2>&1 || true
          touch "$FLAG"
        fi

        cd "$GAME" || exit 1
        exec "$WINE" "$GAME/\(relExe)" "$@"
        """
    }

    private static func infoPlist(appName: String, hasIcon: Bool) -> String {
        let iconKey = hasIcon ? "  <key>CFBundleIconFile</key><string>icon</string>\n" : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleName</key><string>\(appName)</string>
          <key>CFBundleDisplayName</key><string>\(appName)</string>
          <key>CFBundleIdentifier</key><string>com.swondev.vessel.export.\(Self.bundleSlug(appName))</string>
          <key>CFBundleExecutable</key><string>launch</string>
        \(iconKey)  <key>CFBundlePackageType</key><string>APPL</string>
          <key>CFBundleShortVersionString</key><string>1.0</string>
          <key>CFBundleVersion</key><string>1</string>
          <key>LSMinimumSystemVersion</key><string>13.0</string>
          <key>NSHighResolutionCapable</key><true/>
        </dict>
        </plist>
        """
    }

    // MARK: - Icono (.icns squircle desde la carátula, con CoreGraphics)

    /// Construye `Resources/icon.icns` a partir de la carátula: recorte a cuadrado (aspect‑fill) con
    /// máscara **squircle** (esquinas redondeadas, estilo macOS), y genera todas las resoluciones vía
    /// `iconutil`. Todo con CoreGraphics (sin ImageMagick).
    private static func buildAppIcon(coverData: Data, into resourcesDir: String) -> Bool {
        guard let src = CGImageSourceCreateWithData(coverData as CFData, nil),
              let cover = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let master = renderSquircle(cover, size: 1024) else { return false }
        let iconset = "\(NSTemporaryDirectory())vessel-icon-\(UUID().uuidString).iconset"
        try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: iconset) }
        let variants: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
            ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)
        ]
        for (nm, sz) in variants {
            guard let scaled = scaleImage(master, to: sz), writePNG(scaled, to: "\(iconset)/\(nm).png") else { return false }
        }
        let out = "\(resourcesDir)/icon.icns"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", iconset, "-o", out]
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return FileManager.default.fileExists(atPath: out)
    }

    private static func renderSquircle(_ image: CGImage, size: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let radius = CGFloat(size) * 0.2237   // ~squircle de macOS
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        // aspect‑fill (recorta al centro para llenar el cuadrado)
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = max(CGFloat(size) / iw, CGFloat(size) / ih)
        let dw = iw * scale, dh = ih * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(size) - dw) / 2, y: (CGFloat(size) - dh) / 2, width: dw, height: dh))
        return ctx.makeImage()
    }

    private static func scaleImage(_ image: CGImage, to size: Int) -> CGImage? {
        if image.width == size && image.height == size { return image }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    private static func writePNG(_ image: CGImage, to path: String) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - Utilidades (copia con progreso, tamaño, firma)

    private static func copyTree(from src: String, to dest: String, totalBytes: Int64,
                                 _ onProgress: @Sendable @escaping (Double) -> Void) async throws {
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = [src, dest]
        try p.run()
        let total = max(totalBytes, 1)
        while p.isRunning {
            try? await Task.sleep(for: .milliseconds(1200))
            onProgress(min(0.999, Double(dirSize(dest)) / Double(total)))
        }
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw ExportError.copyFailed((src as NSString).lastPathComponent) }
        onProgress(1.0)
    }

    static func dirSize(_ path: String) -> Int64 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return 0 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let s = String(data: data, encoding: .utf8), let kb = Int64(s.split(separator: "\t").first ?? "") else { return 0 }
        return kb * 1024
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) async -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }

    private static func stripQuarantine(_ path: String) async {
        _ = await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", path])
    }

    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(s.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Juego" : cleaned
    }
    private static func bundleSlug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let c = String(s.unicodeScalars.filter { allowed.contains($0) }).lowercased()
        return c.isEmpty ? "game" : c
    }
}
