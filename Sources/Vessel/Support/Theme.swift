import SwiftUI

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

    /// Gradiente de marca para botones prominentes e iconos hero (azul confianza → azul profundo).
    static func gradient(_ base: Color = accent) -> LinearGradient {
        LinearGradient(colors: [base.opacity(0.98), accentDeep.opacity(0.92)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Fondo de la app (navy oceánico)

private struct VesselBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            ZStack {
                LinearGradient(colors: [Theme.navyTop, Theme.navyDeep],
                               startPoint: .top, endPoint: .bottom)
                // Resplandor azul sutil en la parte superior (luz sobre el océano).
                RadialGradient(colors: [Theme.accent.opacity(0.12), .clear],
                               center: .top, startRadius: 0, endRadius: 620)
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    /// Fondo navy oceánico de Vessel: degradado azul profundo + resplandor superior.
    func vesselBackground() -> some View { modifier(VesselBackground()) }
}

// MARK: - Liquid Glass nativo (con degradado a materiales)

extension View {
    /// **Liquid Glass nativo** de SwiftUI (`glassEffect`) en macOS 26; en macOS 15 cae a
    /// un material translúcido con borde sutil. `tint` colorea el cristal (p. ej. el acento
    /// de una tienda); `interactive` activa la respuesta táctil del cristal a la pulsación.
    @ViewBuilder
    func liquidGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let base: Glass = .regular
            let tinted = tint.map { base.tint($0) } ?? base
            let glass = interactive ? tinted.interactive() : tinted
            glassEffect(glass, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(.white.opacity(0.10), lineWidth: 0.5) }
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
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.5)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
                .animation(.spring(response: 0.2, dampingFraction: 0.65), value: configuration.isPressed)
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

// MARK: - Elevación en hover

private struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.03
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.40 : 0.20),
                    radius: hovering ? 18 : 8,
                    y: hovering ? 10 : 4)
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hovering)
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
    func vesselCard(padding: CGFloat = 12, cornerRadius: CGFloat = Theme.Radius.card, tint: Color? = nil) -> some View {
        self
            .padding(padding)
            .liquidGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
    }
}
