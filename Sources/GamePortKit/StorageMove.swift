import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What moving GamePort's data folder will do, checked before anything is touched (`StorageMove.plan`).
public struct StorageMovePlan: Sendable, Equatable {
    /// The current data folder.
    public let source: URL
    /// The folder GamePort uses afterwards.
    public let destination: URL
    /// Bytes to copy (0 when `sameVolume`: the folders are only renamed).
    public let totalBytes: Int64
    /// Free space on the destination's drive.
    public let freeBytes: Int64?
    /// Same drive: an instant rename, nothing is copied.
    public let sameVolume: Bool
    public let destinationIsAPFS: Bool

    /// "Moves 16.2 GB to Samsung T7 (812 GB free). Takes a few minutes."
    public var summary: String {
        let volume = StorageInfo.inspect(destination, isCustom: true).volumeName
        if sameVolume { return "Moves GamePort's folder to \(destination.path) on \(volume). Nothing is copied, so it takes a moment." }
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let free = freeBytes.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) free)" } ?? ""
        let gigabytes = Double(totalBytes) / 1_000_000_000
        let time = gigabytes < 5 ? "Takes a minute or two." : gigabytes < 100 ? "Takes a few minutes." : "Can take an hour or more."
        return "Moves \(size) to \(volume)\(free). \(time)"
    }
}

public struct StorageMoveProgress: Sendable, Equatable {
    public let copiedBytes: Int64
    public let totalBytes: Int64
    /// The path being copied, relative to the data folder.
    public let currentItem: String

    public var fraction: Double { totalBytes <= 0 ? 1 : min(1, Double(copiedBytes) / Double(totalBytes)) }
}

/// Moves GamePort's whole data folder (engines, Windows copies, downloads) to another folder or drive.
///
/// Safe by construction:
/// - `plan` checks everything first: nothing may be using the folder, the destination must be empty
///   (or be the internal folder, which only holds `storage.json`), and another drive needs room for it all.
/// - On the same drive the folders are renamed (instant). On another drive everything is copied into a
///   hidden staging folder, verified (same files, same bytes), and only then put in place, saved as the new
///   folder, and removed from the old place. Any error or cancel before that leaves the old folder and the
///   setting exactly as they were.
/// - `storage.json`, which says where the data folder is, never moves.
/// - Links into the old folder are pointed at the new one, and GamePort's own JSON files outside the
///   Windows copies get the new path; game files and Windows registries are never rewritten.
public enum StorageMove {
    /// Tests: take the copy path on one drive.
    static var forceCopy = false
    /// Room kept free on the destination beyond the data itself.
    static let margin: Int64 = 1 << 30
    /// Files a destination may already hold (Finder's).
    static let ignorable: Set<String> = [".DS_Store"]

