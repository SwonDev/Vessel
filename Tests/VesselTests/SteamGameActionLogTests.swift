import XCTest
@testable import Vessel

final class SteamGameActionLogTests: XCTestCase {
    func testFindsOnlyANewWaitingTaskForTheExactAppID() {
        let baseline = Data("GameAction [AppID 2842890, ActionID 1] : LaunchApp waiting for user response to ShowEula \"\"\n".utf8)
        XCTAssertNil(SteamGameActionLog.waitingTask(
            in: baseline,
            after: baseline,
            appId: "2842890"
        ))

        let unrelated = baseline + Data("GameAction [AppID 28428900, ActionID 2] : LaunchApp waiting for user response to ShowInterstitials \"\"\n".utf8)
        XCTAssertNil(SteamGameActionLog.waitingTask(
            in: unrelated,
            after: baseline,
            appId: "2842890"
        ))

        let current = unrelated + Data("GameAction [AppID 2842890, ActionID 3] : LaunchApp waiting for user response to ShowInterstitials \"\"\n".utf8)
        XCTAssertEqual(SteamGameActionLog.waitingTask(
            in: current,
            after: baseline,
            appId: "2842890"
        ), "ShowInterstitials")
    }

    func testRotatedLogIsTreatedAsANewGeneration() {
        let baseline = Data("old log".utf8)
        let current = Data("GameAction [AppID 6910] : LaunchApp waiting for user response to ShowEula \"\"\n".utf8)
        XCTAssertEqual(SteamGameActionLog.waitingTask(
            in: current,
            after: baseline,
            appId: "6910"
        ), "ShowEula")
    }

    func testResolvedInterstitialFromRealSteamLogIsNotReportedAsBlocking() {
        let baseline = Data("Console Log Start\n".utf8)
        let current = baseline + Data("""
        GameAction [AppID 2842890, ActionID 9] : LaunchApp changed task to ShowInterstitials with ""
        GameAction [AppID 2842890, ActionID 9] : LaunchApp waiting for user response to ShowInterstitials ""
        GameAction [AppID 2842890, ActionID 9] : LaunchApp continues with user response "ShowInterstitials"
        GameAction [AppID 2842890, ActionID 9] : LaunchApp changed task to CreatingProcess with ""
        GameAction [AppID 2842890, ActionID 9] : LaunchApp waiting for user response to CreatingProcess ""
        GameAction [AppID 2842890, ActionID 9] : LaunchApp continues with user response "CreatingProcess"
        GameAction [AppID 2842890, ActionID 9] : LaunchApp changed task to Completed with ""
        """.utf8)

        XCTAssertNil(SteamGameActionLog.waitingTask(
            in: current,
            after: baseline,
            appId: "2842890"
        ))
    }

    func testNewestActionReplacesAnAbandonedWaitFromAnOlderAttempt() {
        let baseline = Data()
        let current = Data("""
        GameAction [AppID 2842890, ActionID 8] : LaunchApp waiting for user response to ShowInterstitials ""
        GameAction [AppID 2842890, ActionID 9] : LaunchApp changed task to CheckShaderDepotManifest with ""
        """.utf8)

        XCTAssertNil(SteamGameActionLog.waitingTask(
            in: current,
            after: baseline,
            appId: "2842890"
        ))
    }

    func testSustainedWaitIgnoresTransientInterstitialAndConfirmsPersistentDecision() {
        var observation = SteamGameActionLog.SustainedWaitingTask()

        XCTAssertNil(observation.observe(
            "ShowInterstitials",
            requiredConsecutiveSamples: 4
        ))
        XCTAssertNil(observation.observe(
            "ShowInterstitials",
            requiredConsecutiveSamples: 4
        ))
        XCTAssertNil(observation.observe(nil, requiredConsecutiveSamples: 4))

        for _ in 0..<3 {
            XCTAssertNil(observation.observe(
                "ShowEula",
                requiredConsecutiveSamples: 4
            ))
        }
        XCTAssertEqual(
            observation.observe("ShowEula", requiredConsecutiveSamples: 4),
            "ShowEula"
        )
    }
}
