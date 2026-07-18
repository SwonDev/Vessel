import SwiftUI
import WebKit

// MARK: - Vincular itch.io (pegar API key)

/// Hoja para vincular itch.io: el usuario pega su **API key** (la genera en la web). Se valida
/// contra `/profile` antes de guardarla.
struct ItchLinkSheet: View {
    let onLinked: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var validating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill").font(.title2).foregroundStyle(StoreKind.local.tint)
                Text("Vincular itch.io").font(.title2.bold())
            }
            Text("Pega tu **API key** de itch.io. La generas en itch.io › Ajustes › API keys. Con ella Vessel puede listar y descargar tus juegos.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("Abrir la página de API keys",
                 destination: URL(string: "https://itch.io/user/settings/api-keys")!)
                .font(.callout.weight(.medium))

            SecureField("API key", text: $key)
                .textFieldStyle(.plain)
                .padding(10)
                .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .onSubmit(validate)
            if let error { Text(error).font(.caption).foregroundStyle(Theme.destructive) }

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .vesselButton(false, tint: StoreKind.local.tint)
                Button(validating ? "Validando…" : "Vincular") { validate() }
                    .vesselButton(tint: StoreKind.local.tint)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || validating)
            }
        }
        .padding(24).frame(width: 460)
        .vesselBackground(tint: StoreKind.local.tint)
    }

    private func validate() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        validating = true; error = nil
        ItchService.shared.setAPIKey(k)
        Task {
            do {
                let user = try await ItchService.shared.validate()
                await MainActor.run { validating = false; onLinked(user); dismiss() }
            } catch {
                ItchService.shared.setAPIKey(nil)
                await MainActor.run {
                    validating = false
                    self.error = (error as? LocalizedError)?.errorDescription ?? "No se pudo validar la API key."
                }
            }
        }
    }
}

// MARK: - Generar juegos DRM-free desde Steam

