import XCTest
@testable import Vessel

@MainActor
final class SteamAuthorizationResumptionTests: XCTestCase {
    func testResumptionIsConsumedOnlyOnce() async {
        let appId = "test-once-\(UUID().uuidString)"
        var calls = 0
        NotificationService.shared.registerSteamAuthorizationResumption(appId: appId) {
            calls += 1
        }

        let action = NotificationService.shared.takeSteamAuthorizationResumption(appId: appId)
        XCTAssertNotNil(action)
        await action?()

        XCTAssertEqual(calls, 1)
        XCTAssertNil(NotificationService.shared.takeSteamAuthorizationResumption(appId: appId))
    }

    func testNewerResumptionReplacesAStaleAttempt() async {
        let appId = "test-replace-\(UUID().uuidString)"
        var result = ""
        NotificationService.shared.registerSteamAuthorizationResumption(appId: appId) {
            result = "antiguo"
        }
        NotificationService.shared.registerSteamAuthorizationResumption(appId: appId) {
            result = "actual"
        }

        let action = NotificationService.shared.takeSteamAuthorizationResumption(appId: appId)
        await action?()

        XCTAssertEqual(result, "actual")
    }

    func testEULAAlertRegistersTheOriginalLaunchContinuation() async {
        let appId = "test-alert-\(UUID().uuidString)"
        var resumed = false

        NotificationService.shared.alert(
            title: "Licencia pendiente",
            body: "Revisa el acuerdo en Steam.",
            actionTitle: "Abrir Steam",
            action: .showSteamClient,
            steamAppId: appId,
            resumeAfterSteamAuthorization: {
                resumed = true
            }
        )

        let action = NotificationService.shared.takeSteamAuthorizationResumption(appId: appId)
        XCTAssertNotNil(action)
        await action?()
        XCTAssertTrue(resumed)
    }
}
