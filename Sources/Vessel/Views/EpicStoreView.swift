import SwiftUI
import AppKit

/// Orquesta la conexión a **Epic Games vía Legendary** (modelo Heroic/Mythic):
/// descarga Legendary si es necesario, autentica al usuario mediante un WebView
/// embebido y, una vez autenticado, expone la biblioteca. Todo lo técnico va por detrás.
@MainActor
@Observable
final class EpicStore {
    enum Phase {
        case disconnected
        case working(String)
        case connected([LegendaryManager.EpicGame])
        case error(String)
    }

    var phase: Phase = .disconnected
    private let legendary = LegendaryManager()
    private let log = LogStore.shared
    private let wineManager = WineManager()
    private let dependencyManager = DependencyManager()
    private let store = BottleStore.shared
    private var epicBottle: Bottle?

    /// Estado de instalación en curso por juego (para los botones de las tarjetas).
    var installingAppNames: Set<String> = []
    var installProgress: [String: String] = [:]
    /// Progreso 0.0–1.0 si se conoce (parseado de legendary) → barra determinada estilo Steam.
    var installPercents: [String: Double] = [:]

    /// Re-evalúa el estado (al abrir la vista o al volver la app a primer plano).
    /// No interrumpe una operación en curso.
    func refresh() {
        if case .working = phase { return }
        if case .connected = phase { return }   // ya cargada: NO recargar al volver el foco (evita el bucle de "Cargando…")
        if legendary.isAuthenticated() {
            // Carga INSTANTÁNEA desde caché; el refresco real va en 2º plano.
            if let cached = LibraryCache.load("epic", as: [LegendaryManager.EpicGame].self) {
                phase = .connected(cached)
            } else {
                phase = .working("Cargando biblioteca Epic…")
            }
            Task { await self.loadLibrary() }
        } else {
            phase = .disconnected
        }
    }

    /// Flujo completo de conexión Epic:
    /// 1) Descarga Legendary si falta, 2) autentica con el código del WebView, 3) carga la biblioteca.
    func connect(code: String) async {
        do {
            // Paso 1: Legendary
            phase = .working("Preparando Legendary…")
            _ = try await legendary.ensureInstalled { msg in
                Task { @MainActor in self.phase = .working(msg) }
            }

            // Paso 2: Autenticación con el código capturado por el WebView
            phase = .working("Autenticando con Epic Games…")
            try await legendary.authenticate(code: code)
            NotificationCenter.default.post(name: .accountProfileDidChange, object: StoreKind.epic)

            // Paso 3: Biblioteca
            phase = .working("Cargando tu biblioteca de Epic Games…")
            let games = try await legendary.ownedGames()
            phase = .connected(games)
        } catch {
            log.log("Error al conectar Epic Games: \(error.localizedDescription)", level: .error)
            phase = .error(error.localizedDescription)
        }
    }

    /// Recarga la biblioteca sin pedir el código de nuevo.
    func reloadLibrary() async {
        guard legendary.isAuthenticated() else { phase = .disconnected; return }
        // Refresco ORGÁNICO: si la biblioteca YA está cargada, NO mostramos splash a pantalla
        // completa (queda horrible). La lista se mantiene visible y se actualiza en su sitio
        // cuando loadLibrary fija `.connected(nuevos)` (los instalados suben arriba solos).
        if case .connected = phase {} else { phase = .working("Actualizando biblioteca Epic…") }
        await loadLibrary()
    }

    /// Cierra sesión eliminando la config de Legendary de Vessel.
    func disconnect() {
        legendary.logout()
        phase = .disconnected
        NotificationCenter.default.post(name: .accountProfileDidChange, object: StoreKind.epic)
    }

    // MARK: - Privado

