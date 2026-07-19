import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Configuración POR JUEGO (se aplica al lanzar). Persistida por id de juego en UserDefaults.
struct GameConfig: Codable, Equatable {
    /// Capa de traducción gráfica preferida para este juego.
    enum GraphicsLayer: String, Codable, CaseIterable, Identifiable {
        case auto, dxmt, gptk, gcenx
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto:  return "Automático (recomendado)"
            case .dxmt:  return "DXMT · D3D11 → Metal"
            case .gptk:  return "GPTK / D3DMetal · D3D12 → Metal"
            case .gcenx: return "Gcenx · D3D9 → Vulkan → Metal"
            }
        }
        var detail: String {
            switch self {
            case .auto:  return "Vessel detecta la API (D3D9/11/12) y elige la capa óptima por juego."
            case .dxmt:  return "Fuerza DXMT. Ideal para juegos modernos D3D11 (Unity, etc.)."
            case .gptk:  return "Fuerza GPTK/D3DMetal. Para juegos AAA con DirectX 12 / Agility SDK."
            case .gcenx: return "Fuerza Gcenx (wined3d→Vulkan). Para juegos D3D9/D3D8 (o que importan D3D11 pero renderizan en D3D9, p. ej. Grim Dawn)."
            }
        }
    }
    var graphicsLayer: GraphicsLayer = .auto
    /// Campo legado conservado únicamente para decodificar configuraciones antiguas. La UI ya no
    /// lo expone y CompatService no lo aplica: la compatibilidad se resuelve en el motor/perfil.
    var launchArguments: String = ""
    var esync: Bool = true
    var fsync: Bool = true
    /// Muestra el HUD de rendimiento de Metal (FPS / tiempos de frame) superpuesto en el juego.
    var metalHUD: Bool = false
    /// Modo "Steam real": el juego necesita la API COMPLETA de Steam (DRM, Steam Input/Controller,
    /// interfaces como STEAMUNIFIEDMESSAGES que Goldberg no implementa) → Vessel arranca el cliente
    /// Steam conectado en segundo plano y lanza el juego en su mismo wineserver. Lo pone el usuario o,
    /// automáticamente, el auto-repair cuando detecta un fallo de interfaz de Steam.
    var useRealSteam: Bool = false
    /// Sincronizar la partida con la NUBE de Steam en Modo Vessel (experimental, opt-in): antes de
    /// jugar, Vessel arranca el cliente Steam en 2º plano (que descarga la última nube de todos tus
    /// juegos); al salir, lo sincroniza (sube los cambios). Validado: arrancar el cliente dispara el
    /// AutoCloud real (cloud_log lo confirma). El backup local sigue activo SIEMPRE como red de seguridad.
    var steamCloudSync: Bool = false
    /// Ejecutable alternativo dentro de la propia carpeta del juego. Sirve para títulos cuyo
    /// launcher es de 32 bits pero el cliente real vive en `x64/`, `Binaries/Win64`, etc.
    var executableOverride: String? = nil

    init() {}

    enum CodingKeys: String, CodingKey {
        case graphicsLayer, launchArguments, esync, fsync, metalHUD, useRealSteam, steamCloudSync
        case executableOverride
    }

    /// Decodificación TOLERANTE: los campos ausentes usan su valor por defecto. El decoder
    /// sintetizado de Swift NO lo hace y RESETEABA todos los ajustes guardados al añadir un campo
    /// nuevo (p. ej. `metalHUD`) → se perdían capa gráfica, args, sync del usuario.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        graphicsLayer = try c.decodeIfPresent(GraphicsLayer.self, forKey: .graphicsLayer) ?? .auto
        launchArguments = try c.decodeIfPresent(String.self, forKey: .launchArguments) ?? ""
        esync = try c.decodeIfPresent(Bool.self, forKey: .esync) ?? true
        fsync = try c.decodeIfPresent(Bool.self, forKey: .fsync) ?? true
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        useRealSteam = try c.decodeIfPresent(Bool.self, forKey: .useRealSteam) ?? false
        steamCloudSync = try c.decodeIfPresent(Bool.self, forKey: .steamCloudSync) ?? false
        executableOverride = try c.decodeIfPresent(String.self, forKey: .executableOverride)
    }
}

