import Foundation

/// Live Play launch progress surfaced in the UI without requiring the Lab.
public enum LaunchState: Equatable, Sendable {
    case idle
    case startingSteam(profileID: String)
    case waitingForGame(profileID: String, title: String)
    /// Windows Steam is working towards starting the game (stage read from Steam's logs).
    case preparing(profileID: String, progress: LaunchProgress)
    /// The game exited; Windows Steam (started hidden for it) is shutting down.
    case closing(profileID: String)
    case running(profileID: String, seconds: Int, fps: Double?)
    case needsAttention(profileID: String, diagnosis: LaunchDiagnosis)
}

extension LaunchState {
    /// The profile this state belongs to, if any.
    public var profileID: String? {
        switch self {
        case .idle: return nil
        case .startingSteam(let id), .waitingForGame(let id, _), .preparing(let id, _),
             .running(let id, _, _), .needsAttention(let id, _), .closing(let id):
            return id
        }
    }

    /// True while a launch is under way but the game is not running yet.
    public var isLaunching: Bool {
        switch self {
        case .startingSteam, .waitingForGame, .preparing: return true
        default: return false
        }
    }
}

/// A Play launch on its way through Windows Steam.
public struct LaunchProgress: Equatable, Sendable {
    public var title: String
    public var stage: SteamLaunchStage
    /// Seconds since Play was pressed.
    public var seconds: Int
    /// Seconds without any new step from Steam.
    public var secondsWithoutProgress: Int
    /// Steam is waiting for an answer in its hidden window (readable description).
    public var waitingForUser: String?
    /// Steam reported the launch failed.
    public var steamFailed: Bool

    /// Long enough without a new step that the user should be offered to look at Steam.
    public var looksStuck: Bool { waitingForUser != nil || steamFailed || (stage != .updatingGame && secondsWithoutProgress >= 75) }

    public init(title: String, stage: SteamLaunchStage, seconds: Int, secondsWithoutProgress: Int, waitingForUser: String? = nil, steamFailed: Bool = false) {
        self.title = title
        self.stage = stage
        self.seconds = seconds
        self.secondsWithoutProgress = secondsWithoutProgress
        self.waitingForUser = waitingForUser
        self.steamFailed = steamFailed
    }
}

/// Safe, 1-click recovery actions derived deterministically from crash/launch logs.
public struct RecoveryAction: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case switchRenderer(Renderer)
        case switchVulkan(VulkanDriver)
        case applyRecipeConfig
        case applyWineDefault(ConfigPatcher.WineDefault)
        case enableAVX
        case restoreSnapshot(String)
    }

    public var id: String
    public var title: String
    public var detail: String
    public var kind: Kind

    public init(id: String, title: String, detail: String, kind: Kind) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
    }
}

public struct LaunchDiagnosis: Equatable, Sendable {
    public var headline: String
    public var explanation: String
    public var actions: [RecoveryAction]
}