/// Hoja que trabaja con TODA tu biblioteca de Steam: (1) los juegos **instalados** los clasifica por
/// DRM y genera una **copia local DRM‑free** (copia + Goldberg); (2) los juegos **poseídos pero no
/// instalados** los puede **instalar desde Steam (SteamCMD) y generar** en un solo paso. El resultado
/// es una carpeta autocontenida, ejecutable sin Steam y exportable a un USB.
struct SteamDRMImportSheet: View {
    let bottle: Bottle
    let onGenerated: (SteamDRMScanner.Candidate, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [SteamDRMScanner.Candidate] = []
    @State private var scanning = true
    /// Progreso por appId (compartido: generar o instalar+generar).
    @State private var progress: [String: (Double, String)] = [:]
    @State private var done: Set<String> = []
    @State private var failed: [String: String] = [:]

    // Biblioteca poseída (para instalar+generar los que aún no están).
    @State private var accountService = SteamAccountService()
    @State private var steamCMD = SteamCMDManager()
    @State private var ownedGames: [SteamAccountService.OwnedGame] = []
    @State private var loadingOwned = false
    @State private var search = ""
    @State private var showSteamCMDLogin = false
    @State private var pendingInstall: (appId: String, name: String)?
    @AppStorage("steamcmd.user") private var steamCMDUser = ""

    /// AppIDs que PCGamingWiki confirma **DRM‑free** (índice completo de Steam, cacheado 7 días).
    @State private var drmFreeAppIds: Set<String> = []
    /// Mostrar solo los juegos de tu biblioteca confirmados DRM‑free.
    @State private var onlyDRMFree = false

    private var generable: [SteamDRMScanner.Candidate] { candidates.filter { $0.status.isGenerable } }
    private var installedAppIds: Set<String> { Set(candidates.map { $0.appId }) }
    /// Los juegos de tu biblioteca que PCGamingWiki confirma DRM‑free y aún no tienes instalados:
    /// literalmente la lista de lo que puedes liberar ahora mismo.
    private var ownedDRMFreeCount: Int {
        ownedGames.count { drmFreeAppIds.contains($0.appId) && !installedAppIds.contains($0.appId) }
    }
    private var ownedNotInstalled: [SteamAccountService.OwnedGame] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return ownedGames
            .filter { !installedAppIds.contains($0.appId) && !done.contains($0.appId) }
            .filter { !onlyDRMFree || drmFreeAppIds.contains($0.appId) }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if scanning {
                VStack(spacing: 10) { ProgressView(); Text("Escaneando tu biblioteca de Steam…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .frame(width: 700, height: 640)
        .task { await scan(); await loadOwned(); await loadDRMFreeIndex() }
        .sheet(isPresented: $showSteamCMDLogin) {
            SteamCMDLoginView(suggestedUser: steamCMDUser.isEmpty ? (accountService.detectAccount(bottle: bottle)?.accountName ?? "") : steamCMDUser) { user in
                steamCMDUser = user
                if let p = pendingInstall {
                    pendingInstall = nil
                    Task { await doInstallAndGenerate(appId: p.appId, name: p.name, user: user) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc.fill").foregroundStyle(StoreKind.local.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Juegos DRM‑free desde Steam").font(.headline)
                Text("Genera copias locales autocontenidas (sin Steam, con Goldberg) — instálalas si hace falta.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cerrar") { dismiss() }
        }
        .padding(14)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    if candidates.isEmpty {
                        Text("No hay juegos de Steam instalados en el entorno de Vessel.")
                            .font(.callout).foregroundStyle(.secondary).padding(14)
                    } else {
                        ForEach(candidates) { c in
                            // El detalle dice QUÉ se ha detectado (Denuvo, Steamworks, EOS…) en vez de
                            // dejar al usuario con una etiqueta opaca: si algo no se puede liberar,
                            // que se vea el motivo exacto.
                            gameRow(appId: c.appId, name: c.name, cover: c.coverURL,
                                    badge: (c.status.label, badgeColor(c.status)),
                                    detail: c.drmDetail ?? byteString(c.sizeBytes)) { installedAction(c) }
                            Divider()
                        }
                    }
                } header: { sectionHeader("Instalados — listos para generar (\(generable.count))") }

                Section {
                    searchField
                    if loadingOwned && ownedNotInstalled.isEmpty {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Cargando tu biblioteca…").font(.caption).foregroundStyle(.secondary) }.padding(14)
                    } else if ownedGames.isEmpty {
                        Text("Conecta tu cuenta de Steam (pestaña Steam) para ver e instalar tu biblioteca aquí.")
                            .font(.caption).foregroundStyle(.secondary).padding(14)
                    }
                    ForEach(ownedNotInstalled.prefix(150)) { g in
                        let confirmed = drmFreeAppIds.contains(g.appId)
                        gameRow(appId: g.appId, name: g.name,
                                cover: "https://cdn.akamai.steamstatic.com/steam/apps/\(g.appId)/library_600x900_2x.jpg",
                                badge: confirmed ? ("DRM‑free confirmado", .green) : nil,
                                detail: confirmed ? "PCGamingWiki lo confirma · AppID \(g.appId)"
                                                  : "AppID \(g.appId)") { ownedAction(g) }
                        Divider()
                    }
                    if ownedNotInstalled.count > 150 {
                        Text("Mostrando 150 de \(ownedNotInstalled.count). Refina la búsqueda para ver más.")
                            .font(.caption2).foregroundStyle(.secondary).padding(12)
                    }
                } header: { sectionHeader("Tu biblioteca de Steam — instalar y generar") }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .liquidGlass(in: Rectangle())
    }

    private var searchField: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Buscar en tu biblioteca de Steam…", text: $search).textFieldStyle(.plain).font(.callout)
            }
            .padding(8)
            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

            // Cuántos de TUS juegos son DRM‑free según PCGamingWiki: el dato que nadie te da.
            if !drmFreeAppIds.isEmpty {
                HStack(spacing: 8) {
                    Toggle(isOn: $onlyDRMFree) {
                        Label("Solo DRM‑free confirmados", systemImage: "lock.open.fill")
                            .font(.caption.weight(.medium))
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Text("\(ownedDRMFreeCount) de \(ownedGames.count) juegos tuyos son DRM‑free")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func gameRow<Trailing: View>(appId: String, name: String, cover: String?,
                                         badge: (String, Color)?, detail: String,
                                         @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: cover.flatMap(URL.init)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Rectangle().fill(.gray.opacity(0.2)) }
                .frame(width: 40, height: 56).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if let badge {
                        Text(badge.0).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(badge.1.opacity(0.2), in: Capsule()).foregroundStyle(badge.1)
                    }
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder private func installedAction(_ c: SteamDRMScanner.Candidate) -> some View {
        if done.contains(c.appId) {
            Label("Generado", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.play)
        } else if let prog = progress[c.appId] {
            progressView(prog)
        } else if c.status.isGenerable {
            Button("Generar") { generate(c) }
                .vesselButton(tint: StoreKind.local.tint)
                .controlSize(.small)
        } else {
            Text("No sin Steam").font(.caption).foregroundStyle(.secondary)
                .vesselHelp("Usa el DRM de Steam (CEG): el ejecutable está cifrado y no corre sin el cliente.")
        }
    }

    @ViewBuilder private func ownedAction(_ g: SteamAccountService.OwnedGame) -> some View {
        if let prog = progress[g.appId] {
            progressView(prog)
        } else if let err = failed[g.appId] {
            Button("Reintentar") { installAndGenerate(g) }
                .vesselButton(false, tint: StoreKind.local.tint)
                .controlSize(.small)
                .vesselHelp("Reintentar la generación", detail: err)
        } else {
            Button("Instalar y generar") { installAndGenerate(g) }
                .vesselButton(false, tint: StoreKind.local.tint)
                .controlSize(.small)
        }
    }

    private func progressView(_ prog: (Double, String)) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            ProgressView(value: prog.0).frame(width: 130)
            Text(prog.1).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 150, alignment: .trailing)
        }
    }

    private func badgeColor(_ s: SteamDRMScanner.DRMStatus) -> Color {
        switch s {
        case .drmFree: return .green
        case .steamworks: return StoreKind.local.tint
        case .steamDRM: return .orange
        case .otherDRM: return .red      // Denuvo / anti-cheat / DRM de cuenta / legacy
        }
    }

    // MARK: - Carga

    private func scan() async {
        scanning = true
        // 1) El disco manda: análisis local, inmediato y sin red.
        candidates = SteamDRMScanner.shared.scan(bottle: bottle)
        scanning = false
        // 2) Las bases de datos en vivo (PCGamingWiki, avisos de Steam, anti‑cheat) añaden lo que el
        //    disco NO puede saber: un Denuvo cuyo token vive en el servidor no deja rastro en el .exe.
        //    Best‑effort y cacheado — si no hay red, se queda lo del disco.
        candidates = await SteamDRMScanner.shared.enrichWithDatabases(candidates)
    }

    /// Carga el índice de AppIDs **confirmados DRM‑free** por PCGamingWiki (cacheado 7 días). Sirve
    /// para señalar en TU biblioteca qué juegos puedes liberar antes siquiera de instalarlos.
    private func loadDRMFreeIndex() async {
        drmFreeAppIds = await DRMDatabase.shared.drmFreeAppIds()
    }

    private func loadOwned() async {
        guard let account = accountService.detectAccount(bottle: bottle) else { return }
        loadingOwned = true; defer { loadingOwned = false }
        if ownedGames.isEmpty, let cached = LibraryCache.load("steam-\(account.steamID64)", as: [SteamAccountService.OwnedGame].self) {
            ownedGames = cached
        }
        let owned = await accountService.fetchOwnedGames(steamID64: account.steamID64)
        if !owned.isEmpty { ownedGames = owned; LibraryCache.save("steam-\(account.steamID64)", owned) }
    }

    // MARK: - Generar (instalado)

    private func generate(_ c: SteamDRMScanner.Candidate) {
        progress[c.appId] = (0, "Preparando…")
        Task {
            do {
                let r = try await SteamDRMScanner.shared.generateLocalCopy(c) { frac, msg in
                    Task { @MainActor in progress[c.appId] = (frac, msg) }
                }
                progress[c.appId] = nil; done.insert(c.appId)
                onGenerated(c, r.exe, r.dir)
            } catch {
                progress[c.appId] = nil
                failed[c.appId] = (error as? LocalizedError)?.errorDescription ?? "Error al generar."
            }
        }
    }

    // MARK: - Instalar desde Steam + generar

    private func installAndGenerate(_ g: SteamAccountService.OwnedGame) {
        failed[g.appId] = nil
        progress[g.appId] = (0, "Preparando SteamCMD…")
        Task {
            do { try await steamCMD.ensureInstalled() } catch {
                progress[g.appId] = nil; failed[g.appId] = "No se pudo preparar SteamCMD."; return
            }
            var user = steamCMDUser
            if user.isEmpty { user = accountService.detectAccount(bottle: bottle)?.accountName ?? "" }
            guard !user.isEmpty, await steamCMD.hasSession(user: user) else {
                progress[g.appId] = nil
                pendingInstall = (g.appId, g.name)
                showSteamCMDLogin = true
                return
            }
            steamCMDUser = user
            await doInstallAndGenerate(appId: g.appId, name: g.name, user: user)
        }
    }

    private func doInstallAndGenerate(appId: String, name: String, user: String) async {
        progress[appId] = (0, "Iniciando descarga…")
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "")
        let installDir = "\(bottle.steamDirectory)/steamapps/common/\(safeName)"
        let ok = await steamCMD.installGame(appId: appId, user: user, installDir: installDir, validate: true) { pct, msg in
            progress[appId] = (msg.contains("Descargando") ? max(0, min(1, pct / 100)) : 0, msg)
        }
        guard ok, let cand = SteamDRMScanner.shared.candidate(appId: appId, name: name, installDir: installDir) else {
            progress[appId] = nil; failed[appId] = "La instalación no se completó."; return
        }
        guard cand.status.isGenerable else {
            progress[appId] = nil; failed[appId] = "Instalado, pero usa DRM de Steam (no corre sin Steam)."; return
        }
        do {
            progress[appId] = (0.9, "Generando copia local DRM‑free…")
            let r = try await SteamDRMScanner.shared.generateLocalCopy(cand) { frac, msg in
                Task { @MainActor in progress[appId] = (0.9 + frac * 0.1, msg) }
            }
            progress[appId] = nil; done.insert(appId)
            onGenerated(cand, r.exe, r.dir)
        } catch {
            progress[appId] = nil
            failed[appId] = (error as? LocalizedError)?.errorDescription ?? "Error al generar."
        }
    }

    private func byteString(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

// MARK: - Vincular Humble (login WebView)

/// Hoja para vincular Humble Bundle: login en un WebView; al capturar la cookie de sesión, se guarda.
struct HumbleLinkSheet: View {
    let onLinked: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bag.fill").foregroundStyle(StoreKind.local.tint)
                Text("Inicia sesión en Humble Bundle").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Cerrar") { dismiss() }
            }
            .padding(12)
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.destructive).padding(.horizontal, 12).padding(.bottom, 8)
            }
            HumbleLoginWebView(
                onSessionCaptured: { value in
                    HumbleService.shared.setSession(value)
                    onLinked(); dismiss()
                },
                onError: { self.error = $0 },
                onLoadingChanged: { self.loading = $0 }
            )
        }
        .frame(width: 720, height: 640)
    }
}
