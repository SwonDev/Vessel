import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// **Hub DRM‑free** de Vessel. Reutiliza `StoreLibraryView` (la MISMA biblioteca genérica de
/// Steam/Epic/GOG) → hereda la sidebar buscable, la rejilla con densidad y la ficha, con total
/// coherencia visual. Sus acciones propias (vincular itch.io/Humble, generar copias locales desde
/// Steam, añadir .exe/instalador) viven en `toolbarExtra`. Agrega TODO lo sin DRM del usuario:
/// itch.io, Humble Bundle, copias locales de Steam, GOG offline y cualquier ejecutable de Windows.
struct LocalGamesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var games = LocalGamesStore.shared
    private let store = BottleStore.shared
    @State private var wineManager = WineManager()
    /// Solo para localizar los juegos de GOG ya instalados (todo GOG es DRM‑free por política de
    /// la tienda) — la instalación/actualización sigue viviendo en la sección de GOG.
    @State private var gogdl = GogdlManager()
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

    /// Bottle compartido (el mismo prefijo con Wine + fixes que usa Steam). Es el de los juegos
    /// que Vessel instala él mismo (itch/Humble/exes sueltos); los de tienda usan el suyo.
    private var bottle: Bottle? {
        store.bottles.first(where: { $0.name == "Steam" })
            ?? store.bottles.first(where: { FileManager.default.fileExists(atPath: $0.steamPath) })
            ?? store.bottles.first
    }

    /// Bottle **donde vive** el juego: el que contiene su ejecutable. Los juegos de GOG y de Epic
    /// están dentro del prefijo de SU tienda y hay que lanzarlos ahí — su registro, sus runtimes y
    /// sus partidas viven en ese prefijo. Lanzarlos en el de Steam los deja sin nada de eso.
    private func bottle(for game: LocalGamesStore.Game) -> Bottle? {
        store.bottles.first { !$0.prefixPath.isEmpty && game.executablePath.hasPrefix($0.prefixPath + "/") }
            ?? bottle
    }

    /// Explica qué se va a exportar **con datos ciertos**: un juego de DOS no lleva Wine (va con el
    /// DOSBox nativo, decenas de MB), así que prometerle 2,2 GB sería mentirle al usuario.
    private func exportExplanation(_ g: LocalGamesStore.Game) -> String {
        if StandaloneMacExporter.isDOSGame(g.executablePath) {
            return "«App para Mac» empaqueta el juego + DOSBox nativo (unas decenas de MB) en un .app "
                 + "que arranca en cualquier Mac SIN Vessel, sin Wine y sin Rosetta. «Carpeta Windows» "
                 + "copia el juego DRM‑free tal cual para ejecutarlo en un PC."
        }
        return "«App para Mac» empaqueta el juego + el motor (~2,2 GB) en un .app que arranca en "
             + "cualquier Mac Apple Silicon sin Vessel. «Carpeta Windows» copia el juego DRM‑free "
             + "para ejecutarlo en un PC."
    }

    /// Carpeta local del juego: la de instalación o, si no consta, la del ejecutable. `nil` si el
    /// juego aún no está en disco. Fuente única para exportar/verificar/abrir carpeta.
    private func folder(of g: LocalGamesStore.Game) -> String? {
        if let ip = g.installPath, !ip.isEmpty { return ip }
        guard !g.executablePath.isEmpty else { return nil }
        return (g.executablePath as NSString).deletingLastPathComponent
    }

    // MARK: - Mapeo a StoreGame (para reutilizar StoreLibraryView)

    private var storeGames: [StoreGame] {
        games.games.map { g in
            let folder = g.installPath ?? (g.installed ? folder(of: g) : nil)
            return StoreGame(
                id: g.id.uuidString,
                title: g.name,
                coverURL: g.coverURL,
                steamAppId: g.source == .steam ? g.sourceId : nil,
                installed: g.installed,
                updateAvailable: g.updateAvailable,
                installPath: folder,
                executablePath: g.executablePath.isEmpty ? nil : g.executablePath,
                // Insignia con la FUENTE (Steam / itch.io / Humble / GOG offline) y, si es nativo de
                // Mac, se dice: es la mejor noticia posible (corre sin Wine).
                badge: g.platform == .mac ? "Nativo de Mac"
                                          : (g.source == .local ? nil : g.source.displayName)
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
            onVerify: { sg in if let g = game(sg) { verifyIntegrity(g) } },
            onUpdate: { sg in if let g = game(sg) { updateGame(g) } },
            onReload: { refresh() },
            onLogout: { },
            toolbarExtra: AnyView(drmFreeMenu),
            onExport: { sg in if let g = game(sg) { exportChoice = g } }
        )
        .task { syncStores() }
        .overlay(alignment: .bottom) { bannerView }
        .confirmationDialog("Exportar «\(exportChoice?.name ?? "")»",
                            isPresented: Binding(get: { exportChoice != nil }, set: { if !$0 { exportChoice = nil } }),
                            titleVisibility: .visible) {
            Button("App para Mac (Apple Silicon)") { if let g = exportChoice { exportChoice = nil; exportMacApp(g) } }
            Button("Carpeta Windows (para USB/PC)") { if let g = exportChoice { exportChoice = nil; exportGame(g) } }
            Button("Cancelar", role: .cancel) { exportChoice = nil }
        } message: {
            Text(exportChoice.map(exportExplanation) ?? "")
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
            Menu("Disco físico") {
                Button { pickImageAndInstall() } label: { Label("Instalar desde una imagen (.iso)…", systemImage: "opticaldiscdrive") }
                let discs = PhysicalMediaImporter.mountedGameDiscs()
                if discs.isEmpty {
                    Text("No hay ningún disco de juego insertado")
                } else {
                    Divider()
                    ForEach(discs, id: \.self) { disc in
                        let name = (disc as NSString).lastPathComponent
                        Menu(name) {
                            Button { installFromMedia(mountedAt: disc) } label: { Label("Instalar desde este disco", systemImage: "arrow.down.circle") }
                            Button { preserveDisc(disc) } label: { Label("Preservar como imagen ISO…", systemImage: "archivebox") }
                        }
                    }
                }
            }
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
        .accessibilityLabel("Añadir juegos DRM-free")
        .vesselHelp("Añadir juegos DRM-free", detail: "Importa desde Steam, itch.io, Humble, un .exe o un disco físico.")
    }

    @ViewBuilder private var bannerView: some View {
        if let ep = exportProgress {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("\(ep.name) — \(ep.msg)").font(.callout.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                }
                // `frac` negativa = no se conoce el avance (p. ej. el volcado de un disco, que no
                // reporta progreso): barra indeterminada en vez de un porcentaje inventado.
                if ep.frac < 0 {
                    ProgressView().progressViewStyle(.linear).tint(StoreKind.local.tint).frame(width: 320)
                } else {
                    ProgressView(value: ep.frac).tint(StoreKind.local.tint).frame(width: 320)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .padding(.bottom, 26)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let banner {
            Label(banner.0, systemImage: banner.1 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.callout.weight(.medium)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .liquidGlass(in: Capsule())
                .overlay(Capsule().strokeBorder((banner.1 ? Color.orange : .green).opacity(0.5), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
                .padding(.bottom, 26)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Recoge de las tiendas todo lo que ya es DRM‑free sin tener que generar nada: GOG (todo su
    /// catálogo lo es) y los juegos de Epic que la propia Epic declara sin token de propiedad.
    @discardableResult
    private func syncStores() -> String? {
        let gog = GOGDRMFreeImporter.sync(gogdl: gogdl)
        let epic = EpicDRMFreeImporter.sync()
        var parts: [String] = []
        if gog > 0 { parts.append("\(gog) de GOG") }
        if epic.imported > 0 { parts.append("\(epic.imported) de Epic") }
        return parts.isEmpty ? nil : parts.joined(separator: " y ")
    }

    private func refresh() {
        let fromStores = syncStores()
        if ItchService.shared.isLinked { syncItch() }
        if HumbleService.shared.isLinked { syncHumble() }
        if !ItchService.shared.isLinked && !HumbleService.shared.isLinked {
            flash(fromStores.map { "Biblioteca DRM‑free actualizada — \($0) incluidos." }
                  ?? "Biblioteca DRM‑free actualizada.", false)
        }
    }

    // MARK: - Verificar / sellar (preservación)

    /// **Verifica la integridad** de la copia, o la **sella** si aún no lo estaba. Sellar = escribir
    /// un manifiesto con el SHA‑256 de cada fichero; verificar = recomprobarlos. Es lo que convierte
    /// una carpeta en un archivo preservado de verdad: dentro de diez años sabrás si tu copia sigue
    /// intacta o si el disco se ha ido degradando (bit rot) sin avisar.
    private func verifyIntegrity(_ g: LocalGamesStore.Game) {
        guard let dir = folder(of: g), FileManager.default.fileExists(atPath: dir) else {
            flash("Este juego no tiene una carpeta local que verificar.", true); return
        }
        let sealed = DRMFreeArchive.readManifest(folder: dir) != nil
        exportProgress = (g.name, -1, sealed ? "Verificando…" : "Sellando la copia…")
        Task {
            do {
                if sealed {
                    let r = try await DRMFreeArchive.shared.verify(folder: dir) { frac, msg in
                        Task { @MainActor in exportProgress = (g.name, frac, msg) }
                    }
                    exportProgress = nil
                    flash(r.summary, !r.isIntact)
                } else {
                    let m = try await DRMFreeArchive.shared.writeManifest(
                        folder: dir, title: g.name, source: g.source.rawValue, sourceId: g.sourceId,
                        executable: (g.executablePath as NSString).lastPathComponent
                    ) { frac, msg in Task { @MainActor in exportProgress = (g.name, frac, msg) } }
                    exportProgress = nil
                    flash("«\(g.name)» sellado: \(m.files.count) fichero(s) con huella SHA‑256. Ya puedes verificarlo cuando quieras.", false)
                }
            } catch {
                exportProgress = nil
                flash((error as? LocalizedError)?.errorDescription ?? "No se pudo verificar la copia.", true)
            }
        }
    }

    /// "Actualizar" = re‑descargar el build nuevo del origen. Solo itch.io y Humble publican builds
    /// que Vessel pueda traerse; el resto se actualiza desde su propia tienda.
    private func updateGame(_ g: LocalGamesStore.Game) {
        switch g.source {
        case .itch, .humble: download(g)
        case .gog: flash("Los juegos de GOG se actualizan desde la sección de GOG.", false)
        case .steam: flash("Vuelve a generar la copia local desde Steam para actualizarla.", false)
        default: flash("«\(g.name)» no tiene un origen del que descargar actualizaciones.", false)
        }
    }

    // MARK: - Medio físico (disco / imagen ISO)

    /// **Instala desde un disco o una imagen.** El juego en disco es el DRM‑free original: lo
    /// compraste, es tuyo y no depende de que ninguna tienda siga existiendo. Monta la imagen en
    /// solo lectura, busca el instalador que declara el propio disco (`autorun.inf`) y lo ejecuta.
    private func installFromMedia(imagePath: String? = nil, mountedAt: String? = nil) {
        guard let bottle else { flash("Aún no hay un entorno de Wine listo.", true); return }
        Task {
            var mounted: PhysicalMediaImporter.Media?
            do {
                let mountPoint: String
                if let mountedAt {
                    mountPoint = mountedAt
                } else if let imagePath {
                    flash("Montando la imagen…", false)
                    let m = try await PhysicalMediaImporter.shared.mount(imageAt: imagePath)
                    mounted = m
                    mountPoint = m.mountPoint
                } else { return }
                guard let installer = PhysicalMediaImporter.findInstaller(in: mountPoint) else {
                    throw PhysicalMediaImporter.MediaError.noInstaller
                }
                flash("Ejecutando «\((installer as NSString).lastPathComponent)» del disco… al acabar, elige el ejecutable del juego.", false)
                let proc = try await wineManager.launch(executable: installer, in: bottle,
                                                        arguments: [], effective: EffectiveLaunchConfig())
                while proc.isRunning { try? await Task.sleep(for: .seconds(1)) }
                promptForInstalledExe(in: bottle)
            } catch {
                flash((error as? LocalizedError)?.errorDescription ?? "No se pudo instalar desde el disco.", true)
            }
            // Se desmonta SIEMPRE lo que montamos nosotros; un disco que ya estaba montado no se toca.
            if let mounted { await PhysicalMediaImporter.shared.unmount(mounted) }
        }
    }

    private func pickImageAndInstall() {
        let panel = NSOpenPanel()
        panel.title = "Elige la imagen del disco (.iso / .img)"
        panel.prompt = "Instalar desde aquí"
        panel.message = "Se montará en solo lectura y se ejecutará su instalador dentro de Vessel."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["iso", "img", "cdr", "dmg"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        installFromMedia(imagePath: url.path)
    }

    /// **Preserva el disco**: lo vuelca a un `.iso` que conservas para siempre — aunque el disco se
    /// raye, se pierda o ya no tengas lector. Con la industria retirando el formato físico, esto es
    /// lo único que garantiza que tu copia siga siendo tuya dentro de veinte años.
    private func preserveDisc(_ mountPoint: String) {
        let discName = (mountPoint as NSString).lastPathComponent
        let panel = NSSavePanel()
        panel.title = "Guardar la imagen de «\(discName)»"
        panel.prompt = "Preservar"
        panel.message = "Se creará una imagen ISO estándar, legible en cualquier sistema."
        panel.nameFieldStringValue = "\(discName).iso"
        panel.allowedContentTypes = [UTType(filenameExtension: "iso")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportProgress = (discName, -1, "Volcando el disco…")
        Task {
            do {
                let iso = try await PhysicalMediaImporter.shared.ripDiscToISO(
                    mountPoint: mountPoint, dest: url.path
                ) { msg in Task { @MainActor in exportProgress = (discName, -1, msg) } }
                exportProgress = nil
                flash("«\(discName)» preservado como \((iso as NSString).lastPathComponent).", false)
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: iso)])
            } catch {
                exportProgress = nil
                flash((error as? LocalizedError)?.errorDescription ?? "No se pudo preservar el disco.", true)
            }
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
        guard let exe = pickInstalledExe(in: bottle) else { return }
        if games.add(name: "", executablePath: exe) != nil { flash("Juego añadido.", false) }
    }

    /// Panel para elegir un `.exe` ya instalado dentro del bottle (apunta a Program Files).
    private func pickInstalledExe(in bottle: Bottle) -> String? {
        let panel = NSOpenPanel()
        panel.title = "Elige el ejecutable del juego instalado"
        panel.prompt = "Usar este"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let exe = UTType(filenameExtension: "exe") { panel.allowedContentTypes = [exe] }
        for candidate in ["\(bottle.prefixPath)/drive_c/Program Files (x86)", "\(bottle.prefixPath)/drive_c/Program Files"] {
            if FileManager.default.fileExists(atPath: candidate) { panel.directoryURL = URL(fileURLWithPath: candidate); break }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// La descarga resultó ser un **instalador** (típico en itch.io/Humble): lo ejecuta en el bottle
    /// y, al terminar, fija el ejecutable REAL del juego en esta misma entrada de la biblioteca.
    private func runDownloadedInstaller(_ g: LocalGamesStore.Game, installerExe: String) async {
        guard let bottle else { return }
        flash("«\(g.name)» es un instalador: ejecutándolo… al acabar, elige el ejecutable del juego.", false)
        do {
            let proc = try await wineManager.launch(executable: installerExe, in: bottle,
                                                    arguments: [], effective: EffectiveLaunchConfig())
            while proc.isRunning { try? await Task.sleep(for: .seconds(1)) }
            if let exe = pickInstalledExe(in: bottle) {
                games.setInstalled(g.id, executablePath: exe,
                                   installPath: (exe as NSString).deletingLastPathComponent)
                flash("«\(g.name)» instalado y listo para jugar.", false)
            } else {
                flash("«\(g.name)»: instalador ejecutado. Cuando quieras, elige su ejecutable desde «Añadir».", false)
            }
        } catch {
            flash((error as? LocalizedError)?.errorDescription ?? "No se pudo ejecutar el instalador de «\(g.name)».", true)
        }
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
                    coverURL: g.coverURL, arguments: g.launchArguments, destParent: destParent
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
        withAnimation(reduceMotion ? nil : .smooth) { banner = (msg, isError) }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await MainActor.run {
                withAnimation(reduceMotion ? nil : .smooth) {
                    if banner?.0 == msg { banner = nil }
                }
            }
        }
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
                await checkItchUpdates()
            } catch { flash((error as? LocalizedError)?.errorDescription ?? "Error al sincronizar itch.io.", true) }
            syncing = false
        }
    }

    /// Comprueba si los juegos de itch.io **instalados** tienen versión nueva en el origen. Los indies
    /// actualizan a menudo; hasta ahora no había forma de enterarse. Compara el token de versión
    /// (md5/build) guardado al instalar con el del build publicado.
    private func checkItchUpdates() async {
        let installed = games.games.filter { $0.source == .itch && $0.installed && ($0.installedVersion?.isEmpty == false) }
        guard !installed.isEmpty else { return }
        var found = 0
        for g in installed {
            guard let sid = g.sourceId, let v = g.installedVersion else { continue }
            let parts = sid.split(separator: ":").map(String.init)
            guard parts.count == 2, let gid = Int(parts[0]), let dkid = Int(parts[1]) else { continue }
            let has = await ItchService.shared.hasUpdate(gameId: gid, downloadKeyId: dkid,
                                                         installedVersion: v,
                                                         preferNative: g.platform == .mac)
            games.setUpdateAvailable(g.id, has)
            if has { found += 1 }
        }
        if found > 0 { flash("itch.io: \(found) juego(s) con actualización disponible.", false) }
    }

    private func syncHumble() {
        syncing = true
        Task {
            do {
                let items = try await HumbleService.shared.fetchLibrary()
                // Humble Trove / Games Collection: catálogo de la suscripción (endpoint aparte).
                // Si no estás suscrito devuelve vacío → no es un error.
                let trove = (try? await HumbleService.shared.fetchTrove()) ?? []
                for it in items + trove {
                    // En el Trove guardamos el `url.web` (nombre a firmar) en downloadURL.
                    games.upsertLibraryEntry(source: .humble, sourceId: it.sourceId,
                                             name: it.name, coverURL: it.iconURL,
                                             downloadURL: it.troveWebName)
                }
                let troveNote = trove.isEmpty ? "" : " + \(trove.count) del Trove"
                flash("Humble: \(items.count) juego(s) DRM‑free\(troveNote) sincronizados.", false)
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
                // Preferimos SIEMPRE el build nativo de macOS si existe: corre sin Wine ni Rosetta.
                var native = false
                var version: String? = nil
                switch g.source {
                case .itch:
                    let parts = sid.split(separator: ":").map(String.init)
                    guard parts.count == 2, let gid = Int(parts[0]), let dkid = Int(parts[1]) else {
                        throw NSError(domain: "Vessel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Id de itch.io inválido."])
                    }
                    let r = try await ItchService.shared.bestDownload(gameId: gid, downloadKeyId: dkid)
                    url = r.url; filenameHint = r.filename; native = (r.platform == .mac); version = r.version
                case .humble:
                    guard let colon = sid.firstIndex(of: ":") else {
                        throw NSError(domain: "Vessel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Id de Humble inválido."])
                    }
                    let gamekey = String(sid[..<colon]); let machine = String(sid[sid.index(after: colon)...])
                    if gamekey == "trove" {
                        // Trove: su `url.web` es un NOMBRE de fichero que hay que firmar (no una URL).
                        guard let webName = g.downloadURL, !webName.isEmpty else {
                            throw NSError(domain: "Vessel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Falta el fichero del Trove; vuelve a sincronizar Humble."])
                        }
                        url = try await HumbleService.shared.troveSignedURL(machineName: machine, webName: webName)
                    } else {
                        let r = try await HumbleService.shared.bestDownloadURL(gamekey: gamekey, machineName: machine)
                        url = r.url; native = (r.platform == .mac)
                    }
                    if let sess = HumbleService.shared.sessionCookie { headers["Cookie"] = "_simpleauth_sess=\(sess)" }
                default:
                    throw NSError(domain: "Vessel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fuente sin descarga automática."])
                }
                let name = g.name
                let installed = try await DRMFreeInstaller.shared.downloadAndInstall(
                    url: url, headers: headers, slug: name, suggestedName: name, filenameHint: filenameHint,
                    source: g.source.rawValue, sourceId: g.sourceId, nativeMac: native
                ) { frac, msg in Task { @MainActor in downloading[g.id] = (frac, msg) } }
                games.setInstalled(g.id, executablePath: installed.executablePath,
                                   installPath: installed.installDir,
                                   platform: installed.isNativeMac ? .mac : .windows,
                                   version: version)
                downloading[g.id] = nil
                if installed.isInstaller {
                    // Lo descargado es un instalador (típico en itch.io): ejecútalo y fija el exe real.
                    await runDownloadedInstaller(g, installerExe: installed.executablePath)
                } else {
                    flash(installed.isNativeMac ? "«\(name)» instalado (build NATIVO de Mac, sin Wine)."
                                                : "«\(name)» instalado.", false)
                }
            } catch {
                downloading[g.id] = nil
                flash((error as? LocalizedError)?.errorDescription ?? "Error al descargar «\(g.name)».", true)
            }
        }
    }

    // MARK: - Jugar (mismo flujo que las tiendas)

    private func play(_ game: LocalGamesStore.Game, forcedLayer: GameConfig.GraphicsLayer? = nil, attempt: Int = 0) {
        guard game.installed else { return }
        // **Build nativo de macOS**: se abre tal cual, sin Wine, sin motor y sin capa gráfica. Es lo
        // mejor que le puede pasar a un juego en un Mac; no hay nada que traducir ni que reparar.
        if game.platform == .mac {
            games.markPlayed(game.id)
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: game.executablePath),
                                               configuration: NSWorkspace.OpenConfiguration()) { _, err in
                if let err { Task { @MainActor in flash("No se pudo abrir «\(game.name)»: \(err.localizedDescription)", true) } }
            }
            return
        }
        guard let bottle = bottle(for: game) else { return }
        let id = game.id.uuidString
        let cfg = GameConfigStore.load(id)
        let exe = GameExecutableOverride.resolve(
            configuredPath: cfg.executableOverride,
            installRoot: folder(of: game),
            fallback: game.executablePath
        )
        let installDir = (exe as NSString).deletingLastPathComponent
        Task {
            // Juegos de GOG: completar su post-instalación si falta (los clásicos no arrancan sin
            // el .ini/.conf que genera el `goggame-<id>.script`). Idempotente y silencioso.
            // OJO: la raíz es `installPath` (donde está el `goggame-<id>.*`), NO la carpeta del exe
            // — en los clásicos el exe cuelga de una subcarpeta (`ScummVM/`, `DOSBOX/`).
            if game.source == .gog, let sid = game.sourceId, let root = folder(of: game) {
                await GOGPostInstall.applyIfNeeded(
                    appId: sid, root: root, prefix: bottle.prefixPath,
                    winePath: wineManager.resolveGameWine(for: bottle, executable: exe))
            }
            let profile = CompatService.shared.profile(steam: nil, title: game.name)
            var eff = CompatService.shared.effectiveConfig(profile: profile, user: cfg)
            if let forcedLayer { eff.graphicsOverride = forcedLayer }
            let usedLayer = wineManager.resolvedGraphicsLayer(forExecutable: exe, effective: eff)
            await tracker.track(
                id, statsKey: "local:\(id)",
                onExit: { Task { await SaveBackupManager.shared.backup(store: .local, id: id, title: game.name, steamId: nil, prefix: bottle.prefixPath, installPath: installDir) } }
            ) {
                await SaveBackupManager.shared.restoreIfNewer(store: .local, id: id, title: game.name, steamId: nil, prefix: bottle.prefixPath, installPath: installDir)
                let proc = try await wineManager.launch(executable: exe, in: bottle,
                                                        arguments: game.launchArguments, effective: eff)
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
