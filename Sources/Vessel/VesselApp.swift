import SwiftUI
import DockProgress

@main
struct VesselApp: App {
    @State private var showingOnboarding = false
    @AppStorage("vessel.onboardingCompleted") private var onboardingCompleted = false

    init() {
        VesselPaths.ensureDirectories()
        // Scrollbars Liquid Glass en TODA la app (SwiftUI ScrollView, List, TextView…).
        NSScrollView.installVesselGlassScrollers()
    }

    var body: some Scene {
        WindowGroup("Vessel") {
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
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandMenu("Biblioteca") {
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
            }
            CommandGroup(after: .appSettings) {
                Button("Ajustes…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
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
        }
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("vessel.openSettings")
    static let openLogs = Notification.Name("vessel.openLogs")
    static let openAbout = Notification.Name("vessel.openAbout")
    static let libraryFind = Notification.Name("vessel.libraryFind")
    static let libraryToggleSidebar = Notification.Name("vessel.libraryToggleSidebar")
    static let libraryShowAll = Notification.Name("vessel.libraryShowAll")
    static let libraryShowHidden = Notification.Name("vessel.libraryShowHidden")
    /// Aviso de lanzamiento visible in-app (p. ej. "el juego necesita Steam"). userInfo: title, body.
    static let launchMessage = Notification.Name("vessel.launchMessage")
    /// Estado EN VIVO de lanzamiento (banner no bloqueante). userInfo: message (ausente = ocultar).
    static let launchStatus = Notification.Name("vessel.launchStatus")
}
