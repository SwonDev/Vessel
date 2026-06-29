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
        .navigationTitle("Vessel")
        .listStyle(.sidebar)
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
            Image(systemName: store.symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(store.tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: store.tint.opacity(highlighted ? 0.55 : 0.28), radius: highlighted ? 9 : 4, y: 2)
                .scaleEffect(hovering ? 1.06 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(store.displayName).font(.headline)
                Text(store.isAvailable ? "Tienda" : "Próximamente")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
            Image(systemName: store.symbol)
                .font(.system(size: 60, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 128, height: 128)
                .background(store.tint.gradient, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: store.tint.opacity(0.5), radius: 26, y: 12)

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
            .buttonStyle(.premium(tint: store.tint))
            .disabled(true)
            .padding(.top, 4)

            Text("Integración en camino — Steam ya está disponible.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vesselBackground()
    }
}
