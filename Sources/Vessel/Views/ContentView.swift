import SwiftUI
import AppKit

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
                // Header navy: oculta el material gris nativo del toolbar para que el
                // fondo `vesselBackground` (navy + resplandor por tienda) fluya por detrás
                // sin costura. Ver DESIGN.md §7 (regla 6 — header navy).
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        // Titlebar transparente + contenido a tamaño completo: el navy de la app sube
        // hasta arriba (estilo Mythic), en vez del gris del sistema. Ver DESIGN.md §7 (regla 6).
        .background(VesselWindowStyler())
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

/// Hace que la barra de título de la ventana respete la **identidad navy** de Vessel en lugar
/// del gris nativo de macOS: titlebar transparente + contenido a tamaño completo, de modo que
/// el `vesselBackground` (navy oceánico + resplandor por tienda) suba por detrás del header
/// sin costura (estilo Mythic). El `backgroundColor` navy es el respaldo para cualquier zona
/// que el contenido no cubra. Ver DESIGN.md §7 (regla 6).
private struct VesselWindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.apply(to: view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView.window) }
    }
    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = NSColor(Theme.navyDeep)
        window.isMovableByWindowBackground = true
    }
}

#Preview {
    ContentView()
}
