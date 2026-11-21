import XCTest
@testable import GamePortKit

final class PlayGuideTests: XCTestCase {
    private func step(engine: Bool = true, profile: Bool = true,
                      needsLicense: Bool = false, steam: Bool = true, appID: Bool = true,
                      game: Bool = true, fallback: Bool = false) -> PlayStep {
        PlayStep.next(engineAvailable: engine, hasProfile: profile, needsLicense: needsLicense,
                      steamInstalled: steam, hasSteamAppID: appID, gameInstalled: game, hasFallback: fallback)
    }

    func testFirstRunThroughPlay() {
        XCTAssertEqual(step(engine: false, profile: false, steam: false, game: false), .setupEngine)
        XCTAssertEqual(step(profile: false, needsLicense: true, steam: false, game: false), .createProfile)
        XCTAssertEqual(step(needsLicense: true, steam: false, game: false), .reviewLicense)
        XCTAssertEqual(step(steam: false, game: false), .installSteam)
        XCTAssertEqual(step(game: false), .downloadGame)
        XCTAssertEqual(step(), .play)
    }

    func testAntiCheatVerdictStaysVisibleAlongsideLaunchGuidance() {
        let recipe = Recipe(id: "test", title: "Test Game", steamAppID: 123, renderer: .dxmt, status: .verified)
        let entry = AntiCheatEntry(id: recipe.id, title: recipe.title, antiCheats: ["AC"],
                                   linuxStatus: "Denied", steamAppID: 123, macVerdict: .blocked)
        let evidence = Evidence.of(recipe, results: [], antiCheat: entry)
        XCTAssertEqual(evidence.level, .blocked)
        XCTAssertEqual(evidence.detail, entry.summary)
        XCTAssertEqual(step(), .play)
    }

    func testGameWithoutSteamIDOpensSteamForManualPlay() {
        XCTAssertEqual(step(steam: false, appID: false), .installSteam)
        XCTAssertEqual(step(appID: false), .openSteam)
        XCTAssertEqual(step(appID: false, game: false), .openSteam)
    }

    func testFallbackPreservesEngineAndLicensePreflight() {
        XCTAssertEqual(step(engine: false, steam: false, game: false, fallback: true), .play)
        XCTAssertEqual(step(engine: false), .setupEngine)
        XCTAssertEqual(step(engine: false, profile: false, fallback: true), .setupEngine)
        XCTAssertEqual(step(engine: false, needsLicense: true, fallback: true), .reviewLicense)
        XCTAssertEqual(step(engine: false, appID: false, fallback: true), .setupEngine)
        XCTAssertEqual(step(steam: false, fallback: true), .installSteam)
        XCTAssertEqual(step(game: false, fallback: true), .downloadGame)
    }

    func testHeaderRequiresAPositiveSteamID() {
        var recipe = Recipe(id: "test", title: "Test Game", renderer: .dxmt)
        XCTAssertNil(recipe.steamHeaderURL)
        for id in [0, -1] {
            recipe.steamAppID = id
            XCTAssertNil(recipe.steamHeaderURL)
        }
        recipe.steamAppID = 440
        XCTAssertEqual(recipe.steamHeaderURL?.absoluteString, "https://cdn.akamai.steamstatic.com/steam/apps/440/header.jpg")
    }
}
