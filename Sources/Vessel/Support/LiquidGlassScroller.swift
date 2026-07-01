import SwiftUI
import AppKit
import ObjectiveC.runtime

/// Scroller (barra de scroll) con estética **Liquid Glass** de Vessel: knob redondeado
/// translúcido con borde sutil, en vez del gris plano del sistema, y sin canal de fondo. Se usa
/// como overlay (aparece al hacer scroll y se desvanece), así no roba espacio ni protagonismo.
///
/// `isCompatibleWithOverlayScrollers = true` es lo que hace que AppKit llame a `drawKnob` de esta
/// subclase también para los overlay scrollers (no solo los legacy). Verificado visualmente.
final class LiquidGlassScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Sin canal de fondo: overlay limpio (solo se ve el knob), coherente con el minimalismo premium.
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        let r = knob.insetBy(dx: 3, dy: 3)
        guard r.width > 0, r.height > 0 else { return }
        let radius = min(r.width, r.height) / 2
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        // Cristal: relleno translúcido + brillo de borde. Más opaco al arrastrar/hover (highlight).
        NSColor.white.withAlphaComponent(isHighlighted ? 0.46 : 0.30).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

extension NSScrollView {
    /// Instala **globalmente** los scrollers Liquid Glass en TODOS los `NSScrollView` de la app
    /// (SwiftUI `ScrollView`, `List`, `TextView`, …) intercambiando `tile`. Es la única vía fiable
    /// de alcanzar el scroller real de un `List` (donde la introspección por `enclosingScrollView`
    /// no llega). Idempotente por scrollview. Llamar UNA vez al arrancar (`VesselApp.init`).
    static func installVesselGlassScrollers() {
        _ = installGlassScrollersOnce
    }

    private static let installGlassScrollersOnce: Void = {
        guard let orig = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.tile)),
              let repl = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.vessel_tile)) else { return }
        method_exchangeImplementations(orig, repl)
    }()

    @objc private func vessel_tile() {
        vessel_applyGlassScrollers()
        vessel_tile()   // tras el swizzle, este selector apunta al `tile` original
    }

    private func vessel_applyGlassScrollers() {
        if let vs = verticalScroller, !(vs is LiquidGlassScroller) {
            let n = LiquidGlassScroller(); n.controlSize = vs.controlSize
            verticalScroller = n
        }
        if let hs = horizontalScroller, !(hs is LiquidGlassScroller) {
            let n = LiquidGlassScroller(); n.controlSize = hs.controlSize
            horizontalScroller = n
        }
    }
}
