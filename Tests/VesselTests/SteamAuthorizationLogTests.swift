import XCTest
@testable import Vessel

final class SteamAuthorizationLogTests: XCTestCase {
    func testRenderedEULAMustBeNewAndMatchTheExactAppID() {
        let baseline = Data("prompt for eula 6910_eula_0\n".utf8)
        XCTAssertFalse(SteamAuthorizationLog.eulaPromptRendered(
            in: baseline,
            after: baseline,
            appId: "6910"
        ))

        let unrelated = baseline + Data("prompt for eula 69100_eula_0\n".utf8)
        XCTAssertFalse(SteamAuthorizationLog.eulaPromptRendered(
            in: unrelated,
            after: baseline,
            appId: "6910"
        ))

        let rendered = unrelated + Data("prompt for eula 6910_eula_1\n".utf8)
        XCTAssertTrue(SteamAuthorizationLog.eulaPromptRendered(
            in: rendered,
            after: baseline,
            appId: "6910"
        ))
    }

    func testRotatedSteamUILogsBelongToTheNewGeneration() {
        let baseline = Data("old SteamApp Init:\n".utf8)
        let rotatedUI = Data("Restart webhelper process, counter 2\n".utf8)
        let rotatedJS = Data("SteamApp Init - After Login: 1311 ms\n".utf8)

        XCTAssertTrue(SteamAuthorizationLog.webHelperRestarted(
            in: rotatedUI,
            after: baseline
        ))
        XCTAssertTrue(SteamAuthorizationLog.steamUIReady(
            in: rotatedJS,
            after: baseline
        ))
    }

    func testEULAAcceptanceMustBeNewAndMatchTheExactAppID() {
        let baseline = Data("accepted eula 6910_eula_0\n".utf8)
        XCTAssertFalse(SteamAuthorizationLog.eulaAccepted(
            in: baseline,
            after: baseline,
            appId: "6910"
        ))

        let unrelated = baseline + Data("eulas complete 69100_eula_0\n".utf8)
        XCTAssertFalse(SteamAuthorizationLog.eulaAccepted(
            in: unrelated,
            after: baseline,
            appId: "6910"
        ))

        let accepted = unrelated + Data("accepted eula 6910_eula_1\n".utf8)
        XCTAssertTrue(SteamAuthorizationLog.eulaAccepted(
            in: accepted,
            after: baseline,
            appId: "6910"
        ))

        let completed = unrelated + Data("eulas complete 6910_eula_2\n".utf8)
        XCTAssertTrue(SteamAuthorizationLog.eulaAccepted(
            in: completed,
            after: baseline,
            appId: "6910"
        ))
    }

    func testEULABackendIsResolvedOnlyAfterAnExplicitResponseOrAdvance() {
        let baseline = Data("Console Log Start\n".utf8)
        let waiting = baseline + Data("""
        GameAction [AppID 2842890, ActionID 1] : LaunchApp changed task to ShowEula with ""
        GameAction [AppID 2842890, ActionID 1] : LaunchApp waiting for user response to ShowEula ""
        """.utf8)
        XCTAssertFalse(SteamAuthorizationLog.eulaResolved(
            in: waiting,
            after: baseline,
            appId: "2842890"
        ))

        let resolved = waiting + Data("""

        GameAction [AppID 2842890, ActionID 1] : LaunchApp continues with user response "ShowEula"
        """.utf8)
        XCTAssertTrue(SteamAuthorizationLog.eulaResolved(
            in: resolved,
            after: baseline,
            appId: "2842890"
        ))
    }
}
