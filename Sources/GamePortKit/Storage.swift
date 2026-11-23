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

    /// The saved custom folder when its drive is not connected (GamePort uses the internal folder meanwhile).
    public static func offlineRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   preferenceFile: URL = preferenceFile) -> URL? {
        if let home = environment[Brand.homeEnvironmentVariable], !home.isEmpty { return nil }
        guard let saved = load(from: preferenceFile).customRoot, !saved.isEmpty else { return nil }
        let url = URL(fileURLWithPath: saved, isDirectory: true)
        return isReachable(url) ? nil : url
    }

    /// The folder can be used now: a folder on the startup disk always (it is created when needed), one
    /// on a drive under `/Volumes` only while that drive is connected.
    public static func isReachable(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path != "/Volumes" else { return false }
        return isOnMountedVolume(url)
    }

    /// A path under `/Volumes/<name>` must be on that drive, not on a leftover folder of the same name
    /// that macOS or an app left on the startup disk while the drive was away. Other paths are internal.
    static func isOnMountedVolume(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[1] == "Volumes" else { return true }
        #if canImport(Darwin)
        var volume = stat(), volumes = stat()
        guard stat("/Volumes/\(parts[2])", &volume) == 0, stat("/Volumes", &volumes) == 0 else { return false }
        return volume.st_dev != volumes.st_dev
        #else
        return true
        #endif
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
        return "\(volumeName) uses \(filesystem), not APFS. Games still run, but every new game copies Windows Steam in full instead of in seconds, and automatic snapshots are off. Format the drive as APFS to get both."
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
        var resolved = url.standardizedFileURL
        guard resolved.isFileURL, resolved.path.hasPrefix("/"), resolved.path != "/", resolved.path != "/Volumes" else {
            throw GamePortError.invalid("choose a valid folder path")
        }
        // A whole drive was chosen: keep GamePort in its own folder on it.
        if resolved.pathComponents.count == 3, resolved.pathComponents[1] == "Volumes" {
            resolved = resolved.appendingPathComponent(Brand.dataFolder, isDirectory: true)
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
