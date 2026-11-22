import XCTest
@testable import GamePortKit

final class WindowsSteamLibraryTests: XCTestCase {
    var temp: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        temp = fm.temporaryDirectory.appendingPathComponent("gp-winsteam-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: temp) }

    /// Registers a fake engine (no real Wine) under `paths`.
    private func installFakeEngine(_ id: String, paths: Paths) throws -> InstalledEngine {
        var m = try XCTUnwrap(EngineStore.bundledManifests().first)
        m.id = id
        let root = temp.appendingPathComponent("engine-\(id)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.engines, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: paths.engine(id), withDestinationURL: root)
        try JSONEncoder().encode(m).write(to: root.appendingPathComponent(EngineStore.receiptName))
        return InstalledEngine(manifest: m, root: root)
    }

    func testInstallFolderComesFromTheRecipe() {
        var recipe = Recipe(id: "x", title: "X", renderer: .dxmt)
        recipe.executable = "Mount & Blade II Bannerlord/bin/Win64_Shipping_Client/TaleWorlds.MountAndBlade.Launcher.exe"
        XCTAssertEqual(GamePort.windowsSteamInstallFolder(recipe: recipe, title: "ignored"), "Mount & Blade II Bannerlord")
        XCTAssertEqual(GamePort.windowsSteamInstallFolder(recipe: nil, title: "Half-Life 2: Episode One"), "Half-Life 2 Episode One")
        XCTAssertEqual(GamePort.windowsSteamInstallFolder(recipe: nil, title: "???"), "Game")
    }

    func testDepotIsClonedIntoWindowsSteamLibrary() throws {
        let paths = Paths(root: temp.appendingPathComponent("home"))
        let kit = GamePort(paths: paths)
        let engine = try installFakeEngine("engine-a", paths: paths)
        let recipe = try XCTUnwrap(kit.catalog["hbdb-mount-blade-ii-bannerlord"])
        let appID = try XCTUnwrap(recipe.steamAppID)
        try kit.profiles.save(Profile(id: "bl", title: recipe.title, recipeID: recipe.id, engineID: engine.id))
        let steam = try kit.steam(for: "bl")

        // No Windows Steam yet.
        XCTAssertThrowsError(try kit.addDepotToWindowsSteam("bl"))
        try fm.createDirectory(at: steam.exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: steam.exe)

        // Not downloaded yet.
        XCTAssertThrowsError(try kit.addDepotToWindowsSteam("bl"))

        let depot = paths.tools.appendingPathComponent("depots/\(appID)")
        let exe = depot.appendingPathComponent("bin/Win64_Shipping_Client/TaleWorlds.MountAndBlade.Launcher.exe")
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("game".utf8).write(to: exe)
        try fm.createDirectory(at: depot.appendingPathComponent(".DepotDownloader"), withIntermediateDirectories: true)
        try SteamDepotManager.markDownloadComplete(appID: appID, name: recipe.title, in: depot)

        let dir = try kit.addDepotToWindowsSteam("bl")
        XCTAssertEqual(dir.lastPathComponent, "Mount & Blade II Bannerlord")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("bin/Win64_Shipping_Client/TaleWorlds.MountAndBlade.Launcher.exe"), encoding: .utf8), "game")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(".DepotDownloader").path), "download bookkeeping is left out")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("steamapps").path))
        XCTAssertTrue(steam.isGameInstalled(appID: appID))
        XCTAssertTrue(fm.fileExists(atPath: exe.path), "the Bridge keeps its own copy")
        XCTAssertEqual(try kit.addDepotToWindowsSteam("bl"), dir, "a second call changes nothing")
    }

    func testSwitchEngineSnapshotsFirst() throws {
        let paths = Paths(root: temp.appendingPathComponent("home"))
        let kit = GamePort(paths: paths)
        let a = try installFakeEngine("engine-a", paths: paths)
        let b = try installFakeEngine("engine-b", paths: paths)
        try kit.profiles.save(Profile(id: "g", title: "G", recipeID: nil, engineID: a.id))
        try fm.createDirectory(at: kit.profiles.prefix("g").appendingPathComponent("drive_c"), withIntermediateDirectories: true)

        XCTAssertEqual(try kit.switchEngine("g", to: b.id).engineID, b.id)
        XCTAssertEqual(try kit.profiles.load("g").engineID, b.id)
        let snapshot = try XCTUnwrap(kit.profiles.listSnapshots("g").first)
        XCTAssertEqual(snapshot.engineID, a.id, "restoring the snapshot brings the old engine back")
        XCTAssertThrowsError(try kit.switchEngine("g", to: "not-installed"))
    }
}

final class WindowsSteamProcessTests: XCTestCase {
    func testWineServerFolderIsNamedAfterThePrefix() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gp-srv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        let dev = try XCTUnwrap(attrs[.systemNumber] as? NSNumber).uint64Value
        let ino = try XCTUnwrap(attrs[.systemFileNumber] as? NSNumber).uint64Value
        XCTAssertEqual(SteamClient.wineServerFolderName(prefix: dir),
                       "server-\(String(dev, radix: 16))-\(String(ino, radix: 16))")
        XCTAssertNil(SteamClient.wineServerFolderName(prefix: dir.appendingPathComponent("missing")))
    }

    func testWorkshopDriveSurvivesIsolation() {
        XCTAssertTrue(WineRunner.keptDrives.contains(WineRunner.workshopDrive))
        XCTAssertEqual(SteamBridge.macSteamWorkshopFolder(appID: 261550, home: URL(fileURLWithPath: "/Users/x")).path,
                       "/Users/x/Library/Application Support/Steam/steamapps/workshop/content/261550")
    }
}
