import SwiftUI

struct ContentView: View {
    @State private var showingCreateSheet = false
    @State private var showingImportSheet = false
    @State private var showingSettings = false
    @State private var showingLogs = false
    @State private var showingAbout = false
    @State private var selectedBottleID: UUID?

    private let store = BottleStore.shared

    var sortedBottles: [Bottle] {
        store.bottles.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    var selectedBottle: Bottle? {
        sortedBottles.first(where: { $0.id == selectedBottleID }) ?? sortedBottles.first
    }

    var body: some View {
        NavigationSplitView {
            BottleSidebar(bottles: sortedBottles, selectedBottleID: $selectedBottleID)
        } detail: {
            if let bottle = selectedBottle {
                BottleDetailView(bottle: bottle)
            } else {
                EmptyStateView(onCreate: { showingCreateSheet = true })
            }
        }
        .navigationTitle("Vessel")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingCreateSheet = true } label: {
                    Label("Nuevo bottle", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingImportSheet = true } label: {
                    Label("Importar Steam", systemImage: "tray.and.arrow.down")
                }
                .disabled(store.bottles.isEmpty)
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
        .sheet(isPresented: $showingCreateSheet) { CreateBottleView() }
        .sheet(isPresented: $showingImportSheet) {
            if let bottle = selectedBottle {
                SteamImportView(bottle: bottle) { showingImportSheet = false }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingLogs) { LogsView() }
        .sheet(isPresented: $showingAbout) { AboutView() }
        .onReceive(NotificationCenter.default.publisher(for: .createBottle)) { _ in
            showingCreateSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .importSteam)) { _ in
            if !store.bottles.isEmpty { showingImportSheet = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openLogs)) { _ in
            showingLogs = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAbout)) { _ in
            showingAbout = true
        }
    }
}

#Preview {
    ContentView()
}
