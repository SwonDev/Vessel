import SwiftUI
import AppKit

/// Orquesta la conexión a **GOG vía gogdl** (modelo Heroic/Mythic):
/// instala gogdl si es necesario, guía al usuario por el flujo de auth code y,
/// una vez autenticado, expone la biblioteca. Todo lo técnico va por detrás.
@MainActor
@Observable
final class GogStore {
    enum Phase {
        case disconnected
        case working(String)
        case connected([GogdlManager.GogGame])
        case error(String)
    }

    var phase: Phase = .disconnected
    private let gogdl = GogdlManager()
    private let log = LogStore.shared
    private let wineManager = WineManager()
    private let dependencyManager = DependencyManager()
    private let store = BottleStore.shared
    private var gogBottle: Bottle?

    let operations = LibraryOperationQueue(storageKey: "gog")
    var updatesAvailable: Set<String> = []

    /// Re-evalúa el estado (al abrir la vista o al volver la app a primer plano).
    /// No interrumpe una operación en curso.
    func refresh() {
        if case .working = phase { return }
        if case .connected = phase { return }   // ya cargada: NO recargar al volver el foco
        if gogdl.isAuthenticated() {
            // Carga INSTANTÁNEA desde caché; el refresco real va en 2.º plano (patrón Heroic).
            if let cached = LibraryCache.load("gog", as: [GogdlManager.GogGame].self) {
                let restored = withInstalledState(cached)
                phase = .connected(restored)
                restoreOperations(for: restored)
                Task { await self.refreshUpdates(for: restored) }
                Task { await self.refreshInstallSizes(for: restored) }
            } else {
                phase = .working("Cargando biblioteca GOG…")
            }
            Task { await self.loadLibrary() }
        } else {
            phase = .disconnected
        }
    }

    /// Flujo completo de conexión GOG:
    /// 1) Instala gogdl si falta, 2) autentica con el código del portal, 3) carga la biblioteca.
    func connect(code: String) async {
        do {
            // Paso 1: gogdl disponible
            phase = .working("Preparando gogdl…")
            _ = try await gogdl.ensureInstalled { msg in
                Task { @MainActor in self.phase = .working(msg) }
            }

            // Paso 2: Autenticación con el código de GOG
            phase = .working("Autenticando con GOG…")
            try await gogdl.authenticate(code: code)
            NotificationCenter.default.post(name: .accountProfileDidChange, object: StoreKind.gog)

            // Paso 3: Biblioteca
            phase = .working("Cargando tu biblioteca de GOG…")
            let games = try await gogdl.ownedGames()
            let installed = withInstalledState(games)
            phase = .connected(installed)
            restoreOperations(for: installed)
            await refreshUpdates(for: installed)
            await refreshInstallSizes(for: installed)
        } catch {
            log.log("Error al conectar GOG: \(error.localizedDescription)", level: .error)
            phase = .error(error.localizedDescription)
        }
    }

    /// Recarga la biblioteca sin pedir el código de nuevo.
    func reloadLibrary() async {
        guard gogdl.isAuthenticated() else { phase = .disconnected; return }
        // Refresco ORGÁNICO: si ya está cargada, NO ponemos splash a pantalla completa; la lista
        // se mantiene y se actualiza en su sitio (los instalados suben arriba) al fijar .connected.
        if case .connected = phase {} else { phase = .working("Actualizando biblioteca GOG…") }
        await loadLibrary()
    }

    /// URL de login de GOG (para el WebView embebido que captura el code automáticamente).
    var authURL: URL { gogdl.authURL }

    /// Abre la página de login de GOG en el navegador predeterminado (respaldo manual).
    func openAuthPage() {
        NSWorkspace.shared.open(gogdl.authURL)
    }

    /// Cierra sesión eliminando las credenciales de gogdl de Vessel.
    func disconnect() {
        gogdl.logout()
        phase = .disconnected
        NotificationCenter.default.post(name: .accountProfileDidChange, object: StoreKind.gog)
    }

    // MARK: - Privado

