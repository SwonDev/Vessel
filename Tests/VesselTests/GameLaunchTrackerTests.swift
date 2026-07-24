import Foundation
import XCTest
@testable import Vessel

@MainActor
final class GameLaunchTrackerTests: XCTestCase {
    private final class ProbeState: @unchecked Sendable {
        var familyIsAlive = true
        var stopWasCalled = false
    }

    private final class StatsRecorder: @unchecked Sendable {
        var marked: [String] = []
        var sessions: [(key: String, seconds: Int)] = []
    }

    private func waitUntilIdle(
        _ id: String,
        tracker: GameLaunchTracker = .shared,
        timeout: Duration = .seconds(3)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while tracker.state(id) != .idle, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func testStatsBeginOnlyWhenTheRealProcessFamilyAppears() async throws {
        let id = "tracker-stats-family-\(UUID().uuidString)"
        let key = "steam:verified-family-\(UUID().uuidString)"
        let probe = ProbeState()
        let stats = StatsRecorder()
        probe.familyIsAlive = false
        let tracker = GameLaunchTracker(
            markPlayed: { stats.marked.append($0) },
            addSession: { stats.sessions.append(($0, $1)) }
        )

        await tracker.track(
            id,
            statsKey: key,
            processFamilyIsRunning: { probe.familyIsAlive }
        ) {
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/bin/sleep")
            launcher.arguments = ["0.05"]
            try launcher.run()
            return launcher
        }

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(stats.marked.isEmpty, "Un intermediario de Steam no debe contar como juego")

        probe.familyIsAlive = true
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while stats.marked.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(stats.marked, [key])

        probe.familyIsAlive = false
        await waitUntilIdle(id, tracker: tracker)
        XCTAssertEqual(tracker.state(id), .idle)
    }

    func testDetachedProcessFamilyKeepsRunningStateUntilTheRealGameCloses() async throws {
        let id = "tracker-detached-\(UUID().uuidString)"
        let probe = ProbeState()

        await GameLaunchTracker.shared.track(
            id,
            processFamilyIsRunning: { probe.familyIsAlive }
        ) {
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/bin/sleep")
            launcher.arguments = ["0.05"]
            try launcher.run()
            return launcher
        }

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(GameLaunchTracker.shared.state(id), .running)

        probe.familyIsAlive = false
        await waitUntilIdle(id)
        XCTAssertEqual(GameLaunchTracker.shared.state(id), .idle)
    }

    func testDetachedProcessFamilyCanAppearAfterLauncherTerminates() async throws {
        let id = "tracker-delayed-family-\(UUID().uuidString)"
        let probe = ProbeState()
        probe.familyIsAlive = false

        await GameLaunchTracker.shared.track(
            id,
            processFamilyIsRunning: { probe.familyIsAlive }
        ) {
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/bin/sleep")
            launcher.arguments = ["0.05"]
            try launcher.run()
            return launcher
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            probe.familyIsAlive = true
        }

        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(GameLaunchTracker.shared.state(id), .running)

        probe.familyIsAlive = false
        await waitUntilIdle(id)
        XCTAssertEqual(GameLaunchTracker.shared.state(id), .idle)
    }

    func testStopUsesExactProcessFamilyAction() async throws {
        let id = "tracker-stop-\(UUID().uuidString)"
        let launcher = Process()
        let probe = ProbeState()

        await GameLaunchTracker.shared.track(
            id,
            processFamilyIsRunning: { probe.familyIsAlive },
            stopProcessFamily: {
                probe.stopWasCalled = true
                probe.familyIsAlive = false
                if launcher.isRunning { launcher.terminate() }
            }
        ) {
            launcher.executableURL = URL(fileURLWithPath: "/bin/sleep")
            launcher.arguments = ["30"]
            try launcher.run()
            return launcher
        }

        GameLaunchTracker.shared.stop(id)
        await waitUntilIdle(id)

        XCTAssertTrue(probe.stopWasCalled)
        XCTAssertEqual(GameLaunchTracker.shared.state(id), .idle)
    }

    func testStopAlsoTerminatesLauncherWhenProcessFamilyNeverAppeared() async throws {
        let id = "tracker-stop-pending-family-\(UUID().uuidString)"
        let launcher = Process()
        let probe = ProbeState()
        probe.familyIsAlive = false
        let tracker = GameLaunchTracker()

        await tracker.track(
            id,
            processFamilyIsRunning: { probe.familyIsAlive },
            stopProcessFamily: {
                probe.stopWasCalled = true
            }
        ) {
            launcher.executableURL = URL(fileURLWithPath: "/bin/sleep")
            launcher.arguments = ["30"]
            try launcher.run()
            return launcher
        }

        tracker.stop(id)
        await waitUntilIdle(id, tracker: tracker)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while launcher.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(probe.stopWasCalled)
        XCTAssertFalse(launcher.isRunning, "Detener debe cerrar también el relé pendiente")
        XCTAssertEqual(tracker.state(id), .idle)
    }

    func testAdoptsRunningFamilyAfterVesselRestarts() async {
        let id = "tracker-adopted-family-\(UUID().uuidString)"
        let probe = ProbeState()

        await GameLaunchTracker.shared.adoptRunningProcessFamily(
            id,
            processFamilyIsRunning: { probe.familyIsAlive },
            stopProcessFamily: {
                probe.stopWasCalled = true
                probe.familyIsAlive = false
            }
        )

        XCTAssertEqual(GameLaunchTracker.shared.state(id), .running)
        GameLaunchTracker.shared.stop(id)
        await waitUntilIdle(id)
        XCTAssertTrue(probe.stopWasCalled)
        XCTAssertEqual(GameLaunchTracker.shared.state(id), .idle)
    }
}