    private func loadLibrary() async {
        do {
            let games = try await legendary.ownedGames()
            phase = .connected(games)
            // Detección de actualizaciones (orientativa, no bloquea la biblioteca).
            Task { self.updatesAvailable = await legendary.gamesWithUpdates() }
        } catch {
            log.log("Error cargando biblioteca Epic: \(error.localizedDescription)", level: .error)
            // Si ya mostramos la caché, no romper la vista con un error.
            if case .connected = phase { return }
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Instalar / Jugar

    /// `appName`s con actualización disponible (detección por `legendary --check-updates`).
    var updatesAvailable: Set<String> = []

    func isInstalling(_ appName: String) -> Bool { installingAppNames.contains(appName) }
    func progress(_ appName: String) -> String? { installProgress[appName] }
    func percent(_ appName: String) -> Double? { installPercents[appName] }

    /// Obtiene (o crea) el bottle dedicado de Epic, con el motor Wine portable instalado.
    private func ensureBottle() async throws -> Bottle {
        if let b = epicBottle { return b }
        if let existing = store.bottles.first(where: { $0.name == "Epic Games" }) {
            epicBottle = existing
            return existing
        }
        let gcenx = try await dependencyManager.ensureWinePortableInstalled { _, _ in }
        let nb = Bottle(name: "Epic Games", winePath: gcenx)
        store.add(nb)
        try await wineManager.createBottle(at: nb.prefixPath, winePath: gcenx)
        epicBottle = nb
        return nb
    }

    /// Instala un juego de Epic dentro del bottle de Vessel (con progreso en vivo).
    func install(_ game: LegendaryManager.EpicGame) async {
        installingAppNames.insert(game.appName)
        installProgress[game.appName] = "Preparando…"
        defer {
            installingAppNames.remove(game.appName)
            installProgress[game.appName] = nil
            installPercents[game.appName] = nil
        }
        do {
            let bottle = try await ensureBottle()
            let dir = "\(bottle.prefixPath)/drive_c/Games"
            try await legendary.installGame(appName: game.appName, basePath: dir) { line in
                // Parsea el % de las líneas de legendary → barra determinada estilo Steam.
                if let pct = LegendaryManager.progressPercent(in: line) {
                    Task { @MainActor in
                        self.installPercents[game.appName] = max(0, min(1, pct / 100))
                        self.installProgress[game.appName] = "Descargando… \(Int(pct))%"
                    }
                }
            }
            NotificationService.shared.notify(title: "Instalación completada", body: game.title)
            await reloadLibrary()
        } catch {
            log.log("Error instalando \(game.title): \(error.localizedDescription)", level: .error)
            installProgress[game.appName] = "Error en la instalación"
        }
    }

    /// Verifica y repara un juego de Epic ya instalado (reusa el feedback visual de instalación).
    func verify(_ game: LegendaryManager.EpicGame) async {
        installingAppNames.insert(game.appName)
        installProgress[game.appName] = "Verificando…"
        defer {
            installingAppNames.remove(game.appName)
            installProgress[game.appName] = nil
            installPercents[game.appName] = nil
        }
        do {
            let bottle = try await ensureBottle()
            let dir = "\(bottle.prefixPath)/drive_c/Games"
            try await legendary.repairGame(appName: game.appName, basePath: dir) { line in
                if let pct = LegendaryManager.progressPercent(in: line) {
                    Task { @MainActor in
                        self.installPercents[game.appName] = max(0, min(1, pct / 100))
                        self.installProgress[game.appName] = "Verificando… \(Int(pct))%"
                    }
                }
            }
            await reloadLibrary()
        } catch {
            log.log("Error verificando \(game.title): \(error.localizedDescription)", level: .error)
            installProgress[game.appName] = "Error en la verificación"
        }
    }

    /// Aplica la actualización de un juego de Epic (reusa el feedback visual de instalación).
    func update(_ game: LegendaryManager.EpicGame) async {
        installingAppNames.insert(game.appName)
        installProgress[game.appName] = "Actualizando…"
        defer {
            installingAppNames.remove(game.appName)
            installProgress[game.appName] = nil
            installPercents[game.appName] = nil
        }
        do {
            let bottle = try await ensureBottle()
            let dir = "\(bottle.prefixPath)/drive_c/Games"
            try await legendary.updateGame(appName: game.appName, basePath: dir) { line in
                if let pct = LegendaryManager.progressPercent(in: line) {
                    Task { @MainActor in
                        self.installPercents[game.appName] = max(0, min(1, pct / 100))
                        self.installProgress[game.appName] = "Actualizando… \(Int(pct))%"
                    }
                }
            }
            updatesAvailable.remove(game.appName)
            await reloadLibrary()
        } catch {
            log.log("Error actualizando \(game.title): \(error.localizedDescription)", level: .error)
            installProgress[game.appName] = "Error en la actualización"
        }
    }

    /// Desinstala un juego de Epic (borra los archivos vía legendary) y refresca la biblioteca.
    func uninstall(_ game: LegendaryManager.EpicGame) async {
        installingAppNames.insert(game.appName)
        installProgress[game.appName] = "Desinstalando…"
        defer {
            installingAppNames.remove(game.appName)
            installProgress[game.appName] = nil
            installPercents[game.appName] = nil
        }
        do {
            try await legendary.uninstallGame(appName: game.appName)
            NotificationService.shared.notify(title: "Juego desinstalado", body: game.title)
            await reloadLibrary()
        } catch {
            log.log("Error desinstalando \(game.title): \(error.localizedDescription)", level: .error)
            installProgress[game.appName] = "Error al desinstalar"
        }
    }

    /// Lanza un juego de Epic ya instalado con el motor de juegos (wine-dxmt), igual que Steam.
    /// `forcedLayer`/`attempt` los usa el fallback automático de motor (relanzar con otra capa).
    func play(_ game: LegendaryManager.EpicGame, forcedLayer: GameConfig.GraphicsLayer? = nil, attempt: Int = 0) async {
        guard let exe = game.executablePath, !exe.isEmpty else {
            log.log("Epic: \(game.title) sin ejecutable conocido (¿reinstalar?)", level: .warn)
            return
        }
        // Resolvemos el bottle antes de track para tener la ruta del prefijo (aviso de compat).
        let bottle: Bottle
        do { bottle = try await ensureBottle() }
        catch {
            log.log("Epic: no se pudo preparar el entorno para \(game.title): \(error.localizedDescription)", level: .error)
            return
        }
        let prefix = bottle.prefixPath
        let gameDir = (exe as NSString).deletingLastPathComponent
        // Config efectiva (perfil comunidad + overrides usuario) resuelta ANTES de track para saber
        // la capa gráfica usada y poder reintentar con otra si falla el arranque.
        let cfg = GameConfigStore.load(game.appName)
        let profile = CompatService.shared.profile(epic: game.appName, title: game.title)
        var eff = CompatService.shared.effectiveConfig(profile: profile, user: cfg)
        if let forcedLayer { eff.graphicsOverride = forcedLayer }
        // Motor REAL que se usará (no `.auto`), para que el fallback recorra los 3 motores.
        let usedLayer = wineManager.resolvedGraphicsLayer(forExecutable: exe, effective: eff)
        // Rastrear el estado (Iniciando… → Ejecutándose) + cloud saves automáticos: al CERRAR
        // el juego, sube la partida a la nube (Epic) + copia local de Vessel. legendary resuelve la ruta.
        await GameLaunchTracker.shared.track(
            game.appName, statsKey: "epic:\(game.appName)",
            onExit: { Task {
                await self.legendary.syncSaves(appName: game.appName, direction: .upload)
                await SaveBackupManager.shared.backup(store: .epic, id: game.appName, title: game.title, steamId: nil, prefix: prefix, installPath: gameDir)
            } }
        ) {
            // Cloud saves: baja lo último de la nube ANTES de jugar (no bloquea si no aplica).
            await legendary.syncSaves(appName: game.appName, direction: .download)
            await SaveBackupManager.shared.restoreIfNewer(store: .epic, id: game.appName, title: game.title, steamId: nil, prefix: prefix, installPath: gameDir)
            return try await wineManager.launch(
                executable: exe, in: bottle, arguments: [], effective: eff
            )
        }
        // Diagnóstico + fallback automático de motor: si falla el arranque de forma recuperable,
        // relanza con la otra capa (DXMT ↔ GPTK) una vez; si no, avisa con causa y acción.
        LaunchDiagnostics.monitorAndMaybeRetry(
            prefix: prefix, gameId: game.appName, gameTitle: game.title,
            currentLayer: usedLayer, attempt: attempt,
            fallbackLayers: wineManager.fallbackLayers(forExecutable: exe, effective: eff),
            isRunning: { GameLaunchTracker.shared.state(game.appName) == .running },
            persistWinningLayer: { winLayer in
                var c = GameConfigStore.load(game.appName)
                c.graphicsLayer = winLayer
                GameConfigStore.save(game.appName, c)
                DiscoveredFixesStore.shared.record(id: game.appName, title: game.title, store: "epic",
                                                   storeId: game.appName, graphicsLayer: winLayer.rawValue,
                                                   useRealSteam: c.useRealSteam)
            },
            // Auto-reparación de runtime (VC++/.NET) también para Epic, igual que Steam.
            retryWithRuntimeFix: { [weak self] in
                await self?.wineManager.installMissingRuntimes(in: bottle, forExecutable: exe)
                await self?.play(game, attempt: attempt + 1)
            }
        ) { [weak self] next in await self?.play(game, forcedLayer: next, attempt: attempt + 1) }
    }
}
// MARK: - Vista raíz

/// Vista de la tienda Epic Games: pantalla de conexión sin sesión, progreso mientras
/// conecta y biblioteca cuando ya está autenticado.
struct EpicStoreView: View {
    @State private var epic = EpicStore()

    var body: some View {
        Group {
            switch epic.phase {
            case .connected(let games):
                StoreLibraryView(
                    store: .epic,
                    games: games.map { StoreGame(id: $0.appName, title: $0.title, coverURL: $0.coverURL, installed: $0.installed, updateAvailable: epic.updatesAvailable.contains($0.appName), installPath: $0.installPath) },
                    installingIDs: epic.installingAppNames,
                    progressFor: { epic.progress($0) },
                    percentFor: { epic.percent($0) },
                    onInstall: { sg in if let g = games.first(where: { $0.appName == sg.id }) { Task { await epic.install(g) } } },
                    onPlay:    { sg in if let g = games.first(where: { $0.appName == sg.id }) { Task { await epic.play(g) } } },
                    onUninstall: { sg in if let g = games.first(where: { $0.appName == sg.id }) { Task { await epic.uninstall(g) } } },
                    onVerify:  { sg in if let g = games.first(where: { $0.appName == sg.id }) { Task { await epic.verify(g) } } },
                    onUpdate:  { sg in if let g = games.first(where: { $0.appName == sg.id }) { Task { await epic.update(g) } } },
                    onReload:  { Task { await epic.reloadLibrary() } },
                    onLogout:  { epic.disconnect() }
                )
            case .working(let msg):
                ConnectEpicView(working: msg, errorMessage: nil,
                                onConnect: { _ in })
            case .error(let msg):
                ConnectEpicView(working: nil, errorMessage: msg,
                                onConnect: { code in Task { await epic.connect(code: code) } })
            case .disconnected:
                ConnectEpicView(working: nil, errorMessage: nil,
                                onConnect: { code in Task { await epic.connect(code: code) } })
            }
        }
        .task { epic.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            epic.refresh()
        }
    }
}

// MARK: - Pantalla de conexión (disconnected / error / working)

/// Pantalla "Conecta tu cuenta de Epic Games": muestra un único botón que abre
/// el WebView embebido de login. El código de autorización se captura automáticamente.
/// Muestra progreso con spinner cuando `working != nil`.
struct ConnectEpicView: View {
    let working: String?
    let errorMessage: String?
    let onConnect: (String) -> Void

    private let tint = StoreKind.epic.tint
    @State private var showingLogin = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            StoreLogoTile(store: .epic)
                .scaleEffect(pulse && !reduceMotion ? 1.08 : 1.0)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                    value: pulse
                )

            Text("Epic Games")
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
                // Pantalla de conexión con un único botón
                VStack(spacing: 20) {
                    Text("Conecta tu cuenta de Epic Games para ver y jugar toda tu biblioteca desde Vessel.")
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
                        Label("Iniciar sesión con Epic Games", systemImage: "globe")
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
        // Sheet con el WebView embebido de Epic
        .sheet(isPresented: $showingLogin) {
            EpicWebLoginSheet { code in
                showingLogin = false
                onConnect(code)
            }
        }
    }
}

// MARK: - Sheet de WebView (login de Epic)

/// Sheet que presenta el portal de inicio de sesión de Epic dentro de un WKWebView.
/// Captura el `authorizationCode` automáticamente al terminar el login y llama a
/// `onCodeCaptured` — sin que el usuario vea JSON ni tenga que copiar nada.
struct EpicWebLoginSheet: View {
    let onCodeCaptured: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isLoading     = true
    @State private var webError: String?
    private let tint = StoreKind.epic.tint

    var body: some View {
        VStack(spacing: 0) {
            // Barra de cabecera
            HStack(spacing: 12) {
                StoreLogoTile(store: .epic, size: 28)
                Text("Iniciar sesión — Epic Games")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    dismiss()
                } label: {
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
                // WebView con el portal de Epic
                EpicLoginWebView(
                    onCodeCaptured: { code in
                        // Código capturado: cerrar sheet y notificar al padre
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

                // Overlay de carga inicial
                if isLoading {
                    ZStack {
                        Theme.navyDeep.opacity(0.88)
                        VStack(spacing: 14) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Cargando Epic Games…")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .padding(28)
                        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                    }
                    .transition(.opacity)
                }

                // Overlay de error
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
                            HStack(spacing: 12) {
                                Button("Cerrar") { dismiss() }
                                    .vesselButton(false)
                            }
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
