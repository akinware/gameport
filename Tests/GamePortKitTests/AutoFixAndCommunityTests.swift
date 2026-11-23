import XCTest
@testable import GamePortKit

final class AutoFixTests: XCTestCase {
    var temp: URL!
    var gp: GamePort!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-autofix-\(UUID().uuidString)")
        gp = GamePort(paths: Paths(root: temp))
        var profile = Profile(id: "game", title: "Game", recipeID: nil, engineID: "e1")
        profile.renderer = .dxvk
        try gp.profiles.save(profile)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func queryCrash() throws -> LaunchDiagnosis {
        SelfHealing.diagnose(profile: try gp.profiles.load("game"), recipe: nil,
                             crashSigns: ["DXVK pipeline-statistics query unsupported"],
                             logText: "vkResetQueryPoolEXT")
    }

    private func session(_ outcome: PlayRecord.Outcome) -> PlayRecord {
        PlayRecord(startedAt: Date().addingTimeInterval(1), seconds: 300, method: .bridge, outcome: outcome,
                   engineID: "e1", renderer: .dxmt, vulkanDriver: .moltenvk, sync: .msync)
    }

    func testOnlySureFixesAreAutomatic() throws {
        XCTAssertEqual(try queryCrash().autoFix?.kind, .switchRenderer(.dxmt))
        // A crash the log does not explain only gets renderer guesses: nothing is applied by itself.
        let unclear = SelfHealing.diagnose(profile: try gp.profiles.load("game"), recipe: nil,
                                           crashSigns: ["The game exited before the end"], logText: "")
        XCTAssertFalse(unclear.actions.isEmpty)
        XCTAssertNil(unclear.autoFix)
    }

    func testFixStaysWhenTheGameWorksAfterwards() throws {
        let fix = try XCTUnwrap(gp.applyAutoFix(try queryCrash(), profileID: "game"))
        XCTAssertEqual(fix.state, .trying)
        XCTAssertEqual(try gp.profiles.load("game").renderer, .dxmt)
        // A quick quit decides nothing.
        gp.playHistory.record(session(.closedEarly), profileID: "game")
        XCTAssertEqual(gp.autoFixes.pending("game")?.actionID, fix.actionID)
        gp.playHistory.record(session(.worked), profileID: "game")
        XCTAssertEqual(gp.autoFixes.fixes("game").first?.state, .kept)
        XCTAssertEqual(try gp.profiles.load("game").renderer, .dxmt)
    }

    func testFixIsUndoneWhenTheGameFailsAgainAndNeverRetried() throws {
        let diagnosis = try queryCrash()
        XCTAssertNotNil(gp.applyAutoFix(diagnosis, profileID: "game"))
        // The player changes something else meanwhile: undoing the fix keeps it.
        var p = try gp.profiles.load("game")
        p.environment["DXVK_HUD"] = "fps"
        try gp.profiles.save(p)
        gp.playHistory.record(session(.crashed), profileID: "game")
        let undone = try gp.profiles.load("game")
        XCTAssertEqual(undone.renderer, .dxvk)
        XCTAssertEqual(undone.environment["DXVK_HUD"], "fps")
        XCTAssertEqual(gp.autoFixes.fixes("game").first?.state, .undone)
        // Same crash again: not tried a second time.
        XCTAssertNil(gp.applyAutoFix(diagnosis, profileID: "game"))
    }

    func testAFailureWhileTryingUndoesAndStops() throws {
        XCTAssertNotNil(gp.applyAutoFix(try queryCrash(), profileID: "game"))
        // The launch fails again before any session was recorded (Windows Steam path order).
        let avx = SelfHealing.diagnose(profile: try gp.profiles.load("game"), recipe: nil,
                                       crashSigns: ["Unhandled exception"], logText: "0xc000001d illegal instruction")
        XCTAssertNotNil(avx.autoFix)
        XCTAssertNil(gp.applyAutoFix(avx, profileID: "game"))
        XCTAssertEqual(try gp.profiles.load("game").renderer, .dxvk)
        XCTAssertNil(gp.autoFixes.pending("game"))
    }
}

final class CommunityAdviceTests: XCTestCase {
    private func verdict(_ renderer: Renderer, macs: Int, works: Int, method: String? = "windowsSteam",
                         fps: Double? = nil, arch: EngineArchitecture = .rosetta,
                         vulkan: VulkanDriver = .moltenvk, problems: [String: Int]? = nil) -> CommunityVerdict {
        CommunityVerdict(steamAppID: 1, chip: "Apple M1", ramGB: 16, renderer: renderer, vulkanDriver: vulkan,
                         engineArch: arch, reports: macs, works: works, avgFPS: fps, onePercentLowFPS: nil,
                         launchMethod: method, installs: macs, problems: problems)
    }

