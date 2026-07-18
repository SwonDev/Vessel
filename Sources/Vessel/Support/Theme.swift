import SwiftUI
import ColorfulX

/// **Sistema de diseño central de Vessel.** Toda la estética premium vive aquí
/// (paleta, radios, materiales, Liquid Glass, botones, elevación en hover), no dispersa
/// ni duplicada por las vistas.
///
/// Identidad cromática: **azul profundo / navy** — barco, océano, profundidad, confianza —
/// en la línea de Steam pero **muy enfocado al Liquid Glass nativo de SwiftUI**
/// (`glassEffect` en macOS 26, con degradado a materiales translúcidos en macOS 15).
/// Inspirado en el lenguaje visual de Mythic. Ver [[vessel-reglas-principales]].
enum Theme {
    /// Radios de esquina, en una escala coherente para toda la app.
    enum Radius {
        static let cover: CGFloat = 14    // carátulas de juego
        static let card: CGFloat = 16     // tarjetas
        static let control: CGFloat = 10  // botones y campos
        static let panel: CGFloat = 20    // paneles grandes / hero (estilo Mythic)
    }

    /// Espaciados de layout reutilizables.
    enum Space {
        static let gameGrid: CGFloat = 18
        static let section: CGFloat = 24
        static let page: CGFloat = 32
        /// Eleva las acciones de la ficha sobre la imagen, como una franja contextual flotante.
        static let heroActionOverlap: CGFloat = 32
        /// Solape de acciones + 52 pt de aire entre la franja y el título del hero.
        static let heroTitleInset: CGFloat = 84
    }

    // MARK: Paleta navy (barco · océano · profundidad · confianza)

    /// Azul de acento (confianza) — acciones primarias, selección, iconos vivos.
    static let accent      = Color(red: 0.16, green: 0.55, blue: 1.0)
    /// Azul profundo del gradiente de acento.
    static let accentDeep  = Color(red: 0.10, green: 0.36, blue: 0.86)
    /// Navy superior del fondo de la app (más claro).
    static let navyTop     = Color(red: 0.058, green: 0.094, blue: 0.156)
    /// Navy inferior del fondo de la app (océano profundo).
    static let navyDeep    = Color(red: 0.020, green: 0.040, blue: 0.086)
    /// Superficie navy para tarjetas sin glass (fallback / acentos).
    static let surface     = Color(red: 0.10, green: 0.145, blue: 0.225)
    /// Metadatos legibles sobre navy. Token `colors.on-surface-secondary` (#B3BAC7).
    static let secondaryText = Color(red: 0.702, green: 0.729, blue: 0.780)
    /// Acción de juego y estados positivos. Token `colors.play` de DESIGN.md (#57B85C).
    static let play        = Color(red: 0.341, green: 0.722, blue: 0.361)
    /// Errores y acciones destructivas. Token `colors.destructive` de DESIGN.md (#D96652).
    static let destructive = Color(red: 0.851, green: 0.400, blue: 0.322)

    // MARK: Colores de plataforma (tokens `steam`/`epic`/`gog`/`drm-free` de DESIGN.md)

    /// Steam (#1A8CD9).
    static let platformSteam   = Color(red: 0.102, green: 0.549, blue: 0.851)
    /// Epic Games (#8C8C8C).
    static let platformEpic    = Color(white: 0.549)
    /// GOG (#9940BF).
    static let platformGOG     = Color(red: 0.600, green: 0.251, blue: 0.749)
    /// DRM‑free (#CC2B2E).
    static let platformDRMFree = Color(red: 0.800, green: 0.169, blue: 0.180)

