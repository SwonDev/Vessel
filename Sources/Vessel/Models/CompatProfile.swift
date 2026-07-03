import Foundation
import SwiftUI

/// Perfil de compatibilidad por juego — la capa **comunidad/empaquetada** del sistema
/// de compatibilidad de Vessel (el equivalente declarativo y seguro a `protonfixes`).
///
/// Es **datos puros** (sin código): la app lo parsea sin ejecutar nada externo. Se
/// combina con los *defaults base* y con los *overrides del usuario* (`GameConfig`)
/// para producir la `EffectiveLaunchConfig` con la que arranca cada juego.
///
/// Formato JSON estable (`schemaVersion`), keado por `(tienda, appId)`. Se empaqueta
/// dentro de la app (offline desde el día 1) y se actualiza desde el repo comunitario
/// `SwonDev/Vessel_DB`.
struct CompatProfile: Codable, Equatable, Identifiable, Sendable {

    /// Nivel de compatibilidad (tiers de ProtonDB).
    enum Rating: String, Codable, CaseIterable, Sendable {
        case platinum, gold, silver, bronze, borked

        var label: String {
            switch self {
            case .platinum: return "Platino"
            case .gold:     return "Oro"
            case .silver:   return "Plata"
            case .bronze:   return "Bronce"
            case .borked:   return "No funciona"
            }
        }
        /// Descripción del tier para la ficha del juego.
        var detail: String {
            switch self {
            case .platinum: return "Funciona de fábrica, sin tocar nada."
            case .gold:     return "Funciona perfecto con este perfil aplicado."
            case .silver:   return "Jugable con problemas menores."
            case .bronze:   return "Arranca, pero con problemas notables."
            case .borked:   return "No arranca o es injugable por ahora."
            }
        }
        var color: Color {
            switch self {
            case .platinum: return Color(red: 0.62, green: 0.84, blue: 0.92)
            case .gold:     return Color(red: 0.95, green: 0.77, blue: 0.30)
            case .silver:   return Color(red: 0.78, green: 0.80, blue: 0.84)
            case .bronze:   return Color(red: 0.80, green: 0.52, blue: 0.30)
            case .borked:   return Color(red: 0.86, green: 0.36, blue: 0.36)
            }
        }
        var systemImage: String {
            switch self {
            case .platinum: return "trophy.fill"
            case .gold:     return "medal.fill"
            case .silver:   return "medal"
            case .bronze:   return "exclamationmark.triangle.fill"
            case .borked:   return "xmark.octagon.fill"
            }
        }
        /// Orden de mayor a menor compatibilidad (para comparar/ordenar).
        var rank: Int {
            switch self {
            case .platinum: return 4
            case .gold:     return 3
            case .silver:   return 2
            case .bronze:   return 1
            case .borked:   return 0
            }
        }
    }

    /// Motor recomendado. Mapea a la selección de motor de Vessel (la mayoría de juegos
    /// van bien en `auto`: el enrutado por API ya elige Gcenx/wine-dxmt/CrossOver/GPTK).
    enum Engine: String, Codable, Sendable {
        case auto, gcenx, dxmt, gptk
    }

    /// Capa gráfica recomendada. `auto` deja que Vessel detecte la API y elija.
    enum GraphicsLayer: String, Codable, Sendable {
        case auto, dxmt, gptk, wined3d, dxvk, opengl

        /// Mapea a la capa que entiende `WineManager.launch(graphicsOverride:)`.
        /// (auto/dxmt/gptk son las que enruta hoy; el resto se logra vía dll/env.)
        var asGameConfigLayer: GameConfig.GraphicsLayer {
            switch self {
            case .dxmt:  return .dxmt
            case .gptk:  return .gptk
            default:     return .auto
            }
        }
    }

    /// Identificadores del juego por tienda (claves de la BD).
    struct StoreRef: Codable, Equatable, Sendable {
        var steam: String? = nil   // AppID de Steam (la clave más universal)
        var gog: String? = nil     // product id de GOG
        var epic: String? = nil    // appName/slug de Epic
    }

    /// Entorno de prueba donde se validó el perfil (para informar y caducar ratings).
    struct TestedOn: Codable, Equatable, Sendable {
        var macOS: String? = nil
        var chip: String? = nil
        var vesselVersion: String? = nil
    }

    var schemaVersion: Int = 1
    var title: String
    var stores: StoreRef = StoreRef()
    var rating: Rating = .gold

    var engine: Engine = .auto
    var graphicsLayer: GraphicsLayer = .auto
    var windowsVersion: String? = nil   // "win10", "win11"…
    var windowsArch: String? = nil      // "win32" | "win64"

    var dllOverrides: [String: String] = [:]   // p. ej. {"d3d11":"native,builtin"}
    var envVars: [String: String] = [:]        // p. ej. {"DXVK_ASYNC":"1"}
    var launchArgs: [String] = []              // p. ej. ["-force-gfx-direct"]
    var winetricksVerbs: [String] = []         // p. ej. ["vcrun2019","d3dx9_43"]

    var notes: String? = nil
    var testedOn: TestedOn? = nil
    var author: String? = nil
    var date: String? = nil
    var verified: Bool = false

