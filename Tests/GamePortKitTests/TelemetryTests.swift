import XCTest
@testable import GamePortKit

final class TelemetryTests: XCTestCase {
    var temp: URL!
    var store: TelemetryStore!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("gameport-telemetry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        store = TelemetryStore(paths: Paths(root: temp))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testEnabledByDefaultAndRespectsOptOutAndEnv() throws {
        XCTAssertTrue(store.load().enabled)
        XCTAssertTrue(store.isEffectivelyEnabled(environment: [:]))
        XCTAssertFalse(store.isEffectivelyEnabled(environment: ["DO_NOT_TRACK": "1"]))
        XCTAssertFalse(store.isEffectivelyEnabled(environment: ["GAMEPORT_TELEMETRY": "0"]))

        try store.setEnabled(false)
        XCTAssertFalse(store.isEffectivelyEnabled(environment: [:]))

        let firstID = store.load().installID
        let rotated = try store.resetInstallID().installID
        XCTAssertNotEqual(firstID, rotated)
    }

    func testSanitizedPayloadStripsPIIAndSkipsInconclusiveRuns() throws {
        let base = LabResult(
            profileID: "secret-profile",
            recipeID: "team-fortress-2",
            renderer: .dxmt,
            sync: .msync,
            engineID: "x64-crossover26.3-hb20261014",
            engineArchitecture: .rosetta,
            macOS: "27.0.1",
            machine: "Apple M1",
            startedAt: Date(timeIntervalSince1970: 1_762_000_000),
            seconds: 180,
            verdict: .works,
            steady: LabStats(frames: 7200, seconds: 120, averageFPS: 60, typicalFPS: 60, slowestFPS: 45, stalls: 0, stallSeconds: 0, onePercentLowFPS: 48),
            whole: nil,
            hudLog: "/Users/alice/private/path.hud.log",
            frontmostShare: 1.0,
            gameStarted: true,
            crashSigns: [
                "Unhandled exception at /Users/alice/game.exe",
                "Steam's GPU process crashed 3 times",
                "DXVK pipeline-statistics query unsupported",
            ],
            vulkanDriver: .kosmickrisp,
            peakThermalState: .fair
        )

        let report = try XCTUnwrap(TelemetryReport.from(base, steamAppID: 440, installID: "anon-1"))
        XCTAssertEqual(report.macOS, "27.0")
        XCTAssertEqual(report.avgFPS, 60)
        XCTAssertEqual(report.onePercentLowFPS, 48)
        XCTAssertEqual(report.crashCodes, ["wine_exception", "steam_gpu_crash", "vulkan_query_unsupported"])

        let json = String(decoding: try JSONEncoder.pretty.encode(report), as: UTF8.self)
        XCTAssertFalse(json.contains("alice"))
        XCTAssertFalse(json.contains("secret-profile"))
        XCTAssertFalse(json.contains("hud.log"))

        var covered = base
        covered.verdict = .notVisible
        XCTAssertNil(TelemetryReport.from(covered, steamAppID: 440, installID: "anon-1"))

        var frozen = base
        frozen.verdict = .unchangedImage
        XCTAssertNil(TelemetryReport.from(frozen, steamAppID: 440, installID: "anon-1"))
    }

    func testEndpointRequiresHTTPS() {
        XCTAssertNil(store.endpoint(environment: [Brand.telemetryURLVariable: "http://example.com/v1/report"]))
        XCTAssertEqual(
            store.endpoint(environment: [Brand.telemetryURLVariable: "https://telemetry.example.com/v1/report"])?.absoluteString,
            "https://telemetry.example.com/v1/report"
        )
    }

    func testPlaySessionClassification() throws {
        // Running smoothly past 60s -> works
        let healthy = try XCTUnwrap(TelemetryReport.fromPlaySession(
            steamAppID: 440, recipeID: "team-fortress-2", renderer: .dxmt, vulkanDriver: .moltenvk,
            sync: .msync, engineID: "e1", engineArch: .rosetta, machine: "Apple M1", macOS: "27.2",
            gameStarted: true, playedSeconds: 95, stillRunning: true, crashSigns: [],
            peakThermalState: .nominal, installID: "anon-1"
        ))
        XCTAssertEqual(healthy.verdict, .works)
        XCTAssertNil(healthy.avgFPS)

        // Crashed early -> stopped with normalized code
        let crashed = try XCTUnwrap(TelemetryReport.fromPlaySession(
            steamAppID: 440, recipeID: "team-fortress-2", renderer: .dxvk, vulkanDriver: .moltenvk,
            sync: .msync, engineID: "e1", engineArch: .rosetta, machine: "Apple M1", macOS: "27.2",
            gameStarted: true, playedSeconds: 12, stillRunning: false,
            crashSigns: ["Unhandled exception at 0x1234"], peakThermalState: .nominal, installID: "anon-1"
        ))
        XCTAssertEqual(crashed.verdict, .stopped)
        XCTAssertEqual(crashed.crashCodes, ["wine_exception"])

        // Quick clean exit (< 60s, no crashes) -> nil (ignored)
        XCTAssertNil(TelemetryReport.fromPlaySession(
            steamAppID: 440, recipeID: "team-fortress-2", renderer: .dxmt, vulkanDriver: .moltenvk,
            sync: .msync, engineID: "e1", engineArch: .rosetta, machine: "Apple M1", macOS: "27.2",
            gameStarted: true, playedSeconds: 15, stillRunning: false, crashSigns: [],
            peakThermalState: .nominal, installID: "anon-1"
        ))

        // Never started with Steam GPU crash -> noFrames
        let noStart = try XCTUnwrap(TelemetryReport.fromPlaySession(
            steamAppID: 440, recipeID: "team-fortress-2", renderer: .dxvk, vulkanDriver: .kosmickrisp,
            sync: .msync, engineID: "e1", engineArch: .rosetta, machine: "Apple M1", macOS: "27.2",
            gameStarted: false, playedSeconds: 0, stillRunning: false,
            crashSigns: ["Steam's GPU process crashed 3 times"], peakThermalState: .nominal, installID: "anon-1"
        ))
        XCTAssertEqual(noStart.verdict, .noFrames)
        XCTAssertEqual(noStart.crashCodes, ["steam_gpu_crash"])
    }
}