/// Deterministic self-healing advisor: turns raw Wine/Steam/Vulkan failures into safe 1-click fixes.
public enum SelfHealing {
    public static func diagnose(
        profile: Profile,
        recipe: Recipe?,
        crashSigns: [String],
        logText: String,
        snapshots: [Snapshot] = [],
        hasD3DMetalLicense: Bool = false,
        availableRenderers: Set<Renderer> = [.dxmt, .d3dmetal, .dxvk, .wined3d]
    ) -> LaunchDiagnosis {
        let lowerLog = logText.lowercased()
        let lowerSigns = crashSigns.map { $0.lowercased() }
        let currentRenderer = profile.renderer ?? recipe?.renderer ?? .dxmt
        let currentVulkan = profile.vulkanDriver ?? .moltenvk

        var headline = "Game exited unexpectedly"
        var explanation = crashSigns.first ?? "The game stopped shortly after launch."
        var actions: [RecoveryAction] = []

        func add(_ action: RecoveryAction) {
            if !actions.contains(where: { $0.kind == action.kind }) { actions.append(action) }
        }

        // 1. KosmicKrisp experimental Vulkan driver issue -> switch back to MoltenVK first
        if currentVulkan == .kosmickrisp && (lowerLog.contains("kosmickrisp") || lowerLog.contains("vk_error") || lowerSigns.contains(where: { $0.contains("vulkan") || $0.contains("exception") })) {
            headline = "Experimental KosmicKrisp driver failed"
            explanation = "The game crashed while using KosmicKrisp. Switching Vulkan back to MoltenVK usually fixes this."
            add(RecoveryAction(id: "vk-mvk", title: "Switch Vulkan back to MoltenVK", detail: "Use the standard stable Vulkan driver.", kind: .switchVulkan(.moltenvk)))
        }

        // 2. DXVK D3D11 pipeline-statistics crash on MoltenVK -> switch to DXMT
        if lowerLog.contains("vkresetquerypoolext") || lowerLog.contains("pipelinestatistics") || lowerSigns.contains(where: { $0.contains("query") }) {
            headline = "DXVK hit an unsupported MoltenVK query"
            explanation = "Stock DXVK crashes on D3D11 pipeline-statistics queries on MoltenVK. DXMT translates D3D11 directly to Metal."
            if currentRenderer != .dxmt && availableRenderers.contains(.dxmt) {
                add(RecoveryAction(id: "r-dxmt", title: "Switch renderer to DXMT", detail: "Avoids the MoltenVK D3D11 query crash.", kind: .switchRenderer(.dxmt)))
            }
        }

        // 3. Missing AVX CPU instruction flag -> advertise AVX under Rosetta
        let avxEnabled = (profile.environment["ROSETTA_ADVERTISE_AVX"] == "1") || (recipe?.advertiseAVX == true)
        if !avxEnabled && (lowerLog.contains("0xc000001d") || lowerLog.contains("illegal instruction") || lowerLog.contains("avx")) {
            headline = "Game requires AVX CPU support"
            explanation = "The game checked for AVX instructions, which Rosetta hides unless explicitly enabled."
            add(RecoveryAction(id: "avx-on", title: "Enable Rosetta AVX support", detail: "Sets ROSETTA_ADVERTISE_AVX=1 for this profile.", kind: .enableAVX))
        }

        // 4. Steam CEF GPU crash loop -> DXVK's dxgi/d3d11 often breaks Steam's browser UI
        if lowerSigns.contains(where: { $0.contains("steam's gpu process") }) {
            headline = "Steam's GPU helper crashed"
            explanation = "Windows Steam failed to draw its window before launching the game."
            if currentRenderer == .dxvk && availableRenderers.contains(.dxmt) {
                add(RecoveryAction(id: "r-dxmt-steam", title: "Switch renderer to DXMT", detail: "Keeps Steam's UI stable on Metal.", kind: .switchRenderer(.dxmt)))
            }
        }

        // 5. D3D12 failure while on DXMT/DXVK -> suggest D3DMetal
        if (lowerLog.contains("d3d12") || lowerLog.contains("dx12") || lowerLog.contains("shader model")) &&
            currentRenderer != .d3dmetal && hasD3DMetalLicense && availableRenderers.contains(.d3dmetal) {
            headline = "DirectX 12 initialization failed"
            explanation = "This game appears to need DirectX 12 features best supported by Apple's D3DMetal."
            add(RecoveryAction(id: "r-d3dm", title: "Switch renderer to D3DMetal", detail: "Best compatibility for DirectX 12 games.", kind: .switchRenderer(.d3dmetal)))
        }

        // 6. Missing Visual C++ / bad-driver / recipe config defaults
        if recipe?.configDefaults != nil {
            add(RecoveryAction(id: "cfg-recipe", title: "Apply missing recipe settings", detail: "Adds known Mac INI/registry fixes without overwriting your saves.", kind: .applyRecipeConfig))
        }

        // 7. Offer sensible fallback renderers
        let fallbackOrder: [Renderer] = currentRenderer == .dxmt ? [.d3dmetal, .dxvk] : [.dxmt, .d3dmetal, .dxvk]
        for candidate in fallbackOrder where candidate != currentRenderer && availableRenderers.contains(candidate) {
            if candidate == .d3dmetal && !hasD3DMetalLicense { continue }
            add(RecoveryAction(id: "r-\(candidate.rawValue)", title: "Try \(candidate.rawValue.uppercased()) renderer", detail: candidate.displayName, kind: .switchRenderer(candidate)))
            if actions.count >= 3 { break }
        }

        // 8. OpenGL display capture fallback if relevant
        if lowerLog.contains("wgl") || lowerLog.contains("opengl") {
            add(RecoveryAction(id: "wine-gl", title: "Apply OpenGL safe display preset", detail: "Disables macOS fullscreen display capture.", kind: .applyWineDefault(.openGL)))
        }

        // 9. Snapshot rollback safety net
        if let latest = snapshots.first {
            add(RecoveryAction(id: "snap-\(latest.name)", title: "Roll back to snapshot \(latest.name)", detail: "Restores this profile to its last known good state.", kind: .restoreSnapshot(latest.name)))
        }

        return LaunchDiagnosis(headline: headline, explanation: explanation, actions: actions)
    }
}

