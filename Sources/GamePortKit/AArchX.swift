import Foundation

/// How an x86_64 Wine engine is translated on Apple Silicon.
public enum ExecutionRunner: String, Codable, Sendable, CaseIterable {
    /// Apple Rosetta 2 (default on macOS 14–27).
    case rosetta
    /// AArchX (`ocerz`, LGPL-2.1) experimental No-Rosetta x86-64 → arm64 JIT translator (macOS 26+).
    case aarchx
    /// AArchX running with its FEXCore backend (`ocerz -fex`, experimental).
    case aarchxFEX = "aarchx-fex"

    public var displayName: String {
        switch self {
        case .rosetta: return "Rosetta 2 (default)"
        case .aarchx: return "AArchX (experimental, no Rosetta)"
        case .aarchxFEX: return "AArchX + FEXCore (experimental)"
        }
    }
}

/// Manages the optional, SHA-256-verified AArchX (`ocerz`, LGPL-2.1-or-later) binary.
/// Downloaded on demand and always executed as a separate process.
public struct AArchXStore: Sendable {
    public struct Pin: Sendable, Equatable {
        public let version: String
        public let url: String
        public let sha256: String
        public let size: Int64
    }

    public static let pinned = Pin(
        version: "1.0.2",
        url: "https://github.com/mont127/AArchX/releases/download/v1.0.2/aarchx-macos-arm64.tar.gz",
        sha256: "765c147e7c06a356bb9bf14b9bc04441e9f1016b8f4966a0513cdd214364e371",
        size: 7_754_260
    )

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public var installDir: URL { paths.tools.appendingPathComponent("aarchx", isDirectory: true) }
    public var managedBinary: URL { installDir.appendingPathComponent("ocerz") }

    /// Prefers GamePort's SHA-256-verified copy; falls back to a user-installed `~/.aarchx/bin/ocerz`.
    public func binaryURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: managedBinary.path) { return managedBinary }
        let userBin = home.appendingPathComponent(".aarchx/bin/ocerz")
        if fm.isExecutableFile(atPath: userBin.path) { return userBin }
        return nil
    }

    public var isInstalled: Bool { binaryURL() != nil }

    public func versionString() -> String? {
        let versionFile = installDir.appendingPathComponent("VERSION")
        if let raw = try? String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        if isInstalled { return "installed" }
        return nil
    }

    /// Downloads, SHA-256 verifies, and atomically installs AArchX (`ocerz`) into `<root>/tools/aarchx`.
    @discardableResult
    public func install(pin: Pin = Self.pinned, progress: ProgressHandler? = nil) async throws -> URL {
        guard Shell.isAppleSilicon else { throw GamePortError.unsupported("AArchX requires Apple Silicon") }
        guard let url = URL(string: pin.url) else { throw GamePortError.invalid(pin.url) }
        try paths.ensure(paths.tools, paths.downloads, paths.temp)

        let downloader = Downloader(cache: paths.downloads)
        let archive = try await downloader.fetch(url, sha256: pin.sha256, size: pin.size, progress: progress)

        let staging = paths.temp.appendingPathComponent("aarchx-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try Archive.extract(archive, into: staging)
        let extractedRoot = staging.appendingPathComponent("aarchx", isDirectory: true)
        let ocerz = extractedRoot.appendingPathComponent("ocerz")
        guard fm.isExecutableFile(atPath: ocerz.path) else {
            throw GamePortError.missing("aarchx/ocerz inside archive")
        }
        try? fm.removeItem(at: installDir)
        try fm.moveItem(at: extractedRoot, to: installDir)
        progress?("Installed AArchX \(pin.version)")
        return managedBinary
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: installDir.path) {
            try FileManager.default.removeItem(at: installDir)
        }
    }

    /// Wraps an executable + arguments for `ExecutionRunner`.
    public func wrap(executable: String, arguments: [String], runner: ExecutionRunner,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> (executable: String, arguments: [String]) {
        switch runner {
        case .rosetta:
            return (executable, arguments)
        case .aarchx:
            guard let bin = binaryURL(home: home) else {
                throw GamePortError.missing("AArchX is not installed (install it in Setup or run `\(Brand.cliName) aarchx install`)")
            }
            return (bin.path, [executable] + arguments)
        case .aarchxFEX:
            guard let bin = binaryURL(home: home) else {
                throw GamePortError.missing("AArchX is not installed (install it in Setup or run `\(Brand.cliName) aarchx install`)")
            }
            return (bin.path, ["-fex", executable] + arguments)
        }
    }
}
