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
    @State private var installPercents: [String: Double] = [:]
    @AppStorage("steamcmd.user") private var steamCMDUser = ""
    @State private var searchText = ""
    @State private var showFavoritesOnly = false
    @State private var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "steam.favorites") ?? [])
    @State private var localBottle: Bottle
    @State private var dxvkInstalled: Bool = false
    @State private var reinstallingDXVK = false

    // MARK: - Enums de ordenación y filtro

    private enum SortOrder: String, CaseIterable {
        case nombre   = "Nombre"
        case recientes = "Recientes"
    }

    private enum LibraryFilter: String, CaseIterable {
        case todos     = "Todos"
        case instalados = "Instalados"
        case porInstalar = "Por instalar"
    }

    @State private var sortOrder: SortOrder = .nombre
    @State private var libraryFilter: LibraryFilter = .todos

    private let store = BottleStore.shared
    private let log = LogStore.shared

    init(bottle: Bottle) {
        self.bottle = bottle
        self._localBottle = State(initialValue: bottle)
    }

    /// Mapeo de los juegos de Steam (instalados + biblioteca owned) al modelo genérico
    /// `StoreGame`, para usar la biblioteca común (igual que Epic/GOG/Amazon).
    private var steamGames: [StoreGame] {
        let installed = localBottle.games.map { g in
            StoreGame(id: g.steamAppId ?? g.id.uuidString, title: g.name,
                      steamAppId: g.steamAppId, installed: true, lastPlayed: g.lastPlayedAt,
                      installPath: (g.executablePath as NSString).deletingLastPathComponent)
        }
        let installedIds = Set(localBottle.games.compactMap { $0.steamAppId })
        let notInstalled = ownedGames
            .filter { !installedIds.contains($0.appId) }
            .map { StoreGame(id: $0.appId, title: $0.name, steamAppId: $0.appId, installed: false) }
        return installed + notInstalled
    }

    var body: some View {
        StoreLibraryView(
            store: .steam,
            games: steamGames,
            installingIDs: installingAppIds,
            progressFor: { installMessages[$0] },
            percentFor: { installPercents[$0] },
            onInstall: { sg in if sg.steamAppId != nil { Task { await installGame(sg.id) } } },
            onPlay: { sg in
                if let g = localBottle.games.first(where: { ($0.steamAppId ?? $0.id.uuidString) == sg.id }) {
                    Task { await launchGame(g) }
                }
            },
            onUninstall: { sg in
                gameToUninstall = localBottle.games.first(where: { ($0.steamAppId ?? $0.id.uuidString) == sg.id })
            },
            onReload: { Task { await loadSteamLibrary() } },
            onLogout: { NotificationCenter.default.post(name: .steamLogout, object: nil) }
        )
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

    // MARK: - Barra de controles (búsqueda, ordenación, filtro, favoritos)

    /// Total de juegos en el pool activo según el filtro de estado (sin búsqueda ni favoritos).
    private var poolTotal: Int {
        let installedIds = Set(localBottle.games.compactMap { $0.steamAppId })
        let notInstalledCount = ownedGames.filter { !installedIds.contains($0.appId) }.count
        switch libraryFilter {
        case .todos:       return localBottle.games.count + notInstalledCount
        case .instalados:  return localBottle.games.count
        case .porInstalar: return notInstalledCount
        }
    }

    /// Total de juegos visibles tras aplicar todos los filtros activos.
    private var poolFiltered: Int {
        switch libraryFilter {
        case .todos:       return filteredInstalled.count + notInstalledGames.count
        case .instalados:  return filteredInstalled.count
        case .porInstalar: return notInstalledGames.count
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 10) {
            // Campo de búsqueda expandible
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
            .padding(10)
            .frame(maxWidth: .infinity)
            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

            // Menú de ordenación
            Menu {
                Picker("Ordenar", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.body.weight(.medium))
                    .foregroundStyle(sortOrder == .nombre ? Color.secondary : Theme.accent)
                    .padding(9)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

            // Menú de filtro por estado
            Menu {
                Picker("Mostrar", selection: $libraryFilter) {
                    ForEach(LibraryFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: libraryFilter == .todos
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                        .font(.body.weight(.medium))
                    Text(libraryFilter.rawValue)
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(libraryFilter == .todos ? Color.secondary : Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

            // Toggle de favoritos
            Toggle(isOn: $showFavoritesOnly) {
                Label("Favoritos", systemImage: showFavoritesOnly ? "star.fill" : "star")
            }
            .toggleStyle(.button)
            .tint(.yellow)
            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

            // Contador de resultados
            if poolTotal > 0 {
                Text(poolFiltered == poolTotal
                     ? "\(poolFiltered) juego\(poolFiltered == 1 ? "" : "s")"
                     : "\(poolFiltered) de \(poolTotal)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .fixedSize()
            }
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

    /// Juegos instalados tras aplicar búsqueda, filtro de favoritos y ordenación.
    private var filteredInstalled: [GameInstall] {
        let base = localBottle.games.filter {
            matchesSearch($0.name) && (!showFavoritesOnly || isFavorite($0.steamAppId))
        }
        switch sortOrder {
        case .nombre:
            return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recientes:
            return base.sorted {
                switch ($0.lastPlayedAt, $1.lastPlayedAt) {
                case let (l?, r?): return l > r
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
        }
    }

    // MARK: - Biblioteca completa de Steam

    /// Juegos de la biblioteca del usuario que aún NO están instalados (tras filtros y ordenación).
    /// OwnedGame no tiene fecha de última sesión, así que todos los modos colapsan a orden alfabético.
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
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.accent)
                        .frame(width: 3, height: 22)
                    Text("Tu biblioteca · \(notInstalledGames.count) sin instalar")
                        .font(.title2.weight(.bold))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: Theme.Space.gameGrid)], spacing: Theme.Space.gameGrid) {
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
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .animation(.snappy(duration: 0.28), value: notInstalledGames.count)
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
                    .vesselButton()
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).count < 16 || loadingLibrary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    /// Carga la biblioteca completa (owned) de la cuenta logueada en el bottle.
    private func loadSteamLibrary() async {
        guard let account = accountService.detectAccount(bottle: localBottle) else { return }
        // Carga INSTANTÁNEA desde caché en disco; así no se ve "Cargando…" cada vez.
        if ownedGames.isEmpty,
           let cached = LibraryCache.load("steam-\(account.steamID64)", as: [SteamAccountService.OwnedGame].self) {
            ownedGames = cached
        }
        // Solo mostrar el indicador si no hay nada que enseñar todavía.
        loadingLibrary = ownedGames.isEmpty
        defer { loadingLibrary = false }
        // Refresco real en 2º plano (la UI ya muestra la caché mientras tanto).
        let owned = await accountService.fetchOwnedGames(steamID64: account.steamID64)
        if !owned.isEmpty {
            ownedGames = owned
            LibraryCache.save("steam-\(account.steamID64)", owned)
            log.log("Biblioteca de Steam cargada: \(owned.count) juego(s) de \(account.personaName)", level: .info)
        } else if ownedGames.isEmpty {
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
        defer { installingAppIds.remove(appId); installMessages[appId] = nil; installPercents[appId] = nil }
        do { try await steamCMD.ensureInstalled() } catch {
            statusMessage = "No se pudo preparar SteamCMD."
            return
        }
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "")
        let installDir = "\(localBottle.prefixPath)/drive_c/Program Files (x86)/Steam/steamapps/common/\(safeName)"
        installMessages[appId] = "Iniciando descarga…"
        let ok = await steamCMD.installGame(appId: appId, user: steamCMDUser, installDir: installDir) { pct, msg in
            installMessages[appId] = msg
            // Solo barra determinada cuando hay descarga real con %; verificación → indeterminado.
            installPercents[appId] = msg.contains("Descargando") ? max(0, min(1, pct / 100)) : nil
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
        HStack(spacing: 16) {
            StoreLogoTile(store: .steam, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text("Steam")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                let n = localBottle.games.count
                Label("\(n) juego\(n == 1 ? "" : "s") instalado\(n == 1 ? "" : "s")", systemImage: "gamecontroller.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.accent)
                        .frame(width: 3, height: 22)
                    Text("Juegos instalados")
                        .font(.title2.weight(.bold))
                }
                Spacer()
                Button { pickGame() } label: { Label("Añadir .exe", systemImage: "plus") }
                    .vesselButton(false)
            }

            if localBottle.games.isEmpty {
                VStack(alignment: .center, spacing: 16) {
                    StoreLogoTile(store: .steam, size: 72)
                    Text("No hay juegos instalados. Lanza Steam para descargar tu biblioteca, o añade un ejecutable .exe manualmente.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: Theme.Space.gameGrid)], spacing: Theme.Space.gameGrid) {
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
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .animation(.snappy(duration: 0.28), value: filteredInstalled.count)
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
        // Mismo id que usa la UI (StoreGame.id) para que el feedback (Iniciando…/Ejecutándose)
        // se refleje en la ficha y la tarjeta.
        let trackId = game.steamAppId ?? game.id.uuidString
        await GameLaunchTracker.shared.track(trackId) {
            let cfg = GameConfigStore.load(trackId)
            let profile = CompatService.shared.profile(steam: game.steamAppId, title: game.name)
            let eff = CompatService.shared.effectiveConfig(profile: profile, user: cfg)
            let proc = try await wineManager.launch(
                executable: game.executablePath, in: localBottle,
                arguments: [], steamAppId: game.steamAppId, effective: eff)
            store.touchGame(game.id, in: localBottle.id)
            return proc
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
        VStack(spacing: 8) {
            GameCoverView(game: game, prefixPath: prefixPath)
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.9)],
                                   startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(game.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                        .padding(10)
                }
                .overlay(alignment: .topTrailing) { favoriteButton }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.32), radius: 9, y: 5)

            HStack(spacing: 8) {
                Button(action: onLaunch) {
                    Label("Jugar", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .vesselButton(tint: Theme.accent)

                Menu {
                    Button(role: .destructive) { onUninstall() } label: {
                        Label("Desinstalar juego", systemImage: "trash")
                    }
                    Button { onRemove() } label: {
                        Label("Quitar de la lista", systemImage: "eye.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
        }
        .hoverLift()
        .contextMenu {
            Button(role: .destructive) { onUninstall() } label: {
                Label("Desinstalar juego", systemImage: "trash")
            }
            Button { onRemove() } label: {
                Label("Quitar de la lista", systemImage: "eye.slash")
            }
        }
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.callout)
                .foregroundStyle(isFavorite ? .yellow : .white)
                .padding(7)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(7)
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
        VStack(spacing: 8) {
            GameCoverView(appId: appId, title: name)
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .saturation(installing ? 1 : 0.85)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.9)],
                                   startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                        .padding(10)
                }
                .overlay(alignment: .topTrailing) {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.callout)
                            .foregroundStyle(isFavorite ? .yellow : .white)
                            .padding(7)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(7)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.32), radius: 9, y: 5)

            Button(action: onInstall) {
                if installing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(statusText ?? "Descargando…").lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("Instalar", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                }
            }
            .vesselButton(false, tint: Theme.accent)
            .disabled(installing)
        }
        .hoverLift()
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
        VStack(spacing: 32) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0.0)],
                            center: .center,
                            startRadius: 20,
                            endRadius: 72
                        )
                    )
                    .frame(width: 144, height: 144)
                Image(systemName: "wineglass")
                    .font(.system(size: 62, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.accent, Theme.accent.opacity(0.5)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            VStack(spacing: 10) {
                Text("Bienvenido a Vessel")
                    .font(.largeTitle.weight(.bold))
                Text("Crea tu primer bottle para empezar a ejecutar juegos Windows en tu Mac con chip Apple Silicon.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            Button(action: onCreate) {
                Label("Crear primer bottle", systemImage: "plus")
                    .padding(.horizontal, 16)
            }
            .controlSize(.large)
            .vesselButton()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesselBackground()
    }
}
