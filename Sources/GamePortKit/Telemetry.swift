import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anonymous compatibility telemetry settings stored at `<root>/telemetry.json`.
/// On by default so real-hardware FPS & verdicts improve game defaults for everyone;
/// users can switch it off in Setup or with `gameport telemetry off`.
public struct TelemetrySettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var installID: String

    public init(enabled: Bool = true, installID: String = UUID().uuidString) {
        self.enabled = enabled
        self.installID = installID
    }
}

/// Strictly anonymous Lab report payload. Never includes usernames, file paths,
/// Steam account IDs, raw log lines, or screenshots.
public struct TelemetryReport: Codable, Sendable, Equatable {
    public var schema: Int = 1
    public var installID: String
    public var steamAppID: Int
    public var recipeID: String?
    public var renderer: Renderer
    public var vulkanDriver: VulkanDriver
    public var sync: SyncMode
    public var engineID: String
    public var engineArch: EngineArchitecture
    public var chip: String
    public var macOS: String
    public var verdict: LabResult.Verdict
    public var avgFPS: Double?
    public var onePercentLowFPS: Double?
    public var peakThermalState: String?
    public var crashCodes: [String]
    public var reportedDay: String

    /// Build a sanitized report from a completed Lab run. Returns nil for inconclusive runs.
    public static func from(_ result: LabResult, steamAppID: Int, installID: String) -> TelemetryReport? {
        guard steamAppID > 0, result.verdict != .notVisible, result.verdict != .unchangedImage else { return nil }
        let stats = result.steady ?? result.whole
        return TelemetryReport(
            installID: installID,
            steamAppID: steamAppID,
            recipeID: result.recipeID,
            renderer: result.renderer,
            vulkanDriver: result.vulkanDriver ?? .moltenvk,
            sync: result.sync,
            engineID: result.engineID,
            engineArch: result.engineArchitecture ?? .rosetta,
            chip: bucketChip(result.machine),
            macOS: majorMinor(result.macOS),
            verdict: result.verdict,
            avgFPS: stats?.averageFPS,
            onePercentLowFPS: stats?.onePercentLowFPS,
            peakThermalState: result.peakThermalState?.label,
            crashCodes: classifyCrashSigns(result.crashSigns ?? []),
            reportedDay: utcDay(result.startedAt)
        )
    }

    /// Build a sanitized report from a normal Play session (no Metal HUD required).
    /// Returns nil for short clean exits (< 60 s) so quick manual quits don't skew data.
    public static func fromPlaySession(
        steamAppID: Int,
        recipeID: String?,
        renderer: Renderer,
        vulkanDriver: VulkanDriver,
        sync: SyncMode,
        engineID: String,
        engineArch: EngineArchitecture,
        machine: String = Shell.machineDescription,
        macOS: String = Shell.macOSVersionString,
        gameStarted: Bool,
        playedSeconds: TimeInterval,
        stillRunning: Bool,
        crashSigns: [String],
        peakThermalState: LabThermalState?,
        installID: String,
        startedAt: Date = Date()
    ) -> TelemetryReport? {
        guard steamAppID > 0 else { return nil }
        let codes = classifyCrashSigns(crashSigns)
        let fatal = codes.contains("wine_exception") || codes.contains("vulkan_error") || codes.contains("vulkan_query_unsupported")
        let verdict: LabResult.Verdict
        if !gameStarted {
            guard !codes.isEmpty else { return nil }
            verdict = .noFrames
        } else if stillRunning && playedSeconds >= 60 && !fatal {
            verdict = .works
        } else if fatal || (!stillRunning && !codes.isEmpty && playedSeconds < 60) {
            verdict = .stopped
        } else if playedSeconds >= 60 {
            verdict = .works
        } else {
            return nil
        }
        return TelemetryReport(
            installID: installID,
            steamAppID: steamAppID,
            recipeID: recipeID,
            renderer: renderer,
            vulkanDriver: vulkanDriver,
            sync: sync,
            engineID: engineID,
            engineArch: engineArch,
            chip: bucketChip(machine),
            macOS: majorMinor(macOS),
            verdict: verdict,
            avgFPS: nil,
            onePercentLowFPS: nil,
            peakThermalState: peakThermalState?.label,
            crashCodes: codes,
            reportedDay: utcDay(startedAt)
        )
    }

