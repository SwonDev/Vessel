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
                // Línea sutil en el borde inferior del header: lo diferencia del contenido
                // (estilo Steam). El separador nativo no se ve con el titlebar transparente.
                .overlay(alignment: .top) { headerSeparator }
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
                // Header navy con efecto "scroll edge": el toolbar usa su material AUTOMÁTICO
                // (transparente arriba del todo, cristal al hacer scroll). Sobre el fondo navy
                // de la ventana queda como **cristal navy** (no gris). El blur del contenido que
                // se mete por detrás = el glow Liquid Glass que buscamos. Ver DESIGN.md §7 (regla 6).
                .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
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

    /// Hairline que separa el header del contenido (borde inferior del toolbar). Un degradado
    /// horizontal sutil (más visible en el centro) para un acabado premium, no una línea plana.
    private var headerSeparator: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [.white.opacity(0.02), .white.opacity(0.14), .white.opacity(0.02)],
                startPoint: .leading, endPoint: .trailing))
            .frame(height: 1)
            .allowsHitTesting(false)
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
        // Línea sutil bajo el header para diferenciarlo del contenido (en vez de la sombra
        // por defecto, que con titlebar transparente apenas se ve).
        window.titlebarSeparatorStyle = .line
    }
}

#Preview {
    ContentView()
}
