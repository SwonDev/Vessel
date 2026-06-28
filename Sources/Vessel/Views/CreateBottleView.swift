import SwiftUI

struct CreateBottleView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var windowsVersion: String = "Windows 11"
    @State private var gptkEnabled: Bool = true
    @State private var dxvkEnabled: Bool = true
    @State private var dxmtEnabled: Bool = false
    @State private var selectedWinePath: String = ""
    @State private var availableWines: [WineInfo] = []
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var installingWine = false
    @State private var didStartAutomaticInstall = false

    private let wineManager = WineManager()
    private let dependencyManager = DependencyManager()
    private let store = BottleStore.shared
    private let windowsVersions = ["Windows 10", "Windows 11", "Windows 7"]

    struct WineInfo: Identifiable, Hashable {
        let id: String
        let name: String
        let path: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 620)
        .onAppear {
            Task { await refreshWines(installIfMissing: true) }
        }
        .background(WindowAccessor())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nuevo bottle").font(.title2).fontWeight(.semibold)
            Text("Un bottle es un entorno Windows aislado donde corren tus juegos.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section(title: "Información") {
                    LabeledRow(label: "Nombre") {
                        TextField("Gaming, Steam, Trabajo", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: "Versión de Windows") {
                        Picker("", selection: $windowsVersion) {
                            ForEach(windowsVersions, id: \.self) { Text($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                section(title: "Motor de Windows") {
                    if availableWines.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(installingWine ? "Instalando motor de Windows" : "No hay motor detectado", systemImage: installingWine ? "arrow.down.circle" : "exclamationmark.triangle")
                                .foregroundStyle(installingWine ? .blue : .orange)
                            Text(installingWine ? "Vessel está descargando y configurando Wine automáticamente." : "Vessel puede descargar y configurar Wine sin tocar /Applications ni pedir pasos manuales.")
                                .font(.caption)
                                    .foregroundStyle(.secondary)
                            Button {
                                Task { await downloadWine() }
                            } label: {
                                if installingWine {
                                    HStack { ProgressView().controlSize(.small); Text("Configurando…") }
                                } else {
                                    Text("Instalar Wine ahora")
                                }
                            }
                            .disabled(installingWine)
                        }
                    } else {
                        Picker("Wine", selection: $selectedWinePath) {
                            ForEach(availableWines) { wine in
                                Text(wine.name).tag(wine.path)
                            }
                        }
                    }
                }

                section(title: "Capa gráfica") {
                    Toggle("Game Porting Toolkit (Apple, nativo ARM)", isOn: $gptkEnabled)
                    Toggle("DXVK (D3D → Vulkan, mejor compatibilidad)", isOn: $dxvkEnabled)
                    Toggle("DXMT (D3D → Metal nativo, mejor rendimiento M-series)", isOn: $dxmtEnabled)
                }

                if let error = errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func LabeledRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 160, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                Task { await create() }
            } label: {
                if isCreating { ProgressView().controlSize(.small) } else { Text("Crear") }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(name.isEmpty || selectedWinePath.isEmpty || isCreating)
        }
        .padding(16)
    }

    private func refreshWines(installIfMissing: Bool = false) async {
        let detected = wineManager.detectWineInstallations()
        availableWines = detected.map { WineInfo(id: $0.path, name: $0.name, path: $0.path) }
        if selectedWinePath.isEmpty || !availableWines.contains(where: { $0.path == selectedWinePath }) {
            selectedWinePath = availableWines.first?.path ?? ""
        }

        if installIfMissing, availableWines.isEmpty, !didStartAutomaticInstall {
            didStartAutomaticInstall = true
            await downloadWine()
        }
    }

    private func downloadWine() async {
        guard !installingWine else { return }
        installingWine = true
        defer { installingWine = false }
        do {
            let winePath = try await dependencyManager.ensureWinePortableInstalled { msg, _ in
                Task { @MainActor in errorMessage = msg }
            }
            await refreshWines()
            selectedWinePath = winePath
            errorMessage = nil
        } catch {
            errorMessage = "No se pudo instalar Wine automáticamente: \(error.localizedDescription)"
        }
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        if selectedWinePath.isEmpty {
            do {
                selectedWinePath = try await dependencyManager.ensureWinePortableInstalled { msg, _ in
                    Task { @MainActor in errorMessage = msg }
                }
                await refreshWines()
            } catch {
                errorMessage = "No se pudo preparar el motor de Windows: \(error.localizedDescription)"
                return
            }
        }

        let bottle = Bottle(
            name: name,
            windowsVersion: windowsVersion,
            dxvkEnabled: dxvkEnabled,
            dxmtEnabled: dxmtEnabled,
            gptkEnabled: gptkEnabled,
            winePath: selectedWinePath
        )

        do {
            try await wineManager.createBottle(at: bottle.prefixPath, winePath: bottle.winePath)
            try await wineManager.configureBottle(bottle)
            store.add(bottle)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Truco para macOS 26: NSWindowDelegate override que filtra errores
/// de data binding de SwiftUI y los reemplaza con un mensaje limpio.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let window = v.window {
                window.title = "Vessel — Nuevo bottle"
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
