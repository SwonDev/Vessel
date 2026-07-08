import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Biblioteca **DRM‑free**: juegos sueltos (itch.io, GOG offline, instaladores standalone, cualquier
/// `.exe` de Windows) que el usuario añade a mano. NO es una tienda — es tu librería, sin DRM. Vessel
/// los ejecuta con el **motor gráfico óptimo + auto‑reparación + copia de partidas**, igual que los de
/// tienda, reutilizando el mismo bottle (prefijo con Wine + fixes).
struct LocalGamesView: View {
    private var games = LocalGamesStore.shared
    private let store = BottleStore.shared
    @State private var wineManager = WineManager()
    private var tracker = GameLaunchTracker.shared

    /// Bottle compartido (el mismo prefijo con Wine + fixes que usa Steam).
    private var bottle: Bottle? {
        store.bottles.first(where: { $0.name == "Steam" })
            ?? store.bottles.first(where: { FileManager.default.fileExists(atPath: $0.steamPath) })
            ?? store.bottles.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if games.games.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 18)], spacing: 22) {
                        ForEach(games.games) { game in
                            LocalGameCard(
                                game: game,
                                busy: tracker.isBusy(game.id.uuidString),
                                running: tracker.state(game.id.uuidString) == .running,
                                onPlay: { play(game) },
                                onStop: { tracker.stop(game.id.uuidString) },
                                onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.executablePath)]) },
                                onRemove: { games.remove(game.id) }
                            )
                        }
                    }
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesselBackground(tint: StoreKind.local.tint)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            StoreLogoTile(store: .local, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("DRM‑free").font(.largeTitle.bold()).foregroundStyle(.white)
                Text("Tus juegos sin DRM: itch.io, GOG offline, instaladores o cualquier .exe de Windows.")
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button { addGame() } label: {
                Label("Añadir juego", systemImage: "plus")
            }
            .vesselButton(tint: StoreKind.local.tint)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.open.fill").font(.system(size: 48)).foregroundStyle(StoreKind.local.tint)
            Text("Aún no has añadido juegos DRM‑free").font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text("Elige el .exe de un juego de itch.io, un GOG offline, un instalador standalone o cualquier juego de Windows. Vessel lo ejecuta con el motor óptimo, auto‑reparación y copia de partidas.")
                .font(.callout).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center).frame(maxWidth: 470)
            Button { addGame() } label: { Label("Añadir juego", systemImage: "plus").frame(maxWidth: 260) }
                .vesselButton(tint: StoreKind.local.tint)
        }
        .frame(maxWidth: .infinity).padding(.top, 70)
    }

    /// Selector de `.exe` (NSOpenPanel). El instalador se ejecuta igual (es un .exe); tras instalar,
    /// el usuario añade el .exe del juego resultante.
    private func addGame() {
        let panel = NSOpenPanel()
        panel.title = "Elige el ejecutable de Windows (.exe)"
        panel.prompt = "Añadir"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let exe = UTType(filenameExtension: "exe") { panel.allowedContentTypes = [exe] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        games.add(name: "", executablePath: url.path)
    }

    private func play(_ game: LocalGamesStore.Game, forcedLayer: GameConfig.GraphicsLayer? = nil, attempt: Int = 0) {
        guard let bottle else { return }
        let exe = game.executablePath
        let id = game.id.uuidString
        let installDir = (exe as NSString).deletingLastPathComponent
        Task {
            let profile = CompatService.shared.profile(steam: nil, title: game.name)
            var eff = CompatService.shared.effectiveConfig(profile: profile, user: GameConfigStore.load(id))
            if let forcedLayer { eff.graphicsOverride = forcedLayer }
            let usedLayer = wineManager.resolvedGraphicsLayer(forExecutable: exe, effective: eff)
            await tracker.track(
                id, statsKey: "local:\(id)",
                onExit: { Task { await SaveBackupManager.shared.backup(store: .local, id: id, title: game.name, steamId: nil, prefix: bottle.prefixPath, installPath: installDir) } }
            ) {
                await SaveBackupManager.shared.restoreIfNewer(store: .local, id: id, title: game.name, steamId: nil, prefix: bottle.prefixPath, installPath: installDir)
                let proc = try await wineManager.launch(executable: exe, in: bottle, arguments: [], effective: eff)
                games.markPlayed(game.id)
                return proc
            }
            LaunchDiagnostics.monitorAndMaybeRetry(
                prefix: bottle.prefixPath, gameId: id, gameTitle: game.name,
                currentLayer: usedLayer, attempt: attempt,
                fallbackLayers: wineManager.fallbackLayers(forExecutable: exe, effective: eff),
                isRunning: { tracker.state(id) == .running },
                persistWinningLayer: { winLayer in
                    var c = GameConfigStore.load(id); c.graphicsLayer = winLayer; GameConfigStore.save(id, c)
                    DiscoveredFixesStore.shared.record(id: id, title: game.name, store: "local", storeId: nil,
                                                       graphicsLayer: winLayer.rawValue, useRealSteam: false)
                },
                retryWithRuntimeFix: {
                    await wineManager.installMissingRuntimes(in: bottle, forExecutable: exe)
                    play(game, attempt: attempt + 1)
                }
            ) { next in play(game, forcedLayer: next, attempt: attempt + 1) }
        }
    }
}

/// Tarjeta premium de un juego DRM‑free: portada-placeholder con gradiente + nombre, botón Jugar/
/// Detener y menú contextual (revelar en Finder / quitar de la lista, sin borrar el juego del disco).
private struct LocalGameCard: View {
    let game: LocalGamesStore.Game
    let busy: Bool
    let running: Bool
    let onPlay: () -> Void
    let onStop: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [StoreKind.local.tint.opacity(0.55), .black.opacity(0.6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 34, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                if hovering || busy {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.35))
                    if busy && !running {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Button(action: running ? onStop : onPlay) {
                            Label(running ? "Detener" : "Jugar", systemImage: running ? "stop.fill" : "play.fill")
                                .font(.headline).padding(.horizontal, 14).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain).foregroundStyle(.white)
                        .background(StoreKind.local.tint.gradient, in: Capsule())
                    }
                }
            }
            .frame(height: 210)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: hovering ? 12 : 6, y: hovering ? 6 : 3)
            .scaleEffect(hovering ? 1.02 : 1)
            Text(game.name).font(.callout.weight(.medium)).foregroundStyle(.white).lineLimit(1)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(running ? "Detener" : "Jugar", systemImage: running ? "stop.fill" : "play.fill") { running ? onStop() : onPlay() }
            Button("Revelar en Finder", systemImage: "folder") { onReveal() }
            Divider()
            Button("Quitar de la lista", systemImage: "trash", role: .destructive) { onRemove() }
        }
    }
}
