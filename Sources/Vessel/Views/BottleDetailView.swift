import SwiftUI

struct BottleDetailView: View {
    let bottle: Bottle
    @State private var isLaunching = false
    @State private var statusMessage: String?
    @State private var showingInstaller = false
    @State private var wineManager = WineManager()
    @State private var importer = SteamLibraryImporter()
    @State private var gamesWatcher = DirectoryWatcher()
    @State private var gameToUninstall: GameInstall?
    @State private var accountService = SteamAccountService()
    @State private var ownedGames: [SteamAccountService.OwnedGame] = []
    @State private var installingAppIds: Set<String> = []
    @State private var localBottle: Bottle
    @State private var dxvkInstalled: Bool = false
    @State private var reinstallingDXVK = false

    private let store = BottleStore.shared
    private let log = LogStore.shared

    init(bottle: Bottle) {
        self.bottle = bottle
        self._localBottle = State(initialValue: bottle)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                quickActions
                gamesSection
                librarySection
            }
            .padding(32)
        }
        .background(Color(NSColor.windowBackgroundColor))
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
    }

    /// Quita el juego de la lista de Vessel (no borra archivos).
    private func removeGameFromList(_ game: GameInstall) {
        store.deleteGame(game.id, from: localBottle.id)
        if let updated = store.bottles.first(where: { $0.id == localBottle.id }) {
            localBottle = updated
        }
    }

    /// Desinstala el juego: borra sus archivos del bottle (carpeta + appmanifest de
    /// Steam) y lo quita de la lista. El watcher en tiempo real refleja el cambio.
    private func uninstallGame(_ game: GameInstall) {
        let fm = FileManager.default
        if !game.installPath.isEmpty, fm.fileExists(atPath: game.installPath) {
            try? fm.removeItem(atPath: game.installPath)
        }
        if let appId = game.steamAppId, !appId.isEmpty {
            let manifest = "\(localBottle.prefixPath)/drive_c/Program Files (x86)/Steam/steamapps/appmanifest_\(appId).acf"
            try? fm.removeItem(atPath: manifest)
        }
        store.deleteGame(game.id, from: localBottle.id)
        if let updated = store.bottles.first(where: { $0.id == localBottle.id }) {
            localBottle = updated
        }
        log.log("Juego desinstalado: \(game.name)", level: .info)
    }

    // MARK: - Biblioteca completa de Steam

    /// Juegos de la biblioteca del usuario que aún NO están instalados.
    private var notInstalledGames: [SteamAccountService.OwnedGame] {
        let installedIds = Set(localBottle.games.compactMap { $0.steamAppId })
        return ownedGames
            .filter { !installedIds.contains($0.appId) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder private var librarySection: some View {
        if !notInstalledGames.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tu biblioteca · \(notInstalledGames.count) sin instalar")
                    .font(.title2).fontWeight(.semibold)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 12) {
                    ForEach(notInstalledGames) { game in
                        LibraryGameCard(
                            appId: game.appId,
                            name: game.name,
                            installing: installingAppIds.contains(game.appId)
                        ) {
                            Task { await installGame(game.appId) }
                        }
                    }
                }
            }
        }
    }

    /// Carga la biblioteca completa (owned) de la cuenta logueada en el bottle.
    private func loadSteamLibrary() async {
        guard let account = accountService.detectAccount(bottle: localBottle) else { return }
        let owned = await accountService.fetchOwnedGames(steamID64: account.steamID64)
        if !owned.isEmpty {
            ownedGames = owned
            log.log("Biblioteca de Steam cargada: \(owned.count) juego(s) de \(account.personaName)", level: .info)
        }
    }

    /// Pide a Steam que instale el juego (desde Vessel). El watcher en tiempo real lo
    /// moverá a "Juegos instalados" cuando termine la descarga.
    private func installGame(_ appId: String) async {
        installingAppIds.insert(appId)
        defer { installingAppIds.remove(appId) }
        do {
            try await wineManager.installSteamGame(appId: appId, in: localBottle)
        } catch {
            statusMessage = "No se pudo iniciar la instalación: \(error.localizedDescription)"
        }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(localBottle.name)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Spacer()
                Text(localBottle.architecture.uppercased())
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.purple.opacity(0.2), in: Capsule())
                    .foregroundStyle(.purple)
            }
            HStack(spacing: 16) {
                Label(localBottle.windowsVersion, systemImage: "windows")
                Label(localBottle.winePath.split(separator: "/").last.map(String.init) ?? "wine", systemImage: "wineglass")
                Label("\(localBottle.games.count) juegos", systemImage: "gamecontroller")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            Button { Task { await launchSteam() } } label: {
                Label("Lanzar Steam", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isLaunching || !FileManager.default.fileExists(atPath: localBottle.steamPath))

            Button { showingInstaller = true } label: {
                Label("Instalar Steam", systemImage: "arrow.down.app").frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.bordered)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: localBottle.prefixPath)])
            } label: {
                Label("Ver carpeta", systemImage: "folder").frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.bordered)
        }
    }

    private var gamesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Juegos instalados").font(.title2).fontWeight(.semibold)
                Spacer()
                Button { pickGame() } label: { Label("Añadir .exe", systemImage: "plus") }
            }

            if localBottle.games.isEmpty {
                Text("No hay juegos instalados. Lanza Steam para descargar tu biblioteca, o añade un ejecutable .exe manualmente.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 12) {
                    ForEach(localBottle.games) { game in
                        GameCard(game: game, prefixPath: localBottle.prefixPath) {
                            Task { await launchGame(game) }
                        } onUninstall: {
                            gameToUninstall = game
                        } onRemove: {
                            removeGameFromList(game)
                        }
                    }
                }
            }
        }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuración").font(.title2).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Game Porting Toolkit (Apple)", isOn: bindingForBottle(\.gptkEnabled))
                Toggle("DXVK (D3D → Vulkan)", isOn: bindingForBottle(\.dxvkEnabled))
                Toggle("DXMT (D3D → Metal nativo)", isOn: bindingForBottle(\.dxmtEnabled))
                Divider().padding(.vertical, 4)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DXVK").font(.callout).fontWeight(.medium)
                        Text(dxvkStatusText)
                            .font(.caption)
                            .foregroundStyle(dxvkInstalled ? .green : .orange)
                    }
                    Spacer()
                    if !dxvkInstalled {
                        Button {
                            Task { await reinstallDXVK() }
                        } label: {
                            if reinstallingDXVK {
                                HStack { ProgressView().controlSize(.small); Text("Instalando…") }
                            } else {
                                Text("Instalar ahora")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(reinstallingDXVK)
                    }
                }

                Divider().padding(.vertical, 4)
                LabeledContent("Ruta de Wine") {
                    Text(localBottle.winePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
                LabeledContent("Prefijo") {
                    Text(localBottle.prefixPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func bindingForBottle<V>(_ keyPath: WritableKeyPath<Bottle, V>) -> Binding<V> {
        Binding(
            get: { localBottle[keyPath: keyPath] },
            set: { newValue in
                localBottle[keyPath: keyPath] = newValue
                store.update(localBottle)
            }
        )
    }

    private func launchSteam() async {
        isLaunching = true
        statusMessage = nil
        defer { isLaunching = false }
        do {
            _ = try await wineManager.launchSteam(in: localBottle)
            store.touch(localBottle.id)
            await refreshDXVKStatus()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func launchGame(_ game: GameInstall) async {
        do {
            _ = try await wineManager.launch(
                executable: game.executablePath,
                in: localBottle,
                steamAppId: game.steamAppId
            )
            store.touchGame(game.id, in: localBottle.id)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func refreshDXVKStatus() async {
        dxvkInstalled = wineManager.isDXVKInstalled(in: localBottle)
    }

    private var dxvkStatusText: String {
        if dxvkInstalled {
            return "Integrado en el motor Wine-DXMT (3Shain)"
        } else {
            return "No instalado — Steam necesita DXVK para renderizar"
        }
    }

    private func reinstallDXVK() async {
        reinstallingDXVK = true
        statusMessage = nil
        defer { reinstallingDXVK = false }
        do {
            try await wineManager.reinstallDXVK(in: localBottle)
            await refreshDXVKStatus()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func pickGame() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Selecciona el ejecutable .exe del juego"
        if panel.runModal() == .OK, let url = panel.url {
            let game = GameInstall(
                name: url.deletingPathExtension().lastPathComponent,
                executablePath: url.path,
                installPath: url.deletingLastPathComponent().path
            )
            store.addGame(game, to: localBottle.id)
            localBottle.games.append(game)
        }
    }
}

struct GameCard: View {
    let game: GameInstall
    let prefixPath: String
    let onLaunch: () -> Void
    var onUninstall: () -> Void = {}
    var onRemove: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GameCoverView(game: game, prefixPath: prefixPath)
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(game.name).font(.headline).lineLimit(1)
            if let last = game.lastPlayedAt {
                Text("Última: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button(action: onLaunch) {
                    Label("Jugar", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)

                Menu {
                    Button(role: .destructive) { onUninstall() } label: {
                        Label("Desinstalar juego", systemImage: "trash")
                    }
                    Button { onRemove() } label: {
                        Label("Quitar de la lista", systemImage: "eye.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
        .contextMenu {
            Button(role: .destructive) { onUninstall() } label: {
                Label("Desinstalar juego", systemImage: "trash")
            }
            Button { onRemove() } label: {
                Label("Quitar de la lista", systemImage: "eye.slash")
            }
        }
    }
}

/// Tarjeta de un juego de la biblioteca que aún NO está instalado: portada + botón
/// "Instalar" (lo descarga Steam desde la propia vista de Vessel).
struct LibraryGameCard: View {
    let appId: String
    let name: String
    let installing: Bool
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GameCoverView(appId: appId, title: name)
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(0.9)
            Text(name).font(.headline).lineLimit(1)
            Button(action: onInstall) {
                if installing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Abriendo Steam…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("Instalar", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(installing)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
    }
}

/// Portada de juego: **portada vertical de alta resolución del CDN de Steam**
/// (`library_600x900`) y, si no existe, un **placeholder limpio** (degradado +
/// iniciales). Nunca un pixelado ni un hueco vacío. Recorte correcto (sin desbordar).
struct GameCoverView: View {
    private let appId: String
    private let title: String
    @State private var portraitFailed = false
    @State private var storeHeader: URL?
    @State private var triedStore = false

    init(game: GameInstall, prefixPath: String = "") {
        self.appId = game.steamAppId ?? ""
        self.title = game.name
    }

    init(appId: String, title: String) {
        self.appId = appId
        self.title = title
    }

    private var portraitURL: URL? {
        appId.isEmpty ? nil : URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/library_600x900_2x.jpg")
    }

    var body: some View {
        placeholder
            .overlay { cover }
            .clipped()   // recorta al marco 2:3 de la tarjeta, sin desbordar
    }

    @ViewBuilder private var cover: some View {
        if !portraitFailed, let url = portraitURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Color.clear.onAppear {
                        portraitFailed = true
                        Task { await loadStoreHeader() }
                    }
                default:
                    Color.clear
                }
            }
        } else if let header = storeHeader {
            AsyncImage(url: header) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.clear
                }
            }
        }
        // Si nada carga, queda el placeholder de fondo (nunca un hueco vacío).
    }

    /// Sin portada vertical en el CDN → pedir el `header_image` a la Steam Store
    /// API (tiene arte de casi todos los juegos, incluso sin portada de biblioteca
    /// como FF Tactics). Es arte real, mejor que un placeholder.
    @MainActor
    private func loadStoreHeader() async {
        guard !triedStore, !appId.isEmpty else { return }
        triedStore = true
        let api = "https://store.steampowered.com/api/appdetails?appids=\(appId)&filters=basic"
        guard let url = URL(string: api),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = json[appId] as? [String: Any],
              (app["success"] as? Bool) == true,
              let info = app["data"] as? [String: Any],
              let header = info["header_image"] as? String,
              let headerURL = URL(string: header) else { return }
        storeHeader = headerURL
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: GameCoverView.gradient(for: title),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(GameCoverView.initials(from: title))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        }
    }

    static func initials(from name: String) -> String {
        let words = name.split(whereSeparator: { " :-_".contains($0) }).filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    static func gradient(for name: String) -> [Color] {
        let palettes: [[Color]] = [
            [.purple, .indigo], [.blue, .cyan], [.pink, .purple],
            [.orange, .red], [.green, .teal], [.indigo, .blue]
        ]
        let hash = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palettes[abs(hash) % palettes.count]
    }
}

struct EmptyStateView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "wineglass")
                .font(.system(size: 80))
                .foregroundStyle(.purple.opacity(0.6))
            VStack(spacing: 8) {
                Text("Bienvenido a Vessel").font(.largeTitle).fontWeight(.bold)
                Text("Crea tu primer bottle para empezar a ejecutar juegos Windows en tu Mac con chip Apple Silicon.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            Button(action: onCreate) {
                Label("Crear primer bottle", systemImage: "plus").padding(.horizontal, 16)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
