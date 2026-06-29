import SwiftUI

/// **Sistema de diseño central de Vessel.** Toda la estética premium vive aquí
/// (radios, materiales, botones con gradiente, elevación en hover, superficies de
/// tarjeta), no dispersa ni duplicada por las vistas. Inspirado en el lenguaje visual
/// de Mythic — esquinas continuas generosas, materiales translúcidos, microinteracciones
/// suaves — adaptado a la identidad multi-tienda de Vessel. Ver [[vessel-reglas-principales]].
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

    /// Color de acento de Vessel (azul eléctrico premium).
    static let accent = Color(red: 0.30, green: 0.56, blue: 1.0)

    /// Gradiente de marca para botones prominentes e iconos hero.
    static func gradient(_ base: Color) -> LinearGradient {
        LinearGradient(colors: [base.opacity(0.96), base.opacity(0.72)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Botón premium

/// Botón con gradiente, borde sutil, sombra de color y respuesta a hover/pressed.
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
                        Color.primary.opacity(hovering ? 0.16 : 0.09)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(.white.opacity(prominent ? 0.22 : 0.0), lineWidth: 0.5)
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
            .shadow(color: .black.opacity(hovering ? 0.34 : 0.16),
                    radius: hovering ? 16 : 7,
                    y: hovering ? 9 : 4)
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

// MARK: - Superficie de tarjeta premium

private struct VesselCard: ViewModifier {
    var padding: CGFloat
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
            }
    }
}

extension View {
    /// Superficie de tarjeta premium: material translúcido + borde sutil + esquinas continuas.
    func vesselCard(padding: CGFloat = 12, cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        modifier(VesselCard(padding: padding, cornerRadius: cornerRadius))
    }
}
