import Foundation

/// One line of "What this game uses": a short label, the value in use, a sentence on why it matters,
/// and where the value came from.
public struct SetupLine: Sendable, Equatable, Identifiable {
    public enum Origin: String, Sendable, Equatable {
        /// Fixed by GamePort for every game.
        case gameport
        /// Set by the game's recipe.
        case recipe
        /// Changed by the player in Options.
        case player
        /// From other players' reports (`CommunityAdvice`).
        case community
        /// Changed by GamePort itself after a crash (`AutoFix`).
        case autoFix
    }

    public var label: String
    public var value: String
    public var why: String
    public var origin: Origin

    public var id: String { label + "|" + value }

    public init(_ label: String, _ value: String, why: String, origin: Origin) {
        self.label = label; self.value = value; self.why = why; self.origin = origin
    }
}

/// The plain-language summary of how a profile runs its game, so a player can see what GamePort and
/// the game's recipe changed without reading JSON.
public struct GameSetup: Sendable, Equatable {
    /// The basics every game has: engine, CPU translation, graphics, sync.
    public var basics: [SetupLine]
    /// Everything the recipe or the player changed beyond the basics (fixes, environment, registry…).
    public var tweaks: [SetupLine]
    /// The recipe's notes, in its own words.
    public var notes: [String]
    public var knownIssues: [Recipe.KnownIssue]
    /// How sure we are that the game works.
    public var status: Recipe.Status?
    /// Where the recipe came from (our own test, the community catalog…), in plain words.
    public var source: String?