    private func loadLibrary() async {
        do {
            let games = try await gogdl.ownedGames()
            let installed = withInstalledState(games)
            phase = .connected(installed)
            restoreOperations(for: installed)
            await refreshUpdates(for: installed)
            await refreshInstallSizes(for: installed)
        } catch {
            log.log("Error cargando biblioteca GOG: \(error.localizedDescription)", level: .error)
            // Si ya mostramos la caché, no romper la vista con un error.
            if case .connected = phase { return }
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Instalar / Jugar (modelo Heroic: descarga con gogdl, lanza con wine-dxmt)

    /// Marca `installed` según el disco (existe el `goggame-<id>.info` en su carpeta del bottle).
    private func withInstalledState(_ games: [GogdlManager.GogGame]) -> [GogdlManager.GogGame] {
        guard let bottle = gogBottle ?? store.bottles.first(where: { $0.name == "GOG" }) else { return games }
        return games.map { g in
            var g = g
            g.installed = gogdl.isInstalled(appId: g.appId, installDir: installDir(bottle, g.appId))
            return g
        }
    }

    /// Obtiene (o crea) el bottle dedicado de GOG, con el motor Wine portable instalado.
    private func ensureBottle() async throws -> Bottle {
        if let b = gogBottle { return b }
        if let existing = store.bottles.first(where: { $0.name == "GOG" }) {
            gogBottle = existing
            return existing
        }
        let gcenx = try await dependencyManager.ensureWinePortableInstalled { _, _ in }
        let nb = Bottle(name: "GOG", winePath: gcenx)
        store.add(nb)
        try await wineManager.createBottle(at: nb.prefixPath, winePath: gcenx)
        gogBottle = nb
        return nb
    }

    /// Carpeta de instalación del juego dentro del bottle de GOG.
    private func installDir(_ bottle: Bottle, _ appId: String) -> String {
        "\(bottle.prefixPath)/drive_c/Games/GOG/\(appId)"
    }

    func installPath(for game: GogdlManager.GogGame) -> String? {
        guard game.installed,
              let bottle = gogBottle ?? store.bottles.first(where: { $0.name == "GOG" }) else { return nil }
        return installDir(bottle, game.appId)
    }

    func executablePath(for game: GogdlManager.GogGame) -> String? {
        guard let path = installPath(for: game) else { return nil }
        return gogdl.primaryExecutable(appId: game.appId, installDir: path)
    }

    private func refreshUpdates(for games: [GogdlManager.GogGame]) async {
        guard let bottle = gogBottle ?? store.bottles.first(where: { $0.name == "GOG" }) else {
            updatesAvailable = []
            return
        }
        let installed = games.filter(\.installed).map {
            (appId: $0.appId, installDir: installDir(bottle, $0.appId))
        }
        updatesAvailable = await gogdl.gamesWithUpdates(installedGames: installed)
    }

    private func refreshInstallSizes(for games: [GogdlManager.GogGame]) async {
        guard let bottle = gogBottle ?? store.bottles.first(where: { $0.name == "GOG" }) else { return }
        let paths = games.filter(\.installed).map { ($0.appId, installDir(bottle, $0.appId)) }
        let sizes = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: paths.compactMap { appID, path in
                GogdlManager.installedSizeBytes(at: path).map { (appID, $0) }
            })
        }.value
        guard case .connected(let current) = phase else { return }
        phase = .connected(current.map { game in
            var updated = game
            updated.installSizeBytes = sizes[game.appId]
            return updated
        })
    }

    func install(_ game: GogdlManager.GogGame) { enqueue(game, kind: .install) }
    func verify(_ game: GogdlManager.GogGame) { enqueue(game, kind: .verify) }
    func update(_ game: GogdlManager.GogGame) { enqueue(game, kind: .update) }
    func uninstall(_ game: GogdlManager.GogGame) { enqueue(game, kind: .uninstall) }

    func updateAll(_ games: [GogdlManager.GogGame]) {
        for game in games where game.installed { enqueue(game, kind: .update) }
    }

    func dlcs(for appID: String) async -> [StoreDLC] {
        await gogdl.ownedDLCs(appId: appID).map {
            StoreDLC(id: $0.id, title: $0.title, coverURL: nil,
                     installID: $0.id, owned: true, installed: $0.installed)
        }
    }