    /// Gradiente de marca para botones prominentes e iconos hero (azul confianza → azul profundo).
    static func gradient(_ base: Color = accent) -> LinearGradient {
        LinearGradient(colors: [base.opacity(0.98), accentDeep.opacity(0.92)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Fondo de la app (navy oceánico)

private struct VesselBackground: ViewModifier {
    var tint: Color = Theme.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                LinearGradient(colors: [Theme.navyTop, Theme.navyDeep],
                               startPoint: .top, endPoint: .bottom)
                // Vida premium: gradiente animado con Metal (ColorfulX) MUY sutil, con el color de la
                // tienda. Aditivo y a baja opacidad → el fondo "respira" sin distraer. Se desactiva
                // con reduce-motion.
                if !reduceMotion && !reduceTransparency {
                    ColorfulView(
                        color: .constant([tint.opacity(0.85), Theme.navyDeep, tint.opacity(0.35), Theme.navyTop]),
                        speed: .constant(0.28)
                    )
                    .opacity(0.11)
                    .blendMode(.plusLighter)
                }
                // Resplandor superior con el color de la sección (branding por tienda).
                RadialGradient(colors: [tint.opacity(reduceTransparency ? 0.08 : 0.16), .clear],
                               center: .top, startRadius: 0, endRadius: 640)
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    /// Fondo navy oceánico de Vessel: degradado azul profundo + resplandor superior con
    /// el color de la sección (branding por tienda).
    func vesselBackground(tint: Color = Theme.accent) -> some View { modifier(VesselBackground(tint: tint)) }
}

// MARK: - Liquid Glass nativo (con degradado a materiales)

private struct LiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Theme.surface.opacity(0.98), in: shape)
                .overlay { shape.stroke(.white.opacity(0.16), lineWidth: 0.5) }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(.white.opacity(0.10), lineWidth: 0.5) }
        }
    }
}

extension View {
    /// **Liquid Glass nativo** de SwiftUI (`glassEffect`) en macOS 26; en macOS 15 cae a
    /// un material translúcido con borde sutil. El cristal permanece neutro por contrato;
    /// el color de estado se añade como velo o borde en el componente. Con «Reducir transparencia»
    /// se convierte en una superficie navy opaca y legible.
    func liquidGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(shape: shape, interactive: interactive))
    }

    /// Agrupa efectos de cristal próximos para que macOS 26 los renderice y transforme como un
    /// conjunto coherente. El fallback conserva exactamente el mismo layout en macOS 15.
    @ViewBuilder
    func vesselGlassContainer(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

// MARK: - Botón premium

/// Botón con gradiente navy, borde sutil, sombra de color y respuesta a hover/pressed.
/// Sustituye a `.borderedProminent`/`.bordered` para un acabado premium y consistente.
/// `prominent: false` da una variante de superficie sutil (acciones secundarias).
struct PremiumButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var prominent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        PremiumButtonBody(configuration: configuration, tint: tint, prominent: prominent)
    }

    private struct PremiumButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if prominent {
                        Theme.gradient(tint)
                    } else {
                        Color.white.opacity(hovering ? 0.16 : 0.09)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(.white.opacity(prominent ? 0.24 : 0.08), lineWidth: 0.5)
                }
                .shadow(color: prominent ? tint.opacity(hovering ? 0.55 : 0.32) : .clear,
                        radius: hovering ? 9 : 5, y: hovering ? 4 : 2)
                .brightness(configuration.isPressed ? -0.06 : (hovering ? 0.06 : 0))
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.96 : 1))
                .opacity(isEnabled ? 1 : 0.5)
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: hovering)
                .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.65), value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == PremiumButtonStyle {
    /// Botón premium de Vessel. `tint` colorea la variante prominente; `prominent: false`
    /// usa una superficie sutil para acciones secundarias.
    static func premium(tint: Color = Theme.accent, prominent: Bool = true) -> PremiumButtonStyle {
        PremiumButtonStyle(tint: tint, prominent: prominent)
    }
}

