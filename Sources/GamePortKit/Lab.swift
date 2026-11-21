import Foundation

/// Measures a game the way a player would see it: launch through Steam, let it run, read Apple's
/// Metal HUD log (once a second, unified log subsystem com.apple.metal.hud) and decide whether it works.
///
/// When per-frame timings are redacted as <private>, only counter-based rates are available.
/// Steam's web helper renders with Metal too; lines carry the
/// process id, and the process with the most frames is taken to be the game.
public enum MetalHUDLog {
    public struct Sample: Equatable, Sendable {
        public var time: TimeInterval   // seconds since 1970
        public var pid: Int
        public var frame: Double
        public var presentIntervalsMS: [Double] = []
    }

    /// Parses `log stream --style compact` output:
    /// `2026-10-30 16:02:59.048 Df wine[82137:db3120] [com.apple.metal.hud:Logging] metal-HUD: 4,484.70,601.46<private>`
    public static func parse(_ text: String) -> [Sample] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        var samples: [Sample] = [], seen = Set<String>()
        for line in text.split(separator: "\n") where line.contains("metal-HUD:") {
            guard seen.insert(String(line)).inserted, line.count > 23,
                  let date = formatter.date(from: String(line.prefix(23))),
                  let open = line.firstIndex(of: "["), let colon = line[open...].firstIndex(of: ":"),
                  let pid = Int(line[line.index(after: open)..<colon]) else { continue }
            let payload = line[line.range(of: "metal-HUD:")!.upperBound...]
            let fields = payload.split(separator: ",", omittingEmptySubsequences: false)
            guard let first = fields.first, let frame = Double(first.trimmingCharacters(in: .whitespaces)),
                  frame.isFinite, frame >= 0, frame < Double(Int.max) else { continue }
            // Apple logs first frame, missed frames, memory, then (present interval, GPU time) in ms.
            var intervals: [Double] = []
            for index in stride(from: 3, to: fields.count - 1, by: 2) {
                if let ms = Double(fields[index].trimmingCharacters(in: .whitespaces)), ms.isFinite, ms > 0,
                   let gpu = Double(fields[index + 1].trimmingCharacters(in: .whitespaces)), gpu.isFinite, gpu >= 0 {
                    intervals.append(ms)
                }
            }
            samples.append(Sample(time: date.timeIntervalSince1970, pid: pid, frame: frame, presentIntervalsMS: intervals))
        }
        return samples
    }

    /// The process that presented the most frames.
    public static func busiestProcess(_ samples: [Sample]) -> Int? {
        let groups = Dictionary(grouping: samples, by: \.pid)
        let spans = groups.mapValues { group -> Double in
            let counters = group.map(\.frame).filter { $0 > 0 }
            return (counters.max() ?? 0) - (counters.min() ?? 0)
        }
        return spans.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key
    }
}

public struct LabStats: Codable, Sendable, Equatable {
    public var frames: Int
    public var seconds: Double
    /// Frames divided by time: the honest number, stalls included.
    public var averageFPS: Double
    /// Median of the one-second rates: what a typical second feels like.
    public var typicalFPS: Double
    public var slowestFPS: Double
    /// Gaps over 2 s, or seconds where the frame counter did not move (shader compiles, loads, hangs).
    public var stalls: Int
    public var stallSeconds: Double
    /// 1000 / nearest-rank p99 present interval in ms. Requires at least 100 timed frames.
    public var onePercentLowFPS: Double? = nil

