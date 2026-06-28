import SwiftUI

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
                .sheet(isPresented: $showingOnboarding) {
                    OnboardingView {
                        onboardingCompleted = true
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Crear bottle nuevo…") {
                    NotificationCenter.default.post(name: .createBottle, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Importar de Steam…") {
                    NotificationCenter.default.post(name: .importSteam, object: nil)
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
            }
        }
    }
}

extension Notification.Name {
    static let createBottle = Notification.Name("vessel.createBottle")
    static let importSteam = Notification.Name("vessel.importSteam")
    static let openSettings = Notification.Name("vessel.openSettings")
    static let openLogs = Notification.Name("vessel.openLogs")
    static let openAbout = Notification.Name("vessel.openAbout")
}
