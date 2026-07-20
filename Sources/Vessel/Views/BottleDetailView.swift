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
    @State private var loadingLibrary = false
    @State private var libraryError: String?
    @State private var steamCMD = SteamCMDManager()
    @State private var operations: LibraryOperationQueue
    @State private var updatesAvailable: Set<String> = []
    @State private var showSteamCMDLogin = false
    @State private var showOfficialLogin = false
    @State private var pendingInstallAppId: String?
    @State private var pendingOperationKind: LibraryOperationKind = .install
    @State private var steamCMDSessionConfirmed = false
    @AppStorage("steamcmd.user") private var steamCMDUser = ""
    @State private var localBottle: Bottle
    @State private var dxvkInstalled: Bool = false

    private let store = BottleStore.shared
    private let log = LogStore.shared

    init(bottle: Bottle) {
        self.bottle = bottle
        self._localBottle = State(initialValue: bottle)
        self._operations = State(initialValue: LibraryOperationQueue(
            storageKey: "steam-\(bottle.id.uuidString)"
        ))
    }

    /// Mapeo de los juegos de Steam (instalados + biblioteca owned) al modelo genérico
    /// `StoreGame`, para usar la biblioteca común (igual que Epic/GOG).
    private var steamGames: [StoreGame] {
        let installed = localBottle.games.map { g in
            StoreGame(id: g.steamAppId ?? g.id.uuidString, title: g.name,
                      steamAppId: g.steamAppId, installed: true,
                      updateAvailable: g.steamAppId.map(updatesAvailable.contains) ?? false,
                      lastPlayed: g.lastPlayedAt,
                      installPath: g.installPath.isEmpty
                        ? (g.executablePath as NSString).deletingLastPathComponent
                        : g.installPath,
                      executablePath: g.executablePath,
                      installSizeBytes: g.steamAppId.flatMap(steamInstallSize))
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
            installingIDs: operations.itemIDs,
            progressFor: { operations.message(for: $0) },
            percentFor: { operations.fraction(for: $0) },
            transferTitleFor: { operations.title(for: $0) },
            transferPhaseFor: { operations.transferPhase(for: $0) },
            transferPositionFor: { operations.position(of: $0) },
            canPauseTransfer: { operations.canPause($0) },
            canCancelTransfer: { operations.canCancel($0) },
            canPrioritizeTransfer: { operations.canPrioritize($0) },
            canRetryTransfer: { operations.canRetry($0) },
            onPauseTransfer: { operations.pause($0.id) },
            onResumeTransfer: { operations.resume($0.id) },
            onCancelTransfer: cancelSteamOperation,
            onPrioritizeTransfer: { operations.prioritize($0.id) },
            onRetryTransfer: { operations.resume($0.id) },
            onInstall: { sg in if sg.steamAppId != nil { Task { await enqueueSteamOperation(sg.id, kind: .install) } } },
            onPlay: { sg in
                if let g = localBottle.games.first(where: { ($0.steamAppId ?? $0.id.uuidString) == sg.id }) {
                    Task { await launchGame(g) }
                }
            },
            onReconcileRunning: { sg in
                if let game = localBottle.games.first(where: {
                    ($0.steamAppId ?? $0.id.uuidString) == sg.id
                }) {
                    await reconcileRunningGame(game)
                }
            },
            onUninstall: { sg in
                gameToUninstall = localBottle.games.first(where: { ($0.steamAppId ?? $0.id.uuidString) == sg.id })
            },
            // Verificar/reparar en Steam = re-ejecutar SteamCMD `app_update <id> validate` (el
            // mismo flujo de instalación, que YA valida la integridad y re-descarga lo dañado).
            onVerify: { sg in if sg.steamAppId != nil { Task { await enqueueSteamOperation(sg.id, kind: .verify) } } },
            // Actualizar en Steam = `app_update <id>` (sin validate forzado, va a la última build).
            onUpdate: { sg in if sg.steamAppId != nil { Task { await enqueueSteamOperation(sg.id, kind: .update) } } },
            onUpdateAll: { storeGames in
                Task {
                    for game in storeGames { await enqueueSteamOperation(game.id, kind: .update) }
                }
            },
            onReload: { Task { await loadSteamLibrary(); await refreshSteamUpdates() } },
            onLogout: { NotificationCenter.default.post(name: .steamLogout, object: nil) },
            onLogin: { NotificationCenter.default.post(name: .steamLogin, object: nil) },
            // "Abrir Steam": arranca el cliente Steam completo conectado en el MOTOR
            // UNIFICADO (CEF + DXMT/Metal en un solo wineserver) para jugar DESDE Steam
            // con DRM real —el modelo que hace funcionar juegos como Grim Dawn—.
            onOpenSteam: { Task { await wineManager.openSteamClient(in: localBottle) } },
            externalLibraryLoading: loadingLibrary,
            externalLibraryError: libraryError,
            onRetryLibraryLoad: { Task { await loadSteamLibrary() } }
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
            await refreshSteamUpdates()
            await restoreSteamOperations()
            resumeInterruptedDownloads()
        }
        .onDisappear { gamesWatcher.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Al volver a Vessel (p.ej. tras instalar un juego en Steam) re-escaneamos
            // y reanudamos la vigilancia por si la carpeta steamapps acaba de aparecer.
            Task {
                await autoImportGames()
                startWatchingGames()
                await refreshSteamUpdates()
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
                    let kind = pendingOperationKind
                    Task { await enqueueSteamOperation(appId, kind: kind) }
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
                    NotificationCenter.default.post(name: .accountProfileDidChange, object: StoreKind.steam)
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
            UserDefaults.standard.removeObject(forKey: "steam.sessionNeedsReauthentication")
            UserDefaults.standard.removeObject(forKey: "steam.remoteRejectedRefreshTokenSHA256")
            SteamAuthService.clearClientSessionSeedTracking()
            ownedGames = []
            statusMessage = "Sesión cerrada. Abre el menú «…» → Iniciar sesión para volver a entrar."
            NotificationCenter.default.post(name: .accountProfileDidChange, object: StoreKind.steam)
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

        // SEGURIDAD CRÍTICA (centralizada en PathSafety): canonicalizar (resolver symlinks y `..`)
        // y exigir que la ruta resultante siga siendo subcarpeta ESTRICTA de steamapps/common.
        if let folder = folderToDelete,
           let resolved = PathSafety.resolvedIfSafeToDelete(folder, under: steamCommon, fileManager: fm) {
            try? fm.removeItem(atPath: resolved)
            log.log("Juego desinstalado: \(game.name) (\(resolved))", level: .info)
        } else if folderToDelete == nil {
            log.log("Desinstalar \(game.name): no se halló carpeta segura; solo se quita de la lista.", level: .warn)
        } else {
            log.log("Desinstalar \(game.name): ruta no segura tras canonicalizar; solo se quita de la lista.", level: .warn)
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
        libraryError = nil
        defer { loadingLibrary = false }
        // Refresco real en 2º plano (la UI ya muestra la caché mientras tanto).
        let owned = await accountService.fetchOwnedGames(steamID64: account.steamID64)
        if !owned.isEmpty {
            ownedGames = owned
            libraryError = nil
            LibraryCache.save("steam-\(account.steamID64)", owned)
            log.log("Biblioteca de Steam cargada: \(owned.count) juego(s) de \(account.personaName)", level: .info)
        } else if ownedGames.isEmpty {
            // Sin caché y sin respuesta: era un falso estado vacío ("No hay juegos") — ahora
            // es un error honesto con reintento (puede ser red, perfil privado o falta de clave API).
            libraryError = "No se pudo cargar tu biblioteca de Steam.\nComprueba la conexión, que el perfil sea público y que la clave API de Ajustes sea válida."
            log.log("Biblioteca de \(account.personaName) vacía (perfil privado o sin clave API)", level: .warn)
        }
    }

    private func restoreSteamOperations() async {
        guard operations.hasItems else { return }
        do { try await steamCMD.ensureInstalled() } catch { return }
        var user = steamCMDUser
        if user.isEmpty { user = accountService.detectAccount(bottle: localBottle)?.accountName ?? "" }
        guard !user.isEmpty, await steamCMD.hasSession(user: user) else { return }
        steamCMDUser = user
        steamCMDSessionConfirmed = true
        for item in operations.items {
            operations.attach(gameID: item.id, executor: steamExecutor(appId: item.id, user: user))
        }
    }

    private func refreshSteamUpdates() async {
        let localBuildIDs = steamLocalBuildIDs()
        guard !localBuildIDs.isEmpty else { updatesAvailable = []; return }
        updatesAvailable = await steamCMD.gamesWithUpdates(localBuildIDs: localBuildIDs)
    }

    private func steamLocalBuildIDs() -> [String: String] {
        var result: [String: String] = [:]
        for game in localBottle.games {
            guard let appID = game.steamAppId, !appID.isEmpty else { continue }
            guard let buildID = SteamCMDManager.installedBuildID(
                appID: appID,
                installPath: game.installPath,
                steamDirectory: localBottle.steamDirectory,
                contentsAtPath: { try? String(contentsOfFile: $0, encoding: .utf8) }
            ) else { continue }
            result[appID] = buildID
        }
        return result
    }

    private func steamInstallSize(_ appID: String) -> Int64? {
        let manifest = "\(localBottle.steamDirectory)/steamapps/appmanifest_\(appID).acf"
        guard let content = try? String(contentsOfFile: manifest, encoding: .utf8) else { return nil }
        return SteamCMDManager.sizeOnDisk(in: content)
    }

    private func enqueueSteamOperation(_ appId: String, kind: LibraryOperationKind) async {
        let name = localBottle.games.first(where: { $0.steamAppId == appId })?.name
            ?? ownedGames.first(where: { $0.appId == appId })?.name
            ?? "App \(appId)"
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
        var hasSteamCMDSession = steamCMDSessionConfirmed
        if !hasSteamCMDSession, !user.isEmpty {
            hasSteamCMDSession = await steamCMD.hasSession(user: user)
        }
        guard !user.isEmpty, hasSteamCMDSession else {
            pendingInstallAppId = appId
            pendingOperationKind = kind
            showSteamCMDLogin = true
            return
        }
        steamCMDSessionConfirmed = true
        steamCMDUser = user
        clearCancelledSteamMarker(appId)
        operations.enqueue(gameID: appId, title: name, kind: kind,
                           executor: steamExecutor(appId: appId, user: user))
    }

    private func steamExecutor(appId: String, user: String) -> LibraryOperationQueue.Executor {
        { operation in
            try await performSteamOperation(operation, appId: appId, user: user)
        }
    }

    private func performSteamOperation(_ operation: LibraryOperationQueue.Operation,
                                       appId: String, user: String) async throws {
        let installedGame = localBottle.games.first { $0.steamAppId == appId }
        let name = installedGame?.name
            ?? ownedGames.first(where: { $0.appId == appId })?.name
            ?? operation.title
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "")
        let installDir: String
        if let existing = installedGame, !existing.installPath.isEmpty {
            installDir = existing.installPath
        } else {
            installDir = "\(localBottle.steamDirectory)/steamapps/common/\(safeName)"
        }

        // Marca de "descarga en vuelo" persistida: si la app muere a mitad (o el steamcmd se
        // interrumpe), `resumeInterruptedDownloads` la reanuda al volver (steamcmd continúa
        // desde su staging con el mismo force_install_dir). Se borra al completar.
        if operation.kind == .install, installedGame == nil {
            var inflight = UserDefaults.standard.dictionary(forKey: "steamcmd.inflight") as? [String: String] ?? [:]
            inflight[appId] = installDir
            UserDefaults.standard.set(inflight, forKey: "steamcmd.inflight")
        }

        let operationID = "steam:\(appId)"
        let validate = operation.kind != .update
        let ok = await steamCMD.installGame(
            appId: appId,
            user: user,
            installDir: installDir,
            validate: validate,
            operationID: operationID
        ) { pct, message in
            let presented: String
            if message.contains("Descargando") {
                switch operation.kind {
                case .update: presented = "Actualizando… \(Int(pct))%"
                case .verify: presented = "Verificando y reparando… \(Int(pct))%"
                default: presented = message
                }
            } else if operation.kind == .verify {
                presented = "Verificando archivos…"
            } else {
                presented = message
            }
            operations.report(
                gameID: appId,
                message: presented,
                fraction: message.contains("Descargando") ? pct / 100 : nil
            )
        }
        try Task.checkCancellation()
        guard ok else {
            throw NSError(domain: "Vessel", code: 41,
                          userInfo: [NSLocalizedDescriptionKey: "SteamCMD no pudo completar la operación."])
        }

        if operation.kind == .install, installedGame == nil, let exe = mainExecutable(in: installDir) {
            let game = GameInstall(
                name: name, executablePath: exe, steamAppId: appId, installPath: installDir,
                coverImageURL: "https://cdn.akamai.steamstatic.com/steam/apps/\(appId)/library_600x900_2x.jpg"
            )
            store.addGame(game, to: localBottle.id)
            if let updated = store.bottles.first(where: { $0.id == localBottle.id }) { localBottle = updated }
            ownedGames.removeAll { $0.appId == appId }
            NotificationService.shared.notify(title: "Instalación completada", body: name)
        } else if operation.kind == .update {
            updatesAvailable.remove(appId)
            NotificationService.shared.notify(title: "Actualización completada", body: name)
        } else if operation.kind == .verify {
            NotificationService.shared.notify(title: "Verificación completada", body: name)
        }

        var done = UserDefaults.standard.dictionary(forKey: "steamcmd.inflight") as? [String: String] ?? [:]
        done.removeValue(forKey: appId)
        UserDefaults.standard.set(done, forKey: "steamcmd.inflight")
        await autoImportGames()
        await refreshSteamUpdates()
    }

    private func cancelSteamOperation(_ game: StoreGame) {
        var cancelled = Set(UserDefaults.standard.stringArray(forKey: "steamcmd.cancelled") ?? [])
        cancelled.insert(game.id)
        UserDefaults.standard.set(Array(cancelled), forKey: "steamcmd.cancelled")
        var inflight = UserDefaults.standard.dictionary(forKey: "steamcmd.inflight") as? [String: String] ?? [:]
        inflight.removeValue(forKey: game.id)
        UserDefaults.standard.set(inflight, forKey: "steamcmd.inflight")
        operations.cancel(game.id)
    }

    private func clearCancelledSteamMarker(_ appId: String) {
        var cancelled = Set(UserDefaults.standard.stringArray(forKey: "steamcmd.cancelled") ?? [])
        guard cancelled.remove(appId) != nil else { return }
        UserDefaults.standard.set(Array(cancelled), forKey: "steamcmd.cancelled")
    }

    /// Reanuda las descargas de SteamCMD que quedaron a medias (app cerrada o steamcmd
    /// interrumpido). SteamCMD continúa desde su propio staging con el mismo `force_install_dir`,
    /// así que basta relanzar la instalación con el mismo directorio.
    private func resumeInterruptedDownloads() {
        // (a) Marcas persistidas por esta versión de la app.
        var pending = UserDefaults.standard.dictionary(forKey: "steamcmd.inflight") as? [String: String] ?? [:]
        let intentionallyCancelled = Set(UserDefaults.standard.stringArray(forKey: "steamcmd.cancelled") ?? [])
        pending = pending.filter { !intentionallyCancelled.contains($0.key) }
        // (b) Descubrimiento por disco: carpetas de staging huérfanas (`common/<Juego>/steamapps/
        // downloading/<appid>`) de interrupciones anteriores a esta versión. Solo si el appId
        // sigue siendo de nuestra propiedad y el juego NO está ya instalado.
        let steamapps = "\(localBottle.steamDirectory)/steamapps"
        let fm = FileManager.default
        if let commons = try? fm.contentsOfDirectory(atPath: "\(steamapps)/common") {
            for dirName in commons {
                let downloading = "\(steamapps)/common/\(dirName)/steamapps/downloading"
                guard let appIds = try? fm.contentsOfDirectory(atPath: downloading) else { continue }
                for appId in appIds where pending[appId] == nil {
                    guard !intentionallyCancelled.contains(appId), !operations.itemIDs.contains(appId) else { continue }
                    let alreadyOwned = localBottle.games.contains { $0.steamAppId == appId }
                    if !alreadyOwned, ownedGames.contains(where: { $0.appId == appId }) {
                        pending[appId] = "\(steamapps)/common/\(dirName)"
                    }
                }
            }
        }
        guard !pending.isEmpty else { return }
        for (appId, dir) in pending {
            if operations.itemIDs.contains(appId) { continue }
            // Si ya está completo (su downloading/ ya no existe y el juego está en el store), limpiar la marca.
            let staged = "\(dir)/steamapps/downloading/\(appId)"
            let alreadyOwned = localBottle.games.contains { $0.steamAppId == appId }
            if alreadyOwned || !fm.fileExists(atPath: staged) {
                var clean = UserDefaults.standard.dictionary(forKey: "steamcmd.inflight") as? [String: String] ?? [:]
                clean.removeValue(forKey: appId)
                UserDefaults.standard.set(clean, forKey: "steamcmd.inflight")
                continue
            }
            log.log("Reanudando descarga interrumpida de \(ownedGames.first(where: { $0.appId == appId })?.name ?? "App \(appId)")…", level: .info)
            Task { await enqueueSteamOperation(appId, kind: .install) }
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
        var changed = false

        // Las instalaciones hechas por SteamCMD guardan su manifiesto dentro de
        // `<juego>/steamapps`, no necesariamente en el `steamapps` del cliente. Por eso un juego
        // ya registrado debe poder autorreparar su ejecutable directamente desde `installPath`,
        // aunque el escaneo de manifiestos no lo devuelva. Esto migra datos de versiones antiguas
        // que eligieron un panel auxiliar (Ys Origin: `config.exe`) sin reinstalar ni cambiar de
        // vista, y también mantiene la garantía si el estudio reorganiza el depot en una update.
        for game in localBottle.games {
            guard let appId = game.steamAppId, !appId.isEmpty else { continue }
            let installPath = game.installPath.isEmpty
                ? (game.executablePath as NSString).deletingLastPathComponent
                : game.installPath
            guard !installPath.isEmpty,
                  FileManager.default.fileExists(atPath: installPath),
                  let resolved = SteamLibraryImporter.mainGameExecutable(in: installPath)
            else { continue }
            if store.fixGameExecutable(
                steamAppId: appId,
                executablePath: resolved,
                installPath: installPath,
                in: localBottle.id
            ) {
                log.log(
                    "Auto-reparado el ejecutable registrado de \(game.name) → \((resolved as NSString).lastPathComponent)",
                    level: .info
                )
                changed = true
            }
        }

        let found = importer.scanBottleGames(bottle: localBottle)
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
        let installRoot = game.installPath.isEmpty
            ? (game.executablePath as NSString).deletingLastPathComponent
            : game.installPath
        exePath = GameExecutableOverride.resolve(
            configuredPath: cfg.executableOverride,
            installRoot: installRoot,
            fallback: exePath
        )
        let profile = CompatService.shared.profile(steam: game.steamAppId, title: game.name)
        var eff = CompatService.shared.effectiveConfig(profile: profile, user: cfg)
        if let forcedLayer { eff.graphicsOverride = forcedLayer }
        let trackingTarget = wineManager.launchTrackingTarget(
            for: exePath,
            basePrefix: localBottle.prefixPath
        )
        let trackedExecutable = trackingTarget.executable
        let trackedPrefix = trackingTarget.prefix
        // Motor REAL que se usará (no `.auto`), para que el fallback recorra los 3 motores.
        let usedLayer = wineManager.resolvedGraphicsLayer(forExecutable: exePath, effective: eff)
        let usesRealSteamLaunch = eff.useRealSteam
            || UserDefaults.standard.bool(forKey: "vessel.steamRealGlobal")
            || SteamDRMScanner.hasSteamStub(exePath)
        await GameLaunchTracker.shared.track(
            trackId, statsKey: "steam:\(trackId)",
            // Copia de partida automática: al CERRAR el juego, respalda la partida (seguro, solo copia).
            onExit: { Task {
                await SaveBackupManager.shared.backup(store: .steam, id: trackId, title: game.name, steamId: game.steamAppId, prefix: localBottle.prefixPath, installPath: game.installPath)
                // Nube de Steam en Modo Vessel (opt-in): al SALIR, sube los cambios de la sesión.
                if cfg.steamCloudSync, !eff.useRealSteam, let appId = game.steamAppId {
                    await wineManager.syncSteamCloud(appId: appId, in: localBottle)
                }
            } },
            processFamilyIsRunning: {
                await wineManager.isGameProcessFamilyRunning(
                    executable: trackedExecutable,
                    prefix: trackedPrefix
                )
            },
            stopProcessFamily: {
                await wineManager.terminateGameProcessFamily(
                    executable: trackedExecutable,
                    prefix: trackedPrefix
                )
            }
        ) {
            // Nube de Steam en Modo Vessel (opt-in): ANTES de jugar, baja la última nube del cliente.
            if cfg.steamCloudSync, !eff.useRealSteam, let appId = game.steamAppId {
                await wineManager.syncSteamCloud(appId: appId, in: localBottle)
            }
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
            usesRealSteam: usesRealSteamLaunch,
            isRunning: { GameLaunchTracker.shared.state(trackId) == .running },
            hasVisibleWindow: {
                await wineManager.hasVisibleGameWindow(
                    executable: trackedExecutable,
                    prefix: trackedPrefix
                )
            },
            // Al reparar con éxito, recordar la capa ganadora como override del juego → la próxima
            // vez arranca directa en el motor que funciona (el arreglo PERSISTE, no se repite el crash).
            persistWinningLayer: { winLayer in
                var c = GameConfigStore.load(trackId)
                c.graphicsLayer = winLayer
                GameConfigStore.save(trackId, c)
                // Loop de auto-aprendizaje: registra el arreglo para poder compartirlo con la comunidad.
                DiscoveredFixesStore.shared.record(id: trackId, title: game.name, store: "steam",
                                                   storeId: game.steamAppId, graphicsLayer: winLayer.rawValue,
                                                   useRealSteam: c.useRealSteam)
            },
            // Auto-reparación de Steam: el juego pide una interfaz de Steam que la emulación no provee
            // (Steam Input/Controller). Activamos el modo Steam-real PERSISTENTE y relanzamos.
            // El cliente y el juego comparten ahora el MISMO motor/wineserver también en PE32 OpenGL,
            // por lo que el IPC real de Steam funciona. Solo se activa cuando el diagnóstico demuestra
            // que falta una interfaz Steamworks; no es un cambio indiscriminado de todos los juegos.
            // Otros PE32 conservan su ruta probada de CrossOver/Goldberg hasta tener evidencia propia.
            retryWithRealSteam: (wineManager.isExecutable32Bit(exePath)
                                 && wineManager.detectGraphicsAPI(forExecutable: exePath) != .opengl) ? nil : ({
                var c = GameConfigStore.load(trackId)
                c.useRealSteam = true
                GameConfigStore.save(trackId, c)
                await launchGame(game, attempt: attempt + 1)
            } as @MainActor () async -> Void),
            // Auto-reparación de RUNTIME: si falta VC++/.NET, instálalo (winetricks) y relanza (una vez).
            retryWithRuntimeFix: { missingLibrary in
                let repaired = await wineManager.installMissingRuntimes(
                    in: localBottle,
                    forExecutable: exePath,
                    missingLibrary: missingLibrary
                )
                if repaired { await launchGame(game, attempt: attempt + 1) }
                return repaired
            }
        ) { next in await launchGame(game, forcedLayer: next, attempt: attempt + 1) }
    }

    /// Si Vessel se actualizó o reinició con el juego aún abierto, reconstruye «Ejecutándose» al
    /// volver a su ficha. La detección usa el ejecutable efectivo y el prefijo; no una bandera
    /// persistida ni un nombre global que pueda confundirse con otro juego o con Steam de macOS.
    private func reconcileRunningGame(_ game: GameInstall) async {
        let trackId = game.steamAppId ?? game.id.uuidString
        var executable = game.executablePath
        if !game.installPath.isEmpty,
           let resolved = SteamLibraryImporter.mainGameExecutable(in: game.installPath) {
            executable = resolved
        }
        let config = GameConfigStore.load(trackId)
        let installRoot = game.installPath.isEmpty
            ? (game.executablePath as NSString).deletingLastPathComponent
            : game.installPath
        executable = GameExecutableOverride.resolve(
            configuredPath: config.executableOverride,
            installRoot: installRoot,
            fallback: executable
        )
        let trackingTarget = wineManager.launchTrackingTarget(
            for: executable,
            basePrefix: localBottle.prefixPath
        )
        let trackedExecutable = trackingTarget.executable
        let trackedPrefix = trackingTarget.prefix
        await GameLaunchTracker.shared.adoptRunningProcessFamily(
            trackId,
            processFamilyIsRunning: {
                await wineManager.isGameProcessFamilyRunning(
                    executable: trackedExecutable,
                    prefix: trackedPrefix
                )
            },
            stopProcessFamily: {
                await wineManager.terminateGameProcessFamily(
                    executable: trackedExecutable,
                    prefix: trackedPrefix
                )
            }
        )
    }

    private func refreshDXVKStatus() async {
        dxvkInstalled = wineManager.isDXVKInstalled(in: localBottle)
    }

}
