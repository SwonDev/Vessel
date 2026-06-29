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
    @State private var apiKeyInput = ""
    @State private var loadingLibrary = false
    @State private var steamCMD = SteamCMDManager()
    @State private var showSteamCMDLogin = false
    @State private var showOfficialLogin = false
    @State private var pendingInstallAppId: String?
    @State private var installMessages: [String: String] = [:]
    @AppStorage("steamcmd.user") private var steamCMDUser = ""
    @State private var searchText = ""
    @State private var showFavoritesOnly = false
    @State private var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "steam.favorites") ?? [])
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
                apiKeyPrompt
                if !localBottle.games.isEmpty || !ownedGames.isEmpty {
                    searchBar
                }
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
        .sheet(isPresented: $showSteamCMDLogin) {
            SteamCMDLoginView(suggestedUser: accountService.detectAccount(bottle: localBottle)?.accountName ?? "") { user in
                steamCMDUser = user
                if let appId = pendingInstallAppId {
                    pendingInstallAppId = nil
                    Task { await installGame(appId) }
                }
            }
        }
        .sheet(isPresented: $showOfficialLogin) {
            SteamOfficialLoginView { tokens in
                if !tokens.accountName.isEmpty { steamCMDUser = tokens.accountName }
                Task { await loadSteamLibrary() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .steamLogin)) { _ in
            showOfficialLogin = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .steamRefresh)) { _ in
            Task { await loadSteamLibrary() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .steamLogout)) { _ in
            steamCMDUser = ""
            SteamAccountService.webAPIKey = ""
            ownedGames = []
            statusMessage = "Sesión cerrada. Usa clic derecho en Steam para volver a iniciar sesión."
        }
    }

    /// Quita el juego de la lista de Vessel (no borra archivos).
    private func removeGameFromList(_ game: GameInstall) {
        store.deleteGame(game.id, from: localBottle.id)
        if let updated = store.bottles.first(where: { $0.id == localBottle.id }) {
            localBottle = updated
        }
    }

    /// Desinstala el juego borrando SOLO su carpeta dentro de `steamapps/common`.
    /// BLINDADO: la carpeta se deriva del `installdir` del appmanifest o del
    /// `executablePath`, y se exige que sea una subcarpeta ESTRICTA de
    /// `steamapps/common` (nunca el prefijo, ni `common`, ni rutas fuera de ahí).
    /// `installPath` NO se usa: puede apuntar al prefijo entero.
    private func uninstallGame(_ game: GameInstall) {
        let fm = FileManager.default
        let steamCommon = "\(localBottle.prefixPath)/drive_c/Program Files (x86)/Steam/steamapps/common"
        var folderToDelete: String?

        if let appId = game.steamAppId, !appId.isEmpty {
            let manifest = "\(localBottle.prefixPath)/drive_c/Program Files (x86)/Steam/steamapps/appmanifest_\(appId).acf"
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

        // SEGURIDAD CRÍTICA: canonicalizar (resolver symlinks y `..`) y exigir que la
        // ruta resultante siga siendo subcarpeta ESTRICTA de steamapps/common.
        if let folder = folderToDelete {
            let resolved = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
            let base = URL(fileURLWithPath: steamCommon).resolvingSymlinksInPath().standardizedFileURL.path
            if resolved.hasPrefix(base + "/"),
               resolved != base,
               (resolved as NSString).lastPathComponent.count > 0,
               fm.fileExists(atPath: resolved) {
                try? fm.removeItem(atPath: resolved)
                log.log("Juego desinstalado: \(game.name) (\(resolved))", level: .info)
            } else {
                log.log("Desinstalar \(game.name): ruta no segura tras canonicalizar; solo se quita de la lista.", level: .warn)
            }
        } else {
            log.log("Desinstalar \(game.name): no se halló carpeta segura; solo se quita de la lista.", level: .warn)
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

    // MARK: - Búsqueda, filtros y favoritos

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar en tu biblioteca…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Toggle(isOn: $showFavoritesOnly) {
                Label("Favoritos", systemImage: showFavoritesOnly ? "star.fill" : "star")
            }
            .toggleStyle(.button)
            .tint(.yellow)
        }
    }

    private func isFavorite(_ appId: String?) -> Bool {
        guard let appId else { return false }
        return favorites.contains(appId)
    }

    private func toggleFavorite(_ appId: String?) {
        guard let appId else { return }
        if favorites.contains(appId) { favorites.remove(appId) } else { favorites.insert(appId) }
        UserDefaults.standard.set(Array(favorites), forKey: "steam.favorites")
    }

    private func matchesSearch(_ name: String) -> Bool {
        searchText.isEmpty || name.localizedCaseInsensitiveContains(searchText)
    }

    /// Juegos instalados tras aplicar búsqueda y filtro de favoritos.
    private var filteredInstalled: [GameInstall] {
        localBottle.games.filter {
            matchesSearch($0.name) && (!showFavoritesOnly || isFavorite($0.steamAppId))
        }
    }

    // MARK: - Biblioteca completa de Steam

    /// Juegos de la biblioteca del usuario que aún NO están instalados (tras filtros).
    private var notInstalledGames: [SteamAccountService.OwnedGame] {
        let installedIds = Set(localBottle.games.compactMap { $0.steamAppId })
        return ownedGames
            .filter { !installedIds.contains($0.appId) }
            .filter { matchesSearch($0.name) && (!showFavoritesOnly || isFavorite($0.appId)) }
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
                            installing: installingAppIds.contains(game.appId),
                            statusText: installMessages[game.appId],
                            isFavorite: isFavorite(game.appId),
                            onToggleFavorite: { toggleFavorite(game.appId) }
                        ) {
                            Task { await installGame(game.appId) }
                        }
                    }
                }
            }
        }
    }

    /// Panel para pegar la clave Web API de Steam y cargar la biblioteca cuando el
    /// perfil es privado y aún no hay juegos (ni instalados ni en biblioteca).
    @ViewBuilder private var apiKeyPrompt: some View {
        if localBottle.games.isEmpty && ownedGames.isEmpty && SteamAccountService.webAPIKey.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Carga tu biblioteca").font(.title2).fontWeight(.semibold)
                Text("Tu perfil de Steam es privado, así que necesito tu clave Web API (gratis, se genera en 10 segundos y no comparte nada). Con ella, Vessel carga toda tu biblioteca para instalar y jugar desde aquí.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link(destination: URL(string: "https://steamcommunity.com/dev/apikey")!) {
                    Label("Obtener mi clave de Steam", systemImage: "key.fill")
                }
                HStack {
                    TextField("Pega aquí tu clave (32 caracteres)", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        SteamAccountService.webAPIKey = apiKeyInput
                        Task { await loadSteamLibrary() }
                    } label: {
                        if loadingLibrary {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Cargando…") }
                        } else {
                            Text("Cargar biblioteca")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).count < 16 || loadingLibrary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Carga la biblioteca completa (owned) de la cuenta logueada en el bottle.
    private func loadSteamLibrary() async {
        guard let account = accountService.detectAccount(bottle: localBottle) else { return }
        loadingLibrary = true
        defer { loadingLibrary = false }
        let owned = await accountService.fetchOwnedGames(steamID64: account.steamID64)
        if !owned.isEmpty {
            ownedGames = owned
            log.log("Biblioteca de Steam cargada: \(owned.count) juego(s) de \(account.personaName)", level: .info)
        } else {
            log.log("Biblioteca de \(account.personaName) vacía (perfil privado o sin clave API)", level: .warn)
        }
    }

    /// Pide a Steam que instale el juego (desde Vessel). El watcher en tiempo real lo
    /// moverá a "Juegos instalados" cuando termine la descarga.
    private func installGame(_ appId: String) async {
        let name = ownedGames.first(where: { $0.appId == appId })?.name ?? "App \(appId)"
        // Requiere sesión de SteamCMD. Si no la hay, pedir login primero.
        guard !steamCMDUser.isEmpty else {
            pendingInstallAppId = appId
            showSteamCMDLogin = true
            return
        }
        installingAppIds.insert(appId)
        defer { installingAppIds.remove(appId); installMessages[appId] = nil }
        do { try await steamCMD.ensureInstalled() } catch {
            statusMessage = "No se pudo preparar SteamCMD."
            return
        }
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "")
        let installDir = "\(localBottle.prefixPath)/drive_c/Program Files (x86)/Steam/steamapps/common/\(safeName)"
        installMessages[appId] = "Iniciando descarga…"
        let ok = await steamCMD.installGame(appId: appId, user: steamCMDUser, installDir: installDir) { _, msg in
            installMessages[appId] = msg
        }
        if ok, let exe = mainExecutable(in: installDir) {
            let game = GameInstall(
                name: name, executablePath: exe, steamAppId: appId, installPath: installDir,
                coverImageURL: "https://cdn.akamai.steamstatic.com/steam/apps/\(appId)/library_600x900_2x.jpg"
            )
            store.addGame(game, to: localBottle.id)
            if let updated = store.bottles.first(where: { $0.id == localBottle.id }) { localBottle = updated }
            ownedGames.removeAll { $0.appId == appId }
        } else if !ok {
            statusMessage = "La instalación de \(name) no se completó. Revisa los logs."
        }
    }

    /// Localiza el ejecutable principal del juego descargado (ignora redistribuibles).
    private func mainExecutable(in dir: String) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dir) else { return nil }
        var candidates: [String] = []
        for case let path as String in enumerator where path.lowercased().hasSuffix(".exe") {
            let lower = path.lowercased()
            if lower.contains("redist") || lower.contains("vcredist") || lower.contains("crashpad")
                || lower.contains("unitycrash") || lower.contains("dxsetup") || lower.contains("dotnet") {
                continue
            }
            candidates.append("\(dir)/\(path)")
        }
        if let launcher = candidates.first(where: { $0.lowercased().contains("launcher") || $0.lowercased().contains((dir as NSString).lastPathComponent.lowercased()) }) {
            return launcher
        }
        return candidates.min(by: { $0.count < $1.count })
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Steam")
                .font(.largeTitle)
                .fontWeight(.bold)
            let n = localBottle.games.count
            Label("\(n) juego\(n == 1 ? "" : "s") instalado\(n == 1 ? "" : "s")", systemImage: "gamecontroller")
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
                    ForEach(filteredInstalled) { game in
                        GameCard(
                            game: game,
                            prefixPath: localBottle.prefixPath,
                            isFavorite: isFavorite(game.steamAppId),
                            onToggleFavorite: { toggleFavorite(game.steamAppId) }
                        ) {
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
    var isFavorite: Bool = false
    var onToggleFavorite: () -> Void = {}
    let onLaunch: () -> Void
    var onUninstall: () -> Void = {}
    var onRemove: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GameCoverView(game: game, prefixPath: prefixPath)
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.callout)
                            .foregroundStyle(isFavorite ? .yellow : .white)
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
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
    var statusText: String? = nil
    var isFavorite: Bool = false
    var onToggleFavorite: () -> Void = {}
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GameCoverView(appId: appId, title: name)
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(0.9)
                .overlay(alignment: .topTrailing) {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.callout)
                            .foregroundStyle(isFavorite ? .yellow : .white)
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            Text(name).font(.headline).lineLimit(1)
            Button(action: onInstall) {
                if installing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(statusText ?? "Descargando…").lineLimit(1)
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
