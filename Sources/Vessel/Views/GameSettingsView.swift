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
    var onClose: () -> Void = {}

    @State private var config = GameConfig()

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

                    if let path = installPath, !path.isEmpty {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } label: {
                            Label("Abrir carpeta del juego", systemImage: "folder").frame(maxWidth: .infinity)
                        }
                        .vesselButton(false)
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 580, height: 560)
        .vesselBackground(tint: tint)
        .onAppear { config = GameConfigStore.load(game.id) }
        .onChange(of: config) { _, new in GameConfigStore.save(game.id, new) }
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
