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

    /// Estado de instalación en curso por juego (para los botones/tarjetas).
    var installingAppIds: Set<String> = []
    var installProgress: [String: String] = [:]
    /// Progreso 0.0–1.0 si se conoce (parseado de gogdl) → barra determinada estilo Steam.
    var installPercents: [String: Double] = [:]

    func isInstalling(_ id: String) -> Bool { installingAppIds.contains(id) }
    func progress(_ id: String) -> String? { installProgress[id] }
    func percent(_ id: String) -> Double? { installPercents[id] }

    /// Re-evalúa el estado (al abrir la vista o al volver la app a primer plano).
    /// No interrumpe una operación en curso.
    func refresh() {
        if case .working = phase { return }
        if case .connected = phase { return }   // ya cargada: NO recargar al volver el foco
        if gogdl.isAuthenticated() {
            // Carga INSTANTÁNEA desde caché; el refresco real va en 2.º plano (patrón Heroic).
            if let cached = LibraryCache.load("gog", as: [GogdlManager.GogGame].self) {
                phase = .connected(withInstalledState(cached))
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
            phase = .connected(withInstalledState(games))
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
            phase = .connected(withInstalledState(games))
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

    /// Instala un juego de GOG dentro del bottle de Vessel (con progreso en vivo).
    func install(_ game: GogdlManager.GogGame) async {
        installingAppIds.insert(game.appId)
        installProgress[game.appId] = "Preparando…"
        defer {
            installingAppIds.remove(game.appId)
            installProgress[game.appId] = nil
            installPercents[game.appId] = nil
        }
        do {
            let bottle = try await ensureBottle()
            let dir = installDir(bottle, game.appId)
            try await gogdl.installGame(appId: game.appId, installDir: dir) { line in
                if let pct = GogdlManager.progressPercent(in: line) {
                    Task { @MainActor in
                        self.installPercents[game.appId] = max(0, min(1, pct / 100))
                        self.installProgress[game.appId] = "Descargando… \(Int(pct))%"
                    }
                }
            }
            // gogdl deja los ficheros, pero el juego NO está completo hasta ejecutar el
            // `goggame-<id>.script` de GOG (crea los .ini/.conf, las carpetas de partidas y las
            // claves de registro que el juego lee al arrancar). Sin esto, los clásicos se cierran
            // al instante sin decir por qué.
            installProgress[game.appId] = "Configurando el juego…"
            await runPostInstall(game.appId, bottle: bottle)
            NotificationService.shared.notify(title: "Instalación completada", body: game.title)
            await reloadLibrary()
        } catch {
            log.log("Error instalando \(game.title): \(error.localizedDescription)", level: .error)
            installProgress[game.appId] = "Error en la instalación"
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

    /// Verifica y repara un juego de GOG ya instalado (reusa el feedback visual de instalación).
    func verify(_ game: GogdlManager.GogGame) async {
        installingAppIds.insert(game.appId)
        installProgress[game.appId] = "Verificando…"
        defer {
            installingAppIds.remove(game.appId)
            installProgress[game.appId] = nil
            installPercents[game.appId] = nil
        }
        do {
            let bottle = try await ensureBottle()
            let dir = installDir(bottle, game.appId)
            try await gogdl.repairGame(appId: game.appId, installDir: dir) { line in
                if let pct = GogdlManager.progressPercent(in: line) {
                    Task { @MainActor in
                        self.installPercents[game.appId] = max(0, min(1, pct / 100))
                        self.installProgress[game.appId] = "Verificando… \(Int(pct))%"
                    }
                }
            }
            await reloadLibrary()
        } catch {
            log.log("Error verificando \(game.title): \(error.localizedDescription)", level: .error)
            installProgress[game.appId] = "Error en la verificación"
        }
    }

    /// Aplica la actualización de un juego de GOG (reusa el feedback visual de instalación).
    func update(_ game: GogdlManager.GogGame) async {
        installingAppIds.insert(game.appId)
        installProgress[game.appId] = "Actualizando…"
        defer {
            installingAppIds.remove(game.appId)
            installProgress[game.appId] = nil
            installPercents[game.appId] = nil
        }
        do {
            let bottle = try await ensureBottle()
            let dir = installDir(bottle, game.appId)
            try await gogdl.updateGame(appId: game.appId, installDir: dir) { line in
                if let pct = GogdlManager.progressPercent(in: line) {
                    Task { @MainActor in
                        self.installPercents[game.appId] = max(0, min(1, pct / 100))
                        self.installProgress[game.appId] = "Actualizando… \(Int(pct))%"
                    }
                }
            }
            await reloadLibrary()
        } catch {
            log.log("Error actualizando \(game.title): \(error.localizedDescription)", level: .error)
            installProgress[game.appId] = "Error en la actualización"
        }
    }

    /// Desinstala un juego de GOG (borra su carpeta de forma segura) y refresca la biblioteca.
    func uninstall(_ game: GogdlManager.GogGame) async {
        installingAppIds.insert(game.appId)
        installProgress[game.appId] = "Desinstalando…"
        defer {
            installingAppIds.remove(game.appId)
            installProgress[game.appId] = nil
            installPercents[game.appId] = nil
        }
        do {
            let bottle = try await ensureBottle()
            let dir = installDir(bottle, game.appId)
            let root = "\(bottle.prefixPath)/drive_c/Games/GOG"
            try gogdl.uninstallGame(installDir: dir, gamesRoot: root)
            NotificationService.shared.notify(title: "Juego desinstalado", body: game.title)
            await reloadLibrary()
        } catch {
            log.log("Error desinstalando \(game.title): \(error.localizedDescription)", level: .error)
            installProgress[game.appId] = "Error al desinstalar"
        }
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
        let profile = CompatService.shared.profile(gog: game.appId, title: game.title)
        var eff = CompatService.shared.effectiveConfig(profile: profile, user: cfg)
        if let forcedLayer { eff.graphicsOverride = forcedLayer }
        // Motor REAL que se usará (no `.auto`), para que el fallback recorra los 3 motores.
        let usedLayer = gogdl.primaryExecutable(appId: game.appId, installDir: dir)
            .map { wineManager.resolvedGraphicsLayer(forExecutable: $0, effective: eff) } ?? eff.graphicsOverride
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
            guard let launch = self.gogdl.primaryLaunch(appId: game.appId, installDir: dir) else {
                throw GogdlManager.GogdlError.notImplemented("No se encontró el ejecutable del juego. Reinstálalo.")
            }
            // Auto-reparación: completa la post-instalación de GOG si falta (juegos instalados
            // antes de que Vessel supiera hacerlo). Idempotente y barato.
            await self.runPostInstall(game.appId, bottle: bottle)
            // Cloud saves: baja lo último de la nube ANTES de jugar (silencioso si no aplica).
            await self.gogdl.syncSaves(appId: game.appId, installDir: dir, prefix: prefix, direction: .download)
            await SaveBackupManager.shared.restoreIfNewer(store: .gog, id: game.appId, title: game.title, steamId: nil, prefix: prefix, installPath: dir)
            return try await self.wineManager.launch(executable: launch.executable, in: bottle,
                                                     arguments: launch.arguments, effective: eff)
        }
        // Diagnóstico + fallback automático de motor (DXMT ↔ GPTK) si falla el arranque.
        LaunchDiagnostics.monitorAndMaybeRetry(
            prefix: prefix, gameId: game.appId, gameTitle: game.title,
            currentLayer: usedLayer, attempt: attempt,
            fallbackLayers: gogdl.primaryExecutable(appId: game.appId, installDir: dir)
                .map { wineManager.fallbackLayers(forExecutable: $0, effective: eff) } ?? [],
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
                guard let self, let exe = self.gogdl.primaryExecutable(appId: game.appId, installDir: dir) else { return }
                await self.wineManager.installMissingRuntimes(in: bottle, forExecutable: exe)
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
                                  coverURL: $0.coverURL, installed: $0.installed)
                    },
                    installingIDs: gog.installingAppIds,
                    progressFor: { gog.progress($0) },
                    percentFor: { gog.percent($0) },
                    onInstall: { sg in if let g = games.first(where: { $0.appId == sg.id }) { Task { await gog.install(g) } } },
                    onPlay:    { sg in if let g = games.first(where: { $0.appId == sg.id }) { Task { await gog.play(g) } } },
                    onUninstall: { sg in if let g = games.first(where: { $0.appId == sg.id }) { Task { await gog.uninstall(g) } } },
                    onVerify:  { sg in if let g = games.first(where: { $0.appId == sg.id }) { Task { await gog.verify(g) } } },
                    onUpdate:  { sg in if let g = games.first(where: { $0.appId == sg.id }) { Task { await gog.update(g) } } },
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

// MARK: - Biblioteca de GOG (connected)

/// Grid de juegos de la cuenta GOG con búsqueda integrada.
struct GogLibraryView: View {
    let games: [GogdlManager.GogGame]
    let onDisconnect: () -> Void
    let onReload: () -> Void

    @State private var searchText = ""
    private let tint = StoreKind.gog.tint
    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 200), spacing: Theme.Space.gameGrid)]

    private var filtered: [GogdlManager.GogGame] {
        guard !searchText.isEmpty else { return games }
        return games.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {

                // Cabecera
                HStack(spacing: 14) {
                    StoreLogoTile(store: .gog, size: 52)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("GOG")
                            .font(.title.bold())
                            .foregroundStyle(.white)
                        Text("\(games.count) juego\(games.count == 1 ? "" : "s") en tu biblioteca")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.50))
                    }

                    Spacer()

                    Button(action: onReload) {
                        Label("Actualizar", systemImage: "arrow.clockwise")
                    }
                    .vesselButton(false)

                    Button(role: .destructive, action: onDisconnect) {
                        Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .vesselButton(false)
                }

                // Barra de búsqueda (solo si hay suficientes juegos)
                if games.count > 6 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.white.opacity(0.40))
                        TextField("Buscar en tu biblioteca de GOG…", text: $searchText)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        .white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    )
                }

                // Grid de juegos
                if filtered.isEmpty {
                    Text(
                        searchText.isEmpty
                        ? "No se encontraron juegos en tu cuenta de GOG."
                        : "Sin resultados para «\(searchText)»."
                    )
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: Theme.Space.gameGrid) {
                        ForEach(filtered) { game in
                            GogGameCard(game: game)
                        }
                    }
                }
            }
            .padding(Theme.Space.page)
        }
        .vesselBackground(tint: tint)
    }
}

