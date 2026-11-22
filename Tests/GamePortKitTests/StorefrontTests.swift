import XCTest
@testable import GamePortKit

final class StorefrontTests: XCTestCase {
    func testEpicLibraryAndInstalledJSONParsing() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-epic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let installedURL = temp.appendingPathComponent("installed.json")
        let installedJSON = """
        {
          "Sugar": {
            "app_name": "Sugar",
            "title": "Rocket League",
            "install_path": "/tmp/Games/RocketLeague",
            "executable": "Binaries/Win64/RocketLeague.exe",
            "version": "2.45",
            "install_size": 25000000000
          }
        }
        """
        try installedJSON.write(to: installedURL, atomically: true, encoding: .utf8)
        let installed = EpicStorefront.parseInstalledJSON(at: installedURL, store: .epic)
        XCTAssertEqual(installed["Sugar"]?.title, "Rocket League")
        XCTAssertEqual(installed["Sugar"]?.executableRelativePath, "Binaries/Win64/RocketLeague.exe")

        let libraryJSON = """
        [
          {
            "app_name": "Sugar",
            "app_title": "Rocket League",
            "metadata": {
              "keyImages": [
                {"type": "DieselGameBoxTall", "url": "https://cdn.example.com/rl-tall.jpg"}
              ]
            }
          },
          {
            "app_name": "Control",
            "app_title": "Control",
            "metadata": {
              "keyImages": [
                {"type": "DieselGameBox", "url": "https://cdn.example.com/control.jpg"}
              ]
            }
          }
        ]
        """
        let games = EpicStorefront.parseLibraryJSON(Data(libraryJSON.utf8), installed: installed)
        XCTAssertEqual(games.count, 2)
        // Installed games sort first
        XCTAssertEqual(games[0].appID, "Sugar")
        XCTAssertTrue(games[0].isInstalled)
        XCTAssertEqual(games[0].artworkURL?.absoluteString, "https://cdn.example.com/rl-tall.jpg")
        XCTAssertEqual(games[1].appID, "Control")
        XCTAssertFalse(games[1].isInstalled)
    }

    func testEpicLaunchJSONParsing() throws {
        let json = """
        {
          "game_directory": "/Users/test/Games/Control",
          "game_executable": "Control_DX12.exe",
          "working_directory": "/Users/test/Games/Control",
          "egl_parameters": ["-AUTH_LOGIN=unused", "-AUTH_TYPE=exchangecode"],
          "game_parameters": ["-skipintro"],
          "environment": {"EPIC_ENV": "1"}
        }
        """
        let params = try EpicStorefront.parseLaunchJSON(Data(json.utf8))
        XCTAssertEqual(params.executable.path, "/Users/test/Games/Control/Control_DX12.exe")
        XCTAssertEqual(params.arguments, ["-AUTH_LOGIN=unused", "-AUTH_TYPE=exchangecode", "-skipintro"])
        XCTAssertEqual(params.environment["EPIC_ENV"], "1")
    }

    func testGOGInfoDiscoveryAndHeroicScanner() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-gog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let fm = FileManager.default
        let cpDir = temp.appendingPathComponent("games/Cyberpunk 2077", isDirectory: true)
        let binDir = cpDir.appendingPathComponent("bin/x64", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try Data([0x4D, 0x5A]).write(to: binDir.appendingPathComponent("Cyberpunk2077.exe"))
        let info = """
        {
          "gameId": "1423049311",
          "name": "Cyberpunk 2077",
          "playTasks": [
            {"isPrimary": true, "path": "bin\\\\x64\\\\Cyberpunk2077.exe"}
          ]
        }
        """
        try info.write(to: cpDir.appendingPathComponent("goggame-1423049311.info"), atomically: true, encoding: .utf8)

        let scanned = GOGStorefront.scanInstalledGames(in: temp.appendingPathComponent("games", isDirectory: true))
        XCTAssertEqual(scanned.count, 1)
        XCTAssertEqual(scanned[0].title, "Cyberpunk 2077")
        XCTAssertEqual(scanned[0].resolvedExecutable()?.lastPathComponent, "Cyberpunk2077.exe")

        // Also verify Heroic Games Launcher multi-store discovery (Epic + GOG + Amazon)
        let heroicRoot = temp.appendingPathComponent("Library/Application Support/heroic", isDirectory: true)
        let hEpic = heroicRoot.appendingPathComponent("legendaryConfig/legendary", isDirectory: true)
        let hGOG = heroicRoot.appendingPathComponent("gog_store", isDirectory: true)
        let hAmazon = heroicRoot.appendingPathComponent("nile_config/nile", isDirectory: true)
        try fm.createDirectory(at: hEpic, withIntermediateDirectories: true)
        try fm.createDirectory(at: hGOG, withIntermediateDirectories: true)
        try fm.createDirectory(at: hAmazon, withIntermediateDirectories: true)

        try """
        {"AlanWake2": {"title": "Alan Wake 2", "install_path": "/tmp/AlanWake2", "executable": "AlanWake2.exe"}}
        """.write(to: hEpic.appendingPathComponent("installed.json"), atomically: true, encoding: .utf8)
        try """
        {"installed": [{"appName": "1423049311", "install_path": "\(cpDir.path)", "version": "2.1"}]}
        """.write(to: hGOG.appendingPathComponent("installed.json"), atomically: true, encoding: .utf8)
        try """
        [{"id": "amzn-1", "title": "Fallout 3", "path": "/tmp/Fallout3"}]
        """.write(to: hAmazon.appendingPathComponent("installed.json"), atomically: true, encoding: .utf8)

        let heroicGames = HeroicDiscovery.scan(home: temp)
        XCTAssertEqual(heroicGames.count, 3)
        XCTAssertTrue(heroicGames.contains { $0.store == .heroicEpic && $0.title == "Alan Wake 2" })
        XCTAssertTrue(heroicGames.contains { $0.store == .heroicGOG && $0.title == "Cyberpunk 2077" })
        XCTAssertTrue(heroicGames.contains { $0.store == .heroicAmazon && $0.title == "Fallout 3" })
    }
}
