import CoreImage
import Foundation
import XCTest
@testable import GamePortKit

final class SteamQRDownloaderTests: XCTestCase {
    /// Renders `text` as a QR code in DepotDownloader's console format (`██` per dark module,
    /// two spaces per light module, 4-module quiet zone).
    private func depotDownloaderArt(for text: String) throws -> [String] {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        let image = try XCTUnwrap(filter.outputImage)
        let ctx = CIContext()
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(image, toBitmap: &pixels, rowBytes: w * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        // CIQRCodeGenerator adds a 1-module margin; DepotDownloader draws a 4-module one.
        let quiet = 4
        let blank = String(repeating: " ", count: (w - 2 + quiet * 2) * 2)
        var lines = Array(repeating: blank, count: quiet)
        for y in 1..<(h - 1) {
            var line = String(repeating: "  ", count: quiet)
            for x in 1..<(w - 1) {
                line += pixels[(y * w + x) * 4] < 128 ? "██" : "  "
            }
            line += String(repeating: "  ", count: quiet)
            lines.append(line)
        }
        lines += Array(repeating: blank, count: quiet)
        return lines
    }

    func testParsesDepotDownloaderQRArtAndDecodesURL() throws {
        let url = "https://s.team/q/1/1234567890123456789"
        let art = try depotDownloaderArt(for: url)
        let code = try XCTUnwrap(SteamQRCode.parse(asciiLines: art))
        XCTAssertEqual(code.modules.count, code.modules.first?.count)
        XCTAssertEqual((code.size - 17) % 4, 0)
        XCTAssertTrue(code.modules[0][0], "top-left finder pattern is dark")
        XCTAssertEqual(code.url, url)
        XCTAssertFalse(code.terminalArt().isEmpty)
    }

    func testParserEmitsQRWithoutWaitingForTrailingOutput() throws {
        let url = "https://s.team/q/1/9876543210"
        var parser = DepotDownloaderOutputParser()
        var events: [SteamQRDownloadEvent] = []
        for line in ["Connecting to Steam3... Done!", "Logging in with QR code...", DepotDownloaderOutputParser.qrHeader] {
            events += parser.consume(line).events
        }
        let art = try depotDownloaderArt(for: url)
        // Feed everything except the trailing quiet-zone rows: DepotDownloader then blocks
        // until the phone approves, so the QR must already be out.
        for line in art.dropLast(4) { events += parser.consume(line).events }
        guard case .qrCode(let code)? = events.first(where: { if case .qrCode = $0 { return true }; return false }) else {
            return XCTFail("no QR event in \(events)")
        }
        XCTAssertEqual(code.url, url)
        XCTAssertEqual(events.last, .waitingForMobileApproval)
        XCTAssertTrue(events.contains(.status("Connecting to Steam…")))
        // Trailing blank rows are ignored.
        for line in art.suffix(4) { XCTAssertTrue(parser.consume(line).events.isEmpty) }
    }

    func testParsesSignInProgressAndFailures() {
        var parser = DepotDownloaderOutputParser()
        XCTAssertEqual(parser.consume("Logging 'gamer_one' into Steam3...").events, [.signedIn(account: "gamer_one")])
        XCTAssertEqual(parser.signedInAccount, "gamer_one")
        _ = parser.consume("Processing depot 261551")
        XCTAssertEqual(
            parser.consume(" 36.60% /Users/x/depots/261550/bin/Win64_Shipping_Client/Bannerlord.exe").events,
            [.downloading(percent: 36.6, detail: "Bannerlord.exe")]
        )
        XCTAssertEqual(parser.consume("100.00% /tmp/a b/c.dll").events, [.downloading(percent: 100, detail: "c.dll")])
        XCTAssertEqual(parser.consume("Access token was rejected (Expired).").failure, .needsQRLogin("Access token was rejected (Expired)."))
        XCTAssertEqual(parser.consume("Enter account password for \"x\": ").failure?.isNeedsQR, true)
        if case .fatal? = parser.consume("App 261550 (Bannerlord) is not available from this account.").failure {} else {
            XCTFail("unowned app should be fatal")
        }
        _ = parser.consume("Error: InitializeSteam failed")
        XCTAssertTrue(parser.lastError?.contains("not owned") == true, "keeps the specific error")
    }

    func testArgumentsForEachLoginMode() {
        let dir = URL(fileURLWithPath: "/tmp/depots/261550", isDirectory: true)
        let qr = DepotDownloaderTool.arguments(appID: 261550, directory: dir, login: .qrCode)
        XCTAssertEqual(Array(qr.prefix(8)), ["-app", "261550", "-os", "windows", "-osarch", "64", "-dir", dir.path])
        XCTAssertTrue(qr.contains("-qr") && qr.contains("-remember-password"))
        XCTAssertFalse(qr.contains("-username"), "DepotDownloader rejects -qr together with -username")
        let remembered = DepotDownloaderTool.arguments(appID: 261550, directory: dir, login: .remembered(account: "gamer_one"), validate: true)
        XCTAssertTrue(remembered.contains("-username") && remembered.contains("gamer_one") && remembered.contains("-validate"))
        XCTAssertFalse(remembered.contains("-qr"))
        let anon = DepotDownloaderTool.arguments(appID: 1007, directory: dir, login: .anonymous)
        XCTAssertFalse(anon.contains("-qr") || anon.contains("-username") || anon.contains("-remember-password"))
        XCTAssertNotEqual(DepotDownloaderTool.loginID(appID: 1), DepotDownloaderTool.loginID(appID: 2))
    }

    func testPinnedReleaseAssetsAreHTTPSAndSHA256() {
        for asset in [DepotDownloaderTool.arm64, DepotDownloaderTool.x64] {
            XCTAssertEqual(asset.url.scheme, "https")
            XCTAssertTrue(asset.url.path.contains(DepotDownloaderTool.releaseTag))
            XCTAssertEqual(asset.sha256.count, 64)
        }
    }

    func testRememberedAccountsNeedATokenForThatAccount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gp-qr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // Never touch the real ~/Library/Application Support/IsolatedStorage from tests.
        let isolated = root.appendingPathComponent("IsolatedStorage", isDirectory: true)
        let tool = DepotDownloaderTool(paths: Paths(root: root), tokenStoreRoots: [isolated])
        tool.rememberAccount("gamer_one")
        XCTAssertNil(tool.cachedAccount(preferred: "gamer_one"), "no account.config yet: QR is still needed")

        // DepotDownloader writes a raw-DEFLATE protobuf keyed by account name.
        let store = isolated.appendingPathComponent("abc/def/Url.xyz/AssemFiles", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let config = store.appendingPathComponent("account.config")
        let payload = Data("\u{0A}\u{09}gamer_one\u{12}\u{05}token".utf8)
        try ((payload as NSData).compressed(using: .zlib) as Data).write(to: config)
        XCTAssertEqual(DepotDownloaderTool.inflate(try Data(contentsOf: config)), payload)

        tool.rememberAccount("second")
        XCTAssertEqual(tool.rememberedAccounts(), ["gamer_one"], "second has no token in the store")
        XCTAssertEqual(tool.cachedAccount(preferred: "GAMER_ONE"), "gamer_one")
        XCTAssertEqual(tool.cachedAccount(preferred: "someone-else"), "gamer_one")
        tool.forgetAccount("gamer_one")
        XCTAssertNil(tool.cachedAccount())
        tool.rememberAccount("gamer_one")
        tool.signOutAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path), "sign-out deletes the token store")
        XCTAssertNil(tool.cachedAccount())
    }

    func testFindsLeftoverDownloadsByBinaryAndDirectory() {
        let bin = "/Users/x/Library/Application Support/GamePort/tools/depotdownloader/DepotDownloader"
        let dir = "/Users/x/Library/Application Support/GamePort/tools/depots/261550"
        let ps = """
          101 \(bin) -app 261550 -os windows -osarch 64 -dir \(dir) -qr -remember-password -loginid 1
          102 \(bin) -app 1007 -os windows -osarch 64 -dir \(dir)0 -loginid 2
          103 /usr/local/bin/DepotDownloader -app 261550 -dir \(dir)
          104 /bin/zsh -c echo \(bin) -dir \(dir)
        """
        XCTAssertEqual(DepotDownloaderTool.matchingPIDs(psOutput: ps, binary: bin, directory: dir), [101])
        XCTAssertEqual(DepotDownloaderTool.matchingPIDs(psOutput: ps, binary: bin, directory: nil), [101, 102])
    }

    func testLogRedactsAccountAndFindsAppID() {
        let args = DepotDownloaderTool.arguments(appID: 261550, directory: URL(fileURLWithPath: "/tmp/d"), login: .remembered(account: "gamer_one"))
        XCTAssertEqual(ProcessBox.appID(in: args), "261550")
        XCTAssertFalse(ProcessBox.redacted(args).contains("gamer_one"))
        XCTAssertTrue(SteamQRDownloadError.failed(status: 1, detail: "Encountered 401 for chunk").description.contains("401"))
    }

    func testDepotCompletionStates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gp-depot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let depots = SteamDepotManager(paths: Paths(root: root))
        let dir = depots.depotDirectory(appID: 42)
        let exeDir = dir.appendingPathComponent("bin/Win64", isDirectory: true)
        try FileManager.default.createDirectory(at: exeDir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 2 * 1024 * 1024).write(to: exeDir.appendingPathComponent("Game.exe"))

        // Legacy folder (no DepotDownloader work dir, no manifest): playable.
        XCTAssertNotNil(depots.downloadedExecutable(appID: 42))

        // DepotDownloader pre-allocated files but has not finished: not playable.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".DepotDownloader"), withIntermediateDirectories: true)
        XCTAssertNil(depots.downloadedExecutable(appID: 42))

        try SteamDepotManager.markDownloadComplete(appID: 42, name: "Game", in: dir)
        XCTAssertTrue(SteamDepotManager.isDownloadComplete(appID: 42, in: dir))
        XCTAssertEqual(depots.downloadedExecutable(appID: 42, preferredName: "Game")?.lastPathComponent, "Game.exe")

        // steamcmd mid-update manifest (StateFlags 1026) is not playable.
        try #""AppState" { "appid" "42" "StateFlags" "1026" }"#.write(to: SteamDepotManager.appManifestURL(appID: 42, in: dir), atomically: true, encoding: .utf8)
        XCTAssertFalse(SteamDepotManager.isDownloadComplete(appID: 42, in: dir))
    }
}

