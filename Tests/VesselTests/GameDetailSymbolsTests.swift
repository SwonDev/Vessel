import AppKit
import Testing
@testable import Vessel

struct GameDetailSymbolsTests {
    @Test("Los iconos de notas existen en SF Symbols")
    func noteSymbolsAreAvailable() {
        for symbol in [
            GameDetailSymbols.note,
            GameDetailSymbols.savedNoteBadge
        ] {
            #expect(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                "SF Symbol no disponible: \(symbol)"
            )
        }
    }
}
