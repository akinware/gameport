import Foundation
import GamePortKit

// Line-buffer stdout so progress (and the sign-in QR code) appear immediately when piped.
setvbuf(stdout, nil, _IOLBF, 0)

let cli = Brand.cliName
let usage = """
\(Brand.displayName): runs Windows games on Apple Silicon Macs.

Usage:
  \(cli) setup                          One-click guided setup (default engine + Steam base)
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
  \(cli) profile engine <profile> <engine>   Move a profile to another installed engine (snapshot first)
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
  \(cli) battlenet install <profile>    Download & run Blizzard's Battle.net installer in a profile
  \(cli) battlenet open <profile>       Open Battle.net in a profile (Overwatch 2, Diablo IV, etc.)
  \(cli) bridge [status|probe|install-steamcmd|install-depotdownloader|download|signout|launch]  Clean-room Mac Steam bridge (zero Windows Steam)
  \(cli) bridge download <appID> [--user <acct>] [--anonymous] [--validate] [--dir <d>] [--steamcmd]
  \(cli) bridge add-to-steam <profile>       Put a downloaded game into the profile's Windows Steam library (APFS clone)
                                       Download a Windows game: Steam Mobile QR sign-in once, then silent
  \(cli) crossover [status|bottles|launch <bottle> <appID>]     Use installed CrossOver.app (0 MB engine & 1-click bottles)
  \(cli) crossover adopt <bottle> <appID>      Play a bottle's Steam game with GamePort's Wine (APFS clone, bottle untouched)
  \(cli) epic [status|install|login <code>|logout|list|download <app>|launch <app>]  Epic Games via native legendary
  \(cli) gog [status|install|login <code>|logout|list|download <id>|launch <id>]    GOG DRM-free via native gogdl
  \(cli) heroic                                                 Discover existing Heroic (Epic/GOG/Amazon) installs
  \(cli) play <profile>                 Start the game
  \(cli) stop <profile>                 Stop everything in a profile
  \(cli) stop --all                    Stop every Windows program (all profiles, CrossOver, leftovers)
  \(cli) lab <profile> [renderer,…] [s] Start the game, measure FPS and record whether it works
  \(cli) lab <profile> auto [s]         Try every renderer and set the fastest working one
  \(cli) lab <profile> compare <other-profile> [s]  Compare two engines on the same game
  \(cli) vulkan <profile> [driver]      Vulkan driver for the game: moltenvk (default) or kosmickrisp (experimental)
  \(cli) telemetry [status|on|off|preview|flush|reset-id]  Anonymous FPS & compatibility sharing (default: on)
  \(cli) history <profile>              How the game ran the last times it was played (kept on this Mac)
  \(cli) storage [status|set <folder>|reset]  Choose an External APFS SSD or custom data folder
  \(cli) perf <profile> [pcores|retina|metalfx|x87|runner] [value]  Apple Silicon performance settings
  \(cli) x87 [status|install|probe|remove]  Rosetta x87 JIT accelerator (x87sidecar, MIT, 182 KB)
  \(cli) aarchx [status|install|remove] Experimental No-Rosetta x86-64 runner (LGPL-2.1)
  \(cli) external                       Detect Obelisk, Siliconium, CrossOver, Mac Steam & NotProton
  \(cli) external owned                 Windows-only games your Mac Steam account owns (recipe, anti-cheat)
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
    case "setup":
        let msg = try await gameport.guidedSetup(progress: progress)
        print("✓ \(msg)")

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
        switch arg(0, "create|list|delete|fallback|engine") {
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
        case "engine":
            let id = arg(1, "profile"), engine = arg(2, "engine")
            let p = try gameport.switchEngine(id, to: engine, progress: progress)
            print("✓ \(p.id) now uses \(p.engineID)")
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

    case "battlenet":
        let action = arg(0, "install|open"), id = arg(1, "profile")
        switch action {
        case "install":
            _ = try await gameport.battleNet(for: id).install(progress: progress)
            print("✓ Battle.net installer launched for \(id). Complete sign-in and game download in its window.")
        case "open":
            _ = try gameport.openBattleNet(id, progress: progress)
            print("✓ Battle.net opened for \(id).")
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
        if args.first == "--all" {
            let n = gameport.stopAllWindowsProcesses()
            print(n == 0 ? "No Windows programs were running." : "✓ Stopped \(n) Windows process\(n == 1 ? "" : "es").")
        } else {
            try gameport.stop(arg(0, "profile"))
            print("✓ Stopped.")
        }

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
            let waiting = gameport.telemetry.outbox().count
            if waiting > 0 { print("\(waiting) report(s) waiting to be sent (retried with the next report).") }
        case "flush":
            let sent = await gameport.telemetry.flushOutbox()
            print("Sent \(sent) waiting report(s); \(gameport.telemetry.outbox().count) still waiting.")
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

    case "history":
        let id = arg(0, "profile")
        _ = try gameport.profiles.load(id)
        let sessions = gameport.playHistory.sessions(id)
        if sessions.isEmpty { print("No sessions recorded for \(id) yet.") }
        for session in sessions {
            print("  • \(session.summary()) · \(session.renderer.rawValue) · \(session.engineID)"
                  + (session.problems.isEmpty ? "" : " · \(session.problems.joined(separator: ", "))"))
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

    case "perf":
        let id = arg(0, "profile")
        var profile = try gameport.profiles.load(id)
        if args.count == 1 {
            print("Profile:   \(id)")
            print("P-cores:   \((profile.performanceCores ?? true) ? "on" : "off")")
            print("Retina:    \(profile.retinaMode.map { $0 ? "hidpi" : "1x" } ?? "auto")")
            print("MetalFX:   \(profile.metalFX == true ? "on" : "off")")
            print("x87:       \(profile.x87Acceleration == true ? "on" : "off")")
            print("Runner:    \((profile.executionRunner ?? .rosetta).rawValue)")
        } else {
            let key = arg(1, "pcores|retina|metalfx|x87|runner").lowercased()
            let val = arg(2, "value").lowercased()
            switch key {
            case "pcores":
                guard ["on", "off"].contains(val) else { fail("pcores expects on|off") }
                profile.performanceCores = (val == "on")
            case "retina":
                switch val {
                case "auto": profile.retinaMode = nil
                case "1x", "off": profile.retinaMode = false
                case "hidpi", "on": profile.retinaMode = true
                default: fail("retina expects auto|1x|hidpi")
                }
            case "metalfx":
                guard ["on", "off"].contains(val) else { fail("metalfx expects on|off") }
                profile.metalFX = val == "on" ? true : nil
            case "x87":
                guard ["on", "off"].contains(val) else { fail("x87 expects on|off") }
                profile.x87Acceleration = val == "on" ? true : nil
            case "runner":
                guard let runner = ExecutionRunner(rawValue: val) else {
                    fail("runner expects one of " + ExecutionRunner.allCases.map(\.rawValue).joined(separator: ", "))
                }
                profile.executionRunner = runner == .rosetta ? nil : runner
            default: fail(usage)
            }
            try gameport.profiles.save(profile)
            print("✓ Updated \(id): \(key)=\(val)")
        }

    case "x87":
        let action = args.first ?? "status"
        switch action {
        case "status":
            if gameport.x87sidecar.isInstalled {
                let check = gameport.x87sidecar.probe()
                print("x87sidecar: installed (\(gameport.x87sidecar.versionString() ?? "unknown")) — probe: \(check.ok ? "supported" : check.detail)")
            } else {
                print("x87sidecar: not installed. Run `\(cli) x87 install` (182 KB, SHA-256 verified, MIT).")
            }
        case "install":
            let bin = try await gameport.x87sidecar.install(progress: progress)
            print("✓ Installed x87sidecar at \(bin.path)")
        case "probe":
            let check = gameport.x87sidecar.probe()
            print("\(check.ok ? "✓" : "✗") \(check.detail)")
            exit(check.ok ? 0 : 1)
        case "remove":
            try gameport.x87sidecar.remove()
            print("✓ Removed x87sidecar")
        default: fail(usage)
        }

    case "aarchx":
        let action = args.first ?? "status"
        switch action {
        case "status":
            if let bin = gameport.aarchx.binaryURL() {
                print("AArchX: installed (\(gameport.aarchx.versionString() ?? "unknown")) at \(bin.path)")
            } else {
                print("AArchX: not installed. Run `\(cli) aarchx install` (7.7 MB, SHA-256 verified, LGPL-2.1).")
            }
        case "install":
            let bin = try await gameport.aarchx.install(progress: progress)
            print("✓ Installed AArchX at \(bin.path)")
        case "remove":
            try gameport.aarchx.remove()
            print("✓ Removed AArchX")
        default: fail(usage)
        }

    case "bridge":
        let action = args.first ?? "status"
        switch action {
        case "add-to-steam":
            let id = arg(1, "profile")
            let dir = try gameport.addDepotToWindowsSteam(id, progress: progress)
            print("✓ In Windows Steam's library: \(dir.path)")
        case "status":
            let st = gameport.steamBridge.status()
            print("GamePort Steam Bridge: \(st.readinessSummary)")
            let archText = gameport.steamBridge.has32BitSupport ? "64-bit + 32-bit WoW64" : "64-bit only"
            print("  Overlay built:    \(st.overlayInstalled ? "yes (\(archText) at \(st.overlayDir.path))" : "no (run Scripts/build-steam-bridge.sh)")")
            print("  Native Mac Steam: \(st.macSteamInstalled ? (st.macSteamRunning ? "installed & running" : "installed (not running)") : "not installed")")
            if let dylib = st.steamClientDylib {
                print("  steamclient.dylib: \(dylib.path) (x86_64 slice: \(st.steamClientHasX86_64 ? "yes" : "no"))")
            } else {
                print("  steamclient.dylib: not found")
            }
            print("  Valve steamcmd:   \(st.steamCmdInstalled ? "installed (\(gameport.steamDepot.installDir.path))" : "not installed (`\(cli) bridge install-steamcmd`)")")
            let dd = gameport.steamQRDownloader.tool
            print("  DepotDownloader:  \(dd.isInstalled ? "\(DepotDownloaderTool.version) installed (\(dd.toolDir.path))" : "not installed (installed on first download)")")
            let remembered = dd.rememberedAccounts()
            print("  QR sign-in:       \(remembered.isEmpty ? "not signed in (a QR code is shown on first download)" : "remembered for \(remembered.joined(separator: ", "))")")
        case "probe":
            var engineID: String? = nil
            var mock = false
            var probe32 = false
            var it = args.dropFirst().makeIterator()
            while let tok = it.next() {
                if tok == "--engine" { engineID = it.next() }
                else if tok == "--mock" { mock = true }
                else if tok == "--32" { probe32 = true }
                else { fail("unknown flag \(tok)") }
            }
            let engine: InstalledEngine
            if let engineID {
                engine = try gameport.engines.engine(engineID)
            } else if let defID = gameport.engines.defaultEngineID(), let def = try? gameport.engines.engine(defID) {
                engine = def
            } else if let first = gameport.engines.installed().first {
                engine = first
            } else {
                fail("no engine installed")
            }
            let res = try gameport.steamBridge.probe(engine: engine, mockMode: mock, probe32: probe32)
            print("\(res.success ? "✓" : "✗") Bridge \(probe32 ? "32-bit WoW64 " : "64-bit ")probe on \(res.engineID) (\(res.mockMode ? "mock" : "native Mac Steam"), exit \(res.exitCode))")
            if !res.output.isEmpty { print(res.output) }
            exit(res.success ? 0 : 1)
        case "install-steamcmd":
            try await gameport.steamDepot.install(progress: progress)
            print("✓ Installed Valve steamcmd.")
        case "install-depotdownloader":
            try await gameport.steamQRDownloader.tool.install(progress: progress)
            print("✓ Installed DepotDownloader \(DepotDownloaderTool.version).")
        case "signout":
            gameport.steamQRDownloader.tool.signOutAll()
            print("✓ Forgot every remembered QR sign-in.")
        case "download":
            let rawID = arg(1, "Steam App ID")
            guard let appID = SteamStore.parseAppID(rawID) else { fail("expected a numeric Steam App ID") }
            var user: String? = nil
            var customDir: URL? = nil
            var useSteamCmd = false
            var anonymous = false
            var validate = false
            var it = args.dropFirst(2).makeIterator()
            while let tok = it.next() {
                if tok == "--user" { user = it.next() }
                else if tok == "--dir" { if let d = it.next() { customDir = URL(fileURLWithPath: d, isDirectory: true) } }
                else if tok == "--steamcmd" { useSteamCmd = true }
                else if tok == "--anonymous" { anonymous = true }
                else if tok == "--validate" { validate = true }
                else { fail("unknown flag \(tok)") }
            }
            let targetDir = customDir ?? gameport.steamDepot.depotDirectory(appID: appID)
            if useSteamCmd {
                let code = try gameport.steamDepot.downloadAttached(appID: appID, installDir: targetDir, username: user ?? "anonymous")
                if code == 0, let exe = SteamDepotManager.mainExecutable(appID: appID, in: targetDir, paths: gameport.paths) {
                    print("✓ Downloaded AppID \(appID) -> \(targetDir.path)")
                    print("  Detected main executable: \(exe.path)")
                }
                exit(code)
            }
            let stream = gameport.steamQRDownloader.download(
                appID: appID,
                title: gameport.catalog.recipe(steamAppID: appID)?.title,
                installDir: targetDir,
                preferredAccount: user ?? ExternalDiscovery.macSteamAccountName(),
                anonymous: anonymous,
                validate: validate
            )
            var lastPrinted = -1.0
            for try await event in stream {
                switch event {
                case .installingTool(let msg), .status(let msg):
                    print(msg)
                case .qrCode(let code):
                    print("\nScan with the Steam Mobile App to sign in once (no password needed):")
                    print(code.terminalArt())
                    if let url = code.url { print("  \(url)") }
                case .waitingForMobileApproval:
                    print("Waiting for approval in the Steam Mobile App…")
                case .signedIn(let account):
                    print("✓ Signed in as \(account)")
                case .downloading(let pct, let detail):
                    if pct - lastPrinted >= 1 || pct >= 100 || pct < lastPrinted {
                        lastPrinted = pct
                        print(String(format: "%6.2f%% %@", pct, detail))
                    }
                case .updateChecked(let changed):
                    print(changed ? "✓ Updated to the latest version" : "✓ Already up to date")
                case .completed(let dir, let exe):
                    print("✓ Downloaded AppID \(appID) -> \(dir.path)")
                    if let exe { print("  Detected main executable: \(exe.path)") }
                }
            }
        case "launch":
            let id = arg(1, "profile")
            var exe: URL? = nil
            var dir: URL? = nil
            var forceVAC = false
            var verbose = false
            var gameArgs: [String] = []
            var it = args.dropFirst(2).makeIterator()
            while let tok = it.next() {
                if tok == "--" { while let a = it.next() { gameArgs.append(a) }; break }
                if tok == "--exe" { if let p = it.next() { exe = URL(fileURLWithPath: p) } }
                else if tok == "--dir" { if let d = it.next() { dir = URL(fileURLWithPath: d, isDirectory: true) } }
                else if tok == "--force-vac" { forceVAC = true }
                else if tok == "--verbose" { verbose = true }
                else { fail("unknown flag \(tok)") }
            }
            let proc = try gameport.launchWithSteamBridge(
                id,
                executable: exe,
                arguments: gameArgs,
                depotDirectory: dir,
                allowVACOverride: forceVAC,
                verboseLog: verbose,
                progress: progress
            )
            // The same watcher as the app: it records the session in `gameport history` and reports it.
            let title = (try? gameport.profiles.load(id).title) ?? id
            await gameport.monitorBridgeLaunch(profileID: id, title: title, process: proc) { state in
                if case .needsAttention(_, let diagnosis) = state {
                    print("✗ \(diagnosis.headline)\n  \(diagnosis.explanation)")
                }
            }
            exit(proc.terminationStatus)
        default:
            fail(usage)
        }

    case "crossover":
        let action = args.first ?? "status"
        switch action {
        case "status":
            if let cx = CrossOverSupport.detect() {
                print("CrossOver: installed (\(cx.version ?? "unknown")) at \(cx.appURL.path)")
                print("  Engine ID: \(CrossOverInstallation.engineID) (0 MB download)")
                let games = CrossOverSupport.discoverBottleGames()
                print("  Bottle games: \(games.count)")
            } else {
                print("CrossOver: not installed in /Applications (GamePort PowerKit engines are ready instead).")
            }
        case "bottles":
            let games = CrossOverSupport.discoverBottleGames()
            if games.isEmpty {
                print("No Steam, Battle.net, Epic, or GOG games found in CrossOver bottles.")
            } else {
                for g in games {
                    switch g.kind {
                    case .steam(let appID): print("[\(g.bottleName)] \(g.title) (Steam \(appID))")
                    case .battleNet, .epicLauncher, .gogGalaxy: print("[\(g.bottleName)] \(g.title)")
                    }
                }
            }
        case "launch":
            let bottleName = arg(1, "bottle")
            let rawID = arg(2, "Steam App ID or battlenet")
            let games = CrossOverSupport.discoverBottleGames()
            let item: CrossOverBottleLaunchItem?
            if rawID.lowercased() == "battlenet" {
                item = games.first { $0.bottleName == bottleName && $0.kind == .battleNet }
            } else if let appID = SteamStore.parseAppID(rawID) {
                item = games.first { $0.bottleName == bottleName && $0.kind == .steam(appID: appID) }
            } else {
                fail("expected a numeric Steam App ID or 'battlenet'")
            }
            guard let target = item else { fail("game \(rawID) not found in CrossOver bottle '\(bottleName)'") }
            print("Launching \(target.title) from CrossOver bottle '\(target.bottleName)'…")
            let proc = try CrossOverSupport.launch(item: target)
            proc.waitUntilExit()
            exit(proc.terminationStatus)
        case "adopt":
            let bottleName = arg(1, "bottle")
            guard let appID = SteamStore.parseAppID(arg(2, "Steam App ID")) else { fail("expected a numeric Steam App ID") }
            guard let target = CrossOverSupport.discoverBottleGames().first(where: {
                $0.bottleName == bottleName && $0.kind == .steam(appID: appID)
            }) else { fail("Steam game \(appID) not found in CrossOver bottle '\(bottleName)'") }
            let profile = try gameport.adoptCrossOverBottleGame(target) { print($0) }
            print("Profile \(profile.id) on \(profile.engineID). Play it with: \(cli) play \(profile.id)")
        default:
            fail(usage)
        }

    case "epic":
        let action = args.first ?? "status"
        switch action {
        case "status":
            let e = gameport.epic
            print("Epic Games (legendary \(EpicStorefront.version)): \(e.isInstalled ? "installed" : "not installed (`\(cli) epic install`)")")
            if e.isInstalled {
                print("  Signed in: \(e.isSignedIn ? (e.accountDisplayName() ?? "yes") : "no (open \(EpicStorefront.loginURL.absoluteString), then `\(cli) epic login <code>`)")")
            }
        case "install":
            let bin = try await gameport.epic.install(progress: progress)
            print("✓ Installed legendary at \(bin.path)")
            print("  Next: open \(EpicStorefront.loginURL.absoluteString) and run `\(cli) epic login <authorizationCode>`")
        case "login":
            try gameport.epic.authenticate(authorizationCode: arg(1, "authorizationCode"))
            print("✓ Signed in to Epic Games\(gameport.epic.accountDisplayName().map { " as \($0)" } ?? "").")
        case "logout":
            try gameport.epic.signOut()
            print("✓ Signed out of Epic Games.")
        case "list":
            let games = try gameport.epic.listGames()
            if games.isEmpty { print("No Epic Games titles found.") }
            for g in games {
                print("\(g.isInstalled ? "[installed]" : "[owned]    ") \(g.appID)  \(g.title)")
            }
        case "download":
            let app = arg(1, "appName")
            let dir = try await gameport.epic.download(appName: app, progress: progress)
            print("✓ Downloaded \(app) into \(dir.path)")
        case "launch":
            let app = arg(1, "appName")
            let games = try gameport.epic.listGames(includeUninstalled: false)
            guard let game = games.first(where: { $0.appID == app || $0.title.caseInsensitiveCompare(app) == .orderedSame }) else {
                fail("installed Epic game '\(app)' not found")
            }
            let proc = try gameport.launchStorefrontGame(game, progress: progress)
            proc.waitUntilExit()
            exit(proc.terminationStatus)
        default: fail(usage)
        }

    case "gog":
        let action = args.first ?? "status"
        switch action {
        case "status":
            let g = gameport.gog
            print("GOG (gogdl \(GOGStorefront.version)): \(g.isInstalled ? "installed" : "not installed (`\(cli) gog install`)")")
            if g.isInstalled {
                print("  Signed in: \(g.isSignedIn ? "yes" : "no (open \(GOGStorefront.loginURL.absoluteString), then `\(cli) gog login <code>`)")")
            }
            print("  Installed games: \(g.listInstalled().count)")
        case "install":
            let bin = try await gameport.gog.install(progress: progress)
            print("✓ Installed gogdl at \(bin.path)")
            print("  Next: open \(GOGStorefront.loginURL.absoluteString) and run `\(cli) gog login <code>`")
        case "login":
            try gameport.gog.authenticate(authorizationCode: arg(1, "code"))
            print("✓ Signed in to GOG.")
        case "logout":
            gameport.gog.signOut()
            print("✓ Signed out of GOG.")
        case "list":
            let games = gameport.gog.listInstalled()
            if games.isEmpty { print("No GOG games installed in \(gameport.gog.gamesDir.path).") }
            for g in games {
                print("[\(g.appID)] \(g.title)  \(g.installPath?.path ?? "")")
            }
        case "download":
            let id = arg(1, "gameID")
            let dir = try await gameport.gog.download(gameID: id, progress: progress)
            print("✓ Downloaded GOG game \(id) into \(dir.path)")
        case "launch":
            let id = arg(1, "gameID")
            let games = gameport.gog.listInstalled()
            guard let game = games.first(where: { $0.appID == id || $0.title.caseInsensitiveCompare(id) == .orderedSame }) else {
                fail("installed GOG game '\(id)' not found")
            }
            let proc = try gameport.launchStorefrontGame(game, progress: progress)
            proc.waitUntilExit()
            exit(proc.terminationStatus)
        default: fail(usage)
        }

    case "heroic":
        let games = HeroicDiscovery.scan()
        if games.isEmpty {
            print("Heroic Games Launcher: no installed Epic/GOG/Amazon games detected.")
        } else {
            print("Heroic Games Launcher: \(games.count) installed game(s):")
            for g in games {
                print("  • [\(g.store.displayName)] \(g.title) (\(g.appID)) — \(g.installPath?.path ?? "")")
            }
        }

    case "external":
        let env = ExternalDiscovery.scan()
        if args.first == "owned" {
            let games = env.macSteamOwnedGames.filter { $0.isGameType && !$0.supportsMacOS }
            print("\(games.count) Windows-only games owned in Mac Steam:")
            for g in games.sorted(by: { ($0.title ?? "") < ($1.title ?? "") }) {
                let recipe = gameport.catalog.recipe(steamAppID: g.appID)
                let ac = AntiCheatDB.bundled.entry(steamAppID: g.appID)
                let acText = ac.map { "\($0.macVerdict.rawValue): \($0.antiCheats.joined(separator: ", "))" } ?? "none known"
                print("  \(g.appID)\t\(g.title ?? recipe?.title ?? "?")\t[recipe: \(recipe?.status.rawValue ?? "none")] [anti-cheat: \(acText)]")
            }
            break
        }
        print("Obelisk:    \(env.obeliskApp?.path ?? "not installed (\(ExternalEnvironment.obeliskWebsite))")")
        print("Siliconium: \(env.siliconiumApp?.path ?? "not installed (\(ExternalEnvironment.siliconiumWebsite))")")
        print("CrossOver:  \(env.crossoverApp?.path ?? "not installed") (\(env.crossoverBottles.count) bottles)")
        for b in env.crossoverBottles {
            print("  • bottle \(b.name): \(b.steamGames.count) Steam games")
        }
        print("Mac Steam: \(env.macSteamApp?.path ?? "not installed") (\(env.macSteamGames.count) installed, \(env.macSteamOwnedGames.count) owned in localconfig\(env.notProtonInstalled ? ", NotProton/Bridgeplay detected" : ""))")
        for g in env.macSteamGames.prefix(15) {
            print("  • \(g.name) (\(g.appID))")
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
