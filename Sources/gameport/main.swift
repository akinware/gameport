import Foundation
import GamePortKit

let cli = Brand.cliName
let usage = """
\(Brand.displayName): runs Windows games on Apple Silicon Macs.

Usage:
  \(cli) doctor                         Check system requirements
  \(cli) engine available               List bundled and installed engines
  \(cli) engine install [id|manifest]   Install the default engine, a bundled engine id, or a manifest.json
  \(cli) engine default [engine]        Show or set the default engine for new profiles
  \(cli) engine remove <engine>         Remove an unused installed engine
  \(cli) engine kosmickrisp <engine>    Install the optional verified Vulkan driver and shim
  \(cli) engine list                    Installed engines
  \(cli) license show apple-gptk        Show the licence summary
  \(cli) license accept apple-gptk      Accept Apple's GPTK licence for D3DMetal
  \(cli) recipes [words or Steam ID] [--status <status>] [--renderer <renderer>]
  \(cli) recipes add <Steam URL or ID> [title] [--renderer <renderer>]  Add any Steam game to your library
  \(cli) anticheat <game name|Steam id> Before downloading: does anti-cheat block it on a Mac?
  \(cli) base build                     Build the Steam base (once; later profiles are ready in seconds)
  \(cli) base status                    Steam base status
  \(cli) profile create <recipe> [id] [--engine <engine>]  Create an isolated game environment
  \(cli) profile fallback <profile> <other-profile|off>   Select an alternate engine profile for play
  \(cli) profile list                   Profiles
  \(cli) config <profile>               Apply missing optional recipe settings after closing the game
  \(cli) config <profile> controller|opengl   Apply missing controller or OpenGL defaults in this profile
  \(cli) snapshot <profile> [name]      Snapshot a profile (before an update)
  \(cli) snapshot list <profile>        Snapshots
  \(cli) snapshot restore <profile> <name>  Roll a profile back to a snapshot
  \(cli) snapshot delete <profile> <name>   Delete a snapshot
  \(cli) snapshot auto <profile> on|off Daily automatic snapshot before Steam starts (default: on)
  \(cli) steam install <profile>        Install Windows Steam in a profile
  \(cli) steam open <profile>           Open Steam (sign in, store, downloads)
  \(cli) play <profile>                 Start the game
  \(cli) stop <profile>                 Stop everything in a profile
  \(cli) lab <profile> [renderer,…] [s] Start the game, measure FPS and record whether it works
  \(cli) lab <profile> auto [s]         Try every renderer and set the fastest working one
  \(cli) lab <profile> compare <other-profile> [s]  Compare two engines on the same game
  \(cli) vulkan <profile> [driver]      Vulkan driver for the game: moltenvk (default) or kosmickrisp (experimental)
  \(cli) telemetry [status|on|off|preview|reset-id]  Anonymous FPS & compatibility sharing (default: on)
  \(cli) storage [status|set <folder>|reset]  Choose an External APFS SSD or custom data folder
  \(cli) env <profile>                  Show the game's environment variables
  \(cli) run <profile> <windows command…>  Run a Windows program in a profile

Data: ~/Library/Application Support/\(Brand.dataFolder) (override with \(Brand.homeEnvironmentVariable))
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Asks a yes/no question on the terminal; anything but yes/y counts as no.
func confirm(_ question: String) -> Bool {
    print("\(question) [yes/no] ", terminator: "")
    return ["yes", "y"].contains(readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
}

@Sendable func progress(_ message: String) { print("  • \(message)") }
let gameport = GamePort()
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func arg(_ i: Int, _ name: String) -> String {
    guard i < args.count else { fail("missing argument: \(name)\n\n\(usage)") }
    return args[i]
}

do {
    switch command {
    case "doctor":
        var allOK = true
        for c in gameport.doctor() {
            print("\(c.ok ? "✓" : "✗") \(c.name): \(c.detail)")
            allOK = allOK && c.ok
        }
        exit(allOK ? 0 : 1)

    case "engine":
        switch arg(0, "available|install|default|remove|list|kosmickrisp") {
        case "available":
            for entry in gameport.engineCatalog() {
                var flags: [String] = []
                if entry.isInstalled { flags.append("installed") } else { flags.append("available") }
                if entry.isDefault { flags.append("default") }
                if entry.profilesUsingCount > 0 { flags.append("\(entry.profilesUsingCount) games") }
                print("\(entry.id)  [\(flags.joined(separator: ", "))]  \(entry.manifest.arch.label)  ~\(entry.manifest.downloadSizeLabel)  \(entry.manifest.displayName)")
            }
        case "install":
            guard args.count <= 2 else { fail(usage) }
            let engine: InstalledEngine
            if args.count == 2 {
                if let bundled = EngineStore.bundledManifest(id: args[1]) {
                    engine = try await gameport.engines.install(bundled, progress: progress)
                } else {
                    let manifest = try EngineManifest.load(URL(fileURLWithPath: args[1]))
                    engine = try await gameport.engines.install(manifest, progress: progress)
                }
            } else {
                engine = try await gameport.installDefaultEngine(progress: progress)
            }
            print("✓ Installed: \(engine.id)")
        case "default":
            if args.count == 1 {
                if let def = gameport.engineCatalog().first(where: \.isDefault) {
                    print("\(def.id)  (\(def.manifest.displayName))")
                } else {
                    print("No engine installed. Run `\(cli) engine install`.")
                }
            } else if args.count == 2 {
                try gameport.engines.setDefaultEngine(args[1])
                print("✓ Default engine set to: \(args[1])")
            } else {
                fail(usage)
            }
        case "remove":
            guard args.count == 2 else { fail(usage) }
            try gameport.removeEngine(args[1])
            print("✓ Removed engine: \(args[1])")
        case "kosmickrisp":
            guard args.count == 2 else { fail(usage) }
            try await gameport.engines.installKosmicKrisp(args[1], progress: progress)
        case "list":
            let list = gameport.engines.installed()
            let defaultID = gameport.engineCatalog().first(where: \.isDefault)?.id
            if list.isEmpty { print("No engine installed. Run `\(cli) engine install`.") }
            for e in list {
                let mark = e.id == defaultID ? " [default]" : ""
                print("\(e.id)\(mark)  \(e.manifest.arch.label)  \(e.manifest.displayName)")
            }
        default: fail(usage)
        }

    case "license":
        let action = arg(0, "show|accept|revoke"), id = arg(1, "licence")
        guard let license = gameport.defaultManifest?.licenses[id] else { fail("unknown licence \(id)") }
        switch action {
        case "show":
            print("\(license.title)\n\n\(license.summary)\n\(license.url.map { "\nFull text: \($0)" } ?? "")")
            print("\nStatus: \(gameport.licenses.isAccepted(id) ? "accepted" : "not accepted")")
        case "accept":
            print("\(license.title)\n\n\(license.summary)\n")
            guard confirm("Do you accept?") else { fail("not accepted") }
            try gameport.licenses.accept(id)
            print("✓ Accepted.")
        case "revoke":
            try gameport.licenses.revoke(id)
            print("✓ Revoked.")
        default: fail(usage)
        }

    case "recipes":
        if args.first == "add" {
            let input = arg(1, "Steam URL or App ID")
            guard let appID = SteamStore.parseAppID(input) else { fail("expected a numeric Steam App ID or Steam Store URL") }
            var renderer: Renderer = .dxmt
            var titleWords: [String] = []
            var rest = args.dropFirst(2).makeIterator()
            while let tok = rest.next() {
                if tok == "--renderer" {
                    guard let val = rest.next(), let r = Renderer(rawValue: val) else {
                        fail("--renderer expects one of " + Renderer.allCases.map(\.rawValue).joined(separator: ", "))
                    }
                    renderer = r
                } else {
                    titleWords.append(tok)
                }
            }
            let title: String
            if !titleWords.isEmpty {
                title = titleWords.joined(separator: " ")
            } else {
                title = (try? await SteamStore.fetchTitle(appID: appID)) ?? "Steam Game \(appID)"
            }
            let recipe = try gameport.addCustomSteamGame(appID: appID, title: title, renderer: renderer)
            print("✓ Ready: \(recipe.id) (\(recipe.title), Steam \(appID), \(recipe.renderer.rawValue))")
            print("  Next: \(cli) profile create \(recipe.id)")
            exit(0)
        }
        var filter = RecipeFilter()
        var words: [String] = []
        var tokens = args.makeIterator()
        while let token = tokens.next() {
            switch token {
            case "--status":
                guard let value = tokens.next(), let status = Recipe.Status(rawValue: value) else {
                    fail("--status expects one of " + Recipe.Status.allCases.map(\.rawValue).joined(separator: ", "))
                }
                filter.status = status
            case "--renderer":
                guard let value = tokens.next(), let renderer = Renderer(rawValue: value) else {
                    fail("--renderer expects one of " + Renderer.allCases.map(\.rawValue).joined(separator: ", "))
                }
                filter.renderer = renderer
            default:
                guard !token.hasPrefix("--") else { fail("unknown recipes option \(token)") }
                words.append(token)
            }
        }
        filter.query = words.joined(separator: " ")
        let matches = filter.apply(to: gameport.catalog.sorted)
        if matches.isEmpty { print("No matching recipes.") }
        for r in matches {
            let appID = r.steamAppID.map { "Steam \($0)" } ?? "-"
            print("\(r.id.padding(toLength: 26, withPad: " ", startingAt: 0)) \(r.renderer.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(r.status.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(appID.padding(toLength: 14, withPad: " ", startingAt: 0)) \(r.title)")
        }

    case "config":
        let id = arg(0, "profile")
        if args.count == 1 {
            try gameport.applyConfigDefaults(id, progress: progress)
        } else if args.count == 2, let preset = ConfigPatcher.WineDefault(rawValue: args[1]) {
            try gameport.applyWineDefault(preset, to: id)
            print("✓ Applied missing defaults. Existing settings kept.")
        } else { fail("expected config <profile> [controller|opengl]") }

    case "base":
        let base = try gameport.steamBase()
        switch arg(0, "build|status|delete") {
        case "build":
            print("Building the Steam base: a Windows environment, Steam and Steam's first update. This happens once.")
            try await base.build(progress: progress)
            print("✓ Ready. New profiles are now cloned from this base.")
        case "status":
            if let stamp = base.stamp, base.isReady {
                print("✓ Steam base ready: \(stamp.engineID), \(stamp.builtAt.formatted())")
            } else {
                print("No Steam base. Build it with `\(cli) base build`; until then every profile installs Steam from scratch.")
            }
        case "delete":
            try base.delete()
            print("✓ Deleted. Existing profiles are not affected.")
        default: fail(usage)
        }

    case "snapshot":
        switch arg(0, "profile|list|restore|delete|auto") {
        case "list":
            let id = arg(1, "profile")
            let list = gameport.profiles.listSnapshots(id)
            if list.isEmpty { print("No snapshots for \(id).") }
            for s in list { print("\(s.name)  \(s.createdAt.formatted())  [\(s.engineID)]") }
        case "restore":
            let id = arg(1, "profile"), name = arg(2, "name")
            guard confirm("Profile \(id) goes back to snapshot \(name); everything since then (downloads, saves) is lost. Are you sure?") else { fail("cancelled") }
            try gameport.restore(id, snapshot: name)
            print("✓ Restored.")
        case "auto":
            let id = arg(1, "profile"), value = arg(2, "on|off")
            guard ["on", "off"].contains(value) else { fail(usage) }
            var profile = try gameport.profiles.load(id)
            profile.autoSnapshots = value == "on"
            try gameport.profiles.save(profile)
            print("✓ Automatic snapshots: \(value)")
        case "delete":
            let id = arg(1, "profile"), name = arg(2, "name")
            guard confirm("Snapshot \(name) will be deleted. Are you sure?") else { fail("cancelled") }
            try gameport.profiles.deleteSnapshot(id, name: name)
            print("✓ Deleted.")
        default:
            let id = arg(0, "profile")
            print("Stopping the profile and taking a snapshot…")
            let s = try gameport.snapshot(id, name: args.count > 1 ? args[1] : nil)
            print("✓ Saved \(s.name). To go back: \(cli) snapshot restore \(id) \(s.name)")
        }

    case "anticheat":
        let query = args.joined(separator: " ")
        guard !query.isEmpty else { fail("a game name or Steam id is needed") }
        let hits = AntiCheatDB.bundled.search(query)
        if hits.isEmpty { print("Not in the anti-cheat list (\(AntiCheatDB.bundled.entries.count) games). That does not mean the game works.") }
        for e in hits {
            let mark = e.risk == .blocked ? "✗" : e.risk == .onlineDenied ? "!" : "·"
            print("\(mark) \(e.title)\(e.steamAppID.map { " (Steam \($0))" } ?? ""): \(e.summary)")
        }
        print("Source: highball-db / Are We Anti-Cheat Yet? (MIT)")

    case "profile":
        switch arg(0, "create|list|delete|fallback") {
        case "create":
            let recipe = arg(1, "recipe")
            var options = Array(args.dropFirst(2))
            let id = options.first.map { !$0.hasPrefix("--") } == true ? options.removeFirst() : nil
            guard options.isEmpty || (options.count == 2 && options[0] == "--engine") else { fail(usage) }
            let profile = try gameport.createProfile(recipeID: recipe, profileID: id, engineID: options.last, progress: progress)
            let next = (try? gameport.steam(for: profile.id).isInstalled) == true ? "\(cli) steam open" : "\(cli) steam install"
            print("✓ Profile ready: \(profile.id). Next: \(next) \(profile.id)")
        case "list":
            for p in gameport.profiles.all() {
                print("\(p.id)  \(p.title)  [\(p.engineID)]" + (p.fallbackProfileID.map { "  fallback: \($0)" } ?? ""))
            }
        case "fallback":
            guard args.count == 3 else { fail(usage) }
            try gameport.setFallback(args[1], to: args[2] == "off" ? nil : args[2])
            print("Fallback for \(args[1]): \(args[2])")
        case "delete":
            let id = arg(1, "profile")
            guard confirm("Profile \(id) and everything in it (installed games, saves) will be deleted. Are you sure?") else { fail("cancelled") }
            try gameport.profiles.delete(id)
            print("✓ Deleted.")
        default: fail(usage)
        }

    case "steam":
        let action = arg(0, "install|open"), id = arg(1, "profile")
        let steam = try gameport.steam(for: id)
        switch action {
        case "install":
            try await steam.install(progress: progress)
            print("✓ Steam installed. Next: \(cli) steam open \(id) (sign in and download the game)")
        case "open":
            let p = try gameport.openSteam(id, progress: progress)
            print("Opening Steam (pid \(p.processIdentifier)). The first start can take a few minutes. Log: \(gameport.profiles.logs(id).appendingPathComponent("steam.log").path)")
        default: fail(usage)
        }

    case "play":
        let id = arg(0, "profile")
        let p = try gameport.play(id, progress: progress)
        print("Game started (pid \(p.processIdentifier)).")

    case "lab":
        let id = arg(0, "profile")
        if args.dropFirst().first == "compare" {
            guard (3...4).contains(args.count), let duration = Int(args.count == 4 ? args[3] : "180"), duration > 0 else { fail(usage) }
            _ = try await gameport.compareEngines(id, with: args[2], seconds: duration, progress: progress)
            exit(0)
        }
        var renderers: [Renderer?] = [nil]
        var seconds = 180
        var auto = false
        for extra in args.dropFirst() {
            if let n = Int(extra) { seconds = n; continue }
            if extra == "auto" { auto = true; continue }
            renderers = try extra.split(separator: ",").map { name in
                guard let r = Renderer(rawValue: String(name)) else { throw GamePortError.invalid("renderer \(name)") }
                return r
            }
        }
        if auto {
            let candidates = try gameport.labCandidates(id)
            print("Trying: \(candidates.map(\.rawValue).joined(separator: ", ")) (\(seconds) s each)")
            let (best, runs) = try await gameport.findBestRenderer(id, seconds: seconds, progress: progress)
            print("\nResult (\(runs.first?.machine ?? ""), macOS \(runs.first?.macOS ?? "")):")
            for r in runs { print("  \(r.summary)") }
            if let best { print("✓ \(id) now uses \(best.renderer.displayName).") }
            else { print("No renderer was measured working; the profile is unchanged.") }
            exit(0)
        }
        var results: [LabResult] = []
        for renderer in renderers {
            let r = try await gameport.lab(id, renderer: renderer, seconds: seconds, progress: progress)
            print("  → \(r.summary)")
            results.append(r)
        }
        print("\nResult (\(results.first?.machine ?? ""), macOS \(results.first?.macOS ?? "")):")
        for r in results { print("  \(r.summary)") }
        print("Details: \(gameport.profiles.directory(id).appendingPathComponent("lab").path)")

    case "stop":
        try gameport.stop(arg(0, "profile"))
        print("✓ Stopped.")

    case "vulkan":
        let id = arg(0, "profile")
        var profile = try gameport.profiles.load(id)
        guard args.count > 1 else {
            print("\(id): \((profile.vulkanDriver ?? .moltenvk).displayName)")
            exit(0)
        }
        guard let driver = VulkanDriver(rawValue: args[1]) else { fail("unknown Vulkan driver \(args[1]) (moltenvk, kosmickrisp)") }
        if driver == .kosmickrisp, try gameport.runner(for: id).engine.kosmicKrispShim == nil {
            fail("Install the optional driver with \(cli) engine kosmickrisp \(profile.engineID)")
        }
        profile.vulkanDriver = driver == .moltenvk ? nil : driver
        try gameport.profiles.save(profile)
        print("✓ \(id) uses \(driver.displayName) for Vulkan (DXVK's D3D9/10/11, vkd3d's D3D12).")

    case "telemetry":
        let action = args.first ?? "status"
        switch action {
        case "status":
            let on = gameport.telemetry.isEffectivelyEnabled()
            let endpoint = gameport.telemetry.endpoint()?.absoluteString ?? "not configured"
            print("Anonymous compatibility sharing: \(on ? "on" : "off") (endpoint: \(endpoint))")
        case "on":
            _ = try gameport.telemetry.setEnabled(true)
            print("✓ Anonymous compatibility sharing enabled.")
        case "off":
            _ = try gameport.telemetry.setEnabled(false)
            print("✓ Anonymous compatibility sharing disabled.")
        case "preview":
            print(gameport.telemetry.previewJSON())
        case "reset-id":
            let updated = try gameport.telemetry.resetInstallID()
            print("✓ Anonymous install ID rotated: \(updated.installID)")
        default: fail(usage)
        }

    case "storage":
        let action = args.first ?? "status"
        switch action {
        case "status":
            let info = StorageInfo.inspect(gameport.paths.root, isCustom: StoragePreference.load().customRoot != nil)
            print("Storage: \(info.root.path)")
            print("Volume:  \(info.volumeName) (\(info.filesystem), \(info.freeSpaceLabel))\(info.isExternal ? " [external]" : "")")
            if let warning = info.warning { print("! \(warning)") }
        case "set":
            let path = arg(1, "folder path")
            let info = try StorageInfo.setCustomRoot(URL(fileURLWithPath: path))
            print("✓ Storage set to \(info.root.path) (\(info.volumeName), \(info.filesystem), \(info.freeSpaceLabel))")
            if let warning = info.warning { print("! \(warning)") }
        case "reset":
            let info = try StorageInfo.resetToDefault()
            print("✓ Storage reset to default: \(info.root.path)")
        default: fail(usage)
        }

    case "env":
        let env = try gameport.runner(for: arg(0, "profile")).environment()
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { print("\(k)=\(v)") }

    case "run":
        let id = arg(0, "profile")
        let rest = Array(args.dropFirst())
        guard !rest.isEmpty else { fail("no command to run") }
        exit(try gameport.runner(for: id).runAttached(rest))

    case "help", "-h", "--help":
        print(usage)

    default:
        fail("unknown command \(command)\n\n\(usage)")
    }
} catch {
    fail("\(error)")
}
