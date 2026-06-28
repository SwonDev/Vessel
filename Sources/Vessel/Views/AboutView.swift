import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            VesselIconView(size: 96)
            Text("Vessel")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("v0.1.0")
                .foregroundStyle(.secondary)

            Divider().frame(width: 320)

            VStack(alignment: .leading, spacing: 8) {
                Text("Hecho con ❤️ por SwonDev")
                Text("Wrapper nativo de macOS para Wine + Game Porting Toolkit")
                Text("GPL-3.0 · Open Source")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Ver en GitHub") {
                    if let url = URL(string: "https://github.com/Ja1zme/vessel-mac") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Reportar bug") {
                    if let url = URL(string: "https://github.com/Ja1zme/vessel-mac/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Spacer()

            Text("Vessel no está afiliado con Valve, CodeWeavers, Apple o CrossOver. Wine®, GPTK™ y DirectX® son marcas registradas de sus respectivos dueños.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Cerrar") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 8)
        }
        .padding(40)
        .frame(width: 460, height: 480)
    }
}
