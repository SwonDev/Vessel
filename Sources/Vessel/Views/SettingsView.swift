import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var dependencyManager = DependencyManager()
    private var logStore = LogStore.shared
    @State private var checkResults: [DependencyManager.CheckResult] = []
    @State private var wineDownloading = false
    @State private var wineStatusText = ""
    @AppStorage(CompatService.autoUpdateKey) private var compatAutoUpdate = true
    /// Clave Web API de Steam (opcional): habilita iconos por logro y garantiza el estado de logros
    /// aunque el perfil sea privado. Se guarda en `SteamAccountService.webAPIKey`.
    @State private var steamApiKey = SteamAccountService.webAPIKey

    var body: some View {
        VStack(spacing: 0) {
            // Cabecera
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

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    dependenciesSection
                    enginesSection
                    steamAccountSection
                    privacySection
                    aboutSection
                }
                .padding(Theme.Space.section)
            }

            Divider()

            HStack {
                Button("Cerrar") { dismiss() }
                    .vesselButton(false)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(16)
        }
        .frame(width: 640, height: 600)
        .vesselBackground()
        .task { checkResults = await dependencyManager.checkAll() }
    }

    // MARK: - Helpers de sección

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }

    private func storageRow(label: String, path: String) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Secciones

    private var dependenciesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Motores disponibles")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(checkResults, id: \.dependency.id) { result in
                    HStack(spacing: 10) {
                        Image(systemName: result.installed ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(result.installed ? .green : .secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.dependency.rawValue).font(.callout)
                            if let note = result.note {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            } else if let p = result.path {
                                Text(p)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
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
                            .vesselButton()
                        } else if !result.installed, result.dependency == .rosetta {
                            Button("Instalar") { Task { await installRosetta() } }
                                .vesselButton(false)
                        }
                    }
                    .padding(.vertical, 8)
                }
                if !wineStatusText.isEmpty {
                    Text(wineStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }
            .vesselCard(padding: 12)
        }
    }

    private var enginesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Almacenamiento")
            VStack(alignment: .leading, spacing: 0) {
                storageRow(label: "Engines", path: "~/Library/Application Support/Vessel/Engines/")
                storageRow(label: "Bottles", path: "~/Library/Application Support/Vessel/Bottles/")
                storageRow(label: "Logs",    path: "~/Library/Application Support/Vessel/Logs/")
                Button("Abrir carpeta de datos") {
                    let path = "\(NSHomeDirectory())/Library/Application Support/Vessel"
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .vesselButton(false)
                .padding(.top, 6)
            }
            .vesselCard(padding: 12)
        }
    }

    /// Cuenta de Steam: clave Web API opcional para logros completos (iconos + estado garantizado).
    private var steamAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Cuenta de Steam")
            VStack(alignment: .leading, spacing: 10) {
                Text("Clave Web API (opcional)").font(.callout)
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.secondary).font(.caption)
                    SecureField("Pega tu clave de steamcommunity.com/dev/apikey", text: $steamApiKey)
                        .textFieldStyle(.plain)
                        .onChange(of: steamApiKey) { _, new in SteamAccountService.webAPIKey = new }
                    if !steamApiKey.isEmpty {
                        Button { steamApiKey = ""; SteamAccountService.webAPIKey = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                Text("Con la clave (gratis) se ve la lista completa de logros con sus iconos y nombres. Para saber cuáles tienes DESBLOQUEADOS, tu perfil de Steam debe tener «Detalles del juego» en Público (Perfil › Editar perfil › Privacidad).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Obtener mi clave Web API", destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
                    .font(.caption.weight(.medium))
            }
            .vesselCard(padding: 12)
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Privacidad y compatibilidad")
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $compatAutoUpdate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Actualizar la base de datos de compatibilidad").font(.callout)
                        Text("Descarga (solo lectura) los perfiles de la comunidad una vez al día. Desactívalo para funcionar 100% local con la base de datos incluida en la app.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Theme.accent)
                Divider().opacity(0.3)
                Label("Vessel no envía telemetría ni datos personales. Los reportes de compatibilidad son anónimos y solo se publican si tú decides enviarlos manualmente.",
                      systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .vesselCard(padding: 12)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Vessel")
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Versión").font(.callout)
                    Spacer()
                    Text("0.1.0").foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                HStack {
                    Text("Licencia").font(.callout)
                    Spacer()
                    Text("GPL-3.0").foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                HStack(spacing: 8) {
                    Button("Ver logs en vivo") {
                        NotificationCenter.default.post(name: .openLogs, object: nil)
                        dismiss()
                    }
                    .vesselButton(false)
                    Button("Diagnosticar sistema") {
                        Task { checkResults = await dependencyManager.checkAll() }
                    }
                    .vesselButton(false)
                }
                .padding(.top, 6)
            }
            .vesselCard(padding: 12)
        }
    }

    // MARK: - Acciones

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
