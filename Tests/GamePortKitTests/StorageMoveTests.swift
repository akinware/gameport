import XCTest
@testable import GamePortKit

final class StorageMoveTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("move-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        StorageMove.forceCopy = false
    }

    override func tearDownWithError() throws {
        StorageMove.forceCopy = false
        try? fm.removeItem(at: base)
    }

    private func write(_ text: String, _ relative: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ relative: String, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// A small data folder like GamePort's: a profile with a Windows copy, links into and out of it,
    /// GamePort's own JSON with the folder's path, and a game's own JSON that must stay byte for byte.
    private func makeData(at root: URL) throws {
        try write("dll", "tools/steam-bridge/x86_64-windows/steamclient64.dll", in: root)
        try write("reg", "profiles/game/prefix/user.reg", in: root)
        try write("save", "profiles/game/prefix/drive_c/users/save.dat", in: root)
        let gameJSON = "{\"path\":\"\(root.path)/keep\",   \"spacing\":   1}"
        try write(gameJSON, "profiles/game/prefix/drive_c/Game/config.json", in: root)
        try write("{\n  \"depot\" : \"\(root.path.replacingOccurrences(of: "/", with: "\\/"))\\/tools\\/depots\\/1\",\n  \"title\" : \"G\"\n}", "profiles/game/profile.json", in: root)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("profiles/game/prefix/steamclient64.dll").path,
                                  withDestinationPath: root.appendingPathComponent("tools/steam-bridge/x86_64-windows/steamclient64.dll").path)
        try fm.createDirectory(at: root.appendingPathComponent("profiles/game/prefix/dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("profiles/game/prefix/dosdevices/c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("profiles/game/prefix/dosdevices/z:").path, withDestinationPath: "/")
        try fm.createDirectory(at: root.appendingPathComponent("downloads"), withIntermediateDirectories: true)
    }

    private func assertMoved(from old: URL, to new: URL, madeAt origin: URL? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try read("profiles/game/prefix/drive_c/users/save.dat", in: new), "save", file: file, line: line)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: new.appendingPathComponent("profiles/game/prefix/steamclient64.dll").path),
                       new.appendingPathComponent("tools/steam-bridge/x86_64-windows/steamclient64.dll").path, "a link into the folder follows it", file: file, line: line)
        XCTAssertEqual(try read("profiles/game/prefix/steamclient64.dll", in: new), "dll", file: file, line: line)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: new.appendingPathComponent("profiles/game/prefix/dosdevices/c:").path), "../drive_c", file: file, line: line)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: new.appendingPathComponent("profiles/game/prefix/dosdevices/z:").path), "/", file: file, line: line)
        XCTAssertEqual(try read("profiles/game/prefix/drive_c/Game/config.json", in: new), "{\"path\":\"\((origin ?? old).path)/keep\",   \"spacing\":   1}",
                       "game files are never rewritten", file: file, line: line)
        let profile = try read("profiles/game/profile.json", in: new)
        XCTAssertTrue(profile.contains(new.path.replacingOccurrences(of: "/", with: "\\/") + "\\/tools\\/depots\\/1"), profile, file: file, line: line)
        XCTAssertTrue(profile.contains("\"title\" : \"G\""), "the rest of GamePort's file is unchanged", file: file, line: line)
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent("downloads").path), "empty folders come along", file: file, line: line)
    }

    // MARK: - Planning

    func testRefusesWhatWouldBreak() throws {
        let pref = base.appendingPathComponent("anchor/storage.json")
        let source = base.appendingPathComponent("data")
        try makeData(at: source)
        XCTAssertThrowsError(try StorageMove.plan(to: source, from: source, preferenceFile: pref))
        XCTAssertThrowsError(try StorageMove.plan(to: source.appendingPathComponent("inside"), from: source, preferenceFile: pref))
        XCTAssertThrowsError(try StorageMove.plan(to: base, from: source, preferenceFile: pref))
        let occupied = base.appendingPathComponent("occupied")
        try write("x", "x", in: occupied)
        XCTAssertThrowsError(try StorageMove.plan(to: occupied, from: source, preferenceFile: pref))
        XCTAssertThrowsError(try StorageMove.plan(to: URL(fileURLWithPath: "/Volumes/GamePort-Test-Missing-\(UUID().uuidString.prefix(6))"), from: source, preferenceFile: pref))
        XCTAssertThrowsError(try StorageMove.plan(to: base.appendingPathComponent("new"), from: base.appendingPathComponent("missing"), preferenceFile: pref))
        // A Finder file does not make a folder "not empty".
        let finder = base.appendingPathComponent("finder")
        try write("", ".DS_Store", in: finder)
        XCTAssertNoThrow(try StorageMove.plan(to: finder, from: source, preferenceFile: pref))
    }

    func testRefusesWhileSomethingUsesTheFolder() throws {
        let source = base.appendingPathComponent("data")
        try makeData(at: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 20; exit 0", source.appendingPathComponent("engines/wine/bin/wineserver").path]
        try process.run()
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertThrowsError(try StorageMove.plan(to: base.appendingPathComponent("new"), from: source,
                                                  preferenceFile: base.appendingPathComponent("anchor/storage.json"))) { error in
            XCTAssertTrue("\(error)".contains("using GamePort's folder"), "\(error)")
        }
    }

    func testPlanCountsWhatACopyNeeds() throws {
        let source = base.appendingPathComponent("data")
        try makeData(at: source)
        StorageMove.forceCopy = true
        let plan = try StorageMove.plan(to: base.appendingPathComponent("new"), from: source, preferenceFile: base.appendingPathComponent("a/storage.json"))
        XCTAssertFalse(plan.sameVolume)
        let expected = try StorageMove.entries(in: source, skipping: []).reduce(Int64(0)) { $0 + $1.bytes }
        XCTAssertEqual(plan.totalBytes, expected)
        XCTAssertTrue(plan.summary.hasPrefix("Moves "), plan.summary)
        StorageMove.forceCopy = false
        XCTAssertTrue(try StorageMove.plan(to: base.appendingPathComponent("new"), from: source, preferenceFile: base.appendingPathComponent("a/storage.json")).sameVolume)
    }

    // MARK: - Moving

    func testRenameOnTheSameDrive() throws {
        let pref = base.appendingPathComponent("anchor/storage.json")
        let source = base.appendingPathComponent("data"), destination = base.appendingPathComponent("elsewhere/GamePort")
        try makeData(at: source)
        let plan = try StorageMove.plan(to: destination, from: source, preferenceFile: pref)
        XCTAssertTrue(plan.sameVolume)
        let info = try StorageMove.perform(plan, preferenceFile: pref)
        try assertMoved(from: source, to: destination)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(StoragePreference.load(from: pref).customRoot, destination.path)
        XCTAssertEqual(info.root.path, destination.path)
    }

    func testCopyToAnotherDrive() throws {
        let pref = base.appendingPathComponent("anchor/storage.json")
        let source = base.appendingPathComponent("data"), destination = base.appendingPathComponent("drive/GamePort")
        try makeData(at: source)
        StorageMove.forceCopy = true
        let plan = try StorageMove.plan(to: destination, from: source, preferenceFile: pref)
        var reports: [StorageMoveProgress] = []
        try StorageMove.perform(plan, preferenceFile: pref, progress: { reports.append($0) })
        try assertMoved(from: source, to: destination)
        XCTAssertFalse(fm.fileExists(atPath: source.path), "the old copy is gone once the new one is in use")
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("drive/.GamePort.moving").path))
        XCTAssertEqual(StoragePreference.load(from: pref).customRoot, destination.path)
        XCTAssertEqual(reports.last?.fraction, 1)
    }

    func testCopyIntoAnExistingEmptyFolder() throws {
        let pref = base.appendingPathComponent("anchor/storage.json")
        let source = base.appendingPathComponent("data"), destination = base.appendingPathComponent("drive/Games")
        try makeData(at: source)
        try write("", ".DS_Store", in: destination)
        StorageMove.forceCopy = true
        try StorageMove.perform(try StorageMove.plan(to: destination, from: source, preferenceFile: pref), preferenceFile: pref)
        try assertMoved(from: source, to: destination)
    }

    /// The internal folder holds storage.json: moving out keeps it there and says where the games went;
    /// moving back in works although the folder is not empty, and the setting goes back to the default.
    func testOutOfAndBackIntoTheInternalFolder() throws {
        let anchor = base.appendingPathComponent("Library/GamePort")
        let pref = anchor.appendingPathComponent("storage.json")
        try makeData(at: anchor)
        let drive = base.appendingPathComponent("Drive/GamePort")
        for copy in [true, false] {
            StorageMove.forceCopy = copy
            try StorageMove.perform(try StorageMove.plan(to: drive, from: anchor, preferenceFile: pref), preferenceFile: pref)
            try assertMoved(from: anchor, to: drive, madeAt: anchor)
            XCTAssertEqual(StoragePreference.load(from: pref).customRoot, drive.path, "copy: \(copy)")
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: anchor.path), ["storage.json"], "only the setting stays behind")

            let back = try StorageMove.plan(to: anchor, from: drive, preferenceFile: pref)
            try StorageMove.perform(back, preferenceFile: pref)
            try assertMoved(from: drive, to: anchor, madeAt: anchor)
            XCTAssertFalse(fm.fileExists(atPath: pref.path), "the internal folder is the default again")
            XCTAssertNil(StoragePreference.load(from: pref).customRoot)
            XCTAssertFalse(fm.fileExists(atPath: drive.path))
        }
    }

    func testCancelChangesNothing() throws {
        let pref = base.appendingPathComponent("anchor/storage.json")
        try StoragePreference.save(StoragePreference(customRoot: base.appendingPathComponent("data").path), to: pref)
        let source = base.appendingPathComponent("data"), destination = base.appendingPathComponent("drive/GamePort")
        try makeData(at: source)
        let before = try StorageMove.entries(in: source, skipping: []).map(\.relative)
        for copy in [true, false] {
            StorageMove.forceCopy = copy
            var calls = 0
            let plan = try StorageMove.plan(to: destination, from: source, preferenceFile: pref)
            XCTAssertThrowsError(try StorageMove.perform(plan, preferenceFile: pref, isCancelled: { calls += 1; return calls > 1 }))
            XCTAssertEqual(try StorageMove.entries(in: source, skipping: []).map(\.relative), before, "copy: \(copy)")
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: source.appendingPathComponent("profiles/game/prefix/steamclient64.dll").path),
                           source.appendingPathComponent("tools/steam-bridge/x86_64-windows/steamclient64.dll").path)
            XCTAssertFalse(fm.fileExists(atPath: destination.path))
            XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("drive/.GamePort.moving").path))
            XCTAssertEqual(StoragePreference.load(from: pref).customRoot, source.path)
        }
    }

    func testAFailedCopyChangesNothing() throws {
        let pref = base.appendingPathComponent("anchor/storage.json")
        let source = base.appendingPathComponent("data"), destination = base.appendingPathComponent("drive/GamePort")
        try makeData(at: source)
        let unreadable = source.appendingPathComponent("profiles/game/prefix/locked.bin")
        try write("secret", "profiles/game/prefix/locked.bin", in: source)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        StorageMove.forceCopy = true
        let plan = try StorageMove.plan(to: destination, from: source, preferenceFile: pref)
        XCTAssertThrowsError(try StorageMove.perform(plan, preferenceFile: pref))
        XCTAssertTrue(fm.fileExists(atPath: unreadable.path))
        try assertNotMoved(source, destination, pref)
    }

    private func assertNotMoved(_ source: URL, _ destination: URL, _ pref: URL) throws {
        XCTAssertEqual(try read("profiles/game/prefix/drive_c/users/save.dat", in: source), "save")
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertFalse(fm.fileExists(atPath: destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).moving").path))
        XCTAssertNil(StoragePreference.load(from: pref).customRoot)
    }
}
