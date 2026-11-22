import XCTest
@testable import GamePortKit

final class SteamStoreTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("gameport-steamstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testParseAppIDFromNumbersAndURLs() {
        XCTAssertEqual(SteamStore.parseAppID("1145360"), 1145360)
        XCTAssertEqual(SteamStore.parseAppID("https://store.steampowered.com/app/1145360/Hades/"), 1145360)
        XCTAssertEqual(SteamStore.parseAppID("steam://rungameid/440"), 440)
        XCTAssertNil(SteamStore.parseAppID("0"))
        XCTAssertNil(SteamStore.parseAppID("Hades"))
    }

    func testParseSteamStoreJSON() throws {
        let searchJSON = #"{"items":[{"id":1145360,"name":"Hades","tiny_image":"https://example.com/h.jpg"},{"id":0,"name":"Bad"}]}"#
        let items = try SteamStore.parseSearchResponse(Data(searchJSON.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, 1145360)
        XCTAssertEqual(items.first?.name, "Hades")

        let detailsJSON = #"{"1145360":{"success":true,"data":{"name":"Hades"}}}"#
        XCTAssertEqual(SteamStore.parseAppDetailsTitle(Data(detailsJSON.utf8), appID: 1145360), "Hades")
    }

    func testAddCustomSteamGamePersistsAndDeduplicates() throws {
        let gp = GamePort(paths: Paths(root: temp))
        // Existing bundled game returns the bundled recipe without creating a duplicate
        let existing = try gp.addCustomSteamGame(appID: 440, title: "TF2 Duplicate")
        XCTAssertEqual(existing.id, "team-fortress-2")

        // Brand-new untested Steam game is written to db/recipes and reloaded cleanly
        let custom = try gp.addCustomSteamGame(appID: 999_999_123, title: "My Untested Game", renderer: .d3dmetal)
        XCTAssertEqual(custom.id, "custom-999999123")
        XCTAssertEqual(custom.status, .untested)
        XCTAssertEqual(custom.renderer, .d3dmetal)
        XCTAssertEqual(gp.catalog.recipe(steamAppID: 999_999_123)?.title, "My Untested Game")

        XCTAssertThrowsError(try gp.addCustomSteamGame(appID: 0, title: "Invalid"))
        XCTAssertThrowsError(try gp.addCustomSteamGame(appID: 123, title: "   "))
    }
}
