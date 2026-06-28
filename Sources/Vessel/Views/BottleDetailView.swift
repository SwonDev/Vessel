import SwiftUI

struct BottleDetailView: View {
    let bottle: Bottle
    @State private var isLaunching = false
    @State private var statusMessage: String?
    @State private var showingInstaller = false
    @State private var wineManager = WineManager()
    @State private var localBottle: Bottle

    private let store = BottleStore.shared

    init(bottle: Bottle) {
        self.bottle = bottle
        self._localBottle = State(initialValue: bottle)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
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
            }
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
                        GameCard(game: game) {
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
        defer { isLaunching = false }
        do {
            _ = try await wineManager.launch(executable: localBottle.steamPath, in: localBottle)
            store.touch(localBottle.id)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func launchGame(_ game: GameInstall) async {
        do {
            _ = try await wineManager.launch(executable: game.executablePath, in: localBottle)
            store.touchGame(game.id, in: localBottle.id)
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
    let onLaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.purple.opacity(0.15))
                    .aspectRatio(1, contentMode: .fit)
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.purple)
            }
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