    /// Stats for one process's samples taken at or after `after` (seconds since 1970).
    /// Frame number 0 shows up between real lines (an idle surface or a counter reset) and is skipped.
    public static func from(_ samples: [MetalHUDLog.Sample], after: TimeInterval = 0) -> LabStats? {
        let points = samples.filter { $0.time >= after && $0.frame > 0 }.sorted { $0.time < $1.time }
        var measuredFrames = 0.0, measuredSeconds = 0.0
        var rates: [(rate: Double, span: Double)] = []
        for (a, b) in zip(points, points.dropFirst()) where b.time > a.time && b.frame >= a.frame {
            let frames = b.frame - a.frame, span = b.time - a.time
            measuredFrames += frames
            measuredSeconds += span
            rates.append((frames / span, span))
        }
        guard !rates.isEmpty, measuredFrames < Double(Int.max) else { return nil }
        let stalls = rates.filter { $0.rate == 0 || $0.span > 2 }
        let sorted = rates.map(\.rate).sorted()
        func r(_ x: Double) -> Double { (x * 10).rounded() / 10 }
        let intervals = points.flatMap(\.presentIntervalsMS).sorted()
        let p99 = intervals.count >= 100 ? intervals[Int(ceil(Double(intervals.count) * 0.99)) - 1] : nil
        let low = p99.map { r(1000 / $0) }.flatMap { $0.isFinite ? $0 : nil }
        return LabStats(frames: Int(measuredFrames), seconds: r(measuredSeconds),
                        averageFPS: r(measuredFrames / measuredSeconds),
                        typicalFPS: r(sorted[sorted.count / 2]), slowestFPS: r(sorted[0]),
                        stalls: stalls.count, stallSeconds: r(stalls.map(\.span).reduce(0, +)), onePercentLowFPS: low)
    }
}

/// macOS thermal pressure sampled at launch, every Lab poll, and just before stopping the game.
public enum LabThermalState: Int, Codable, Sendable {
    case nominal, fair, serious, critical

    var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        }
    }

    static func current() -> Self? {
        #if os(macOS)
        return Self(rawValue: ProcessInfo.processInfo.thermalState.rawValue)
        #else
        return nil
        #endif
    }

    static func peak(_ samples: [Self]) -> Self? { samples.max { $0.rawValue < $1.rawValue } }
}

public struct LabResult: Codable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        case works          // still presenting new frames at the end of the run
        case stopped        // rendered, then stopped: crash, hang or a dialog
        case noFrames       // never presented a Metal frame
        case blackScreen    // the foreground game window stayed black at the end
        case unchangedImage // HUD advanced, but the image did not: an idle scene or possible freeze
        case notVisible     // another app was in front most of the time: macOS throttles a covered
                            // window's frames, so the run measured nothing either way
    }

    public var profileID: String
    public var recipeID: String?
    public var renderer: Renderer
    public var sync: SyncMode
    public var engineID: String
    public var engineArchitecture: EngineArchitecture? = nil
    public var macOS: String
    public var machine: String
    public var startedAt: Date
    public var seconds: Int
    public var verdict: Verdict
    /// After the first minute (loading, shader compiles).
    public var steady: LabStats?
    public var whole: LabStats?
    public var hudLog: String
    /// Share of the 30-second samples in which a Wine window was the frontmost app (nil in older results).
    public var frontmostShare: Double? = nil
    /// Whether the game's own process (an .exe under steamapps\common) was seen running.
    public var gameStarted: Bool? = nil
    /// Crash evidence from the run's part of game.log: page faults, stack overflows, a web-helper loop.
    public var crashSigns: [String]? = nil
    /// The Vulkan driver the game ran on (nil in older results = MoltenVK).
    public var vulkanDriver: VulkanDriver? = nil
    public var peakThermalState: LabThermalState? = nil

    /// "dxmt", or "dxmt + KosmicKrisp" when the game ran on KosmicKrisp.
    public var setup: String {
        renderer.rawValue + (vulkanDriver == .kosmickrisp ? " + KosmicKrisp" : "")
    }

    /// One-liner for the CLI, the app and recipe notes.
    public var summary: String {
        let what: String
        switch verdict {
        case .works: what = "works"
        case .stopped: what = "stopped rendering (crash or hang)"
        case .noFrames: what = "no frames"
        case .blackScreen: what = "game window stayed black"
        case .unchangedImage: what = "unchanged game image (possible freeze or idle scene); rerun during gameplay"
        case .notVisible: return "\(setup): not measured, the game window was not in front" + thermalSummary
        }
        let fps = (steady ?? whole).map { s in
            let low = s.onePercentLowFPS.map { "1% low \($0) FPS" } ?? "1% low unavailable"
            return "average \(s.averageFPS) FPS, typical \(s.typicalFPS), \(low), slowest second \(s.slowestFPS), \(s.stalls) stalls / \(s.stallSeconds) s"
        } ?? "FPS not measured"
        var why: [String] = []
        if gameStarted == false { why.append("the game process never started") }
        why += crashSigns ?? []
        let reasons = verdict == .works || why.isEmpty ? "" : " (" + why.joined(separator: "; ") + ")"
        return "\(setup): \(what)\(reasons); \(fps)" + thermalSummary
    }

    private var thermalSummary: String { peakThermalState.map { ", peak thermal state \($0.label)" } ?? "" }

    /// Classifies a run: frames must still be advancing in the last `window` seconds.
    /// A covered window only excuses missing frames when the game is not known to have failed: it never
    /// started, or the log shows a crash (a TF2 run hid a Steam web-helper crash loop this way).
    static func verdict(_ samples: [MetalHUDLog.Sample], end: TimeInterval, window: TimeInterval = 30,
                        frontmostShare: Double? = nil, gameStarted: Bool? = nil, crashSigns: [String] = [],
                        gameExited: Bool = false, visual: LabFrameFinding? = nil) -> Verdict {
        if gameStarted == false { return .noFrames }
        let measured = measuredVerdict(samples, end: end, window: window)
        if gameExited { return measured == .noFrames ? .noFrames : .stopped }
        if visual == .black { return .blackScreen }
        if visual == .unchanged, measured == .works {
            return crashSigns.isEmpty ? .unchangedImage : .stopped
        }
        if measured != .works, let share = frontmostShare, share < 0.5, gameStarted != false, crashSigns.isEmpty {
            return .notVisible
        }
        return measured
    }
}