    public static func sample(installID: String) -> TelemetryReport {
        TelemetryReport(
            installID: installID,
            steamAppID: 440,
            recipeID: "team-fortress-2",
            renderer: .dxmt,
            vulkanDriver: .moltenvk,
            sync: .msync,
            engineID: "x64-crossover26.3-hb20261014",
            engineArch: .rosetta,
            chip: bucketChip(Shell.machineDescription),
            macOS: majorMinor(Shell.macOSVersionString),
            verdict: .works,
            avgFPS: 120.0,
            onePercentLowFPS: 84.0,
            peakThermalState: "nominal",
            crashCodes: [],
            reportedDay: utcDay(Date())
        )
    }

    static func bucketChip(_ machine: String) -> String {
        let trimmed = machine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Apple Silicon" }
        // Keep only the chip/model label (max 40 safe ASCII chars).
        let clean = String(trimmed.prefix(40).filter { $0.isASCII && ($0.isLetter || $0.isNumber || " .-".contains($0)) })
        return clean.isEmpty ? "Apple Silicon" : clean
    }

    static func majorMinor(_ version: String) -> String {
        let parts = version.split(separator: ".").prefix(2)
        return parts.isEmpty ? "unknown" : parts.joined(separator: ".")
    }

    static func utcDay(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    /// Map free-text crash signs to fixed, privacy-safe category codes.
    static func classifyCrashSigns(_ signs: [String]) -> [String] {
        var codes: [String] = []
        for sign in signs {
            let s = sign.lowercased()
            let code: String
            if s.contains("steam itself never started") { code = "steam_not_started" }
            else if s.contains("steam's gpu process") { code = "steam_gpu_crash" }
            else if s.contains("exited before the end") { code = "game_exited" }
            else if s.contains("pipeline") || s.contains("query") { code = "vulkan_query_unsupported" }
            else if s.contains("vulkan") || s.contains("dxvk") { code = "vulkan_error" }
            else if s.contains("exception") || s.contains("page fault") || s.contains("assert") { code = "wine_exception" }
            else { code = "other_error" }
            if !codes.contains(code) { codes.append(code) }
        }
        return codes
    }
}

public struct TelemetryStore: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public var file: URL { paths.root.appendingPathComponent("telemetry.json") }

    public func load() -> TelemetrySettings {
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode(TelemetrySettings.self, from: data),
           !decoded.installID.isEmpty {
            return decoded
        }
        let fresh = TelemetrySettings()
        try? save(fresh)
        return fresh
    }

    public func save(_ settings: TelemetrySettings) throws {
        try paths.ensure(paths.root)
        try JSONEncoder.pretty.encode(settings).write(to: file, options: .atomic)
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) throws -> TelemetrySettings {
        var current = load()
        current.enabled = enabled
        try save(current)
        return current
    }

    @discardableResult
    public func resetInstallID() throws -> TelemetrySettings {
        var current = load()
        current.installID = UUID().uuidString
        try save(current)
        return current
    }

