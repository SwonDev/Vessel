import SwiftUI

struct BottleDetailView: View {
    let bottle: Bottle
    @State private var statusMessage: String?
    @State private var showingInstaller = false
    @State private var wineManager = WineManager()
    @State private var importer = SteamLibraryImporter()
    @State private var gamesWatcher = DirectoryWatcher()
    @State private var gameToUninstall: GameInstall?
    @State private var accountService = SteamAccountService()
    @State private var ownedGames: [SteamAccountService.OwnedGame] = []
    @State private var installingAppIds: Set<String> = []
    @State private var loadingLibrary = false
    @State private var steamCMD = SteamCMDManager()
    @State private var showSteamCMDLogin = false
    @State private var showOfficialLogin = false
    @State private var pendingInstallAppId: String?
    @State private var installMessages: [String: String] = [:]
    @State private var installPercents: [String: Double] = [:]
    @AppStorage("steamcmd.user") private var steamCMDUser = ""
    @State private var localBottle: Bottle
    @State private var dxvkInstalled: Bool = false

    private let store = BottleStore.shared
    private let log = LogStore.shared

    init(bottle: Bottle) {
        self.bottle = bottle
        self._localBottle = State(initialValue: bottle)
    }

    /// Mapeo de los juegos de Steam (instalados + biblioteca owned) al modelo genérico
    /// `StoreGame`, para usar la biblioteca común (igual que Epic/GOG/Amazon).
    private var steamGames: [StoreGame] {
        let installed = localBottle.games.map { g in
            StoreGame(id: g.steamAppId ?? g.id.uuidString, title: g.name,
                      steamAppId: g.steamAppId, installed: true, lastPlayed: g.lastPlayedAt,
                      installPath: (g.executablePath as NSString).deletingLastPathComponent)
        }
        let installedIds = Set(localBottle.games.compactMap { $0.steamAppId })
        let notInstalled = ownedGames
            .filter { !installedIds.contains($0.appId) }
            .map { StoreGame(id: $0.appId, title: $0.name, steamAppId: $0.appId, installed: false) }
        return installed + notInstalled
    }

    var body: some View {
        StoreLibraryView(
            store: .steam,
            games: steamGames,
            installingIDs: installingAppIds,
            progressFor: { installMessages[$0] },
            percentFor: { installPercents[$0] },
            onInstall: { sg in if sg.steamAppId != nil { Task { await installGame(sg.id) } } },
            onPlay: { sg in
                if let g = localBottle.games.first(where: { ($0.steamAppId ?? $0.id.uuidString) == sg.id }) {
                    Task { await launchGame(g) }
                }
            },
            onUninstall: { sg in
                gameToUninstall = localBottle.games.first(where: { ($0.steamAppId ?? $0.id.uuidString) == sg.id })
            },
            // Verificar/reparar en Steam = re-ejecutar SteamCMD `app_update <id> validate` (el
            // mismo flujo de instalación, que YA valida la integridad y re-descarga lo dañado).
            onVerify: { sg in if sg.steamAppId != nil { Task { await installGame(sg.id) } } },
            onReload: { Task { await loadSteamLibrary() } },
            onLogout: { NotificationCenter.default.post(name: .steamLogout, object: nil) }
        )
        .sheet(isPresented: $showingInstaller) {
            SteamInstallerView(bottle: localBottle, wineManager: wineManager) {
                showingInstaller = false
                Task { await refreshDXVKStatus() }
            }
        }
        .task {
            await refreshDXVKStatus()
            await autoImportGames()
            startWatchingGames()
            await loadSteamLibrary()
        }
        .onDisappear { gamesWatcher.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Al volver a Vessel (p.ej. tras instalar un juego en Steam) re-escaneamos
            // y reanudamos la vigilancia por si la carpeta steamapps acaba de aparecer.
            Task {
                await autoImportGames()
                startWatchingGames()
            }
        }
        .alert("¿Desinstalar el juego?", isPresented: Binding(
            get: { gameToUninstall != nil },
            set: { if !$0 { gameToUninstall = nil } }
        )) {
            Button("Cancelar", role: .cancel) { gameToUninstall = nil }
            Button("Desinstalar", role: .destructive) {
                if let g = gameToUninstall { uninstallGame(g) }
                gameToUninstall = nil
            }
        } message: {
            Text(gameToUninstall.map { "Se borrarán del bottle los archivos de \u{201C}\($0.name)\u{201D}. Esta acción no se puede deshacer." } ?? "")
        }
        .sheet(isPresented: $showSteamCMDLogin) {
            SteamCMDLoginView(suggestedUser: accountService.detectAccount(bottle: localBottle)?.accountName ?? "") { user in
                steamCMDUser = user
                if let appId = pendingInstallAppId {
                    pendingInstallAppId = nil
                    Task { await installGame(appId) }
                }
            }
        }
        .sheet(isPresented: $showOfficialLogin) {
            SteamOfficialLoginView { tokens in
                if !tokens.accountName.isEmpty { steamCMDUser = tokens.accountName }
                Task { await loadSteamLibrary() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .steamLogin)) { _ in
            showOfficialLogin = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .steamRefresh)) { _ in
            Task { await loadSteamLibrary() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .steamLogout)) { _ in
            steamCMDUser = ""
            SteamAccountService.webAPIKey = ""
            ownedGames = []
            statusMessage = "Sesión cerrada. Usa clic derecho en Steam para volver a iniciar sesión."
        }
    }

