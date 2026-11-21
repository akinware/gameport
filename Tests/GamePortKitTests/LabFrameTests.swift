import XCTest
@testable import GamePortKit
#if os(macOS)
import CoreGraphics
#endif

final class LabFrameTests: XCTestCase {
    private func solid(_ brightness: UInt8) -> LabFrameSignature {
        LabFrameSignature(luminance: Array(repeating: brightness, count: 64))!
    }

    private func repeated(_ frame: LabFrameSignature) -> LabFrameSequence {
        var sequence = LabFrameSequence()
        for time in stride(from: 5.0, through: 25, by: 5) { sequence.record(frame, window: 1, at: time) }
        return sequence
    }

    func testMeanAndPerceptualHash() throws {
        XCTAssertNil(LabFrameSignature(luminance: [0]))
        let stripes = (0..<64).map { UInt8($0.isMultiple(of: 2) ? 60 : 120) }
        let first = try XCTUnwrap(LabFrameSignature(luminance: stripes))
        XCTAssertEqual(first.mean, 90)
        XCTAssertEqual(first.hash.nonzeroBitCount, 32)
        XCTAssertTrue(first.resembles(try XCTUnwrap(LabFrameSignature(luminance: stripes.map { $0 + 2 }))))
        XCTAssertFalse(first.resembles(try XCTUnwrap(LabFrameSignature(luminance: Array(stripes.reversed())))))
        XCTAssertFalse(solid(190).resembles(solid(200)))
        XCTAssertTrue(solid(6).isBlack)
        XCTAssertFalse(solid(7).isBlack)
    }

    func testPersistentTailAndMissingOrRecoveredFrames() {
        var sequence = repeated(solid(4))
        XCTAssertEqual(sequence.finding(at: 26), .black)
        XCTAssertNil(sequence.finding(at: 35), "capture stopped")
        sequence.record(solid(6), window: 1, at: 31)
        XCTAssertEqual(sequence.finding(at: 31), .black)
        sequence.record(solid(200), window: 1, at: 36)
        XCTAssertNil(sequence.finding(at: 36), "the game recovered")
        sequence = repeated(solid(120))
        XCTAssertEqual(sequence.finding(at: 25), .unchanged)
        sequence.record(solid(120), window: 2, at: 30)
        XCTAssertNil(sequence.finding(at: 30), "a different window must start a fresh streak")
        sequence = repeated(solid(120))
        sequence.record(solid(120), window: 1, at: 34)
        XCTAssertNil(sequence.finding(at: 34), "a missing capture breaks the streak")
    }

    func testShortStreaksAndGradualChangesAreNotFrozen() {
        var sequence = LabFrameSequence()
        for time in 0..<20 { sequence.record(solid(80), window: 1, at: Double(time)) }
        XCTAssertNil(sequence.finding(at: 19))
        for step in 0..<12 {
            sequence.record(solid(UInt8(80 + step * 2)), window: 1, at: 20 + Double(step * 5))
        }
        XCTAssertNil(sequence.finding(at: 75))
    }

    func testVisualVerdictsAndEvidence() throws {
        let samples: [MetalHUDLog.Sample] = [.init(time: 95, pid: 2, frame: 200), .init(time: 99, pid: 2, frame: 300)]
        XCTAssertEqual(LabResult.verdict(samples, end: 100), .works)
        XCTAssertEqual(LabResult.verdict(samples, end: 100, visual: .black), .blackScreen)
        XCTAssertEqual(LabResult.verdict(samples, end: 100, visual: .unchanged), .unchangedImage)
        XCTAssertEqual(LabResult.verdict(samples, end: 100, crashSigns: ["page fault"], visual: .unchanged), .stopped)
        XCTAssertEqual(LabResult.verdict(samples, end: 100, gameExited: true, visual: .black), .stopped)
        XCTAssertEqual(LabResult.verdict([], end: 100, gameStarted: false, visual: .black), .noFrames)
        XCTAssertEqual(LabResult.verdict([], end: 100, visual: .unchanged), .noFrames)
        let recipe = Recipe(id: "g", title: "Game", renderer: .dxmt, status: .community)
        var run = LabResult(profileID: "g", renderer: .dxmt, sync: .msync, engineID: "e", macOS: "14",
                            machine: "Mac", startedAt: Date(), seconds: 90, verdict: .unchangedImage, hudLog: "hud")
        XCTAssertEqual(Evidence.of(recipe, results: [run]).level, .community)
        XCTAssertNil(LabResult.best([run]))
        XCTAssertTrue(run.summary.contains("possible freeze or idle scene"))
        run.verdict = .blackScreen
        XCTAssertEqual(Evidence.of(recipe, results: [run]).level, .labFailed)
        XCTAssertNil(LabResult.best([run]))
        XCTAssertEqual(try JSONDecoder().decode(LabResult.self, from: JSONEncoder().encode(run)).verdict, .blackScreen)
    }

    func testSteamLaunchingAGameIsNotTheGameProcess() {
        let listing = #"""
        12 C:\Program Files (x86)\Steam\steam.exe C:\Steam\steamapps\common\Demo\run.exe
        34 C:\STEAM\STEAMAPPS\COMMON\Demo\run.EXE --windowed
        """#
        XCTAssertEqual(LabResult.gameProcessIDs(inProcessList: listing), [34])
    }

    #if os(macOS)
    func testDarwinProcessMatchingUsesTheExactRunMarkerAndGameExecutable() throws {
        let marker = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Use a test-owned executable: macOS redacts the environment of protected system
        // binaries. This fixture also reproduces Wine's NUL padding after the game title.
        let game = directory.appendingPathComponent(#"C:\Steam\steamapps\common\Trial\game.exe"#)
        let source = directory.appendingPathComponent("game.c")
        try Data("""
        #include <string.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            if (argc > 1) memset(argv[1], 0, strlen(argv[1]));
            return sleep(15);
        }
        """.utf8).write(to: source)
        try Shell.run("/usr/bin/cc", [source.path, "-o", game.path])
        let child = Process()
        child.executableURL = game
        child.arguments = ["padding"]
        child.environment = [LabWindowCapture.markerKey: marker]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        XCTAssertTrue(LabWindowCapture.belongsToTrial(child.processIdentifier, marker: marker))
        XCTAssertFalse(LabWindowCapture.belongsToTrial(child.processIdentifier, marker: String(marker.dropLast())))
    }

    func testCapturedImageExcludesChromeAndTransparency() throws {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 160, height: 160, bitsPerComponent: 8, bytesPerRow: 640,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.clear(CGRect(x: 0, y: 0, width: 160, height: 160))
        XCTAssertNil(LabWindowCapture.signature(try XCTUnwrap(bitmap.makeImage())))
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
        bitmap.setFillColor(gray: 0, alpha: 1)
        bitmap.fill(CGRect(x: 20, y: 20, width: 120, height: 120))
        let frame = try XCTUnwrap(LabWindowCapture.signature(try XCTUnwrap(bitmap.makeImage())))
        XCTAssertTrue(frame.isBlack)
    }
    #endif
}
