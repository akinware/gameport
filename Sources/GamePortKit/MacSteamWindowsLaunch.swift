import Foundation

/// Starting a Windows game that Mac Steam itself installed (`ExternalEnvironment.macSteamWindowsGame`).
///
/// Mac Steam only installs the Windows version of a game when Steam Play was turned on for it, by
/// NotProton or a similar tool. Asking Mac Steam to start it (`steam://rungameid/<AppID>`) lets that
/// tool run it, exactly as pressing Play inside Steam. GamePort does not run, copy or change that
/// tool; it only watches for the game's process, so it can say when the game is running and offer the
/// Steam Bridge (on the same files) when it never comes up.
public enum MacSteamWindowsLaunch {
    /// After this long without the game, Play switches to another way (the Bridge).
    public static let patience: TimeInterval = 90
    /// The game is still noticed this long after Play, in case Steam was slow (an update, a first-run setup).
    public static let watchLimit: TimeInterval = 300

    public static func launchURL(appID: Int) -> URL? {
        appID > 0 ? URL(string: "steam://rungameid/\(appID)") : nil
    }

    /// Lowercased pieces of a command line that only the game's own processes have: its program's
    /// file name, and its folder under `steamapps/common` written the Mac or the Windows way.
    public static func markers(installDir: String, executable: URL?) -> [String] {
        var markers: [String] = []
        if let name = executable?.lastPathComponent.lowercased(), name.hasSuffix(".exe") { markers.append(name) }
        let dir = installDir.lowercased()
        if !dir.isEmpty {
            markers.append("steamapps/common/\(dir)/")
            markers.append("steamapps\\common\\\(dir)\\")
        }
        return markers
    }

    /// True when a line of `ps -axww -o pid=,command=` output belongs to the game.
    public static func isRunning(inProcessList ps: String, markers: [String]) -> Bool {
        guard !markers.isEmpty else { return false }
        return ps.split(whereSeparator: \.isNewline).contains { line in
            let command = line.lowercased()
            return markers.contains { command.contains($0) }
        }
    }

    /// Reads the process list now.
    public static func isRunning(markers: [String]) -> Bool {
        let ps = (try? Shell.run("/bin/ps", ["-axww", "-o", "pid=,command="], check: false).output) ?? ""
        return isRunning(inProcessList: ps, markers: markers)
    }
}
