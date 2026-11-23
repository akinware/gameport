import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// APFS clones: a copy that shares every block with the original until one side writes to it.
/// Cloning a prefix with a 50 GB game in it takes seconds and almost no disk.
public enum CopyOnWrite {
    /// Clones `source` (file or whole directory tree) to `destination`, which must not exist.
    /// Falls back to a plain copy where the volume cannot clone (not APFS, another volume), unless
    /// `allowCopy` is false (for game folders too big to copy in full).
    public static func clone(_ source: URL, to destination: URL, allowCopy: Bool = true) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if canImport(Darwin)
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        guard errno == ENOTSUP || errno == EXDEV else {
            throw GamePortError.invalid("could not clone \(source.path): \(String(cString: strerror(errno)))")
        }
        #endif
        guard allowCopy else {
            throw GamePortError.unsupported("\(source.path) cannot be cloned to \(destination.path) (not the same APFS volume), and a full copy is not allowed here")
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Puts a clone of `source` at `destination`, replacing what is there only once the clone is complete.
    public static func replace(_ destination: URL, withCloneOf source: URL) throws {
        let fresh = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).new")
        let old = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).old")
        try? FileManager.default.removeItem(at: fresh)
        try? FileManager.default.removeItem(at: old)
        try clone(source, to: fresh)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: destination, to: old)
        }
        try FileManager.default.moveItem(at: fresh, to: destination)
        try? FileManager.default.removeItem(at: old)
    }
}

/// A saved state of a profile's prefix (Steam, game files, saves, registry) to roll back to
/// after a Steam, game or engine update breaks something.
public struct Snapshot: Codable, Sendable, Equatable {
    public var name: String
    public var engineID: String
    public var createdAt: Date
}

extension ProfileStore {
    public func snapshots(_ id: String) -> URL { directory(id).appendingPathComponent("snapshots", isDirectory: true) }
    func snapshotDirectory(_ id: String, _ name: String) -> URL { snapshots(id).appendingPathComponent(name, isDirectory: true) }

    /// Newest first.
    public func listSnapshots(_ id: String) -> [Snapshot] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: snapshots(id).path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.compactMap { name in
            let meta = snapshotDirectory(id, name).appendingPathComponent("snapshot.json")
            return (try? Data(contentsOf: meta)).flatMap { try? decoder.decode(Snapshot.self, from: $0) }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func snapshotName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.string(from: date)
    }

    /// Clones the prefix. Stop the profile first, or the registry Wine has not flushed yet is missed.
    /// `allowCopy`: where the drive cannot clone (not APFS), make a full copy instead of failing. A full
    /// copy holds the whole game again, so automatic snapshots never do that.
    @discardableResult
    public func createSnapshot(_ id: String, name: String? = nil, now: Date = Date(), allowCopy: Bool = true) throws -> Snapshot {
        let profile = try load(id)
        let name = name ?? Self.snapshotName(now)
        try validateID(name, what: "snapshot name")
        let dir = snapshotDirectory(id, name)
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw GamePortError.invalid("snapshot \(name) already exists") }
        guard FileManager.default.fileExists(atPath: prefix(id).path) else { throw GamePortError.missing("the Windows environment of profile \(id)") }
        do {
            try CopyOnWrite.clone(prefix(id), to: dir.appendingPathComponent("prefix", isDirectory: true), allowCopy: allowCopy)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        let snapshot = Snapshot(name: name, engineID: profile.engineID, createdAt: now)
        let encoder = JSONEncoder.pretty
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: dir.appendingPathComponent("snapshot.json"))
        return snapshot
    }

    /// Replaces the prefix with the snapshot's (the snapshot itself is kept) and puts the profile
    /// back on the engine it was taken with. Stop the profile first.
    @discardableResult
    public func restoreSnapshot(_ id: String, name: String) throws -> Snapshot {
        try validateID(name, what: "snapshot name")
        guard let snapshot = listSnapshots(id).first(where: { $0.name == name }) else { throw GamePortError.missing("snapshot \(name)") }
        try CopyOnWrite.replace(prefix(id), withCloneOf: snapshotDirectory(id, name).appendingPathComponent("prefix", isDirectory: true))
        var profile = try load(id)
        if profile.engineID != snapshot.engineID {
            profile.engineID = snapshot.engineID
            try save(profile)
        }
        return snapshot
    }

    /// Automatic snapshots are named auto-<time>; the player's own are never pruned.
    public static let autoPrefix = "auto-"

    /// True when the newest automatic snapshot is older than `interval` (or there is none).
    public func autoSnapshotDue(_ id: String, now: Date = Date(), interval: TimeInterval = 24 * 3600) -> Bool {
        guard let last = listSnapshots(id).first(where: { $0.name.hasPrefix(Self.autoPrefix) }) else { return true }
        return now.timeIntervalSince(last.createdAt) >= interval
    }

    /// Deletes all but the newest `keep` automatic snapshots.
    public func pruneAutoSnapshots(_ id: String, keep: Int) throws {
        for old in listSnapshots(id).filter({ $0.name.hasPrefix(Self.autoPrefix) }).dropFirst(keep) {
            try deleteSnapshot(id, name: old.name)
        }
    }

    public func deleteSnapshot(_ id: String, name: String) throws {
        try validateID(name, what: "snapshot name")
        let dir = snapshotDirectory(id, name)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw GamePortError.missing("snapshot \(name)") }
        try FileManager.default.removeItem(at: dir)
    }
}
