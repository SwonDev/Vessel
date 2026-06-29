import SwiftUI

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
}

/// Sidebar de tiendas (sustituye a la lista de bottles, que pasa a ser interna).
struct StoreSidebar: View {
    @Binding var selection: StoreKind

    var body: some View {
        List(StoreKind.allCases, selection: $selection) { store in
            HStack(spacing: 10) {
                Image(systemName: store.symbol)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(store.tint.gradient, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.displayName).font(.headline)
                    Text(store.isAvailable ? "Tienda" : "Próximamente")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
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
        .navigationTitle("Vessel")
        .listStyle(.sidebar)
        .frame(minWidth: 240)
    }
}

/// Pantalla de "Conecta tu cuenta" para las tiendas aún no integradas. Mantiene la
/// estética y deja claro el camino (Heroic-style), sin romper nada.
struct StoreConnectView: View {
    let store: StoreKind

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: store.symbol)
                .font(.system(size: 64))
                .foregroundStyle(.white)
                .frame(width: 120, height: 120)
                .background(store.tint.gradient, in: RoundedRectangle(cornerRadius: 28))
                .shadow(color: store.tint.opacity(0.4), radius: 20, y: 8)

            Text(store.displayName)
                .font(.largeTitle.bold())

            Text("Inicia sesión para ver y jugar toda tu biblioteca de \(store.displayName) desde Vessel.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button {
                // La integración (Legendary/gogdl/…) se conecta aquí.
            } label: {
                Label("Conectar cuenta de \(store.displayName)", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: 320)
                    .padding(.vertical, 4)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(store.tint)
            .disabled(true)

            Text("Integración en camino — Steam ya está disponible.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
