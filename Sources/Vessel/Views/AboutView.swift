import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VesselIconView(size: 96)

            VStack(spacing: 4) {
                Text("Vessel")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("v\(VesselAppInfo.displayVersion)")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .center, spacing: 8) {
                Text("Hecho por SwonDev")
                Text("Biblioteca unificada para jugar a tus juegos de Windows en macOS, de forma nativa.")
                Text("GPL-3.0 · Código abierto")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .vesselCard(padding: 20, cornerRadius: Theme.Radius.card)
            .frame(maxWidth: 360)

            HStack(spacing: 12) {
                Button("Ver en GitHub") {
                    if let url = URL(string: "https://github.com/SwonDev/Vessel") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .vesselButton()
                .vesselHelp("Abrir el repositorio de Vessel en GitHub")
                Button("Reportar bug") {
                    if let url = URL(string: "https://github.com/SwonDev/Vessel/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .vesselButton(false)
                .vesselHelp("Abrir un nuevo reporte de error en GitHub")
            }

            Spacer()

            Text("Vessel no está afiliado con Valve, CodeWeavers, Apple o CrossOver. Wine®, GPTK™ y DirectX® son marcas registradas de sus respectivos dueños.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Cerrar") { dismiss() }
                .vesselButton(false)
                .keyboardShortcut(.cancelAction)
                .vesselHelp("Cerrar Acerca de Vessel", shortcut: "Esc")
                .padding(.top, 8)
        }
        .padding(40)
        // Ancho fijo, alto al CONTENIDO: con la altura fija de antes (480) el texto largo se
        // truncaba y el botón «Cerrar» quedaba cortado por el borde inferior de la sheet.
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .vesselBackground()
    }
}
