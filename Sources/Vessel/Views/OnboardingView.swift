import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var dependencyManager = DependencyManager()
    @State private var checkResults: [DependencyManager.CheckResult] = []
    @State private var isWorking = true
    @State private var statusText: String = "Configurando tu Mac…"
    @State private var progress: Double = 0
    @State private var logStore = LogStore()
    @State private var setupSucceeded = false

    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VesselIconView(size: 110)
                .symbolEffect(.pulse, options: .repeating, isActive: isWorking)

            Text("Vessel")
                .font(.system(size: 32, weight: .bold))

            VStack(spacing: 4) {
                Text(statusText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                if isWorking {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .frame(maxWidth: 320)
                        .padding(.top, 8)
                }
            }

            if !isWorking {
                statusList
            }

            Spacer()

            if !isWorking {
                Button {
                    if setupSucceeded {
                        onComplete()
                        dismiss()
                    } else {
                        Task { await runOnboarding() }
                    }
                } label: {
                    Text(setupSucceeded ? "Empezar a usar Vessel" : "Reintentar instalación automática")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.premium())
                .keyboardShortcut(.defaultAction)
                .padding(.horizontal, 32)
            }
        }
        .frame(width: 560, height: 520)
        .vesselBackground()
        .task { await runOnboarding() }
    }

    private var statusList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(checkResults, id: \.dependency.id) { result in
                HStack(spacing: 8) {
                    Image(systemName: result.installed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(result.installed ? .green : .orange)
                        .frame(width: 16)
                    Text(result.dependency.rawValue).font(.callout)
                    if let note = result.note {
                        Text("· \(note)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .padding(.horizontal, 32)
    }

    /// Onboarding totalmente automático: cero clicks, cero pantallas,
    /// cero permisos del usuario. Solo progreso visual.
    private func runOnboarding() async {
        isWorking = true
        setupSucceeded = false
        logStore.log("Iniciando onboarding de Vessel")

        // 1. Comprobar estado actual
        statusText = "Comprobando tu sistema…"
        progress = 0.1
        checkResults = await dependencyManager.checkAll()
        logStore.log("Estado inicial: \(checkResults.map { "\($0.dependency.rawValue)=\($0.installed ? "OK" : "FALTA")" }.joined(separator: ", "))")

        // 2. Instalar Rosetta si falta (para Wine Intel, por compatibilidad)
        if !(checkResults.first(where: { $0.dependency == .rosetta })?.installed ?? true) {
            statusText = "Instalando Rosetta 2 (requerido para apps Intel)…"
            progress = 0.25
            logStore.log("Rosetta no detectado, instalando…")
            do {
                try await dependencyManager.installRosetta()
                logStore.log("✓ Rosetta instalado", level: .info)
            } catch {
                logStore.log("No se pudo instalar Rosetta automáticamente: \(error.localizedDescription). Se intentará más tarde si es necesario.", level: .warn)
            }
        }

        // 3. Descargar Wine portable si falta (la pieza clave)
        let wineResult = checkResults.first(where: { $0.dependency == .winePortable })
        if !(wineResult?.installed ?? false) {
            statusText = "Descargando Wine portable (no toca /Applications, no requiere sudo)…"
            progress = 0.5
            logStore.log("Wine portable no encontrado, descargando desde Gcenx/macOS_Wine_builds…")
            do {
                _ = try await dependencyManager.ensureWinePortableInstalled { msg, p in
                    Task { @MainActor in
                        statusText = msg
                        progress = 0.5 + (p * 0.4)
                    }
                }
                logStore.log("✓ Wine portable listo", level: .info)
            } catch {
                logStore.log("Error descargando Wine: \(error.localizedDescription)", level: .error)
            }
        }

        // 4. Verificación final
        statusText = "Verificación final…"
        progress = 0.95
        checkResults = await dependencyManager.checkAll()
        let wineReady = checkResults.first(where: { $0.dependency == .winePortable })?.installed ?? false
        setupSucceeded = wineReady
        logStore.log("Onboarding completado. Wine listo: \(wineReady ? "SÍ" : "NO")")

        statusText = wineReady ? "Todo listo" : "No se pudo instalar Wine automáticamente. Revisa tu conexión y vuelve a intentarlo."
        progress = 1.0
        isWorking = false
    }
}
