import Foundation

/// Builds the exact environment for a profile and runs Wine in it.
public struct WineRunner: Sendable {
    public let paths: Paths
    public let engine: InstalledEngine
    public let profile: Profile
    public let recipe: Recipe?
    /// Holds prefix/, home/ and logs/: the profile's folder, or the Steam base's.
    public let directory: URL

    public init(paths: Paths, engine: InstalledEngine, profile: Profile, recipe: Recipe?, directory: URL? = nil) {
        self.paths = paths; self.engine = engine; self.profile = profile; self.recipe = recipe
        self.directory = directory ?? paths.profile(profile.id)
    }

    public var prefix: URL { directory.appendingPathComponent("prefix", isDirectory: true) }
    /// Private HOME / caches so Wine and Steam never write into the user's real home folders.
    public var home: URL { directory.appendingPathComponent("home", isDirectory: true) }
    public var logs: URL { directory.appendingPathComponent("logs", isDirectory: true) }
    public var effectiveRenderer: Renderer { profile.renderer ?? recipe?.renderer ?? .dxmt }
    public var effectiveSync: SyncMode { profile.sync ?? recipe?.sync ?? .msync }
    public var effectiveVulkanDriver: VulkanDriver { profile.vulkanDriver ?? .moltenvk }

    /// Layers, later wins: engine base → isolation → sync → renderer → recipe → player.
    public func environment(sync overrideSync: SyncMode? = nil, extra: [String: String] = [:]) throws -> [String: String] {
        let renderer = effectiveRenderer
        if let license = renderer.gatingLicense(in: engine.manifest), !LicenseStore(paths: paths).isAccepted(license) {
            throw GamePortError.licenseNotAccepted(license)
        }
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "USER": ProcessInfo.processInfo.environment["USER"] ?? NSUserName(),
            "HOME": home.path,
            "TMPDIR": home.appendingPathComponent("tmp").path,
            "XDG_CACHE_HOME": home.appendingPathComponent("cache").path,
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": "fixme-all",
            // Never let Wine scatter .desktop/menu entries into the user's system.
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
            "CX_FWD_COMPAT_GL_CTX": "1",
            "MVK_CONFIG_LOG_LEVEL": "2",
        ]
        if let tz = ProcessInfo.processInfo.environment["TZ"] { env["TZ"] = tz }
        env = mergeEnvironment(env, engine.baseEnvironment())
        env = mergeEnvironment(env, (overrideSync ?? effectiveSync).environment)
        env = mergeEnvironment(env, try renderer.environment(engine: engine))
        if let recipe {
            env = mergeEnvironment(env, recipe.environment)
            if let o = recipe.dllOverrides { env = mergeEnvironment(env, ["WINEDLLOVERRIDES": o]) }
        }
        if (profile.advertiseAVX ?? recipe?.advertiseAVX ?? false), engine.manifest.requiresRosetta {
            env["ROSETTA_ADVERTISE_AVX"] = "1"
        }
        if profile.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if effectiveVulkanDriver == .kosmickrisp {
            guard let shim = engine.kosmicKrispShim else {
                throw GamePortError.missing("KosmicKrisp in \(engine.id) (run \(Brand.cliName) engine kosmickrisp \(engine.id))")
            }
            // CrossOver's win32u loads the Vulkan library CX_LIBVULKAN names, but only while the backend is
            // "wined3d"; nothing else in the engine reads CX_ACTIVE_GRAPHICS_BACKEND. The shim then sends only
            // the game's own .exe to KosmicKrisp.
            env["CX_LIBVULKAN"] = shim.path
            env["CX_ACTIVE_GRAPHICS_BACKEND"] = "wined3d"
        }
        env = mergeEnvironment(env, profile.environment)
        env = mergeEnvironment(env, extra)
        if engine.manifest.arch == .fex { env.removeValue(forKey: "ROSETTA_ADVERTISE_AVX") }
        return env
    }

    /// Runs a Wine command to completion (wineboot, reg, installers).
    @discardableResult
    public func run(_ arguments: [String], sync: SyncMode? = nil, extra: [String: String] = [:], check: Bool = true) throws -> Shell.Result {
        try prepareDirectories()
        return try Shell.run(engine.wine.path, arguments, environment: try environment(sync: sync, extra: extra), check: check)
    }

    /// Runs a Wine command to completion with its output streamed live to the terminal (`gameport run`).
    @discardableResult
    public func runAttached(_ arguments: [String], sync: SyncMode? = nil, extra: [String: String] = [:]) throws -> Int32 {
        try prepareDirectories()
        return try Shell.runAttached(engine.wine.path, arguments, environment: try environment(sync: sync, extra: extra))
    }

    /// Starts a Wine program and returns at once; output goes to the profile's log.
    public func spawn(_ arguments: [String], sync: SyncMode? = nil, extra: [String: String] = [:], logName: String) throws -> Process {
        try prepareDirectories()
        let log = logs.appendingPathComponent(logName)
        return try Shell.spawn(engine.wine.path, arguments, environment: try environment(sync: sync, extra: extra), log: log)
    }

    func prepareDirectories() throws {
        if engine.manifest.arch == .fex {
            try engine.checkHost()
            try engine.checkFiles()
        }
        try paths.ensure(home, home.appendingPathComponent("tmp"), home.appendingPathComponent("cache"), logs)
        try RendererStager.sync(renderer: effectiveRenderer, engine: engine, prefix: prefix)
    }

    /// Creates or updates the prefix.
    public func boot() throws {
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try run(["wineboot", "-u"], sync: SyncMode.none, extra: ["WINEDLLOVERRIDES": "mscoree,mshtml="])
        try waitForServer()
        try settle()
    }

    /// Makes a prefix that was cloned from elsewhere (Steam base, snapshot) this profile's own:
    /// host drives dropped again and the recipe's registry values applied.
    public func settle() throws {
        try applyRegistry()
        // Last, after the server has exited: Wine's mount manager maps volumes again whenever it starts.
        try waitForServer()
        try isolateHostDrives()
    }

    /// Display settings installed automatically by older releases.
    @available(*, deprecated, message: "Use GamePort.applyWineDefault(_:to:) to apply the OpenGL preset.")
    public static let prefixDefaults = ConfigPatcher.WineDefault.openGL.registry

    /// Wine maps the whole Mac as Z: and every mounted volume as D:, E:, …. Keep only C: (and the prefix)
    /// so a game cannot wander the disk. Steam libraries live inside the prefix, so nothing a game needs is lost.
    /// Wine's mount manager adds volumes again while it runs; this clears them each time the prefix is settled.
    /// Known gap: on macOS, mountmgr.sys (diskarb.c) gives every removable volume, mounted disk images
    /// included, a letter as soon as the prefix starts, and no registry value turns that off. Closing it
    /// needs a Wine patch (skip ADD_DOS_DEVICE for removable volumes) in GamePort's own engine build.
    func isolateHostDrives() throws {
        let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dosdevices.path) else { return }
        for name in entries where name.lowercased() != "c:" {
            let link = dosdevices.appendingPathComponent(name)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try FileManager.default.removeItem(at: link)
            }
        }
    }

    public func applyRegistry() throws {
        try applyRegistry(recipe?.registry ?? [])
    }

    func applyRegistry(_ values: [Recipe.RegistryValue]) throws {
        guard !values.isEmpty else { return }
        for value in values {
            var args = ["reg", "add", value.key, "/t", value.type, "/d", value.data, "/f"]
            if value.name.isEmpty { args.insert("/ve", at: 3) } else { args.insert(contentsOf: ["/v", value.name], at: 3) }
            try run(args, sync: SyncMode.none)
        }
        try waitForServer()
    }

    /// Waits until the prefix's wineserver has exited (registry flushed to disk).
    public func waitForServer() throws {
        try Shell.run(engine.wineServer.path, ["-w"], environment: try environment(sync: SyncMode.none), check: false)
    }

    /// Like `waitForServer()`, but gives up after `timeout` seconds. Returns false if the server is still up.
    public func waitForServer(timeout: TimeInterval) throws -> Bool {
        let process = Process()
        process.executableURL = engine.wineServer
        process.arguments = ["-w"]
        process.environment = try environment(sync: SyncMode.none)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        if process.isRunning {
            process.terminate()
            return false
        }
        guard process.terminationStatus == 0 else {
            throw GamePortError.process("wineserver -w could not check whether the profile is idle", process.terminationStatus)
        }
        return true
    }

    /// Stops every process in this profile's prefix and nothing else.
    public func killAll() throws {
        try Shell.run(engine.wineServer.path, ["-k"], environment: try environment(sync: SyncMode.none), check: false)
    }

    /// Windows path for a file inside the prefix's C: drive.
    public static func windowsPath(cDriveRelative path: String) -> String {
        "C:\\" + path.replacingOccurrences(of: "/", with: "\\")
    }
}
