import SwiftUI
import AppKit

extension Notification.Name {
    static let steamLogin = Notification.Name("vessel.steamLogin")
    static let steamLogout = Notification.Name("vessel.steamLogout")
    static let steamRefresh = Notification.Name("vessel.steamRefresh")
}

/// Las **tiendas** que Vessel integra. La sidebar muestra estas (no "bottles"): el
/// usuario entra en una tienda, inicia sesión y ve/gestiona su biblioteca. El
/// concepto de bottle queda oculto (una automática por tienda). Modelo Heroic/Mythic,
/// con Steam de primera clase. Ver [[vessel-filosofia-ux]].
enum StoreKind: String, CaseIterable, Identifiable {
    case steam, epic, gog

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .steam: return "Steam"
        case .epic: return "Epic Games"
        case .gog: return "GOG"
        }
    }

    /// SF Symbol representativo (sin depender de logos externos).
    var symbol: String {
        switch self {
        case .steam: return "gamecontroller.fill"
        case .epic: return "e.circle.fill"
        case .gog: return "g.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .steam: return Color(red: 0.10, green: 0.55, blue: 0.85)
        case .epic: return Color(white: 0.55)
        case .gog: return Color(red: 0.60, green: 0.25, blue: 0.75)
        }
    }

    /// Steam, Epic y GOG están integradas (modelo Heroic).
    var isAvailable: Bool { true }

    /// Nombre del PNG del **logo oficial** de la tienda (en el bundle, ver Resources/StoreLogos).
    var logoAsset: String {
        switch self {
        case .steam: return "store-steam"
        case .epic: return "store-epic"
        case .gog: return "store-gog"
        }
    }
}

/// Caché de los logos oficiales de tienda cargados del bundle (evita releer disco
/// en cada redibujado/hover de la sidebar).
@MainActor
enum StoreLogo {
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}

/// Insignia grande de marca: **logo oficial** de la tienda sobre su gradiente, con borde
/// y sombra de color. Es el icono "hero" de las pantallas de conexión y cabeceras de sección.
struct StoreLogoTile: View {
    let store: StoreKind
    var size: CGFloat = 128

    var body: some View {
        Group {
            if let logo = StoreLogo.image(store.logoAsset) {
                Image(nsImage: logo).resizable().scaledToFit().padding(size * 0.24)
            } else {
                Image(systemName: store.symbol).font(.system(size: size * 0.46, weight: .medium))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(store.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: store.tint.opacity(0.5), radius: size * 0.2, y: size * 0.09)
    }
}

/// **Selector de tienda del header** (estilo Steam): una fila de iconos con el **logo
/// oficial** de cada tienda (Steam/Epic/GOG). El seleccionado se resalta con cristal
/// tintado del color de la tienda. Sustituye a la antigua sidebar de tiendas — ahora la
/// sidebar son los JUEGOS (ver DESIGN.md §7).
struct StoreSwitcher: View {
    @Binding var selection: StoreKind

    var body: some View {
        HStack(spacing: 8) {
            ForEach(StoreKind.allCases) { store in
                StoreSwitchButton(store: store, isSelected: selection == store) {
                    selection = store
                }
            }
        }
        .padding(4)
        .liquidGlass(in: Capsule())
    }
}

/// Botón individual del `StoreSwitcher`: logo de la tienda con estado seleccionado
/// (gradiente del `tint` + sombra de color) y realce al hover (microinteracción premium).
private struct StoreSwitchButton: View {
    let store: StoreKind
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let logo = StoreLogo.image(store.logoAsset) {
                    Image(nsImage: logo).resizable().scaledToFit().padding(7)
                } else {
                    Image(systemName: store.symbol).font(.title3)
                }
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
            .frame(width: 34, height: 34)
            .background {
                if isSelected {
                    Circle().fill(store.tint.gradient)
                } else if hovering {
                    Circle().fill(.white.opacity(0.10))
                }
            }
            .overlay {
                Circle().strokeBorder(.white.opacity(isSelected ? 0.28 : 0), lineWidth: 0.5)
            }
            .shadow(color: isSelected ? store.tint.opacity(0.55) : .clear, radius: 7, y: 2)
            .scaleEffect(hovering && !isSelected ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .help(store.displayName)
        .accessibilityLabel("Tienda \(store.displayName)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// Pantalla de "Conecta tu cuenta" para las tiendas aún no integradas. Mantiene la
/// estética y deja claro el camino (Heroic-style), sin romper nada.
struct StoreConnectView: View {
    let store: StoreKind

    var body: some View {
        VStack(spacing: 22) {
            StoreLogoTile(store: store)

            Text(store.displayName)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)

            Text("Inicia sesión para ver y jugar toda tu biblioteca de \(store.displayName) desde Vessel.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Button {
                // La integración (Legendary/gogdl/…) se conecta aquí.
            } label: {
                Label("Conectar cuenta de \(store.displayName)", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: 320)
                    .padding(.vertical, 4)
            }
            .vesselButton(tint: store.tint)
            .disabled(true)
            .padding(.top, 4)

            Text("Integración en camino — Steam ya está disponible.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesselBackground(tint: store.tint)
    }
}
