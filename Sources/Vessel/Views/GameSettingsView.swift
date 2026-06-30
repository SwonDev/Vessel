import SwiftUI
import AppKit

/// Configuración POR JUEGO (se aplica al lanzar). Persistida por id de juego en UserDefaults.
struct GameConfig: Codable, Equatable {
    /// Capa de traducción gráfica preferida para este juego.
    enum GraphicsLayer: String, Codable, CaseIterable, Identifiable {
        case auto, dxmt, gptk
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Automático (recomendado)"
            case .dxmt: return "DXMT · D3D11 → Metal"
            case .gptk: return "GPTK / D3DMetal · D3D12 → Metal"
            }
        }
        var detail: String {
            switch self {
            case .auto: return "Vessel detecta la API (D3D9/11/12) y elige la capa óptima por juego."
            case .dxmt: return "Fuerza DXMT. Ideal para juegos modernos D3D11 (Unity, etc.)."
            case .gptk: return "Fuerza GPTK/D3DMetal. Para juegos AAA con DirectX 12 / Agility SDK."
            }
        }
    }
    var graphicsLayer: GraphicsLayer = .auto
    var launchArguments: String = ""
    var esync: Bool = true
    var fsync: Bool = true
    /// Muestra el HUD de rendimiento de Metal (FPS / tiempos de frame) superpuesto en el juego.
    var metalHUD: Bool = false

    init() {}

    enum CodingKeys: String, CodingKey { case graphicsLayer, launchArguments, esync, fsync, metalHUD }

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

/// Ajustes de un juego: capa gráfica, opciones de lanzamiento, sincronización y carpeta.
/// Premium navy + Liquid Glass. Se guarda al instante y se aplica al lanzar el juego.
struct GameSettingsView: View {
    let game: StoreGame
    let tint: Color
    var installPath: String? = nil
    var store: StoreKind = .steam
    var onClose: () -> Void = {}

    @State private var config = GameConfig()
    @State private var profile: CompatProfile?
    @State private var copied = false
    @State private var saveBackupDate: Date?

    private var sbStore: SaveBackupManager.Store {
        switch store { case .steam: return .steam; case .epic: return .epic; case .gog: return .gog }
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
                    Text(game.title).font(.callout).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cerrar ajustes")
            }
            .padding(.bottom, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let p = profile {
                        compatBadge(p)
                    }

                    section("Capa gráfica") {
                        Text("Cómo se traduce el render del juego a Metal. En automático, Vessel elige la mejor según el juego.")
                            .font(.caption).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                        Picker("", selection: $config.graphicsLayer) {
                            ForEach(GameConfig.GraphicsLayer.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                        Text(config.graphicsLayer.detail)
                            .font(.caption2).foregroundStyle(.white.opacity(0.45))
                    }

                    section("Opciones de lanzamiento") {
                        TextField("p. ej. -windowed -novid", text: $config.launchArguments)
                            .textFieldStyle(.plain).foregroundStyle(.white).padding(10)
                            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        Text("Argumentos que se pasan al ejecutable al iniciar.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.45))
                    }

                    section("Sincronización (rendimiento)") {
                        Toggle("Esync", isOn: $config.esync).tint(tint).foregroundStyle(.white)
                        Toggle("Fsync", isOn: $config.fsync).tint(tint).foregroundStyle(.white)
                    }

                    section("Rendimiento en pantalla") {
                        Toggle("Mostrar HUD de Metal", isOn: $config.metalHUD)
                            .tint(tint).foregroundStyle(.white)
                        Text("Superpone FPS y tiempos de frame en el juego (HUD nativo de Metal). Útil para medir rendimiento; desactívalo para jugar.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if winePrefix != nil {
                        section("Copias de partida") {
                            Text("Vessel respalda tu partida al cerrar el juego y la restaura si la copia es más nueva. Solo copia; nunca borra.")
                                .font(.caption).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(.white.opacity(0.5))
                                Text(saveBackupDate.map { "Última copia: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Aún sin copias.")
                                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
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

                                Button {
                                    if let f = SaveBackupManager.shared.backupsFolder(store: sbStore, id: sbId) {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)])
                                    }
                                } label: { Label("Ver copias", systemImage: "folder").frame(maxWidth: .infinity) }
                                .vesselButton(false)
                                .disabled(saveBackupDate == nil)
                            }
                        }
                    }

                    if let path = installPath, !path.isEmpty {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } label: {
                            Label("Abrir carpeta del juego", systemImage: "folder").frame(maxWidth: .infinity)
                        }
                        .vesselButton(false)
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
                    }
                    Label("Reporte anónimo: solo el juego, tu sistema (macOS/chip) y tus notas. No se envía ningún dato personal ni se sube nada automáticamente.",
                          systemImage: "lock.shield")
                        .font(.caption2).foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(28)
        .frame(width: 580, height: 560)
        .vesselBackground(tint: tint)
        .onAppear {
            config = GameConfigStore.load(game.id)
            profile = CompatService.shared.profile(steam: game.steamAppId, title: game.title)
            saveBackupDate = SaveBackupManager.shared.lastBackupDate(store: sbStore, id: sbId)
        }
        .onChange(of: config) { _, new in GameConfigStore.save(game.id, new) }
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
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                if !p.verified {
                    Text("sin verificar")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
            }
            if let notes = p.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption).foregroundStyle(.white.opacity(0.62))
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
