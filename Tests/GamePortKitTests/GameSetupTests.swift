import XCTest
@testable import GamePortKit

final class GameSetupTests: XCTestCase {
    private func runner(profile: Profile, recipe: Recipe?) throws -> WineRunner {
        let m = try XCTUnwrap(EngineStore.bundledManifests().first)
        let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("gp-setup-\(UUID().uuidString)"))
        return WineRunner(paths: paths, engine: InstalledEngine(manifest: m, root: paths.root), profile: profile, recipe: recipe)
    }

    func testRecipeSettingsAreExplained() throws {
        var recipe = Recipe(id: "g", title: "G", renderer: .dxvk, sync: .esync, advertiseAVX: true,
                            environment: ["WINE_SIMULATE_WRITECOPY": "1"], dllOverrides: "d3dcompiler_47=n",
                            launchArguments: ["-dx11"], status: .community)
        recipe.source = "https://github.com/x/highball-db/blob/abc/db/games/g.json (CC0-1.0)"
        recipe.notes = ["Use windowed mode."]
        let setup = GameSetup.describe(try runner(profile: Profile(id: "g", title: "G", recipeID: "g", engineID: "e"), recipe: recipe))

        let graphics = try XCTUnwrap(setup.basics.first { $0.label == "Graphics" })
        XCTAssertEqual(graphics.value, "DXVK")
        XCTAssertEqual(graphics.origin, .recipe)
        XCTAssertEqual(setup.basics.first { $0.label == "Thread sync" }?.value, "ESync")
        XCTAssertTrue(setup.tweaks.contains { $0.label == "AVX" && $0.origin == .recipe })
        XCTAssertTrue(setup.tweaks.contains { $0.value == "WINE_SIMULATE_WRITECOPY=1" && !$0.why.contains("An environment setting") })
        XCTAssertTrue(setup.tweaks.contains { $0.label == "Windows libraries" && $0.value == "d3dcompiler_47=n" })
        XCTAssertTrue(setup.tweaks.contains { $0.label == "Launch options" && $0.value == "-dx11" })
        XCTAssertEqual(setup.notes, ["Use windowed mode."])
        XCTAssertEqual(setup.status, .community)
        XCTAssertTrue(setup.source?.contains("community catalog") == true)
    }

    func testPlayerChoicesWinAndSaySo() throws {
        let recipe = Recipe(id: "g", title: "G", renderer: .dxmt)
        var profile = Profile(id: "g", title: "G", recipeID: "g", engineID: "e")
        profile.renderer = .d3dmetal
        profile.metalFX = true
        let setup = GameSetup.describe(try runner(profile: profile, recipe: recipe))
        let graphics = try XCTUnwrap(setup.basics.first { $0.label == "Graphics" })
        XCTAssertEqual(graphics.value, "D3DMetal")
        XCTAssertEqual(graphics.origin, .player)
        XCTAssertTrue(setup.tweaks.contains { $0.label == "MetalFX" && $0.origin == .player })
    }

    func testEngineNamesAreShortened() {
        XCTAssertEqual(GameSetup.shortName("CrossOver 26.3 (System · 0 MB)"), "CrossOver 26.3")
        XCTAssertEqual(GameSetup.shortName("Wine 11.0 (CrossOver 26.3 source) — Intel, Rosetta 2"), "Wine 11.0 (CrossOver 26.3 source)")
        XCTAssertEqual(GameSetup.shortName("Wine"), "Wine")
    }

    func testNoRecipeMeansDefaults() throws {
        let setup = GameSetup.describe(try runner(profile: Profile(id: "g", title: "G", recipeID: nil, engineID: "e"), recipe: nil))
        XCTAssertEqual(setup.basics.first { $0.label == "Graphics" }?.origin, .gameport)
        XCTAssertNil(setup.status)
        XCTAssertTrue(setup.notes.isEmpty)
    }
}
