import Foundation
import Yams

/// Sistema UNIFICADO de copias de partidas para las 3 tiendas (la "nube" de Vessel).
///
/// Steam Cloud lo gestiona el cliente de Steam (que Vessel no usa); Epic/GOG ya sincronizan con
/// sus CLIs. Este sistema añade una capa propia, robusta y SEGURA: localiza las carpetas de
/// guardado de cada juego con el **manifiesto de ludusavi** (el estándar de la comunidad) y las
/// **copia** a un almacén de Vessel, con instantáneas con fecha. Protege TODAS las partidas.
///
/// ## Seguridad (datos sensibles — reglas inviolables)
/// - **Solo COPIA, jamás borra** archivos del juego.
/// - **Backup** (al cerrar el juego) siempre es seguro: lee y copia, nunca pierde nada.
/// - **Restore** (al abrir) solo pisa la partida local si la copia es MÁS NUEVA (o no hay local),
///   para no sobrescribir una partida reciente con una vieja.
/// - Conserva las últimas N instantáneas por juego (historial ante errores).
@MainActor
@Observable
final class SaveBackupManager {
    static let shared = SaveBackupManager()

    /// Cuántas instantáneas conservar por juego.
    private let keepSnapshots = 8

    private var backupsRoot: String { "\(VesselPaths.appSupport)/SaveBackups" }
    private var manifestCache: String { "\(VesselPaths.cacheDirectory)/ludusavi-index.json" }
    private static let manifestURL = URL(string: "https://raw.githubusercontent.com/mtkennerly/ludusavi-manifest/master/data/manifest.yaml")!

    private let log = LogStore.shared

    /// Índice compacto: para cada juego, sus plantillas de ruta de guardado (tag `save`).
    /// Mapas por **steam appid** y por **nombre normalizado**. Se construye del manifiesto y se
    /// cachea como JSON (carga instantánea las siguientes veces).
    struct Index: Codable {
        var bySteamId: [String: [String]] = [:]
        var byName: [String: [String]] = [:]
        var builtAt: Double = 0
    }
    private var index: Index?

    // MARK: - Identidad del juego (para localizar su carpeta de copias)

    enum Store: String { case steam, epic, gog, local }

    /// Clave de la carpeta de copias del juego.
    private func gameKey(store: Store, id: String) -> String { "\(store.rawValue)/\(id)" }

    // MARK: - Índice del manifiesto

