import Foundation

extension GamePort {
    /// The profile that plays a CrossOver bottle's game with GamePort's own Wine.
    public static func bottleProfileID(_ item: CrossOverBottleLaunchItem) -> String {
        let slug = item.bottleName.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let bottle = String(slug).split(separator: "-").joined(separator: "-")
        switch item.kind {
        case .steam(let appID): return "cx-\(bottle.isEmpty ? "bottle" : bottle)-\(appID)"
        case .battleNet: return "cx-\(bottle)-battlenet"
        case .epicLauncher: return "cx-\(bottle)-epic"
        case .gogGalaxy: return "cx-\(bottle)-gog"
        }
    }

    /// The profile already made for this bottle game, if any.
    public func bottleProfile(for item: CrossOverBottleLaunchItem) -> Profile? {
        try? profiles.load(Self.bottleProfileID(item))
    }

    /// Lets a game installed in a CrossOver bottle run on GamePort's own Wine, for example after the
    /// CrossOver trial ends. The bottle itself is never changed: it is APFS-cloned into a new GamePort
    /// profile (seconds, no extra disk space until files change), which then behaves like any other
    /// profile: its Windows Steam is the bottle's Steam, signed in and with the bottle's games.
    ///
    /// Only Steam games are supported. Returns the new (or existing) profile.
    @discardableResult
    public func adoptCrossOverBottleGame(_ item: CrossOverBottleLaunchItem, engineID: String? = nil,
                                         progress: ProgressHandler? = nil) throws -> Profile {
        guard case .steam(let appID) = item.kind else {
            throw GamePortError.invalid("Only Steam games in CrossOver bottles can move to GamePort's Wine for now.")
        }
        if let existing = bottleProfile(for: item) { return existing }
        let fm = FileManager.default
        guard fm.fileExists(atPath: item.bottlePath.appendingPathComponent("drive_c").path) else {
            throw GamePortError.missing("CrossOver bottle \(item.bottleName) at \(item.bottlePath.path)")
        }
        let recipe = try catalog.recipe(steamAppID: appID) ?? addCustomSteamGame(appID: appID, title: item.title)
        let engine = try bottleEngine(engineID)
        try engine.checkHost()
        try engine.checkFiles()

        let id = Self.bottleProfileID(item)
        try validateID(id, what: "profile id")
        try paths.ensure(paths.profiles)
        let directory = profiles.directory(id)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        let profile = Profile(id: id, title: recipe.title, recipeID: recipe.id, engineID: engine.id)
        let runner = WineRunner(paths: paths, engine: engine, profile: profile, recipe: recipe)
        do {
            progress?("Copying the bottle \u{201C}\(item.bottleName)\u{201D} (APFS clone, no extra disk space; the bottle stays as it is)…")
            try CopyOnWrite.clone(item.bottlePath, to: runner.prefix, allowCopy: false)
            progress?("Preparing it for \(engine.manifest.displayName)…")
            try runner.settle()
            try profiles.save(profile)
        } catch {
            try? runner.killAll()
            _ = try? runner.waitForServer(timeout: 5)
            try? fm.removeItem(at: directory)
            throw error
        }
        progress?("\(recipe.title) now also runs with GamePort's Wine. The CrossOver bottle is unchanged.")
        return profile
    }

    /// GamePort's own engine when one is installed (the point is not needing CrossOver), else any.
    private func bottleEngine(_ id: String?) throws -> InstalledEngine {
        if let id { return try engines.engine(id) }
        let own = engines.installed().filter { $0.id != CrossOverInstallation.engineID }
        let preferred = engines.defaultEngineID()
        if let engine = own.first(where: { $0.id == preferred }) ?? own.first { return engine }
        guard let any = engines.installed().first else { throw GamePortError.missing("no engine installed") }
        return any
    }
}
