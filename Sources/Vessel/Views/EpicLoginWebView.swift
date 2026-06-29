import SwiftUI
import WebKit

/// Envuelve un `WKWebView` con el portal de inicio de sesión de Epic Games.
/// Detecta automáticamente el redirect al endpoint de autorización y extrae
/// el `authorizationCode` del cuerpo JSON — sin que el usuario tenga que
/// copiar ni pegar nada (mismo enfoque que Mythic/Heroic con `legendary.gl/epiclogin`).
///
/// Usa un `WKWebsiteDataStore.nonPersistent()` para que la sesión sea
/// completamente aislada: si el usuario cierra sesión podrá autenticarse
/// con otra cuenta sin rastro de cookies o caché previas.
struct EpicLoginWebView: NSViewRepresentable {

    // MARK: - Callbacks

    /// Se llama cuando el `authorizationCode` se ha extraído con éxito.
    let onCodeCaptured: (String) -> Void
    /// Se llama si la carga de la página o la extracción del código falla.
    let onError: (String) -> Void
    /// `true` al empezar una carga provisional, `false` al terminar (éxito o error).
    let onLoadingChanged: (Bool) -> Void

    // MARK: - URL de autenticación

    /// URL de login gestionada por Legendary (redirige al portal OAuth de Epic).
    /// Al terminar el login, Epic sirve un JSON con `authorizationCode` en el body.
    /// Mismo origen que usa Heroic/Mythic.
    static let authURL = URL(string: "https://legendary.gl/epiclogin")!

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
        // User-Agent de Safari real: el portal de Epic requiere un navegador compatible.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        webView.load(URLRequest(url: Self.authURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    // MARK: - Coordinator (WKNavigationDelegate)

    /// Delegado de navegación del WKWebView.
    /// En cada `didFinish` evalúa `document.body.innerText` e intenta parsear
    /// JSON con `authorizationCode`. La mayoría de páginas del flujo no contienen
    /// ese campo y se ignoran silenciosamente; solo la página de redirect de Epic lo tiene.
    ///
    /// `@unchecked Sendable`: todos los métodos del delegado son llamados en el hilo
    /// principal por WebKit, y todas las closures almacenadas se invocan únicamente
    /// desde ese mismo hilo.
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
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChanged(false)
            guard !didExtractCode else { return }

            // En cada página terminada, leemos el texto del body e intentamos parsearlo
            // como JSON buscando "authorizationCode". La mayoría de páginas del flujo
            // de login fallarán el parse silenciosamente; la página de redirect de Epic
            // devuelve exactamente ese JSON en el body.
            webView.evaluateJavaScript("document.body.innerText") { [weak self] result, _ in
                guard let self, !self.didExtractCode else { return }
                guard
                    let text = result as? String,
                    let data = text.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let code = json["authorizationCode"] as? String,
                    !code.isEmpty
                else { return }  // página intermedia del flujo — ignorar

                self.didExtractCode = true
                self.onCodeCaptured(code)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChanged(false)
            let nsErr = error as NSError
            guard nsErr.code != NSURLErrorCancelled else { return }
            onError("Error al cargar la página de inicio de sesión de Epic: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadingChanged(false)
            let nsErr = error as NSError
            guard nsErr.code != NSURLErrorCancelled else { return }
            onError("Error de conexión con Epic Games: \(error.localizedDescription)")
        }
    }
}
