import Foundation

/// Where GamePort keeps everything. One folder; deleting it is a full uninstall.
///
/// Layout:
///   <root>/engines/<engine id>/        installed engines (Wine + frameworks + renderers)
///   <root>/downloads/                  verified download cache (by SHA-256)
///   <root>/profiles/<profile id>/      one isolated Windows environment per game
///   <root>/profiles/<id>/snapshots/    copy-on-write snapshots of that profile's prefix
///   <root>/bases/<engine id>/          Steam base prefix new profiles are cloned from
///   <root>/licenses/<license id>       acceptance receipts (e.g. Apple's GPTK licence)
///   <root>/db/                         game recipes (bundled + imported)
public struct Paths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `GAMEPORT_HOME` wins (tests, isolated QA). Next is a saved External SSD / custom folder in
    /// `storage.json` (when mounted). Otherwise `~/Library/Application Support/<Brand.dataFolder>`.
    public static func `default`(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 preferenceFile: URL = StoragePreference.preferenceFile) -> Paths {
        if let custom = environment[Brand.homeEnvironmentVariable], !custom.isEmpty {
            return Paths(root: URL(fileURLWithPath: custom, isDirectory: true))
        }
        if let saved = StoragePreference.load(from: preferenceFile).customRoot, !saved.isEmpty {
            let url = URL(fileURLWithPath: saved, isDirectory: true)
            // Only while its drive is connected; otherwise the internal folder (see `StoragePreference.offlineRoot`).
            if StoragePreference.isReachable(url) { return Paths(root: url) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(root: home.appendingPathComponent("Library/Application Support/\(Brand.dataFolder)", isDirectory: true))
    }

    public var engines: URL { root.appendingPathComponent("engines", isDirectory: true) }
    public var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    public var profiles: URL { root.appendingPathComponent("profiles", isDirectory: true) }
    public var bases: URL { root.appendingPathComponent("bases", isDirectory: true) }
    public var licenses: URL { root.appendingPathComponent("licenses", isDirectory: true) }
    public var db: URL { root.appendingPathComponent("db", isDirectory: true) }
    public var tools: URL { root.appendingPathComponent("tools", isDirectory: true) }
    public var temp: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    public func engine(_ id: String) -> URL { engines.appendingPathComponent(id, isDirectory: true) }
    public func profile(_ id: String) -> URL { profiles.appendingPathComponent(id, isDirectory: true) }
    public func base(_ engineID: String) -> URL { bases.appendingPathComponent(engineID, isDirectory: true) }

    public func ensure(_ dirs: URL...) throws {
        for dir in dirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

public enum GamePortError: Error, CustomStringConvertible, Equatable {
    case invalid(String)
    case missing(String)
    case checksum(file: String, expected: String, actual: String)
    case process(String, Int32)
    case licenseNotAccepted(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .invalid(let s): return "Invalid: \(s)"
        case .missing(let s): return "Not found: \(s)"
        case .checksum(let f, let e, let a): return "SHA-256 mismatch: \(f)\n  expected \(e)\n  found    \(a)"
        case .process(let s, let code): return "\(s) failed (exit code \(code))"
        case .licenseNotAccepted(let id): return "Licence not accepted: \(id). Run `\(Brand.cliName) license accept \(id)` first."
        case .unsupported(let s): return "Not supported: \(s)"
        }
    }
}

/// Validates ids that become folder names: letters, digits, dot, dash, underscore.
public func validateID(_ id: String, what: String) throws {
    let ok = !id.isEmpty && id.count <= 80 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    guard ok, id != ".", id != ".." else { throw GamePortError.invalid("\(what) '\(id)' (use only letters, digits, - _ .)") }
}