extension GamePort {
    /// Watches a live Play launch: reports Windows Steam's launch steps (from its logs) with timings,
    /// flags a launch that waits on a hidden Steam prompt or stops progressing, follows the running
    /// game until it exits, and returns a Self-Healing diagnosis on an early crash.
    public func monitorLaunch(
        profile: Profile,
        recipe: Recipe,
        cefStart: UInt64,
        bootstrapStart: UInt64,
        marks: SteamLaunchLogMarks? = nil,
        closeSteamWhenGameExits: Bool = false,
        onState: @escaping @Sendable (LaunchState) -> Void
    ) async {
        let gameLog = profiles.logs(profile.id).appendingPathComponent("game.log")
        let fpsLog = profiles.logs(profile.id).appendingPathComponent("play-fps.log")
        let steamLogs = (try? steam(for: profile.id).logs)
        let cefLog = steamLogs?.appendingPathComponent("cef_log.txt")
        let bootstrapLog = steamLogs?.appendingPathComponent("bootstrap_log.txt")
        let consoleLog = steamLogs?.appendingPathComponent("console_log.txt")
        let connectionLog = steamLogs?.appendingPathComponent("connection_log.txt")
        let contentLog = steamLogs?.appendingPathComponent("content_log.txt")
        // Without marks taken before Play, start from the logs' current ends (never from old launches).
        let marks: SteamLaunchLogMarks = marks ?? {
            var m = steamLaunchLogMarks(profile.id)
            m.cef = cefStart
            m.bootstrap = bootstrapStart
            return m
        }()
        let appID = recipe.steamAppID ?? -1
        let hasGPTK = licenses.isAccepted("apple-gptk")
        let startedAt = Date()
        var lastProgressAt = startedAt
        var lastSnapshot = SteamLaunchSnapshot()
        var gameStart: Date?
        var missedPolls = 0

        onState(.preparing(profileID: profile.id, progress: LaunchProgress(title: recipe.title, stage: .startingSteam, seconds: 0, secondsWithoutProgress: 0)))

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(gameStart == nil ? 1 : 3))
            if Task.isCancelled { return }
            let ps = (try? Shell.run("/bin/ps", ["-axo", "pid=,command="], check: false).output) ?? ""
            let active = LabResult.gameProcessIDs(inProcessList: ps)
            let now = Date()

