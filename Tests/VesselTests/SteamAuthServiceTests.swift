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
}
