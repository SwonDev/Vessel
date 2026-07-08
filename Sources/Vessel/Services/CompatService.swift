import Foundation

/// Servicio central de **compatibilidad por juego** de Vessel.
///
/// Mantiene la base de datos de `CompatProfile` (capa comunidad) combinando:
///  1. **BD empaquetada** dentro de la app (`Resources/CompatDB/compat-db.json`) →
///     funciona offline desde el primer arranque, con los juegos ya validados.
///  2. **BD remota** del repo comunitario `SwonDev/Vessel_DB` (`index.json`), que se
///     descarga como mucho **una vez al día** y se cachea en App Support. La remota
///     pisa a la empaquetada por `id`.
///
/// Expone la búsqueda por `(tienda, appId)`/título y la resolución de la
/// `EffectiveLaunchConfig` (defaults base → perfil → overrides del usuario).
@MainActor
@Observable
final class CompatService {
    static let shared = CompatService()

    /// URL del `index.json` del repo comunitario (raw GitHub).
    static let remoteIndexURL = URL(string: "https://raw.githubusercontent.com/SwonDev/Vessel_DB/main/index.json")!
    /// URL base para reportar compatibilidad (issue pre-rellenado).
    static let repoIssuesURL = "https://github.com/SwonDev/Vessel_DB/issues/new"

    /// Sobre del fichero de BD (empaquetado y remoto comparten formato).
    struct Database: Codable {
        var schemaVersion: Int = 1
        var profiles: [CompatProfile] = []
    }

    private(set) var profiles: [CompatProfile] = []

    // Índices de búsqueda rápida.
    private var bySteam: [String: CompatProfile] = [:]
    private var byGOG: [String: CompatProfile] = [:]
    private var byEpic: [String: CompatProfile] = [:]
    private var byTitle: [String: CompatProfile] = [:]

    private let cacheURL: URL = URL(fileURLWithPath: "\(VesselPaths.cacheDirectory)/compat/index.json")
    private let lastFetchKey = "compat.lastRemoteFetch"

