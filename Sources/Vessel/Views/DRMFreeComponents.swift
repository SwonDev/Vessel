import SwiftUI
import WebKit

/// Tarjeta premium de un juego DRM‑free (itch.io / Humble / local): portada (URL remota o
/// placeholder), insignia de fuente, y acción contextual — **Jugar/Detener** si está instalado,
/// **Descargar** si está en la biblioteca pero aún no, o barra de progreso mientras se instala.
struct DRMFreeCard: View {
    let game: LocalGamesStore.Game
    let progress: (Double, String)?
    let busy: Bool
    let running: Bool
    let onPlay: () -> Void
    let onStop: () -> Void
    let onDownload: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    private var tint: Color { StoreKind.local.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                cover
                if let progress {   // descargando / instalando
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.55))
                    VStack(spacing: 8) {
                        ProgressView(value: progress.0).progressViewStyle(.linear).tint(tint)
                            .frame(width: 120)
                        Text(progress.1).font(.caption2).foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }.padding(.horizontal, 12)
                } else if hovering || busy {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.38))
                    if busy && !running {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        actionButton
                    }
                }
                sourceBadge
            }
            .frame(height: 210)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: hovering ? 12 : 6, y: hovering ? 6 : 3)
            .scaleEffect(hovering ? 1.02 : 1)
            Text(game.name).font(.callout.weight(.medium)).foregroundStyle(.white).lineLimit(1)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu { contextMenu }
    }

    @ViewBuilder private var cover: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if let local = game.coverPath, let img = NSImage(contentsOfFile: local) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).clipShape(shape)
        } else if let s = game.coverURL, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                default: placeholder
                }
            }.clipShape(shape)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.55), .black.opacity(0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "lock.open.fill").font(.system(size: 34, weight: .medium)).foregroundStyle(.white.opacity(0.85))
        }
    }

    @ViewBuilder private var actionButton: some View {
        if game.installed {
            Button(action: running ? onStop : onPlay) {
                Label(running ? "Detener" : "Jugar", systemImage: running ? "stop.fill" : "play.fill")
                    .font(.headline).padding(.horizontal, 14).padding(.vertical, 8)
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .background(tint.gradient, in: Capsule())
        } else if game.source == .itch || game.source == .humble {
            Button(action: onDownload) {
                Label("Descargar", systemImage: "arrow.down.circle.fill")
                    .font(.headline).padding(.horizontal, 14).padding(.vertical, 8)
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .background(tint.gradient, in: Capsule())
        }
    }

    /// Insignia de la fuente (arriba a la izquierda), salvo en local.
    @ViewBuilder private var sourceBadge: some View {
        if game.source != .local {
            VStack {
                HStack {
                    Text(game.source.displayName)
                        .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(6)
                    Spacer()
                }
                Spacer()
            }
        }
    }

    @ViewBuilder private var contextMenu: some View {
        if game.installed {
            Button(running ? "Detener" : "Jugar", systemImage: running ? "stop.fill" : "play.fill") { running ? onStop() : onPlay() }
        } else if game.source == .itch || game.source == .humble {
            Button("Descargar", systemImage: "arrow.down.circle") { onDownload() }
        }
        if let s = game.pageURL, let u = URL(string: s) {
            Button("Ver en la web", systemImage: "safari") { NSWorkspace.shared.open(u) }
        }
        Button("Revelar en Finder", systemImage: "folder") { onReveal() }
        Divider()
        Button("Quitar de la lista", systemImage: "eye.slash", role: .destructive) { onRemove() }
        if game.installed, game.installPath?.hasPrefix(VesselPaths.drmFreeDirectory) == true {
            Button("Borrar del disco", systemImage: "trash", role: .destructive) { onDelete() }
        }
    }
}

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
            Button("Abrir la página de API keys") {
                NSWorkspace.shared.open(URL(string: "https://itch.io/user/settings/api-keys")!)
            }.buttonStyle(.link)

            SecureField("API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(validate)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                Button(validating ? "Validando…" : "Vincular") { validate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || validating)
            }
        }
        .padding(24).frame(width: 460)
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

/// Hoja que escanea los juegos de Steam instalados, los clasifica por DRM y permite **generar una
/// copia local DRM‑free** (copia los archivos + Goldberg) de los que pueden correr sin Steam.
struct SteamDRMImportSheet: View {
    let bottle: Bottle
    let onGenerated: (SteamDRMScanner.Candidate, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [SteamDRMScanner.Candidate] = []
    @State private var scanning = true
    @State private var generating: [String: (Double, String)] = [:]   // appId → progreso
    @State private var done: Set<String> = []

    private var generable: [SteamDRMScanner.Candidate] { candidates.filter { $0.status.isGenerable } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill").foregroundStyle(StoreKind.local.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Generar juegos DRM‑free desde Steam").font(.headline)
                    Text("Vessel copia los archivos y los deja ejecutables sin Steam (Goldberg).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cerrar") { dismiss() }
            }
            .padding(14)
            Divider()
            if scanning {
                VStack(spacing: 10) { ProgressView(); Text("Escaneando tu biblioteca de Steam…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if candidates.isEmpty {
                Text("No se encontraron juegos de Steam instalados en el entorno de Vessel.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(candidates) { c in row(c); Divider() }
                    }
                }
                HStack {
                    Text("\(generable.count) de \(candidates.count) pueden generarse como DRM‑free.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(12)
            }
        }
        .frame(width: 640, height: 560)
        .task { await scan() }
    }

    private func row(_ c: SteamDRMScanner.Candidate) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: c.coverURL.flatMap(URL.init)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Rectangle().fill(.gray.opacity(0.2)) }
                .frame(width: 40, height: 56).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                Text(c.name).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(c.status.label).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(badgeColor(c.status).opacity(0.2), in: Capsule())
                        .foregroundStyle(badgeColor(c.status))
                    Text(byteString(c.sizeBytes)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            action(c)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder private func action(_ c: SteamDRMScanner.Candidate) -> some View {
        if done.contains(c.appId) {
            Label("Generado", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        } else if let prog = generating[c.appId] {
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: prog.0).frame(width: 120)
                Text(prog.1).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if c.status.isGenerable {
            Button("Generar") { generate(c) }.buttonStyle(.borderedProminent).controlSize(.small)
        } else {
            Text("No sin Steam").font(.caption).foregroundStyle(.secondary)
                .help("Usa el DRM de Steam (CEG): el ejecutable está cifrado y no corre sin el cliente.")
        }
    }

    private func badgeColor(_ s: SteamDRMScanner.DRMStatus) -> Color {
        switch s { case .drmFree: return .green; case .steamworks: return StoreKind.local.tint; case .steamDRM: return .orange }
    }

    private func scan() async {
        scanning = true
        let result = SteamDRMScanner.shared.scan(bottle: bottle)
        await MainActor.run { candidates = result; scanning = false }
    }

    private func generate(_ c: SteamDRMScanner.Candidate) {
        generating[c.appId] = (0, "Preparando…")
        Task {
            do {
                let r = try await SteamDRMScanner.shared.generateLocalCopy(c) { frac, msg in
                    Task { @MainActor in generating[c.appId] = (frac, msg) }
                }
                await MainActor.run {
                    generating[c.appId] = nil
                    done.insert(c.appId)
                    onGenerated(c, r.exe, r.dir)
                }
            } catch {
                await MainActor.run {
                    generating[c.appId] = nil
                    // Reaprovecha la fila con un aviso breve reutilizando el badge de error via help.
                }
            }
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
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 8)
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
