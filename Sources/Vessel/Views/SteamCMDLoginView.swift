import SwiftUI

/// Sheet de inicio de sesión para SteamCMD (necesario para descargar juegos de forma
/// robusta). La contraseña solo se usa para iniciar sesión; no se guarda (SteamCMD
/// recuerda la sesión tras el primer login con Steam Guard).
struct SteamCMDLoginView: View {
    let suggestedUser: String
    let onLoggedIn: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var steamCMD = SteamCMDManager()
    @State private var user = ""
    @State private var password = ""
    @State private var guardCode = ""
    @State private var needsGuard = false
    @State private var working = false
    @State private var status = "Para instalar juegos, Vessel descarga con SteamCMD usando tu cuenta. Tu contraseña no se guarda."
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Conectar Steam para instalar")
                .font(.title2).fontWeight(.bold)
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                TextField("Usuario de Steam (nombre de cuenta)", text: $user)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                SecureField("Contraseña", text: $password)
                    .textFieldStyle(.roundedBorder)
                if needsGuard {
                    TextField("Código de Steam Guard (de tu app/email)", text: $guardCode)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .vesselCard(padding: 10, cornerRadius: Theme.Radius.control)

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .vesselButton(false)
                Button {
                    Task { await doLogin() }
                } label: {
                    if working {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Conectando…") }
                    } else {
                        Text(needsGuard ? "Verificar código" : "Iniciar sesión")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .vesselButton()
                .disabled(working || user.isEmpty || password.isEmpty || (needsGuard && guardCode.isEmpty))
            }
        }
        .padding(28)
        .frame(width: 460)
        .vesselBackground()
        .onAppear { if user.isEmpty { user = suggestedUser } }
    }

    private func doLogin() async {
        working = true
        errorText = nil
        do {
            status = "Preparando SteamCMD…"
            try await steamCMD.ensureInstalled()
        } catch {
            working = false
            errorText = "No se pudo preparar SteamCMD: \(error.localizedDescription)"
            return
        }
        status = "Iniciando sesión en Steam…"
        let result = await steamCMD.login(user: user, password: password, guardCode: needsGuard ? guardCode : nil)
        working = false
        switch result {
        case .ok:
            onLoggedIn(user)
            dismiss()
        case .needsGuard:
            needsGuard = true
            status = "Steam te ha enviado un código de Steam Guard. Introdúcelo para continuar."
        case .invalidPassword:
            errorText = "Usuario o contraseña incorrectos."
        case .failed(let message):
            errorText = message
        }
    }
}
