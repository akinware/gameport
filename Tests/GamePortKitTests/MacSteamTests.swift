import XCTest
@testable import GamePortKit

final class MacSteamTests: XCTestCase {
    func testSignedInAfterLogOnResponse() {
        let log = """
        [2026-11-22 17:12:56] [Logged Off, 0, 0] [U:1:0] CCMInterface::SetSteamID( [U:1:0] )
        [2026-11-22 17:12:59] [Connected, 4, 7] [U:1:1] Logging on [U:1:1]
        [2026-11-22 17:12:59] [Logging On, 4, 7] [U:1:1] RecvMsgClientLogOnResponse() : [U:1:1] 'OK'
        [2026-11-22 17:12:59] [Logged On, 4, 7] [U:1:1] RecvMsgClientLogOnResponse() : processing complete
        """
        XCTAssertEqual(MacSteam.parseSignIn(connectionLog: log), .signedIn)
    }

    func testWindowsLineEndings() {
        // Mac Steam writes CRLF; in Swift "\r\n" is one Character, so splitting on "\n" alone fails.
        let log = "[2026-11-22 17:17:53] [Logged Off, 0, 0] [U:1:1] Log session ended\r\n"
            + "[2026-11-22 17:17:59] [Logged On, 4, 7] [U:1:1] RecvMsgClientLogOnResponse() : processing complete\r\n"
            + "[2026-11-22 17:18:00] CClientJobGetClientUpdateHosts: cached version not expired\r\n"
        XCTAssertEqual(MacSteam.parseSignIn(connectionLog: log), .signedIn)
    }

    func testSessionReplacedIsDetected() {
        let log = """
        [2026-11-22 14:00:00] [Logged On, 4, 7] [U:1:1] RecvMsgClientLogOnResponse() : processing complete
        [2026-11-22 14:23:23] [Logged Off, 4, 0] [U:1:1] ConnectionDisconnected() not auto reconnecting due to Session Replaced
        [2026-11-22 14:23:23] [Logged Off, 0, 0] [U:1:1] Sending SteamServersDisconnected_t because we were logged on
        """
        XCTAssertEqual(MacSteam.parseSignIn(connectionLog: log), .signedOut(sessionReplaced: true))
    }

    func testQuitSteamIsUnknownAndRelogClearsReplacement() {
        let quit = """
        [2026-11-22 15:19:19] [Logged Off, 0, 0] [U:1:1] ResetVoiceRecording()
        [2026-11-22 15:19:19] [Logged Off, 0, 0] [U:1:1] Log session ended
        """
        XCTAssertEqual(MacSteam.parseSignIn(connectionLog: quit), .unknown)

        let relogged = """
        [2026-11-22 14:23:23] [Logged Off, 4, 0] [U:1:1] not auto reconnecting due to Session Replaced
        [2026-11-22 14:30:00] [Logging On, 4, 7] [U:1:1] Logging on
        """
        XCTAssertEqual(MacSteam.parseSignIn(connectionLog: relogged), .connecting)
        XCTAssertEqual(MacSteam.parseSignIn(connectionLog: ""), .unknown)
    }

    func testBridgeExitDiagnosisNamesMacSteam() {
        let notRunning = GamePort.bridgeExitDiagnosis(seconds: 4, exitStatus: 1, macSteamRunning: false,
                                                      macSteamSignIn: .unknown, crashSigns: [], logPath: "/x.log")
        XCTAssertTrue(notRunning.explanation.contains("Mac Steam is not running"))

        let replaced = GamePort.bridgeExitDiagnosis(seconds: 4, exitStatus: 1, macSteamRunning: true,
                                                    macSteamSignIn: .signedOut(sessionReplaced: true), crashSigns: [], logPath: "/x.log")
        XCTAssertTrue(replaced.explanation.contains("signed out"))

        let other = GamePort.bridgeExitDiagnosis(seconds: 4, exitStatus: 3, macSteamRunning: true,
                                                 macSteamSignIn: .signedIn, crashSigns: [], logPath: "/x.log")
        XCTAssertTrue(other.explanation.contains("exit status 3"))
        XCTAssertTrue(other.explanation.contains("/x.log"))
    }
}