    public static func describe(_ runner: WineRunner) -> GameSetup {
        let profile = runner.profile
        let recipe = runner.recipe
        let engine = runner.engine.manifest

        var basics: [SetupLine] = []
        let isCrossOver = engine.id == CrossOverInstallation.engineID
        basics.append(SetupLine(
            "Engine", shortName(engine.displayName),
            why: isCrossOver
                ? "Your CrossOver app's Wine. It turns the game's Windows calls into macOS ones."
                : "Wine, the layer that turns the game's Windows calls into macOS ones. Each game gets its own copy of Windows; the engine itself is shared and never changed.",
            origin: .gameport))

        let cpu: String
        let cpuWhy: String
        switch runner.effectiveExecutionRunner {
        case .rosetta where engine.requiresRosetta:
            cpu = "Rosetta 2"
            cpuWhy = "The game is built for Intel processors. Apple's Rosetta translates it for Apple silicon."
        case .rosetta:
            cpu = "Native Apple silicon"
            cpuWhy = "This engine runs directly on Apple silicon."
        case .aarchx, .aarchxFEX:
            cpu = runner.effectiveExecutionRunner.displayName
            cpuWhy = "An experimental translator that runs Intel code without Rosetta."
        }
        basics.append(SetupLine("Processor", cpu, why: cpuWhy,
                                origin: profile.executionRunner == nil ? .gameport : .player))

        let renderer = runner.effectiveRenderer
        let fixes = AutoFixStore(paths: runner.paths).fixes(profile.id).filter { $0.state != .undone }
        let rendererFix = fixes.first { !["vk-mvk", "avx-on"].contains($0.actionID) }
        if profile.renderer != nil, let rendererFix {
            basics.append(SetupLine("Graphics", rendererName(renderer),
                                    why: rendererWhy(renderer) + " GamePort switched to it after a problem: \(rendererFix.reason).",
                                    origin: .autoFix))
        } else if profile.renderer == nil, let community = recipe?.community {
            basics.append(SetupLine("Graphics", rendererName(renderer),
                                    why: rendererWhy(renderer) + " " + community.summary, origin: .community))
        } else {
            basics.append(SetupLine("Graphics", rendererName(renderer), why: rendererWhy(renderer),
                                    origin: profile.renderer != nil ? .player : (recipe != nil ? .recipe : .gameport)))
        }

        if runner.effectiveVulkanDriver != .moltenvk || renderer == .dxvk {
            basics.append(SetupLine("Vulkan driver", runner.effectiveVulkanDriver.displayName,
                                    why: "Translates Vulkan to Metal for the graphics layer above.",
                                    origin: profile.vulkanDriver == nil ? .gameport : .player))
        }

        let sync = runner.effectiveSync
        basics.append(SetupLine("Thread sync", syncName(sync), why: syncWhy(sync),
                                origin: profile.sync != nil ? .player : (recipe != nil ? .recipe : .gameport)))

        var tweaks: [SetupLine] = []
        let avx = profile.advertiseAVX ?? recipe?.advertiseAVX ?? false
        if avx {
            tweaks.append(SetupLine("AVX", engine.requiresRosetta ? "Reported to the game" : "Not available on this engine",
                                    why: "Some games refuse to start unless the processor says it supports AVX. Rosetta can run AVX code, so GamePort tells the game it is there.",
                                    origin: profile.advertiseAVX != nil ? .player : .recipe))
        }
        if runner.effectivePerformanceCores {
            tweaks.append(SetupLine("Performance cores", "On",
                                    why: "The game runs on the Mac's fast cores, not the efficiency cores.",
                                    origin: profile.performanceCores == nil ? .gameport : .player))
        }
        if profile.metalFX == true {
            tweaks.append(SetupLine("MetalFX", "On", why: "Renders at a lower resolution and upscales it with Apple's MetalFX for more frames.", origin: .player))
        }
        if let retina = profile.retinaMode {
            tweaks.append(SetupLine("Resolution", retina ? "Retina" : "Native 1×",
                                    why: retina ? "Uses every pixel of a Retina screen. Sharper, slower." : "Draws at 1× on Retina screens. Faster, slightly softer.",
                                    origin: .player))
        }
        if profile.x87Acceleration == true {
            tweaks.append(SetupLine("x87 acceleration", "On", why: "Speeds up the old floating-point maths many 32-bit and DirectX 9 games use.", origin: .player))
        }
        if profile.metalHUD {
            tweaks.append(SetupLine("Metal HUD", "On", why: "Shows the frame rate on screen.", origin: .player))
        }
        if let recipe {
            if let overrides = recipe.dllOverrides, !overrides.isEmpty {
                tweaks.append(SetupLine("Windows libraries", overrides,
                                        why: "Tells Wine to use the game's own copy of these DLLs, or Wine's built-in one, where the other breaks the game.",
                                        origin: .recipe))
            }
            for key in recipe.environment.keys.sorted() {
                tweaks.append(SetupLine("Setting", "\(key)=\(recipe.environment[key] ?? "")",
                                        why: environmentWhy(key), origin: .recipe))
            }
            for value in recipe.registry {
                let name = value.name.isEmpty ? "(default)" : value.name
                tweaks.append(SetupLine("Windows registry", "\(shortKey(value.key)) › \(name) = \(value.data)",
                                        why: "A Windows setting written into this game's own Windows copy before it starts.",
                                        origin: .recipe))
            }
            if !recipe.launchArguments.isEmpty {
                tweaks.append(SetupLine("Launch options", recipe.launchArguments.joined(separator: " "),
                                        why: "Passed to the game when it starts, like Steam's launch options.",
                                        origin: .recipe))
            }
            if recipe.launch == .direct {
                tweaks.append(SetupLine("Start", "Game's own program",
                                        why: "Steam's normal start adds a step that cannot run under Wine, so the game is started directly with Steam in the background.",
                                        origin: .recipe))
            }
        }
        for key in profile.environment.keys.sorted() {
            tweaks.append(SetupLine("Setting", "\(key)=\(profile.environment[key] ?? "")",
                                    why: environmentWhy(key), origin: .player))
        }

        return GameSetup(basics: basics, tweaks: tweaks,
                         notes: recipe?.notes ?? [],
                         knownIssues: recipe?.knownIssues ?? [],
                         status: recipe?.status,
                         source: recipe.map(sourceText))
    }

    // MARK: - Plain-language texts

    public static func rendererName(_ r: Renderer) -> String {
        switch r {
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .d3dmetal: return "D3DMetal"
        case .wined3d: return "WineD3D"
        }
    }

    public static func rendererWhy(_ r: Renderer) -> String {
        switch r {
        case .dxmt: return "Turns the game's DirectX 10/11 graphics straight into Apple's Metal. Usually the fastest for DirectX 11 games."
        case .dxvk: return "Turns DirectX 9/10/11 into Vulkan, then Metal. Most compatible with older games, a little slower."
        case .d3dmetal: return "Apple's own DirectX 11/12 to Metal translator from the Game Porting Toolkit. Needed for most DirectX 12 games."
        case .wined3d: return "Wine's built-in OpenGL translator. Slowest; used when nothing else draws the game."
        }
    }