    private init() {
        try? FileManager.default.createDirectory(
            atPath: cacheURL.deletingLastPathComponent().path, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Carga / merge

    /// Recarga la BD: empaquetada (base) + remota cacheada (pisa por id) y reconstruye índices.
    func reload() {
        var merged: [String: CompatProfile] = [:]
        for p in loadBundled() { merged[p.id] = p }
        for p in loadCachedRemote() {
            // La remota (comunidad) gana SOLO si NO es más ANTIGUA que la del bundle. Antes ganaba
            // siempre, y una entrada comunitaria vieja PISABA un fix recién shippeado en el bundle
            // (p. ej. `useRealSteam` de FFT se perdía → no arrancaba). Comparación por `date`
            // (YYYY-MM-DD, ordenable como string). Si alguna no tiene fecha, gana la remota (comportamiento previo).
            if let bundled = merged[p.id], let bd = bundled.date, let rd = p.date, rd < bd { continue }
            merged[p.id] = p
        }
        profiles = Array(merged.values)
        rebuildIndices()
        LogStore.shared.log("Compatibilidad: \(profiles.count) perfil(es) cargados", level: .debug)
    }

    private func rebuildIndices() {
        bySteam.removeAll(); byGOG.removeAll(); byEpic.removeAll(); byTitle.removeAll()
        for p in profiles {
            if let s = p.stores.steam { bySteam[s] = p }
            if let g = p.stores.gog { byGOG[g] = p }
            if let e = p.stores.epic { byEpic[e.lowercased()] = p }
            byTitle[Self.normalizeTitle(p.title)] = p
        }
    }

    private func loadBundled() -> [CompatProfile] {
        guard let url = Self.bundledDatabaseURL,
              let data = try? Data(contentsOf: url),
              let db = try? JSONDecoder().decode(Database.self, from: data) else { return [] }
        return db.profiles
    }

    private func loadCachedRemote() -> [CompatProfile] {
        guard let data = try? Data(contentsOf: cacheURL),
              let db = try? JSONDecoder().decode(Database.self, from: data) else { return [] }
        return db.profiles
    }

    /// Ruta del JSON empaquetado: dentro del `.app` o, en desarrollo, el repo.
    static var bundledDatabaseURL: URL? {
        VesselPaths.bundledResource("CompatDB/compat-db.json")
    }

    // MARK: - Búsqueda

    /// Busca el perfil del juego por (Steam → GOG → Epic → título normalizado).
    func profile(steam: String? = nil, gog: String? = nil, epic: String? = nil, title: String = "") -> CompatProfile? {
        if let s = steam, let p = bySteam[s] { return p }
        if let g = gog, let p = byGOG[g] { return p }
        if let e = epic, let p = byEpic[e.lowercased()] { return p }
        if !title.isEmpty, let p = byTitle[Self.normalizeTitle(title)] { return p }
        return nil
    }

    static func normalizeTitle(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    // MARK: - Resolución de config efectiva

    /// Combina **defaults base → perfil de compatibilidad → overrides del usuario**.
    /// El usuario siempre gana sobre el perfil; el perfil gana sobre los defaults.
    func effectiveConfig(profile: CompatProfile?, user: GameConfig) -> EffectiveLaunchConfig {
        var cfg = EffectiveLaunchConfig()   // defaults base (msync/esync on, fsync off, retina on)

        if let p = profile {
            cfg.graphicsOverride = p.graphicsLayer.asGameConfigLayer
            // wined3d/dxvk/opengl NO son capas de enrutado de primera clase en Vessel (el enum de
            // lanzamiento es auto/dxmt/gptk). En vez de descartarlas en silencio, avisamos: su
            // intención se logra normalmente vía los dllOverrides/envVars del propio perfil
            // (que sí se aplican). Routing completo de dxvk exigiría instalar DXVK y, para FL 11_0,
            // ni siquiera funciona (Metal no tiene geometry shaders) → no se fuerza a ciegas.
            switch p.graphicsLayer {
            case .wined3d, .dxvk, .opengl:
                LogStore.shared.log("Perfil '\(p.title)' pide capa gráfica '\(p.graphicsLayer.rawValue)': Vessel la aproxima con auto-detección; usa dllOverrides/envVars del perfil para forzarla.", level: .info)
            case .auto, .dxmt, .gptk:
                break
            }
            cfg.dllOverrides = p.dllOverrides
            cfg.extraEnv = p.envVars
            cfg.launchArgs = p.launchArgs
            cfg.winetricksVerbs = p.winetricksVerbs
            cfg.windowsVersion = p.windowsVersion
            cfg.rating = p.rating
            cfg.verified = p.verified
            cfg.useRealSteam = p.useRealSteam
            cfg.fromProfile = true
        }

        // Overrides del usuario (ganan). La capa gráfica explícita del usuario manda.
        if user.graphicsLayer != .auto { cfg.graphicsOverride = user.graphicsLayer }
        cfg.esync = user.esync
        cfg.fsync = user.fsync
        cfg.metalHUD = user.metalHUD
        // Steam-real: el override del usuario/auto-repair SUMA (nunca desactiva lo que pida el perfil).
        if user.useRealSteam { cfg.useRealSteam = true }
        let userArgs = user.launchArguments.split(separator: " ").map(String.init)
        cfg.launchArgs += userArgs

        return cfg
    }

    /// ¿Debe aplicarse el perfil en silencio? Política elegida: **verificados en
    /// silencio; los no verificados se avisan** (la UI muestra el aviso).
    func shouldApplySilently(_ profile: CompatProfile?) -> Bool {
        profile?.verified ?? true   // sin perfil → defaults base, silencioso
    }

    // MARK: - Reporte comunitario (GitHub)

    /// Nombre del chip (p. ej. "Apple M5 Pro") vía sysctl.
    static func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var brand = [UInt8](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        if let nul = brand.firstIndex(of: 0) { brand.removeSubrange(nul...) }
        return String(decoding: brand, as: UTF8.self)
    }

    /// Versión de Vessel (CFBundleShortVersionString).
    static var vesselVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// Resumen de sistema para el reporte. **Anónimo a propósito**: solo modelo de chip,
    /// versión de macOS y versión de Vessel. NUNCA incluye usuario, nombre de equipo,
    /// número de serie ni ningún identificador personal.
    static func systemSummary() -> String {
        "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(chipName()) · Vessel \(vesselVersion)"
    }

    /// Cuerpo del reporte de compatibilidad, **anónimo**. Reutilizado por la URL de issue
    /// de GitHub y por la opción de copiar al portapapeles (para quien no quiera usar GitHub).
    static func reportBody(gameTitle: String, store: String, storeId: String?) -> String {
        let idLine = storeId.map { "- **AppID (\(store))**: \($0)" } ?? "- **Tienda**: \(store)"
        return """
        ## Reporte de compatibilidad (anónimo)

        > 🔒 Este reporte es **anónimo**: incluye solo el juego, datos técnicos del sistema
        > (macOS, chip, versión de Vessel) y tus notas. **No** contiene tu nombre de usuario,
        > correo, nombre del equipo ni ningún dato personal, y nada se envía automáticamente.

        - **Juego**: \(gameTitle)
        \(idLine)
        - **Sistema**: \(systemSummary())

        ### ¿Cómo te ha ido?
        <!-- Marca uno: 🏆 Platino (va de fábrica) · 🥇 Oro (va perfecto) · 🥈 Plata (bugs menores) · 🥉 Bronce (problemas notables) · ❌ No funciona -->
        **Rating**:

        ### ¿Qué configuración usaste? (si tocaste algo)
        <!-- Capa gráfica, flags de lanzamiento, overrides… o "todo automático" -->

        ### Notas / errores
        <!-- Describe el problema. Si pegas rutas de los logs, sustituye tu nombre de usuario por <usuario> -->
        """
    }

    /// Construye la URL de un issue de GitHub PRE-RELLENADO (cuerpo anónimo) en
    /// `SwonDev/Vessel_DB`. El usuario revisa y decide si lo envía (nada es automático).
    static func reportIssueURL(gameTitle: String, store: String, storeId: String?) -> URL? {
        var comps = URLComponents(string: CompatService.repoIssuesURL)
        comps?.queryItems = [
            URLQueryItem(name: "title", value: "[Compat] \(gameTitle)"),
            URLQueryItem(name: "labels", value: "compat-report"),
            URLQueryItem(name: "body", value: reportBody(gameTitle: gameTitle, store: store, storeId: storeId))
        ]
        return comps?.url
    }

    // MARK: - Descarga remota (1×/día)

    /// Clave de preferencia: auto-actualizar la BD desde el repo (default ON). Si el
    /// usuario la desactiva, Vessel funciona 100% LOCAL con la BD empaquetada (privacidad).
    static let autoUpdateKey = "compat.autoUpdate"

    /// Descarga el `index.json` del repo comunitario si pasó ≥1 día desde la última vez.
    /// Cachea en App Support y recarga la BD. No lanza: ante fallo de red, se conserva
    /// la BD empaquetada/cacheada. **Es una descarga de solo lectura**: no envía ningún
    /// dato personal (solo la petición HTTP GET inherente). Respeta el modo local.
    func refreshRemoteIfNeeded(force: Bool = false) async {
        // Privacidad / uso local ante todo: si el usuario desactivó la auto-actualización,
        // no se contacta con el repo (la BD empaquetada ya cubre offline).
        let autoUpdate = UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool ?? true
        guard force || autoUpdate else {
            LogStore.shared.log("Compatibilidad: auto-actualización desactivada (modo local)", level: .debug)
            return
        }
        if !force, let last = UserDefaults.standard.object(forKey: lastFetchKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 { return }
        do {
            var req = URLRequest(url: Self.remoteIndexURL)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                LogStore.shared.log("Compatibilidad: índice remoto no disponible (se usa BD local)", level: .debug)
                return
            }
            // Validar que parsea antes de cachear.
            guard let db = try? JSONDecoder().decode(Database.self, from: data) else {
                LogStore.shared.log("Compatibilidad: índice remoto con formato inválido (ignorado)", level: .warn)
                return
            }
            try data.write(to: cacheURL, options: .atomic)
            UserDefaults.standard.set(Date(), forKey: lastFetchKey)
            reload()
            LogStore.shared.log("Compatibilidad: BD actualizada del repo (\(db.profiles.count) perfiles)", level: .info)
        } catch {
            LogStore.shared.log("Compatibilidad: no se pudo actualizar la BD remota (\(error.localizedDescription))", level: .debug)
        }
    }
}
