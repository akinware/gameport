import XCTest
@testable import GamePortKit

final class PlayHistoryTests: XCTestCase {
    var temp: URL!
    var paths: Paths!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-history-\(UUID().uuidString)")
        paths = Paths(root: temp)
        try FileManager.default.createDirectory(at: paths.profile("game"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func session(_ method: PlayRecord.Method, _ outcome: PlayRecord.Outcome, ago: TimeInterval = 0) -> PlayRecord {
        PlayRecord(startedAt: Date().addingTimeInterval(-ago), seconds: 120, method: method, outcome: outcome,
                    engineID: "e", renderer: .dxmt, vulkanDriver: .moltenvk, sync: .msync)
    }

    func testOutcome() {
        XCTAssertEqual(PlayRecord.outcome(gameStarted: false, seconds: 0, problems: []), .didNotStart)
        XCTAssertEqual(PlayRecord.outcome(gameStarted: true, seconds: 24, problems: []), .closedEarly)
        XCTAssertEqual(PlayRecord.outcome(gameStarted: true, seconds: 24, problems: [], failedExit: true), .crashed)
        XCTAssertEqual(PlayRecord.outcome(gameStarted: true, seconds: 24, problems: ["game_exited"]), .crashed)
        XCTAssertEqual(PlayRecord.outcome(gameStarted: true, seconds: 600, problems: []), .worked)
        XCTAssertEqual(PlayRecord.outcome(gameStarted: true, seconds: 600, problems: ["wine_exception"]), .crashed)
    }

    func testRecordKeepsNewestFirstAndCaps() {
        let store = PlayHistoryStore(paths: paths)
        for i in 0..<(PlayHistoryStore.limit + 5) {
            var s = session(.bridge, .worked)
            s.seconds = i
            store.record(s, profileID: "game")
        }
        let all = store.sessions("game")
        XCTAssertEqual(all.count, PlayHistoryStore.limit)
        XCTAssertEqual(all.first?.seconds, PlayHistoryStore.limit + 4)
    }

    func testNoHistoryForMissingProfile() {
        let store = PlayHistoryStore(paths: paths)
        store.record(session(.bridge, .worked), profileID: "gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.profile("gone").path))
    }

    func testPrefersWindowsSteamOnlyWhenBridgeFailedAndSteamWorked() {
        XCTAssertFalse([PlayRecord]().prefersWindowsSteamOverBridge)
        XCTAssertTrue([session(.bridge, .crashed), session(.windowsSteam, .worked)].prefersWindowsSteamOverBridge)
        // A quick deliberate quit says nothing: the crash before it still counts.
        XCTAssertTrue([session(.bridge, .closedEarly), session(.bridge, .didNotStart), session(.windowsSteam, .worked)]
            .prefersWindowsSteamOverBridge)
        // The Bridge worked last time.
        XCTAssertFalse([session(.bridge, .worked), session(.bridge, .crashed), session(.windowsSteam, .worked)]
            .prefersWindowsSteamOverBridge)
        // Windows Steam never worked either.
        XCTAssertFalse([session(.bridge, .crashed), session(.windowsSteam, .crashed)].prefersWindowsSteamOverBridge)
    }

    func testSummary() {
        var s = session(.bridge, .worked)
        s.seconds = 25 * 60
        s.avgFPS = 59.6
        XCTAssertEqual(s.summary(), "Today · 25 min · worked · Steam Bridge · 60 FPS")
    }
}

final class TelemetryOutboxTests: XCTestCase {
    var temp: URL!
    var store: TelemetryStore!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-outbox-\(UUID().uuidString)")
        store = TelemetryStore(paths: Paths(root: temp))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testBridgeReportCarriesLaunchMethod() throws {
        let report = try XCTUnwrap(TelemetryReport.fromPlaySession(
            steamAppID: 945360, recipeID: nil, renderer: .dxmt, vulkanDriver: .moltenvk, sync: .msync,
            engineID: "e", engineArch: .rosetta, gameStarted: true, playedSeconds: 300, stillRunning: false,
            crashSigns: [], peakThermalState: nil, installID: "id", launchMethod: .bridge))
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertTrue(json.contains(#""launchMethod":"bridge""#))
        XCTAssertLessThan(json.utf8.count, 2048, "the server refuses bigger reports")
    }

    func testUnsentReportsWaitAndStayWhenStillOffline() async {
        let report = TelemetryReport.sample(installID: "id")
        // Nothing listens on port 9: the send fails at once.
        let offline = URL(string: "https://127.0.0.1:9/v1/report")!
        let sent = await store.send(report, to: offline)
        XCTAssertFalse(sent)
        XCTAssertEqual(store.outbox(), [report])
        let flushed = await store.flushOutbox(to: offline)
        XCTAssertEqual(flushed, 0)
        XCTAssertEqual(store.outbox().count, 1)
    }

    func testOutboxKeepsNewestWhenFull() {
        var reports: [TelemetryReport] = []
        for app in 1...(TelemetryStore.outboxLimit + 3) {
            var r = TelemetryReport.sample(installID: "id")
            r.steamAppID = app
            reports.append(r)
        }
        store.enqueue(reports)
        XCTAssertEqual(store.outbox().count, TelemetryStore.outboxLimit)
        XCTAssertEqual(store.outbox().last?.steamAppID, TelemetryStore.outboxLimit + 3)
    }

    func testOldServerFeedWithoutLaunchMethodStillDecodes() throws {
        let json = #"{"schema":1,"updatedAt":"2026-11-23","verdicts":[{"steamAppID":440,"chip":"Apple M1","ramGB":16,"renderer":"dxmt","vulkanDriver":"moltenvk","engineArch":"x86_64","reports":1,"works":0,"avgFPS":34.8,"onePercentLowFPS":24.7}]}"#
        let feed = try JSONDecoder().decode(CommunityVerdictFeed.self, from: Data(json.utf8))
        XCTAssertNil(feed.verdicts.first?.launchMethod)
    }
}
