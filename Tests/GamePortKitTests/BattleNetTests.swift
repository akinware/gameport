import XCTest
@testable import GamePortKit

final class BattleNetTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("gameport-bnet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testBundledBattleNetRecipesAndPlayGuideFlow() throws {
        let catalog = RecipeCatalog.load(paths: Paths(root: temp))
        let ow2 = try XCTUnwrap(catalog["overwatch-2-battlenet"])
        XCTAssertEqual(ow2.launch, .battlenet)
        XCTAssertEqual(ow2.battleNetProduct, "Pro")
        XCTAssertEqual(ow2.renderer, .d3dmetal)
        XCTAssertTrue(ow2.advertiseAVX)

        let d4 = try XCTUnwrap(catalog["diablo-iv-battlenet"])
        XCTAssertEqual(d4.launch, .battlenet)
        XCTAssertEqual(d4.battleNetProduct, "Fen")

        let d2r = try XCTUnwrap(catalog["diablo-ii-resurrected-battlenet"])
        XCTAssertEqual(d2r.battleNetProduct, "OSI")

        // PlayGuide guides cleanly through Create -> License -> Install Battle.net -> Open Battle.net
        XCTAssertEqual(
            PlayStep.next(engineAvailable: true, hasProfile: true, needsLicense: true,
                          steamInstalled: false, hasSteamAppID: false, gameInstalled: false, hasFallback: false,
                          isBattleNet: true, battleNetInstalled: false),
            .reviewLicense
        )
        XCTAssertEqual(
            PlayStep.next(engineAvailable: true, hasProfile: true, needsLicense: false,
                          steamInstalled: false, hasSteamAppID: false, gameInstalled: false, hasFallback: false,
                          isBattleNet: true, battleNetInstalled: false),
            .installBattleNet
        )
        XCTAssertEqual(
            PlayStep.next(engineAvailable: true, hasProfile: true, needsLicense: false,
                          steamInstalled: false, hasSteamAppID: false, gameInstalled: false, hasFallback: false,
                          isBattleNet: true, battleNetInstalled: true),
            .openBattleNet
        )
    }

    func testBattleNetClientDetectsInstalledLauncherExe() throws {
        let paths = Paths(root: temp)
        let engineRoot = paths.engine("e1")
        let manifest = EngineManifest(
            schema: 1, id: "e1", displayName: "Test", arch: .rosetta,
            fexModules: nil, overlayMode: .prepend, supportsKosmicKrisp: false,
            minMacOS: "14.0", wineLoader: "engine/bin/wine", wineServer: "engine/bin/wineserver",
            components: [], baseEnvironment: [:], licenses: [:], notes: []
        )
        let engine = InstalledEngine(manifest: manifest, root: engineRoot)
        let profile = Profile(id: "ow2-bn", title: "Overwatch 2 (Battle.net)", recipeID: "overwatch-2-battlenet", engineID: "e1")
        let runner = WineRunner(paths: paths, engine: engine, profile: profile, recipe: nil)
        let bn = BattleNetClient(runner: runner)
        XCTAssertFalse(bn.isInstalled)

        let exe = runner.prefix.appendingPathComponent("drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: exe)
        XCTAssertTrue(bn.isInstalled)
        XCTAssertEqual(bn.windowsLauncherExe, "C:\\Program Files (x86)\\Battle.net\\Battle.net Launcher.exe")
    }
}
