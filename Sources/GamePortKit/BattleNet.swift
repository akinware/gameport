import Foundation

/// The Windows Battle.net client inside an isolated profile.
/// Downloads Blizzard's official Battle.net-Setup.exe directly from Blizzard over HTTPS
/// (never bundled or mirrored) and runs it in its own prefix — ideal for Overwatch 2,
/// Diablo IV, Diablo II: Resurrected, and Diablo III.
public struct BattleNetClient: Sendable {
    public static let installerURL = URL(string: "https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe")!
    public static let relativeLauncherExes = [
        "Program Files (x86)/Battle.net/Battle.net Launcher.exe",
        "Program Files (x86)/Battle.net/Battle.net.exe",
    ]

    public let runner: WineRunner
    public init(runner: WineRunner) { self.runner = runner }

    public var launcherExe: URL? {
        for rel in Self.relativeLauncherExes {
            let candidate = runner.prefix.appendingPathComponent("drive_c/" + rel)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public var isInstalled: Bool { launcherExe != nil }

    var windowsLauncherExe: String {
        for rel in Self.relativeLauncherExes {
            let candidate = runner.prefix.appendingPathComponent("drive_c/" + rel)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return WineRunner.windowsPath(cDriveRelative: rel)
            }
        }
        return WineRunner.windowsPath(cDriveRelative: Self.relativeLauncherExes[0])
    }

    /// Downloads Blizzard's official Battle.net-Setup.exe over HTTPS and launches the installer
    /// inside this profile's isolated Wine prefix.
    public func install(progress: ProgressHandler? = nil) async throws -> Process {
        let downloader = Downloader(cache: runner.paths.downloads)
        let setup = try await downloader.fetch(Self.installerURL, sha256: nil, progress: progress)
        let header = (try? Data(contentsOf: setup, options: .mappedIfSafe).prefix(2)) ?? Data()
        guard header == Data([0x4D, 0x5A]) else {
            throw GamePortError.invalid("Battle.net-Setup.exe is not a valid Windows installer (missing MZ header)")
        }
        progress?("Battle.net-Setup.exe SHA-256: \(try Checksum.sha256(file: setup))")
        let target = runner.prefix.appendingPathComponent("drive_c/users/Public/Battle.net-Setup.exe")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: setup, to: target)
        progress?("Launching Battle.net installer (sign in and install your game inside the Battle.net window)…")
        try runner.killAll()
        return try runner.spawn(
            ["C:\\users\\Public\\Battle.net-Setup.exe"],
            sync: SyncMode.none,
            extra: ["WINE_SIMULATE_WRITECOPY": "1"],
            logName: "battlenet-install.log"
        )
    }

    /// Opens Battle.net (and optionally requests launching a specific Blizzard product code such as
    /// `"Pro"` for Overwatch 2, `"Fen"` for Diablo IV, `"OSI"` for Diablo II: Resurrected, or `"D3"` for Diablo III).
    public func openClient(productCode: String? = nil) throws -> Process {
        guard isInstalled else {
            throw GamePortError.missing("Battle.net is not installed in this profile yet")
        }
        try runner.killAll()
        var args = [windowsLauncherExe]
        if let code = productCode, !code.isEmpty {
            args.append("--exec=launch \(code)")
        }
        return try runner.spawn(
            args,
            extra: ["WINE_SIMULATE_WRITECOPY": "1"],
            logName: "game.log"
        )
    }
}
