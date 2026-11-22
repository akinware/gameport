import Foundation

/// The Windows Steam client inside a profile. The player signs in in Steam's own window;
/// GamePort never sees or stores credentials.
public struct SteamClient: Sendable {
    public static let installerURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!
    public static let relativeExe = "Program Files (x86)/Steam/steam.exe"

    public let runner: WineRunner
    public init(runner: WineRunner) { self.runner = runner }

    public var exe: URL { runner.prefix.appendingPathComponent("drive_c/" + Self.relativeExe) }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: exe.path) }
    public var steamapps: URL { runner.prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps", isDirectory: true) }
    /// Steam's own logs; cef_log.txt is its web helper's (Chromium) log and keeps growing across launches.
    public var logs: URL { runner.prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/logs", isDirectory: true) }
    var windowsExe: String { WineRunner.windowsPath(cDriveRelative: Self.relativeExe) }

    /// Downloads Valve's installer over HTTPS and runs it silently. Valve changes the installer
    /// often, so it is not pinned; its SHA-256 is written to the profile log for the record.
    public func install(progress: ProgressHandler? = nil) async throws {
        let downloader = Downloader(cache: runner.paths.downloads)
        let setup = try await downloader.fetch(Self.installerURL, sha256: nil, progress: progress)
        progress?("SteamSetup.exe SHA-256: \(try Checksum.sha256(file: setup))")
        let target = runner.prefix.appendingPathComponent("drive_c/users/Public/SteamSetup.exe")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: setup, to: target)
        progress?("Installing Steam…")
        try runner.run(["C:\\users\\Public\\SteamSetup.exe", "/S"], sync: SyncMode.none)
        try runner.waitForServer()
        guard isInstalled else { throw GamePortError.missing("Steam after installing it") }
    }

    /// Opens Steam's window for sign-in, store and downloads. Steam's web UI hangs under
    /// msync/esync, so its own session always runs with sync off.
    public func openClient() throws -> Process {
        try runner.killAll()
        return try runner.spawn([windowsExe], sync: SyncMode.none, logName: "steam.log")
    }

    /// Starts the recipe's game. Games run with the recipe's sync mode (msync is much faster),
    /// so the prefix's server is restarted in that mode first.
    public func play() throws -> Process {
        guard let recipe = runner.recipe else { throw GamePortError.missing("a recipe for this profile") }
        try runner.killAll()
        switch recipe.launch {
        case .steam:
            guard let appID = recipe.steamAppID else { throw GamePortError.missing("\(recipe.id): steamAppID") }
            // If the game isn't downloaded inside this prefix yet, launch Steam visibly with sync off
            // so the login / install dialog appears instead of running invisibly under `-silent` + msync.
            if !isGameInstalled(appID: appID) {
                return try runner.spawn([windowsExe, "steam://install/\(appID)"], sync: SyncMode.none, logName: "steam.log")
            }
            return try runner.spawn([windowsExe, "-silent", "-applaunch", String(appID)] + recipe.launchArguments, logName: "game.log")
        case .direct:
            guard let appID = recipe.steamAppID, let exe = recipe.executable else { throw GamePortError.missing("\(recipe.id): executable") }
            _ = try runner.spawn([windowsExe, "-silent"], logName: "steam.log")
            Thread.sleep(forTimeInterval: 8) // let Steam's IPC come up before the game asks for it
            let path = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\" + exe.replacingOccurrences(of: "/", with: "\\")
            return try runner.spawn([path] + recipe.launchArguments,
                                    extra: ["SteamAppId": String(appID), "SteamGameId": String(appID)], logName: "game.log")
        case .battlenet:
            return try BattleNetClient(runner: runner).openClient(productCode: recipe.battleNetProduct)
        }
    }

    /// True when Steam reports the game fully installed (appmanifest StateFlags 4).
    public func isGameInstalled(appID: Int) -> Bool {
        let manifest = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return false }
        return text.range(of: #""StateFlags"\s+"4""#, options: .regularExpression) != nil
    }

    /// True when this prefix's Windows Steam (`steam.exe`) is running. Never starts anything: running
    /// `steam.exe -shutdown` to find out would start Steam when it is not running.
    ///
    /// A Wine process keeps files open in its wineserver's folder, `/tmp/.wine-<uid>/server-<dev>-<inode>`,
    /// named after the prefix folder, so a `steam.exe` with that folder open belongs to this prefix.
    public var isRunning: Bool {
        guard let server = Self.wineServerFolderName(prefix: runner.prefix) else { return false }
        let ps = (try? Shell.run("/bin/ps", ["-axo", "pid=,command="], check: false))?.output ?? ""
        let pids = ps.split(separator: "\n").compactMap { line -> String? in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[1].hasPrefix(#"C:\Program Files (x86)\Steam\steam.exe"#) else { return nil }
            return String(parts[0])
        }
        for pid in pids {
            let open = (try? Shell.run("/usr/sbin/lsof", ["-a", "-p", pid, "-Fn"], check: false))?.output ?? ""
            if open.contains("/\(server)/") { return true }
        }
        return false
    }

    /// `server-<st_dev>-<st_ino>` (hex), the wineserver folder Wine uses for `prefix`.
    static func wineServerFolderName(prefix: URL) -> String? {
        var st = stat()
        guard stat(prefix.path, &st) == 0 else { return nil }
        return "server-" + String(UInt64(st.st_dev), radix: 16) + "-" + String(UInt64(st.st_ino), radix: 16)
    }

    /// Asks Steam to quit and waits for the prefix to go quiet; after `seconds` everything is stopped.
    public func shutdown(within seconds: TimeInterval = 60) throws {
        _ = try? runner.run([windowsExe, "-shutdown"], sync: SyncMode.none, check: false)
        if try !runner.waitForServer(timeout: seconds) { try runner.killAll() }
    }
}
