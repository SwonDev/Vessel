import SwiftUI
import AppKit

/// Orquesta la conexión a **Epic Games vía Legendary** (modelo Heroic/Mythic):
/// descarga Legendary si es necesario, autentica al usuario mediante un WebView
/// embebido y, una vez autenticado, expone la biblioteca. Todo lo técnico va por detrás.
@MainActor
@Observable
final class EpicStore {
    enum Phase {
        case disconnected
        case working(String)
        case connected([LegendaryManager.EpicGame])
        case error(String)
    }

    var phase: Phase = .disconnected
    private let legendary = LegendaryManager()
    private let log = LogStore.shared

    /// Re-evalúa el estado (al abrir la vista o al volver la app a primer plano).
    /// No interrumpe una operación en curso.
    func refresh() {
        if case .working = phase { return }
        if legendary.isAuthenticated() {
            phase = .working("Cargando biblioteca Epic…")
            Task { await self.loadLibrary() }
        } else {
            phase = .disconnected
        }
    }

    /// Flujo completo de conexión Epic:
    /// 1) Descarga Legendary si falta, 2) autentica con el código del WebView, 3) carga la biblioteca.
    func connect(code: String) async {
        do {
            // Paso 1: Legendary
            phase = .working("Preparando Legendary…")
            _ = try await legendary.ensureInstalled { msg in
                Task { @MainActor in self.phase = .working(msg) }
            }

            // Paso 2: Autenticación con el código capturado por el WebView
            phase = .working("Autenticando con Epic Games…")
            try await legendary.authenticate(code: code)

            // Paso 3: Biblioteca
            phase = .working("Cargando tu biblioteca de Epic Games…")
            let games = try await legendary.ownedGames()
            phase = .connected(games)
        } catch {
            log.log("Error al conectar Epic Games: \(error.localizedDescription)", level: .error)
            phase = .error(error.localizedDescription)
        }
    }

    /// Recarga la biblioteca sin pedir el código de nuevo.
    func reloadLibrary() async {
        guard legendary.isAuthenticated() else { phase = .disconnected; return }
        phase = .working("Actualizando biblioteca Epic…")
        await loadLibrary()
    }

    /// Cierra sesión eliminando la config de Legendary de Vessel.
    func disconnect() {
        legendary.logout()
        phase = .disconnected
    }

    // MARK: - Privado

    private func loadLibrary() async {
        do {
            let games = try await legendary.ownedGames()
            phase = .connected(games)
        } catch {
            log.log("Error cargando biblioteca Epic: \(error.localizedDescription)", level: .error)
            phase = .error(error.localizedDescription)
        }
    }
}

// MARK: - Vista raíz

/// Vista de la tienda Epic Games: pantalla de conexión sin sesión, progreso mientras
/// conecta y biblioteca cuando ya está autenticado.
struct EpicStoreView: View {
    @State private var epic = EpicStore()

    var body: some View {
        Group {
            switch epic.phase {
            case .connected(let games):
                EpicLibraryView(
                    games: games,
                    onDisconnect:    { epic.disconnect() },
                    onReload:        { Task { await epic.reloadLibrary() } }
                )
            case .working(let msg):
                ConnectEpicView(working: msg, errorMessage: nil,
                                onConnect: { _ in })
            case .error(let msg):
                ConnectEpicView(working: nil, errorMessage: msg,
                                onConnect: { code in Task { await epic.connect(code: code) } })
            case .disconnected:
                ConnectEpicView(working: nil, errorMessage: nil,
                                onConnect: { code in Task { await epic.connect(code: code) } })
            }
        }
        .task { epic.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            epic.refresh()
        }
    }
}

// MARK: - Pantalla de conexión (disconnected / error / working)

/// Pantalla "Conecta tu cuenta de Epic Games": muestra un único botón que abre
/// el WebView embebido de login. El código de autorización se captura automáticamente.
/// Muestra progreso con spinner cuando `working != nil`.
struct ConnectEpicView: View {
    let working: String?
    let errorMessage: String?
    let onConnect: (String) -> Void

    private let tint = StoreKind.epic.tint
    @State private var showingLogin = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22) {
            StoreLogoTile(store: .epic)
                .scaleEffect(pulse ? 1.08 : 1.0)
                .animation(
                    .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                    value: pulse
                )

            Text("Epic Games")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)

            if let working {
                // Estado de progreso
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
                        .background(.white.opacity(0.10), in: Capsule())
                }
                .padding(.top, 4)
            } else {
                // Pantalla de conexión con un único botón
                VStack(spacing: 20) {
                    Text("Conecta tu cuenta de Epic Games para ver y jugar toda tu biblioteca desde Vessel.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)

                    // Mensaje de error (si lo hay)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 440)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                .red.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            )
                    }

                    // Único botón: abre el WebView de login dentro de la app
                    Button {
                        showingLogin = true
                    } label: {
                        Label("Iniciar sesión con Epic Games", systemImage: "globe")
                            .frame(maxWidth: 320)
                            .padding(.vertical, 4)
                    }
                    .vesselButton(tint: tint)
                    .padding(.top, 4)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesselBackground(tint: tint)
        .onAppear { pulse = working != nil }
        .onChange(of: working) { _, new in pulse = new != nil }
        // Sheet con el WebView embebido de Epic
        .sheet(isPresented: $showingLogin) {
            EpicWebLoginSheet { code in
                showingLogin = false
                onConnect(code)
            }
        }
    }
}

