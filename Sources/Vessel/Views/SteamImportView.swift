import SwiftUI

struct SteamImportView: View {
    @Environment(\.dismiss) private var dismiss
    let bottle: Bottle
    let onImport: () -> Void

    @State private var importer = SteamLibraryImporter()
    @State private var libraries: [SteamLibraryImporter.SteamLibrary] = []
    @State private var selectedGames: Set<String> = []
    @State private var isScanning = false

    private let store = BottleStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 720, height: 540)
        .task { await scan() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Importar juegos de Steam").font(.title2).fontWeight(.semibold)
                Text("Vessel escanea tu biblioteca de Steam Windows y los añade al bottle «\(bottle.name)»")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await scan() } } label: { Label("Reescanear", systemImage: "arrow.clockwise") }
        }
        .padding(20)
    }

    private var content: some View {
        Group {
            if isScanning {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Buscando Steam en tu sistema…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if libraries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("No se encontró Steam instalado").font(.headline)
                    Text("Instala Steam primero (Windows o Mac) y vuelve aquí")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(libraries, id: \.path) { library in
                        Section(library.path) {
                            ForEach(library.games) { game in
                                gameRow(game)
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(selectedGames.count) seleccionados").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Cancelar") { dismiss() }
                .vesselButton(false)
                .keyboardShortcut(.cancelAction)
            Button { doImport() } label: { Text("Importar") }
                .vesselButton()
                .keyboardShortcut(.defaultAction)
                .disabled(selectedGames.isEmpty)
        }
        .padding(16)
    }

    private func gameRow(_ game: SteamLibraryImporter.ImportedGame) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { selectedGames.contains(game.id) },
                set: { isOn in
                    if isOn { selectedGames.insert(game.id) } else { selectedGames.remove(game.id) }
                }
            )).labelsHidden()
            AsyncImage(url: URL(string: game.coverURL ?? "")) { phase in
                switch phase {
                case .empty: ProgressView().frame(width: 40, height: 60)
                case .success(let image): image.resizable().frame(width: 40, height: 60).clipShape(RoundedRectangle(cornerRadius: 4))
                case .failure: Image(systemName: "gamecontroller").frame(width: 40, height: 60).foregroundStyle(.purple)
                @unknown default: EmptyView()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.headline)
                Text("App ID: \(game.appId)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func scan() async {
        isScanning = true
        libraries = await Task.detached { await MainActor.run { importer.discoverSteamLibraries() } }.value
        isScanning = false
    }

    private func doImport() {
        let gamesToImport = libraries.flatMap { $0.games }.filter { selectedGames.contains($0.id) }
        for game in gamesToImport {
            let new = GameInstall(
                name: game.name,
                executablePath: game.executablePath,
                steamAppId: game.appId,
                installPath: game.installPath,
                coverImageURL: game.coverURL
            )
            store.addGame(new, to: bottle.id)
        }
        onImport()
        dismiss()
    }
}
