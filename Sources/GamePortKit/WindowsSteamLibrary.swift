import Foundation

extension GamePort {
    /// Moves a profile to another installed engine (for example from GamePort's own CrossOver-based
    /// Wine to the user's CrossOver.app). Stops the profile's Wine first and takes a snapshot, so
    /// restoring it brings the old engine back. Returns the updated profile.
    @discardableResult
    public func switchEngine(_ profileID: String, to engineID: String, progress: ProgressHandler? = nil) throws -> Profile {
        var profile = try profiles.load(profileID)
        guard profile.engineID != engineID else { return profile }
        let target = try engines.engine(engineID)
        if let r = try? runner(for: profileID) { try? r.killAll() }
        if let snap = try? profiles.createSnapshot(profileID, name: nil) {
            progress?("Snapshot before switching engines: \(snap.name)")
        }
        profile.engineID = target.id
        try profiles.save(profile)
        progress?("\(profile.title) now runs on \(target.manifest.displayName)")
        return profile
    }

    /// The folder name under Windows Steam's `steamapps/common` for a game: the first component of the
    /// recipe's `executable` (which is relative to `steamapps/common`), else the title without characters
    /// Windows does not allow in file names.
    public static func windowsSteamInstallFolder(recipe: Recipe?, title: String) -> String {
        if let first = recipe?.executable?.split(separator: "/").first, !first.isEmpty { return String(first) }
        let banned = Set("<>:\"/\\|?*")
        let cleaned = String(title.filter { !banned.contains($0) }).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Game" : cleaned
    }

    /// Puts a game downloaded without Windows Steam (`tools/depots/<appID>`) into the profile's Windows
    /// Steam library, so it can be played through Windows Steam too:
    /// - the download is APFS-cloned to `steamapps/common/<folder>` (seconds, no extra disk space; the
    ///   Bridge keeps using its own copy);
    /// - an `appmanifest_<appID>.acf` tells Windows Steam the game is installed. Steam checks the files
    ///   once at the next start and downloads only what differs.
    ///
    /// Returns the game's folder in the Windows Steam library.
    @discardableResult
    public func addDepotToWindowsSteam(_ profileID: String, progress: ProgressHandler? = nil) throws -> URL {
        let r = try runner(for: profileID)
        guard let appID = r.recipe?.steamAppID else {
            throw GamePortError.invalid("profile \(profileID) has no Steam AppID recipe")
        }
        let steam = try steam(for: profileID)
        guard steam.isInstalled else {
            throw GamePortError.missing("Windows Steam is not installed in this game's profile yet. Install it first.")
        }
        let title = r.recipe?.title ?? profileID
        let folder = Self.windowsSteamInstallFolder(recipe: r.recipe, title: title)
        let target = steam.steamapps.appendingPathComponent("common/\(folder)", isDirectory: true)
        if steam.isGameInstalled(appID: appID) { return target }

        let depot = paths.tools.appendingPathComponent("depots/\(appID)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: depot.path), SteamDepotManager.isDownloadComplete(appID: appID, in: depot) else {
            throw GamePortError.missing("\(title) has not finished downloading yet.")
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw GamePortError.invalid("Windows Steam already has a folder for \(title): \(target.path). Remove it or let Steam finish installing.")
        }

        // Windows Steam must not be running while its library changes under it.
        if let up = try? r.waitForServer(timeout: 1), !up {
            progress?("Closing Windows Steam…")
            try? steam.shutdown(within: 30)
        }
        progress?("Adding \(title) to Windows Steam (APFS clone, no extra disk space)…")
        try CopyOnWrite.clone(depot, to: target, allowCopy: false)
        // The download's own bookkeeping is not part of the game.
        for extra in [".DepotDownloader", "steamapps"] {
            try? FileManager.default.removeItem(at: target.appendingPathComponent(extra))
        }
        try SteamDepotManager.writeAppManifest(appID: appID, name: title, installDirName: folder, into: steam.steamapps)
        progress?("\(title) is in Windows Steam's library. Steam checks its files once at the next start.")
        return target
    }
}
