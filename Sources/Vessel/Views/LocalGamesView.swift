import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// **Hub DRM‑free** de Vessel: agrega TODO lo sin DRM y del usuario — biblioteca de **itch.io**,
/// de **Humble Bundle**, GOG offline y cualquier `.exe`/instalador suelto. Vincula cuentas,
/// sincroniza bibliotecas, descarga/instala, y ejecuta cada juego con el motor gráfico óptimo +
/// auto‑reparación + backup de partidas, reutilizando el bottle de Steam (prefijo con Wine + fixes).
struct LocalGamesView: View {
    private var games = LocalGamesStore.shared
    private let store = BottleStore.shared
    @State private var wineManager = WineManager()
    private var tracker = GameLaunchTracker.shared

    @State private var filter: SourceFilter = .all
    @State private var showingItchLink = false
    @State private var showingHumbleLink = false
    /// Progreso de descarga/instalación por juego: (fracción 0…1, mensaje).
    @State private var downloading: [UUID: (Double, String)] = [:]
    @State private var syncing = false
    @State private var banner: (String, Bool)?   // (mensaje, esError)

    enum SourceFilter: Hashable { case all, itch, humble, local
        var title: String {
            switch self { case .all: return "Todos"; case .itch: return "itch.io"
            case .humble: return "Humble"; case .local: return "Local" }
        }
    }

    private var bottle: Bottle? {
        store.bottles.first(where: { $0.name == "Steam" })
            ?? store.bottles.first(where: { FileManager.default.fileExists(atPath: $0.steamPath) })
            ?? store.bottles.first
    }

    private var visibleGames: [LocalGamesStore.Game] {
        let all = games.games
        switch filter {
        case .all: return all
        case .itch: return all.filter { $0.source == .itch }
        case .humble: return all.filter { $0.source == .humble }
        case .local: return all.filter { $0.source == .local || $0.source == .gogOffline }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                accountsBar
                if let banner {
                    Label(banner.0, systemImage: banner.1 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(banner.1 ? .orange : .green)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
                filterPills
                if visibleGames.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 18)], spacing: 22) {
                        ForEach(visibleGames) { game in
                            DRMFreeCard(
                                game: game,
                                progress: downloading[game.id],
                                busy: tracker.isBusy(game.id.uuidString),
                                running: tracker.state(game.id.uuidString) == .running,
                                onPlay: { play(game) },
                                onStop: { tracker.stop(game.id.uuidString) },
                                onDownload: { download(game) },
                                onReveal: { reveal(game) },
                                onRemove: { games.remove(game.id) },
                                onDelete: { games.removeAndDelete(game.id) }
                            )
                        }
                    }
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesselBackground(tint: StoreKind.local.tint)
        .sheet(isPresented: $showingItchLink) { ItchLinkSheet { user in
            flash("itch.io vinculado como \(user).", false); syncItch()
        } }
        .sheet(isPresented: $showingHumbleLink) { HumbleLinkSheet {
            flash("Humble Bundle vinculado.", false); syncHumble()
        } }
    }

    // MARK: - Secciones

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            StoreLogoTile(store: .local, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("DRM‑free").font(.largeTitle.bold()).foregroundStyle(.white)
                Text("Tu biblioteca sin DRM: itch.io, Humble Bundle, GOG offline o cualquier .exe de Windows.")
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Menu {
                Button { addGame() } label: { Label("Añadir .exe o instalador…", systemImage: "plus.app") }
                Divider()
                if !ItchService.shared.isLinked {
                    Button { showingItchLink = true } label: { Label("Vincular itch.io…", systemImage: "link") }
                }
                if !HumbleService.shared.isLinked {
                    Button { showingHumbleLink = true } label: { Label("Vincular Humble Bundle…", systemImage: "link") }
                }
            } label: {
                Label("Añadir", systemImage: "plus")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .vesselButton(tint: StoreKind.local.tint)
        }
    }

