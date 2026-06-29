import SwiftUI
import CoreImage.CIFilterBuiltins

/// Cuadro de login con la estética de Steam y código **QR** para iniciar sesión con
/// Steam Guard desde la app móvil (flujo de autenticación oficial). Devuelve los
/// tokens al aprobar el login. Ver [[vessel-seccion-tienda-plan]].
struct SteamOfficialLoginView: View {
    let onLoggedIn: (SteamAuthService.Tokens) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var auth = SteamAuthService()
    @State private var qrImage: NSImage?
    @State private var status = "Generando código…"

    var body: some View {
        VStack(spacing: 18) {
            Text("Iniciar sesión en Steam")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(.white)

            Text("Escanea este código con la app de Steam en tu móvil para iniciar sesión con Steam Guard.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Group {
                if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                } else {
                    ProgressView()
                        .frame(width: 220, height: 220)
                }
            }
            .padding(10)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))

            Text(status)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))

            Button("Cancelar") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(32)
        .frame(width: 380)
        .background(Color(red: 0.10, green: 0.12, blue: 0.16))
        .task { await start() }
    }

    private func start() async {
        do {
            let session = try await auth.beginQR()
            qrImage = makeQR(session.challengeURL)
            status = "Esperando aprobación en tu móvil…"
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: UInt64(max(2.0, session.interval) * 1_000_000_000))
                if let tokens = try await auth.poll(session: session) {
                    onLoggedIn(tokens)
                    dismiss()
                    return
                }
            }
            status = "El código ha caducado. Cierra y vuelve a intentarlo."
        } catch {
            status = "No se pudo generar el código: \(error.localizedDescription)"
        }
    }

    private func makeQR(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
