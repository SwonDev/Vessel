import XCTest
@testable import Vessel

final class SteamClientPreferencesTests: XCTestCase {
    func testMarksOnlyGamepadRecommendedForTheRequestedApp() throws {
        let original = Data("""
        "UserLocalConfigStore"
        {
        \t"WebStorage"
        \t{
        \t\t"Deck_ConfiguratorInterstitialsVersionSeen_GamepadRecommended"\t\t"1"
        \t\t"Deck_ConfiguratorInterstitialsCheckbox_GamepadRecommended"\t\t"0"
        \t\t"Deck_ConfiguratorInterstitialApps_GamepadRecommended"\t\t"[1004640]"
        \t}
        \t"UserAppConfig"
        \t{
        \t}
        }
        """.utf8)

        let updated = try XCTUnwrap(SteamClientPreferences.markingGamepadRecommendationSeen(
            appId: "2842890",
            in: original
        ))
        let text = String(decoding: updated, as: UTF8.self)
        XCTAssertTrue(text.contains("\"Deck_ConfiguratorInterstitialApps_GamepadRecommended\"\t\t\"[1004640,2842890]\""))
        XCTAssertFalse(text.contains("GamepadRequired"))
        XCTAssertFalse(text.contains("VRRequired"))
        XCTAssertTrue(SteamClientPreferences.isGamepadRecommendationSeen(appId: "2842890", in: updated))
    }

    func testCreatesMissingSteamWebStorageKeysAndIsIdempotent() throws {
        let original = Data("""
        "UserLocalConfigStore"
        {
        \t"WebStorage"
        \t{
        \t\t"Existing"\t\t"value"
        \t}
        }
        """.utf8)
        let first = try XCTUnwrap(SteamClientPreferences.markingGamepadRecommendationSeen(
            appId: "2842890",
            in: original
        ))
        let second = try XCTUnwrap(SteamClientPreferences.markingGamepadRecommendationSeen(
            appId: "2842890",
            in: first
        ))
        XCTAssertEqual(first, second)
        XCTAssertTrue(SteamClientPreferences.isGamepadRecommendationSeen(appId: "2842890", in: second))
        XCTAssertEqual(String(decoding: second, as: UTF8.self).components(separatedBy: "2842890").count - 1, 1)
    }

    func testRejectsInvalidAppIDAndUnrelatedVDF() {
        let unrelated = Data("\"Other\"\n{\n}\n".utf8)
        XCTAssertNil(SteamClientPreferences.markingGamepadRecommendationSeen(
            appId: "",
            in: unrelated
        ))
        XCTAssertNil(SteamClientPreferences.markingGamepadRecommendationSeen(
            appId: "28;42890",
            in: unrelated
        ))
        XCTAssertNil(SteamClientPreferences.markingGamepadRecommendationSeen(
            appId: "2842890",
            in: unrelated
        ))
    }
}