    static func syncName(_ s: SyncMode) -> String {
        switch s {
        case .msync: return "MSync"
        case .esync: return "ESync"
        case .none: return "Off"
        }
    }

    static func syncWhy(_ s: SyncMode) -> String {
        switch s {
        case .msync: return "Fast thread coordination built on macOS's own primitives. Smoother frame times."
        case .esync: return "Older fast thread coordination. Used when MSync makes this game stutter or hang."
        case .none: return "Wine's slow but safest thread coordination. Used when the faster ones crash this game."
        }
    }

    static func environmentWhy(_ key: String) -> String {
        let known: [String: String] = [
            "DXMT_METALFX_SPATIAL_SWAPCHAIN": "Upscales the picture with MetalFX.",
            "DXVK_ASYNC": "Compiles shaders in the background to avoid stutter.",
            "DXVK_HUD": "Shows DXVK's on-screen statistics.",
            "MTL_HUD_ENABLED": "Shows Apple's Metal performance HUD.",
            "WINEDLLOVERRIDES": "Chooses between the game's own DLLs and Wine's built-in ones.",
            "ROSETTA_ADVERTISE_AVX": "Tells the game the processor supports AVX.",
            "D3DM_SUPPORT_DXR": "Turns on ray tracing in D3DMetal.",
            "D3DM_ENABLE_METALFX": "Lets D3DMetal upscale with MetalFX.",
            "WINE_LARGE_ADDRESS_AWARE": "Lets a 32-bit game use more than 2 GB of memory.",
            "MVK_CONFIG_RESUME_LOST_DEVICE": "Keeps MoltenVK going after a GPU hiccup instead of crashing.",
            "WINE_SIMULATE_WRITECOPY": "Handles memory the way Windows does; some launchers and anti-tamper code need it.",
            "SteamAppId": "Tells the game which Steam app it is.",
            "SteamGameId": "Tells the game which Steam app it is.",
        ]
        if let text = known[key] { return text }
        if key.hasPrefix("DXVK_") { return "A DXVK setting this game needs." }
        if key.hasPrefix("DXMT_") { return "A DXMT setting this game needs." }
        if key.hasPrefix("D3DM_") { return "A D3DMetal setting this game needs." }
        if key.hasPrefix("MVK_") { return "A MoltenVK (Vulkan to Metal) setting this game needs." }
        if key.hasPrefix("WINE") { return "A Wine setting this game needs." }
        return "An environment setting this game needs."
    }

    /// "CrossOver 26.3 (System · 0 MB)" → "CrossOver 26.3"; "Wine 11.0 (CrossOver 26.3 source) — Intel, Rosetta 2"
    /// → "Wine 11.0 (CrossOver 26.3 source)". The processor has its own line.
    public static func shortName(_ name: String) -> String {
        var short = name
        if let dash = short.range(of: " — ") { short = String(short[..<dash.lowerBound]) }
        if let paren = short.range(of: " ("), short[paren.lowerBound...].contains("MB") {
            short = String(short[..<paren.lowerBound])
        }
        short = short.trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? name : short
    }

    static func shortKey(_ key: String) -> String {
        let parts = key.split(separator: "\\")
        guard parts.count > 3 else { return key }
        return "…\\" + parts.suffix(2).joined(separator: "\\")
    }

    static func sourceText(_ recipe: Recipe) -> String {
        switch recipe.status {
        case .verified: return "Tested end to end by GamePort on a Mac."
        case .community:
            return (recipe.source ?? "").contains("highball")
                ? "From the community catalog (highball-db, CC0). Reported working by players; not yet tested by GamePort."
                : "Reported working by players; not yet tested by GamePort."
        case .untested: return "Nobody has confirmed this game yet. GamePort uses safe defaults."
        case .blocked: return "Known not to work, usually because of kernel anti-cheat."
        }
    }
}

extension GamePort {
    /// "What this game uses", in plain words, for a profile.
    public func setup(for profileID: String) throws -> GameSetup {
        GameSetup.describe(try runner(for: profileID))
    }
}
