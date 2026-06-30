import SwiftUI
import WebKit

/// Envuelve un `WKWebView` con el portal de inicio de sesión de GOG. Detecta el redirect a
/// `embed.gog.com/on_login_success?…&code=XXX` y extrae el `code` del query param — sin que
/// el usuario tenga que copiar ni pegar nada (mismo enfoque que Heroic, paridad con Epic).
///
/// Usa `WKWebsiteDataStore.nonPersistent()` para que la sesión sea aislada: al cerrar sesión
/// el usuario podrá autenticarse con otra cuenta sin rastro de cookies o caché previas.
struct GogLoginWebView: NSViewRepresentable {

    // MARK: - Entrada / Callbacks

    /// URL de login de GOG (la misma que usa gogdl/Heroic).
    let authURL: URL
    /// Se llama cuando el `code` se ha extraído con éxito.
    let onCodeCaptured: (String) -> Void
    /// Se llama si la carga de la página falla.
    let onError: (String) -> Void
    /// `true` al empezar una carga provisional, `false` al terminar (éxito o error).
    let onLoadingChanged: (Bool) -> Void

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCodeCaptured:   onCodeCaptured,
            onError:          onError,
            onLoadingChanged: onLoadingChanged
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Sesión no persistente: sin cookies ni caché compartidas con el sistema.
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // User-Agent de Safari real: el portal de GOG requiere un navegador compatible.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        webView.load(URLRequest(url: authURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    // MARK: - Coordinator (WKNavigationDelegate)

    /// `@unchecked Sendable`: WebKit llama a todos los métodos del delegado en el hilo
    /// principal, y las closures almacenadas solo se invocan desde ese mismo hilo.
    final class Coordinator: NSObject, WKNavigationDelegate, @unchecked Sendable {

        private let onCodeCaptured:   (String) -> Void
        private let onError:          (String) -> Void
        private let onLoadingChanged: (Bool)   -> Void
        private var didExtractCode = false

        init(
            onCodeCaptured:   @escaping (String) -> Void,
            onError:          @escaping (String) -> Void,
            onLoadingChanged: @escaping (Bool)   -> Void
        ) {
            self.onCodeCaptured   = onCodeCaptured
            self.onError          = onError
            self.onLoadingChanged = onLoadingChanged
        }

        // MARK: Delegado

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingChanged(true)
            captureCodeIfPresent(in: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // El redirect de éxito ya tiene la URL final aquí (antes de pintar la página en blanco).
            captureCodeIfPresent(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChanged(false)
            captureCodeIfPresent(in: webView)
        }

        /// Si la URL actual del WebView es el redirect de éxito de GOG, extrae el `code` una vez.
        private func captureCodeIfPresent(in webView: WKWebView) {
            guard !didExtractCode, let url = webView.url, let code = Self.extractCode(from: url) else { return }
            didExtractCode = true
            onCodeCaptured(code)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChanged(false)
            let nsErr = error as NSError
            guard nsErr.code != NSURLErrorCancelled else { return }
            onError("Error al cargar la página de inicio de sesión de GOG: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadingChanged(false)
            let nsErr = error as NSError
            guard nsErr.code != NSURLErrorCancelled else { return }
            onError("Error de conexión con GOG: \(error.localizedDescription)")
        }

        /// Extrae el `code` del query SOLO si la URL es exactamente el redirect de éxito de GOG
        /// (`https://embed.gog.com/on_login_success`). Anclar scheme/host/path evita que un
        /// redirect a un host atacante (`https://evil.com/on_login_success?code=…`) cuele un code ajeno.
        static func extractCode(from url: URL) -> String? {
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  comps.scheme?.lowercased() == "https",
                  comps.host?.lowercased() == "embed.gog.com",
                  comps.path == "/on_login_success",
                  let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
                  !code.isEmpty
            else { return nil }
            return code
        }
    }
}
