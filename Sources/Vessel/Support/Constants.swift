import Foundation

enum VesselAppInfo {
    /// La versión visible siempre procede del bundle instalado. Evita que Ajustes y Acerca de
    /// queden desfasados respecto a la Release realmente ejecutada.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Desarrollo"
    }

    static var build: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !value.isEmpty,
              value != version else { return nil }
        return value
    }

    static var displayVersion: String {
        build.map { "\(version) (\($0))" } ?? version
    }
}

enum VesselPaths {
    static let appSupport: String = {
        let home = NSHomeDirectory()
        return "\(home)/Library/Application Support/Vessel"
    }()

    static let bottlesDirectory: String = "\(appSupport)/Bottles"
    static let enginesDirectory: String = "\(appSupport)/Engines"
    static let cacheDirectory: String = "\(appSupport)/Cache"
    /// Juegos DRM‑free descargados por Vessel (itch.io, Humble…), un subdirectorio por juego.
    static let drmFreeDirectory: String = "\(appSupport)/DRMFree"

    static func ensureDirectories() {
        let paths = [appSupport, bottlesDirectory, enginesDirectory, cacheDirectory, drmFreeDirectory]
        for path in paths {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    /// Raíz del repo en DESARROLLO, resuelta de forma relativa a este fichero fuente (`#filePath`),
    /// para NUNCA hardcodear la ruta del usuario en el código (el repo es público). Este fichero vive
    /// en `Sources/Vessel/Support/Constants.swift` → subir 4 niveles llega a la raíz del repo. Solo se
    /// usa como fallback cuando la app corre sin bundle (`swift run`); en la `.app` mandan los recursos
    /// de `Contents/Resources`. En la máquina de otro desarrollador resuelve a SU ruta, sin literales.
    static let devRepoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Support/
        .deletingLastPathComponent()   // Vessel/
        .deletingLastPathComponent()   // Sources/
        .deletingLastPathComponent()   // <repo>/

    /// Recurso empaquetado en `Contents/Resources/<relPath>` de la `.app` o, en desarrollo, en
    /// `<repo>/Resources/<relPath>`. `nil` si no existe en ninguno. Sin rutas de usuario.
    static func bundledResource(_ relPath: String) -> URL? {
        if let res = Bundle.main.resourceURL {
            let inBundle = res.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: inBundle.path) { return inBundle }
        }
        let dev = devRepoRoot.appendingPathComponent("Resources/\(relPath)")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }
}

enum SteamConstants {
    static let setupURL = "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Vessel/0.1"
}