/// Persistencia de la configuración por juego.
@MainActor
enum GameConfigStore {
    static func load(_ id: String) -> GameConfig {
        guard let data = UserDefaults.standard.data(forKey: "gameconfig.\(id)"),
              let cfg = try? JSONDecoder().decode(GameConfig.self, from: data) else { return GameConfig() }
        return cfg
    }
    static func save(_ id: String, _ config: GameConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "gameconfig.\(id)")
        }
    }
}

/// Ajustes de un juego: capa gráfica, sincronización y carpeta.
/// Premium navy + Liquid Glass. Se guarda al instante y se aplica al lanzar el juego.
struct GameSettingsView: View {
    let game: StoreGame
    let tint: Color
    var installPath: String? = nil
    var store: StoreKind = .steam
    var onClose: () -> Void = {}

    @State private var config: GameConfig
    @State private var profile: CompatProfile?
    @State private var copied = false
    @State private var saveBackupDate: Date?
    @State private var executableError: String?
    @State private var showExecutableOptions = false

    // Carga la config guardada EN EL INIT (no en `onAppear`): así el sheet abre ya con el valor
    // real (antes pintaba un frame con los defaults — "Automático" y toggles por defecto — y saltaba
    // al guardado, un parpadeo visible). También evita el re-guardado redundante que disparaba el
    // `onChange(of: config)` al asignar en `onAppear`.
    init(game: StoreGame, tint: Color, installPath: String? = nil, store: StoreKind = .steam, onClose: @escaping () -> Void = {}) {
        self.game = game
        self.tint = tint
        self.installPath = installPath
        self.store = store
        self.onClose = onClose
        _config = State(initialValue: GameConfigStore.load(game.id))
    }

