import SwiftUI
import DockProgress
import CoreSpotlight

/// AppDelegate para el **menú del Dock** (clic derecho sobre el icono): accesos rápidos
/// contextuales — abrir la app, seguir jugando al último título y buscar actualizaciones.
/// Se construye bajo demanda (cada apertura) para reflejar el estado del momento.
final class VesselAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// Spotlight (Core Spotlight): el usuario abre una ficha de juego directamente desde ⌘Espacio
    /// del sistema. El identificador es "<tienda>:<id>" (el mismo que el indexador).
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return false }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .spotlightOpenGame, object: nil,
                                        userInfo: ["identifier": identifier])
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let abrir = NSMenuItem(title: "Abrir Vessel", action: #selector(abrirVessel), keyEquivalent: "")
        abrir.target = self
        menu.addItem(abrir)

        // «Seguir jugando»: abre el quick open, que ya ordena los jugados recientemente arriba
        // (la tienda dueña del lanzamiento no se acopla al Dock; el quick open es la vía neutra).
        let resume = NSMenuItem(title: "Seguir jugando…", action: #selector(seguirJugando), keyEquivalent: "")
        resume.target = self
        menu.addItem(resume)

        menu.addItem(.separator())
        let updates = NSMenuItem(title: "Buscar actualizaciones…", action: #selector(buscarActualizaciones), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        let ajustes = NSMenuItem(title: "Ajustes…", action: #selector(abrirAjustes), keyEquivalent: ",")
        ajustes.target = self
        menu.addItem(ajustes)
        return menu
    }

    @objc private func abrirVessel() {
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func seguirJugando() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .libraryQuickOpen, object: nil)
    }

    @objc private func buscarActualizaciones() {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            UpdaterManager.shared.checkForUpdates()
        }
    }

    @objc private func abrirAjustes() {
        NSApp.activate(ignoringOtherApps: true)
        // Desde el Dock no hay cadena de respuesta fiable: se intentan ambos selectores
        // (macOS 14+ usa showSettingsWindow:; versiones previas, showPreferencesWindow:).
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

@main
struct VesselApp: App {
    @NSApplicationDelegateAdaptor(VesselAppDelegate.self) private var appDelegate
    @State private var showingOnboarding = false
    @AppStorage("vessel.onboardingCompleted") private var onboardingCompleted = false
    /// Densidad de carátulas compartida con la biblioteca (menú Visualización ↔ toggle del grid).
    @AppStorage("vessel.gridDensity") private var menuGridDensity: GridDensity = .normal

    init() {
        VesselPaths.ensureDirectories()
        // Scrollbars Liquid Glass en TODA la app (SwiftUI ScrollView, List, TextView…).
        NSScrollView.installVesselGlassScrollers()
    }

    private var uiReviewEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["VESSEL_UI_REVIEW"] == "1"
#else
        false
#endif
    }

    var body: some Scene {
        WindowGroup(uiReviewEnabled ? "Vessel — Revisión UI" : "Vessel") {
            windowContent
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            LibraryGameCommands()
            // Menú Archivo: acciones de importación de la biblioteca DRM‑free (antes solo
            // accesibles desde el menú de su toolbar; en macOS viven en Archivo con atajo).
            CommandGroup(replacing: .newItem) {
                Button("Importar un .exe de juego…") {
                    NotificationCenter.default.post(name: .localImportExe, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            // Menú Visualización: densidad de carátulas (compartida con el toggle del grid) y
            // juegos ocultos con atajo.
            CommandGroup(before: .sidebar) {
                Menu("Densidad de carátulas") {
                    ForEach(GridDensity.allCases) { d in
                        Button {
                            menuGridDensity = d
                        } label: {
                            if menuGridDensity == d {
                                Label(d.rawValue, systemImage: "checkmark")
                            } else {
                                Text(d.rawValue)
                            }
                        }
                    }
                }
                Button("Mostrar juegos ocultos") {
                    NotificationCenter.default.post(name: .libraryShowHidden, object: nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
            }
            CommandMenu("Biblioteca") {                Button("Abrir juego rápidamente…") {
                    NotificationCenter.default.post(name: .libraryQuickOpen, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Buscar en la biblioteca") {
                    NotificationCenter.default.post(name: .libraryFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Mostrar u ocultar la lista") {
                    NotificationCenter.default.post(name: .libraryToggleSidebar, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Mostrar todos los juegos") {
                    NotificationCenter.default.post(name: .libraryShowAll, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
                Button("Mostrar juegos ocultos") {
                    NotificationCenter.default.post(name: .libraryShowHidden, object: nil)
                }
                Divider()
                Button("Actualizar biblioteca") {
                    NotificationCenter.default.post(name: .libraryRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Plataforma") {
                Button(StoreKind.steam.displayName) {
                    NotificationCenter.default.post(name: .selectStore, object: StoreKind.steam)
                }
                .keyboardShortcut("1", modifiers: .command)
                Button(StoreKind.epic.displayName) {
                    NotificationCenter.default.post(name: .selectStore, object: StoreKind.epic)
                }
                .keyboardShortcut("2", modifiers: .command)
                Button(StoreKind.gog.displayName) {
                    NotificationCenter.default.post(name: .selectStore, object: StoreKind.gog)
                }
                .keyboardShortcut("3", modifiers: .command)
                Button(StoreKind.local.displayName) {
                    NotificationCenter.default.post(name: .selectStore, object: StoreKind.local)
                }
                .keyboardShortcut("4", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Button("Ver logs…") {
                    NotificationCenter.default.post(name: .openLogs, object: nil)
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("Acerca de Vessel") {
                    NotificationCenter.default.post(name: .openAbout, object: nil)
                }
                Button("Buscar actualizaciones…") {
                    UpdaterManager.shared.checkForUpdates()
                }
            }
            CommandGroup(after: .help) {
                Button("Atajos de teclado…") {
                    NotificationCenter.default.post(name: .openShortcutReference, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }

        // Ventana de Ajustes NATIVA (⌘, automático, pestañas, redimensionable, coexiste con la
        // biblioteca). Antes: sheet modal fija lanzada por notificación.
        Settings {
            SettingsView()
        }
    }

    @ViewBuilder private var windowContent: some View {
#if DEBUG
        if uiReviewEnabled {
            VesselUIReviewView()
                .frame(minWidth: 1024, minHeight: 680)
        } else {
            productionContent
        }
#else
        productionContent
#endif
    }

    private var productionContent: some View {
        ContentView()
            .frame(minWidth: 1024, minHeight: 680)
            .onAppear {
                if !onboardingCompleted {
                    showingOnboarding = true
                }
            }
            .task {
                // El icono del Dock arranca SIEMPRE limpio (por si una instalación quedó a
                // medias en una sesión anterior); el progreso se repinta solo si hay descargas.
                DockProgress.resetProgress()
                // Permiso de notificaciones (descarga lista, update disponible…), una vez.
                NotificationService.shared.requestAuthorization()
                // Arranca Sparkle (comprobación automática de actualizaciones firmadas).
                _ = UpdaterManager.shared
                // Actualiza la BD de compatibilidad desde el repo comunitario (1×/día).
                await CompatService.shared.refreshRemoteIfNeeded()
            }
            .sheet(isPresented: $showingOnboarding) {
                OnboardingView {
                    onboardingCompleted = true
                }
            }
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("vessel.openSettings")
    static let openLogs = Notification.Name("vessel.openLogs")
    static let openAbout = Notification.Name("vessel.openAbout")
    static let openShortcutReference = Notification.Name("vessel.openShortcutReference")
    static let libraryFind = Notification.Name("vessel.libraryFind")
    static let libraryQuickOpen = Notification.Name("vessel.libraryQuickOpen")
    static let libraryToggleSidebar = Notification.Name("vessel.libraryToggleSidebar")
    static let libraryShowAll = Notification.Name("vessel.libraryShowAll")
    static let libraryShowHidden = Notification.Name("vessel.libraryShowHidden")
    static let libraryRefresh = Notification.Name("vessel.libraryRefresh")
    static let selectStore = Notification.Name("vessel.selectStore")
    /// Spotlight abrió un juego. userInfo: identifier ("<tienda>:<id>").
    static let spotlightOpenGame = Notification.Name("vessel.spotlightOpenGame")
    /// Menú Archivo → importar un .exe de juego (lo atiende la sección DRM‑free).
    static let localImportExe = Notification.Name("vessel.localImportExe")
    static let accountProfileDidChange = Notification.Name("vessel.accountProfileDidChange")
    /// Aviso de lanzamiento visible in-app (p. ej. "el juego necesita Steam"). userInfo: title, body.
    static let launchMessage = Notification.Name("vessel.launchMessage")
    /// Estado EN VIVO de lanzamiento (banner no bloqueante). userInfo: message (ausente = ocultar).
    static let launchStatus = Notification.Name("vessel.launchStatus")
}