    /// Desinstala el juego borrando SOLO su carpeta dentro de `steamapps/common`.
    /// BLINDADO: la carpeta se deriva del `installdir` del appmanifest o del
    /// `executablePath`, y se exige que sea una subcarpeta ESTRICTA de
    /// `steamapps/common` (nunca el prefijo, ni `common`, ni rutas fuera de ahí).
    /// `installPath` NO se usa: puede apuntar al prefijo entero.
    private func uninstallGame(_ game: GameInstall) {
        let fm = FileManager.default
        let steamCommon = "\(localBottle.prefixPath)/drive_c/Program Files (x86)/Steam/steamapps/common"
        var folderToDelete: String?

        if let appId = game.steamAppId, !appId.isEmpty {
            let manifest = "\(localBottle.prefixPath)/drive_c/Program Files (x86)/Steam/steamapps/appmanifest_\(appId).acf"
            if let content = try? String(contentsOfFile: manifest, encoding: .utf8),
               let installdir = installDir(in: content), !installdir.isEmpty {
                folderToDelete = "\(steamCommon)/\(installdir)"
            }
            try? fm.removeItem(atPath: manifest)
        }
        if folderToDelete == nil, let range = game.executablePath.range(of: "\(steamCommon)/") {
            let rest = game.executablePath[range.upperBound...]
            if let first = rest.split(separator: "/").first {
                folderToDelete = "\(steamCommon)/\(first)"
            }
        }

        // SEGURIDAD CRÍTICA: canonicalizar (resolver symlinks y `..`) y exigir que la
        // ruta resultante siga siendo subcarpeta ESTRICTA de steamapps/common.
        if let folder = folderToDelete {
            let resolved = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
            let base = URL(fileURLWithPath: steamCommon).resolvingSymlinksInPath().standardizedFileURL.path
            if resolved.hasPrefix(base + "/"),
               resolved != base,
               (resolved as NSString).lastPathComponent.count > 0,
               fm.fileExists(atPath: resolved) {
                try? fm.removeItem(atPath: resolved)
                log.log("Juego desinstalado: \(game.name) (\(resolved))", level: .info)
            } else {
                log.log("Desinstalar \(game.name): ruta no segura tras canonicalizar; solo se quita de la lista.", level: .warn)
            }
        } else {
            log.log("Desinstalar \(game.name): no se halló carpeta segura; solo se quita de la lista.", level: .warn)
        }

        store.deleteGame(game.id, from: localBottle.id)
        if let updated = store.bottles.first(where: { $0.id == localBottle.id }) {
            localBottle = updated
        }
    }