    public static func plan(to destination: URL, from source: URL = Paths.default().root,
                            preferenceFile: URL = StoragePreference.preferenceFile) throws -> StorageMovePlan {
        let fm = FileManager.default
        let src = source.standardizedFileURL
        var dst = destination.standardizedFileURL
        if dst.pathComponents.count == 3, dst.pathComponents[1] == "Volumes" {
            dst = dst.appendingPathComponent(Brand.dataFolder, isDirectory: true)
        }
        let anchor = preferenceFile.deletingLastPathComponent().standardizedFileURL
        guard fm.fileExists(atPath: src.path) else { throw GamePortError.missing("GamePort's folder at \(src.path)") }
        guard dst.path != src.path else { throw GamePortError.invalid("GamePort already uses \(dst.path)") }
        guard !dst.path.hasPrefix(src.path + "/") else {
            throw GamePortError.invalid("the new folder cannot be inside GamePort's current folder")
        }
        guard !src.path.hasPrefix(dst.path + "/") else {
            throw GamePortError.invalid("the new folder cannot contain GamePort's current folder")
        }
        guard StoragePreference.isReachable(dst) else {
            throw GamePortError.invalid("the drive for \(dst.path) is not connected")
        }
        if fm.fileExists(atPath: dst.path) {
            let kept = dst.path == anchor.path ? [preferenceFile.lastPathComponent] : []
            let contents = try fm.contentsOfDirectory(atPath: dst.path)
                .filter { !ignorable.contains($0) && !kept.contains($0) }
            guard contents.isEmpty else {
                throw GamePortError.invalid("\(dst.path) is not empty. Choose an empty folder, or a drive")
            }
        }
        if let program = programUsing(src) {
            throw GamePortError.invalid("something is still using GamePort's folder (\(program)). Quit games, Steam and downloads first")
        }

        let existing = nearestExistingFolder(dst)
        let same = !forceCopy && device(src) != nil && device(src) == device(existing)
        let values = try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        var bytes: Int64 = 0
        if !same {
            bytes = try entries(in: src, skipping: skipped(src, preferenceFile: preferenceFile)).reduce(0) { $0 + $1.bytes }
            if let free, free < bytes + margin {
                let need = ByteCountFormatter.string(fromByteCount: bytes + margin, countStyle: .file)
                throw GamePortError.invalid("not enough space on that drive: GamePort needs \(need) free")
            }
        }
        let fs = StorageInfo.filesystemName(at: existing.path)
        return StorageMovePlan(source: src, destination: dst, totalBytes: bytes, freeBytes: free,
                               sameVolume: same, destinationIsAPFS: fs.lowercased() == "apfs")
    }