/// Pure analysis of the log slices written during one trial. Findings are returned in a fixed order.
enum LabTriage {
    static func findings(game: String, cef: String, bootstrap: String?, gameExited: Bool) -> [String] {
        crashSigns(inLog: game) + steamCrashSigns(inCEFLog: cef, bootstrap: bootstrap)
            + (gameExited ? ["the game exited before the end"] : [])
    }

    /// Crash evidence in the part of game.log a run wrote. Steam's web helper normally starts twice;
    /// DXVK logs each start ("Game: steamwebhelper.exe"), so more than four is a crash loop.
    static func crashSigns(inLog text: String) -> [String] {
        var signs: [String] = []
        let lines = text.split(separator: "\n")
        let helperStarts = lines.filter { $0.contains("Game: steamwebhelper.exe") }.count
        if helperStarts > 4 { signs.append("Steam web helper restarted \(helperStarts) times") }
        for (needle, label) in [("Unhandled page fault", "page fault"), ("Unhandled exception", "unhandled exception"),
                                ("stack overflow", "stack overflow"),
                                ("Failed to create Vulkan", "Vulkan initialization failed"),
                                ("VK_ERROR_DEVICE_LOST", "Vulkan device lost")] {
            let n = lines.filter { $0.contains(needle) }.count
            if n > 0 { signs.append(n == 1 ? label : "\(label) ×\(n)") }
        }
        return signs
    }

    /// Crash evidence in the part of Steam's cef_log.txt a run wrote. Chromium restarts a crashed GPU
    /// process and gives up after a few tries, which leaves Steam's window black and the game unlaunched.
    /// `bootstrap` is the run's part of bootstrap_log.txt, which Steam writes to first on every start.
    static func steamCrashSigns(inCEFLog text: String, bootstrap: String? = nil) -> [String] {
        let gpuCrashes = text.split(separator: "\n").filter { $0.contains("GPU process exited unexpectedly") }.count
        if let bootstrap, !bootstrap.contains("Startup"), text.isEmpty { return ["Steam itself never started"] }
        return gpuCrashes > 1 ? ["Steam's GPU process crashed \(gpuCrashes) times"] : []
    }
}

