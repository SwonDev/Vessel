import SwiftUI
import AppKit

/// Raíz de Vessel (layout estilo Steam — ver DESIGN.md §7): el **cambio de tienda vive en
/// el header** (`StoreSwitcher` con los logos de Steam/Epic/GOG) y cada tienda muestra su
/// biblioteca en dos paneles (lista de juegos + ficha). Sin sidebar de tiendas.
struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Acción oficial para abrir la ventana de Ajustes nativa (escena `Settings` de VesselApp).
    @Environment(\.openSettings) private var openSettings
    @State private var selectedStore: StoreKind = .steam
    @State private var profileStore = PlatformProfileStore.shared
    @State private var showingLogs = false
    @State private var showingAbout = false
    @State private var showingShortcutReference = false
    /// Alto de la zona del header (área segura superior), medido en runtime.
    @State private var headerHeight: CGFloat = 52
    /// Aviso de lanzamiento (p. ej. "el juego necesita Steam"): alerta in-app SIEMPRE visible
    /// (las notificaciones del sistema en app firmada ad-hoc no siempre aparecen).
    @State private var showingLaunchAlert = false
    @State private var launchAlertTitle = ""
    @State private var launchAlertBody = ""
    @State private var launchAlertActionTitle: String?
    @State private var launchAlertAction: NotificationService.LaunchAlertAction?
    @State private var launchAlertSteamAppId: String?
    /// Estado EN VIVO no bloqueante (abrir Steam, esperar login…): banner inferior con spinner.
    @State private var launchStatus: String?

    var body: some View {
        NavigationStack {
            activeStore
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Vessel")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        StoreSwitcher(selection: $selectedStore.animation(
                            reduceMotion ? nil : .smooth(duration: 0.28)
                        ))
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let profile = profileStore.profile(for: selectedStore) {
                            PlatformProfileMenu(
                                store: selectedStore,
                                profile: profile,
                                isRefreshing: profileStore.isLoading(selectedStore),
                                onRefreshProfile: {
                                    Task { await profileStore.refresh(selectedStore, force: true) }
                                },
                                onRefreshLibrary: {
                                    NotificationCenter.default.post(name: .libraryRefresh, object: nil)
                                }
                            )
                        }

                        Menu {
                            Button {
                                NotificationCenter.default.post(name: .libraryRefresh, object: nil)
                            } label: {
                                Label("Actualizar biblioteca", systemImage: "arrow.clockwise")
                            }
                            Divider()
                            // Ajustes = ventana NATIVA (escena Settings); se abre con la acción
                            // oficial `openSettings` del entorno (el sendAction anterior con el
                            // selector showSettingsWindow: no llegaba desde el menú de la toolbar).
                            Button("Ajustes…") { openSettings() }
                            Button("Ver logs…") { showingLogs = true }
                            Button("Atajos de teclado…") { showingShortcutReference = true }
                            Divider()
                            Button("Acerca de Vessel") { showingAbout = true }
                        } label: {
                            Label("Más", systemImage: "ellipsis.circle")
                        }
                        .vesselHelp("Más opciones", detail: "Abre ajustes, registros y acciones de la biblioteca.")
                        .accessibilityLabel("Más opciones")
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
        .sheet(isPresented: $showingLogs) { LogsView() }
        .sheet(isPresented: $showingAbout) { AboutView() }
        .sheet(isPresented: $showingShortcutReference) { ShortcutReferenceView() }
        .onReceive(NotificationCenter.default.publisher(for: .openLogs)) { _ in showingLogs = true }
        .onReceive(NotificationCenter.default.publisher(for: .openAbout)) { _ in showingAbout = true }
        .onReceive(NotificationCenter.default.publisher(for: .openShortcutReference)) { _ in
            showingShortcutReference = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectStore)) { note in
            guard let store = note.object as? StoreKind else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) { selectedStore = store }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountProfileDidChange)) { note in
            guard let store = note.object as? StoreKind else { return }
            Task { await profileStore.accountDidChange(store) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await profileStore.refresh(selectedStore) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launchMessage)) { note in
            launchAlertTitle = note.userInfo?["title"] as? String ?? "Vessel"
            launchAlertBody = note.userInfo?["body"] as? String ?? ""
            launchAlertActionTitle = note.userInfo?["actionTitle"] as? String
            launchAlertAction = (note.userInfo?["action"] as? String)
                .flatMap(NotificationService.LaunchAlertAction.init(rawValue:))
            launchAlertSteamAppId = note.userInfo?["steamAppId"] as? String
            showingLaunchAlert = true
            launchStatus = nil   // un aviso terminal oculta el banner de progreso
        }
        .onReceive(NotificationCenter.default.publisher(for: .launchStatus)) { note in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                launchStatus = note.userInfo?["message"] as? String
            }
        }
        .alert(launchAlertTitle, isPresented: $showingLaunchAlert) {
            if let launchAlertActionTitle, let launchAlertAction {
                Button(launchAlertActionTitle) {
                    NotificationService.shared.perform(
                        launchAlertAction,
                        steamAppId: launchAlertSteamAppId
                    )
                }
                Button("Ahora no", role: .cancel) { }
            } else {
                Button("Entendido", role: .cancel) { }
            }
        } message: {
            Text(launchAlertBody)
        }
        // Banner de estado EN VIVO (no bloqueante): el usuario SIEMPRE sabe qué pasa
        // (abriendo Steam, esperando login, reiniciando…). Ver mensaje de la fase actual.
        .overlay(alignment: .bottom) {
            if let launchStatus {
                LaunchStatusBanner(message: launchStatus)
                    .padding(.bottom, 28)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: selectedStore) {
            await profileStore.refresh(selectedStore)
        }
    }

    /// Barra de **Liquid Glass** en la zona del header. En macOS 26 usa `glassEffect` (refracta y
    /// curva el contenido que pasa por detrás al hacer scroll); en macOS 15 cae a un material
    /// translúcido (blur). No intercepta clics (el contenido y el toolbar siguen siendo usables).
    @ViewBuilder private var glassHeader: some View {
        Group {
            if reduceTransparency {
                Theme.navyTop.opacity(0.98)
            } else if #available(macOS 26.0, *) {
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
            case .local: LocalGamesView()
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

/// Banner de estado EN VIVO (no bloqueante) para fases largas de lanzamiento: abrir Steam,
/// esperar el login, reiniciar el cliente… Aparece abajo con un spinner y el mensaje de la
/// fase, para que el usuario SIEMPRE sepa qué está pasando (cero fricción). Estilo Liquid Glass.
private struct LaunchStatusBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 460)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

#Preview {
    ContentView()
}
