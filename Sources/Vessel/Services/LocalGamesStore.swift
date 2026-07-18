import Foundation

/// **Biblioteca DRM‑free** de Vessel: agrega TODO lo que no lleva DRM y es del usuario —
/// exes/instaladores sueltos, juegos de **itch.io** y de **Humble Bundle** (y GOG offline).
/// Cada entrada puede estar **instalada** (tiene `executablePath`) o solo en la biblioteca
/// (aún sin descargar). Vessel los ejecuta con el motor gráfico óptimo + auto‑reparación +
/// backup de partidas, igual que los de tienda. Persiste en App Support (JSON).
@MainActor
@Observable
final class LocalGamesStore {
    static let shared = LocalGamesStore()

    /// Origen del juego DRM‑free.
    enum Source: String, Codable, Hashable {
        case local        // .exe / instalador añadido a mano
        case itch         // itch.io (biblioteca vinculada)
        case humble       // Humble Bundle (biblioteca vinculada)
        case gog          // GOG (biblioteca vinculada) — DRM‑free por política de la tienda
        case gogOffline   // instalador offline de GOG añadido a mano
        case epic         // Epic — solo los que la propia Epic declara sin token de propiedad
        case steam        // copia local DRM‑free generada desde un juego de Steam sin CEG

        var displayName: String {
            switch self {
            case .local: return "Local"
            case .itch: return "itch.io"
            case .humble: return "Humble Bundle"
            case .gog: return "GOG"
            case .gogOffline: return "GOG offline"
            case .epic: return "Epic"
            case .steam: return "Steam (DRM‑free)"
            }
        }
    }

    /// Cómo se ejecuta el juego. Un build **nativo** de macOS es SIEMPRE preferible: corre sin Wine,
    /// sin Rosetta y con el rendimiento real de la máquina. Muchos indies de itch/Humble lo tienen.
    enum Platform: String, Codable, Hashable {
        case windows   // `.exe` → se ejecuta con el motor Wine
        case mac       // `.app` nativo → se abre directamente
        var label: String { self == .mac ? "Nativo de Mac" : "Windows (Wine)" }
    }

    struct Game: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var name: String
        /// De dónde viene (para agrupar/filtrar y saber cómo descargar/actualizar).
        var source: Source = .local
        /// Id estable dentro de su fuente (itch: id del download‑key; humble: "gamekey:machine_name").
        /// Sirve para deduplicar al re‑sincronizar la biblioteca. `nil` para juegos locales.
        var sourceId: String?
        /// Ruta a lo que se lanza: el `.exe` de Windows o el `.app` nativo (ver `platform`). Vacía si
        /// la entrada está en la biblioteca pero aún NO se ha descargado/instalado.
        var executablePath: String = ""
        /// Windows (vía Wine) o nativo de macOS. Se decide al descargar, prefiriendo lo nativo.
        var platform: Platform = .windows
        /// Argumentos con los que hay que lanzar el ejecutable. Casi siempre vacío, pero los juegos
        /// clásicos de GOG son DOS/ScummVM envueltos y su ejecutable es `DOSBOX\dosbox.exe`, que
        /// SIN `-conf …` abre un prompt de DOS en vez del juego. Los declara el propio GOG.
        var launchArguments: [String] = []
        /// Huella de la versión instalada (md5/build del origen). Si el build publicado tiene otra,
        /// hay actualización. `nil` = instalado antes de que existiera este control, o fuente sin versión.
        var installedVersion: String?
        /// `true` si la última comprobación encontró una versión nueva en el origen.
        var updateAvailable: Bool = false
        /// Directorio donde Vessel instaló el juego (para descargas de itch/humble). `nil` si es
        /// un `.exe` que el usuario apuntó en su sitio.
        var installPath: String?
        /// URL de descarga resuelta (itch/humble), si se conoce sin re‑consultar la API.
        var downloadURL: String?
        /// Carátula local elegida por el usuario.
        var coverPath: String?
        /// Carátula remota (itch/humble) — se muestra directamente por URL.
        var coverURL: String?
        /// Página del juego (para "ver en la web").
        var pageURL: String?
        var addedAt: Date = Date()
        var lastPlayedAt: Date?

