import SwiftUI
import WebKit

/// Envuelve un `WKWebView` con el login de **Humble Bundle**. Humble no tiene API pública; el
/// enfoque robusto (el mismo que usan las herramientas open‑source) es dejar que el usuario inicie
/// sesión en el WebView (incl. captcha/2FA) y **capturar la cookie de sesión `_simpleauth_sess`**,
/// que autentica luego las llamadas a `api/v1/user/order`.
///
/// Sesión no persistente (aislada): al desvincular no queda rastro; se puede entrar con otra cuenta.
struct HumbleLoginWebView: NSViewRepresentable {

    /// Se llama con el valor de la cookie `_simpleauth_sess` cuando el login ha tenido éxito.
    let onSessionCaptured: (String) -> Void
    let onError: (String) -> Void
    let onLoadingChanged: (Bool) -> Void

    static let loginURL = URL(string: "https://www.humblebundle.com/login")!
    static let sessionCookieName = "_simpleauth_sess"

    func makeCoordinator() -> Coordinator {
        Coordinator(onSessionCaptured: onSessionCaptured, onError: onError, onLoadingChanged: onLoadingChanged)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        webView.load(URLRequest(url: Self.loginURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, @unchecked Sendable {
        private let onSessionCaptured: (String) -> Void
        private let onError: (String) -> Void
        private let onLoadingChanged: (Bool) -> Void
        private var captured = false

        init(onSessionCaptured: @escaping (String) -> Void, onError: @escaping (String) -> Void,
             onLoadingChanged: @escaping (Bool) -> Void) {
            self.onSessionCaptured = onSessionCaptured; self.onError = onError; self.onLoadingChanged = onLoadingChanged
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingChanged(true)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChanged(false)
            checkForSession(webView)
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            checkForSession(webView)
        }

        /// Tras cada navegación, mira si ya existe la cookie de sesión de Humble. Solo se considera
        /// logueado cuando la cookie aparece Y ya no estamos en la página de login.
        private func checkForSession(_ webView: WKWebView) {
            guard !captured else { return }
            let store = webView.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.captured else { return }
                guard let c = cookies.first(where: { $0.name == HumbleLoginWebView.sessionCookieName }),
                      !c.value.isEmpty else { return }
                // La cookie de sesión ya existe pre‑login como placeholder; exigimos que NO estemos
                // en /login para confirmar que el login se completó.
                let path = webView.url?.path ?? ""
                guard !path.hasPrefix("/login") else { return }
                self.captured = true
                self.onSessionCaptured(c.value)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChanged(false)
            let ns = error as NSError
            guard ns.code != NSURLErrorCancelled else { return }
            onError("Error al cargar el inicio de sesión de Humble: \(error.localizedDescription)")
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadingChanged(false)
            let ns = error as NSError
            guard ns.code != NSURLErrorCancelled else { return }
            onError("Error de conexión con Humble: \(error.localizedDescription)")
        }
    }
}
