import SwiftUI
import AppKit

/// Orquesta la conexión a **Amazon Games vía nile** (modelo Heroic/Mythic):
/// descarga nile si es necesario, guía al usuario por el flujo de auth PKCE de Amazon
/// y, una vez autenticado, expone la biblioteca. Todo lo técnico va por detrás.
///
/// **Flujo de autenticación (PKCE — 2 pasos):**
/// - Paso 1: «Iniciar sesión con Amazon» → nile genera los parámetros PKCE y la URL;
///   Vessel abre el navegador. El usuario se loguea con su cuenta Amazon / Prime Gaming.
/// - Paso 2: Amazon redirige a `https://www.amazon.com` con
///   `openid.oa2.authorization_code=XXXX` en la URL. El usuario copia ese valor y lo
///   pega en el campo de texto de Vessel.
@MainActor
@Observable
final class AmazonStore {
    enum Phase {
        case disconnected
        case working(String)
        /// Sesión PKCE pendiente: nile ya generó la URL, esperamos el código del usuario.
        case awaitingCode(NileManager.AuthSession)
        case connected([NileManager.AmazonGame])
        case error(String)
    }

    var phase: Phase = .disconnected
    private let nile = NileManager()
    private let log  = LogStore.shared

    /// Re-evalúa el estado (al abrir la vista o al recuperar el foco).
    /// No interrumpe una operación en curso.
    func refresh() {
        if case .working = phase     { return }
        if case .awaitingCode = phase { return }
        if case .connected = phase   { return }   // ya cargada: NO recargar al volver el foco

        if nile.isAuthenticated() {
            phase = .working("Cargando biblioteca de Amazon Games…")
            Task { await self.loadLibrary() }
        } else {
            phase = .disconnected
        }
    }

    // MARK: - Flujo de conexión (2 pasos PKCE)

    /// **Paso 1:** Descarga nile si falta, genera la sesión PKCE y abre el navegador.
    /// Tras esto, la fase pasa a `.awaitingCode(session)` para esperar el código.
    func startLogin() async {
        do {
            phase = .working("Preparando nile para Amazon Games…")
            _ = try await nile.ensureInstalled { msg in
                Task { @MainActor in self.phase = .working(msg) }
            }

            phase = .working("Generando sesión de autenticación con Amazon…")
            let session = try await nile.startAuth()

            // Abrir el navegador con la URL de login de Amazon
            NSWorkspace.shared.open(session.url)

            // Transición a pantalla de espera del código
            phase = .awaitingCode(session)
        } catch {
            log.log("Error iniciando login Amazon: \(error.localizedDescription)", level: .error)
            phase = .error(error.localizedDescription)
        }
    }

    /// **Paso 2:** Completa el registro con el authorization code del usuario.
    func complete(code: String, session: NileManager.AuthSession) async {
        do {
            phase = .working("Completando registro con Amazon Games…")
            try await nile.register(code: code, session: session)

            phase = .working("Cargando tu biblioteca de Amazon Games…")
            let games = try await nile.ownedGames()
            phase = .connected(games)
        } catch {
            log.log("Error al autenticar con Amazon Games: \(error.localizedDescription)", level: .error)
            // Volvemos a awaitingCode para que el usuario pueda reintentar con otro código
            // (las sesiones PKCE de nile no expiran de inmediato).
            phase = .error(error.localizedDescription)
        }
    }

    /// Recarga la biblioteca sin pedir autenticación.
    func reloadLibrary() async {
        guard nile.isAuthenticated() else { phase = .disconnected; return }
        phase = .working("Actualizando biblioteca de Amazon Games…")
        await loadLibrary()
    }

    /// Cierra sesión eliminando los archivos de credenciales de nile.
    func disconnect() {
        nile.logout()
        phase = .disconnected
    }

    // MARK: - Privado

    private func loadLibrary() async {
        do {
            let games = try await nile.ownedGames()
            phase = .connected(games)
        } catch {
            log.log("Error cargando biblioteca Amazon: \(error.localizedDescription)", level: .error)
            phase = .error(error.localizedDescription)
        }
    }
}

// MARK: - Vista raíz

