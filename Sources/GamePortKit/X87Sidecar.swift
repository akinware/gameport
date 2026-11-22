import Foundation

/// Manages the optional, SHA-256-verified `x87sidecar` (MIT, athei/x87sidecar) Rosetta x87 JIT accelerator.
/// When enabled on a profile, sets `ROSETTA_X87_PATH` so cooperative Wine engines automatically attach
/// `x87sidecar --cooperative` to 32-bit Windows game processes (large speedups in classic DX9/x87 games).
public struct X87SidecarStore: Sendable {
    public struct Pin: Sendable, Equatable {
        public let version: String
        public let url: String
        public let sha256: String
        public let size: Int64
    }

    public static let pinned = Pin(
        version: "1.9.1",
        url: "https://github.com/athei/x87sidecar/releases/download/v1.9.1/x87sidecar.tar.xz",
        sha256: "e18d1c2443f1440ae5a8e137dd0c85ec33e53506b67604675826094122106615",
        size: 182_240
    )

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public var installDir: URL { paths.tools.appendingPathComponent("x87sidecar", isDirectory: true) }
    public var binaryURL: URL { installDir.appendingPathComponent("x87sidecar") }
    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binaryURL.path) }

    public func versionString() -> String? {
        guard isInstalled else { return nil }
        let vf = installDir.appendingPathComponent("VERSION")
        if let raw = try? String(contentsOf: vf, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        return Self.pinned.version
    }

    /// Runs `x87sidecar --probe` to check whether this Mac's Rosetta runtime is supported.
    public func probe() -> (ok: Bool, detail: String) {
        guard isInstalled else { return (false, "x87sidecar is not installed") }
        guard let res = try? Shell.run(binaryURL.path, ["--probe"], check: false) else {
            return (false, "could not run x87sidecar --probe")
        }
        let detail = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (res.status == 0, detail.isEmpty ? (res.status == 0 ? "supported" : "exit \(res.status)") : detail)
    }

    @discardableResult
    public func install(pin: Pin = Self.pinned, progress: ProgressHandler? = nil) async throws -> URL {
        guard Shell.isAppleSilicon else { throw GamePortError.unsupported("x87sidecar requires Apple Silicon") }
        guard let url = URL(string: pin.url) else { throw GamePortError.invalid(pin.url) }
        try paths.ensure(paths.tools, paths.downloads, paths.temp)

        let downloader = Downloader(cache: paths.downloads)
        let archive = try await downloader.fetch(url, sha256: pin.sha256, size: pin.size, progress: progress)

        let staging = paths.temp.appendingPathComponent("x87sidecar-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try Archive.extract(archive, into: staging)
        let extracted = staging.appendingPathComponent("x87sidecar")
        guard fm.fileExists(atPath: extracted.path) else {
            throw GamePortError.missing("x87sidecar binary inside archive")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extracted.path)
        _ = try? Shell.run("/usr/bin/xattr", ["-d", "com.apple.quarantine", extracted.path], check: false)

        try? fm.removeItem(at: installDir)
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
        try fm.moveItem(at: extracted, to: binaryURL)
        try (pin.version + "\n").write(to: installDir.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        let check = probe()
        progress?("Installed x87sidecar \(pin.version) (probe: \(check.ok ? "supported" : check.detail))")
        return binaryURL
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: installDir.path) {
            try FileManager.default.removeItem(at: installDir)
        }
    }
}
