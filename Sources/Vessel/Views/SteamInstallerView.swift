import SwiftUI
import SwiftData

struct SteamInstallerView: View {
    @Environment(\.dismiss) private var dismiss
    let bottle: Bottle
    let wineManager: WineManager
    let onComplete: () -> Void

    @State private var stage: InstallStage = .ready
    @State private var progress: Double = 0
    @State private var statusText: String = "Listo para descargar Steam"
    @State private var error: String?

    enum InstallStage {
        case ready, downloading, installing, done, failed
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: stageIcon)
                .font(.system(size: 64))
                .foregroundStyle(stageColor)
                .symbolEffect(.pulse, options: .repeating, isActive: stage == .downloading || stage == .installing)

            Text("Instalar Steam en «\(bottle.name)»")
                .font(.title3)
                .fontWeight(.semibold)

            Text(statusText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if stage == .downloading || stage == .installing {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 360)
            }

            if let error = error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack {
                if stage == .ready || stage == .failed {
                    Button("Cancelar") { dismiss() }
                }
                if stage == .ready {
                    Button("Instalar") {
                        Task { await run() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if stage == .done {
                    Button("Cerrar") {
                        onComplete()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                if stage == .failed {
                    Button("Reintentar") {
                        Task { await run() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(32)
        .frame(width: 480, height: 340)
    }

    private var stageIcon: String {
        switch stage {
        case .ready: return "icloud.and.arrow.down"
        case .downloading: return "arrow.down.circle"
        case .installing: return "gearshape.2"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var stageColor: Color {
        switch stage {
        case .ready: return .blue
        case .downloading, .installing: return .orange
        case .done: return .green
        case .failed: return .red
        }
    }

    private func run() async {
        error = nil
        stage = .downloading
        statusText = "Descargando SteamSetup.exe desde el CDN de Valve…"
        progress = 0.1

        do {
            stage = .installing
            statusText = "Ejecutando el instalador dentro del bottle (puede tardar 1-2 minutos)…"
            progress = 0.4

            try await wineManager.installSteam(bottle: bottle)

            progress = 1.0
            stage = .done
            statusText = "Steam instalado correctamente. Ya puedes lanzarlo desde el bottle."
        } catch {
            self.error = error.localizedDescription
            stage = .failed
        }
    }
}
