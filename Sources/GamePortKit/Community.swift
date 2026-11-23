import Foundation

/// What other players' anonymous reports say about a game, turned into safe defaults.
///
/// Reports are anonymous, so anyone can send them. To keep a handful of fake or unlucky reports from
/// changing a game for everyone:
/// - a setup counts only when enough different Macs report it (`minMacs`) and most of them say it
///   works (`minWorkRate`);
/// - only two things can change: the renderer (never D3DMetal without Apple's licence, never on a
///   verified recipe) and whether Play prefers Windows Steam over the Bridge. Environment variables,
///   DLLs and registry values never come from the network;
/// - the player's own choice, a Lab result and an automatic fix always win;
/// - `Scripts/community-recipes.py` uses the same thresholds for the bundled recipes, through a
///   reviewed pull request.
public struct CommunityAdvice: Equatable, Sendable {
    public static let minMacs = 3
    public static let minWorkRate = 0.8
    /// The Bridge counts as failing for a game when at most this share of its reports work.
    public static let maxFailingWorkRate = 0.2

    public struct Tally: Equatable, Sendable {
        public var macs: Int
        public var reports: Int
        public var works: Int
        public var avgFPS: Double?

        public var workRate: Double { reports == 0 ? 0 : Double(works) / Double(reports) }
        public var qualifies: Bool { macs >= CommunityAdvice.minMacs && workRate >= CommunityAdvice.minWorkRate }
        public var failing: Bool { macs >= CommunityAdvice.minMacs && workRate <= CommunityAdvice.maxFailingWorkRate }
    }

    /// The renderer most Macs run the game with, when it qualifies.
    public var renderer: Renderer?
    public var rendererTally: Tally?
    /// The Bridge fails for other players while Windows Steam works.
    public var prefersWindowsSteam: Bool
    /// The problem seen most in the reports that did not work.
    public var commonProblem: String?

    /// Advice from one game's verdicts, or nil when they do not say anything sure.
    /// Only Rosetta engines with MoltenVK count: that is what every player has.
    public static func from(_ verdicts: [CommunityVerdict], allowD3DMetal: Bool) -> CommunityAdvice? {
        let usable = verdicts.filter { $0.engineArch == .rosetta && $0.vulkanDriver == .moltenvk }
        guard !usable.isEmpty else { return nil }

        var byRenderer: [Renderer: Tally] = [:]
        for v in usable { byRenderer[v.renderer] = add(byRenderer[v.renderer], v) }
        let best = byRenderer
            .filter { $0.value.qualifies && ($0.key != .d3dmetal || allowD3DMetal) }
            .max { ($0.value.macs, $0.value.avgFPS ?? 0) < ($1.value.macs, $1.value.avgFPS ?? 0) }

        var bridge: Tally?
        var windowsSteam: Tally?
        for v in usable {
            switch v.launchMethod ?? PlayRecord.Method.windowsSteam.rawValue {
            case PlayRecord.Method.bridge.rawValue: bridge = add(bridge, v)
            case PlayRecord.Method.windowsSteam.rawValue: windowsSteam = add(windowsSteam, v)
            default: break
            }
        }
        let prefersWindowsSteam = bridge?.failing == true && windowsSteam?.qualifies == true

        var problems: [String: Int] = [:]
        for v in usable { for (code, n) in v.problems ?? [:] { problems[code, default: 0] += n } }
        let common = problems.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key

        guard best != nil || prefersWindowsSteam else { return nil }
        return CommunityAdvice(renderer: best?.key, rendererTally: best?.value,
                               prefersWindowsSteam: prefersWindowsSteam, commonProblem: common)
    }

    private static func add(_ tally: Tally?, _ v: CommunityVerdict) -> Tally {
        var t = tally ?? Tally(macs: 0, reports: 0, works: 0, avgFPS: nil)
        // FPS averaged by report count; groups without FPS do not pull it down.
        if let fps = v.avgFPS {
            let weighted = (t.avgFPS ?? 0) * Double(t.reports) + fps * Double(v.reports)
            let counted = t.avgFPS == nil ? v.reports : t.reports + v.reports
            t.avgFPS = counted == 0 ? nil : weighted / Double(counted)
        }
        t.macs += v.installs ?? v.reports
        t.reports += v.reports
        t.works += v.works
        return t
    }
}

/// A recipe default that came from other players' reports, not from the recipe file.
public struct CommunityTuning: Codable, Sendable, Equatable {
    public var renderer: Renderer
    /// What the recipe file says.
    public var recipeRenderer: Renderer
    public var macs: Int
    public var workRate: Double

    /// "Other players: DXMT works on 5 Macs (100%); the recipe said DXVK."
    public var summary: String {
        "Other players: \(GameSetup.rendererName(renderer)) works on \(macs) Macs (\(Int((workRate * 100).rounded()))%); "
            + "the recipe said \(GameSetup.rendererName(recipeRenderer))."
    }
}

extension TelemetryStore {
    /// Community defaults are on unless the player turned them off (`gameport community off`) or
    /// `GAMEPORT_COMMUNITY_DEFAULTS=0` is set. They only need the downloaded results, never sharing.
    public func usesCommunityDefaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if environment["GAMEPORT_COMMUNITY_DEFAULTS"] == "0" { return false }
        return load().communityDefaults ?? true
    }

    public func setCommunityDefaults(_ on: Bool) throws {
        var settings = load()
        settings.communityDefaults = on
        try save(settings)
    }
}

extension RecipeCatalog {
    /// Puts other players' renderer into recipes that are not verified, as `CommunityTuning`.
    func withCommunityDefaults(_ verdicts: [Int: [CommunityVerdict]], allowD3DMetal: Bool) -> RecipeCatalog {
        guard !verdicts.isEmpty else { return self }
        var tuned = self
        for (id, recipe) in recipes {
            guard recipe.status == .community || recipe.status == .untested,
                  let appID = recipe.steamAppID, let list = verdicts[appID],
                  let advice = CommunityAdvice.from(list, allowD3DMetal: allowD3DMetal),
                  let renderer = advice.renderer, let tally = advice.rendererTally,
                  renderer != recipe.renderer else { continue }
            var changed = recipe
            changed.community = CommunityTuning(renderer: renderer, recipeRenderer: recipe.renderer,
                                                macs: tally.macs, workRate: tally.workRate)
            changed.renderer = renderer
            tuned.recipes[id] = changed
        }
        return tuned
    }
}

extension GamePort {
    /// What other players' reports say about a Steam game (from the last downloaded results).
    public func communityAdvice(steamAppID: Int) -> CommunityAdvice? {
        guard let list = telemetry.loadCachedVerdicts()[steamAppID] else { return nil }
        return CommunityAdvice.from(list, allowD3DMetal: licenses.isAccepted("apple-gptk"))
    }
}
