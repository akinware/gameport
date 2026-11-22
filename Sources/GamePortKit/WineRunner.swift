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
    public var effectivePerformanceCores: Bool { profile.performanceCores ?? true }
    public var effectiveExecutionRunner: ExecutionRunner { profile.executionRunner ?? .rosetta }

    /// Layers, later wins: engine base → isolation → sync → renderer → recipe → player.
    public func environment(sync overrideSync: SyncMode? = nil, extra: [String: String] = [:]) throws -> [String: String] {
        let renderer = effectiveRenderer
        if let license = renderer.gatingLicense(in: engine.manifest), !LicenseStore(paths: paths).isAccepted(license) {
            throw GamePortError.licenseNotAccepted(license)
        }
        let cacheRoot = home.appendingPathComponent("cache", isDirectory: true)
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "USER": ProcessInfo.processInfo.environment["USER"] ?? NSUserName(),
            "HOME": home.path,
            "TMPDIR": home.appendingPathComponent("tmp").path,
            "XDG_CACHE_HOME": cacheRoot.path,
            // Persistent per-profile shader caches so compiled Metal/Vulkan pipelines survive restarts.
            "DXVK_STATE_CACHE_PATH": cacheRoot.appendingPathComponent("dxvk").path,
            "DXMT_SHADER_CACHE_PATH": cacheRoot.appendingPathComponent("dxmt").path,
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
        if profile.metalFX == true {
            env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1"
            env["DXMT_ENABLE_NVEXT"] = "1"
            env["D3DM_ENABLE_METALFX"] = "1"
        }
        if profile.x87Acceleration == true, engine.manifest.requiresRosetta {
            let sidecar = X87SidecarStore(paths: paths)
            if sidecar.isInstalled {
                env["ROSETTA_X87_PATH"] = sidecar.binaryURL.path
            }
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

    /// Resolves the final executable and argument list, applying optional AArchX translation.
    /// IMPORTANT: Never wrap `wine` in `/usr/sbin/taskpolicy` as a parent exec on macOS —
    /// SIP strips `DYLD_FALLBACK_LIBRARY_PATH` / `DYLD_FALLBACK_FRAMEWORK_PATH` whenever a
    /// system binary in `/usr/sbin` is executed, breaking MoltenVK, GnuTLS, FreeType, and D3DMetal.
    /// Instead, Performance-core QoS is applied post-spawn via `applyPerformanceCores(pid:)`.
    public func resolvedCommand(arguments: [String], applyPerformanceCores: Bool) throws -> (executable: String, arguments: [String]) {
        _ = applyPerformanceCores
        var exec = engine.wine.path
        var args = arguments
        if engine.manifest.requiresRosetta, effectiveExecutionRunner != .rosetta {
            let wrapped = try AArchXStore(paths: paths).wrap(executable: exec, arguments: args, runner: effectiveExecutionRunner)
            exec = wrapped.executable
            args = wrapped.arguments
        }
        return (exec, args)
    }

    /// Applies macOS Performance-core scheduling (`taskpolicy -B -p <pid>`) to an already-launched
    /// process so `DYLD_FALLBACK_LIBRARY_PATH` is never stripped by SIP during exec.
    public static func applyPerformanceCores(pid: Int32) {
        #if os(macOS)
        guard pid > 0, FileManager.default.isExecutableFile(atPath: "/usr/sbin/taskpolicy") else { return }
        _ = try? Shell.run("/usr/sbin/taskpolicy", ["-B", "-p", String(pid)], check: false)
        #else
        _ = pid
        #endif
    }

    /// Runs a Wine command to completion (wineboot, reg, installers).
    @discardableResult
    public func run(_ arguments: [String], sync: SyncMode? = nil, extra: [String: String] = [:], check: Bool = true) throws -> Shell.Result {
        try prepareDirectories()
        let cmd = try resolvedCommand(arguments: arguments, applyPerformanceCores: false)
        return try Shell.run(cmd.executable, cmd.arguments, environment: try environment(sync: sync, extra: extra), check: check)
    }

    /// Runs a Wine command to completion with its output streamed live to the terminal (`gameport run`).
    @discardableResult
    public func runAttached(_ arguments: [String], sync: SyncMode? = nil, extra: [String: String] = [:]) throws -> Int32 {
        try prepareDirectories()
        let cmd = try resolvedCommand(arguments: arguments, applyPerformanceCores: true)
        return try Shell.runAttached(cmd.executable, cmd.arguments, environment: try environment(sync: sync, extra: extra))
    }

    /// Starts a Wine program and returns at once; output goes to the profile's log.
    public func spawn(_ arguments: [String], sync: SyncMode? = nil, extra: [String: String] = [:], logName: String, currentDirectory: URL? = nil) throws -> Process {
        try prepareDirectories()
        let log = logs.appendingPathComponent(logName)
        let cmd = try resolvedCommand(arguments: arguments, applyPerformanceCores: true)
        let proc = try Shell.spawn(cmd.executable, cmd.arguments, environment: try environment(sync: sync, extra: extra), log: log, currentDirectory: currentDirectory)
        if effectivePerformanceCores {
            Self.applyPerformanceCores(pid: proc.processIdentifier)
        }
        return proc
    }

    func prepareDirectories() throws {
        if engine.manifest.arch == .fex {
            try engine.checkHost()
            try engine.checkFiles()
        }
        let cacheRoot = home.appendingPathComponent("cache", isDirectory: true)
        try paths.ensure(
            home,
            home.appendingPathComponent("tmp"),
            cacheRoot,
            cacheRoot.appendingPathComponent("dxvk"),
            cacheRoot.appendingPathComponent("dxmt"),
            logs
        )
        try RendererStager.sync(renderer: effectiveRenderer, engine: engine, prefix: prefix)
        try mapEngineDrive()
        applyRetinaModeIfConfigured()
    }

    /// Writes `HKCU\Software\Wine\Mac Driver` `"RetinaMode"="Y"|"N"` directly in `user.reg` when configured.
    func applyRetinaModeIfConfigured() {
        guard let retina = profile.retinaMode else { return }
        let userReg = prefix.appendingPathComponent("user.reg")
        guard var content = try? String(contentsOf: userReg, encoding: .utf8) else { return }
        let desired = retina ? "\"RetinaMode\"=\"Y\"" : "\"RetinaMode\"=\"N\""
        let header = "[Software\\\\Wine\\\\Mac Driver]"
        if let range = content.range(of: header) {
            let sectionStart = range.lowerBound
            let rest = content[range.upperBound...]
            let sectionEnd = rest.range(of: "\n[")?.lowerBound ?? content.endIndex
            var section = String(content[sectionStart..<sectionEnd])
            if let existing = section.range(of: #""RetinaMode"="[^"]*""#, options: .regularExpression) {
                guard String(section[existing]) != desired else { return }
                section.replaceSubrange(existing, with: desired)
            } else {
                if !section.hasSuffix("\n") { section.append("\n") }
                section.append(desired + "\n")
            }
            content.replaceSubrange(sectionStart..<sectionEnd, with: section)
        } else {
            if !content.hasSuffix("\n") { content.append("\n") }
            content.append("\n\(header)\n\(desired)\n")
        }
        try? content.write(to: userReg, atomically: true, encoding: .utf8)
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

    /// Wine maps the whole Mac as Z: and every mounted volume as D:, E:, …. Keep only C: (and the prefix),
    /// plus GamePort's own X: (engine), Y: (the game's depot folder) and W: (its Workshop folder in
    /// Mac Steam), so a game cannot wander the disk.
    /// Steam libraries live inside the prefix, so nothing a game needs is lost.
    /// Wine's mount manager adds volumes again while it runs; this clears them each time the prefix is settled.
    /// Known gap: on macOS, mountmgr.sys (diskarb.c) gives every removable volume, mounted disk images
    /// included, a letter as soon as the prefix starts, and no registry value turns that off. Closing it
    /// needs a Wine patch (skip ADD_DOS_DEVICE for removable volumes) in GamePort's own engine build.
    func isolateHostDrives() throws {
        let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dosdevices.path) else { return }
        for name in entries where !Self.keptDrives.contains(name.lowercased()) {
            let link = dosdevices.appendingPathComponent(name)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try FileManager.default.removeItem(at: link)
            }
        }
    }

    /// Drives GamePort maps itself; isolation keeps them. Far from D:, E:, … which Wine's mount manager
    /// hands to mounted volumes.
    public static let engineDrive = "x:"
    public static let gameDrive = "y:"
    /// Mac Steam's Workshop folder for a Bridge game, so the game can open the mods Mac Steam downloads.
    public static let workshopDrive = "w:"
    static let keptDrives: Set<String> = ["c:", engineDrive, gameDrive, workshopDrive]

    /// Maps the (read-only, shared) engine as X:. Without Z:, Wine can name its own data folder only as
    /// a `\\?\unix\…` path, which mscoree cannot use: Wine Mono is then "not installed" and every .NET
    /// game quits at start. Through X: the data folder becomes `X:\engine\share\wine`.
    func mapEngineDrive() throws {
        try mapDrive(Self.engineDrive, to: engine.root)
    }

    /// Maps a game folder that lives outside the prefix (a Steam depot download) as Y: and returns the
    /// executable's Windows path on it. Without a drive letter Wine runs such a game from a
    /// `\\?\unix\…` path, which .NET hosts (and some native games) cannot resolve, so they quit at start.
    /// Returns nil when the executable is not inside `folder`.
    @discardableResult
    public func mapGameDrive(_ folder: URL, executable: URL) throws -> String? {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let exe = executable.standardizedFileURL.resolvingSymlinksInPath().path
        guard exe.hasPrefix(root + "/") else { return nil }
        try mapDrive(Self.gameDrive, to: URL(fileURLWithPath: root, isDirectory: true))
        let relative = exe.dropFirst(root.count + 1).replacingOccurrences(of: "/", with: "\\")
        return Self.gameDrive.uppercased() + "\\" + relative
    }

    /// Points `dosdevices/<drive>` at `target`, replacing a link that points elsewhere.
    func mapDrive(_ drive: String, to target: URL) throws {
        let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dosdevices.path) else { return }
        let link = dosdevices.appendingPathComponent(drive)
        if let current = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            if current == target.path { return }
            try FileManager.default.removeItem(at: link)
        } else if FileManager.default.fileExists(atPath: link.path) {
            return // a real folder the user made; leave it alone
        }
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
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
