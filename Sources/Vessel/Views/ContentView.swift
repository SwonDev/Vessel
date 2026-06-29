import SwiftUI

struct ContentView: View {
    @State private var selectedStore: StoreKind = .steam
    @State private var showingSettings = false
    @State private var showingLogs = false
    @State private var showingAbout = false
    @State private var showingCreateSheet = false

    var body: some View {
        NavigationSplitView {
            StoreSidebar(selection: $selectedStore)
        } detail: {
            detailView
                .id(selectedStore)
                .transition(.opacity)
        }
        .navigationTitle("Vessel")
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.28), value: selectedStore)
        .toolbar {
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
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingLogs) { LogsView() }
        .sheet(isPresented: $showingAbout) { AboutView() }
        .sheet(isPresented: $showingCreateSheet) { CreateBottleView() }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in showingSettings = true }
        .onReceive(NotificationCenter.default.publisher(for: .openLogs)) { _ in showingLogs = true }
        .onReceive(NotificationCenter.default.publisher(for: .openAbout)) { _ in showingAbout = true }
        .onReceive(NotificationCenter.default.publisher(for: .createBottle)) { _ in showingCreateSheet = true }
    }

    @ViewBuilder private var detailView: some View {
        switch selectedStore {
        case .steam:
            SteamStoreView()
        default:
            StoreConnectView(store: selectedStore)
        }
    }
}

#Preview {
    ContentView()
}