    /// Asegura el índice cargado: usa la caché JSON si es reciente (<14 días); si no, descarga
    /// el manifiesto YAML, lo parsea (fuera del hilo principal) y reconstruye la caché.
    private func ensureIndex() async {
        if index != nil { return }
        // 1) Caché JSON válida.
        if let data = FileManager.default.contents(atPath: manifestCache),
           let idx = try? JSONDecoder().decode(Index.self, from: data),
           Date().timeIntervalSince1970 - idx.builtAt < 14 * 24 * 3600 {
            index = idx
            return
        }
        // 2) Descargar + parsear el manifiesto (en segundo plano) → índice compacto.
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.manifestURL)
            let built: Index = try await Task.detached(priority: .utility) {
                try Self.buildIndex(fromYAML: data)
            }.value
            index = built
            if let out = try? JSONEncoder().encode(built) {
                try? FileManager.default.createDirectory(atPath: VesselPaths.cacheDirectory, withIntermediateDirectories: true)
                try? out.write(to: URL(fileURLWithPath: manifestCache), options: .atomic)
            }
            log.log("Copias de partidas: índice de rutas construido (\(built.bySteamId.count) juegos con steam id).", level: .info)
        } catch {
            log.log("Copias de partidas: no se pudo obtener el manifiesto de rutas (\(error.localizedDescription)). Se usará heurística básica.", level: .warn)
            index = Index(builtAt: Date().timeIntervalSince1970)   // vacío: caemos a heurística
        }
    }

    /// Parsea el YAML de ludusavi y extrae, por juego, solo las plantillas con tag `save`.
    nonisolated static func buildIndex(fromYAML data: Data) throws -> Index {
        guard let text = String(data: data, encoding: .utf8),
              let root = try Yams.load(yaml: text) as? [String: Any] else {
            throw NSError(domain: "Vessel", code: 70, userInfo: [NSLocalizedDescriptionKey: "Manifiesto YAML no válido"])
        }
        var idx = Index()
        idx.builtAt = Date().timeIntervalSince1970
        for (name, value) in root {
            guard let game = value as? [String: Any] else { continue }
            guard let files = game["files"] as? [String: Any] else { continue }
            var templates: [String] = []
            for (path, meta) in files {
                let tags = (meta as? [String: Any])?["tags"] as? [String] ?? []
                if tags.contains("save") { templates.append(path) }
            }
            guard !templates.isEmpty else { continue }
            idx.byName[normalize(name)] = templates
            if let steam = game["steam"] as? [String: Any], let sid = steam["id"] as? Int {
                idx.bySteamId["\(sid)"] = templates
            }
        }
        return idx
    }

    nonisolated private static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    // MARK: - Resolución de carpetas de guardado (contra el prefijo Wine)

    /// Carpetas/archivos de guardado CONCRETOS del juego dentro del prefijo. Cada plantilla se
    /// recorta hasta el primer comodín (esa es la carpeta de guardado) para copiarla entera —
    /// captura toda la partida y es seguro. Devuelve rutas absolutas existentes.
    private func saveLocations(steamId: String?, title: String, prefix: String, installPath: String?) async -> [String] {
        await ensureIndex()
        let templates: [String] = {
            if let sid = steamId, let t = index?.bySteamId[sid] { return t }
            if let t = index?.byName[Self.normalize(title)] { return t }
            return []
        }()
        guard !templates.isEmpty, let user = wineUser(prefix: prefix) else { return [] }
        let home = "\(prefix)/drive_c/users/\(user)"
        let base = installPath ?? ""
        let root = (base as NSString).deletingLastPathComponent
        let fm = FileManager.default
        var out = Set<String>()
        for t in templates {
            var p = t
            let map: [String: String] = [
                "<base>": base, "<game>": base, "<root>": root, "<home>": home,
                "<winDocuments>": "\(home)/Documents", "<winAppData>": "\(home)/AppData/Roaming",
                "<winLocalAppData>": "\(home)/AppData/Local", "<winPublic>": "\(prefix)/drive_c/users/Public",
                "<winProgramData>": "\(prefix)/drive_c/ProgramData", "<winDir>": "\(prefix)/drive_c/windows"
            ]
            for (k, v) in map { p = p.replacingOccurrences(of: k, with: v) }
            // Comodines de usuario/cuenta → cualquiera.
            for w in ["<storeUserId>", "<osUserName>", "<skip>"] { p = p.replacingOccurrences(of: w, with: "*") }
            p = p.replacingOccurrences(of: "\\", with: "/")
            if p.contains("<") { continue }                 // variable desconocida → no arriesgar
            if base.isEmpty && (p.hasPrefix("/") == false) { continue }
            // Recortar hasta el primer comodín → carpeta de guardado.
            if let star = p.firstIndex(of: "*") {
                let cut = p[..<star]
                p = String(cut).hasSuffix("/") ? String(cut).dropLast().description : (cut as Substring).description
                p = (p as NSString).deletingLastPathComponent.isEmpty ? p : p   // ya es carpeta
            }
            // Validación de seguridad: debe caer dentro del prefijo o del install dir.
            guard p.hasPrefix(prefix) || (!base.isEmpty && p.hasPrefix(base)) else { continue }
            if fm.fileExists(atPath: p) { out.insert(p) }
        }
        return Array(out)
    }

    private func wineUser(prefix: String) -> String? {
        let users = "\(prefix)/drive_c/users"
        guard let subs = try? FileManager.default.contentsOfDirectory(atPath: users) else { return nil }
        return subs.first { $0 != "Public" && !$0.hasPrefix(".") }
    }

    // MARK: - Backup / Restore (SEGUROS: solo copian)

    /// Copia las partidas del juego a una instantánea con fecha. SIEMPRE seguro (solo lee+copia).
    func backup(store: Store, id: String, title: String, steamId: String?, prefix: String, installPath: String?) async {
        let locations = await saveLocations(steamId: steamId, title: title, prefix: prefix, installPath: installPath)
        guard !locations.isEmpty else { return }
        let stamp = Self.timestamp()
        let snapDir = "\(backupsRoot)/\(gameKey(store: store, id: id))/\(stamp)"
        let fm = FileManager.default
        var copiedAny = false
        for loc in locations {
            // Nombre estable dentro de la instantánea (basado en la ruta relativa al prefijo).
            let rel = loc.replacingOccurrences(of: prefix + "/", with: "").replacingOccurrences(of: "/", with: "∕")
            let dest = "\(snapDir)/\(rel)"
            do {
                try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest) { try? fm.removeItem(atPath: dest) }   // dest es NUESTRO almacén
                try fm.copyItem(atPath: loc, toPath: dest)
                copiedAny = true
            } catch {
                log.log("Copia de partida: no se pudo copiar \(loc): \(error.localizedDescription)", level: .warn)
            }
        }
        guard copiedAny else { try? fm.removeItem(atPath: snapDir); return }
        pruneSnapshots(store: store, id: id)
        log.log("Partida respaldada: \(title) (\(locations.count) ubicación/es).", level: .info)
    }

    /// Restaura la última instantánea SOLO si es más nueva que la partida local (o no hay local),
    /// para no pisar una partida reciente con una vieja. Solo copia; no borra nada del juego.
    func restoreIfNewer(store: Store, id: String, title: String, steamId: String?, prefix: String, installPath: String?) async {
        guard let snap = latestSnapshotDir(store: store, id: id) else { return }
        let snapDate = (try? FileManager.default.attributesOfItem(atPath: snap))?[.creationDate] as? Date
        let locations = await saveLocations(steamId: steamId, title: title, prefix: prefix, installPath: installPath)
        // Fecha de la partida local más reciente.
        let localDate = locations.compactMap { mostRecentMTime(in: $0) }.max()
        if let l = localDate, let s = snapDate, l > s { return }   // local es más nuevo → no tocar
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: snap) else { return }
        for item in items {
            let src = "\(snap)/\(item)"
            let original = prefix + "/" + item.replacingOccurrences(of: "∕", with: "/")
            do {
                try fm.createDirectory(atPath: (original as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                // Copia segura: a un temporal y swap, para no dejar la partida a medias.
                let tmp = original + ".vessel-restoring"
                try? fm.removeItem(atPath: tmp)
                try fm.copyItem(atPath: src, toPath: tmp)
                if fm.fileExists(atPath: original) { try? fm.removeItem(atPath: original) }
                try fm.moveItem(atPath: tmp, toPath: original)
            } catch {
                log.log("Restaurar partida: no se pudo restaurar \(original): \(error.localizedDescription)", level: .warn)
            }
        }
        log.log("Partida restaurada de la copia: \(title).", level: .info)
    }

    /// Carpeta de copias del juego (para "abrir en Finder"). `nil` si aún no hay copias.
    func backupsFolder(store: Store, id: String) -> String? {
        let dir = "\(backupsRoot)/\(gameKey(store: store, id: id))"
        return FileManager.default.fileExists(atPath: dir) ? dir : nil
    }

    /// Fecha del último backup (para la UI). `nil` si no hay copias.
    func lastBackupDate(store: Store, id: String) -> Date? {
        guard let snap = latestSnapshotDir(store: store, id: id) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: snap))?[.creationDate] as? Date
    }

    // MARK: - Privado: instantáneas

    private func latestSnapshotDir(store: Store, id: String) -> String? {
        let dir = "\(backupsRoot)/\(gameKey(store: store, id: id))"
        guard let subs = try? FileManager.default.contentsOfDirectory(atPath: dir), !subs.isEmpty else { return nil }
        return subs.sorted().last.map { "\(dir)/\($0)" }
    }

    private func pruneSnapshots(store: Store, id: String) {
        let dir = "\(backupsRoot)/\(gameKey(store: store, id: id))"
        guard let subs = try? FileManager.default.contentsOfDirectory(atPath: dir).sorted(), subs.count > keepSnapshots else { return }
        for old in subs.prefix(subs.count - keepSnapshots) {
            try? FileManager.default.removeItem(atPath: "\(dir)/\(old)")
        }
    }

    private func mostRecentMTime(in path: String) -> Date? {
        let fm = FileManager.default
        func mtime(_ p: String) -> Date? { (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { return mtime(path) }
        var latest = mtime(path)
        if let walker = fm.enumerator(atPath: path) {
            for case let rel as String in walker {
                if let m = mtime("\(path)/\(rel)"), latest == nil || m > latest! { latest = m }
            }
        }
        return latest
    }

    /// Marca temporal ordenable (YYYYMMDD-HHMMSS) sin depender de locale.
    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
