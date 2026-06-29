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
    case steam, epic, gog, battlenet, amazon

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .steam: return "Steam"
        case .epic: return "Epic Games"
        case .gog: return "GOG"
        case .battlenet: return "Battle.net"
        case .amazon: return "Amazon Games"
        }
    }

    /// SF Symbol representativo (sin depender de logos externos).
    var symbol: String {
        switch self {
        case .steam: return "gamecontroller.fill"
        case .epic: return "e.circle.fill"
        case .gog: return "g.circle.fill"
        case .battlenet: return "b.circle.fill"
        case .amazon: return "a.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .steam: return Color(red: 0.10, green: 0.55, blue: 0.85)
        case .epic: return Color(white: 0.55)
        case .gog: return Color(red: 0.60, green: 0.25, blue: 0.75)
        case .battlenet: return Color(red: 0.0, green: 0.45, blue: 0.85)
        case .amazon: return Color(red: 0.95, green: 0.60, blue: 0.10)
        }
    }

    /// Por ahora Steam es la tienda totalmente funcional. El resto están en camino
    /// (integración Legendary/gogdl/etc.), con su pantalla de conexión preparada.
    var isAvailable: Bool { self == .steam }

    /// Nombre del PNG del **logo oficial** de la tienda (en el bundle, ver Resources/StoreLogos).
    var logoAsset: String {
        switch self {
        case .steam: return "store-steam"
        case .epic: return "store-epic"
        case .gog: return "store-gog"
        case .battlenet: return "store-battlenet"
        case .amazon: return "store-amazon"
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

/// Sidebar de tiendas (sustituye a la lista de bottles, que pasa a ser interna).
struct StoreSidebar: View {
    @Binding var selection: StoreKind

    var body: some View {
        List(StoreKind.allCases, selection: $selection) { store in
            StoreRow(store: store, isSelected: selection == store)
                .tag(store)
                .contextMenu {
                if store == .steam {
                    Button { NotificationCenter.default.post(name: .steamLogin, object: nil) } label: {
                        Label("Iniciar sesión", systemImage: "person.crop.circle")
                    }
                    Button { NotificationCenter.default.post(name: .steamRefresh, object: nil) } label: {
                        Label("Actualizar biblioteca", systemImage: "arrow.clockwise")
                    }
                    Divider()
                    Button(role: .destructive) { NotificationCenter.default.post(name: .steamLogout, object: nil) } label: {
                        Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Text("\(store.displayName) — próximamente")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 9) {
                Group {
                    if let logo = StoreLogo.image("vessel-logo") {
                        Image(nsImage: logo).resizable().scaledToFit()
                    } else {
                        Image(systemName: "sailboat.fill").foregroundStyle(Theme.accent.gradient)
                    }
                }
                .frame(width: 26, height: 26)
                Text("Vessel")
                    .font(.title2.bold())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        .navigationTitle("Vessel")
        .listStyle(.sidebar)
        .tint(Theme.accent)
        .frame(minWidth: 248)
    }
}

/// Fila de tienda en la sidebar: icono con gradiente de marca + sombra, con realce
/// suave al pasar el cursor o estar seleccionada (microinteracción premium).
private struct StoreRow: View {
    let store: StoreKind
    let isSelected: Bool
    @State private var hovering = false

    private var highlighted: Bool { isSelected || hovering }

    var body: some View {
        HStack(spacing: 11) {
            storeIcon
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(store.tint.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                .shadow(color: store.tint.opacity(highlighted ? 0.6 : 0.30), radius: highlighted ? 10 : 5, y: 2)
                .scaleEffect(hovering ? 1.06 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayName).font(.headline)
                Text(store.isAvailable ? "Disponible" : "Próximamente")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(store.isAvailable ? Color(red: 0.30, green: 0.85, blue: 0.55) : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((store.isAvailable ? Color(red: 0.30, green: 0.85, blue: 0.55) : Color.white).opacity(0.14), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }

    /// Logo oficial de la tienda (blanco) o, si no está en el bundle, su SF Symbol.
    @ViewBuilder private var storeIcon: some View {
        if let logo = StoreLogo.image(store.logoAsset) {
            Image(nsImage: logo).resizable().scaledToFit().padding(9)
        } else {
            Image(systemName: store.symbol).font(.title3)
        }
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