    func installDLC(_ dlc: StoreDLC, for game: GogdlManager.GogGame) {
        guard game.installed, dlc.owned, dlc.installed != true else { return }
        operations.enqueue(
            gameID: game.appId,
            title: "\(game.title) · \(dlc.title)",
            kind: .dlc,
            targetID: dlc.id,
            executor: executor(for: game)
        )
    }

    private func enqueue(_ game: GogdlManager.GogGame, kind: LibraryOperationKind) {
        operations.enqueue(gameID: game.appId, title: game.title, kind: kind,
                           executor: executor(for: game))
    }

    private func restoreOperations(for games: [GogdlManager.GogGame]) {
        let byID = Dictionary(games.map { ($0.appId, $0) }, uniquingKeysWith: { first, _ in first })
        for item in operations.items {
            guard let game = byID[item.id] else { continue }
            operations.attach(gameID: item.id, executor: executor(for: game))
        }
    }

    private func executor(for game: GogdlManager.GogGame) -> LibraryOperationQueue.Executor {
        { [weak self] operation in
            guard let self else { throw CancellationError() }
            try await self.perform(operation, game: game)
        }
    }

    private func perform(_ operation: LibraryOperationQueue.Operation,
                         game: GogdlManager.GogGame) async throws {
        do {
            let bottle = try await ensureBottle()
            let dir = installDir(bottle, game.appId)
            let operationID = "gog:\(operation.id)"
            let progress: @Sendable (String) -> Void = { [weak self] line in
                guard let pct = GogdlManager.progressPercent(in: line) else { return }
                Task { @MainActor [weak self] in
                    let verb = operation.kind == .verify ? "Verificando" :
                               (operation.kind == .update ? "Actualizando" : "Descargando")
                    self?.operations.report(gameID: operation.id,
                                            message: "\(verb)… \(Int(pct))%",
                                            fraction: pct / 100)
                }
            }

            switch operation.kind {
            case .install:
                try await gogdl.installGame(appId: game.appId, installDir: dir,
                                            operationID: operationID, onProgress: progress)
                operations.report(gameID: operation.id, message: "Configurando el juego…", fraction: nil)
                await runPostInstall(game.appId, bottle: bottle)
                NotificationService.shared.notify(title: "Instalación completada", body: game.title)
            case .verify:
                try await gogdl.repairGame(appId: game.appId, installDir: dir,
                                           operationID: operationID, onProgress: progress)
            case .update:
                try await gogdl.updateGame(appId: game.appId, installDir: dir,
                                           operationID: operationID, onProgress: progress)
                updatesAvailable.remove(game.appId)
                NotificationService.shared.notify(title: "Actualización completada", body: game.title)
            case .uninstall:
                let root = "\(bottle.prefixPath)/drive_c/Games/GOG"
                try gogdl.uninstallGame(installDir: dir, gamesRoot: root)
                NotificationService.shared.notify(title: "Juego desinstalado", body: game.title)
            case .dlc:
                guard let dlcID = operation.targetID else {
                    throw GogdlManager.GogdlError.notImplemented("No se pudo identificar el contenido adicional.")
                }
                try await gogdl.installDLC(appId: game.appId, dlcID: dlcID, installDir: dir,
                                           operationID: operationID, onProgress: progress)
                NotificationService.shared.notify(title: "Contenido instalado", body: operation.title)
            }
            await reloadLibrary()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.log("GOG · \(game.title): \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    /// Aplica el script de post-instalación de GOG (idempotente). Se llama al instalar y también
    /// antes de jugar: así los juegos que ya estaban instalados **se auto-reparan solos**, sin que
    /// el usuario tenga que reinstalar nada ni enterarse de que existía el problema.
    private func runPostInstall(_ appId: String, bottle: Bottle) async {
        let dir = installDir(bottle, appId)
        guard let root = gogdl.gameRoot(appId: appId, installDir: dir) else { return }
        await GOGPostInstall.applyIfNeeded(appId: appId, root: root, prefix: bottle.prefixPath,
                                           winePath: wineManager.resolveGameWine(for: bottle))
    }

    /// Lanza un juego de GOG ya instalado con el motor de juegos (wine-dxmt), igual que Steam/Epic.
    /// `forcedLayer`/`attempt` los usa el fallback automático de motor (relanzar con otra capa).
    func play(_ game: GogdlManager.GogGame, forcedLayer: GameConfig.GraphicsLayer? = nil, attempt: Int = 0) async {
        // Resolvemos el bottle ANTES de track para tener la ruta del prefijo en ambos extremos
        // (bajar partidas antes de jugar / subirlas al cerrar). Si el bottle no se puede preparar,
        // no hay nada que lanzar.
        let bottle: Bottle
        do { bottle = try await ensureBottle() }
        catch {
            log.log("GOG: no se pudo preparar el entorno para \(game.title): \(error.localizedDescription)", level: .error)
            return
        }
        let dir = installDir(bottle, game.appId)
        let prefix = bottle.prefixPath
        // Config efectiva resuelta ANTES de track para saber la capa gráfica usada y reintentar.
        let cfg = GameConfigStore.load(game.appId)
        let detectedLaunch = gogdl.primaryLaunch(appId: game.appId, installDir: dir)
        let executable = GameExecutableOverride.resolve(
            configuredPath: cfg.executableOverride,
            installRoot: dir,
            fallback: detectedLaunch?.executable ?? ""
        )
        guard !executable.isEmpty else {
            log.log("GOG: no se encontró el ejecutable de \(game.title). Elige uno en Ajustes → Avanzado o reinstala el juego.", level: .warn)
            return
        }
        let launchArguments = executable == detectedLaunch?.executable ? (detectedLaunch?.arguments ?? []) : []
        let profile = CompatService.shared.profile(gog: game.appId, title: game.title)
        var eff = CompatService.shared.effectiveConfig(profile: profile, user: cfg)
        if let forcedLayer { eff.graphicsOverride = forcedLayer }
        // Motor REAL que se usará (no `.auto`), para que el fallback recorra los 3 motores.
        let usedLayer = wineManager.resolvedGraphicsLayer(forExecutable: executable, effective: eff)
        await GameLaunchTracker.shared.track(
            game.appId, statsKey: "gog:\(game.appId)",
            // Cloud saves automáticos: al CERRAR el juego, sube a la nube de GOG + copia local de Vessel.
            onExit: { Task {
                await self.gogdl.syncSaves(appId: game.appId, installDir: dir, prefix: prefix, direction: .upload)
                await SaveBackupManager.shared.backup(store: .gog, id: game.appId, title: game.title, steamId: nil, prefix: prefix, installPath: dir)
            } }
        ) {
            // Ejecutable **y argumentos**: los clásicos de GOG son DOS/ScummVM envueltos y su
            // ejecutable es `DOSBOX\dosbox.exe`, que sin `-conf …` abre un prompt de DOS vacío.
            // Auto-reparación: completa la post-instalación de GOG si falta (juegos instalados
            // antes de que Vessel supiera hacerlo). Idempotente y barato.
            await self.runPostInstall(game.appId, bottle: bottle)
            // Cloud saves: baja lo último de la nube ANTES de jugar (silencioso si no aplica).
            await self.gogdl.syncSaves(appId: game.appId, installDir: dir, prefix: prefix, direction: .download)
            await SaveBackupManager.shared.restoreIfNewer(store: .gog, id: game.appId, title: game.title, steamId: nil, prefix: prefix, installPath: dir)
            return try await self.wineManager.launch(executable: executable, in: bottle,
                                                     arguments: launchArguments, effective: eff)
        }
        // Diagnóstico + fallback automático de motor (DXMT ↔ GPTK) si falla el arranque.
        LaunchDiagnostics.monitorAndMaybeRetry(
            prefix: prefix, gameId: game.appId, gameTitle: game.title,
            currentLayer: usedLayer, attempt: attempt,
            fallbackLayers: wineManager.fallbackLayers(forExecutable: executable, effective: eff),
            isRunning: { GameLaunchTracker.shared.state(game.appId) == .running },
            persistWinningLayer: { winLayer in
                var c = GameConfigStore.load(game.appId)
                c.graphicsLayer = winLayer
                GameConfigStore.save(game.appId, c)
                DiscoveredFixesStore.shared.record(id: game.appId, title: game.title, store: "gog",
                                                   storeId: game.appId, graphicsLayer: winLayer.rawValue,
                                                   useRealSteam: c.useRealSteam)
            },
            // Auto-reparación de runtime (VC++/.NET) también para GOG, igual que Steam.
            retryWithRuntimeFix: { [weak self] in
                guard let self else { return }
                await self.wineManager.installMissingRuntimes(in: bottle, forExecutable: executable)
                await self.play(game, attempt: attempt + 1)
            }
        ) { [weak self] next in await self?.play(game, forcedLayer: next, attempt: attempt + 1) }
    }
}
// MARK: - Vista raíz

/// Vista de la tienda GOG: pantalla de conexión sin sesión, progreso mientras
/// conecta y biblioteca cuando ya está autenticado.
struct GogStoreView: View {
    @State private var gog = GogStore()

    var body: some View {
        Group {
            switch gog.phase {
            case .connected(let games):
                StoreLibraryView(
                    store: .gog,
                    games: games.map {
                        StoreGame(id: $0.appId, title: $0.title,
                                  coverURL: $0.coverURL, installed: $0.installed,
                                  updateAvailable: gog.updatesAvailable.contains($0.appId),
                                  installPath: gog.installPath(for: $0),
                                  executablePath: gog.executablePath(for: $0),
                                  installSizeBytes: $0.installSizeBytes)
                    },
                    installingIDs: gog.operations.itemIDs,
                    progressFor: { gog.operations.message(for: $0) },
                    percentFor: { gog.operations.fraction(for: $0) },
                    transferTitleFor: { gog.operations.title(for: $0) },
                    transferPhaseFor: { gog.operations.transferPhase(for: $0) },
                    transferPositionFor: { gog.operations.position(of: $0) },
                    canPauseTransfer: { gog.operations.canPause($0) },
                    canCancelTransfer: { gog.operations.canCancel($0) },
                    canPrioritizeTransfer: { gog.operations.canPrioritize($0) },
                    canRetryTransfer: { gog.operations.canRetry($0) },
                    onPauseTransfer: { gog.operations.pause($0.id) },
                    onResumeTransfer: { gog.operations.resume($0.id) },
                    onCancelTransfer: { gog.operations.cancel($0.id) },
                    onPrioritizeTransfer: { gog.operations.prioritize($0.id) },
                    onRetryTransfer: { gog.operations.resume($0.id) },
                    onInstall: { sg in if let g = games.first(where: { $0.appId == sg.id }) { gog.install(g) } },
                    onPlay:    { sg in if let g = games.first(where: { $0.appId == sg.id }) { Task { await gog.play(g) } } },
                    onUninstall: { sg in if let g = games.first(where: { $0.appId == sg.id }) { gog.uninstall(g) } },
                    onVerify:  { sg in if let g = games.first(where: { $0.appId == sg.id }) { gog.verify(g) } },
                    onUpdate:  { sg in if let g = games.first(where: { $0.appId == sg.id }) { gog.update(g) } },
                    onUpdateAll: { storeGames in
                        gog.updateAll(storeGames.compactMap { sg in games.first { $0.appId == sg.id } })
                    },
                    dlcsFor: { await gog.dlcs(for: $0.id) },
                    onInstallDLC: { storeGame, dlc in
                        guard let game = games.first(where: { $0.appId == storeGame.id }) else { return }
                        gog.installDLC(dlc, for: game)
                    },
                    onReload:  { Task { await gog.reloadLibrary() } },
                    onLogout:  { gog.disconnect() }
                )
            case .working(let msg):
                ConnectGogView(working: msg, errorMessage: nil, authURL: gog.authURL, onConnect: { _ in })
            case .error(let msg):
                ConnectGogView(working: nil, errorMessage: msg, authURL: gog.authURL,
                               onConnect:  { code in Task { await gog.connect(code: code) } })
            case .disconnected:
                ConnectGogView(working: nil, errorMessage: nil, authURL: gog.authURL,
                               onConnect:  { code in Task { await gog.connect(code: code) } })
            }
        }
        .task { gog.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            gog.refresh()
        }
    }
}

// MARK: - Pantalla de conexión (disconnected / error / working)

/// Pantalla "Conecta tu cuenta de GOG": guía al usuario en 2 pasos
/// (abrir la web de GOG → pegar el authorization code).
/// Muestra progreso con spinner cuando `working != nil`.
struct ConnectGogView: View {
    let working: String?
    let errorMessage: String?
    let authURL: URL
    let onConnect: (String) -> Void

    private let tint = StoreKind.gog.tint
    @State private var showingLogin = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            StoreLogoTile(store: .gog)
                .scaleEffect(pulse && !reduceMotion ? 1.08 : 1.0)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                    value: pulse
                )

            Text("GOG")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)

            if let working {
                // Estado de progreso
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text(working)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .liquidGlass(in: Capsule())
                }
                .padding(.top, 4)
            } else {
                // Pantalla de conexión con un único botón (WebView embebido captura el code)
                VStack(spacing: 20) {
                    Text("Conecta tu cuenta de GOG para ver y jugar toda tu biblioteca desde Vessel.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)

                    // Mensaje de error (si lo hay)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 440)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                .red.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            )
                    }

                    // Único botón: abre el WebView de login dentro de la app
                    Button {
                        showingLogin = true
                    } label: {
                        Label("Iniciar sesión con GOG", systemImage: "globe")
                            .frame(maxWidth: 320)
                            .padding(.vertical, 4)
                    }
                    .vesselButton(tint: tint)
                    .padding(.top, 4)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesselBackground(tint: tint)
        .onAppear { pulse = working != nil }
        .onChange(of: working) { _, new in pulse = new != nil }
        // Sheet con el WebView embebido de GOG
        .sheet(isPresented: $showingLogin) {
            GogWebLoginSheet(authURL: authURL) { code in
                showingLogin = false
                onConnect(code)
            }
        }
    }
}

// MARK: - Sheet de WebView (login de GOG)

/// Sheet que presenta el portal de inicio de sesión de GOG dentro de un WKWebView.
/// Captura el `code` automáticamente del redirect — sin que el usuario copie ni pegue nada.
struct GogWebLoginSheet: View {
    let authURL: URL
    let onCodeCaptured: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isLoading = true
    @State private var webError: String?
    private let tint = StoreKind.gog.tint

