import SwiftUI
import AppKit

/// Orquesta la conexión de la tienda Steam (modelo Heroic): instala el motor y Steam
/// si faltan, abre el login y, una vez con sesión, expone la biblioteca. El usuario
/// solo ve "Conectar Steam" → inicia sesión → juega. Todo el detalle (bottle, Wine,
/// bootstrap) va por detrás. Ver [[vessel-filosofia-ux]].
@MainActor
@Observable
final class SteamStore {
    enum Phase: Equatable {
        case disconnected
        case working(String)
        case connected
    }

    var phase: Phase = .disconnected
    var bottle: Bottle?

    private let wineManager = WineManager()
    private let dependencyManager = DependencyManager()
    private let accountService = SteamAccountService()
    private let store = BottleStore.shared
    private let log = LogStore.shared

    /// Re-evalúa el estado (al abrir la vista o al volver la app a primer plano). No
    /// interrumpe una conexión en curso.
    func refresh() {
        if case .working = phase { return }
        // El bottle de Steam por NOMBRE (no `first`: puede haber bottles de otras tiendas, p. ej. Epic).
        bottle = store.bottles.first(where: { $0.name == "Steam" }) ?? store.bottles.first(where: { FileManager.default.fileExists(atPath: $0.steamPath) })
        if let b = bottle,
           FileManager.default.fileExists(atPath: b.steamPath),
           accountService.detectAccount(bottle: b) != nil {
            phase = .connected
        } else {
            phase = .disconnected
        }
    }

    /// Flujo completo de "Conectar Steam": motor → bottle → Steam → login → biblioteca.
    func connect() async {
        phase = .working("Preparando Vessel…")
        do {
            // 1) Motores de Vessel (Wine). Auto-instalación silenciosa si faltan.
            let gcenx = try await dependencyManager.ensureWinePortableInstalled { msg, _ in
                Task { @MainActor in self.phase = .working(msg) }
            }

            // 2) Entorno (bottle) de Steam. Invisible para el usuario.
            let b: Bottle
            if let existing = store.bottles.first(where: { $0.name == "Steam" }) {
                b = existing
            } else {
                let nb = Bottle(name: "Steam", winePath: gcenx)
                store.add(nb)
                phase = .working("Creando el entorno de Steam…")
                try await wineManager.createBottle(at: nb.prefixPath, winePath: gcenx)
                b = nb
            }
            bottle = b

            // 3) Cliente de Steam instalado.
            if !FileManager.default.fileExists(atPath: b.steamPath) {
                phase = .working("Instalando Steam…")
                try await wineManager.installSteam(bottle: b)
            }

            // 4) Dejar Steam listo y abrir el login (sin pantalla negra).
            try await wineManager.ensureSteamReadyForLogin(in: b) { msg in
                Task { @MainActor in self.phase = .working(msg) }
            }

            // 5) Esperar a que inicies sesión (aparece la cuenta en el prefijo).
            phase = .working("Inicia sesión en la ventana de Steam…")
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if accountService.detectAccount(bottle: b) != nil {
                    store.touch(b.id)
                    phase = .connected
                    NotificationCenter.default.post(name: .accountProfileDidChange, object: StoreKind.steam)
                    return
                }
            }
            phase = .disconnected   // sin login aún; Steam sigue abierto para reintentar
        } catch {
            log.log("Error al conectar Steam: \(error.localizedDescription)", level: .error)
            phase = .disconnected
        }
    }
}

/// Vista de la tienda Steam: pantalla de conexión cuando no hay sesión, y la
/// biblioteca (reutilizando `BottleDetailView`) cuando ya estás conectado.
struct SteamStoreView: View {
    @State private var steam = SteamStore()
    /// Task del flujo de conexión (para poder cancelarlo: la espera de login llega a 240 s).
    @State private var connectTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch steam.phase {
            case .connected:
                if let bottle = steam.bottle {
                    BottleDetailView(bottle: bottle).id(bottle.id)
                } else {
                    ConnectSteamView(working: nil) { connectTask = Task { await steam.connect() } }
                }
            case .working(let msg):
                ConnectSteamView(working: msg, onConnect: {}, onCancel: {
                    connectTask?.cancel()
                    connectTask = nil
                    steam.phase = .disconnected
                })
            case .disconnected:
                ConnectSteamView(working: nil) { connectTask = Task { await steam.connect() } }
            }
        }
        .task { steam.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            steam.refresh()
        }
    }
}

/// Pantalla "Conecta tu cuenta de Steam" (y estado de progreso mientras conecta).
struct ConnectSteamView: View {
    let working: String?
    let onConnect: () -> Void
    /// Cancelación del flujo en curso (instalación de motores + espera de login de hasta 240 s):
    /// sin ella el usuario quedaba atrapado mirando un spinner sin salida.
    var onCancel: (() -> Void)? = nil

    private let tint = StoreKind.steam.tint
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            StoreLogoTile(store: .steam)
                .scaleEffect(pulse && !reduceMotion ? 1.08 : 1.0)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                    value: pulse
                )

            Text("Steam").font(.largeTitle.bold()).foregroundStyle(.white)

            if let working {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text(working)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .liquidGlass(in: Capsule())
                    if let onCancel {
                        Button("Cancelar", action: onCancel)
                            .vesselButton(false, tint: tint)
                            .controlSize(.small)
                            .accessibilityHint("Detiene la conexión y vuelve al inicio")
                    }
                }
                .padding(.top, 4)
            } else {
                Text("Conecta tu cuenta para ver y jugar toda tu biblioteca de Steam desde Vessel. Se instalará Steam si hace falta y se abrirá el inicio de sesión por ti.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)

                Button(action: onConnect) {
                    Label("Conectar Steam", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: 320)
                        .padding(.vertical, 4)
                }
                .vesselButton(tint: tint)
                .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesselBackground(tint: tint)
        .onAppear { pulse = working != nil }
        .onChange(of: working) { _, new in pulse = new != nil }
    }
}