    /// Barra de estado de cuentas vinculadas (sincronizar / desvincular).
    @ViewBuilder private var accountsBar: some View {
        let itch = ItchService.shared.isLinked
        let humble = HumbleService.shared.isLinked
        if itch || humble {
            HStack(spacing: 10) {
                if itch {
                    accountChip(name: "itch.io", icon: "gamecontroller.fill",
                                count: games.games.filter { $0.source == .itch }.count,
                                onSync: { syncItch() },
                                onUnlink: { ItchService.shared.setAPIKey(nil); games.removeAll(source: .itch); flash("itch.io desvinculado.", false) })
                }
                if humble {
                    accountChip(name: "Humble", icon: "bag.fill",
                                count: games.games.filter { $0.source == .humble }.count,
                                onSync: { syncHumble() },
                                onUnlink: { HumbleService.shared.setSession(nil); games.removeAll(source: .humble); flash("Humble desvinculado.", false) })
                }
                if syncing { ProgressView().controlSize(.small).tint(.white) }
                Spacer()
            }
        }
    }

    private func accountChip(name: String, icon: String, count: Int,
                             onSync: @escaping () -> Void, onUnlink: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(StoreKind.local.tint)
            Text("\(name) · \(count)").font(.callout.weight(.medium)).foregroundStyle(.white)
            Button { onSync() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7)).help("Sincronizar biblioteca")
            Menu { Button("Desvincular", role: .destructive) { onUnlink() } } label: {
                Image(systemName: "ellipsis")
            }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }

    private var filterPills: some View {
        HStack(spacing: 8) {
            ForEach([SourceFilter.all, .itch, .humble, .local], id: \.self) { f in
                let n = count(for: f)
                Button { withAnimation(.snappy) { filter = f } } label: {
                    Text(n > 0 ? "\(f.title) (\(n))" : f.title)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .foregroundStyle(filter == f ? .white : .white.opacity(0.6))
                .background(filter == f ? StoreKind.local.tint.opacity(0.85) : Color.white.opacity(0.06),
                            in: Capsule())
            }
        }
    }

    private func count(for f: SourceFilter) -> Int {
        switch f {
        case .all: return games.games.count
        case .itch: return games.games.filter { $0.source == .itch }.count
        case .humble: return games.games.filter { $0.source == .humble }.count
        case .local: return games.games.filter { $0.source == .local || $0.source == .gogOffline }.count
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.open.fill").font(.system(size: 48)).foregroundStyle(StoreKind.local.tint)
            Text("Tu biblioteca DRM‑free está vacía").font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text("Vincula tu cuenta de itch.io o Humble Bundle para traer tus juegos, o añade un .exe / instalador de Windows a mano. Vessel los descarga, instala y ejecuta con el motor óptimo.")
                .font(.callout).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center).frame(maxWidth: 480)
            HStack(spacing: 10) {
                Button { showingItchLink = true } label: { Label("Vincular itch.io", systemImage: "link") }
                    .vesselButton(tint: StoreKind.local.tint)
                Button { showingHumbleLink = true } label: { Label("Vincular Humble", systemImage: "link") }
                    .vesselButton(tint: StoreKind.local.tint)
                Button { addGame() } label: { Label("Añadir .exe", systemImage: "plus") }
                    .vesselButton(tint: StoreKind.local.tint)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: - Añadir local / revelar

    private func addGame() {
        let panel = NSOpenPanel()
        panel.title = "Elige el ejecutable de Windows (.exe) o un instalador"
        panel.prompt = "Añadir"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let exe = UTType(filenameExtension: "exe") { panel.allowedContentTypes = [exe] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        games.add(name: "", executablePath: url.path)
    }

    private func reveal(_ game: LocalGamesStore.Game) {
        let path = game.installed ? game.executablePath : (game.installPath ?? game.executablePath)
        guard !path.isEmpty else {
            if let s = game.pageURL, let u = URL(string: s) { NSWorkspace.shared.open(u) }; return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func flash(_ msg: String, _ isError: Bool) {
        withAnimation { banner = (msg, isError) }
        Task { try? await Task.sleep(for: .seconds(5)); await MainActor.run { withAnimation { if banner?.0 == msg { banner = nil } } } }
    }

    // MARK: - Sincronizar bibliotecas

    private func syncItch() {
        syncing = true
        Task {
            do {
                let keys = try await ItchService.shared.fetchOwnedGames()
                for k in keys {
                    guard let g = k.game, let gid = g.id, let dkid = k.id else { continue }
                    games.upsertLibraryEntry(source: .itch, sourceId: "\(gid):\(dkid)",
                                             name: g.title ?? "Juego", coverURL: g.cover_url, pageURL: g.url)
                }
                flash("itch.io: \(keys.count) juego(s) sincronizados.", false)
            } catch { flash((error as? LocalizedError)?.errorDescription ?? "Error al sincronizar itch.io.", true) }
            syncing = false
        }
    }

    private func syncHumble() {
        syncing = true
        Task {
            do {
                let items = try await HumbleService.shared.fetchLibrary()
                for it in items {
                    games.upsertLibraryEntry(source: .humble, sourceId: it.sourceId,
                                             name: it.name, coverURL: it.iconURL)
                }
                flash("Humble: \(items.count) juego(s) DRM‑free sincronizados.", false)
            } catch { flash((error as? LocalizedError)?.errorDescription ?? "Error al sincronizar Humble.", true) }
            syncing = false
        }
    }

    // MARK: - Descargar / instalar

    private func download(_ game: LocalGamesStore.Game) {
        guard let sid = game.sourceId else { return }
        downloading[game.id] = (0, "Resolviendo descarga…")
        Task {
            do {
                let url: URL
                var headers: [String: String] = [:]
                var filenameHint: String? = nil
                switch game.source {
                case .itch:
                    let parts = sid.split(separator: ":").map(String.init)
                    guard parts.count == 2, let gid = Int(parts[0]), let dkid = Int(parts[1]) else {
                        throw NSError(domain: "Vessel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Id de itch.io inválido."])
                    }
                    let r = try await ItchService.shared.windowsDownload(gameId: gid, downloadKeyId: dkid)
                    url = r.url; filenameHint = r.filename
                case .humble:
                    guard let colon = sid.firstIndex(of: ":") else {
                        throw NSError(domain: "Vessel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Id de Humble inválido."])
                    }
                    let gamekey = String(sid[..<colon]); let machine = String(sid[sid.index(after: colon)...])
                    url = try await HumbleService.shared.windowsDownloadURL(gamekey: gamekey, machineName: machine)
                    if let sess = HumbleService.shared.sessionCookie { headers["Cookie"] = "_simpleauth_sess=\(sess)" }
                default:
                    throw NSError(domain: "Vessel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fuente sin descarga automática."])
                }
                let name = game.name
                let installed = try await DRMFreeInstaller.shared.downloadAndInstall(
                    url: url, headers: headers, slug: name, suggestedName: name, filenameHint: filenameHint
                ) { frac, msg in
                    Task { @MainActor in downloading[game.id] = (frac, msg) }
                }
                games.setInstalled(game.id, executablePath: installed.executablePath, installPath: installed.installDir)
                downloading[game.id] = nil
                flash("«\(name)» instalado.", false)
            } catch {
                downloading[game.id] = nil
                flash((error as? LocalizedError)?.errorDescription ?? "Error al descargar «\(game.name)».", true)
            }
        }
    }

    // MARK: - Jugar (mismo flujo que las tiendas)

    private func play(_ game: LocalGamesStore.Game, forcedLayer: GameConfig.GraphicsLayer? = nil, attempt: Int = 0) {
        guard let bottle, game.installed else { return }
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