            if active.isEmpty, gameStart != nil, missedPolls < 1 {
                // One missing sample is not an exit (process lists can race with Wine re-execs).
                missedPolls += 1
                continue
            }
            if !active.isEmpty {
                missedPolls = 0
                if gameStart == nil { gameStart = now }
                let secs = Int(now.timeIntervalSince(gameStart!))
                let liveFPS = (try? String(contentsOf: fpsLog, encoding: .utf8))
                    .flatMap { TelemetryStore.parsePlayFPSLog($0, steadyAfter: 5)?.avgFPS }
                onState(.running(profileID: profile.id, seconds: secs, fps: liveFPS))
            } else if let start = gameStart {
                let played = now.timeIntervalSince(start)
                // Only this launch's part of game.log, and only real crash evidence: quitting a
                // game quickly is not a crash.
                let logText = GamePort.tail(of: gameLog, from: marks.game)
                let cefText = cefLog.map { GamePort.tail(of: $0, from: marks.cef) } ?? ""
                let bootText = bootstrapLog.map { GamePort.tail(of: $0, from: marks.bootstrap) } ?? ""
                let signs = LabTriage.findings(game: logText, cef: cefText, bootstrap: bootText, gameExited: false)
                if played < 60 && !signs.isEmpty {
                    let snaps = profiles.listSnapshots(profile.id)
                    let diag = SelfHealing.diagnose(profile: profile, recipe: recipe, crashSigns: signs, logText: logText, snapshots: snaps, hasD3DMetalLicense: hasGPTK)
                    onState(.needsAttention(profileID: profile.id, diagnosis: diag))
                } else if closeSteamWhenGameExits {
                    // Windows Steam was started hidden just for this game: close it (it finishes
                    // Steam Cloud sync first) so no Wine processes stay behind.
                    onState(.closing(profileID: profile.id))
                    try? steam(for: profile.id).shutdown(within: 45)
                    onState(.idle)
                } else {
                    onState(.idle)
                }
                return
            } else {
                let snapshot = SteamLaunchProgress.parse(
                    appID: appID,
                    console: consoleLog.map { GamePort.tail(of: $0, from: marks.console) } ?? "",
                    connection: connectionLog.map { GamePort.tail(of: $0, from: marks.connection) } ?? "",
                    content: contentLog.map { GamePort.tail(of: $0, from: marks.content) } ?? ""
                )
                if snapshot != lastSnapshot {
                    lastSnapshot = snapshot
                    lastProgressAt = now
                }
                let stalled = now.timeIntervalSince(lastProgressAt)
                let progress = LaunchProgress(
                    title: recipe.title,
                    stage: snapshot.stage,
                    seconds: Int(now.timeIntervalSince(startedAt)),
                    secondsWithoutProgress: Int(stalled),
                    waitingForUser: snapshot.waitingForUser.map(SteamLaunchProgress.describePrompt),
                    steamFailed: snapshot.failed
                )
                // Give up only when Steam itself has stopped moving for a long time (updates can run for ages).
                let giveUp = snapshot.failed ? stalled >= 20
                    : (snapshot.waitingForUser == nil && snapshot.stage != SteamLaunchStage.updatingGame && stalled >= 180)
                if giveUp {
                    let logText = GamePort.tail(of: gameLog, from: marks.game)
                    let cefText = cefLog.map { GamePort.tail(of: $0, from: marks.cef) } ?? ""
                    let bootText = bootstrapLog.map { GamePort.tail(of: $0, from: marks.bootstrap) } ?? ""
                    let signs = LabTriage.findings(game: logText, cef: cefText, bootstrap: bootText, gameExited: false)
                    let reason = snapshot.failed
                        ? "Windows Steam reported that the launch failed"
                        : "Windows Steam stopped at \"\(snapshot.stage.title)\" and the game never started"
                    let diag = SelfHealing.diagnose(
                        profile: profile, recipe: recipe,
                        crashSigns: signs.isEmpty ? [reason] : signs,
                        logText: logText, snapshots: profiles.listSnapshots(profile.id), hasD3DMetalLicense: hasGPTK
                    )
                    onState(.needsAttention(profileID: profile.id, diagnosis: diag))
                    return
                }
                onState(.preparing(profileID: profile.id, progress: progress))
            }
        }
    }

    /// Applies a single 1-click self-healing recovery action to a profile.
    @discardableResult
    public func applyRecovery(_ kind: RecoveryAction.Kind, to profileID: String, progress: ProgressHandler? = nil) throws -> String {
        switch kind {
        case .switchRenderer(let renderer):
            var profile = try profiles.load(profileID)
            profile.renderer = renderer
            try profiles.save(profile)
            return "Switched \(profileID) to \(renderer.displayName)"
        case .switchVulkan(let driver):
            var profile = try profiles.load(profileID)
            profile.vulkanDriver = driver == .moltenvk ? nil : driver
            try profiles.save(profile)
            return "Switched Vulkan driver to \(driver.displayName)"
        case .applyRecipeConfig:
            try applyConfigDefaults(profileID, progress: progress)
            return "Applied missing recipe settings"
        case .applyWineDefault(let preset):
            try applyWineDefault(preset, to: profileID)
            return "Applied \(preset.rawValue) defaults"
        case .enableAVX:
            var profile = try profiles.load(profileID)
            profile.environment["ROSETTA_ADVERTISE_AVX"] = "1"
            try profiles.save(profile)
            return "Enabled ROSETTA_ADVERTISE_AVX=1 for \(profileID)"
        case .restoreSnapshot(let name):
            _ = try restore(profileID, snapshot: name)
            return "Restored snapshot \(name)"
        }
    }

    /// Builds a privacy-redacted diagnostic report suitable for pasting into GitHub issues or sharing.
    public func diagnosticReport(profileID: String, diagnosis: LaunchDiagnosis? = nil) -> String {
        let profile = try? profiles.load(profileID)
        let recipe = profile?.recipeID.flatMap { catalog[$0] }
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        let userName = NSUserName()
        func redact(_ s: String) -> String {
            var out = s.replacingOccurrences(of: userHome, with: "~")
            if !userName.isEmpty { out = out.replacingOccurrences(of: "/Users/\(userName)", with: "/Users/<redacted>") }
            return out
        }

        var lines: [String] = [
            "### \(Brand.displayName) Diagnostic Report",
            "- **Hardware:** \(Shell.machineDescription) (\(TelemetryReport.currentRAMGB()) GB RAM)",
            "- **macOS:** \(Shell.macOSVersionString)",
            "- **Game:** \(recipe?.title ?? profile?.title ?? profileID) (Steam AppID: \(recipe?.steamAppID.map(String.init) ?? "n/a"))",
            "- **Engine:** \(profile?.engineID ?? "unknown")",
            "- **Renderer / Sync:** \((profile?.renderer ?? recipe?.renderer ?? .dxmt).rawValue) / \((profile?.sync ?? recipe?.sync ?? .msync).rawValue)",
            "- **Performance Pack:** P-cores=\((profile?.performanceCores ?? true) ? "on" : "off"), Retina=\(profile?.retinaMode.map { $0 ? "HiDPI" : "1x" } ?? "auto"), MetalFX=\(profile?.metalFX == true ? "on" : "off"), Runner=\((profile?.executionRunner ?? .rosetta).rawValue)",
        ]
        if let diagnosis {
            lines.append("- **Diagnosis:** \(diagnosis.headline) — \(diagnosis.explanation)")
        }
        let gameLog = profiles.logs(profileID).appendingPathComponent("game.log")
        if let raw = try? String(contentsOf: gameLog, encoding: .utf8), !raw.isEmpty {
            let tail = raw.split(whereSeparator: \.isNewline).suffix(50).joined(separator: "\n")
            lines.append("\n#### Last 50 lines of game.log\n```text\n\(redact(tail))\n```")
        }
        return lines.joined(separator: "\n")
    }
}
