import SwiftUI
import DockProgress

@main
struct VesselApp: App {
    @State private var showingOnboarding = false
    @AppStorage("vessel.onboardingCompleted") private var onboardingCompleted = false

    init() {
        VesselPaths.ensureDirectories()
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
            }
        }
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("vessel.openSettings")
    static let openLogs = Notification.Name("vessel.openLogs")
    static let openAbout = Notification.Name("vessel.openAbout")
}
