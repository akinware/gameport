import XCTest
@testable import GamePortKit

final class ExternalDriveTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    func testAMissingDriveIsOfflineAndGamePortUsesTheInternalFolder() throws {
        let pref = temp.appendingPathComponent("storage.json")
        let missing = "/Volumes/GamePort-Test-Missing-\(UUID().uuidString.prefix(8))"
        for saved in [missing + "/GamePort", missing] {
            try StoragePreference.save(StoragePreference(customRoot: saved), to: pref)
            let paths = Paths.default(environment: [:], preferenceFile: pref)
            XCTAssertFalse(paths.root.path.hasPrefix("/Volumes/"), "\(saved): not a folder on a drive that is not there")
            XCTAssertEqual(StoragePreference.offlineRoot(environment: [:], preferenceFile: pref)?.path, saved)
            XCTAssertNil(StoragePreference.offlineRoot(environment: [Brand.homeEnvironmentVariable: temp.path], preferenceFile: pref))
        }
        // An internal custom folder is always reachable, also before its first run.
        let internalFolder = temp.appendingPathComponent("Games/GamePort")
        try StoragePreference.save(StoragePreference(customRoot: internalFolder.path), to: pref)
        XCTAssertNil(StoragePreference.offlineRoot(environment: [:], preferenceFile: pref), "its parent does not exist yet")
        try FileManager.default.createDirectory(at: internalFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertNil(StoragePreference.offlineRoot(environment: [:], preferenceFile: pref))
        XCTAssertEqual(Paths.default(environment: [:], preferenceFile: pref).root.path, internalFolder.path)
    }

    func testOnlyARealDriveCountsUnderVolumes() {
        XCTAssertTrue(StoragePreference.isOnMountedVolume(temp))
        XCTAssertFalse(StoragePreference.isOnMountedVolume(URL(fileURLWithPath: "/Volumes/GamePort-Test-Missing-\(UUID().uuidString)/x")))
        XCTAssertFalse(StoragePreference.isReachable(URL(fileURLWithPath: "/Volumes/GamePort-Test-Missing-\(UUID().uuidString)")))
        // Every drive macOS mounts under /Volumes counts.
        let mounted = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for name in mounted {
            let url = URL(fileURLWithPath: "/Volumes/\(name)")
            if (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true {
                XCTAssertTrue(StoragePreference.isOnMountedVolume(url), name)
            }
        }
    }

    /// Set GAMEPORT_TEST_EJECTABLE_VOLUME to a mounted test drive (e.g. a disk image at /Volumes/GPTest):
    /// the test uses it, ejects it, and checks GamePort notices.
    func testEjectingTheDrive() throws {
        guard let volume = ProcessInfo.processInfo.environment["GAMEPORT_TEST_EJECTABLE_VOLUME"] else {
            throw XCTSkip("no test drive given")
        }
        let pref = temp.appendingPathComponent("storage.json")
        let folder = URL(fileURLWithPath: volume).appendingPathComponent("GamePort", isDirectory: true).path
        try StoragePreference.save(StoragePreference(customRoot: folder), to: pref)
        XCTAssertEqual(Paths.default(environment: [:], preferenceFile: pref).root.path, folder)
        XCTAssertNil(StoragePreference.offlineRoot(environment: [:], preferenceFile: pref))
        let eject = Process()
        eject.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        eject.arguments = ["detach", volume, "-quiet"]
        try eject.run()
        eject.waitUntilExit()
        XCTAssertEqual(eject.terminationStatus, 0)
        XCTAssertNotEqual(Paths.default(environment: [:], preferenceFile: pref).root.path, folder)
        XCTAssertEqual(StoragePreference.offlineRoot(environment: [:], preferenceFile: pref)?.path, folder)
    }

    func testAutomaticSnapshotsNeverCopyTheWholeGame() throws {
        // Set GAMEPORT_TEST_NON_APFS_DIR to a folder on an exFAT or Mac OS Extended drive to run this.
        guard let dir = ProcessInfo.processInfo.environment["GAMEPORT_TEST_NON_APFS_DIR"] else {
            throw XCTSkip("no non-APFS folder given")
        }
        let root = URL(fileURLWithPath: dir).appendingPathComponent("gp-\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kit = GamePort(paths: Paths(root: root))
        try kit.profiles.save(Profile(id: "g", title: "G", recipeID: nil, engineID: "e"))
        let prefix = kit.profiles.prefix("g")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try Data("game".utf8).write(to: prefix.appendingPathComponent("drive_c/game.bin"))

        XCTAssertThrowsError(try kit.profiles.createSnapshot("g", name: "auto-x", allowCopy: false))
        XCTAssertEqual(kit.profiles.listSnapshots("g"), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: kit.profiles.snapshots("g").appendingPathComponent("auto-x").path),
                       "no empty snapshot folder is left behind")
        XCTAssertNoThrow(try kit.profiles.createSnapshot("g", name: "mine"), "the player's own snapshot may still copy")
    }
}