    var body: some View {
        VStack(spacing: 0) {
            // Barra de cabecera
            HStack(spacing: 12) {
                StoreLogoTile(store: .gog, size: 28)
                Text("Iniciar sesión — GOG")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("Cerrar inicio de sesión")
                .vesselHelp("Cerrar inicio de sesión", shortcut: "Esc")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.navyTop)

            Divider().opacity(0.15)

            ZStack {
                GogLoginWebView(
                    authURL: authURL,
                    onCodeCaptured: { code in
                        dismiss()
                        onCodeCaptured(code)
                    },
                    onError: { error in
                        webError = error
                        isLoading = false
                    },
                    onLoadingChanged: { loading in
                        if loading { webError = nil }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                            isLoading = loading
                        }
                    }
                )

                if isLoading {
                    ZStack {
                        Theme.navyDeep.opacity(0.88)
                        VStack(spacing: 14) {
                            ProgressView().controlSize(.large).tint(.white)
                            Text("Cargando GOG…")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .padding(28)
                        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                    }
                    .transition(.opacity)
                }

                if let webError {
                    ZStack {
                        Theme.navyDeep.opacity(0.94)
                        VStack(spacing: 20) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 48))
                                .foregroundStyle(tint.opacity(0.75))
                            Text(webError)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 360)
                            Button("Cerrar") { dismiss() }
                                .vesselButton(false)
                        }
                        .padding(36)
                    }
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: webError)
        }
        .frame(width: 820, height: 640)
        .background(Theme.navyDeep)
    }
}