/// Vista de la tienda Amazon Games: flujo completo (conexión → auth PKCE → biblioteca).
struct AmazonStoreView: View {
    @State private var amazon = AmazonStore()

    var body: some View {
        Group {
            switch amazon.phase {
            case .connected(let games):
                AmazonLibraryView(
                    games: games,
                    onDisconnect: { amazon.disconnect() },
                    onReload:     { Task { await amazon.reloadLibrary() } }
                )

            case .awaitingCode(let session):
                ConnectAmazonView(
                    phase: .awaitingCode(session),
                    onStartLogin:    { Task { await amazon.startLogin() } },
                    onCompleteLogin: { code in Task { await amazon.complete(code: code, session: session) } }
                )

            case .working(let msg):
                ConnectAmazonView(
                    phase: .working(msg),
                    onStartLogin:    {},
                    onCompleteLogin: { _ in }
                )

            case .error(let msg):
                ConnectAmazonView(
                    phase: .error(msg),
                    onStartLogin:    { Task { await amazon.startLogin() } },
                    onCompleteLogin: { code in
                        // En caso de error, intentamos recuperar desde el estado inicial
                        Task { await amazon.startLogin() }
                        _ = code // El código anterior puede haber caducado; reiniciamos el flujo
                    }
                )

            case .disconnected:
                ConnectAmazonView(
                    phase: .disconnected,
                    onStartLogin:    { Task { await amazon.startLogin() } },
                    onCompleteLogin: { _ in }
                )
            }
        }
        .task { amazon.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            amazon.refresh()
        }
    }
}

// MARK: - Pantalla de conexión / progreso / espera de código

/// Pantalla polivalente de conexión a Amazon Games.
/// Gestiona los estados: desconectado · progreso · espera de código PKCE · error.
struct ConnectAmazonView: View {

    /// Estado simplificado (espejo de `AmazonStore.Phase`) para esta vista stateless.
    enum ViewPhase {
        case disconnected
        case working(String)
        case awaitingCode(NileManager.AuthSession)
        case error(String)
    }

    let phase: ViewPhase
    let onStartLogin:    () -> Void
    let onCompleteLogin: (String) -> Void

    private let tint = StoreKind.amazon.tint
    @State private var authCode = ""
    @State private var pulse    = false

