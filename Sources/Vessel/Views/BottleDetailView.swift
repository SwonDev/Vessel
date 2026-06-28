import SwiftUI

struct BottleDetailView: View {
    let bottle: Bottle
    @State private var isLaunching = false
    @State private var statusMessage: String?
    @State private var showingInstaller = false
    @State private var wineManager = WineManager()
    @State private var importer = SteamLibraryImporter()
    @State private var gamesWatcher = DirectoryWatcher()
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
                configurationSection
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
            Button(action: onLaunch) {
                Label("Jugar", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
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
