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

    func testRememberedAccountsNeedTokenStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gp-qr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = DepotDownloaderTool(paths: Paths(root: root))
        tool.rememberAccount("gamer_one")
        XCTAssertNil(tool.cachedAccount(preferred: "gamer_one"), "no account.config yet: QR is still needed")

        let store = tool.homeDir.appendingPathComponent("Library/Application Support/IsolatedStorage/abc/AssemFiles", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data([1]).write(to: store.appendingPathComponent("account.config"))
        tool.rememberAccount("second")
        XCTAssertEqual(tool.rememberedAccounts(), ["second", "gamer_one"])
        XCTAssertEqual(tool.cachedAccount(preferred: "GAMER_ONE"), "gamer_one")
        XCTAssertEqual(tool.cachedAccount(preferred: "someone-else"), "second")
        tool.forgetAccount("second")
        XCTAssertEqual(tool.cachedAccount(), "gamer_one")
        tool.signOutAll()
        XCTAssertNil(tool.cachedAccount())
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