    @discardableResult
    public static func perform(_ plan: StorageMovePlan,
                               preferenceFile: URL = StoragePreference.preferenceFile,
                               progress: (StorageMoveProgress) -> Void = { _ in },
                               isCancelled: () -> Bool = { false }) throws -> StorageInfo {
        let fm = FileManager.default
        let src = plan.source, dst = plan.destination
        let skip = skipped(src, preferenceFile: preferenceFile)
        let createdDestination = !fm.fileExists(atPath: dst.path)
        // Undoes everything this move did to the destination; the source is untouched until the very end.
        var undo: () -> Void = {}

        if plan.sameVolume {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            var moved: [(from: URL, to: URL)] = []
            undo = {
                for item in moved.reversed() { try? fm.moveItem(at: item.to, to: item.from) }
                try? repointLinks(in: src, from: dst, to: src)
                rewriteOwnJSON(in: src, from: dst, to: src)
                if createdDestination { try? fm.removeItem(at: dst) }
            }
            do {
                for child in try topLevel(src, skipping: skip) {
                    if isCancelled() { throw cancelled }
                    let target = dst.appendingPathComponent(child.lastPathComponent)
                    try fm.moveItem(at: child, to: target)
                    moved.append((child, target))
                }
                try repointLinks(in: dst, from: src, to: dst)
                rewriteOwnJSON(in: dst, from: src, to: dst)
            } catch {
                undo()
                throw error
            }
            progress(StorageMoveProgress(copiedBytes: 0, totalBytes: 0, currentItem: ""))
        } else {
            let staging = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).moving", isDirectory: true)
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            var placed: [URL] = []
            undo = {
                try? fm.removeItem(at: staging)
                for item in placed { try? fm.removeItem(at: item) }
                if createdDestination { try? fm.removeItem(at: dst) }
            }
            do {
                let all = try entries(in: src, skipping: skip)
                var copied: Int64 = 0
                var lastReport = Date.distantPast
                for entry in all {
                    if isCancelled() { throw cancelled }
                    let target = staging.appendingPathComponent(entry.relative)
                    switch entry.kind {
                    case .directory:
                        try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    case .symlink(let destination):
                        try fm.createSymbolicLink(atPath: target.path, withDestinationPath: repointed(destination, from: src, to: dst))
                    case .file:
                        try fm.copyItem(at: entry.url, to: target)
                        copied += entry.bytes
                    }
                    let now = Date()
                    if now.timeIntervalSince(lastReport) >= 0.25 {
                        lastReport = now
                        progress(StorageMoveProgress(copiedBytes: copied, totalBytes: plan.totalBytes, currentItem: entry.relative))
                    }
                }
                // Folders get their dates and permissions once their contents are in.
                for entry in all.reversed() where entry.kind == .directory {
                    guard let original = try? fm.attributesOfItem(atPath: entry.url.path) else { continue }
                    var kept: [FileAttributeKey: Any] = [:]
                    for key in [FileAttributeKey.posixPermissions, .modificationDate] { kept[key] = original[key] }
                    try? fm.setAttributes(kept, ofItemAtPath: staging.appendingPathComponent(entry.relative).path)
                }
                try verify(staging, against: all)
                rewriteOwnJSON(in: staging, from: src, to: dst)
                if isCancelled() { throw cancelled }
                progress(StorageMoveProgress(copiedBytes: copied, totalBytes: plan.totalBytes, currentItem: ""))
                if createdDestination {
                    try fm.moveItem(at: staging, to: dst)
                } else {
                    // The destination exists (empty, or the internal folder with storage.json): put each item in.
                    for child in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                        let target = dst.appendingPathComponent(child.lastPathComponent)
                        if ignorable.contains(child.lastPathComponent) { try? fm.removeItem(at: target) }
                        try fm.moveItem(at: child, to: target)
                        placed.append(target)
                    }
                    try fm.removeItem(at: staging)
                }
            } catch {
                undo()
                throw error
            }
        }

        // The new place is complete: save it, then clear the old one.
        let toInternal = dst.path == preferenceFile.deletingLastPathComponent().standardizedFileURL.path
        do {
            if toInternal {
                if fm.fileExists(atPath: preferenceFile.path) { try fm.removeItem(at: preferenceFile) }
            } else {
                try StoragePreference.save(StoragePreference(customRoot: dst.path), to: preferenceFile)
            }
        } catch {
            undo()
            throw error
        }
        if !plan.sameVolume {
            for child in (try? topLevel(src, skipping: skip)) ?? [] { try? fm.removeItem(at: child) }
        }
        if skip.isEmpty, ((try? fm.contentsOfDirectory(atPath: src.path)) ?? ["?"]).allSatisfy(ignorable.contains) {
            try? fm.removeItem(at: src)
        }
        return StorageInfo.inspect(dst, isCustom: !toInternal)
    }

    // MARK: - Pieces

    static let cancelled = GamePortError.invalid("the move was cancelled; nothing changed")

    struct Entry {
        enum Kind: Equatable { case directory, file, symlink(String) }
        let url: URL
        let relative: String
        let kind: Kind
        let bytes: Int64
    }

    /// `storage.json` stays where it is when the data folder is the internal one that holds it.
    static func skipped(_ source: URL, preferenceFile: URL) -> Set<String> {
        preferenceFile.deletingLastPathComponent().standardizedFileURL.path == source.path ? [preferenceFile.lastPathComponent] : []
    }

    static func topLevel(_ folder: URL, skipping: Set<String>) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !skipping.contains($0.lastPathComponent) }
    }

    /// Every item under `root`, parents before children, links not followed.
    static func entries(in root: URL, skipping: Set<String>) throws -> [Entry] {
        let fm = FileManager.default
        var result: [Entry] = []
        func visit(_ folder: URL, _ prefix: String) throws {
            for name in try fm.contentsOfDirectory(atPath: folder.path).sorted() {
                if prefix.isEmpty, skipping.contains(name) { continue }
                let url = folder.appendingPathComponent(name)
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw GamePortError.invalid("cannot read \(url.path)") }
                switch info.st_mode & S_IFMT {
                case S_IFLNK:
                    result.append(Entry(url: url, relative: relative, kind: .symlink(try fm.destinationOfSymbolicLink(atPath: url.path)), bytes: 0))
                case S_IFDIR:
                    result.append(Entry(url: url, relative: relative, kind: .directory, bytes: 0))
                    try visit(url, relative)
                case S_IFREG:
                    result.append(Entry(url: url, relative: relative, kind: .file, bytes: Int64(info.st_size)))
                default:
                    continue // sockets, pipes: nothing to keep
                }
            }
        }
        try visit(root, "")
        return result
    }

    /// The copy has every file, link and folder of the original, with the same sizes.
    static func verify(_ copy: URL, against original: [Entry]) throws {
        let copied = try entries(in: copy, skipping: [])
        let files = { (list: [Entry]) in list.filter { $0.kind == .file } }
        let count = { (list: [Entry]) in (files(list).count, list.filter { $0.kind != .file && $0.kind != .directory }.count, list.filter { $0.kind == .directory }.count) }
        let bytes = { (list: [Entry]) in files(list).reduce(Int64(0)) { $0 + $1.bytes } }
        guard count(copied) == count(original), bytes(copied) == bytes(original) else {
            throw GamePortError.invalid("the copy did not match the original (\(files(copied).count) of \(files(original).count) files, \(bytes(copied)) of \(bytes(original)) bytes); nothing changed")
        }
    }

    /// A link target inside the old folder, pointed at the same place in the new one.
    static func repointed(_ target: String, from source: URL, to destination: URL) -> String {
        if target == source.path { return destination.path }
        guard target.hasPrefix(source.path + "/") else { return target }
        return destination.path + target.dropFirst(source.path.count)
    }

    /// After a rename: links that pointed into the old folder point into the new one.
    static func repointLinks(in root: URL, from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        for entry in try entries(in: root, skipping: []) {
            guard case .symlink(let target) = entry.kind else { continue }
            let fixed = repointed(target, from: source, to: destination)
            guard fixed != target else { continue }
            try fm.removeItem(at: entry.url)
            try fm.createSymbolicLink(atPath: entry.url.path, withDestinationPath: fixed)
        }
    }

    /// GamePort's own JSON files (not those inside Windows copies, snapshots, downloads or engines) that hold
    /// the old folder's path get the new one. The text is changed in place, so nothing else in the file moves.
    static func rewriteOwnJSON(in root: URL, from source: URL, to destination: URL) {
        let excluded: Set<String> = ["prefix", "home", "snapshots", "drive_c", "engines", "bases", "downloads", "depots", "tmp"]
        guard let all = try? entries(in: root, skipping: []) else { return }
        let forms = [(source.path, destination.path),
                     (source.path.replacingOccurrences(of: "/", with: "\\/"), destination.path.replacingOccurrences(of: "/", with: "\\/"))]
        for entry in all where entry.kind == .file && entry.url.pathExtension.lowercased() == "json" {
            guard entry.bytes < 4 << 20, Set(entry.relative.split(separator: "/").dropLast().map(String.init)).isDisjoint(with: excluded),
                  let text = try? String(contentsOf: entry.url, encoding: .utf8) else { continue }
            var changed = text
            for (old, new) in forms {
                for end in ["\"", "/", "\\/"] { changed = changed.replacingOccurrences(of: "\"" + old + end, with: "\"" + new + end) }
            }
            if changed != text { try? changed.write(to: entry.url, atomically: true, encoding: .utf8) }
        }
    }

    /// A process (other than this one) whose command line names the data folder: Wine, a game, a download.
    static func programUsing(_ folder: URL) -> String? {
        let ps = (try? Shell.run("/bin/ps", ["-axww", "-o", "pid=,command="], check: false).output) ?? ""
        let own = ProcessInfo.processInfo.processIdentifier
        for line in ps.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            let parts = text.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, Int32(parts[0]) != own, parts[1].contains(folder.path) else { continue }
            let command = String(parts[1])
            let program = command.components(separatedBy: folder.path + "/").last?.split(separator: " ").first.map(String.init) ?? command
            return URL(fileURLWithPath: program).lastPathComponent
        }
        return nil
    }

    static func nearestExistingFolder(_ url: URL) -> URL {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe = probe.deletingLastPathComponent() }
        return probe
    }

    static func device(_ url: URL) -> dev_t? {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_dev : nil
    }
}