    var body: some View {
        VStack(spacing: 22) {
            StoreLogoTile(store: .amazon)
                .scaleEffect(pulse ? 1.08 : 1.0)
                .animation(
                    .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                    value: pulse
                )

            Text("Amazon Games")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)

            switch phase {

            // ────────────── Progreso ──────────────
            case .working(let msg):
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text(msg)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.10), in: Capsule())
                }
                .padding(.top, 4)

            // ────────────── Espera del código PKCE ──────────────
            case .awaitingCode:
                awaitingCodeContent

            // ────────────── Desconectado · Error ──────────────
            case .disconnected, .error:
                disconnectedContent
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesselBackground(tint: tint)
        .onAppear {
            if case .working = phase { pulse = true }
        }
        .onChange(of: isPulsing) { _, new in pulse = new }
    }

    private var isPulsing: Bool {
        if case .working = phase { return true }
        return false
    }

    // MARK: Pantalla «Espera del código»

    @ViewBuilder
    private var awaitingCodeContent: some View {
        VStack(spacing: 20) {
            // Instrucción
            VStack(spacing: 8) {
                Text("Inicio de sesión abierto en el navegador")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Text(
                    "Inicia sesión con tu cuenta Amazon o Prime Gaming. "
                    + "Cuando Amazon te redirija, copia el valor de "
                    + "«openid.oa2.authorization_code=» que aparece en la URL de tu navegador."
                )
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            }

            // Cajón visual que ilustra dónde mirar en la URL
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("https://www.amazon.com/?…")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("openid.oa2.authorization_code=")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                    + Text("TU-CÓDIGO-AQUÍ")
                        .font(.system(.caption2, design: .monospaced).bold())
                        .foregroundStyle(tint.opacity(0.90))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                .white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
            )
            .frame(maxWidth: 480)

            // Campo + botón
            HStack(spacing: 10) {
                TextField("Código de autorización de Amazon…", text: $authCode)
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
                    .onSubmit { submitCode() }

                Button { submitCode() } label: {
                    Label("Conectar", systemImage: "person.crop.circle.badge.plus")
                        .padding(.vertical, 4)
                }
                .vesselButton(tint: tint)
                .disabled(authCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(maxWidth: 480)

            // Reiniciar flujo (por si la sesión PKCE caducó)
            Button {
                authCode = ""
                onStartLogin()
            } label: {
                Label("Volver a abrir el inicio de sesión", systemImage: "arrow.counterclockwise")
            }
            .vesselButton(false)
        }
    }

    // MARK: Pantalla «Desconectado / Error»

    @ViewBuilder
    private var disconnectedContent: some View {
        VStack(spacing: 20) {
            Text("Conecta tu cuenta de Amazon Games o Prime Gaming para ver y jugar toda tu biblioteca desde Vessel.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            // Mensaje de error (si lo hay)
            if case .error(let msg) = phase {
                Text(msg)
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

            // CTA principal — inicia el flujo PKCE
            Button(action: onStartLogin) {
                Label("Iniciar sesión con Amazon Games", systemImage: "safari")
                    .frame(maxWidth: 320)
                    .padding(.vertical, 4)
            }
            .vesselButton(tint: tint)

            Text("Se abrirá el navegador. Inicia sesión con tu cuenta Amazon o Prime Gaming.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.40))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
    }

    // MARK: Acción

    private func submitCode() {
        let trimmed = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCompleteLogin(trimmed)
    }
}

// MARK: - Biblioteca de Amazon Games

/// Grid de juegos de la cuenta Amazon con búsqueda integrada.
struct AmazonLibraryView: View {
    let games: [NileManager.AmazonGame]
    let onDisconnect: () -> Void
    let onReload: () -> Void

    @State private var searchText = ""
    private let tint    = StoreKind.amazon.tint
    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 200), spacing: Theme.Space.gameGrid)]

    private var filtered: [NileManager.AmazonGame] {
        guard !searchText.isEmpty else { return games }
        return games.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {

                // Cabecera
                HStack(spacing: 14) {
                    StoreLogoTile(store: .amazon, size: 52)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Amazon Games")
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

                // Barra de búsqueda (solo con suficientes juegos)
                if games.count > 6 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.white.opacity(0.40))
                        TextField("Buscar en tu biblioteca de Amazon…", text: $searchText)
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
                        ? "No se encontraron juegos en tu cuenta de Amazon Games."
                        : "Sin resultados para «\(searchText)»."
                    )
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: Theme.Space.gameGrid) {
                        ForEach(filtered) { game in
                            AmazonGameCard(game: game)
                        }
                    }
                }
            }
            .padding(Theme.Space.page)
        }
        .vesselBackground(tint: tint)
    }
}

// MARK: - Tarjeta de juego Amazon

/// Tarjeta de juego de Amazon Games con portada generada a partir del título
/// (degradado de color + iniciales) hasta que se integre la API de imágenes.
/// El color se genera deterministamente por hash del ID del juego para que sea
/// consistente entre sesiones y no cambie al actualizar la biblioteca.
struct AmazonGameCard: View {
    let game: NileManager.AmazonGame
    @State private var hovering = false

    /// Color de fondo generado deterministamente por hash del ID del juego.
    private var placeholderColor: Color {
        var h = 5381
        for c in game.id.unicodeScalars { h = ((h << 5) &+ h) &+ Int(c.value) }
        // Rotamos en el espacio cálido-ámbar de Amazon para coherencia de marca
        let hue = (Double(abs(h) % 240) / 240.0 * 0.20) + 0.04  // 0.04–0.24 (ámbar/naranja/rojo)
        return Color(hue: hue, saturation: 0.55, brightness: 0.38)
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
            // Portada placeholder
            ZStack {
                LinearGradient(
                    colors: [placeholderColor, placeholderColor.opacity(0.50)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                // Icono de Amazon Games como referencia visual de la tienda
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.18))
                    .offset(x: 36, y: 32)

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
            color: placeholderColor.opacity(hovering ? 0.50 : 0.18),
            radius: hovering ? 18 : 6,
            y: hovering ? 9 : 3
        )
        .scaleEffect(hovering ? 1.03 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: hovering)
        .onHover { hovering = $0 }
    }
}
