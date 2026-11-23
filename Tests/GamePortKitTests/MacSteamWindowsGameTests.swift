import XCTest
@testable import GamePortKit

final class MacSteamWindowsGameTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mswg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func manifest(_ appID: Int, _ name: String, dir: String, flags: Int?) -> String {
        var text = "\"AppState\"\n{\n\t\"appid\"\t\t\"\(appID)\"\n\t\"name\"\t\t\"\(name)\"\n\t\"installdir\"\t\t\"\(dir)\"\n"
        if let flags { text += "\t\"StateFlags\"\t\t\"\(flags)\"\n" }
        return text + "}\n"
    }

    private func touch(_ relative: String, in base: URL) throws {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func library(_ base: URL, games: [(Int, String, String, Int?, [String])]) throws {
        let steamapps = base.appendingPathComponent("steamapps", isDirectory: true)
        for (id, name, dir, flags, files) in games {
            try touch("appmanifest_\(id).acf", in: steamapps)
            try manifest(id, name, dir: dir, flags: flags).write(to: steamapps.appendingPathComponent("appmanifest_\(id).acf"),
                                                                 atomically: true, encoding: .utf8)
            for file in files { try touch("common/\(dir)/\(file)", in: steamapps) }
        }
    }

    func testStateFlagsSayWhetherSteamFinishedInstalling() {
        XCTAssertEqual(ExternalDiscovery.parseAppManifest(manifest(1, "A", dir: "A", flags: 4))?.fullyInstalled, true)
        XCTAssertEqual(ExternalDiscovery.parseAppManifest(manifest(1, "A", dir: "A", flags: 1026))?.fullyInstalled, false)
        XCTAssertEqual(ExternalDiscovery.parseAppManifest(manifest(1, "A", dir: "A", flags: nil))?.fullyInstalled, true)
    }

    func testFolderPlatform() throws {
        try touch("Mac/Game.app/Contents/MacOS/Game", in: root)
        try touch("Mac/redist/setup.exe", in: root)
        try touch("Win/bin/game.exe", in: root)
        try touch("Empty/readme.txt", in: root)
        XCTAssertEqual(ExternalDiscovery.installPlatform(of: root.appendingPathComponent("Mac")), .mac)
        XCTAssertEqual(ExternalDiscovery.installPlatform(of: root.appendingPathComponent("Win")), .windows)
        XCTAssertEqual(ExternalDiscovery.installPlatform(of: root.appendingPathComponent("Empty")), .unknown)
        XCTAssertEqual(ExternalDiscovery.installPlatform(of: root.appendingPathComponent("Missing")), .unknown)
    }

    func testLibraryFolderPaths() {
        let vdf = """
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"/Users/someone/Library/Application Support/Steam"
        \t\t"apps" { "440" "1" }
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"/Volumes/Games/SteamLibrary"
        \t}
        }
        """
        XCTAssertEqual(ExternalDiscovery.parseLibraryFolderPaths(vdf),
                       ["/Users/someone/Library/Application Support/Steam", "/Volumes/Games/SteamLibrary"])
    }

    func testScansEveryLibraryAndTellsMacFromWindows() throws {
        let steamRoot = root.appendingPathComponent("Steam", isDirectory: true)
        let external = root.appendingPathComponent("External", isDirectory: true)
        try library(steamRoot, games: [
            (10, "Mac Game", "MacGame", 4, ["MacGame.app/Contents/Info.plist"]),
            (20, "Windows Game", "WinGame", 4, ["bin/wingame.exe"]),
        ])
        try library(external, games: [
            (30, "Downloading", "Down", 1026, ["bin/down.exe"]),
            (20, "Windows Game", "WinGameCopy", 4, ["copy.exe"]),
        ])
        try """
        "libraryfolders"
        {
        \t"0" { "path" "\(steamRoot.path)" }
        \t"1" { "path" "\(external.path)" }
        }
        """.write(to: steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)

        let games = ExternalDiscovery.scanMacSteamLibraries(steamRoot: steamRoot)
        XCTAssertEqual(games.map(\.appID).sorted(), [10, 20, 30])
        XCTAssertEqual(games.first { $0.appID == 20 }?.installDir, "WinGame", "the main library's install wins")
        XCTAssertEqual(games.first { $0.appID == 10 }?.platform, .mac)
        XCTAssertEqual(games.first { $0.appID == 20 }?.platform, .windows)
        XCTAssertEqual(games.first { $0.appID == 20 }?.folder?.lastPathComponent, "WinGame")

        let env = ExternalEnvironment(obeliskApp: nil, siliconiumApp: nil, crossoverApp: nil, crossoverBottles: [],
                                      macSteamApp: nil, macSteamGames: games, macSteamOwnedGames: [], notProtonInstalled: false)
        XCTAssertNotNil(env.macSteamNativeGame(appID: 10))
        XCTAssertNil(env.macSteamNativeGame(appID: 20), "a Windows install is not the Mac version")
        XCTAssertNotNil(env.macSteamWindowsGame(appID: 20))
        XCTAssertNil(env.macSteamWindowsGame(appID: 30), "still downloading")
        XCTAssertNil(env.macSteamWindowsGame(appID: 10))
        XCTAssertNotNil(env.macSteamGame(appID: 30))
    }

    /// The real process list: a stand-in for the game, whose command line has the game's path.
    func testSeesARealProcess() throws {
        let exe = root.appendingPathComponent("steamapps/common/Fake Game \(UUID().uuidString.prefix(6))/bin/fakegame.exe")
        let markers = MacSteamWindowsLaunch.markers(installDir: exe.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                                                    executable: nil)
        XCTAssertFalse(MacSteamWindowsLaunch.isRunning(markers: markers))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 20; exit 0", exe.path]
        try process.run()
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(MacSteamWindowsLaunch.isRunning(markers: markers))
        process.terminate()
        process.waitUntilExit()
        XCTAssertFalse(MacSteamWindowsLaunch.isRunning(markers: markers))
    }

    func testProcessMarkers() {
        let exe = URL(fileURLWithPath: "/Lib/steamapps/common/Helldivers 2/bin/helldivers2.exe")
        let markers = MacSteamWindowsLaunch.markers(installDir: "Helldivers 2", executable: exe)
        XCTAssertEqual(markers, ["helldivers2.exe", "steamapps/common/helldivers 2/", "steamapps\\common\\helldivers 2\\"])
        let wine = "  812 C:\\Program Files (x86)\\Steam\\steamapps\\common\\Helldivers 2\\bin\\helldivers2.exe"
        let tool = "  640 /opt/tool/run waitforexitandrun /Users/x/Library/Application Support/Steam/steamapps/common/Helldivers 2/bin/helldivers2.exe"
        let other = "  100 /Applications/Steam.app/Contents/MacOS/steam_osx\n  101 /usr/bin/helldivers"
        XCTAssertTrue(MacSteamWindowsLaunch.isRunning(inProcessList: wine, markers: markers))
        XCTAssertTrue(MacSteamWindowsLaunch.isRunning(inProcessList: tool, markers: markers))
        XCTAssertFalse(MacSteamWindowsLaunch.isRunning(inProcessList: other, markers: markers))
        XCTAssertFalse(MacSteamWindowsLaunch.isRunning(inProcessList: wine, markers: []))
        XCTAssertEqual(MacSteamWindowsLaunch.launchURL(appID: 553850)?.absoluteString, "steam://rungameid/553850")
        XCTAssertNil(MacSteamWindowsLaunch.launchURL(appID: 0))
    }

    func testSteamSupportPackagesAreNotGames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("steamapps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (id, name) in [(945360, "Among Us"), (228980, "Steamworks Common Redistributables"), (1493710, "Proton Experimental"),
                           (4000000, "Steam Linux Runtime 9.0 (future)")] {
            let manifest = "\"AppState\"\n{\n\t\"appid\"\t\t\"\(id)\"\n\t\"name\"\t\t\"\(name)\"\n\t\"StateFlags\"\t\t\"4\"\n\t\"installdir\"\t\t\"\(name)\"\n}\n"
            try manifest.write(to: dir.appendingPathComponent("appmanifest_\(id).acf"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(ExternalDiscovery.scanSteamApps(in: dir).map(\.appID), [945360])
        XCTAssertFalse(ExternalDiscovery.isSteamSupportPackage(appID: 1245620, name: "ELDEN RING"))
        XCTAssertFalse(ExternalDiscovery.isSteamSupportPackage(appID: 1, name: "Protonaut"))
    }
}
