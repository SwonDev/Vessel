import SwiftUI
import AppKit

/// Orquesta la conexión a **Epic Games vía Legendary** (modelo Heroic/Mythic):
/// descarga Legendary si es necesario, guía al usuario por el flujo de auth code y,
/// una vez autenticado, expone la biblioteca. Todo lo técnico va por detrás.
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
    /// 1) Descarga Legendary si falta, 2) autentica con el código del portal, 3) carga la biblioteca.
    func connect(code: String) async {
        do {
            // Paso 1: Legendary
            phase = .working("Preparando Legendary…")
            _ = try await legendary.ensureInstalled { msg in
                Task { @MainActor in self.phase = .working(msg) }
            }

            // Paso 2: Autenticación con el código de Epic
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

    /// Abre la página de login de Epic en el navegador predeterminado.
    func openAuthPage() {
        NSWorkspace.shared.open(legendary.authURL)
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
                ConnectEpicView(working: msg, errorMessage: nil, onOpenAuth: {}, onConnect: { _ in })
            case .error(let msg):
                ConnectEpicView(working: nil, errorMessage: msg,
                                onOpenAuth: { epic.openAuthPage() },
                                onConnect:  { code in Task { await epic.connect(code: code) } })
            case .disconnected:
                ConnectEpicView(working: nil, errorMessage: nil,
                                onOpenAuth: { epic.openAuthPage() },
                                onConnect:  { code in Task { await epic.connect(code: code) } })
            }
        }
        .task { epic.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            epic.refresh()
        }
    }
}

// MARK: - Pantalla de conexión (disconnected / error / working)

/// Pantalla "Conecta tu cuenta de Epic Games": guía al usuario en 2 pasos
/// (abrir la web de Epic → pegar el authorization code).
/// Muestra progreso con spinner cuando `working != nil`.
struct ConnectEpicView: View {
    let working: String?
    let errorMessage: String?
    let onOpenAuth: () -> Void
    let onConnect: (String) -> Void

    private let tint = StoreKind.epic.tint
    @State private var authCode = ""
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
                // Pantalla de conexión con los 2 pasos
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

                    // Paso 1 — Abrir página de login
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Paso 1 — Inicia sesión en Epic Games", systemImage: "1.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))

                        Button(action: onOpenAuth) {
                            Label("Abrir inicio de sesión de Epic", systemImage: "safari")
                                .frame(maxWidth: 320)
                                .padding(.vertical, 4)
                        }
                        .vesselButton(tint: tint)

                        Text("Se abrirá el navegador. Tras iniciar sesión, Epic mostrará una página con un texto entre llaves { } (no es un error). Copia solo el valor que aparece después de \u{201C}authorizationCode\u{201D} —los 32 caracteres— y pégalo abajo.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 440, alignment: .leading)

                    // Paso 2 — Pegar el código
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Paso 2 — Pega el código de autorización", systemImage: "2.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))

                        HStack(spacing: 10) {
                            TextField("Pega aquí el authorizationCode…", text: $authCode)
                                .textFieldStyle(.plain)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    .white.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                                )
                                .onSubmit {
                                    let trimmed = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !trimmed.isEmpty else { return }
                                    onConnect(trimmed)
                                }

                            Button {
                                let trimmed = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { return }
                                onConnect(trimmed)
                            } label: {
                                Label("Conectar", systemImage: "person.crop.circle.badge.plus")
                                    .padding(.vertical, 4)
                            }
                            .vesselButton(tint: tint)
                            .disabled(authCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .frame(maxWidth: 440)
                    }
                    .frame(maxWidth: 440, alignment: .leading)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesselBackground(tint: tint)
        .onAppear { pulse = working != nil }
        .onChange(of: working) { _, new in pulse = new != nil }
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
/// El color de fondo se genera deterministamente por hash del `appName` para que sea
/// consistente entre sesiones y no cambie al actualizar la biblioteca.
struct EpicGameCard: View {
    let game: LegendaryManager.EpicGame
    @State private var hovering = false

    /// Color de fondo generado deterministamente por hash del appName del juego.
    private var placeholderColor: Color {
        var h = 5381
        for c in game.appName.unicodeScalars { h = ((h << 5) &+ h) &+ Int(c.value) }
        return Color(hue: Double(abs(h) % 360) / 360.0, saturation: 0.48, brightness: 0.42)
    }

    /// Iniciales del título (máximo 2 palabras, 1 carácter cada una).
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
            // Portada placeholder: degradado de color + iniciales
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

            // Información del juego
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