        /// `true` si hay un ejecutable presente en disco (instalado y jugable).
        var installed: Bool {
            !executablePath.isEmpty && FileManager.default.fileExists(atPath: executablePath)
        }

        // Decodificación TOLERANTE: el JSON viejo solo tenía id/name/executablePath/coverPath/
        // addedAt/lastPlayedAt. Los campos nuevos usan valores por defecto si faltan.
        init(id: UUID = UUID(), name: String, source: Source = .local, sourceId: String? = nil,
             executablePath: String = "", platform: Platform = .windows,
             installPath: String? = nil, downloadURL: String? = nil,
             coverPath: String? = nil, coverURL: String? = nil, pageURL: String? = nil,
             addedAt: Date = Date(), lastPlayedAt: Date? = nil) {
            self.id = id; self.name = name; self.source = source; self.sourceId = sourceId
            self.executablePath = executablePath; self.platform = platform; self.installPath = installPath
            self.downloadURL = downloadURL; self.coverPath = coverPath; self.coverURL = coverURL
            self.pageURL = pageURL; self.addedAt = addedAt; self.lastPlayedAt = lastPlayedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            source = (try? c.decode(Source.self, forKey: .source)) ?? .local
            sourceId = try? c.decodeIfPresent(String.self, forKey: .sourceId)
            executablePath = (try? c.decode(String.self, forKey: .executablePath)) ?? ""
            platform = (try? c.decode(Platform.self, forKey: .platform)) ?? .windows
            launchArguments = (try? c.decode([String].self, forKey: .launchArguments)) ?? []
            installedVersion = try? c.decodeIfPresent(String.self, forKey: .installedVersion)
            updateAvailable = (try? c.decode(Bool.self, forKey: .updateAvailable)) ?? false
            installPath = try? c.decodeIfPresent(String.self, forKey: .installPath)
            downloadURL = try? c.decodeIfPresent(String.self, forKey: .downloadURL)
            coverPath = try? c.decodeIfPresent(String.self, forKey: .coverPath)
            coverURL = try? c.decodeIfPresent(String.self, forKey: .coverURL)
            pageURL = try? c.decodeIfPresent(String.self, forKey: .pageURL)
            addedAt = (try? c.decode(Date.self, forKey: .addedAt)) ?? Date()
            lastPlayedAt = try? c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        }
    }

    private(set) var games: [Game] = []
    private let fileURL = URL(fileURLWithPath: "\(VesselPaths.appSupport)/local-games.json")

    private init() { load() }

    // MARK: - Locales (exe/instalador a mano)

    /// Añade un juego local (dedup por ruta del ejecutable). Idempotente.
    @discardableResult
    func add(name: String, executablePath: String, coverPath: String? = nil,
             source: Source = .local) -> Game? {
        guard !executablePath.isEmpty,
              !games.contains(where: { $0.executablePath == executablePath }) else { return nil }
        let g = Game(name: name.isEmpty ? Self.defaultName(for: executablePath) : name,
                     source: source, executablePath: executablePath, coverPath: coverPath)
        games.insert(g, at: 0)
        save()
        return g
    }

    // MARK: - Biblioteca vinculada (itch/humble)

    /// Inserta o actualiza una entrada de biblioteca (dedup por `source`+`sourceId`). Conserva el
    /// estado de instalación y las fechas si ya existía. Devuelve el id de la entrada.
    @discardableResult
    func upsertLibraryEntry(source: Source, sourceId: String, name: String,
                            coverURL: String? = nil, pageURL: String? = nil,
                            downloadURL: String? = nil) -> UUID {
        if let i = games.firstIndex(where: { $0.source == source && $0.sourceId == sourceId }) {
            games[i].name = name
            if let coverURL { games[i].coverURL = coverURL }
            if let pageURL { games[i].pageURL = pageURL }
            if let downloadURL { games[i].downloadURL = downloadURL }
            save()
            return games[i].id
        }
        let g = Game(name: name, source: source, sourceId: sourceId,
                     downloadURL: downloadURL, coverURL: coverURL, pageURL: pageURL)
        games.append(g)
        save()
        return g.id
    }

    /// Registra (o actualiza) un juego **ya instalado en disco** que entra al hub DRM‑free
    /// (copia generada desde Steam, juego de GOG…). Dedup por `source`+`sourceId`. Devuelve el id.
    @discardableResult
    func upsertInstalledCopy(source: Source, sourceId: String, name: String,
                             executablePath: String, installPath: String,
                             coverURL: String? = nil, pageURL: String? = nil,
                             platform: Platform = .windows,
                             launchArguments: [String] = []) -> UUID {
        // Dedup por `source`+`sourceId` y, si no, **por ejecutable**. Lo segundo no es paranoia: una
        // versión ANTIGUA de Vessel que no conozca un `source` nuevo lo decodifica como `.local` y
        // vuelve a guardar el JSON así; sin este segundo criterio, la versión nueva no reconocería
        // su propia entrada y crearía un duplicado. Con él, la entrada se cura sola.
        if let i = games.firstIndex(where: { $0.source == source && $0.sourceId == sourceId })
            ?? games.firstIndex(where: { !$0.executablePath.isEmpty && $0.executablePath == executablePath }) {
            games[i].source = source
            games[i].sourceId = sourceId
            games[i].name = name
            games[i].executablePath = executablePath
            games[i].installPath = installPath
            games[i].platform = platform
            games[i].launchArguments = launchArguments
            if let coverURL { games[i].coverURL = coverURL }
            if let pageURL { games[i].pageURL = pageURL }
            save()
            return games[i].id
        }
        var g = Game(name: name, source: source, sourceId: sourceId,
                     executablePath: executablePath, platform: platform,
                     installPath: installPath, coverURL: coverURL, pageURL: pageURL)
        g.launchArguments = launchArguments
        games.insert(g, at: 0)
        save()
        return g.id
    }

    /// Registra (o actualiza) una **copia local DRM‑free generada desde Steam** — ya instalada.
    @discardableResult
    func upsertSteamCopy(appId: String, name: String, executablePath: String,
                         installPath: String, coverURL: String?) -> UUID {
        upsertInstalledCopy(source: .steam, sourceId: appId, name: name,
                            executablePath: executablePath, installPath: installPath,
                            coverURL: coverURL,
                            pageURL: "https://store.steampowered.com/app/\(appId)")
    }

    /// Quita del hub las entradas de una fuente **espejo del disco** (GOG/Steam) cuyo ejecutable
    /// ya no existe — p. ej. porque el juego se desinstaló desde su tienda. Nunca borra archivos:
    /// solo deja de listar lo que ya no está. No aplica a itch/Humble, donde la entrada de
    /// biblioteca debe sobrevivir a la desinstalación (es re‑descargable).
    func pruneMissing(source: Source) {
        let before = games.count
        games.removeAll { $0.source == source && !$0.installed }
        if games.count != before { save() }
    }

    /// Marca una entrada como instalada tras descargarla (fija exe/app + dir + plataforma + versión).
    func setInstalled(_ id: UUID, executablePath: String, installPath: String?,
                      platform: Platform = .windows, version: String? = nil) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].executablePath = executablePath
        games[i].installPath = installPath
        games[i].platform = platform
        if let version { games[i].installedVersion = version }
        games[i].updateAvailable = false     // acabamos de instalar: estamos al día
        save()
    }

    /// Marca (o desmarca) que hay una versión nueva en el origen.
    func setUpdateAvailable(_ id: UUID, _ available: Bool) {
        guard let i = games.firstIndex(where: { $0.id == id }), games[i].updateAvailable != available else { return }
        games[i].updateAvailable = available
        save()
    }

    /// Juegos instalados con actualización pendiente.
    var gamesWithUpdates: [Game] { games.filter { $0.installed && $0.updateAvailable } }

    /// Quita SOLO el juego de una fuente vinculada (p. ej. al desvincular la cuenta).
    func removeAll(source: Source) { games.removeAll { $0.source == source }; save() }

    // MARK: - Común

    func remove(_ id: UUID) { games.removeAll { $0.id == id }; save() }

    /// "Desinstala" un juego: borra los archivos si Vessel los generó/descargó. Para itch/Humble
    /// conserva la entrada de biblioteca (vuelve a estado "no instalado", re-descargable); para el
    /// resto (local/steam/gog) lo quita de la lista.
    func uninstall(_ id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        // SEGURIDAD (ver PathSafety + incidente de borrado): borra SOLO si `installPath` es
        // subcarpeta ESTRICTA canonicalizada de DRMFree — nunca la raíz ni una carpeta hermana.
        if let ip = games[i].installPath, !ip.isEmpty {
            if PathSafety.isStrictDescendant(ip, of: VesselPaths.drmFreeDirectory) {
                try? FileManager.default.removeItem(atPath: PathSafety.canonical(ip))
            } else {
                LogStore.shared.log("Desinstalar DRM‑free: '\(ip)' fuera de la carpeta DRMFree; no se borra en disco.", level: .warn)
            }
        }
        if games[i].source == .itch || games[i].source == .humble {
            games[i].executablePath = ""
            games[i].installPath = nil
            save()
        } else {
            games.remove(at: i)
            save()
        }
    }

    /// Quita el juego de la lista y, si estaba instalado por Vessel, borra su carpeta de instalación.
    func removeAndDelete(_ id: UUID) {
        guard let g = games.first(where: { $0.id == id }) else { return }
        // Solo borra si Vessel lo instaló (installPath bajo DRMFree/), NUNCA la raíz ni una ruta
        // ajena: subcarpeta ESTRICTA canonicalizada (ver PathSafety y el incidente de borrado).
        if let ip = g.installPath, PathSafety.isStrictDescendant(ip, of: VesselPaths.drmFreeDirectory) {
            try? FileManager.default.removeItem(atPath: PathSafety.canonical(ip))
        }
        remove(id)
    }

    func markPlayed(_ id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].lastPlayedAt = Date(); save()
    }

    func game(_ id: UUID) -> Game? { games.first { $0.id == id } }

    /// Nombre por defecto = nombre del .exe sin extensión, capitalizado.
    static func defaultName(for exe: String) -> String {
        ((exe as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private func load() {
        guard let d = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard var g = try? dec.decode([Game].self, from: d) else { return }
        let before = g.count
        g = Self.deduped(g)
        games = g
        if g.count != before {
            LogStore.shared.log("Biblioteca DRM‑free: \(before - g.count) entrada(s) duplicada(s) fusionadas.",
                                level: .info)
            save()
        }
    }

    /// Fusiona entradas que apuntan al MISMO ejecutable. Pueden aparecer si una versión antigua de
    /// Vessel guardó el JSON sin conocer un `source` nuevo (lo degrada a `.local`) y luego una
    /// versión nueva reimportó el juego con su origen real. Gana la entrada mejor informada: la que
    /// NO es `.local` y, a igualdad, la que trae argumentos de lanzamiento.
    static func deduped(_ games: [Game]) -> [Game] {
        var byExe: [String: Game] = [:]
        var out: [Game] = []
        for g in games {
            guard !g.executablePath.isEmpty else { out.append(g); continue }
            guard let existing = byExe[g.executablePath] else {
                byExe[g.executablePath] = g; continue
            }
            byExe[g.executablePath] = better(existing, g)
        }
        // Se conserva el orden original (por la primera aparición de cada ejecutable).
        var seen = Set<String>()
        var result: [Game] = []
        for g in games {
            if g.executablePath.isEmpty { continue }
            guard !seen.contains(g.executablePath) else { continue }
            seen.insert(g.executablePath)
            if let best = byExe[g.executablePath] { result.append(best) }
        }
        return result + out
    }

    private static func better(_ a: Game, _ b: Game) -> Game {
        if (a.source == .local) != (b.source == .local) { return a.source == .local ? b : a }
        if a.launchArguments.isEmpty != b.launchArguments.isEmpty { return a.launchArguments.isEmpty ? b : a }
        // A igualdad, la más reciente en jugarse (conserva el historial del usuario).
        return (a.lastPlayedAt ?? .distantPast) >= (b.lastPlayedAt ?? .distantPast) ? a : b
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(games) { try? d.write(to: fileURL, options: .atomic) }
    }
}