extension LabResult {
    /// The pids of Windows game processes in `ps -axo pid=,command=` output (Wine shows each by its Windows path).
    static func gameProcessIDs(inProcessList text: String) -> Set<Int> {
        Set(text.split(separator: "\n").compactMap { line -> Int? in
            // Only the executable path counts. Steam's command-line arguments can name a game too.
            let command = line.lowercased()
            guard let exe = command.range(of: ".exe"),
                  command[..<exe.lowerBound].contains("\\steamapps\\common\\") else { return nil }
            return Int(line.split(separator: " ", maxSplits: 1).first ?? "")
        })
    }

    /// The HUD samples that belong to the game. Steam's own window also draws through Metal (through DXMT
    /// or D3DMetal), and a TF2 run counted Steam's frames as the game's after the game had crashed. So
    /// only the game's own processes count once one has been seen; before that, the busiest process does.
    static func gameSamples(_ all: [MetalHUDLog.Sample], gamePIDs: Set<Int>) -> [MetalHUDLog.Sample] {
        let candidates = gamePIDs.isEmpty ? all : all.filter { gamePIDs.contains($0.pid) }
        let busiest = MetalHUDLog.busiestProcess(candidates)
        return candidates.filter { $0.pid == busiest }
    }

    static func measuredVerdict(_ samples: [MetalHUDLog.Sample], end: TimeInterval, window: TimeInterval) -> Verdict {
        let real = samples.filter { $0.frame > 0 }.sorted { $0.time < $1.time }
        guard let last = real.last else { return .noFrames }
        let recent = real.filter { $0.time >= end - window }
        guard last.time >= end - window, let lo = recent.first, lo.frame < last.frame else { return .stopped }
        return .works
    }
}

extension ProfileStore {
    /// Lab results for a profile, newest first.
    public func labResults(_ id: String) -> [LabResult] {
        let dir = directory(id).appendingPathComponent("lab", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { try? decoder.decode(LabResult.self, from: $0) }
        }.sorted { $0.startedAt > $1.startedAt }
    }
}