// MARK: - Sheet de WebView (login de Epic)

/// Sheet que presenta el portal de inicio de sesión de Epic dentro de un WKWebView.
/// Captura el `authorizationCode` automáticamente al terminar el login y llama a
/// `onCodeCaptured` — sin que el usuario vea JSON ni tenga que copiar nada.
struct EpicWebLoginSheet: View {
    let onCodeCaptured: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading     = true
    @State private var webError: String?
    private let tint = StoreKind.epic.tint

    var body: some View {
        VStack(spacing: 0) {
            // Barra de cabecera
            HStack(spacing: 12) {
                StoreLogoTile(store: .epic, size: 28)
                Text("Iniciar sesión — Epic Games")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.navyTop)

            Divider().opacity(0.15)

            ZStack {
                // WebView con el portal de Epic
                EpicLoginWebView(
                    onCodeCaptured: { code in
                        // Código capturado: cerrar sheet y notificar al padre
                        dismiss()
                        onCodeCaptured(code)
                    },
                    onError: { error in
                        webError = error
                        isLoading = false
                    },
                    onLoadingChanged: { loading in
                        if loading { webError = nil }
                        withAnimation(.easeOut(duration: 0.3)) { isLoading = loading }
                    }
                )

                // Overlay de carga inicial
                if isLoading {
                    ZStack {
                        Theme.navyDeep.opacity(0.88)
                        VStack(spacing: 14) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Cargando Epic Games…")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .padding(28)
                        .background(.ultraThinMaterial,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                    }
                    .transition(.opacity)
                }

                // Overlay de error
                if let webError {
                    ZStack {
                        Theme.navyDeep.opacity(0.94)
                        VStack(spacing: 20) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 48))
                                .foregroundStyle(tint.opacity(0.75))
                            Text(webError)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 360)
                            HStack(spacing: 12) {
                                Button("Cerrar") { dismiss() }
                                    .vesselButton(false)
                            }
                        }
                        .padding(36)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: webError)
        }
        .frame(width: 820, height: 640)
        .background(Theme.navyDeep)
    }
}

// MARK: - Biblioteca de Epic Games (connected)

/// Grid de juegos de la cuenta Epic con búsqueda integrada.
struct EpicLibraryView: View {
    let games: [LegendaryManager.EpicGame]
    let onDisconnect: () -> Void
    let onReload: () -> Void

    @State private var searchText = ""
    private let tint = StoreKind.epic.tint
    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 200), spacing: Theme.Space.gameGrid)]

    private var filtered: [LegendaryManager.EpicGame] {
        guard !searchText.isEmpty else { return games }
        return games.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {

                // Cabecera
                HStack(spacing: 14) {
                    StoreLogoTile(store: .epic, size: 52)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Epic Games")
                            .font(.title.bold())
                            .foregroundStyle(.white)
                        Text("\(games.count) juego\(games.count == 1 ? "" : "s") en tu biblioteca")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.50))
                    }

                    Spacer()

                    Button(action: onReload) {
                        Label("Actualizar", systemImage: "arrow.clockwise")
                    }
                    .vesselButton(false)

                    Button(role: .destructive, action: onDisconnect) {
                        Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .vesselButton(false)
                }

                // Barra de búsqueda (solo si hay suficientes juegos)
                if games.count > 6 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.white.opacity(0.40))
                        TextField("Buscar en tu biblioteca de Epic…", text: $searchText)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        .white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    )
                }

                // Grid de juegos
                if filtered.isEmpty {
                    Text(
                        searchText.isEmpty
                        ? "No se encontraron juegos en tu cuenta de Epic Games."
                        : "Sin resultados para «\(searchText)»."
                    )
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: Theme.Space.gameGrid) {
                        ForEach(filtered) { game in
                            EpicGameCard(game: game)
                        }
                    }
                }
            }
            .padding(Theme.Space.page)
        }
        .vesselBackground(tint: tint)
    }
}

// MARK: - Tarjeta de juego Epic

/// Tarjeta de juego de Epic Games con portada generada a partir del título
/// (degradado + iniciales) hasta que se integre la API de imágenes de Epic.
struct EpicGameCard: View {
    let game: LegendaryManager.EpicGame
    @State private var hovering = false

    private var placeholderColor: Color {
        var h = 5381
        for c in game.appName.unicodeScalars { h = ((h << 5) &+ h) &+ Int(c.value) }
        return Color(hue: Double(abs(h) % 360) / 360.0, saturation: 0.48, brightness: 0.42)
    }

    private var initials: String {
        game.title
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [placeholderColor, placeholderColor.opacity(0.50)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Text(initials)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.30), radius: 4, y: 2)
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if game.installed {
                    Label("Instalado", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(red: 0.30, green: 0.85, blue: 0.55))
                } else {
                    Text("En tu biblioteca")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 9)
        }
        .background(
            .white.opacity(hovering ? 0.10 : 0.05),
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(hovering ? 0.20 : 0.08), lineWidth: 0.5)
        )
        .shadow(
            color: placeholderColor.opacity(hovering ? 0.45 : 0.15),
            radius: hovering ? 18 : 6,
            y: hovering ? 9 : 3
        )
        .scaleEffect(hovering ? 1.03 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: hovering)
        .onHover { hovering = $0 }
    }
}