    public func isEffectivelyEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if environment["DO_NOT_TRACK"] == "1" || environment["GAMEPORT_TELEMETRY"] == "0" { return false }
        return load().enabled
    }

    public func endpoint(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let raw = environment[Brand.telemetryURLVariable] ?? Brand.telemetryEndpoint
        guard let raw, !raw.isEmpty, let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }

    public func previewJSON() -> String {
        let report = TelemetryReport.sample(installID: load().installID)
        guard let data = try? JSONEncoder.pretty.encode(report), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Best-effort HTTPS POST. Never throws or blocks gameplay if offline or unconfigured.
    @discardableResult
    public func submitIfEnabled(_ result: LabResult, steamAppID: Int,
                                environment: [String: String] = ProcessInfo.processInfo.environment) async -> Bool {
        guard isEffectivelyEnabled(environment: environment),
              let url = endpoint(environment: environment),
              let report = TelemetryReport.from(result, steamAppID: steamAppID, installID: load().installID) else { return false }
        return await post(report, to: url)
    }

    /// Lightweight background observer for normal Play sessions (no Metal HUD overlay).
    /// Polls every 5 s; reports `.works` once a game runs cleanly for 90 s, or `.stopped`/`.noFrames` on crash.
    public func monitorPlaySession(
        runner: WineRunner,
        steamAppID: Int,
        cefLogOffset: UInt64,
        bootstrapLogOffset: UInt64,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard isEffectivelyEnabled(environment: environment),
              let url = endpoint(environment: environment) else { return }
        let installID = load().installID
        let startedAt = Date()
        let gameLog = runner.logs.appendingPathComponent("game.log")
        let steam = SteamClient(runner: runner)
        let cefLog = steam.logs.appendingPathComponent("cef_log.txt")
        let bootstrapLog = steam.logs.appendingPathComponent("bootstrap_log.txt")
        let recipeID = runner.profile.recipeID
        let renderer = runner.effectiveRenderer
        let vulkanDriver = runner.effectiveVulkanDriver
        let sync = runner.effectiveSync
        let engineID = runner.engine.id
        let engineArch = runner.engine.manifest.arch

        Task.detached(priority: .utility) {
            var gameStart: Date?
            var thermalSamples: [LabThermalState] = [LabThermalState.current()].compactMap { $0 }
            let maxWaitWithoutGame: TimeInterval = 180
            let healthyThreshold: TimeInterval = 90

            while true {
                try? await Task.sleep(for: .seconds(5))
                if let t = LabThermalState.current() { thermalSamples.append(t) }
                let ps = (try? Shell.run("/bin/ps", ["-axo", "pid=,command="], check: false).output) ?? ""
                let activePIDs = LabResult.gameProcessIDs(inProcessList: ps)
                let now = Date()

                if !activePIDs.isEmpty {
                    if gameStart == nil { gameStart = now }
                    let played = now.timeIntervalSince(gameStart!)
                    if played >= healthyThreshold {
                        let logText = (try? String(contentsOf: gameLog, encoding: .utf8)) ?? ""
                        let signs = LabTriage.findings(
                            game: logText,
                            cef: GamePort.tail(of: cefLog, from: cefLogOffset),
                            bootstrap: GamePort.tail(of: bootstrapLog, from: bootstrapLogOffset),
                            gameExited: false
                        )
                        if let report = TelemetryReport.fromPlaySession(
                            steamAppID: steamAppID, recipeID: recipeID, renderer: renderer,
                            vulkanDriver: vulkanDriver, sync: sync, engineID: engineID, engineArch: engineArch,
                            gameStarted: true, playedSeconds: played, stillRunning: true,
                            crashSigns: signs, peakThermalState: LabThermalState.peak(thermalSamples),
                            installID: installID, startedAt: startedAt
                        ) {
                            _ = await self.post(report, to: url)
                        }
                        return
                    }
                } else if let start = gameStart {
                    let played = now.timeIntervalSince(start)
                    let logText = (try? String(contentsOf: gameLog, encoding: .utf8)) ?? ""
                    let signs = LabTriage.findings(
                        game: logText,
                        cef: GamePort.tail(of: cefLog, from: cefLogOffset),
                        bootstrap: GamePort.tail(of: bootstrapLog, from: bootstrapLogOffset),
                        gameExited: true
                    )
                    if let report = TelemetryReport.fromPlaySession(
                        steamAppID: steamAppID, recipeID: recipeID, renderer: renderer,
                        vulkanDriver: vulkanDriver, sync: sync, engineID: engineID, engineArch: engineArch,
                        gameStarted: true, playedSeconds: played, stillRunning: false,
                        crashSigns: signs, peakThermalState: LabThermalState.peak(thermalSamples),
                        installID: installID, startedAt: startedAt
                    ) {
                        _ = await self.post(report, to: url)
                    }
                    return
                } else if now.timeIntervalSince(startedAt) >= maxWaitWithoutGame {
                    let logText = (try? String(contentsOf: gameLog, encoding: .utf8)) ?? ""
                    let signs = LabTriage.findings(
                        game: logText,
                        cef: GamePort.tail(of: cefLog, from: cefLogOffset),
                        bootstrap: GamePort.tail(of: bootstrapLog, from: bootstrapLogOffset),
                        gameExited: false
                    )
                    if let report = TelemetryReport.fromPlaySession(
                        steamAppID: steamAppID, recipeID: recipeID, renderer: renderer,
                        vulkanDriver: vulkanDriver, sync: sync, engineID: engineID, engineArch: engineArch,
                        gameStarted: false, playedSeconds: 0, stillRunning: false,
                        crashSigns: signs, peakThermalState: LabThermalState.peak(thermalSamples),
                        installID: installID, startedAt: startedAt
                    ) {
                        _ = await self.post(report, to: url)
                    }
                    return
                }
            }
        }
    }

    @discardableResult
    func post(_ report: TelemetryReport, to url: URL) async -> Bool {
        guard let body = try? JSONEncoder().encode(report) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(Brand.displayName)/1", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return false }
        return true
    }
}
