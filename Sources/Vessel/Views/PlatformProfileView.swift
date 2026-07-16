import SwiftUI
import AppKit

/// Perfil compacto del encabezado, inspirado en la densidad de Steam y acabado con el cristal
/// neutro de Vessel. Solo aparece cuando la plataforma activa tiene una sesión reconocida.
struct PlatformProfileMenu: View {
    let store: StoreKind
    let profile: PlatformAccountProfile
    let isRefreshing: Bool
    let onRefreshProfile: () -> Void
    let onRefreshLibrary: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var showingActions = false

    var body: some View {
        Button { showingActions.toggle() } label: {
            HStack(spacing: 8) {
                PlatformAvatar(store: store, data: profile.avatarData)

                Text(profile.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .frame(maxWidth: 112, alignment: .leading)

                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.7))
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.42))
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .contentShape(Capsule())
            .liquidGlass(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showingActions, arrowEdge: .bottom) {
            profilePopover
        }
        .vesselHelp(
            "Cuenta de \(store.displayName)",
            detail: "\(profile.displayName) · abre el perfil y las acciones de sincronización."
        )
        .accessibilityLabel("Cuenta de \(store.displayName): \(profile.displayName)")
    }

    private var profilePopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PlatformAvatar(store: store, data: profile.avatarData, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.headline)
                    Text(store.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Divider()

            if let profileURL = profile.profileURL {
                Button {
                    showingActions = false
                    openURL(profileURL)
                } label: {
                    Label("Abrir perfil público", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .vesselButton(false, tint: store.tint)
            }

            Button {
                onRefreshProfile()
            } label: {
                Label(isRefreshing ? "Actualizando perfil…" : "Actualizar perfil",
                      systemImage: "person.crop.circle.badge.clock")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .vesselButton(false, tint: store.tint)
            .disabled(isRefreshing)

            Button {
                showingActions = false
                onRefreshLibrary()
            } label: {
                Label("Actualizar biblioteca", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .vesselButton(false, tint: store.tint)
        }
        .padding(16)
        .frame(width: 260)
        .presentationCompactAdaptation(.popover)
    }
}

/// Puente AppKit de tamaño intrínseco estricto. Evita que el motor de toolbar de SwiftUI en
/// macOS 26 propague el tamaño natural del PNG al encabezado (el origen del avatar gigante).
private struct PlatformAvatar: NSViewRepresentable {
    let store: StoreKind
    let data: Data?
    var size: CGFloat = 26

    func makeNSView(context: Context) -> FixedAvatarView {
        FixedAvatarView(diameter: size)
    }

    func updateNSView(_ avatarView: FixedAvatarView, context: Context) {
        avatarView.avatarImage = data.flatMap(NSImage.init(data:))
        avatarView.fallbackImage = StoreLogo.image(store.logoAsset)
        avatarView.backgroundColor = store.avatarBackgroundColor
        avatarView.needsDisplay = true
    }
}

private extension StoreKind {
    var avatarBackgroundColor: NSColor {
        switch self {
        case .steam: NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.85, alpha: 0.22)
        case .epic: NSColor(white: 0.55, alpha: 0.22)
        case .gog: NSColor(calibratedRed: 0.60, green: 0.25, blue: 0.75, alpha: 0.22)
        case .local: NSColor(calibratedRed: 0.80, green: 0.17, blue: 0.18, alpha: 0.22)
        }
    }
}

private final class FixedAvatarView: NSView {
    let diameter: CGFloat
    var avatarImage: NSImage?
    var fallbackImage: NSImage?
    var backgroundColor = NSColor.clear

    init(diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: diameter, height: diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Aunque un contenedor externo propusiera un tamaño incorrecto, jamás dibujamos fuera
        // de este rectángulo de diámetro contractual.
        let avatarRect = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        ).integral

        NSGraphicsContext.saveGraphicsState()
        let clipPath = NSBezierPath(ovalIn: avatarRect)
        clipPath.addClip()
        backgroundColor.setFill()
        avatarRect.fill()

        if let avatarImage {
            avatarImage.drawAspectFill(in: avatarRect)
        } else if let fallbackImage {
            let inset = diameter * 0.18
            fallbackImage.drawAspectFit(in: avatarRect.insetBy(dx: inset, dy: inset))
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.18).setStroke()
        let border = NSBezierPath(ovalIn: avatarRect.insetBy(dx: 0.25, dy: 0.25))
        border.lineWidth = 0.5
        border.stroke()
    }
}

private extension NSImage {
    func drawAspectFill(in destination: NSRect) {
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(destination.width / size.width, destination.height / size.height)
        let sourceSize = NSSize(width: destination.width / scale, height: destination.height / scale)
        let source = NSRect(
            x: (size.width - sourceSize.width) / 2,
            y: (size.height - sourceSize.height) / 2,
            width: sourceSize.width,
            height: sourceSize.height
        )
        draw(in: destination, from: source, operation: .sourceOver, fraction: 1)
    }

    func drawAspectFit(in destination: NSRect) {
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(destination.width / size.width, destination.height / size.height)
        let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
        let drawRect = NSRect(
            x: destination.midX - drawSize.width / 2,
            y: destination.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
