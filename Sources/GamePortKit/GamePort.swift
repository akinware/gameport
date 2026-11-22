import Foundation

/// The operations the app and the CLI share. Everything a button does goes through here.
public struct GamePort: Sendable {
    public let paths: Paths
    public init(paths: Paths = .default()) { self.paths = paths }

    public var engines: EngineStore { EngineStore(paths: paths) }
    public var profiles: ProfileStore { ProfileStore(paths: paths) }
    public var licenses: LicenseStore { LicenseStore(paths: paths) }
    public var telemetry: TelemetryStore { TelemetryStore(paths: paths) }
    public var catalog: RecipeCatalog { RecipeCatalog.load(paths: paths) }

    /// The engine new profiles use: the first bundled manifest.
    public var defaultManifest: EngineManifest? { EngineStore.bundledManifests().first }

    public struct Check: Sendable {
        public var name: String
        public var ok: Bool
        public var detail: String
    }

    /// What must be true before anything can run.
    public func doctor() -> [Check] {
        var checks: [Check] = []
        #if os(macOS)
        let v = Shell.macOSVersion
        checks.append(Check(name: "macOS", ok: v.majorVersion >= 14, detail: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (14 or later required)"))
        checks.append(Check(name: "Apple Silicon", ok: Shell.isAppleSilicon, detail: Shell.isAppleSilicon ? "yes" : "Intel Macs are not supported"))
        let native = engines.installed().contains { engine in
            engine.manifest.arch == .fex && (try? engine.checkFiles()) != nil && (try? engine.checkHost()) != nil
        }
        if !native {
            let rosetta = Shell.rosettaInstalled
            checks.append(Check(name: "Rosetta 2", ok: rosetta, detail: rosetta ? "installed" : "needed for the x86_64 engine"))
        }
        #else
        checks.append(Check(name: "macOS", ok: false, detail: "\(Brand.displayName) runs games on macOS only"))
        #endif
        let installed = engines.installed()
        checks.append(Check(name: "Engine", ok: !installed.isEmpty, detail: installed.isEmpty ? "not installed: \(Brand.cliName) engine install" : installed.map(\.id).joined(separator: ", ")))
        return checks
    }

    public func installDefaultEngine(progress: ProgressHandler? = nil) async throws -> InstalledEngine {
        guard let manifest = defaultManifest else { throw GamePortError.missing("bundled engine manifest") }
        return try await engines.install(manifest, progress: progress)
    }

    /// Unified catalog of bundled engines + any installed custom/community engines.
    public func engineCatalog() -> [EngineCatalogEntry] {
        let bundled = EngineStore.bundledManifests()
        let bundledIDs = Set(bundled.map(\.id))
        let installed = Dictionary(uniqueKeysWithValues: engines.installed().map { ($0.id, $0) })
        let activeDefault = engines.defaultEngineID()
            ?? (defaultManifest.flatMap { installed[$0.id] != nil ? $0.id : nil })
            ?? installed.keys.sorted().first
        var usage: [String: Int] = [:]
        for p in profiles.all() { usage[p.engineID, default: 0] += 1 }

        var seen = Set<String>()
        var rows: [EngineCatalogEntry] = []
        for m in bundled {
            seen.insert(m.id)
            let inst = installed[m.id]
            rows.append(EngineCatalogEntry(
                manifest: inst?.manifest ?? m,
                isBundled: true,
                isInstalled: inst != nil,
                isDefault: inst != nil && m.id == activeDefault,
                kosmicKrispInstalled: inst?.kosmicKrispShim != nil,
                profilesUsingCount: usage[m.id] ?? 0
            ))
        }
        for id in installed.keys.sorted() where !seen.contains(id) {
            guard let inst = installed[id] else { continue }
            rows.append(EngineCatalogEntry(
                manifest: inst.manifest,
                isBundled: bundledIDs.contains(id),
                isInstalled: true,
                isDefault: id == activeDefault,
                kosmicKrispInstalled: inst.kosmicKrispShim != nil,
                profilesUsingCount: usage[id] ?? 0
            ))
        }
        return rows
    }

    /// Removes an installed engine only when no game profile still depends on it.
    public func removeEngine(_ id: String) throws {
        _ = try engines.engine(id)
        let using = profiles.all().filter { $0.engineID == id }.map(\.id)
        if !using.isEmpty {
            throw GamePortError.invalid("engine \(id) is still used by \(using.joined(separator: ", "))")
        }
        try engines.remove(id)
    }

    private func selectedEngine(_ id: String?) throws -> InstalledEngine {
        if let id { return try engines.engine(id) }
        let all = engines.installed()
        let preferredID = engines.defaultEngineID() ?? defaultManifest?.id
        let ordered = all.filter { $0.id == preferredID } + all.filter { $0.id != preferredID }
        guard let first = ordered.first else { throw GamePortError.missing("no engine installed") }
        return ordered.first { (try? $0.checkHost()) != nil && (try? $0.checkFiles()) != nil } ?? first
    }

    /// Creates an isolated environment for a recipe. With a Steam base for the engine the prefix is an
    /// APFS clone of it (seconds, Steam already updated); otherwise a fresh prefix is booted.
    @discardableResult
    public func createProfile(recipeID: String, profileID: String? = nil, engineID: String? = nil, progress: ProgressHandler? = nil) throws -> Profile {
        guard let recipe = catalog[recipeID] else { throw GamePortError.missing("recipe \(recipeID)") }
        let engine = try selectedEngine(engineID)
        try engine.checkHost()
        try engine.checkFiles()
        let id = profileID ?? recipe.id
        try validateID(id, what: "profile id")
        try paths.ensure(paths.profiles)
        // Reserve the ID before booting. Never initialize an existing or partially prepared prefix.
        let directory = profiles.directory(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var profile = Profile(id: id, title: recipe.title, recipeID: recipe.id, engineID: engine.id)
        if engine.manifest.arch == .fex && recipe.renderer == .d3dmetal {
            profile.renderer = engine.rendererDirectory("dxmt") == nil ? .wined3d : .dxmt
        }
        // The prefix itself does not need a licence-gated renderer: set it up with wined3d, keep the choice.
        var setupProfile = profile
        if let license = (profile.renderer ?? recipe.renderer).gatingLicense(in: engine.manifest), !licenses.isAccepted(license) {
            progress?("Note: the game cannot start until the \(license) licence is accepted.")
            setupProfile.renderer = .wined3d
        }
        let runner = WineRunner(paths: paths, engine: engine, profile: setupProfile, recipe: recipe)
        let base = SteamBase(paths: paths, engine: engine)
        do {
            if base.isReady {
                progress?("Cloning the Steam base…")
                try base.clone(to: runner.prefix)
                try runner.settle()
            } else {
                progress?("Preparing the Windows environment (1-2 minutes the first time)…")
                try runner.boot()
            }
            try profiles.save(profile)
        } catch {
            try? runner.killAll()
            if (try? runner.waitForServer(timeout: 5)) == true { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
        return profile
    }

    public func steamBase(engineID: String? = nil) throws -> SteamBase {
        let engine = try selectedEngine(engineID)
        return SteamBase(paths: paths, engine: engine)
    }

    /// Stops the profile (so Wine has flushed its registry) and snapshots its prefix.
    @discardableResult
    public func snapshot(_ profileID: String, name: String? = nil) throws -> Snapshot {
        try runner(for: profileID).killAll()
        try runner(for: profileID).waitForServer()
        return try profiles.createSnapshot(profileID, name: name)
    }

    /// Steam updates itself and its games whenever it starts, so once a day, before it does, the profile
    /// gets an automatic snapshot (the newest two are kept). Returns nil when none was due or it failed:
    /// a missing snapshot must never stop the player from starting Steam.
    @discardableResult
    public func autoSnapshot(_ profileID: String, now: Date = Date()) -> Snapshot? {
        guard let profile = try? profiles.load(profileID), profile.autoSnapshots ?? true,
              FileManager.default.fileExists(atPath: profiles.prefix(profileID).path),
              profiles.autoSnapshotDue(profileID, now: now) else { return nil }
        let snapshot = try? snapshot(profileID, name: ProfileStore.autoPrefix + ProfileStore.snapshotName(now))
        try? profiles.pruneAutoSnapshots(profileID, keep: 2)
        return snapshot
    }

    public func openSteam(_ profileID: String, progress: ProgressHandler? = nil) throws -> Process {
        if let s = autoSnapshot(profileID) { progress?("Automatic snapshot: \(s.name)") }
        let process = try steam(for: profileID).openClient()
        recordLaunch(requested: profileID, actual: profileID)
        return process
    }

    public func play(_ profileID: String, progress: ProgressHandler? = nil) throws -> Process {
        let baseRunner = try playbackRunner(profileID, progress: progress)
        let actual = baseRunner.profile.id
        var launchProfile = baseRunner.profile
        var fpsLog: URL? = nil
        if telemetry.isEffectivelyEnabled(), telemetry.endpoint() != nil,
           let probe = telemetry.fpsProbeLibrary(for: baseRunner.engine.manifest.arch) {
            try? paths.ensure(baseRunner.logs)
            let log = baseRunner.logs.appendingPathComponent("play-fps.log")
            try? FileManager.default.removeItem(at: log)
            let existing = launchProfile.environment["DYLD_INSERT_LIBRARIES"] ?? ""
            launchProfile.environment["DYLD_INSERT_LIBRARIES"] = existing.isEmpty ? probe.path : "\(probe.path):\(existing)"
            launchProfile.environment["GAMEPORT_FPS_LOG"] = log.path
            fpsLog = log
        }
        let runner = WineRunner(paths: paths, engine: baseRunner.engine, profile: launchProfile, recipe: baseRunner.recipe)
        let steam = SteamClient(runner: runner)
        if let id = runner.recipe?.steamAppID, !steam.isGameInstalled(appID: id) {
            progress?("Steam does not yet report the game as installed (appmanifest_\(id)). Trying anyway.")
        }
        if let s = autoSnapshot(actual) { progress?("Automatic snapshot: \(s.name)") }
        func fileSize(_ file: URL) -> UInt64 { (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? 0 }
        let cefOffset = fileSize(steam.logs.appendingPathComponent("cef_log.txt"))
        let bootstrapOffset = fileSize(steam.logs.appendingPathComponent("bootstrap_log.txt"))
        progress?("Launching \(actual) on \(runner.engine.id) (\(runner.engine.manifest.arch.label)). Log: \(runner.logs.appendingPathComponent("game.log").path)")
        let process = try steam.play()
        recordLaunch(requested: profileID, actual: actual)
        if let appID = runner.recipe?.steamAppID {
            telemetry.monitorPlaySession(runner: runner, steamAppID: appID, cefLogOffset: cefOffset, bootstrapLogOffset: bootstrapOffset, fpsLog: fpsLog)
        }
        return process
    }

    private func recordLaunch(requested: String, actual: String) {
        let marker = profiles.directory(requested).appendingPathComponent("last-play-profile")
        try? Data(actual.utf8).write(to: marker, options: .atomic)
    }

    public func stop(_ id: String) throws {
        let profile = try profiles.load(id)
        let marker = profiles.directory(id).appendingPathComponent("last-play-profile")
        if let last = try? String(contentsOf: marker, encoding: .utf8), last != id,
           let other = try? enginePair(profile, otherID: last) {
            try runner(for: other).killAll()
        } else {
            try runner(for: profile).killAll()
        }
        try? FileManager.default.removeItem(at: marker)
    }

    func enginePair(_ profile: Profile, otherID: String) throws -> Profile {
        let other = try profiles.load(otherID)
        guard let recipe = profile.recipeID, recipe == other.recipeID, profile.engineID != other.engineID else {
            throw GamePortError.invalid("choose a profile for the same game on a different engine")
        }
        return other
    }

    public func setFallback(_ id: String, to otherID: String?) throws {
        var profile = try profiles.load(id)
        if let otherID { _ = try enginePair(profile, otherID: otherID) }
        profile.fallbackProfileID = otherID
        try profiles.save(profile)
    }

    /// Fall back only during engine preflight. Once Steam has been launched it must never be launched twice.
    func playbackRunner(_ id: String, progress: ProgressHandler? = nil,
                        checkHost: (InstalledEngine) throws -> Void = { try $0.checkHost() }) throws -> WineRunner {
        let profile = try profiles.load(id)
        func available(_ candidate: Profile) throws -> WineRunner {
            let runner = try self.runner(for: candidate)
            try checkHost(runner.engine)
            try runner.engine.checkFiles()
            _ = try runner.environment()
            return runner
        }
        do { return try available(profile) }
        catch GamePortError.licenseNotAccepted(let licence) { throw GamePortError.licenseNotAccepted(licence) }
        catch {
            guard let otherID = profile.fallbackProfileID else { throw error }
            let primaryError = error
            do {
                let runner = try available(enginePair(profile, otherID: otherID))
                let steam = SteamClient(runner: runner)
                guard let appID = runner.recipe?.steamAppID, steam.isInstalled, steam.isGameInstalled(appID: appID) else {
                    throw GamePortError.missing("install the game in fallback profile \(otherID)")
                }
                progress?("Using fallback \(otherID): \(primaryError)")
                return runner
            } catch {
                throw GamePortError.unsupported("\(id): \(primaryError). Fallback \(otherID): \(error)")
            }
        }
    }

    /// Stops the profile and rolls its prefix (and engine choice) back to a snapshot.
    @discardableResult
    public func restore(_ profileID: String, snapshot name: String) throws -> Snapshot {
        if let snapshot = profiles.listSnapshots(profileID).first(where: { $0.name == name }) {
            _ = try engines.engine(snapshot.engineID) // the engine it was taken with must still be installed
        }
        try runner(for: profileID).killAll()
        try runner(for: profileID).waitForServer()
        return try profiles.restoreSnapshot(profileID, name: name)
    }

    public func runner(for profileID: String) throws -> WineRunner {
        try runner(for: profiles.load(profileID))
    }

    func runner(for profile: Profile) throws -> WineRunner {
        let engine = try engines.engine(profile.engineID)
        let recipe = profile.recipeID.flatMap { catalog[$0] }
        return WineRunner(paths: paths, engine: engine, profile: profile, recipe: recipe)
    }

    public func steam(for profileID: String) throws -> SteamClient {
        SteamClient(runner: try runner(for: profileID))
    }
}
