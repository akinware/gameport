import XCTest
@testable import GamePortKit

final class Phase1PackTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("gameport-phase1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testPerformancePackEnvRetinaModeAndCommandWrapping() throws {
        let paths = Paths(root: temp)
        let gp = GamePort(paths: paths)
        let engineRoot = paths.engine("e1")
        let fm = FileManager.default
        try fm.createDirectory(at: engineRoot.appendingPathComponent("engine/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: engineRoot.appendingPathComponent("renderers/dxmt/wine/x86_64-windows"), withIntermediateDirectories: true)
        let wineBin = engineRoot.appendingPathComponent("engine/bin/wine")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wineBin)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineBin.path)

        let manifest = EngineManifest(
            schema: 1, id: "e1", displayName: "Test Engine", arch: .rosetta,
            fexModules: nil, overlayMode: .prepend, supportsKosmicKrisp: false,
            minMacOS: "14.0", wineLoader: "engine/bin/wine", wineServer: "engine/bin/wineserver",
            components: [], baseEnvironment: [:], licenses: [:], notes: []
        )
        let engine = InstalledEngine(manifest: manifest, root: engineRoot)

        var profile = Profile(id: "cod4", title: "Call of Duty 4", recipeID: nil, engineID: "e1")
        profile.renderer = .dxmt
        profile.performanceCores = true
        profile.retinaMode = false
        profile.metalFX = true
        try gp.profiles.save(profile)

        // Seed user.reg so RetinaMode can be written directly
        let prefix = gp.profiles.prefix("cod4")
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        let userReg = prefix.appendingPathComponent("user.reg")
        try "WINE REGISTRY Version 2\n\n[Software\\\\Wine\\\\Mac Driver]\n\"RetinaMode\"=\"Y\"\n".write(to: userReg, atomically: true, encoding: .utf8)

        let runner = WineRunner(paths: paths, engine: engine, profile: profile, recipe: nil)
        let env = try runner.environment()
        XCTAssertEqual(env["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "1")
        XCTAssertEqual(env["DXMT_ENABLE_NVEXT"], "1")
        XCTAssertEqual(env["D3DM_ENABLE_METALFX"], "1")
        XCTAssertTrue(env["DXVK_STATE_CACHE_PATH"]?.hasSuffix("/cache/dxvk") == true)
        XCTAssertTrue(env["DXMT_SHADER_CACHE_PATH"]?.hasSuffix("/cache/dxmt") == true)

        try runner.prepareDirectories()
        let updatedReg = try String(contentsOf: userReg, encoding: .utf8)
        XCTAssertTrue(updatedReg.contains("\"RetinaMode\"=\"N\""))
        XCTAssertTrue(fm.fileExists(atPath: gp.profiles.home("cod4").appendingPathComponent("cache/dxvk").path))
        XCTAssertTrue(fm.fileExists(atPath: gp.profiles.home("cod4").appendingPathComponent("cache/dxmt").path))

        // P-core wrapping via taskpolicy on macOS
        let cmd = try runner.resolvedCommand(arguments: ["game.exe"], applyPerformanceCores: true)
        #if os(macOS)
        XCTAssertEqual(cmd.executable, "/usr/sbin/taskpolicy")
        XCTAssertEqual(Array(cmd.arguments.prefix(5)), ["-a", "-t", "5", "-l", "5"])
        XCTAssertEqual(cmd.arguments.last, "game.exe")
        #endif

        // AArchX wrapping when installed
        let aarchxDir = gp.aarchx.installDir
        try fm.createDirectory(at: aarchxDir, withIntermediateDirectories: true)
        let ocerz = gp.aarchx.managedBinary
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: ocerz)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ocerz.path)

        // x87sidecar injects ROSETTA_X87_PATH when installed and enabled on the profile
        try fm.createDirectory(at: gp.x87sidecar.installDir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: gp.x87sidecar.binaryURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gp.x87sidecar.binaryURL.path)
        var x87Profile = profile
        x87Profile.x87Acceleration = true
        let x87Env = try WineRunner(paths: paths, engine: engine, profile: x87Profile, recipe: nil).environment()
        XCTAssertEqual(x87Env["ROSETTA_X87_PATH"], gp.x87sidecar.binaryURL.path)

        var aarchxProfile = profile
        aarchxProfile.executionRunner = .aarchxFEX
        aarchxProfile.performanceCores = false
        let aarchxRunner = WineRunner(paths: paths, engine: engine, profile: aarchxProfile, recipe: nil)
        let wrapped = try aarchxRunner.resolvedCommand(arguments: ["game.exe"], applyPerformanceCores: true)
        XCTAssertEqual(wrapped.executable, ocerz.path)
        XCTAssertEqual(wrapped.arguments, ["-fex", wineBin.path, "game.exe"])
    }

    func testExternalDiscoveryCrossOverMacSteamNotProtonAndObeliskSuggestion() throws {
        let fm = FileManager.default
        let apps = temp.appendingPathComponent("Applications", isDirectory: true)
        let fakeHome = temp.appendingPathComponent("FakeHome", isDirectory: true)
        try fm.createDirectory(at: apps.appendingPathComponent("Obelisk.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: apps.appendingPathComponent("CrossOver.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: apps.appendingPathComponent("Steam.app"), withIntermediateDirectories: true)

        // Fake Mac Steam game + NotProton compat tool
        let macSteamApps = fakeHome.appendingPathComponent("Library/Application Support/Steam/steamapps", isDirectory: true)
        let compatTools = fakeHome.appendingPathComponent("Library/Application Support/Steam/compatibilitytools.d/NotProton", isDirectory: true)
        try fm.createDirectory(at: macSteamApps, withIntermediateDirectories: true)
        try fm.createDirectory(at: compatTools, withIntermediateDirectories: true)
        let acf = """
        "AppState"
        {
            "appid"        "440"
            "name"         "Team Fortress 2"
            "installdir"   "Team Fortress 2"
            "SizeOnDisk"   "25000000000"
        }
        """
        try acf.write(to: macSteamApps.appendingPathComponent("appmanifest_440.acf"), atomically: true, encoding: .utf8)

        // Fake CrossOver bottle with Rocket League
        let bottle = fakeHome.appendingPathComponent("Library/Application Support/CrossOver/Bottles/Steam", isDirectory: true)
        let bottleApps = bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps", isDirectory: true)
        try fm.createDirectory(at: bottleApps, withIntermediateDirectories: true)
        try Data("[Bottle]\n".utf8).write(to: bottle.appendingPathComponent("cxbottle.conf"))
        let rlACF = """
        "AppState"
        {
            "appid"        "252950"
            "name"         "Rocket League"
            "installdir"   "rocketleague"
        }
        """
        try rlACF.write(to: bottleApps.appendingPathComponent("appmanifest_252950.acf"), atomically: true, encoding: .utf8)

        let env = ExternalDiscovery.scan(applicationsDirs: [apps], home: fakeHome)
        XCTAssertTrue(env.hasObelisk)
        XCTAssertTrue(env.hasCrossOver)
        XCTAssertTrue(env.hasMacSteam)
        XCTAssertTrue(env.notProtonInstalled)
        XCTAssertEqual(env.macSteamGame(appID: 440)?.name, "Team Fortress 2")
        XCTAssertEqual(env.crossoverBottle(containingAppID: 252950)?.name, "Steam")

        // Obelisk suggestion triggers ONLY for Linux-supported EAC/BattlEye games, never VAC or Denied ones
        let linuxEAC = AntiCheatEntry(id: "rl", title: "Rocket League", antiCheats: ["Easy Anti-Cheat"],
                                      linuxStatus: "Supported", steamAppID: 252950, macVerdict: .warning)
        let vacGame = AntiCheatEntry(id: "tf2", title: "Team Fortress 2", antiCheats: ["VAC"],
                                     linuxStatus: "Supported", steamAppID: 440, macVerdict: .warning)
        let deniedAC = AntiCheatEntry(id: "val", title: "Valorant", antiCheats: ["Vanguard"],
                                      linuxStatus: "Denied", steamAppID: nil, macVerdict: .blocked)
        XCTAssertTrue(ExternalEnvironment.suggestsObelisk(for: linuxEAC))
        XCTAssertFalse(ExternalEnvironment.suggestsObelisk(for: vacGame))
        XCTAssertFalse(ExternalEnvironment.suggestsObelisk(for: deniedAC))
        XCTAssertFalse(ExternalEnvironment.suggestsObelisk(for: nil))

        // Siliconium suggestion triggers strictly for supported classic Call of Duty Steam AppIDs
        XCTAssertTrue(ExternalEnvironment.suggestsSiliconium(steamAppID: 7940))   // CoD 4
        XCTAssertTrue(ExternalEnvironment.suggestsSiliconium(steamAppID: 311210)) // BO3
        XCTAssertFalse(ExternalEnvironment.suggestsSiliconium(steamAppID: 440))   // TF2
        XCTAssertFalse(ExternalEnvironment.suggestsSiliconium(steamAppID: nil))
    }

    func testDiagnosticReportRedactsUserHome() throws {
        let gp = GamePort(paths: Paths(root: temp))
        let profile = Profile(id: "tf2", title: "Team Fortress 2", recipeID: "team-fortress-2", engineID: "e1")
        try gp.profiles.save(profile)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        try "err: something failed at \(home)/secret/file.dll\n".write(
            to: gp.profiles.logs("tf2").appendingPathComponent("game.log"),
            atomically: true, encoding: .utf8
        )
        let report = gp.diagnosticReport(profileID: "tf2")
        XCTAssertTrue(report.contains("Team Fortress 2"))
        XCTAssertFalse(report.contains(home))
        XCTAssertTrue(report.contains("~/secret/file.dll"))
    }
}