    /// Modo **"Steam real"**: el juego necesita el cliente Steam REAL corriendo y
    /// conectado (DRM real, como CrossOver) porque NO arranca standalone con Goldberg.
    /// Vessel arranca el cliente Steam en el motor unificado y lanza el juego en el
    /// MISMO wineserver con su `steam_api` original → `SteamAPI_Init` habla con el
    /// cliente vivo y el juego renderiza por DXMT→Metal. P. ej. Grim Dawn (muere en la
    /// init de su Engine.dll con exit 53 en modo standalone). Requiere sesión iniciada.
    var useRealSteam: Bool = false

    /// Id estable para de-duplicar (preferimos Steam AppID por universalidad).
    var id: String { stores.steam ?? stores.gog ?? stores.epic ?? title.lowercased() }

    init(title: String, stores: StoreRef = StoreRef(), rating: Rating = .gold) {
        self.title = title
        self.stores = stores
        self.rating = rating
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, title, stores, rating, engine, graphicsLayer
        case windowsVersion, windowsArch, dllOverrides, envVars, launchArgs
        case winetricksVerbs, notes, testedOn, author, date, verified
        case useRealSteam
    }

    /// Decodificación TOLERANTE: solo `title` es obligatorio; todo lo demás usa su
    /// valor por defecto si falta en el JSON (el decoder sintetizado de Swift NO usa
    /// los defaults, y los perfiles de la comunidad son intencionadamente parciales).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        stores = try c.decodeIfPresent(StoreRef.self, forKey: .stores) ?? StoreRef()
        rating = try c.decodeIfPresent(Rating.self, forKey: .rating) ?? .gold
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? .auto
        graphicsLayer = try c.decodeIfPresent(GraphicsLayer.self, forKey: .graphicsLayer) ?? .auto
        windowsVersion = try c.decodeIfPresent(String.self, forKey: .windowsVersion)
        windowsArch = try c.decodeIfPresent(String.self, forKey: .windowsArch)
        dllOverrides = try c.decodeIfPresent([String: String].self, forKey: .dllOverrides) ?? [:]
        envVars = try c.decodeIfPresent([String: String].self, forKey: .envVars) ?? [:]
        launchArgs = try c.decodeIfPresent([String].self, forKey: .launchArgs) ?? []
        winetricksVerbs = try c.decodeIfPresent([String].self, forKey: .winetricksVerbs) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        testedOn = try c.decodeIfPresent(TestedOn.self, forKey: .testedOn)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        useRealSteam = try c.decodeIfPresent(Bool.self, forKey: .useRealSteam) ?? false
    }
}

/// Configuración EFECTIVA con la que arranca un juego: el resultado de combinar
/// **defaults base → perfil de compatibilidad → overrides del usuario**.
/// `WineManager.launch` la consume para aplicar overrides de DLL, env, args, versión
/// de Windows y sincronización sin romper el enrutado por API ya validado.
struct EffectiveLaunchConfig: Sendable {
    /// Capa gráfica para el enrutado de `launch()` (auto/dxmt/gptk).
    var graphicsOverride: GameConfig.GraphicsLayer = .auto
    /// Variables de entorno extra (perfil + usuario), pisan al entorno base.
    var extraEnv: [String: String] = [:]
    /// Overrides de DLL a fusionar en `WINEDLLOVERRIDES` (p. ej. d3d11=native).
    var dllOverrides: [String: String] = [:]
    /// Argumentos extra a añadir al ejecutable.
    var launchArgs: [String] = []
    /// Verbos de winetricks recomendados (se informan/aplican en preparación del prefijo).
    var winetricksVerbs: [String] = []
    /// Versión de Windows a fijar en el prefijo (winecfg), si el perfil la pide.
    var windowsVersion: String? = nil
    /// Sincronización (cableada de verdad desde el perfil/usuario; antes era fija).
    var esync: Bool = true
    var fsync: Bool = false
    var msync: Bool = true
    /// Modo Retina (DPI 192) — nitidez en pantallas Apple, como hace Mythic.
    var retina: Bool = true
    /// HUD de rendimiento de Metal (FPS / tiempos de frame) superpuesto. Ajuste del usuario.
    var metalHUD: Bool = false

    /// Procedencia (para logs/UI): de dónde salió la config aplicada.
    var rating: CompatProfile.Rating? = nil
    var verified: Bool = false
    var fromProfile: Bool = false

    /// Modo **"Steam real"**: lanzar con el cliente Steam conectado + `steam_api` original
    /// (DRM real, como CrossOver) en vez de Goldberg standalone. Para juegos que NO arrancan
    /// standalone (p. ej. Grim Dawn). Enruta `launch()` a `launchViaRealSteam`.
    var useRealSteam: Bool = false

    /// Construye el fragmento de `WINEDLLOVERRIDES` de los overrides de DLL del perfil.
    /// Formato Wine: `dll1=mode;dll2=mode` (mode admite `n`,`b`,`n,b`, etc.).
    var dllOverridesString: String {
        dllOverrides
            .map { "\($0.key)=\(normalizeMode($0.value))" }
            .sorted()
            .joined(separator: ";")
    }

    private func normalizeMode(_ raw: String) -> String {
        // Acepta "native,builtin" / "native" / "n,b" / "disabled" y normaliza a tokens Wine.
        raw.lowercased()
            .replacingOccurrences(of: "native", with: "n")
            .replacingOccurrences(of: "builtin", with: "b")
            .replacingOccurrences(of: "disabled", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}
