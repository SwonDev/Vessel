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
    /// Ayudas emergentes visuales en botones y controles. La accesibilidad permanece disponible.
    @AppStorage(VesselHelpPreference.defaultsKey) private var tooltipsEnabled =
        VesselHelpPreference.defaultValue
    /// Modo Steam real GLOBAL: todos los juegos de Steam se lanzan con el cliente de Steam conectado
    /// (nube de Steam/updates/DLC/logros nativos, como CrossOver). Anulable por juego en sus Ajustes.
    @AppStorage("vessel.steamRealGlobal") private var steamRealGlobal = false
    /// Clave Web API de Steam (opcional): habilita iconos por logro y garantiza el estado de logros
    /// aunque el perfil sea privado. Se guarda en `SteamAccountService.webAPIKey`.
    @State private var steamApiKey = SteamAccountService.webAPIKey
    /// Clave de SteamGridDB (opcional, gratis): mejora la calidad de las carátulas. La lee
    /// `SteamGridDBClient` de `UserDefaults` con la misma clave.
    @AppStorage(SteamGridDBClient.apiKeyDefaultsKey) private var steamGridDBKey = ""
    /// Arreglos que Vessel ha aprendido solo (loop local→comunidad); se pueden compartir.
    private var fixesStore = DiscoveredFixesStore.shared

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
                    interfaceSection
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
                    .vesselHelp("Cerrar ajustes", shortcut: "Esc")
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
                            .vesselHelp("Descargar Wine", detail: "Instala el motor portable dentro de Vessel; no modifica macOS.")
                        } else if !result.installed, result.dependency == .rosetta {
                            Button("Instalar") { Task { await installRosetta() } }
                                .vesselButton(false)
                                .vesselHelp("Instalar Rosetta 2", detail: "Necesario para algunos componentes Intel de juegos antiguos.")
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
                storageRow(label: "Motores", path: "~/Library/Application Support/Vessel/Engines/")
                storageRow(label: "Botellas", path: "~/Library/Application Support/Vessel/Bottles/")
                storageRow(label: "Registros", path: "~/Library/Application Support/Vessel/Logs/")
                Button("Abrir carpeta de datos") {
                    let path = "\(NSHomeDirectory())/Library/Application Support/Vessel"
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .vesselButton(false)
                .vesselHelp("Abrir los datos de Vessel en Finder")
                .padding(.top, 6)
            }
            .vesselCard(padding: 12)
        }
    }

    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Interfaz")
            Toggle(isOn: $tooltipsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mostrar ayudas al mantener el cursor")
                        .font(.callout)
                    Text("Enseña explicaciones breves en botones y controles. Puedes ocultarlas sin afectar a VoiceOver.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.accent)
            .vesselHelp(
                tooltipsEnabled ? "Desactivar ayudas emergentes" : "Activar ayudas emergentes",
                detail: "Controla los tooltips visuales de toda la aplicación."
            )
            .vesselCard(padding: 12)
        }
    }

    /// Cuenta de Steam: clave Web API opcional para logros completos (iconos + estado garantizado).
    private var steamAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Cuenta de Steam")
            VStack(alignment: .leading, spacing: 10) {
                if SteamAuthService.storedSessionExpired {
                    Label("Tu sesión de Steam ha caducado. Vuelve a iniciar sesión (botón de Steam, arriba) para ver logros, DLC y la nube de Steam.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().overlay(.white.opacity(0.08)).padding(.vertical, 2)
                }
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
                        .accessibilityLabel("Borrar clave Web API de Steam")
                        .vesselHelp("Borrar clave Web API de Steam")
                    }
                }
                .padding(8)
                .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                Text("Con la clave (gratis) se ve la lista completa de logros con sus iconos y nombres. Para saber cuáles tienes DESBLOQUEADOS, tu perfil de Steam debe tener «Detalles del juego» en Público (Perfil › Editar perfil › Privacidad).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Obtener mi clave Web API", destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
                    .font(.caption.weight(.medium))

                Divider().overlay(.white.opacity(0.08)).padding(.vertical, 4)
                Text("Clave de SteamGridDB (opcional)").font(.callout)
                HStack(spacing: 8) {
                    Image(systemName: "photo.fill").foregroundStyle(.secondary).font(.caption)
                    SecureField("Pega tu clave de steamgriddb.com/profile/preferences/api", text: $steamGridDBKey)
                        .textFieldStyle(.plain)
                    if !steamGridDBKey.isEmpty {
                        Button { steamGridDBKey = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Borrar clave de SteamGridDB")
                        .vesselHelp("Borrar clave de SteamGridDB")
                    }
                }
                .padding(8)
                .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                Text("Con la clave (gratis) las carátulas de tus juegos se ven en alta calidad. Sin ella, la búsqueda de portadas va muy limitada.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Obtener mi clave de SteamGridDB", destination: URL(string: "https://www.steamgriddb.com/profile/preferences/api")!)
                    .font(.caption.weight(.medium))

                Divider().overlay(.white.opacity(0.08)).padding(.vertical, 4)
                Toggle("Modo Steam real para todos los juegos de Steam", isOn: $steamRealGlobal)
                    .font(.callout)
                    .vesselHelp("Usar Steam real por defecto", detail: "Activa Steam Cloud, actualizaciones, DLC y logros nativos; se puede anular por juego.")
                Text("Con esto activado, tus juegos de Steam se lanzan con el cliente de Steam conectado: **nube de Steam (Steam Cloud), actualizaciones, DLC y logros nativos**, igual que CrossOver. Puedes anularlo por juego en sus Ajustes. Nota: usa el motor unificado del cliente Steam; algunos juegos (p. ej. Palworld) rinden mejor en modo Vessel (motor gráfico óptimo + copia de partida local).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                .vesselHelp("Actualización comunitaria de compatibilidad", detail: "Descarga perfiles anónimos una vez al día; desactívalo para uso totalmente local.")
                if !fixesStore.fixes.isEmpty {
                    Divider().opacity(0.3)
                    HStack {
                        Text("Arreglos que Vessel ha aprendido").font(.callout)
                        Spacer()
                        if fixesStore.unsharedCount > 0 {
                            Text("\(fixesStore.unsharedCount) sin compartir")
                                .font(.caption).foregroundStyle(Theme.accent)
                        }
                    }
                    Text("Cuando Vessel repara un juego solo, lo apunta aquí. Compártelo (issue anónimo en la BD comunitaria) para que funcione para todos.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(fixesStore.fixes) { fix in
                        HStack(spacing: 8) {
                            Image(systemName: fix.shared ? "checkmark.circle.fill" : "wrench.and.screwdriver")
                                .foregroundStyle(fix.shared ? Theme.play : Theme.accent).font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(fix.title).font(.caption.weight(.medium)).lineLimit(1)
                                Text("\(fix.graphicsLayer)\(fix.useRealSteam ? " · Steam real" : "")")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(fix.shared ? "Compartido" : "Compartir") {
                                if let url = CompatService.shareFixIssueURL(fix) {
                                    NSWorkspace.shared.open(url)
                                    fixesStore.markShared(fix.id)
                                }
                            }
                            .buttonStyle(.plain).font(.caption.weight(.medium))
                            .foregroundStyle(fix.shared ? Color.secondary : Theme.accent)
                            .disabled(fix.shared)
                            .vesselHelp(fix.shared ? "Este arreglo ya está compartido" : "Compartir arreglo anónimo en GitHub")
                        }
                    }
                }
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
                    Text(VesselAppInfo.displayVersion).foregroundStyle(.secondary)
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
                    .vesselHelp("Abrir los registros en vivo")
                    Button("Diagnosticar sistema") {
                        Task { checkResults = await dependencyManager.checkAll() }
                    }
                    .vesselButton(false)
                    .vesselHelp("Volver a comprobar motores y dependencias")
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
