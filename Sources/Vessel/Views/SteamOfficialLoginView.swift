import SwiftUI
import CoreImage.CIFilterBuiltins

/// Réplica del **cuadro de login oficial de Steam**: a la izquierda usuario/contraseña
/// (con cifrado RSA real) + "Recordarme", a la derecha el **código QR** (Steam Guard
/// desde el móvil) — ambos a la vez, con la estética de Steam. Flujo de autenticación
/// oficial (`IAuthenticationService`). Ver [[vessel-seccion-tienda-plan]].
struct SteamOfficialLoginView: View {
    let onLoggedIn: (SteamAuthService.Tokens) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var auth = SteamAuthService()
    @State private var qrImage: NSImage?
    @State private var qrError: String?

    @State private var user = ""
    @State private var password = ""
    @State private var rememberLogin = true
    @State private var guardCode = ""
    @State private var guardHandle: SteamAuthService.PollHandle?
    @State private var guardSteamID: UInt64 = 0
    @State private var guardCodeType = 0
    @State private var working = false
    @State private var errorText: String?

    private let steamBlue = Color(red: 0.10, green: 0.62, blue: 1.0)
    private let fieldBG = Color(red: 0.19, green: 0.23, blue: 0.28)
    private let panelBG = Color(red: 0.094, green: 0.118, blue: 0.149)
    private let backdrop = Color(red: 0.06, green: 0.08, blue: 0.10)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                HStack(alignment: .center, spacing: 10) {
                    StoreLogoTile(store: .steam, size: 30)
                    Text("Inicio de sesión")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.medium)).foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cerrar inicio de sesión")
                .vesselHelp("Cerrar inicio de sesión", shortcut: "Esc")
            }
            .padding(.bottom, 26)

            HStack(alignment: .top, spacing: 56) {
                credentialsColumn
                qrColumn
            }
        }
        .padding(40)
        .frame(width: 780)
        .background(panelBG)
        .task { await startQR() }
    }

    // MARK: - Columna izquierda (usuario/contraseña)

    private var credentialsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INICIA SESIÓN CON TU NOMBRE DE CUENTA")
                .font(.caption.weight(.bold)).foregroundStyle(steamBlue)

            field(text: $user, secure: false)

            Text("CONTRASEÑA")
                .font(.caption).foregroundStyle(.white.opacity(0.6)).padding(.top, 6)
            field(text: $password, secure: true)

            if guardHandle != nil {
                Text("CÓDIGO DE STEAM GUARD")
                    .font(.caption).foregroundStyle(.white.opacity(0.6)).padding(.top, 6)
                field(text: $guardCode, secure: false)
            }

            Toggle(isOn: $rememberLogin) {
                Text("Recordarme").foregroundStyle(.white.opacity(0.85))
            }
            .toggleStyle(.checkbox)
            .padding(.vertical, 4)

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(Theme.destructive)
            }

            Button {
                Task { guardHandle == nil ? await doCredentials() : await submitGuard() }
            } label: {
                Group {
                    if working {
                        HStack(spacing: 6) { ProgressView().controlSize(.small).tint(.white); Text("Conectando…") }
                    } else {
                        Text(guardHandle == nil ? "Iniciar sesión" : "Verificar código")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .vesselButton()
            .keyboardShortcut(.defaultAction)
            .disabled(working || (guardHandle == nil && (user.isEmpty || password.isEmpty)) || (guardHandle != nil && guardCode.isEmpty))
            .padding(.top, 6)

            Text("Tu contraseña se cifra (RSA) y se envía a Steam; no se guarda.")
                .font(.caption2).foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
        }
        .frame(width: 340)
    }

    @ViewBuilder
    private func field(text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField("", text: text)
            } else {
                TextField("", text: text)
            }
        }
        .textFieldStyle(.plain)
        .foregroundStyle(.white)
        .padding(10)
        .background(fieldBG)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Columna derecha (QR)

    private var qrColumn: some View {
        VStack(spacing: 14) {
            Text("O BIEN CON UN CÓDIGO QR")
                .font(.caption.weight(.bold)).foregroundStyle(steamBlue)

            Group {
                if let err = qrError {
                    VStack(spacing: 8) {
                        Image(systemName: "qrcode").font(.largeTitle).foregroundStyle(.black.opacity(0.35))
                        Text(err).font(.caption2).foregroundStyle(.black.opacity(0.6))
                            .multilineTextAlignment(.center)
                        Button("Reintentar") { qrError = nil; Task { await startQR() } }
                            .font(.caption.weight(.semibold)).tint(steamBlue)
                    }
                    .padding(8).frame(width: 180, height: 180)
                } else if let qrImage {
                    Image(nsImage: qrImage).interpolation(.none).resizable().frame(width: 180, height: 180)
                } else {
                    ProgressView().frame(width: 180, height: 180)
                }
            }
            .padding(10)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("Usa la aplicación Steam Mobile para iniciar sesión con un código QR")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center).frame(width: 180)
        }
        .frame(width: 220)
    }

    // MARK: - Lógica de autenticación

    private func startQR() async {
        // El challenge de Steam CADUCA (~1 min): si no se regenera, el usuario mira un QR muerto que
        // ya no valida (parecía que "no pasa nada"). Bucle exterior que pide un QR NUEVO al caducar.
        while !Task.isCancelled {
            do {
                let session = try await auth.beginQR()
                qrImage = makeQR(session.challengeURL)
                qrError = nil
                // Sondear ~50 s (antes de que caduque) y luego regenerar en la siguiente vuelta.
                let interval = max(2.0, session.handle.interval)
                let iterations = max(6, Int(50.0 / interval))
                for _ in 0..<iterations {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { return }
                    if let tokens = try await auth.poll(handle: session.handle) {
                        onLoggedIn(tokens); dismiss(); return
                    }
                }
            } catch {
                // No dejar un spinner eterno: avisar y permitir reintentar (o usar credenciales).
                qrImage = nil
                qrError = "No se pudo generar el código QR. Usa usuario y contraseña, o reintenta."
                return
            }
        }
    }

    private func doCredentials() async {
        working = true; errorText = nil
        do {
            switch try await auth.loginWithCredentials(accountName: user, password: password, rememberLogin: rememberLogin) {
            case .session(let handle): await pollUntilTokens(handle)
            case .needsGuard(let handle, let sid, let type):
                guardHandle = handle; guardSteamID = sid; guardCodeType = type; working = false
            case .badPassword: working = false; errorText = "Usuario o contraseña incorrectos."
            case .failed(let message): working = false; errorText = message
            }
        } catch { working = false; errorText = error.localizedDescription }
    }

    private func submitGuard() async {
        guard let handle = guardHandle else { return }
        working = true; errorText = nil
        do {
            try await auth.submitSteamGuard(handle: handle, steamID: guardSteamID, code: guardCode, codeType: guardCodeType)
            await pollUntilTokens(handle)
        } catch { working = false; errorText = "El código no es válido. Inténtalo de nuevo." }
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