    private var sbStore: SaveBackupManager.Store {
        switch store { case .steam: return .steam; case .epic: return .epic; case .gog: return .gog; case .local: return .local }
    }
    private var sbId: String { game.steamAppId ?? game.id }
    /// Prefijo Wine, derivado de la ruta de instalación (la parte previa a `/drive_c`).
    private var winePrefix: String? {
        guard let ip = installPath, let r = ip.range(of: "/drive_c") else { return nil }
        return String(ip[..<r.lowerBound])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ajustes del juego").font(.title2.bold()).foregroundStyle(.white)
                    Text(game.title).font(.callout).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cerrar ajustes")
                .vesselHelp("Cerrar ajustes", shortcut: "Esc")
            }
            .padding(.bottom, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let p = profile {
                        compatBadge(p)
                    }

                    section("Capa gráfica") {
                        Text("Cómo se traduce el render del juego a Metal. En automático, Vessel elige la mejor según el juego.")
                            .font(.caption).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                        Picker("", selection: $config.graphicsLayer) {
                            ForEach(GameConfig.GraphicsLayer.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                        Text(config.graphicsLayer.detail)
                            .font(.caption2).foregroundStyle(Theme.secondaryText)
                    }

                    section("Sincronización (rendimiento)") {
                        Toggle("Esync", isOn: $config.esync).tint(tint).foregroundStyle(.white)
                            .vesselHelp("Esync", detail: "Reduce la sobrecarga de sincronización de Wine mediante descriptores de archivo.")
                        Toggle("Fsync", isOn: $config.fsync).tint(tint).foregroundStyle(.white)
                            .vesselHelp("Fsync", detail: "Usa sincronización rápida cuando el motor y el juego son compatibles.")
                    }

                    section("Rendimiento en pantalla") {
                        Toggle("Mostrar HUD de Metal", isOn: $config.metalHUD)
                            .tint(tint).foregroundStyle(.white)
                            .vesselHelp("HUD de rendimiento", detail: "Muestra FPS y tiempos de frame sobre el juego.")
                        Text("Superpone FPS y tiempos de frame en el juego (HUD nativo de Metal). Útil para medir rendimiento; desactívalo para jugar.")
                            .font(.caption2).foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if winePrefix != nil {
                        section("Copias de partida") {
                            Text("Vessel respalda tu partida al cerrar el juego y la restaura si la copia es más nueva. Solo copia; nunca borra.")
                                .font(.caption).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(Theme.secondaryText)
                                Text(saveBackupDate.map { "Última copia: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Aún sin copias.")
                                    .font(.caption2).foregroundStyle(Theme.secondaryText)
                            }
                            HStack(spacing: 10) {
                                Button {
                                    Task {
                                        if let prefix = winePrefix {
                                            await SaveBackupManager.shared.backup(store: sbStore, id: sbId, title: game.title,
                                                                                  steamId: game.steamAppId, prefix: prefix, installPath: installPath)
                                            saveBackupDate = SaveBackupManager.shared.lastBackupDate(store: sbStore, id: sbId)
                                        }
                                    }
                                } label: { Label("Hacer copia ahora", systemImage: "arrow.down.doc").frame(maxWidth: .infinity) }
                                .vesselButton(false)
                                .vesselHelp("Crear una copia de la partida ahora")

                                Button {
                                    if let f = SaveBackupManager.shared.backupsFolder(store: sbStore, id: sbId) {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)])
                                    }
                                } label: { Label("Ver copias", systemImage: "folder").frame(maxWidth: .infinity) }
                                .vesselButton(false)
                                .disabled(saveBackupDate == nil)
                                .vesselHelp("Mostrar las copias de partida en Finder")
                            }
                        }
                    }

                    if game.steamAppId != nil {
                        section("Nube de Steam y actualizaciones") {
                            Text("En **modo Steam real**, Vessel abre el cliente de Steam conectado y lanza el juego con él: obtienes la **nube de Steam (Steam Cloud)**, actualizaciones, DLC y logros NATIVOS —como en un PC, igual que CrossOver—. En **modo Vessel** (por defecto) el juego usa el motor gráfico óptimo (mejor rendimiento; p. ej. Palworld por D3DMetal) y tus partidas se respaldan con la copia local de arriba.")
                                .font(.caption).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                            Toggle("Modo Steam real (nube de Steam, actualizaciones, DLC y logros)", isOn: $config.useRealSteam)
                                .tint(tint).foregroundStyle(.white)
                                .vesselHelp("Modo Steam real", detail: "Lanza con el cliente de Steam para usar sus servicios nativos.")
                            Text(config.useRealSteam
                                 ? "Activo: el juego corre con el cliente de Steam (motor unificado) y Steam sincroniza tus partidas en la nube. El render puede diferir del modo Vessel óptimo."
                                 : "Modo Vessel: motor gráfico óptimo por juego + tu copia de partida local (arriba). La nube de Steam es opcional (abajo).")
                                .font(.caption2).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                            if !config.useRealSteam {
                                Divider().overlay(.white.opacity(0.06)).padding(.vertical, 2)
                                Toggle("Sincronizar con Steam Cloud (experimental)", isOn: $config.steamCloudSync)
                                    .tint(tint).foregroundStyle(.white)
                                    .vesselHelp("Steam Cloud experimental", detail: "Sincroniza antes y después de jugar manteniendo el motor óptimo de Vessel.")
                                Text("Mantiene el motor gráfico óptimo (Modo Vessel) Y sincroniza tu partida con la nube de Steam: Vessel abre el cliente en 2º plano antes de jugar (baja lo último) y al salir (sube los cambios). Tu copia local sigue como red de seguridad.")
                                    .font(.caption2).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if let path = installPath, !path.isEmpty {
                        if supportsExecutableOverride {
                            section("Avanzado") {
                                DisclosureGroup(isExpanded: $showExecutableOptions) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("Vessel elige automáticamente el cliente correcto. Si un juego abre un launcher incompatible, puedes señalar aquí su .exe principal de 64 bits.")
                                            .font(.caption).foregroundStyle(Theme.secondaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                        HStack(spacing: 10) {
                                            Image(systemName: "terminal")
                                                .foregroundStyle(tint)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(selectedExecutableName)
                                                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                                                    .lineLimit(1).truncationMode(.middle)
                                                Text(config.executableOverride == nil ? "Detectado automáticamente" : "Selección manual")
                                                    .font(.caption2).foregroundStyle(Theme.secondaryText)
                                            }
                                            Spacer()
                                        }
                                        .padding(10)
                                        // Velo sutil, sin vidrio sobre vidrio.
                                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

                                        HStack(spacing: 10) {
                                            Button("Elegir otro…", action: chooseExecutableOverride)
                                                .vesselButton(false)
                                            if config.executableOverride != nil {
                                                Button("Restaurar automático") {
                                                    config.executableOverride = nil
                                                    executableError = nil
                                                }
                                                .buttonStyle(.plain)
                                                .foregroundStyle(tint)
                                            }
                                        }
                                        if let executableError {
                                            Label(executableError, systemImage: "exclamationmark.triangle.fill")
                                                .font(.caption2).foregroundStyle(.orange)
                                        }
                                        Text("Por seguridad solo se admiten archivos .exe situados dentro de la carpeta instalada.")
                                            .font(.caption2).foregroundStyle(Theme.secondaryText)
                                    }
                                    .padding(.top, 8)
                                } label: {
                                    Label("Ejecutable alternativo", systemImage: "terminal")
                                        .font(.callout.weight(.semibold)).foregroundStyle(.white)
                                }
                                .tint(tint)
                            }
                        }

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } label: {
                            Label("Abrir carpeta del juego", systemImage: "folder").frame(maxWidth: .infinity)
                        }
                        .vesselButton(false)
                        .vesselHelp("Mostrar la carpeta instalada en Finder")
                    }

                    HStack(spacing: 10) {
                        Button {
                            let store = game.steamAppId != nil ? "steam" : "otra"
                            if let url = CompatService.reportIssueURL(
                                gameTitle: game.title, store: store, storeId: game.steamAppId ?? game.id) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Reportar en GitHub", systemImage: "exclamationmark.bubble")
                                .frame(maxWidth: .infinity)
                        }
                        .vesselButton(false)
                        .vesselHelp("Preparar un reporte anónimo de compatibilidad en GitHub")

                        Button {
                            let store = game.steamAppId != nil ? "steam" : "otra"
                            let body = CompatService.reportBody(
                                gameTitle: game.title, store: store, storeId: game.steamAppId ?? game.id)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(body, forType: .string)
                            withAnimation { copied = true }
                        } label: {
                            Label(copied ? "¡Copiado!" : "Copiar (anónimo)",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .vesselButton(false)
                        .vesselHelp("Copiar un reporte anónimo al portapapeles")
                    }
                    Label("Reporte anónimo: solo el juego, tu sistema (macOS/chip) y tus notas. No se envía ningún dato personal ni se sube nada automáticamente.",
                          systemImage: "lock.shield")
                        .font(.caption2).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(28)
        .frame(width: 580, height: 560)
        .vesselBackground(tint: tint)
        .onAppear {
            // `config` ya se cargó en el init (sin flash). Aquí solo lo que no bloquea el primer frame.
            profile = CompatService.shared.profile(steam: game.steamAppId, title: game.title)
            saveBackupDate = SaveBackupManager.shared.lastBackupDate(store: sbStore, id: sbId)
        }
        .onChange(of: config) { _, new in GameConfigStore.save(game.id, new) }
    }

    private var supportsExecutableOverride: Bool {
        guard let installPath, !installPath.isEmpty else { return false }
        if store != .local { return true }
        guard let executable = game.executablePath, !executable.isEmpty else { return false }
        return (executable as NSString).pathExtension.caseInsensitiveCompare("exe") == .orderedSame
    }

    private var selectedExecutableName: String {
        ((config.executableOverride ?? game.executablePath ?? "Automático") as NSString).lastPathComponent
    }

    private func chooseExecutableOverride() {
        guard let installPath, !installPath.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Elegir ejecutable del juego"
        panel.message = "Selecciona el ejecutable principal dentro de la carpeta instalada."
        panel.prompt = "Usar ejecutable"
        panel.directoryURL = URL(fileURLWithPath: installPath, isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let executableType = UTType(filenameExtension: "exe") {
            panel.allowedContentTypes = [executableType]
        }
        guard panel.runModal() == .OK, let selected = panel.url else { return }

        switch GameExecutableOverride.validate(selected.path, installRoot: installPath) {
        case .success(let executable):
            config.executableOverride = executable
            executableError = nil
        case .failure(let error):
            executableError = error.localizedDescription
        }
    }

    /// Insignia de compatibilidad (rating de la comunidad) + notas del perfil.
    @ViewBuilder
    private func compatBadge(_ p: CompatProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: p.rating.systemImage)
                    .font(.title3).foregroundStyle(p.rating.color)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Compatibilidad: \(p.rating.label)")
                            .font(.callout.bold()).foregroundStyle(.white)
                        if p.verified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2).foregroundStyle(p.rating.color)
                        }
                    }
                    Text(p.rating.detail)
                        .font(.caption2).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if !p.verified {
                    Text("Sin verificar")
                        .font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
            }
            if let notes = p.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(p.rating.color.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(tint)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
