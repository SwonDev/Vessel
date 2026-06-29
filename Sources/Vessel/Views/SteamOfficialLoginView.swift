import SwiftUI
import CoreImage.CIFilterBuiltins

/// Cuadro de login con la estética de Steam: pestañas **QR** (Steam Guard desde el
/// móvil) y **usuario/contraseña** (con cifrado RSA oficial), opción de **recordar
/// sesión** y campo de Steam Guard cuando Steam lo pide. Devuelve los tokens al
/// completar. Es el flujo de autenticación oficial de Steam. Ver
/// [[vessel-seccion-tienda-plan]].
struct SteamOfficialLoginView: View {
    let onLoggedIn: (SteamAuthService.Tokens) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var auth = SteamAuthService()
    @State private var mode = 0   // 0 = QR, 1 = credenciales

    // QR
    @State private var qrImage: NSImage?
    @State private var qrStatus = "Generando código…"

    // Credenciales
    @State private var user = ""
    @State private var password = ""
    @State private var rememberLogin = true
    @State private var guardCode = ""
    @State private var guardHandle: SteamAuthService.PollHandle?
    @State private var guardSteamID: UInt64 = 0
    @State private var guardCodeType = 0
    @State private var working = false
    @State private var errorText: String?

    private let steamBG = Color(red: 0.10, green: 0.12, blue: 0.16)
    private let steamBlue = Color(red: 0.10, green: 0.55, blue: 0.85)

    var body: some View {
        VStack(spacing: 16) {
            Text("Iniciar sesión en Steam")
                .font(.title2).fontWeight(.bold).foregroundStyle(.white)

            Picker("", selection: $mode) {
                Text("Código QR").tag(0)
                Text("Usuario y contraseña").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

            if mode == 0 { qrView } else { credentialsView }

            Button("Cancelar") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(28)
        .frame(width: 420)
        .background(steamBG)
        .task(id: mode) { if mode == 0 { await startQR() } }
    }

    // MARK: - QR

    private var qrView: some View {
        VStack(spacing: 12) {
            Text("Escanea con la app de Steam en tu móvil para iniciar sesión con Steam Guard.")
                .font(.callout).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            Group {
                if let qrImage {
                    Image(nsImage: qrImage).interpolation(.none).resizable().frame(width: 200, height: 200)
                } else {
                    ProgressView().frame(width: 200, height: 200)
                }
            }
            .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12))
            Text(qrStatus).font(.footnote).foregroundStyle(.white.opacity(0.6))
        }
    }

    private func startQR() async {
        qrImage = nil
        qrStatus = "Generando código…"
        do {
            let session = try await auth.beginQR()
            qrImage = makeQR(session.challengeURL)
            qrStatus = "Esperando aprobación en tu móvil…"
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: UInt64(max(2.0, session.handle.interval) * 1_000_000_000))
                if mode != 0 { return }
                if let tokens = try await auth.poll(handle: session.handle) {
                    onLoggedIn(tokens); dismiss(); return
                }
            }
            qrStatus = "El código ha caducado. Cambia de pestaña y vuelve para refrescar."
        } catch {
            qrStatus = "No se pudo generar el código: \(error.localizedDescription)"
        }
    }

    // MARK: - Credenciales

    private var credentialsView: some View {
        VStack(spacing: 12) {
            TextField("Usuario de Steam", text: $user)
                .textFieldStyle(.roundedBorder).textContentType(.username)
                .disabled(guardHandle != nil)
            SecureField("Contraseña", text: $password)
                .textFieldStyle(.roundedBorder)
                .disabled(guardHandle != nil)

            if guardHandle != nil {
                TextField("Código de Steam Guard", text: $guardCode)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Recordar inicio de sesión", isOn: $rememberLogin)
                .toggleStyle(.checkbox)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { guardHandle == nil ? await doCredentials() : await submitGuard() }
            } label: {
                if working {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Conectando…") }
                        .frame(maxWidth: .infinity)
                } else {
                    Text(guardHandle == nil ? "Iniciar sesión" : "Verificar código")
                        .frame(maxWidth: .infinity)
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(steamBlue)
            .disabled(working || (guardHandle == nil && (user.isEmpty || password.isEmpty)) || (guardHandle != nil && guardCode.isEmpty))
        }
        .frame(width: 300)
    }

    private func doCredentials() async {
        working = true; errorText = nil
        do {
            switch try await auth.loginWithCredentials(accountName: user, password: password, rememberLogin: rememberLogin) {
            case .session(let handle):
                await pollUntilTokens(handle)
            case .needsGuard(let handle, let sid, let type):
                guardHandle = handle; guardSteamID = sid; guardCodeType = type
                working = false
            case .badPassword:
                working = false; errorText = "Usuario o contraseña incorrectos."
            case .failed(let message):
                working = false; errorText = message
            }
        } catch {
            working = false; errorText = error.localizedDescription
        }
    }

    private func submitGuard() async {
        guard let handle = guardHandle else { return }
        working = true; errorText = nil
        do {
            try await auth.submitSteamGuard(handle: handle, steamID: guardSteamID, code: guardCode, codeType: guardCodeType)
            await pollUntilTokens(handle)
        } catch {
            working = false; errorText = "El código no es válido. Inténtalo de nuevo."
        }
    }

    private func pollUntilTokens(_ handle: SteamAuthService.PollHandle) async {
        for _ in 0..<30 {
            if let tokens = try? await auth.poll(handle: handle) {
                onLoggedIn(tokens); dismiss(); return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        working = false; errorText = "No se pudo completar el inicio de sesión."
    }

    // MARK: - QR image

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
