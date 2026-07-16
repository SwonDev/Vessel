import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// **Hub DRM‑free** de Vessel. Reutiliza `StoreLibraryView` (la MISMA biblioteca genérica de
/// Steam/Epic/GOG) → hereda la sidebar buscable, la rejilla con densidad y la ficha, con total
/// coherencia visual. Sus acciones propias (vincular itch.io/Humble, generar copias locales desde
/// Steam, añadir .exe/instalador) viven en `toolbarExtra`. Agrega TODO lo sin DRM del usuario:
/// itch.io, Humble Bundle, copias locales de Steam, GOG offline y cualquier ejecutable de Windows.
struct LocalGamesView: View {
    private var games = LocalGamesStore.shared
    private let store = BottleStore.shared
    @State private var wineManager = WineManager()
    private var tracker = GameLaunchTracker.shared

    @State private var showingItchLink = false
    @State private var showingHumbleLink = false
    @State private var showingSteamImport = false
    /// Progreso de descarga/instalación por juego (fracción 0…1, mensaje).
    @State private var downloading: [UUID: (Double, String)] = [:]
    @State private var syncing = false
    @State private var banner: (String, Bool)?   // (mensaje, esError)
    /// Juego pendiente de elegir formato de exportación (Mac app vs carpeta Windows).
    @State private var exportChoice: LocalGamesStore.Game?
    /// Progreso de una exportación larga (nombre, fracción, mensaje) — banner persistente.
    @State private var exportProgress: (name: String, frac: Double, msg: String)?

    /// Bottle compartido (el mismo prefijo con Wine + fixes que usa Steam).
    private var bottle: Bottle? {
        store.bottles.first(where: { $0.name == "Steam" })
            ?? store.bottles.first(where: { FileManager.default.fileExists(atPath: $0.steamPath) })
            ?? store.bottles.first
    }

    // MARK: - Mapeo a StoreGame (para reutilizar StoreLibraryView)

    private var storeGames: [StoreGame] {
        games.games.map { g in
            let folder = g.installPath
                ?? (g.installed ? (g.executablePath as NSString).deletingLastPathComponent : nil)
            return StoreGame(
                id: g.id.uuidString,
                title: g.name,
                coverURL: g.coverURL,
                steamAppId: g.source == .steam ? g.sourceId : nil,
                installed: g.installed,
                installPath: folder
            )
        }
    }

    private func game(_ sg: StoreGame) -> LocalGamesStore.Game? {
        games.games.first { $0.id.uuidString == sg.id }
    }
    private func uuid(_ id: String) -> UUID? { UUID(uuidString: id) }

    var body: some View {
        StoreLibraryView(
            store: .local,
            games: storeGames,
            installingIDs: Set(downloading.keys.map { $0.uuidString }),
            progressFor: { id in uuid(id).flatMap { downloading[$0]?.1 } },
            percentFor: { id in uuid(id).flatMap { downloading[$0]?.0 } },
            onInstall: { sg in if let g = game(sg) { download(g) } },
            onPlay: { sg in if let g = game(sg) { play(g) } },
            onUninstall: { sg in if let g = game(sg) { games.uninstall(g.id) } },
            onReload: { refresh() },
            onLogout: { },
            toolbarExtra: AnyView(drmFreeMenu),
            onExport: { sg in if let g = game(sg) { exportChoice = g } }
        )
        .overlay(alignment: .bottom) { bannerView }
        .confirmationDialog("Exportar «\(exportChoice?.name ?? "")»",
                            isPresented: Binding(get: { exportChoice != nil }, set: { if !$0 { exportChoice = nil } }),
                            titleVisibility: .visible) {
            Button("App para Mac (Apple Silicon)") { if let g = exportChoice { exportChoice = nil; exportMacApp(g) } }
            Button("Carpeta Windows (para USB/PC)") { if let g = exportChoice { exportChoice = nil; exportGame(g) } }
            Button("Cancelar", role: .cancel) { exportChoice = nil }
        } message: {
            Text("«App para Mac» empaqueta el juego + el motor (~2,2 GB) en un .app que arranca en cualquier Mac Apple Silicon sin Vessel. «Carpeta Windows» copia el juego DRM‑free para ejecutarlo en un PC.")
        }
        .sheet(isPresented: $showingItchLink) { ItchLinkSheet { user in
            flash("itch.io vinculado como \(user).", false); syncItch()
        } }
        .sheet(isPresented: $showingHumbleLink) { HumbleLinkSheet {
            flash("Humble Bundle vinculado.", false); syncHumble()
        } }
        .sheet(isPresented: $showingSteamImport) {
            if let bottle {
                SteamDRMImportSheet(bottle: bottle) { c, exe, dir in
                    games.upsertSteamCopy(appId: c.appId, name: c.name, executablePath: exe,
                                          installPath: dir, coverURL: c.coverURL)
                    flash("«\(c.name)» generado como juego DRM‑free local.", false)
                }
            }
        }
    }