/// Botón **Liquid Glass premium** de Vessel (macOS 26): cristal `.regular` **translúcido** en
/// cápsula (no el relleno sólido de `.glassProminent`, que queda "cantoso"), tintado con `tint`
/// en acciones principales y neutro en secundarias. Refracta lo de detrás y reacciona al press
/// (cristal interactivo) + glow de color y micro-escala en hover. Acabado mucho más premium.
struct GlassButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var prominent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, tint: tint, prominent: prominent)
    }

    private struct GlassButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = Capsule(style: .continuous)
            configuration.label
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background {
                    // El color es solo un ACENTO (velo mínimo + borde), nunca un relleno sólido.
                    if prominent {
                        shape.fill(tint.opacity(hovering ? 0.16 : 0.10))
                    }
                }
                // En un `GlassEffectContainer`, el cristal debe pertenecer al control completo.
                // Aplicarlo a un `Color.clear` de fondo hace que macOS 26 eleve únicamente esa capa
                // durante la composición y puede difuminar la etiqueta situada detrás.
                .liquidGlass(in: shape, interactive: true)
                .overlay { shape.strokeBorder(tint.opacity(prominent ? 0.45 : 0.12), lineWidth: 0.8) }
                .clipShape(shape)
                // Sombra NEUTRA de profundidad (sin glow de color: el aura tintada "cantaba").
                // El color queda solo en el velo + el borde.
                .shadow(color: .black.opacity(hovering ? 0.28 : 0.18),
                        radius: hovering ? 10 : 6, y: hovering ? 4 : 3)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : (hovering ? 1.02 : 1)))
                .opacity(isEnabled ? 1 : 0.5)
                .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.7), value: hovering)
                .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.65), value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(shape)
        }
    }
}

extension View {
    /// Botón canónico de Vessel: **Liquid Glass premium** (`GlassButtonStyle`, cristal `.regular`
    /// translúcido en cápsula) en macOS 26+; en macOS 15 cae al `PremiumButtonStyle` (gradiente).
    /// `prominent` = acción principal (cristal tintado); `prominent: false` = secundaria (cristal
    /// neutro). Usar SIEMPRE este en vez de `.borderedProminent`/`.glassProminent`/`.premium` sueltos.
    @ViewBuilder
    func vesselButton(_ prominent: Bool = true, tint: Color = Theme.accent) -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(GlassButtonStyle(tint: tint, prominent: prominent))
        } else {
            buttonStyle(.premium(tint: tint, prominent: prominent))
        }
    }
}

// MARK: - Ayuda contextual nativa

enum VesselHelpPreference {
    static let defaultsKey = "vessel.tooltipsEnabled"
    static let defaultValue = true
}

private struct VesselHelpModifier: ViewModifier {
    let helpText: Text
    let accessibilityText: Text
    @AppStorage(VesselHelpPreference.defaultsKey) private var tooltipsEnabled =
        VesselHelpPreference.defaultValue

    @ViewBuilder
    func body(content: Content) -> some View {
        if tooltipsEnabled {
            content
                .help(helpText)
                .accessibilityHint(accessibilityText)
        } else {
            // La preferencia solo controla el elemento visual. VoiceOver debe conservar
            // siempre la explicación de la acción, aunque el usuario oculte los tooltips.
            content.accessibilityHint(accessibilityText)
        }
    }
}

extension View {
    /// Tooltip nativo de macOS con microcopy consistente y una pista accesible equivalente.
    /// La ayuda aparece solo tras mantener el cursor y puede desactivarse globalmente en Ajustes.
    /// La pista de VoiceOver permanece activa con independencia de esa preferencia visual.
    func vesselHelp(_ title: String, detail: String? = nil, shortcut: String? = nil) -> some View {
        let parts = [title, detail, shortcut.map { "Atajo: \($0)" }].compactMap { $0 }
        return modifier(VesselHelpModifier(
            helpText: Text(parts.joined(separator: "\n")),
            accessibilityText: Text(detail ?? title)
        ))
    }
}

// MARK: - Elevación en hover

private struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.03
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.40 : 0.20),
                    radius: hovering ? 18 : 8,
                    y: hovering ? 10 : 4)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72), value: hovering)
            .onHover { hovering = $0 }
            .zIndex(hovering ? 1 : 0)
    }
}

extension View {
    /// Eleva el elemento al pasar el cursor (escala + sombra) con un muelle suave.
    func hoverLift(scale: CGFloat = 1.03) -> some View {
        modifier(HoverLift(scale: scale))
    }
}

// MARK: - Superficie de tarjeta premium (Liquid Glass)

extension View {
    /// Superficie de tarjeta premium: **Liquid Glass** translúcido con esquinas continuas
    /// (o material en macOS 15). El acabado lo da `liquidGlass`.
    func vesselCard(padding: CGFloat = 12, cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        self
            .padding(padding)
            .liquidGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