private extension DepotDownloaderOutputParser.Failure {
    var isNeedsQR: Bool { if case .needsQRLogin = self { return true }; return false }
}

final class SteamLaunchProgressTests: XCTestCase {
    private let consoleTF2 = """
    [2026-11-22 16:33:51] Console Log Start
    [2026-11-22 16:34:13] ExecCommandLine: ""C:\\Program Files (x86)\\Steam\\steam.exe" -silent -applaunch 440"
    [2026-11-22 16:34:13] GameAction [AppID 440, ActionID 1] : LaunchApp changed task to UpdatingAppInfo with ""
    [2026-11-22 16:34:13] GameAction [AppID 440, ActionID 1] : LaunchApp changed task to CheckShaderDepotManifest with ""
    [2026-11-22 16:34:13] GameAction [AppID 440, ActionID 1] : LaunchApp changed task to RunningInstallScript with ""
    """

    func testStartsAtSteamThenFollowsSignIn() {
        XCTAssertEqual(SteamLaunchProgress.parse(appID: 440, console: "", connection: "").stage, .startingSteam)
        let conn = "[2026-11-22 16:34:10] [Connected, 4, 7] [U:1:1] Logging on [U:1:1]"
        XCTAssertEqual(SteamLaunchProgress.parse(appID: 440, console: "", connection: conn).stage, .signingIn)
        let done = conn + "\n[2026-11-22 16:34:11] [Logged On, 4, 7] [U:1:1] RecvMsgClientLogOnResponse() : processing complete"
        XCTAssertEqual(SteamLaunchProgress.parse(appID: 440, console: "", connection: done).stage, .checkingForUpdates)
    }

