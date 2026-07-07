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
            // Actualizar en Steam = `app_update <id>` (sin validate forzado, va a la última build).
            onUpdate: { sg in if sg.steamAppId != nil { Task { await installGame(sg.id, validate: false) } } },
            onReload: { Task { await loadSteamLibrary() } },
            onLogout: { NotificationCenter.default.post(name: .steamLogout, object: nil) },
            onLogin: { NotificationCenter.default.post(name: .steamLogin, object: nil) },
            // "Abrir Steam": arranca el cliente Steam completo conectado en el MOTOR
            // UNIFICADO (CEF + DXMT/Metal en un solo wineserver) para jugar DESDE Steam
            // con DRM real —el modelo que hace funcionar juegos como Grim Dawn—.
            onOpenSteam: { Task { await wineManager.openSteamClient(in: localBottle) } }
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
                // NO marcamos `steamCMDUser` aquí: el login oficial (web/RSA) carga la biblioteca
                // pero NO crea sesión de SteamCMD (que es lo que DESCARGA). Si lo marcáramos, el
                // install creería tener sesión y fallaría/se colgaba ("hacía como que instala").
                // La sesión real de SteamCMD se obtiene en su propio login (showSteamCMDLogin).
                //
                // SEMBRAR la sesión del CLIENTE de Steam con el token FRESCO (SteamClient) → el
                // cliente auto-loguea por JWT SIN pasar por el CEF (que no renderiza en el M5), y
                // los juegos con DRM que exigen Steam abierto funcionan. FORZADO: reemplaza cualquier
                // sesión sembrada previa (clave para recuperar una sesión caducada/marcada para
                // re-auth, y para el primer login de un usuario nuevo).
                Task {
                    if let sid = SteamAuthService.steamID64(fromJWT: tokens.refreshToken) {
                        let wine = WineEngineLocator.clientWineBinary() ?? wineManager.resolveClientWine(for: localBottle)
                        _ = await SteamClientSeeder.shared.seed(
                            login: tokens.accountName, steamID64: sid, personaName: tokens.accountName,
                            refreshToken: tokens.refreshToken, in: localBottle, wine: wine)
                    }
                    await loadSteamLibrary()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .steamLogin)) { _ in
            showOfficialLogin = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .steamRefresh)) { _ in
            Task { await loadSteamLibrary() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .steamLogout)) { _ in
            // Cerrar sesión = borrar la SESIÓN WEB (tokens). NO tocamos ni la Web API key (credencial
            // pegada a mano) ni `steamCMDUser` (la sesión de DESCARGA de SteamCMD es independiente y
            // sigue cacheada; borrar el nombre obligaba a re-loguear en SteamCMD sin necesidad).
            UserDefaults.standard.removeObject(forKey: "steam.accessToken")
            UserDefaults.standard.removeObject(forKey: "steam.refreshToken")
            ownedGames = []
            statusMessage = "Sesión cerrada. Abre el menú «…» → Iniciar sesión para volver a entrar."
        }
    }

    /// Desinstala el juego borrando SOLO su carpeta dentro de `steamapps/common`.
    /// BLINDADO: la carpeta se deriva del `installdir` del appmanifest o del
    /// `executablePath`, y se exige que sea una subcarpeta ESTRICTA de
    /// `steamapps/common` (nunca el prefijo, ni `common`, ni rutas fuera de ahí).
    /// `installPath` NO se usa: puede apuntar al prefijo entero.
    private func uninstallGame(_ game: GameInstall) {
        let fm = FileManager.default
        let steamCommon = "\(localBottle.steamDirectory)/steamapps/common"
        var folderToDelete: String?

        if let appId = game.steamAppId, !appId.isEmpty {
            let manifest = "\(localBottle.steamDirectory)/steamapps/appmanifest_\(appId).acf"
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
    private func installGame(_ appId: String, validate: Bool = true) async {
        let name = ownedGames.first(where: { $0.appId == appId })?.name ?? "App \(appId)"
        do { try await steamCMD.ensureInstalled() } catch {
            statusMessage = "No se pudo preparar SteamCMD."
            return
        }
        // Descargar de Steam requiere una SESIÓN REAL de SteamCMD, distinta del login oficial web
        // (que solo da el nombre de cuenta para la biblioteca). Sin sesión, `app_update` falla en
        // silencio → parecía "que instala pero no instala nada". Pedimos login de SteamCMD primero.
        // Usuario de SteamCMD: el guardado o, si está vacío (p. ej. tras cerrar la sesión WEB), el de
        // la cuenta detectada en el prefijo. La sesión de SteamCMD puede seguir CACHEADA aunque no
        // tengamos el nombre guardado, así que la comprobamos antes de pedir login otra vez.
        var user = steamCMDUser
        if user.isEmpty { user = accountService.detectAccount(bottle: localBottle)?.accountName ?? "" }
        guard !user.isEmpty, await steamCMD.hasSession(user: user) else {
            pendingInstallAppId = appId
            showSteamCMDLogin = true
            return
        }
        steamCMDUser = user   // recordarlo para la próxima
        installingAppIds.insert(appId)
        defer { installingAppIds.remove(appId); installMessages[appId] = nil; installPercents[appId] = nil }
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "")
        let installDir = "\(localBottle.steamDirectory)/steamapps/common/\(safeName)"
        installMessages[appId] = "Iniciando descarga…"
        let ok = await steamCMD.installGame(appId: appId, user: user, installDir: installDir, validate: validate) { pct, msg in
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
            NotificationService.shared.notify(title: "Instalación completada", body: name)
        } else if !ok {
            statusMessage = "La instalación de \(name) no se completó. Revisa los logs."
        }
    }

    /// Localiza el ejecutable principal del juego descargado (ignora redistribuibles).
    private func mainExecutable(in dir: String) -> String? {
        SteamLibraryImporter.mainGameExecutable(in: dir)
    }

    /// Vigila en tiempo real la carpeta `steamapps` del bottle: cuando Steam instala
    /// o desinstala un juego, re-escaneamos y la lista de Vessel se actualiza sola,
    /// sin reiniciar la app.
    private func startWatchingGames() {
        let steamapps = "\(localBottle.steamDirectory)/steamapps"
        guard FileManager.default.fileExists(atPath: steamapps) else { return }
        gamesWatcher.start(path: steamapps) {
            Task { await autoImportGames() }
        }
    }

    /// Escanea el Steam del bottle y añade a la lista los juegos instalados que aún
    /// no estén. Hace que aparezcan automáticamente con su botón "Jugar" (wine-dxmt).
    private func autoImportGames() async {
        let found = importer.scanBottleGames(bottle: localBottle)
        var changed = false
        for g in found {
            let existing = localBottle.games.first { $0.steamAppId == g.appId || $0.executablePath == g.executablePath }
            if existing == nil {
                let game = GameInstall(
                    name: g.name,
                    executablePath: g.executablePath,
                    steamAppId: g.appId,
                    installPath: g.installPath,
                    coverImageURL: g.coverURL
                )
                store.addGame(game, to: localBottle.id)
                changed = true
            } else if store.fixGameExecutable(steamAppId: g.appId, executablePath: g.executablePath,
                                               installPath: g.installPath, in: localBottle.id) {
                // El escaneo anterior había guardado el exe equivocado (p. ej. server.exe): corregido.
                log.log("Auto-reparado el ejecutable de \(g.name) → \((g.executablePath as NSString).lastPathComponent)", level: .info)
                changed = true
            }
        }
        if changed, let updated = store.bottles.first(where: { $0.id == localBottle.id }) {
            localBottle = updated
            log.log("Biblioteca de Steam sincronizada (\(found.count) juego(s)) en \(localBottle.name)", level: .info)
        }
    }

    private func launchGame(_ game: GameInstall, forcedLayer: GameConfig.GraphicsLayer? = nil, attempt: Int = 0) async {
        // Mismo id que usa la UI (StoreGame.id) para que el feedback (Iniciando…/Ejecutándose)
        // se refleje en la ficha y la tarjeta.
        let trackId = game.steamAppId ?? game.id.uuidString
        // GARANTÍA al lanzar: re-resolver el ejecutable desde la carpeta del juego. Si un escaneo
        // antiguo guardó el exe equivocado (p. ej. el server.exe headless de un MMO), aquí se
        // corrige justo antes de arrancar → SIEMPRE se lanza el cliente, aunque el dato persistido
        // esté obsoleto. Se persiste la corrección para que la ficha/detalles también queden bien.
        var exePath = game.executablePath
        if !game.installPath.isEmpty,
           let resolved = SteamLibraryImporter.mainGameExecutable(in: game.installPath),
           resolved != exePath {
            exePath = resolved
            if let appId = game.steamAppId {
                store.fixGameExecutable(steamAppId: appId, executablePath: resolved,
                                        installPath: game.installPath, in: localBottle.id)
            }
            log.log("Ejecutable re-resuelto al lanzar \(game.name): \((resolved as NSString).lastPathComponent)", level: .info)
        }
        // Config efectiva resuelta ANTES de track para saber la capa gráfica usada y reintentar.
        let cfg = GameConfigStore.load(trackId)
        let profile = CompatService.shared.profile(steam: game.steamAppId, title: game.name)
        var eff = CompatService.shared.effectiveConfig(profile: profile, user: cfg)
        if let forcedLayer { eff.graphicsOverride = forcedLayer }
        // Motor REAL que se usará (no `.auto`), para que el fallback recorra los 3 motores.
        let usedLayer = wineManager.resolvedGraphicsLayer(forExecutable: exePath, effective: eff)
        await GameLaunchTracker.shared.track(
            trackId, statsKey: "steam:\(trackId)",
            // Copia de partida automática: al CERRAR el juego, respalda la partida (seguro, solo copia).
            onExit: { Task { await SaveBackupManager.shared.backup(store: .steam, id: trackId, title: game.name, steamId: game.steamAppId, prefix: localBottle.prefixPath, installPath: game.installPath) } }
        ) {
            // Restaura la copia ANTES de jugar SOLO si es más nueva que la partida local.
            await SaveBackupManager.shared.restoreIfNewer(store: .steam, id: trackId, title: game.name, steamId: game.steamAppId, prefix: localBottle.prefixPath, installPath: game.installPath)
            let proc = try await wineManager.launch(
                executable: exePath, in: localBottle,
                arguments: [], steamAppId: game.steamAppId, effective: eff)
            store.touchGame(game.id, in: localBottle.id)
            return proc
        }
        // Diagnóstico + fallback automático de motor (DXMT → GPTK → Gcenx) si falla el arranque o el
        // juego se cierra sin renderizar; si no, avisa con causa y acción.
        LaunchDiagnostics.monitorAndMaybeRetry(
            prefix: localBottle.prefixPath, gameId: trackId, gameTitle: game.name,
            currentLayer: usedLayer, attempt: attempt,
            fallbackLayers: wineManager.fallbackLayers(forExecutable: exePath, effective: eff),
            usesRealSteam: eff.useRealSteam,
            usesSteamworks: wineManager.usesSteamworks(exePath),
            isRunning: { GameLaunchTracker.shared.state(trackId) == .running },
            // Al reparar con éxito, recordar la capa ganadora como override del juego → la próxima
            // vez arranca directa en el motor que funciona (el arreglo PERSISTE, no se repite el crash).
            persistWinningLayer: { winLayer in
                var c = GameConfigStore.load(trackId)
                c.graphicsLayer = winLayer
                GameConfigStore.save(trackId, c)
            },
            // Auto-reparación de Steam: el juego pide una interfaz de Steam que la emulación no provee
            // (Steam Input/Controller). Activamos el modo Steam-real PERSISTENTE y relanzamos.
            // SOLO para juegos de 64-bit: el `steam_api` de 32-bit no conecta al cliente de 64-bit por
            // IPC en WoW64, así que Steam-real nunca le funcionaría — su vía es Goldberg + interfaces
            // (ver CaveBlazers). Grim Dawn NO se ve afectado: su exe lanzado (`x64/…`) ES de 64-bit.
            retryWithRealSteam: wineManager.isExecutable32Bit(exePath) ? nil : ({
                var c = GameConfigStore.load(trackId)
                c.useRealSteam = true
                GameConfigStore.save(trackId, c)
                await launchGame(game, attempt: attempt + 1)
            } as @MainActor () async -> Void)
        ) { next in await launchGame(game, forcedLayer: next, attempt: attempt + 1) }
    }

    private func refreshDXVKStatus() async {
        dxvkInstalled = wineManager.isDXVKInstalled(in: localBottle)
    }

}

