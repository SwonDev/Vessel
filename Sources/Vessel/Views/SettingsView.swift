import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var dependencyManager = DependencyManager()
    private var logStore = LogStore.shared
    @State private var checkResults: [DependencyManager.CheckResult] = []
    @State private var wineDownloading = false
    @State private var wineStatusText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                dependenciesSection
                enginesSection
                aboutSection
            }
            .formStyle(.grouped)
            .frame(minHeight: 480)
            Divider()
            HStack {
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(16)
        }
        .frame(width: 640, height: 600)
        .task { checkResults = await dependencyManager.checkAll() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ajustes de Vessel")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Todos los motores se descargan y mantienen en segundo plano. No necesitas tocar nada del sistema.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var dependenciesSection: some View {
        Section("Motores disponibles") {
            ForEach(checkResults, id: \.dependency.id) { result in
                HStack {
                    Image(systemName: result.installed ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(result.installed ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(result.dependency.rawValue).font(.callout)
                        if let note = result.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        } else if let p = result.path {
                            Text(p).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    if !result.installed, result.dependency == .winePortable {
                        Button {
                            Task { await downloadWine() }
                        } label: {
                            if wineDownloading {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Descargar")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    } else if !result.installed, result.dependency == .rosetta {
                        Button("Instalar") {
                            Task { await installRosetta() }
                        }
                    }
                }
            }
            if !wineStatusText.isEmpty {
                Text(wineStatusText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var enginesSection: some View {
        Section("Almacenamiento") {
            LabeledContent("Engines") {
                Text("~/Library/Application Support/Vessel/Engines/").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            LabeledContent("Bottles") {
                Text("~/Library/Application Support/Vessel/Bottles/").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            LabeledContent("Logs") {
                Text("~/Library/Application Support/Vessel/Logs/").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Button("Abrir carpeta de datos") {
                let path = "\(NSHomeDirectory())/Library/Application Support/Vessel"
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }

    private var aboutSection: some View {
        Section("Vessel") {
            LabeledContent("Versión", value: "0.1.0")
            LabeledContent("Licencia", value: "GPL-3.0")
            HStack {
                Button("Ver logs en vivo") {
                    NotificationCenter.default.post(name: .openLogs, object: nil)
                    dismiss()
                }
                Button("Diagnosticar sistema") {
                    Task { checkResults = await dependencyManager.checkAll() }
                }
            }
        }
    }

    private func downloadWine() async {
        wineDownloading = true
        wineStatusText = "Descargando Wine portable…"
        defer {
            wineDownloading = false
            wineStatusText = ""
        }
        do {
            _ = try await dependencyManager.ensureWinePortableInstalled { msg, _ in
                Task { @MainActor in wineStatusText = msg }
            }
            checkResults = await dependencyManager.checkAll()
        } catch {
            wineStatusText = "Error: \(error.localizedDescription)"
        }
    }

    private func installRosetta() async {
        do {
            try await dependencyManager.installRosetta()
            checkResults = await dependencyManager.checkAll()
        } catch {
            wineStatusText = "Error: \(error.localizedDescription)"
        }
    }
}