    // MARK: - Acciones propias (toolbarExtra)

    private var drmFreeMenu: some View {
        Menu {
            Button { showingSteamImport = true } label: { Label("Generar copia local desde Steam…", systemImage: "arrow.down.doc") }
            Button { addGame() } label: { Label("Añadir un .exe de juego…", systemImage: "plus.app") }
            Button { runInstaller() } label: { Label("Ejecutar un instalador…", systemImage: "shippingbox") }
            Divider()
            if ItchService.shared.isLinked {
                Menu("itch.io") {
                    Button { syncItch() } label: { Label("Sincronizar biblioteca", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { ItchService.shared.setAPIKey(nil); games.removeAll(source: .itch); flash("itch.io desvinculado.", false) } label: { Label("Desvincular", systemImage: "xmark.circle") }
                }
            } else {
                Button { showingItchLink = true } label: { Label("Vincular itch.io…", systemImage: "link") }
            }
            if HumbleService.shared.isLinked {
                Menu("Humble Bundle") {
                    Button { syncHumble() } label: { Label("Sincronizar biblioteca", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { HumbleService.shared.setSession(nil); games.removeAll(source: .humble); flash("Humble desvinculado.", false) } label: { Label("Desvincular", systemImage: "xmark.circle") }
                }
            } else {
                Button { showingHumbleLink = true } label: { Label("Vincular Humble Bundle…", systemImage: "link") }
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title3).foregroundStyle(StoreKind.local.tint)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Añadir juegos DRM‑free (Steam, itch.io, Humble, .exe)")
    }

    @ViewBuilder private var bannerView: some View {
        if let ep = exportProgress {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Exportando «\(ep.name)» — \(ep.msg)").font(.callout.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                }
                ProgressView(value: ep.frac).tint(StoreKind.local.tint).frame(width: 320)
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .padding(.bottom, 26)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let banner {
            Label(banner.0, systemImage: banner.1 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.callout.weight(.medium)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder((banner.1 ? Color.orange : .green).opacity(0.5), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
                .padding(.bottom, 26)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func refresh() {
        if ItchService.shared.isLinked { syncItch() }
        if HumbleService.shared.isLinked { syncHumble() }
        if !ItchService.shared.isLinked && !HumbleService.shared.isLinked {
            flash("Biblioteca DRM‑free actualizada.", false)
        }
    }

    // MARK: - Añadir local / instalador

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

    /// Ejecuta un **instalador** en el bottle (para "generar" el juego) y, al terminar, ofrece elegir
    /// el ejecutable resultante (apunta a Program Files del bottle).
    private func runInstaller() {
        guard let bottle else { flash("Aún no hay un entorno de Wine listo.", true); return }
        let panel = NSOpenPanel()
        panel.title = "Elige el instalador de Windows (.exe / .msi)"
        panel.prompt = "Ejecutar"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "exe"), UTType(filenameExtension: "msi")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        flash("Ejecutando el instalador… cuando termine, elige el ejecutable del juego.", false)
        Task {
            do {
                let proc = try await wineManager.launch(executable: url.path, in: bottle,
                                                        arguments: [], effective: EffectiveLaunchConfig())
                while proc.isRunning { try? await Task.sleep(for: .seconds(1)) }
                await MainActor.run { promptForInstalledExe(in: bottle) }
            } catch {
                flash((error as? LocalizedError)?.errorDescription ?? "No se pudo ejecutar el instalador.", true)
            }
        }
    }

    private func promptForInstalledExe(in bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.title = "Elige el ejecutable del juego instalado"
        panel.prompt = "Añadir"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let exe = UTType(filenameExtension: "exe") { panel.allowedContentTypes = [exe] }
        for candidate in ["\(bottle.prefixPath)/drive_c/Program Files (x86)", "\(bottle.prefixPath)/drive_c/Program Files"] {
            if FileManager.default.fileExists(atPath: candidate) { panel.directoryURL = URL(fileURLWithPath: candidate); break }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if games.add(name: "", executablePath: url.path) != nil { flash("Juego añadido.", false) }
    }

    /// **Exporta** el juego: copia su carpeta autocontenida (juego + Goldberg) a un USB/disco externo
    /// elegido por el usuario. Como es DRM‑free y suyo, puede llevárselo y ejecutarlo en otro sitio.
    private func exportGame(_ g: LocalGamesStore.Game) {
        let dir = g.installPath
            ?? (g.executablePath.isEmpty ? nil : (g.executablePath as NSString).deletingLastPathComponent)
        guard let dir, FileManager.default.fileExists(atPath: dir) else {
            flash("Este juego no tiene una carpeta local que exportar.", true); return
        }
        let panel = NSOpenPanel()
        panel.title = "Elige dónde copiar «\(g.name)» (USB, disco externo…)"
        panel.prompt = "Exportar aquí"
        panel.message = "Se copiará una carpeta autocontenida y DRM‑free, lista para ejecutar en otro equipo."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destParent = panel.url else { return }
        let destName = DRMFreeInstaller.sanitize(g.name)
        let dest = destParent.appendingPathComponent(destName)
        flash("Copiando «\(g.name)» a \(destParent.lastPathComponent)…", false)
        Task {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = [dir, dest.path]
            do {
                try p.run()
                while p.isRunning { try? await Task.sleep(for: .milliseconds(500)) }
                let ok = p.terminationStatus == 0
                if ok {
                    let exeName = (g.executablePath as NSString).lastPathComponent
                    let readme = """
                    \(g.name) — juego DRM‑free para Windows
                    Creado con Vessel · https://github.com/SwonDev/Vessel

                    Este juego es TUYO y no lleva DRM: se ejecuta en cualquier PC con Windows SIN Steam.

                    CÓMO JUGAR
                    1. Copia esta carpeta a tu PC con Windows.
                    2. Ejecuta «\(exeName)».

                    Si el juego pide algún componente (Visual C++, .NET…), instálalo desde Microsoft.
                    No necesitas Steam ni ninguna cuenta.
                    """
                    try? readme.write(to: dest.appendingPathComponent("LÉEME.txt"), atomically: true, encoding: .utf8)
                }
                flash(ok ? "«\(g.name)» exportado a \(destParent.lastPathComponent) — listo para llevártelo."
                         : "La copia falló (código \(p.terminationStatus)).", !ok)
            } catch {
                flash("No se pudo exportar: \(error.localizedDescription)", true)
            }
        }
    }

    /// **Exporta como app de macOS autónoma** (Apple Silicon): empaqueta el juego + el motor en un
    /// `.app` que arranca en cualquier Mac Silicon SIN Vessel. Copiable a un USB.
    private func exportMacApp(_ g: LocalGamesStore.Game) {
        let folder = g.installPath
            ?? (g.executablePath.isEmpty ? nil : (g.executablePath as NSString).deletingLastPathComponent)
        guard let folder, FileManager.default.fileExists(atPath: folder), !g.executablePath.isEmpty else {
            flash("Este juego no tiene una carpeta local que empaquetar.", true); return
        }
        let panel = NSOpenPanel()
        panel.title = "Elige dónde crear la app de «\(g.name)» (USB, disco…)"
        panel.prompt = "Exportar app aquí"
        panel.message = "Se creará una app de macOS autónoma (~2,2 GB) que arranca en cualquier Mac Apple Silicon sin Vessel."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destParent = panel.url else { return }
        exportProgress = (g.name, 0, "Preparando…")
        Task {
            do {
                let appURL = try await StandaloneMacExporter.shared.exportMacApp(
                    name: g.name, gameFolder: folder, exePath: g.executablePath,
                    coverURL: g.coverURL, destParent: destParent
                ) { frac, msg in Task { @MainActor in exportProgress = (g.name, frac, msg) } }
                exportProgress = nil
                flash("App de «\(g.name)» creada en \(destParent.lastPathComponent) — arranca en cualquier Mac Silicon.", false)
                NSWorkspace.shared.activateFileViewerSelecting([appURL])
            } catch {
                exportProgress = nil
                flash((error as? LocalizedError)?.errorDescription ?? "No se pudo exportar la app.", true)
            }
        }
    }

    private func flash(_ msg: String, _ isError: Bool) {
        withAnimation(.smooth) { banner = (msg, isError) }
        Task { try? await Task.sleep(for: .seconds(5)); await MainActor.run { withAnimation { if banner?.0 == msg { banner = nil } } } }
    }

    // MARK: - Sincronizar bibliotecas vinculadas

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

    // MARK: - Descargar / instalar (itch/Humble)

    private func download(_ g: LocalGamesStore.Game) {
        guard let sid = g.sourceId else { return }
        downloading[g.id] = (0, "Resolviendo descarga…")
        Task {
            do {
                let url: URL
                var headers: [String: String] = [:]
                var filenameHint: String? = nil
                switch g.source {
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
                let name = g.name
                let installed = try await DRMFreeInstaller.shared.downloadAndInstall(
                    url: url, headers: headers, slug: name, suggestedName: name, filenameHint: filenameHint
                ) { frac, msg in Task { @MainActor in downloading[g.id] = (frac, msg) } }
                games.setInstalled(g.id, executablePath: installed.executablePath, installPath: installed.installDir)
                downloading[g.id] = nil
                flash("«\(name)» instalado.", false)
            } catch {
                downloading[g.id] = nil
                flash((error as? LocalizedError)?.errorDescription ?? "Error al descargar «\(g.name)».", true)
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