// MARK: - Tarjeta de juego GOG

/// Tarjeta de juego de GOG con portada generada a partir del título
/// (degradado + iniciales) hasta que se integre la API de imágenes de GOG.
/// El color de fondo se genera deterministamente por hash del `appId` para que sea
/// consistente entre sesiones y no cambie al actualizar la biblioteca.
struct GogGameCard: View {
    let game: GogdlManager.GogGame
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Color de fondo generado deterministamente por hash del appId del juego.
    private var placeholderColor: Color {
        var h = 5381
        for c in game.appId.unicodeScalars { h = ((h << 5) &+ h) &+ Int(c.value) }
        // Matiz púrpura/violeta (identidad visual de GOG) desplazado por hash
        let baseHue = 0.76  // ~275° — morado GOG
        let offset  = Double(abs(h) % 80) / 80.0 * 0.20 - 0.10  // ±10% de desviación
        return Color(hue: (baseHue + offset).truncatingRemainder(dividingBy: 1.0),
                     saturation: 0.52, brightness: 0.38)
    }

    /// Iniciales del título (máximo 2 palabras, 1 carácter cada una).
    private var initials: String {
        game.title
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Portada placeholder: degradado morado GOG + iniciales
            ZStack {
                LinearGradient(
                    colors: [placeholderColor, placeholderColor.opacity(0.50)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                // Patrón de estrella decorativo (identidad GOG)
                Image(systemName: "star.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.white.opacity(0.06))
                    .offset(x: 28, y: -20)

                Text(initials)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.30), radius: 4, y: 2)
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))

            // Información del juego
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if game.installed {
                    Label("Instalado", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(red: 0.30, green: 0.85, blue: 0.55))
                } else {
                    Text("En tu biblioteca")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 9)
        }
        .background(
            .white.opacity(hovering ? 0.10 : 0.05),
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(hovering ? 0.20 : 0.08), lineWidth: 0.5)
        )
        .shadow(
            color: placeholderColor.opacity(hovering ? 0.50 : 0.18),
            radius: hovering ? 18 : 6,
            y: hovering ? 9 : 3
        )
        .scaleEffect(hovering && !reduceMotion ? 1.03 : 1.0)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72), value: hovering)
        .onHover { hovering = $0 }
    }
}
