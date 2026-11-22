import Foundation

/// Live Play launch progress surfaced in the UI without requiring the Lab.
public enum LaunchState: Equatable, Sendable {
    case idle
    case startingSteam(profileID: String)
    case waitingForGame(profileID: String, title: String)
    case running(profileID: String, seconds: Int, fps: Double?)
    case needsAttention(profileID: String, diagnosis: LaunchDiagnosis)
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
    /// Watches a live Play launch, emitting stage updates and returning a Self-Healing diagnosis on crash/failure.
    public func monitorLaunch(
        profile: Profile,
        recipe: Recipe,
        cefStart: UInt64,
        bootstrapStart: UInt64,
        onState: @escaping @Sendable (LaunchState) -> Void
    ) async {
        onState(.waitingForGame(profileID: profile.id, title: recipe.title))
        let gameLog = profiles.logs(profile.id).appendingPathComponent("game.log")
        let fpsLog = profiles.logs(profile.id).appendingPathComponent("play-fps.log")
        let steamLogs = (try? steam(for: profile.id).logs)
        let cefLog = steamLogs?.appendingPathComponent("cef_log.txt")
        let bootstrapLog = steamLogs?.appendingPathComponent("bootstrap_log.txt")
        let hasGPTK = licenses.isAccepted("apple-gptk")
        let startedAt = Date()
        var gameStart: Date?

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            let ps = (try? Shell.run("/bin/ps", ["-axo", "pid=,command="], check: false).output) ?? ""
            let active = LabResult.gameProcessIDs(inProcessList: ps)
            let now = Date()

            if !active.isEmpty {
                if gameStart == nil { gameStart = now }
                let secs = Int(now.timeIntervalSince(gameStart!))
                let liveFPS = (try? String(contentsOf: fpsLog, encoding: .utf8))
                    .flatMap { TelemetryStore.parsePlayFPSLog($0, steadyAfter: 5)?.avgFPS }
                onState(.running(profileID: profile.id, seconds: secs, fps: liveFPS))
                if secs >= 120 { return }
            } else if let start = gameStart {
                let played = now.timeIntervalSince(start)
                let logText = (try? String(contentsOf: gameLog, encoding: .utf8)) ?? ""
                let cefText = cefLog.map { GamePort.tail(of: $0, from: cefStart) } ?? ""
                let bootText = bootstrapLog.map { GamePort.tail(of: $0, from: bootstrapStart) } ?? ""
                let signs = LabTriage.findings(game: logText, cef: cefText, bootstrap: bootText, gameExited: true)
                if played < 60 && !signs.isEmpty {
                    let snaps = profiles.listSnapshots(profile.id)
                    let diag = SelfHealing.diagnose(profile: profile, recipe: recipe, crashSigns: signs, logText: logText, snapshots: snaps, hasD3DMetalLicense: hasGPTK)
                    onState(.needsAttention(profileID: profile.id, diagnosis: diag))
                } else {
                    onState(.idle)
                }
                return
            } else if now.timeIntervalSince(startedAt) >= 120 {
                let logText = (try? String(contentsOf: gameLog, encoding: .utf8)) ?? ""
                let cefText = cefLog.map { GamePort.tail(of: $0, from: cefStart) } ?? ""
                let bootText = bootstrapLog.map { GamePort.tail(of: $0, from: bootstrapStart) } ?? ""
                let signs = LabTriage.findings(game: logText, cef: cefText, bootstrap: bootText, gameExited: false)
                let snaps = profiles.listSnapshots(profile.id)
                let diag = SelfHealing.diagnose(
                    profile: profile, recipe: recipe,
                    crashSigns: signs.isEmpty ? ["The game process never started within 2 minutes"] : signs,
                    logText: logText, snapshots: snaps, hasD3DMetalLicense: hasGPTK
                )
                onState(.needsAttention(profileID: profile.id, diagnosis: diag))
                return
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
}
