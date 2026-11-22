import XCTest
@testable import GamePortKit

final class SteamBridgeTests: XCTestCase {
    func testMachOInspectorDetectsThinAndUniversalSlices() {
        // Thin 64-bit x86_64 Mach-O (little-endian MH_MAGIC_64 + CPU_TYPE_X86_64)
        var x64 = Data()
        x64.append(contentsOf: [0xCF, 0xFA, 0xED, 0xFE])
        x64.append(contentsOf: [0x07, 0x00, 0x00, 0x01])
        XCTAssertEqual(MachOInspector.architectures(from: x64), .init(hasX86_64: true, hasARM64: false))

        // Thin 64-bit arm64 Mach-O
        var arm = Data()
        arm.append(contentsOf: [0xCF, 0xFA, 0xED, 0xFE])
        arm.append(contentsOf: [0x0C, 0x00, 0x00, 0x01])
        XCTAssertEqual(MachOInspector.architectures(from: arm), .init(hasX86_64: false, hasARM64: true))

        // Universal FAT Mach-O (big-endian FAT_MAGIC + 2 slices: x86_64 and arm64)
        var fat = Data()
        fat.append(contentsOf: [0xCA, 0xFE, 0xBA, 0xBE]) // FAT_MAGIC
        fat.append(contentsOf: [0x00, 0x00, 0x00, 0x02]) // nfat_arch = 2
        // Entry 0 (20 bytes): CPU_TYPE_X86_64 (big-endian 0x01000007)
        fat.append(contentsOf: [0x01, 0x00, 0x00, 0x07])
        fat.append(contentsOf: Array(repeating: UInt8(0), count: 16))
        // Entry 1 (20 bytes): CPU_TYPE_ARM64 (big-endian 0x0100000C)
        fat.append(contentsOf: [0x01, 0x00, 0x00, 0x0C])
        fat.append(contentsOf: Array(repeating: UInt8(0), count: 16))
        XCTAssertEqual(MachOInspector.architectures(from: fat), .init(hasX86_64: true, hasARM64: true))

        // Non-Mach-O data
        XCTAssertEqual(MachOInspector.architectures(from: Data("MZ\0\0\0\0\0\0".utf8)), .init(hasX86_64: false, hasARM64: false))
    }

    func testVACGuardBlocksVACAndAllowsNonVAC() {
        let vacEntry = AntiCheatEntry(
            id: "counter-strike-2",
            title: "Counter-Strike 2",
            antiCheats: ["VAC"],
            linuxStatus: "Supported",
            steamAppID: 730,
            macVerdict: .warning
        )
        if case .blocked(let reason) = SteamBridge.vacDecision(for: vacEntry) {
            XCTAssertTrue(reason.contains("VAC"))
        } else {
            XCTFail("Expected VAC game to be blocked by default in Bridge mode")
        }

        let wardenEntry = AntiCheatEntry(
            id: "overwatch-2",
            title: "Overwatch 2",
            antiCheats: ["Warden"],
            linuxStatus: "Running",
            steamAppID: 2357570,
            macVerdict: .warning
        )
        XCTAssertEqual(SteamBridge.vacDecision(for: wardenEntry), .allowed)
        XCTAssertEqual(SteamBridge.vacDecision(for: nil), .allowed)
    }

    func testSteamCmdDownloadArgumentsAndProgressParsing() {
        let dir = URL(fileURLWithPath: "/tmp/game-depot")
        let args = SteamDepotManager.downloadArguments(appID: 1091500, installDir: dir, username: "alice", validate: true)
        XCTAssertEqual(args, [
            "+@sSteamCmdForcePlatformType", "windows",
            "+force_install_dir", "/tmp/game-depot",
            "+login", "alice",
            "+app_update", "1091500", "validate",
            "+quit",
        ])

        let anonArgs = SteamDepotManager.downloadArguments(appID: 480, installDir: dir, username: "   ", validate: false)
        XCTAssertTrue(anonArgs.contains("anonymous"))
        XCTAssertFalse(anonArgs.contains("validate"))

        XCTAssertEqual(SteamDepotManager.parseProgressPercent(from: " Update state (0x61) downloading, progress: 42.75 (1234 / 2886)"), 42.75)
        XCTAssertNil(SteamDepotManager.parseProgressPercent(from: "Connecting anonymously to Steam Public...OK"))
    }

    func testDiscoverMainExecutableSkipsRedistributablesAndCrashHandlers() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-depot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let fm = FileManager.default
        let redist = temp.appendingPathComponent("_CommonRedist/vcredist", isDirectory: true)
        let bin = temp.appendingPathComponent("Binaries/Win64", isDirectory: true)
        try fm.createDirectory(at: redist, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)

        try Data(repeating: 0x41, count: 6 * 1024 * 1024).write(to: redist.appendingPathComponent("vc_redist.x64.exe"))
        try Data(repeating: 0x41, count: 512).write(to: temp.appendingPathComponent("unins000.exe"))
        try Data(repeating: 0x41, count: 512).write(to: temp.appendingPathComponent("UnityCrashHandler64.exe"))
        let expected = bin.appendingPathComponent("MyCoolGame-Win64-Shipping.exe")
        try Data(repeating: 0x41, count: 2 * 1024 * 1024).write(to: expected)

        let found = SteamDepotManager.discoverMainExecutable(in: temp, preferredName: "My Cool Game")
        XCTAssertEqual(found?.standardizedFileURL, expected.standardizedFileURL)
    }

    func testWriteAppManifestIsReadableBySteamScanner() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-acf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try SteamDepotManager.writeAppManifest(appID: 2357570, name: "Overwatch 2", installDirName: "Overwatch", into: temp)
        let games = ExternalDiscovery.scanSteamApps(in: temp)
        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].appID, 2357570)
        XCTAssertEqual(games[0].name, "Overwatch 2")
        XCTAssertEqual(games[0].installDir, "Overwatch")
    }

    func testBridgeEnvironmentMatchesEngineOverlayMode() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-bridge-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let paths = Paths(root: temp)
        let bridge = SteamBridge(paths: paths)
        let dylib = URL(fileURLWithPath: "/Applications/Steam.app/Contents/MacOS/steamclient.dylib")

        let cxManifest = try XCTUnwrap(EngineStore.bundledManifest(id: "x64-crossover26.3-hb20261014"))
        let cxEngine = InstalledEngine(manifest: cxManifest, root: paths.engine(cxManifest.id))
        let cxEnv = bridge.bridgeEnvironment(engine: cxEngine, appID: 1245620, macSteamClient: dylib)
        XCTAssertEqual(cxEnv["SteamAppId"], "1245620")
        XCTAssertEqual(cxEnv["GAMEPORT_MAC_STEAMCLIENT"], dylib.path)
        XCTAssertEqual(cxEnv["WINEDLLOVERRIDES"], "steamclient64,steamclient=b")
        XCTAssertEqual(cxEnv["WINEDLLPATH_PREPEND+"], bridge.overlayDir.path)
        XCTAssertNil(cxEnv["WINEDLLPATH+"])

        let w11Manifest = try XCTUnwrap(EngineStore.bundledManifest(id: "x64-wine-staging-11.21"))
        let w11Engine = InstalledEngine(manifest: w11Manifest, root: paths.engine(w11Manifest.id))
        let w11Env = bridge.bridgeEnvironment(engine: w11Engine, appID: 1245620, macSteamClient: dylib)
        XCTAssertEqual(w11Env["WINEDLLPATH+"], bridge.overlayDir.path)
        XCTAssertNil(w11Env["WINEDLLPATH_PREPEND+"])
    }
}
