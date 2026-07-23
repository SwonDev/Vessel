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

        #expect(await gate.acquire())
        let second = Task {
            await probe.record("esperando")
            let acquired = await gate.acquire()
            guard acquired else { return }
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

    @Test("Cancelar una orden en espera no retiene el siguiente turno")
    func cancellationRemovesWaiter() async {
        let gate = SteamCMDExecutionGate()
        let probe = SteamCMDGateProbe()

        #expect(await gate.acquire())
        let cancelled = Task {
            await probe.record("esperando cancelación")
            return await gate.acquire()
        }
        while await probe.events.isEmpty {
            await Task.yield()
        }

        cancelled.cancel()
        #expect(await cancelled.value == false)
        await gate.release()

        #expect(await gate.acquire())
        await gate.release()
    }
}