extension GamePort {
    /// Launches the profile's game with `renderer` (nil = its own choice) for `seconds`, measures it and
    /// stops everything. The profile is put back exactly as it was. Results land in profiles/<id>/lab/.
    public func lab(_ profileID: String, renderer: Renderer? = nil, seconds: Int = 180,
                    sync: SyncMode? = nil, vulkanDriver: VulkanDriver? = nil,
                    steadyAfter: TimeInterval = 60, progress: ProgressHandler? = nil) async throws -> LabResult {
        guard seconds > 0 else { throw GamePortError.invalid("Lab duration must be positive") }
        let original = try profiles.load(profileID)
        var trial = original
        if let renderer { trial.renderer = renderer }
        if let sync { trial.sync = sync }
        if let vulkanDriver { trial.vulkanDriver = vulkanDriver }
        trial.metalHUD = true
        trial.environment["MTL_HUD_LOG_ENABLED"] = "1"
        #if os(macOS)
        let marker = UUID().uuidString
        trial.environment[LabWindowCapture.markerKey] = marker
        #endif
        let runner = try self.runner(for: trial)
        try runner.engine.checkHost()
        try runner.engine.checkFiles()
        let steam = SteamClient(runner: runner)
        guard runner.recipe?.steamAppID != nil else { throw GamePortError.unsupported("\(profileID): the lab only runs Steam games") }
        let labDir = profiles.directory(profileID).appendingPathComponent("lab", isDirectory: true)
        try paths.ensure(labDir)
        let startedAt = Date()
        let stamp = ProfileStore.snapshotName(startedAt) + "-" + runner.effectiveRenderer.rawValue
        let hudLog = labDir.appendingPathComponent("\(stamp).hud.log")
        FileManager.default.createFile(atPath: hudLog.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: hudLog)
        let stream = Process()
        stream.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        stream.arguments = ["stream", "--style", "compact", "--predicate", #"subsystem == "com.apple.metal.hud""#]
        stream.standardOutput = logHandle
        stream.standardError = FileHandle.nullDevice
        try stream.run()
        defer { if stream.isRunning { stream.terminate() }; try? logHandle.close() }

        let driver = runner.effectiveVulkanDriver == .moltenvk ? "" : " on \(runner.effectiveVulkanDriver.displayName)"
        progress?("Starting with \(runner.effectiveRenderer.displayName)\(driver), measuring for \(seconds) s…")
        let gameLog = runner.logs.appendingPathComponent("game.log")
        let cefLog = steam.logs.appendingPathComponent("cef_log.txt")
        let bootstrapLog = steam.logs.appendingPathComponent("bootstrap_log.txt")
        func size(_ file: URL) -> UInt64 { (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? 0 }
        let cefStart = size(cefLog), bootstrapStart = size(bootstrapLog)
        var thermalSamples = [LabThermalState.current()].compactMap { $0 }
        _ = try steam.play()
        #if os(macOS)
        let capture = LabWindowCapture(marker: marker)
        let visualTask = Task {
            if steadyAfter < Double(seconds) {
                await capture.monitor(after: steadyAfter, progress: progress)
            }
        }
        defer { visualTask.cancel() }
        #endif
        var stopped = false
        defer { if !stopped { try? runner.killAll() } }
        var front: [Bool] = []
        var gamePIDs = Set<Int>()
        func runningGamePIDs() -> Set<Int> {
            LabResult.gameProcessIDs(inProcessList: (try? Shell.run("/bin/ps", ["-axo", "pid=,command="], check: false).output) ?? "")
        }
        for elapsed in stride(from: 30, through: seconds, by: 30) {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            gamePIDs.formUnion(runningGamePIDs())
            if let thermal = LabThermalState.current() { thermalSamples.append(thermal) }
            let app = Shell.frontmostAppName()
            front.append(app?.lowercased().contains("wine") ?? false)
            if front.last == false { progress?("Warning: \(app ?? "another app") is in front; keep the game window in front") }
            let samples = MetalHUDLog.parse((try? String(contentsOf: hudLog, encoding: .utf8)) ?? "")
            let frames = LabResult.gameSamples(samples, gamePIDs: gamePIDs).map(\.frame).max() ?? 0
            progress?("\(elapsed) s: \(Int(frames)) frames")
        }
        if seconds % 30 != 0 {
            try await Task.sleep(nanoseconds: UInt64(seconds % 30) * 1_000_000_000)
            gamePIDs.formUnion(runningGamePIDs())
        }
        let end = Date().timeIntervalSince1970
        #if os(macOS)
        visualTask.cancel()
        let visual = await capture.finding(progress: progress)
        #else
        let visual: LabFrameFinding? = nil
        #endif
        let finalPIDs = runningGamePIDs()
        let gameExited = !gamePIDs.isEmpty && finalPIDs.isEmpty
        gamePIDs.formUnion(finalPIDs)
        if let thermal = LabThermalState.current() { thermalSamples.append(thermal) }
        try runner.killAll()
        guard try runner.waitForServer(timeout: 15) else { throw GamePortError.invalid("Wine is still running in \(profileID)") }
        stopped = true
        stream.terminate()
        stream.waitUntilExit()

        let all = MetalHUDLog.parse((try? String(contentsOf: hudLog, encoding: .utf8)) ?? "")
        let gameSeen = !gamePIDs.isEmpty
        let samples = gameSeen ? LabResult.gameSamples(all, gamePIDs: gamePIDs) : []
        let frontmostShare = front.isEmpty ? nil : Double(front.filter { $0 }.count) / Double(front.count)
        // Shell.spawn starts game.log afresh for every launch, so the whole file is this run's.
        let logText = (try? String(contentsOf: gameLog, encoding: .utf8)) ?? ""
        let crashSigns = LabTriage.findings(game: logText, cef: Self.tail(of: cefLog, from: cefStart),
                                            bootstrap: Self.tail(of: bootstrapLog, from: bootstrapStart), gameExited: gameExited)
        let result = LabResult(
            profileID: profileID, recipeID: original.recipeID, renderer: runner.effectiveRenderer, sync: runner.effectiveSync,
            engineID: runner.engine.id, engineArchitecture: runner.engine.manifest.arch,
            macOS: Shell.macOSVersionString, machine: Shell.machineDescription,
            startedAt: startedAt, seconds: seconds, verdict: LabResult.verdict(samples, end: end, frontmostShare: frontmostShare,
                                                                         gameStarted: gameSeen, crashSigns: crashSigns, gameExited: gameExited, visual: visual),
            steady: LabStats.from(samples, after: startedAt.timeIntervalSince1970 + steadyAfter),
            whole: LabStats.from(samples), hudLog: hudLog.lastPathComponent, frontmostShare: frontmostShare,
            gameStarted: gameSeen, crashSigns: crashSigns, vulkanDriver: runner.effectiveVulkanDriver,
            peakThermalState: LabThermalState.peak(thermalSamples))
        let encoder = JSONEncoder.pretty
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(result).write(to: labDir.appendingPathComponent("\(stamp).json"))
        if let appID = runner.recipe?.steamAppID {
            _ = await telemetry.submitIfEnabled(result, steamAppID: appID)
        }
        return result
    }
}

/// How much a player can trust that a game runs, shown before anything is downloaded.
/// A measurement on this Mac beats a recipe's status; a recipe that cannot work always says so.
public struct Evidence: Sendable, Equatable {
    public enum Level: String, Sendable {
        case labWorks       // measured here: still rendering at the end of a lab run
        case labFailed      // measured here: crashed, froze or drew nothing
        case verified       // a GamePort developer ran it end to end
        case community      // reported working elsewhere, not checked by GamePort
        case antiCheatRisk  // anti-cheat refuses Wine: online play will almost certainly fail
        case untested
        case blocked        // cannot work (kernel anti-cheat, …)
    }

    public var level: Level
    public var title: String
    public var detail: String?

    public static func of(_ recipe: Recipe, results: [LabResult], antiCheat: AntiCheatEntry? = nil) -> Evidence {
        if recipe.status == .blocked {
            return Evidence(level: .blocked, title: "Will not run", detail: recipe.knownIssues.first?.symptom ?? antiCheat?.summary)
        }
        if let ac = antiCheat, ac.risk == .blocked {
            return Evidence(level: .blocked, title: "Will not run", detail: ac.summary)
        }
        var evidence = measuredOrStated(recipe, results: results)
        guard let ac = antiCheat else { return evidence }
        // A run in the lab shows the game starts; it says nothing about online play past anti-cheat.
        if ac.risk == .onlineDenied, evidence.level != .labWorks, evidence.level != .labFailed {
            return Evidence(level: .antiCheatRisk, title: "Online play will most likely fail", detail: ac.summary)
        }
        evidence.detail = [evidence.detail, ac.summary].compactMap { $0 }.joined(separator: " · ")
        return evidence
    }

    static func measuredOrStated(_ recipe: Recipe, results: [LabResult]) -> Evidence {
        // A covered window or idle scene cannot establish compatibility either way.
        if let last = results.filter({ $0.verdict != .notVisible && $0.verdict != .unchangedImage }).max(by: { $0.startedAt < $1.startedAt }) {
            let when = last.startedAt.formatted(date: .abbreviated, time: .omitted)
            let fps = (last.steady ?? last.whole).map { " · average \($0.averageFPS) FPS" } ?? ""
            return last.verdict == .works
                ? Evidence(level: .labWorks, title: "Measured on this Mac: works", detail: "\(last.setup)\(fps) · \(when)")
                : Evidence(level: .labFailed, title: "Measured on this Mac: problems", detail: "\(last.summary) · \(when)")
        }
        switch recipe.status {
        case .verified: return Evidence(level: .verified, title: "Verified by \(Brand.displayName)", detail: nil)
        case .community: return Evidence(level: .community, title: "Community report, not verified by \(Brand.displayName)", detail: nil)
        case .untested, .blocked: return Evidence(level: .untested, title: "Not tested", detail: nil)
        }
    }
}

extension LabResult {
    /// The run to pick a renderer by: one that still worked at the end, with the highest average FPS
    /// after warm-up (the whole run when there is no steady phase). Nil when none worked.
    public static func best(_ results: [LabResult]) -> LabResult? {
        func fps(_ r: LabResult) -> Double { (r.steady ?? r.whole)?.averageFPS ?? 0 }
        return results.filter { $0.verdict == .works }.max { fps($0) < fps($1) }
    }
}

extension GamePort {
    /// Renderers worth trying for a profile, its current choice first: DXMT, D3DMetal once Apple's
    /// licence is accepted, DXVK. WineD3D is left out: it is the fallback, never the fastest.
    /// The text a file gained after `offset` (all of it if the file was replaced by a shorter one).
    static func tail(of file: URL, from offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: offset <= size ? offset : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    public func labCandidates(_ profileID: String) throws -> [Renderer] {
        let runner = try runner(for: profileID)
        var list: [Renderer] = [runner.effectiveRenderer]
        for r in [Renderer.dxmt, .d3dmetal, .dxvk] where !list.contains(r) {
            if let license = r.gatingLicense(in: runner.engine.manifest), !licenses.isAccepted(license) { continue }
            if (try? r.environment(engine: runner.engine)) == nil { continue }
            list.append(r)
        }
        return list.filter { $0 != .wined3d }
    }

    /// Compare two independently installed copies with the primary profile's renderer, sync and Vulkan driver.
    /// Preflight both before either run and keep each result in its own profile's history.
    func comparisonRunners(_ id: String, with otherID: String,
                           checkHost: (InstalledEngine) throws -> Void = { try $0.checkHost() }) throws -> [WineRunner] {
        let first = try runner(for: id)
        let other = try enginePair(first.profile, otherID: otherID)
        let renderer = first.effectiveRenderer, sync = first.effectiveSync, driver = first.effectiveVulkanDriver
        return try [first.profile, other].map { profile in
            var candidate = profile
            candidate.renderer = renderer
            candidate.sync = sync
            candidate.vulkanDriver = driver
            let runner = try self.runner(for: candidate)
            try checkHost(runner.engine)
            try runner.engine.checkFiles()
            _ = try runner.environment()
            let steam = SteamClient(runner: runner)
            guard let appID = runner.recipe?.steamAppID, steam.isInstalled, steam.isGameInstalled(appID: appID) else {
                throw GamePortError.missing("install the Steam game in profile \(candidate.id) before comparing engines")
            }
            return runner
        }
    }

    public func compareEngines(_ id: String, with otherID: String, seconds: Int = 180,
                               progress: ProgressHandler? = nil) async throws -> [LabResult] {
        let runners = try comparisonRunners(id, with: otherID)
        var results: [LabResult] = []
        for runner in runners {
            progress?("Testing \(runner.profile.id) on \(runner.engine.id)")
            let run = try await lab(runner.profile.id, renderer: runner.effectiveRenderer, seconds: seconds,
                                    sync: runner.effectiveSync, vulkanDriver: runner.effectiveVulkanDriver, progress: progress)
            progress?("\(run.engineID): \(run.summary)")
            results.append(run)
        }
        return results
    }

    /// Runs the lab once per candidate renderer and switches the profile to the fastest one that works.
    /// The profile only gets an override when the winner differs from the recipe's own renderer.
    public func findBestRenderer(_ profileID: String, seconds: Int = 180,
                                 progress: ProgressHandler? = nil) async throws -> (best: LabResult?, runs: [LabResult]) {
        var runs: [LabResult] = []
        for renderer in try labCandidates(profileID) {
            do {
                runs.append(try await lab(profileID, renderer: renderer, seconds: seconds, progress: progress))
                progress?("→ \(runs.last!.summary)")
            } catch {
                progress?("→ \(renderer.rawValue): could not run (\(error))")
            }
        }
        guard let best = LabResult.best(runs) else { return (nil, runs) }
        var profile = try profiles.load(profileID)
        let recipeRenderer = profile.recipeID.flatMap { catalog[$0] }?.renderer
        profile.renderer = best.renderer == recipeRenderer ? nil : best.renderer
        try profiles.save(profile)
        return (best, runs)
    }
}
