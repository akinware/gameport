import XCTest
@testable import GamePortKit

final class CrossOverEngineTests: XCTestCase {
    func testDetectSyntheticCrossOverAppAndSynthesizeZeroMBEngine() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-cx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let fm = FileManager.default
        let app = temp.appendingPathComponent("CrossOver.app", isDirectory: true)
        let shared = app.appendingPathComponent("Contents/SharedSupport/CrossOver", isDirectory: true)
        let bin = shared.appendingPathComponent("bin", isDirectory: true)
        let gptk = shared.appendingPathComponent("lib/apple_gptk/external", isDirectory: true)
        let dxmt = shared.appendingPathComponent("lib/dxmt/wine", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: gptk, withIntermediateDirectories: true)
        try fm.createDirectory(at: dxmt, withIntermediateDirectories: true)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>26.3</string></dict></plist>
        """
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        for tool in ["wine", "wineserver"] {
            let file = bin.appendingPathComponent(tool)
            try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        let detected = try XCTUnwrap(CrossOverSupport.detect(applicationsDirs: [temp]))
        XCTAssertEqual(detected.version, "26.3")
        XCTAssertTrue(detected.hasExecutableWine)

        let engine = detected.asInstalledEngine()
        XCTAssertEqual(engine.id, CrossOverInstallation.engineID)
        XCTAssertEqual(engine.manifest.downloadSizeLabel, "0 MB (System)")
        XCTAssertEqual(engine.manifest.totalDownloadSize, 0)
        XCTAssertNotNil(engine.rendererDirectory("d3dmetal"))
        XCTAssertNotNil(engine.rendererDirectory("dxmt"))
    }

    func testDiscoverCrossOverBottleSteamAndBattleNetGamesAndLaunchSpec() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-cx-bottles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let fm = FileManager.default
        let bottle = temp.appendingPathComponent("SteamBottle", isDirectory: true)
        let steamapps = bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps", isDirectory: true)
        let bnetDir = bottle.appendingPathComponent("drive_c/Program Files (x86)/Battle.net", isDirectory: true)
        try fm.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try fm.createDirectory(at: bnetDir, withIntermediateDirectories: true)
        try "[Bottle]\n".write(to: bottle.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
        try SteamDepotManager.writeAppManifest(appID: 1245620, name: "ELDEN RING", installDirName: "ELDEN RING", into: steamapps)
        try Data([0x4D, 0x5A]).write(to: bnetDir.appendingPathComponent("Battle.net Launcher.exe"))

        let items = CrossOverSupport.discoverBottleGames(bottlesRoot: temp)
        XCTAssertEqual(items.count, 2)
        let steamItem = try XCTUnwrap(items.first { $0.kind == .steam(appID: 1245620) })
        let bnetItem = try XCTUnwrap(items.first { $0.kind == .battleNet })

        let fakeInstall = CrossOverInstallation(
            appURL: URL(fileURLWithPath: "/Applications/CrossOver.app"),
            sharedSupportURL: URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"),
            version: "26.3"
        )
        let steamSpec = CrossOverSupport.launchSpec(installation: fakeInstall, item: steamItem, performanceCores: false, metalFX: true, metalHUD: true)
        XCTAssertEqual(steamSpec.executable, fakeInstall.wineURL.path)
        XCTAssertTrue(steamSpec.arguments.contains("-applaunch"))
        XCTAssertTrue(steamSpec.arguments.contains("1245620"))
        XCTAssertEqual(steamSpec.environment["CX_BOTTLE"], "SteamBottle")
        XCTAssertEqual(steamSpec.environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "1")
        XCTAssertEqual(steamSpec.environment["MTL_HUD_ENABLED"], "1")

        let bnetSpec = CrossOverSupport.launchSpec(installation: fakeInstall, item: bnetItem, performanceCores: false, battleNetProduct: "Pro")
        XCTAssertTrue(bnetSpec.arguments.contains("--exec=launch Pro"))
        XCTAssertEqual(bnetSpec.environment["WINE_SIMULATE_WRITECOPY"], "1")
    }
}