    func testNeedsEnoughMacsAndMostlyWorking() {
        XCTAssertNil(CommunityAdvice.from([verdict(.dxmt, macs: 2, works: 2)], allowD3DMetal: false))
        XCTAssertNil(CommunityAdvice.from([verdict(.dxmt, macs: 5, works: 3)], allowD3DMetal: false))
        let advice = CommunityAdvice.from([verdict(.dxmt, macs: 5, works: 5)], allowD3DMetal: false)
        XCTAssertEqual(advice?.renderer, .dxmt)
        XCTAssertEqual(advice?.rendererTally?.macs, 5)
    }

    func testMacsAddUpAcrossChipsAndMostMacsWin() {
        let advice = CommunityAdvice.from([
            verdict(.dxmt, macs: 2, works: 2, fps: 60), verdict(.dxmt, macs: 2, works: 2, fps: 40),
            verdict(.dxvk, macs: 3, works: 3, fps: 120),
        ], allowD3DMetal: false)
        XCTAssertEqual(advice?.renderer, .dxmt)
        XCTAssertEqual(advice?.rendererTally?.avgFPS ?? 0, 50, accuracy: 0.01)
    }

    func testNeverD3DMetalWithoutTheLicenceNorExperimentalSetups() {
        XCTAssertNil(CommunityAdvice.from([verdict(.d3dmetal, macs: 9, works: 9)], allowD3DMetal: false))
        XCTAssertEqual(CommunityAdvice.from([verdict(.d3dmetal, macs: 9, works: 9)], allowD3DMetal: true)?.renderer, .d3dmetal)
        XCTAssertNil(CommunityAdvice.from([verdict(.dxmt, macs: 9, works: 9, vulkan: .kosmickrisp)], allowD3DMetal: false))
        XCTAssertNil(CommunityAdvice.from([verdict(.dxmt, macs: 9, works: 9, arch: .fex)], allowD3DMetal: false))
    }

    func testBridgeFailingForOthersPrefersWindowsSteam() {
        let advice = CommunityAdvice.from([
            verdict(.dxmt, macs: 4, works: 0, method: "bridge", problems: ["wine_exception": 4]),
            verdict(.dxmt, macs: 4, works: 4, method: "windowsSteam"),
        ], allowD3DMetal: false)
        XCTAssertEqual(advice?.prefersWindowsSteam, true)
        XCTAssertEqual(advice?.commonProblem, "wine_exception")
    }

    func testCatalogTakesCommunityRendererOnlyForUnverifiedRecipes() throws {
        func recipe(_ id: String, _ status: Recipe.Status) -> Recipe {
            Recipe(id: id, title: id, steamAppID: 1, launch: .steam, renderer: .dxvk, sync: .msync, advertiseAVX: false,
                   environment: [:], launchArguments: [], registry: [], status: status, notes: [], knownIssues: [], source: nil)
        }
        let verdicts = [1: [verdict(.dxmt, macs: 4, works: 4)]]
        let community = RecipeCatalog(recipes: [recipe("a", .community)]).withCommunityDefaults(verdicts, allowD3DMetal: false)
        XCTAssertEqual(community["a"]?.renderer, .dxmt)
        XCTAssertEqual(community["a"]?.community?.recipeRenderer, .dxvk)
        let verified = RecipeCatalog(recipes: [recipe("b", .verified)]).withCommunityDefaults(verdicts, allowD3DMetal: false)
        XCTAssertEqual(verified["b"]?.renderer, .dxvk)
        XCTAssertNil(verified["b"]?.community)
    }

    func testCommunityDefaultsCanBeTurnedOff() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-community-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = TelemetryStore(paths: Paths(root: temp))
        XCTAssertTrue(store.usesCommunityDefaults(environment: [:]))
        XCTAssertFalse(store.usesCommunityDefaults(environment: ["GAMEPORT_COMMUNITY_DEFAULTS": "0"]))
        try store.setCommunityDefaults(false)
        XCTAssertFalse(store.usesCommunityDefaults(environment: [:]))
    }

    func testFeedWithNewFieldsDecodes() throws {
        let json = #"{"schema":1,"updatedAt":"2026-11-23","verdicts":[{"steamAppID":1,"chip":"c","ramGB":16,"renderer":"dxmt","vulkanDriver":"moltenvk","engineArch":"x86_64","launchMethod":"bridge","reports":2,"installs":2,"works":1,"avgFPS":null,"onePercentLowFPS":null,"problems":{"wine_exception":1}}]}"#
        let feed = try JSONDecoder().decode(CommunityVerdictFeed.self, from: Data(json.utf8))
        XCTAssertEqual(feed.verdicts.first?.installs, 2)
        XCTAssertEqual(feed.verdicts.first?.problems?["wine_exception"], 1)
    }
}
