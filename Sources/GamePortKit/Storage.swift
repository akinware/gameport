import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Persistent custom storage location (e.g. an external APFS SSD for large games).
/// Stored at the fixed anchor `~/Library/Application Support/<Brand.dataFolder>/storage.json`.
public struct StoragePreference: Codable, Sendable, Equatable {
    public var customRoot: String?

    public init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    public static var anchorDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(Brand.dataFolder)", isDirectory: true)
    }

    public static var preferenceFile: URL {
        anchorDirectory.appendingPathComponent("storage.json")
    }

    public static func load(from file: URL = preferenceFile) -> StoragePreference {
        guard let data = try? Data(contentsOf: file),
              let pref = try? JSONDecoder().decode(StoragePreference.self, from: data) else {
            return StoragePreference()
        }
        return pref
    }

    public static func save(_ pref: StoragePreference, to file: URL = preferenceFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(pref).write(to: file, options: .atomic)
    }
}

public struct StorageInfo: Sendable, Equatable {
    public var root: URL
    public var isCustom: Bool
    public var isExternal: Bool
    public var volumeName: String
    public var filesystem: String
    public var isAPFS: Bool
    public var freeBytes: Int64?

    public var freeSpaceLabel: String {
        guard let freeBytes else { return "Unknown free space" }
        return ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file) + " free"
    }

    public var warning: String? {
        guard !isAPFS else { return nil }
        return "\(volumeName) uses \(filesystem), not APFS. Instant Steam cloning and snapshots need APFS, and some games break on exFAT. Format external gaming SSDs as APFS for best results."
    }

    public static func inspect(_ root: URL, isCustom: Bool) -> StorageInfo {
        // Walk up to the nearest existing directory so statfs/resourceValues succeed even before first mkdir.
        var probe = root
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeNameKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let volumeName = values?.volumeName ?? "Macintosh HD"
        let isExternal = (values?.volumeIsInternal == false) || (values?.volumeIsRemovable == true)
        let free = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        let fs = filesystemName(at: probe.path)
        return StorageInfo(
            root: root,
            isCustom: isCustom,
            isExternal: isExternal,
            volumeName: volumeName,
            filesystem: fs,
            isAPFS: fs.lowercased() == "apfs",
            freeBytes: free
        )
    }

    static func filesystemName(at path: String) -> String {
        #if canImport(Darwin)
        var s = statfs()
        guard statfs(path, &s) == 0 else { return "unknown" }
        return withUnsafePointer(to: &s.f_fstypename) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0).uppercased()
            }
        }
        #else
        return "APFS"
        #endif
    }

    /// Validates and saves a custom GamePort data folder (e.g. `/Volumes/MySSD/GamePort`).
    @discardableResult
    public static func setCustomRoot(_ url: URL, preferenceFile: URL = StoragePreference.preferenceFile) throws -> StorageInfo {
        let resolved = url.standardizedFileURL
        guard resolved.isFileURL, resolved.path.hasPrefix("/"), resolved.path != "/" else {
            throw GamePortError.invalid("choose a valid folder path")
        }
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: resolved.path) else {
            throw GamePortError.invalid("folder is not writable: \(resolved.path)")
        }
        try StoragePreference.save(StoragePreference(customRoot: resolved.path), to: preferenceFile)
        return inspect(resolved, isCustom: true)
    }

    @discardableResult
    public static func resetToDefault(preferenceFile: URL = StoragePreference.preferenceFile) throws -> StorageInfo {
        try? FileManager.default.removeItem(at: preferenceFile)
        return inspect(StoragePreference.anchorDirectory, isCustom: false)
    }
}