    /// Extrae `"installdir" "X"` de un appmanifest .acf, rechazando valores con
    /// separadores de ruta o traversal (`..`) por seguridad.
    private func installDir(in manifest: String) -> String? {
        for line in manifest.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().contains("\"installdir\"") {
                let parts = t.components(separatedBy: "\"").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if let last = parts.last, last.lowercased() != "installdir" {
                    guard !last.contains("/"), !last.contains("\\"), !last.contains("..") else { return nil }
                    return last
                }
            }
        }
        return nil
    }

    /// Carga la biblioteca completa (owned) de la cuenta logueada en el bottle.
    private func loadSteamLibrary() async {
        guard let account = accountService.detectAccount(bottle: localBottle) else { return }
        // Carga INSTANTÁNEA desde caché en disco; así no se ve "Cargando…" cada vez.
        if ownedGames.isEmpty,
           let cached = LibraryCache.load("steam-\(account.steamID64)", as: [SteamAccountService.OwnedGame].self) {
            ownedGames = cached
        }
        // Solo mostrar el indicador si no hay nada que enseñar todavía.
        loadingLibrary = ownedGames.isEmpty
        defer { loadingLibrary = false }
        // Refresco real en 2º plano (la UI ya muestra la caché mientras tanto).
        let owned = await accountService.fetchOwnedGames(steamID64: account.steamID64)
        if !owned.isEmpty {
            ownedGames = owned
            LibraryCache.save("steam-\(account.steamID64)", owned)
            log.log("Biblioteca de Steam cargada: \(owned.count) juego(s) de \(account.personaName)", level: .info)
        } else if ownedGames.isEmpty {
            log.log("Biblioteca de \(account.personaName) vacía (perfil privado o sin clave API)", level: .warn)
        }
    }

    /// Pide a Steam que instale el juego (desde Vessel). El watcher en tiempo real lo
    /// moverá a "Juegos instalados" cuando termine la descarga.
    private func installGame(_ appId: String) async {
        let name = ownedGames.first(where: { $0.appId == appId })?.name ?? "App \(appId)"
        // Requiere sesión de SteamCMD. Si no la hay, pedir login primero.
        guard !steamCMDUser.isEmpty else {
            pendingInstallAppId = appId
            showSteamCMDLogin = true
            return
        }
        installingAppIds.insert(appId)
        defer { installingAppIds.remove(appId); installMessages[appId] = nil; installPercents[appId] = nil }
        do { try await steamCMD.ensureInstalled() } catch {
            statusMessage = "No se pudo preparar SteamCMD."
            return
        }
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "")
        let installDir = "\(localBottle.prefixPath)/drive_c/Program Files (x86)/Steam/steamapps/common/\(safeName)"
        installMessages[appId] = "Iniciando descarga…"
        let ok = await steamCMD.installGame(appId: appId, user: steamCMDUser, installDir: installDir) { pct, msg in
            installMessages[appId] = msg
            // Solo barra determinada cuando hay descarga real con %; verificación → indeterminado.
            installPercents[appId] = msg.contains("Descargando") ? max(0, min(1, pct / 100)) : nil
        }
        if ok, let exe = mainExecutable(in: installDir) {
            let game = GameInstall(
                name: name, executablePath: exe, steamAppId: appId, installPath: installDir,
                coverImageURL: "https://cdn.akamai.steamstatic.com/steam/apps/\(appId)/library_600x900_2x.jpg"
            )
            store.addGame(game, to: localBottle.id)
            if let updated = store.bottles.first(where: { $0.id == localBottle.id }) { localBottle = updated }
            ownedGames.removeAll { $0.appId == appId }
        } else if !ok {
            statusMessage = "La instalación de \(name) no se completó. Revisa los logs."
        }
    }

    /// Localiza el ejecutable principal del juego descargado (ignora redistribuibles).
    private func mainExecutable(in dir: String) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dir) else { return nil }
        let dirName = (dir as NSString).lastPathComponent.lowercased()
        // (ruta relativa en minúsculas, ruta completa) de cada .exe que NO sea redistribuible/instalador.
        var exes: [(rel: String, full: String)] = []
        for case let path as String in enumerator where path.lowercased().hasSuffix(".exe") {
            let lower = path.lowercased()
            if lower.contains("redist") || lower.contains("vcredist") || lower.contains("crashpad")
                || lower.contains("unitycrash") || lower.contains("dxsetup") || lower.contains("dotnet") {
                continue
            }
            exes.append((lower, "\(dir)/\(path)"))
        }
        guard !exes.isEmpty else { return nil }
        // Preferir el juego real frente a launchers de terceros (EA/Ubisoft/Rockstar): si
        // eligiéramos el launcher, se enrutaría el motor por su bitness/API, no la del juego.
        func isLauncher(_ rel: String) -> Bool { rel.contains("launcher") }
        let real = exes.filter { !isLauncher($0.rel) }
        // 1) exe que coincide con el nombre de la carpeta y NO es launcher → el juego real.
        if let game = real.first(where: { $0.rel.contains(dirName) }) { return game.full }
        // 2) cualquier exe que no sea launcher (ruta más corta, normalmente en la raíz).
        if let shortest = real.min(by: { $0.rel.count < $1.rel.count }) { return shortest.full }
        // 3) solo quedan launchers (el juego arranca por su launcher): el de ruta más corta.
        return exes.min(by: { $0.rel.count < $1.rel.count })?.full
    }

    /// Vigila en tiempo real la carpeta `steamapps` del bottle: cuando Steam instala
    /// o desinstala un juego, re-escaneamos y la lista de Vessel se actualiza sola,
    /// sin reiniciar la app.
    private func startWatchingGames() {
        let steamapps = "\(localBottle.prefixPath)/drive_c/Program Files (x86)/Steam/steamapps"
        guard FileManager.default.fileExists(atPath: steamapps) else { return }
        gamesWatcher.start(path: steamapps) {
            Task { await autoImportGames() }
        }
    }

    /// Escanea el Steam del bottle y añade a la lista los juegos instalados que aún
    /// no estén. Hace que aparezcan automáticamente con su botón "Jugar" (wine-dxmt).
    private func autoImportGames() async {
        let found = importer.scanBottleGames(bottle: localBottle)
        var added = false
        for g in found where !localBottle.games.contains(where: {
            $0.steamAppId == g.appId || $0.executablePath == g.executablePath
        }) {
            let game = GameInstall(
                name: g.name,
                executablePath: g.executablePath,
                steamAppId: g.appId,
                installPath: g.installPath,
                coverImageURL: g.coverURL
            )
            store.addGame(game, to: localBottle.id)
            added = true
        }
        if added, let updated = store.bottles.first(where: { $0.id == localBottle.id }) {
            localBottle = updated
            log.log("Auto-importados \(found.count) juego(s) de Steam en \(localBottle.name)", level: .info)
        }
    }

    private func launchGame(_ game: GameInstall) async {
        // Mismo id que usa la UI (StoreGame.id) para que el feedback (Iniciando…/Ejecutándose)
        // se refleje en la ficha y la tarjeta.
        let trackId = game.steamAppId ?? game.id.uuidString
        await GameLaunchTracker.shared.track(trackId, statsKey: "steam:\(trackId)") {
            let cfg = GameConfigStore.load(trackId)
            let profile = CompatService.shared.profile(steam: game.steamAppId, title: game.name)
            let eff = CompatService.shared.effectiveConfig(profile: profile, user: cfg)
            let proc = try await wineManager.launch(
                executable: game.executablePath, in: localBottle,
                arguments: [], steamAppId: game.steamAppId, effective: eff)
            store.touchGame(game.id, in: localBottle.id)
            return proc
        }
    }

    private func refreshDXVKStatus() async {
        dxvkInstalled = wineManager.isDXVKInstalled(in: localBottle)
    }

}