    func testReadsLaunchTasksForThatAppOnly() {
        let snap = SteamLaunchProgress.parse(appID: 440, console: consoleTF2, connection: "")
        XCTAssertEqual(snap.stage, .preparingGame)
        XCTAssertEqual(snap.steamTask, "RunningInstallScript")
        XCTAssertNil(snap.waitingForUser)
        XCTAssertEqual(SteamLaunchProgress.parse(appID: 730, console: consoleTF2, connection: "").stage, .startingSteam)

        let started = consoleTF2 + """

        [2026-11-22 16:34:19] GameAction [AppID 440, ActionID 1] : LaunchApp changed task to CreatingProcess with ""
        [2026-11-22 16:34:19] GameAction [AppID 440, ActionID 1] : LaunchApp waiting for user response to CreatingProcess ""
        [2026-11-22 16:34:19] GameAction [AppID 440, ActionID 1] : LaunchApp continues with user response "CreatingProcess"
        [2026-11-22 16:34:19] GameAction [AppID 440, ActionID 1] : LaunchApp changed task to Completed with ""
        """
        let s2 = SteamLaunchProgress.parse(appID: 440, console: started, connection: "")
        XCTAssertEqual(s2.stage, .startingGame)
        XCTAssertNil(s2.waitingForUser, "CreatingProcess is answered by Steam itself")
    }

    func testFlagsHiddenPromptsAndFailures() {
        let prompt = consoleTF2 + "\n[x] GameAction [AppID 440, ActionID 1] : LaunchApp waiting for user response to IgnorePendingCloudSessions \"\""
        let snap = SteamLaunchProgress.parse(appID: 440, console: prompt, connection: "")
        XCTAssertEqual(snap.waitingForUser, "IgnorePendingCloudSessions")
        XCTAssertTrue(SteamLaunchProgress.describePrompt("IgnorePendingCloudSessions").contains("Cloud"))
        let p = LaunchProgress(title: "TF2", stage: snap.stage, seconds: 10, secondsWithoutProgress: 2, waitingForUser: "x")
        XCTAssertTrue(p.looksStuck)

        let failed = "[x] GameAction [AppID 440, ActionID 1] : LaunchApp changed task to Failed with \"\""
        XCTAssertTrue(SteamLaunchProgress.parse(appID: 440, console: failed, connection: "").failed)

        XCTAssertFalse(LaunchProgress(title: "", stage: .preparingGame, seconds: 40, secondsWithoutProgress: 30).looksStuck)
        XCTAssertTrue(LaunchProgress(title: "", stage: .preparingGame, seconds: 120, secondsWithoutProgress: 90).looksStuck)
        XCTAssertFalse(LaunchProgress(title: "", stage: .updatingGame, seconds: 600, secondsWithoutProgress: 300).looksStuck,
                       "updates may go quiet for a long time")
        XCTAssertTrue(LaunchState.preparing(profileID: "a", progress: p).isLaunching)
        XCTAssertEqual(LaunchState.running(profileID: "a", seconds: 1, fps: nil).profileID, "a")
    }
}
