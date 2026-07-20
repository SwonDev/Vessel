import Foundation
import XCTest
@testable import Vessel

final class SteamAuthServiceTests: XCTestCase {
    private func jwt(subject: String = "76561198000000000", audiences: [String], expiresIn: TimeInterval) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none"])
        let payload = try JSONSerialization.data(withJSONObject: [
            "sub": subject,
            "aud": audiences,
            "exp": Date().timeIntervalSince1970 + expiresIn
        ])
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(base64URL(header)).\(base64URL(payload)).signature"
    }

    func testAcceptsCurrentSteamClientRefreshForSameAccount() throws {
        let token = try jwt(audiences: ["client", "web", "renew", "derive"], expiresIn: 3_600)
        XCTAssertTrue(SteamAuthService.isClientRefreshTokenUsable(
            token,
            storedSteamID: "76561198000000000"
        ))
    }

    func testRejectsWrongAudienceAccountAndExpiry() throws {
        let mobile = try jwt(audiences: ["mobile", "web", "renew", "derive"], expiresIn: 3_600)
        let client = try jwt(audiences: ["client", "web", "renew", "derive"], expiresIn: 3_600)
        let expired = try jwt(audiences: ["client", "web", "renew", "derive"], expiresIn: -3_600)

        XCTAssertFalse(SteamAuthService.isClientRefreshTokenUsable(mobile, storedSteamID: "76561198000000000"))
        XCTAssertFalse(SteamAuthService.isClientRefreshTokenUsable(client, storedSteamID: "76561198000000001"))
        XCTAssertFalse(SteamAuthService.isClientRefreshTokenUsable(expired, storedSteamID: "76561198000000000"))
    }

    func testSteamClientDeviceIdentityIsStableAndWindowsShaped() {
        XCTAssertEqual(SteamAuthService.steamMachineName(hostname: "vessel-mac"), "DESKTOP-HXXOWBR")
        XCTAssertEqual(
            SteamAuthService.steamMachineID(accountName: "vessel-user"),
            SteamAuthService.steamMachineID(accountName: "vessel-user")
        )
        XCTAssertNotEqual(
            SteamAuthService.steamMachineID(accountName: "vessel-user"),
            SteamAuthService.steamMachineID(accountName: "other-user")
        )
        XCTAssertTrue(SteamAuthService.steamMachineID(accountName: "vessel-user").starts(with: Data([0])))
        XCTAssertTrue(SteamAuthService.steamMachineID(accountName: "vessel-user").suffix(2) == Data([8, 8]))
    }

    func testExistingClientSessionIsOnlyReplacedByMatchingFreshCMLogin() throws {
        let current = try jwt(audiences: ["client", "web"], expiresIn: 3_600)
        let other = try jwt(subject: "76561198000000001", audiences: ["client", "web"], expiresIn: 3_600)

        XCTAssertFalse(SteamAuthService.shouldSeedStoredRefresh(
            hasExistingClientSession: true,
            storedRefresh: current,
            pendingFingerprint: ""
        ))
        XCTAssertFalse(SteamAuthService.shouldSeedStoredRefresh(
            hasExistingClientSession: true,
            storedRefresh: current,
            pendingFingerprint: SteamAuthService.refreshFingerprint(other)
        ))
        XCTAssertTrue(SteamAuthService.shouldSeedStoredRefresh(
            hasExistingClientSession: true,
            storedRefresh: current,
            pendingFingerprint: SteamAuthService.refreshFingerprint(current)
        ))
        XCTAssertTrue(SteamAuthService.shouldSeedStoredRefresh(
            hasExistingClientSession: false,
            storedRefresh: current,
            pendingFingerprint: ""
        ))
    }

    @MainActor
    func testSteamClientCMTransportLiveWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["VESSEL_STEAM_CM_LIVE_TEST"] == "1" else {
            throw XCTSkip("La prueba CM en vivo es optativa.")
        }
        let session = try await SteamAuthService().beginQR()
        XCTAssertGreaterThan(session.handle.clientID, 0)
        XCTAssertFalse(session.handle.requestID.isEmpty)
        XCTAssertTrue(session.challengeURL.hasPrefix("https://s.team/q/"))
    }
}
