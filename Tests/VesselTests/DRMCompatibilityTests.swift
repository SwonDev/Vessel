import Testing
@testable import Vessel

@Suite("Compatibilidad de anti-cheat")
struct DRMCompatibilityTests {
    @Test("Solo Denied y Broken con anti-cheat conocido bloquean macOS")
    func blockingStatuses() {
        var verdict = DRMDatabase.Verdict(appId: "1")
        verdict.antiCheats = ["Easy Anti-Cheat"]

        verdict.antiCheatStatus = "Denied"
        #expect(verdict.antiCheatBlocksMacOS)
        verdict.antiCheatStatus = "Broken"
        #expect(verdict.antiCheatBlocksMacOS)
        verdict.antiCheatStatus = "Unknown"
        #expect(!verdict.antiCheatBlocksMacOS)
        verdict.antiCheats = []
        verdict.antiCheatStatus = "Denied"
        #expect(!verdict.antiCheatBlocksMacOS)
    }
}
