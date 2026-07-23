import Testing
@testable import Vessel

private actor SteamCMDGateProbe {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

@Suite("Exclusión mutua de SteamCMD")
struct SteamCMDExecutionGateTests {
    @Test("Una segunda orden espera a que la primera libere SteamCMD")
    func serializesCommands() async {
        let gate = SteamCMDExecutionGate()
        let probe = SteamCMDGateProbe()

        await gate.acquire()
        let second = Task {
            await probe.record("esperando")
            await gate.acquire()
            await probe.record("adquirido")
            await gate.release()
        }

        while await probe.events.isEmpty {
            await Task.yield()
        }
        #expect(await probe.events == ["esperando"])

        await gate.release()
        await second.value
        #expect(await probe.events == ["esperando", "adquirido"])
    }
}
