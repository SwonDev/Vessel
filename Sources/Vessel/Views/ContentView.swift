import SwiftUI

/// Raíz de Vessel (layout estilo Steam — ver DESIGN.md §7): el **cambio de tienda vive en
/// el header** (`StoreSwitcher` con los logos de Steam/Epic/GOG) y cada tienda muestra su
/// biblioteca en dos paneles (lista de juegos + ficha). Sin sidebar de tiendas.
struct ContentView: View {
    @State private var selectedStore: StoreKind = .steam
    @State private var showingSettings = false
    @State private var showingLogs = false
    @State private var showingAbout = false
    @State private var showingCreateSheet = false

    var body: some View {
        NavigationStack {
            activeStore
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Vessel")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        StoreSwitcher(selection: $selectedStore.animation(.smooth(duration: 0.28)))
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Ajustes…") { showingSettings = true }
                            Button("Ver logs…") { showingLogs = true }
                            Divider()
                            Button("Acerca de Vessel") { showingAbout = true }
                        } label: {
                            Label("Más", systemImage: "ellipsis.circle")
                        }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingLogs) { LogsView() }
        .sheet(isPresented: $showingAbout) { AboutView() }
        .sheet(isPresented: $showingCreateSheet) { CreateBottleView() }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in showingSettings = true }
        .onReceive(NotificationCenter.default.publisher(for: .openLogs)) { _ in showingLogs = true }
        .onReceive(NotificationCenter.default.publisher(for: .openAbout)) { _ in showingAbout = true }
        .onReceive(NotificationCenter.default.publisher(for: .createBottle)) { _ in showingCreateSheet = true }
    }

    @ViewBuilder private var activeStore: some View {
        Group {
            switch selectedStore {
            case .steam: SteamStoreView()
            case .epic:  EpicStoreView()
            case .gog:   GogStoreView()
            }
        }
        .id(selectedStore)
        .transition(.opacity)
    }
}

#Preview {
    ContentView()
}
