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
    /// Alto de la zona del header (área segura superior), medido en runtime.
    @State private var headerHeight: CGFloat = 52

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
                // Ocultamos el material del toolbar del sistema: la barra de cristal la pone
                // `glassHeader` (abajo), por la que el contenido se refracta al hacer scroll.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        // Mide el alto de la zona del header (área segura superior = toolbar) para que la
        // barra de cristal la cubra exactamente.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { headerHeight = proxy.safeAreaInsets.top }
                    .onChange(of: proxy.safeAreaInsets.top) { _, new in headerHeight = new }
            }
        }
        // Titlebar transparente + contenido a tamaño completo (navy hasta arriba, estilo Mythic).
        .background(VesselWindowStyler())
        // Barra de Liquid Glass en la zona del header: el contenido pasa por DETRÁS (contenido a
        // tamaño completo) y se difumina/refracta al meterse bajo el cristal, mientras el
        // `StoreSwitcher` (toolbar del sistema) queda nítido por encima. Ver DESIGN.md §7 (regla 6).
        .overlay(alignment: .top) {
            glassHeader
                .frame(height: max(headerHeight, 1))
                .ignoresSafeArea(edges: .top)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingLogs) { LogsView() }
        .sheet(isPresented: $showingAbout) { AboutView() }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in showingSettings = true }
        .onReceive(NotificationCenter.default.publisher(for: .openLogs)) { _ in showingLogs = true }
        .onReceive(NotificationCenter.default.publisher(for: .openAbout)) { _ in showingAbout = true }
    }

    /// Barra de **Liquid Glass** en la zona del header. En macOS 26 usa `glassEffect` (refracta y
    /// curva el contenido que pasa por detrás al hacer scroll); en macOS 15 cae a un material
    /// translúcido (blur). No intercepta clics (el contenido y el toolbar siguen siendo usables).
    @ViewBuilder private var glassHeader: some View {
        Group {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: Rectangle())
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .bottom) { headerSeparator }
        .allowsHitTesting(false)
    }

    /// Hairline que separa el header del contenido (borde inferior del cristal). Un degradado
    /// horizontal sutil (más visible en el centro) para un acabado premium, no una línea plana.
    private var headerSeparator: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [.white.opacity(0.02), .white.opacity(0.16), .white.opacity(0.02)],
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
        // Titlebar transparente + contenido a tamaño completo: el sistema no dibuja su propia
        // barra (la pone `glassHeader`) y el contenido sube hasta el borde superior, pasando por
        // DETRÁS del cristal del header al hacer scroll. Fondo navy de respaldo.
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = NSColor(Theme.navyDeep)
        // La ventana se mueve SOLO arrastrando por el header/titlebar (comportamiento estándar de
        // macOS), no desde cualquier punto del contenido. `true` hacía arrastrable todo el fondo,
        // lo que movía la ventana al arrastrar sobre el grid/lista/ficha. Ver DESIGN.md §7.
        window.isMovableByWindowBackground = false
        window.titlebarSeparatorStyle = .none
    }
}

#Preview {
    ContentView()
}
