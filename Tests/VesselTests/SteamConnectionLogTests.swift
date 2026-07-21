import Foundation
import XCTest
@testable import Vessel

final class SteamConnectionLogTests: XCTestCase {
    func testCurrentAttemptDoesNotReuseHistoricalLoggedOn() {
        let old = "[2026-07-18] [Logged On, 4, 7] processing complete\n"
        let current = "[2026-07-19] Client version: 1782866176\n"
        let data = Data((old + current).utf8)

        XCTAssertEqual(
            SteamConnectionLogState.parse(data, afterByteOffset: Data(old.utf8).count),
            .starting
        )
    }

    func testCurrentAttemptAcceptsLoggedOnAfterBaseline() {
        let old = "[2026-07-18] [Logged On, 4, 7] processing complete\n"
        let current = "[2026-07-19] Client version: 1782866176\n"
            + "[2026-07-19] [Logged On, 4, 7] processing complete\n"

        XCTAssertEqual(
            SteamConnectionLogState.parse(
                Data((old + current).utf8),
                afterByteOffset: Data(old.utf8).count
            ),
            .connected
        )
    }

    func testCurrentAttemptAcceptsSteamCRLFLoggedOnAfterBaseline() {
        let old = "[2026-07-18] [Logged On, 4, 7] processing complete\r\n"
        let current = "[2026-07-19] Client version: 1782866176\r\n"
            + "[2026-07-19] [Logged Off, 4, 0] scheduling connection\r\n"
            + "[2026-07-19] [Logged On, 4, 7] processing complete\r\n"

        XCTAssertEqual(
            SteamConnectionLogState.parse(
                Data((old + current).utf8),
                afterByteOffset: Data(old.utf8).count
            ),
            .connected
        )
    }

    func testAccessDeniedSurvivesTheFollowingLoggedOffLines() {
        let text = "[Logging On, 4, 7] RecvMsgClientLogOnResponse() : 'Access Denied'\n"
            + "Clearing in-memory token - 15 (Access Denied): LogonFailureReceived(2)\n"
            + "[Logged Off, 4, 0] ConnectionDisconnected() not auto reconnecting due to Access Denied\n"

        XCTAssertEqual(SteamConnectionLogState.parse(Data(text.utf8)), .accessDenied)
    }

    func testNewClientGenerationCanRecoverAfterOldAccessDenied() {
        let text = "[Logging On, 4, 7] RecvMsgClientLogOnResponse() : 'Access Denied'\n"
            + "[Logged Off, 4, 0] ConnectionDisconnected()\n"
            + "Client version: 1782866176\n"
            + "[Logged On, 4, 7] processing complete\n"

        XCTAssertEqual(SteamConnectionLogState.parse(Data(text.utf8)), .connected)
    }

    func testRotatedLogDoesNotApplyOldOffsetToLongerNewFile() {
        let baseline = Data(("[old] [Logged On, 4, 7] processing complete\n" + String(repeating: "x", count: 40)).utf8)
        let rotated = Data((String(repeating: "new generation filler\n", count: 8)
            + "[new] Client version: 1782866176\n"
            + "[new] [Logged On, 4, 7] processing complete\n").utf8)

        XCTAssertGreaterThan(rotated.count, baseline.count)
        XCTAssertEqual(
            SteamConnectionLogState.parse(rotated, afterBaseline: baseline),
            .connected
        )
    }

    func testRecentTailIgnoresLargeHistoricalFailuresAndFindsCurrentLogin() {
        let historical = "[old] RecvMsgClientLogOnResponse() : 'Access Denied'\n"
            + "[old] [Logged Off, 4, 0] ConnectionDisconnected()\n"
            + String(repeating: "historical filler that must not govern the live state\n", count: 4_000)
        let current = "[new] Client version: 1782866176\n"
            + "[new] [Logged On, 4, 7] processing complete\n"
        let data = Data((historical + current).utf8)

        XCTAssertEqual(
            SteamConnectionLogState.parseRecent(data, maximumBytes: 4_096),
            .connected
        )
    }

    func testRecentTailParsesSteamCRLFGeneration() {
        let historical = String(repeating: "[old] historical filler\r\n", count: 4_000)
        let current = "[new] Client version: 1782866176\r\n"
            + "[new] [Logged Off, 4, 0] scheduling connection\r\n"
            + "[new] [Logged On, 4, 7] processing complete\r\n"

        XCTAssertEqual(
            SteamConnectionLogState.parseRecent(
                Data((historical + current).utf8),
                maximumBytes: 4_096
            ),
            .connected
        )
    }

    func testSessionReplacementRemainsTerminalAfterDisconnectLines() {
        let text = """
        [2026-07-21 07:58:13] [Logged On, 4, 7] RecvMsgClientLoggedOff('Session Replaced')\r
        [2026-07-21 07:58:13] [Logged Off, 4, 0] ConnectionDisconnected('Disconnected By Remote Host') : 'Session Replaced'\r
        [2026-07-21 07:58:13] ConnectionDisconnected() not auto reconnecting due to Session Replaced\r
        """

        XCTAssertEqual(
            SteamConnectionLogState.parseRecent(Data(text.utf8)),
            .sessionReplaced
        )
    }
}
